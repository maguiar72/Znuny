# Znuny container image (Apache2 + mod_perl) for Azure Container Apps.
#
# Build context is the repository root:
#   docker build -f deploy/docker/Dockerfile -t znuny:local .
#
# Runtime configuration is supplied through environment variables
# (see deploy/docker/entrypoint.sh). The database is expected to be an
# external Azure Database for MySQL Flexible Server.

FROM debian:bookworm-slim

# Apache runs as the Debian default www-data user; Znuny files are owned by the
# znuny user with the www-data group so the web server can write to var/.
ENV DEBIAN_FRONTEND=noninteractive \
    ZNUNY_HOME=/opt/znuny \
    ZNUNY_USER=znuny \
    ZNUNY_WEB_GROUP=www-data

# --- System packages + Perl modules --------------------------------------
# The Perl dependencies mirror the "Required" modules reported by
# bin/znuny.CheckModules.pl. Debian packages are used instead of CPAN builds
# to keep the image small and reproducible.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        apache2 \
        libapache2-mod-perl2 \
        libapache-dbi-perl \
        perl \
        default-mysql-client \
        procps \
        curl \
        ca-certificates \
        tzdata \
        libdbi-perl \
        libdbd-mysql-perl \
        libdatetime-perl \
        libdatetime-timezone-perl \
        libtemplate-perl \
        libnet-dns-perl \
        libio-socket-ssl-perl \
        liblwp-protocol-https-perl \
        libwww-perl \
        libjson-xs-perl \
        libyaml-libyaml-perl \
        libxml-libxml-perl \
        libxml-libxslt-perl \
        libxml-parser-perl \
        libtext-csv-xs-perl \
        libcrypt-eksblowfish-perl \
        libencode-hanextra-perl \
        libmoo-perl \
        libnamespace-clean-perl \
        libarchive-zip-perl \
        libconvert-binhex-perl \
        libmail-imapclient-perl \
        libauthen-sasl-perl \
        libauthen-ntlm-perl \
        libgd-perl \
        libgd-text-perl \
        libgd-graph-perl \
        libhtml-parser-perl \
        libtimedate-perl \
        libsisimai-perl \
        ; \
    rm -rf /var/lib/apt/lists/*

# --- Application user ------------------------------------------------------
RUN useradd -r -g www-data -d "${ZNUNY_HOME}" -s /bin/bash "${ZNUNY_USER}"

# --- Application source -----------------------------------------------------
COPY . ${ZNUNY_HOME}
WORKDIR ${ZNUNY_HOME}

# Provide the default config templates and fix permissions.
RUN set -eux; \
    cp -f deploy/docker/Config.pm Kernel/Config.pm; \
    for f in $(find . -name '*.dist' -type f); do \
        target="${f%.dist}"; \
        if [ ! -e "$target" ]; then cp -f "$f" "$target"; fi; \
    done; \
    perl bin/znuny.SetPermissions.pl --znuny-user="${ZNUNY_USER}" --web-group="${ZNUNY_WEB_GROUP}" || true

# --- Apache configuration ---------------------------------------------------
# Listen on 8080 (Container Apps default target port, no root needed) and load
# the Znuny mod_perl configuration shipped in the repository.
RUN set -eux; \
    a2enmod perl headers deflate filter; \
    a2dismod mpm_event || true; \
    a2enmod mpm_prefork; \
    sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf; \
    printf 'ServerName localhost\n' > /etc/apache2/conf-available/servername.conf; \
    a2enconf servername; \
    ln -sf ${ZNUNY_HOME}/scripts/apache2-httpd.include.conf /etc/apache2/conf-available/znuny.conf; \
    a2enconf znuny; \
    printf '<VirtualHost *:8080>\n    DocumentRoot %s/var/httpd/htdocs\n    RedirectMatch ^/$ /znuny/index.pl\n    ErrorLog /proc/self/fd/2\n    CustomLog /proc/self/fd/1 combined\n</VirtualHost>\n' "${ZNUNY_HOME}" \
        > /etc/apache2/sites-available/znuny-vhost.conf; \
    a2ensite znuny-vhost; \
    a2dissite 000-default || true; \
    # Send the global error log to the container's stderr as well.
    sed -i 's#^ErrorLog .*#ErrorLog /proc/self/fd/2#' /etc/apache2/apache2.conf

COPY deploy/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080

# Container Apps health probe hits "/" which redirects to the login page.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD curl -fsS http://127.0.0.1:8080/znuny/index.pl > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
