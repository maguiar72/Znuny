#!/bin/bash
# --
# Container entrypoint for Znuny on Azure Container Apps.
#
# Responsibilities:
#   1. Optionally fetch the Azure MySQL TLS CA certificate.
#   2. Wait for the database to become reachable.
#   3. Load the schema on first boot (idempotent).
#   4. Rebuild the Znuny config cache and fix permissions.
#   5. Start the Znuny daemon (background) and Apache (foreground).
# --
set -euo pipefail

ZNUNY_HOME="${ZNUNY_HOME:-/opt/znuny}"
ZNUNY_USER="${ZNUNY_USER:-znuny}"

DB_HOST="${ZNUNY_DB_HOST:-127.0.0.1}"
DB_PORT="${ZNUNY_DB_PORT:-3306}"
DB_NAME="${ZNUNY_DB_NAME:-znuny}"
DB_USER="${ZNUNY_DB_USER:-znuny}"
DB_PASSWORD="${ZNUNY_DB_PASSWORD:-}"

log() { echo "[entrypoint] $*"; }

# --- 1. TLS CA certificate for Azure Database for MySQL --------------------
# Azure Database for MySQL Flexible Server enforces TLS. If ZNUNY_DB_SSL_CA is
# a URL we download it; if it is an existing path we use it as-is.
# Flags below use MariaDB-client syntax (Debian's default-mysql-client is the
# MariaDB client): --ssl / --ssl-ca / --ssl-verify-server-cert.
CA_ARGS=()
if [ -n "${ZNUNY_DB_SSL_CA:-}" ]; then
    case "${ZNUNY_DB_SSL_CA}" in
        http://*|https://*)
            CA_PATH="${ZNUNY_HOME}/var/azure-mysql-ca.pem"
            if [ ! -s "${CA_PATH}" ]; then
                log "Downloading MySQL CA certificate from ${ZNUNY_DB_SSL_CA}"
                curl -fsSL "${ZNUNY_DB_SSL_CA}" -o "${CA_PATH}"
            fi
            export ZNUNY_DB_SSL_CA="${CA_PATH}"
            ;;
    esac
    CA_ARGS=(--ssl "--ssl-ca=${ZNUNY_DB_SSL_CA}" --ssl-verify-server-cert)
elif [ "${ZNUNY_DB_SSL:-required}" = "required" ]; then
    CA_ARGS=(--ssl)
fi

mysql_cmd() {
    MYSQL_PWD="${DB_PASSWORD}" mysql \
        --host="${DB_HOST}" --port="${DB_PORT}" \
        --user="${DB_USER}" "${CA_ARGS[@]}" "$@"
}

# --- 2. Wait for the database ---------------------------------------------
log "Waiting for database ${DB_HOST}:${DB_PORT} ..."
for i in $(seq 1 60); do
    if mysql_cmd --execute="SELECT 1" >/dev/null 2>&1; then
        log "Database is reachable."
        break
    fi
    if [ "$i" -eq 60 ]; then
        log "ERROR: database not reachable after 60 attempts."
        exit 1
    fi
    sleep 5
done

# --- 3. First-boot schema load --------------------------------------------
# Ensure the database exists (Azure MySQL user needs CREATE, or pre-create it).
mysql_cmd --execute="CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4;" 2>/dev/null || true

TABLE_COUNT=$(mysql_cmd --database="${DB_NAME}" --skip-column-names \
    --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo 0)

if [ "${TABLE_COUNT:-0}" -eq 0 ]; then
    if [ "${ZNUNY_DB_AUTO_SCHEMA:-1}" = "1" ]; then
        log "Empty database detected – loading Znuny schema."
        mysql_cmd --database="${DB_NAME}" < "${ZNUNY_HOME}/scripts/database/schema.mysql.sql"
        mysql_cmd --database="${DB_NAME}" < "${ZNUNY_HOME}/scripts/database/initial_insert.mysql.sql"
        mysql_cmd --database="${DB_NAME}" < "${ZNUNY_HOME}/scripts/database/schema-post.mysql.sql"
        log "Schema loaded. Default admin login: root@localhost / root (change immediately)."
    else
        log "Empty database but ZNUNY_DB_AUTO_SCHEMA=0 – skipping schema load."
    fi
else
    log "Database already initialized (${TABLE_COUNT} tables)."
fi

# --- 3b. Generate Kernel/Config.pm with literal values --------------------
# mod_perl runs with "PerlOptions +SetupEnv", which replaces %ENV with the
# per-request CGI environment. Reading container env vars from %ENV at request
# time is therefore unreliable, so we bake the resolved values into Config.pm
# at boot. This also guarantees the daemon and the web use identical settings.
log "Generating Kernel/Config.pm."

# Build the DSN, enabling TLS whenever it is not explicitly disabled
# (Azure Database for MySQL enforces require_secure_transport=ON).
#
# IMPORTANT: Debian's DBD::mysql is linked against the MariaDB connector, which
# does NOT support "mysql_ssl=1" (it raises "Enforcing SSL encryption is not
# supported"). With this connector, TLS is enabled by supplying a CA file via
# "mysql_ssl_ca_file". The system CA bundle already contains the DigiCert roots
# that Azure Database for MySQL chains to, so we default to it.
DSN="DBI:mysql:database=${DB_NAME};host=${DB_HOST};port=${DB_PORT}"
if [ "${ZNUNY_DB_SSL:-required}" != "disabled" ]; then
    SSL_CA="${ZNUNY_DB_SSL_CA:-/etc/ssl/certs/ca-certificates.crt}"
    DSN="${DSN};mysql_ssl_ca_file=${SSL_CA}"
fi

# Escape values for a Perl single-quoted string ( \ and ' are special ).
perl_quote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }

HTTP_TYPE="${ZNUNY_HTTP_TYPE:-https}"

# Derive the public FQDN from the values Container Apps injects, unless it was
# provided explicitly (e.g. a custom domain). This lets Znuny build correct
# absolute links without hardcoding the ingress hostname.
if [ -z "${ZNUNY_FQDN:-}" ] && [ -n "${CONTAINER_APP_NAME:-}" ] && [ -n "${CONTAINER_APP_ENV_DNS_SUFFIX:-}" ]; then
    ZNUNY_FQDN="${CONTAINER_APP_NAME}.${CONTAINER_APP_ENV_DNS_SUFFIX}"
    log "Derived public FQDN: ${ZNUNY_FQDN}"
fi

FQDN_LINE=""
if [ -n "${ZNUNY_FQDN:-}" ]; then
    FQDN_LINE="    \$Self->{FQDN} = '$(perl_quote "${ZNUNY_FQDN}")';
    \$Self->{HttpType} = '$(perl_quote "${HTTP_TYPE}")';
    \$Self->{ScriptAlias} = 'znuny/';"
fi

cat > "${ZNUNY_HOME}/Kernel/Config.pm" <<EOF
# Generated at container start by deploy/docker/entrypoint.sh - do not edit.
package Kernel::Config;
use strict;
use warnings;
use utf8;

sub Load {
    my \$Self = shift;

    \$Self->{DatabaseHost} = '$(perl_quote "${DB_HOST}")';
    \$Self->{Database}     = '$(perl_quote "${DB_NAME}")';
    \$Self->{DatabaseUser} = '$(perl_quote "${DB_USER}")';
    \$Self->{DatabasePw}   = '$(perl_quote "${DB_PASSWORD}")';
    \$Self->{DatabaseDSN}  = '$(perl_quote "${DSN}")';

    \$Self->{Home} = '${ZNUNY_HOME}';

    \$Self->{LogModule}            = 'Kernel::System::Log::File';
    \$Self->{'LogModule::LogFile'} = '${ZNUNY_HOME}/var/log/znuny.log';
${FQDN_LINE}

    # \$DIBI\$
    return 1;
}

use Kernel::Config::Defaults;
use parent qw(Kernel::Config::Defaults);

1;
EOF
chown "${ZNUNY_USER}:${ZNUNY_WEB_GROUP:-www-data}" "${ZNUNY_HOME}/Kernel/Config.pm"
chmod 660 "${ZNUNY_HOME}/Kernel/Config.pm"

# --- 4. Config cache + permissions ----------------------------------------
log "Rebuilding configuration cache."
su -s /bin/bash "${ZNUNY_USER}" -c "cd ${ZNUNY_HOME} && perl bin/znuny.Console.pl Maint::Config::Rebuild" || \
    log "WARNING: config rebuild reported issues (continuing)."

perl "${ZNUNY_HOME}/bin/znuny.SetPermissions.pl" \
    --znuny-user="${ZNUNY_USER}" --web-group="${ZNUNY_WEB_GROUP:-www-data}" >/dev/null 2>&1 || true

# --- 5. Start daemon + Apache ---------------------------------------------
# The Znuny daemon handles background jobs (email, generic agent, escalations).
# For higher throughput run it as a dedicated Container Apps replica/job.
if [ "${ZNUNY_RUN_DAEMON:-1}" = "1" ]; then
    log "Starting Znuny daemon."
    su -s /bin/bash "${ZNUNY_USER}" -c "cd ${ZNUNY_HOME} && perl bin/znuny.Daemon.pl start" || \
        log "WARNING: could not start Znuny daemon."
fi

log "Starting Apache (foreground) on port 8080."
exec apache2ctl -D FOREGROUND
