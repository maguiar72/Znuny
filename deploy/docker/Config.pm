# --
# Kernel/Config.pm - container/environment driven configuration
# --
# This configuration file is tailored for containerized deployments
# (Azure Container Apps). Database credentials and a handful of runtime
# settings are read from environment variables so that no secrets are baked
# into the image. All other configuration is managed through the Znuny
# web interface (SysConfig) and stored in the database.
# --

package Kernel::Config;

use strict;
use warnings;
use utf8;

sub Load {
    my $Self = shift;

    # ---------------------------------------------------- #
    # database settings (from environment)                 #
    # ---------------------------------------------------- #
    $Self->{DatabaseHost} = $ENV{ZNUNY_DB_HOST}     // '127.0.0.1';
    $Self->{Database}     = $ENV{ZNUNY_DB_NAME}     // 'znuny';
    $Self->{DatabaseUser} = $ENV{ZNUNY_DB_USER}     // 'znuny';
    $Self->{DatabasePw}   = $ENV{ZNUNY_DB_PASSWORD} // '';

    my $Port = $ENV{ZNUNY_DB_PORT} // '3306';

    # MySQL / MariaDB DSN. Azure Database for MySQL Flexible Server enforces
    # TLS (require_secure_transport=ON), so enable mysql_ssl unless it is
    # explicitly disabled. Add CA verification when a CA path is provided.
    #
    # NOTE: at runtime the container entrypoint regenerates this file with
    # literal values because mod_perl (+SetupEnv) replaces %ENV per request,
    # making env lookups here unreliable. This env-based version is a fallback.
    my $DSN = "DBI:mysql:database=$Self->{Database};host=$Self->{DatabaseHost};port=$Port";
    if ( ( $ENV{ZNUNY_DB_SSL} // 'required' ) ne 'disabled' || $ENV{ZNUNY_DB_SSL_CA} ) {
        $DSN .= ";mysql_ssl=1";
        $DSN .= ";mysql_ssl_ca_file=$ENV{ZNUNY_DB_SSL_CA}" if $ENV{ZNUNY_DB_SSL_CA};
    }
    $Self->{DatabaseDSN} = $DSN;

    # ---------------------------------------------------- #
    # fs root directory                                    #
    # ---------------------------------------------------- #
    $Self->{Home} = $ENV{ZNUNY_HOME} // '/opt/znuny';

    # ---------------------------------------------------- #
    # deployment specific settings                         #
    # ---------------------------------------------------- #

    # Public base URL (behind the Container Apps HTTPS ingress).
    if ( $ENV{ZNUNY_FQDN} ) {
        $Self->{HttpType}          = $ENV{ZNUNY_HTTP_TYPE} // 'https';
        $Self->{FQDN}              = $ENV{ZNUNY_FQDN};
        $Self->{ScriptAlias}       = 'znuny/';
    }

    # Log to a file (no syslog daemon in the container). Inspect with
    # `az containerapp exec` -> tail -f var/log/znuny.log.
    $Self->{LogModule}             = 'Kernel::System::Log::File';
    $Self->{'LogModule::LogFile'}  = ( $ENV{ZNUNY_HOME} // '/opt/znuny' ) . '/var/log/znuny.log';

    # ---------------------------------------------------- #
    # data inserted by installer                           #
    # ---------------------------------------------------- #
    # $DIBI$

    return 1;
}

# ---------------------------------------------------- #
# needed system stuff (don't edit this)                #
# ---------------------------------------------------- #

use Kernel::Config::Defaults;    # import Translatable()
use parent qw(Kernel::Config::Defaults);

1;
