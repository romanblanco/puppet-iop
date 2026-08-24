# == Class: iop
#
# Install and configure IOP services
#
# === Parameters:
#
# === Advanced parameters:
#
# $register_as_smartproxy:: Whether to register as a smart proxy
#
# $foreman_base_url:: Base URL for Foreman connection
#
# $ensure:: Whether services should be present or absent
#
# === Database parameters:
#
# $database_host:: Shared database host for all services
#
# $database_port:: Shared database port for all services
#
# $inventory_database_name:: Database name for host inventory service
#
# $inventory_database_user:: Database user for host inventory service
#
# $inventory_database_password:: Database password for host inventory service
#
# $vulnerability_database_name:: Database name for vulnerability service
#
# $vulnerability_database_user:: Database user for vulnerability service
#
# $vulnerability_database_password:: Database password for vulnerability service
#
# $vmaas_database_name:: Database name for vmaas service
#
# $vmaas_database_user:: Database user for vmaas service
#
# $vmaas_database_password:: Database password for vmaas service
#
# $advisor_database_name:: Database name for advisor service
#
# $advisor_database_user:: Database user for advisor service
#
# $advisor_database_password:: Database password for advisor service
#
# $remediations_database_name:: Database name for remediations service
#
# $remediations_database_user:: Database user for remediations service
#
# $remediations_database_password:: Database password for remediations service
#
# $compliance_database_name:: Database name for compliance service
#
# $compliance_database_user:: Database user for compliance service
#
# $compliance_database_password:: Database password for compliance service
#
# === Core Engine parameters:
#
# $core_engine_log_level_insights_core_dr:: Log level for insights.core.dr logger
#
# $core_engine_log_level_insights_messaging:: Log level for insights_messaging logger
#
# $core_engine_log_level_insights_kafka_service:: Log level for insights_kafka_service logger
#
# $core_engine_log_level_root:: Log level for root logger
#
class iop (
  Enum['present', 'absent'] $ensure = 'present',
  Boolean $register_as_smartproxy = true,
  Optional[Stdlib::HTTPUrl] $foreman_base_url = undef,
  String[1] $database_host = '/var/run/postgresql/',
  Stdlib::Port $database_port = 5432,
  String[1] $inventory_database_name = 'inventory_db',
  String[1] $inventory_database_user = 'inventory_user',
  String[1] $inventory_database_password = $iop::params::inventory_database_password,
  String[1] $vulnerability_database_name = 'vulnerability_db',
  String[1] $vulnerability_database_user = 'vulnerability_admin',
  String[1] $vulnerability_database_password = $iop::params::vulnerability_database_password,
  String[1] $vmaas_database_name = 'vmaas_db',
  String[1] $vmaas_database_user = 'vmaas_admin',
  String[1] $vmaas_database_password = $iop::params::vmaas_database_password,
  String[1] $advisor_database_name = 'advisor_db',
  String[1] $advisor_database_user = 'advisor_user',
  String[1] $advisor_database_password = $iop::params::advisor_database_password,
  String[1] $remediations_database_name = 'remediations_db',
  String[1] $remediations_database_user = 'remediations_user',
  String[1] $remediations_database_password = $iop::params::remediations_database_password,
  String[1] $compliance_database_name = 'compliance_db',
  String[1] $compliance_database_user = 'compliance_admin',
  String[1] $compliance_database_password = $iop::params::compliance_database_password,
  Enum['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'] $core_engine_log_level_insights_core_dr = 'ERROR',
  Enum['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'] $core_engine_log_level_insights_messaging = 'INFO',
  Enum['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'] $core_engine_log_level_insights_kafka_service = 'INFO',
  Enum['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'] $core_engine_log_level_root = 'INFO',
) inherits iop::params {
  class { 'iop::core_network': ensure => $ensure }
  class { 'iop::core_kafka': ensure => $ensure }
  class { 'iop::core_ingress': ensure => $ensure }
  class { 'iop::core_puptoo': ensure => $ensure }
  class { 'iop::core_yuptoo': ensure => $ensure }
  class { 'iop::core_engine':
    ensure                           => $ensure,
    log_level_insights_core_dr       => $core_engine_log_level_insights_core_dr,
    log_level_insights_messaging     => $core_engine_log_level_insights_messaging,
    log_level_insights_kafka_service => $core_engine_log_level_insights_kafka_service,
    log_level_root                   => $core_engine_log_level_root,
  }
  class { 'iop::core_gateway': ensure => $ensure }
  class { 'iop::core_host_inventory':
    ensure            => $ensure,
    database_host     => $database_host,
    database_port     => $database_port,
    database_name     => $inventory_database_name,
    database_user     => $inventory_database_user,
    database_password => $inventory_database_password,
  }
  class { 'iop::core_host_inventory_frontend': ensure => $ensure }

  class { 'iop::service_vmaas':
    ensure            => $ensure,
    database_host     => $database_host,
    database_port     => $database_port,
    database_name     => $vmaas_database_name,
    database_user     => $vmaas_database_user,
    database_password => $vmaas_database_password,
  }
  class { 'iop::service_vulnerability_frontend': ensure => $ensure }
  class { 'iop::service_vulnerability':
    ensure            => $ensure,
    database_host     => $database_host,
    database_port     => $database_port,
    database_name     => $vulnerability_database_name,
    database_user     => $vulnerability_database_user,
    database_password => $vulnerability_database_password,
  }

  class { 'iop::service_advisor_frontend': ensure => $ensure }
  class { 'iop::service_advisor':
    ensure            => $ensure,
    database_host     => $database_host,
    database_port     => $database_port,
    database_name     => $advisor_database_name,
    database_user     => $advisor_database_user,
    database_password => $advisor_database_password,
  }
  class { 'iop::service_remediations':
    ensure            => $ensure,
    database_host     => $database_host,
    database_port     => $database_port,
    database_name     => $remediations_database_name,
    database_user     => $remediations_database_user,
    database_password => $remediations_database_password,
  }
  class { 'iop::service_compliance':
    ensure            => $ensure,
    database_host     => $database_host,
    database_port     => $database_port,
    database_name     => $compliance_database_name,
    database_user     => $compliance_database_user,
    database_password => $compliance_database_password,
  }

  if $register_as_smartproxy {
    $oauth_consumer_key = extlib::cache_data('foreman_cache_data', 'oauth_consumer_key', extlib::random_password(32))
    $oauth_consumer_secret = extlib::cache_data('foreman_cache_data', 'oauth_consumer_secret', extlib::random_password(32))

    $_foreman_base_url_real = pick($foreman_base_url, "https://${facts['networking']['fqdn']}")

    foreman_smartproxy { 'iop-gateway':
      ensure          => $ensure,
      base_url        => $_foreman_base_url_real,
      consumer_key    => $oauth_consumer_key,
      consumer_secret => $oauth_consumer_secret,
      effective_user  => 'admin',
      ssl_ca          => $certs::iop::client_ca_cert,
      url             => 'https://localhost:24443',
      require         => [
        Class['iop::core_gateway'],
      ],
    }
  }

  class { 'iop_advisor_engine':
    ensure => 'absent',
  }
}
