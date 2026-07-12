# == Class: iop::service_compliance
#
# Install and configure the Compliance service
#
# === Parameters:
#
# $image:: The container image
#
# $ensure:: Ensure service is present or absent
#
# $database_user:: Username for the compliance database
#
# $database_name:: Name of the compliance database
#
# $database_password:: Password for the compliance database
#
# $database_host:: Host for the compliance database
#
# $database_port:: Port for the compliance database
#
class iop::service_compliance (
  # TODO: Replace with official images once PRs are merged and CI pipelines publish to quay.io/iop/
  # Production: quay.io/cloudservices/compliance-backend:latest (or quay.io/iop/compliance-backend:<tag>)
  String[1] $image = 'quay.io/rblanco/compliance-backend:foreman-iop-dev',
  # TODO: Replace with quay.io/cloudservices/compliance-ssg:latest (or quay.io/iop/compliance-ssg-upstream:<tag>)
  String[1] $ssg_image = 'quay.io/rblanco/compliance-ssg-upstream:latest',
  Enum['present', 'absent'] $ensure = 'present',
  String[1] $database_name = 'compliance_db',
  String[1] $database_user = 'compliance_admin',
  String[1] $database_password = $iop::params::compliance_database_password,
  String[1] $database_host = '/var/run/postgresql',
  Stdlib::Port $database_port = 5432,
) inherits iop::params {
  include podman
  include iop::database
  include iop::core_kafka
  include iop::core_network
  include iop::core_host_inventory

  $service_name = 'iop-service-compliance-backend'
  $database_username_secret_name = "${service_name}-database-username"
  $database_password_secret_name = "${service_name}-database-password"
  $database_name_secret_name = "${service_name}-database-name"
  $database_host_secret_name = "${service_name}-database-host"
  $database_port_secret_name = "${service_name}-database-port"

  $socket_volume = $database_host ? {
    /^\/var\/run\/postgresql/ => ['/var/run/postgresql:/var/run/postgresql:rw'],
    default                   => [],
  }

  podman::secret { $database_username_secret_name:
    ensure => $ensure,
    secret => Sensitive($database_user),
  }

  podman::secret { $database_password_secret_name:
    ensure => $ensure,
    secret => Sensitive($database_password),
  }

  podman::secret { $database_name_secret_name:
    ensure => $ensure,
    secret => Sensitive($database_name),
  }

  podman::secret { $database_host_secret_name:
    ensure => $ensure,
    secret => Sensitive($database_host),
  }

  podman::secret { $database_port_secret_name:
    ensure => $ensure,
    secret => Sensitive(String($database_port)),
  }

  Postgresql_psql {
    cwd => '/',
  }

  include postgresql::client, postgresql::server

  postgresql::server::db { $database_name:
    user     => $database_user,
    password => postgresql::postgresql_password($database_user, $database_password),
    owner    => $database_user,
    encoding => 'utf8',
    locale   => 'en_US.utf8',
  }

  postgresql_psql { "create_extensions_${database_name}":
    db      => $database_name,
    command => 'CREATE EXTENSION IF NOT EXISTS dblink; CREATE EXTENSION IF NOT EXISTS pgcrypto;',
    unless  => "SELECT 1 FROM pg_extension WHERE extname = 'dblink'",
    require => Postgresql::Server::Db[$database_name],
  }

  iop::postgresql_fdw { 'compliance':
    database_name        => $database_name,
    database_user        => $database_user,
    database_password    => $database_password,
    remote_database_name => $iop::core_host_inventory::database_name,
    remote_user          => $iop::core_host_inventory::database_user,
    remote_password      => $iop::core_host_inventory::database_password,
    expected_columns     => $iop::core_host_inventory::remote_view_expected_columns,
    require              => [
      Postgresql::Server::Db[$database_name],
      Postgresql::Server::Schema['inventory'],
      Postgresql_psql['create_or_replace_remote_view_inventory_hosts'],
    ],
  }

  $common_secrets = [
    "${database_username_secret_name},type=env,target=POSTGRESQL_USER",
    "${database_password_secret_name},type=env,target=POSTGRESQL_PASSWORD",
    "${database_name_secret_name},type=env,target=POSTGRESQL_DATABASE",
    "${database_host_secret_name},type=env,target=POSTGRESQL_HOST",
    "${database_port_secret_name},type=env,target=POSTGRESQL_PORT",
  ]

  $common_env = [
    'RAILS_ENV=production',
    'SECRET_KEY_BASE=foreman-iop-dev-secret-key-base-not-for-production-use',
    'KAFKA_BROKERS=iop-core-kafka:9092',
    'KAFKA_SECURITY_PROTOCOL=plaintext',
    'DISABLE_RBAC=true',
    'HOST_INVENTORY_URL=http://iop-core-host-inventory-api:8081',
    "COMPLIANCE_SSG_URL=http://${service_name}-ssg:8088",
    'RAILS_LOG_TO_STDOUT=true',
  ]

  podman::quadlet { "${service_name}-ssg":
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    settings     => {
      'Unit'      => {
        'Description' => 'Compliance SSG Datastream Server',
      },
      'Container' => {
        'Image'         => $ssg_image,
        'ContainerName' => "${service_name}-ssg",
        'Network'       => 'iop-core-network',
        'Environment'   => [
          'NGINX_PORT=8088',
        ],
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Restart'     => 'on-failure',
      },
      'Install'   => { 'WantedBy' => 'default.target' },
    },
  }

  podman::quadlet { "${service_name}-migrate":
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    defaults     => {},
    require      => [
      Postgresql::Server::Db[$database_name],
    ],
    subscribe    => [
      Podman::Secret[$database_username_secret_name],
      Podman::Secret[$database_password_secret_name],
      Podman::Secret[$database_name_secret_name],
      Podman::Secret[$database_host_secret_name],
      Podman::Secret[$database_port_secret_name],
    ],
    settings     => {
      'Unit'      => {
        'Description' => 'Compliance Backend DB Migration',
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => "${service_name}-migrate",
        'Network'       => 'iop-core-network',
        'Exec'          => 'sh -c "bundle exec rake db:migrate --trace"',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env,
        'Secret'        => $common_secrets,
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Type'        => 'oneshot',
        'RemainAfterExit' => 'true',
      },
      'Install'   => { 'WantedBy' => 'default.target' },
    },
  }

  podman::quadlet { "${service_name}-import-ssg":
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    defaults     => {},
    require      => [
      Podman::Quadlet["${service_name}-migrate"],
      Podman::Quadlet["${service_name}-ssg"],
    ],
    subscribe    => [
      Podman::Secret[$database_username_secret_name],
      Podman::Secret[$database_password_secret_name],
      Podman::Secret[$database_name_secret_name],
      Podman::Secret[$database_host_secret_name],
      Podman::Secret[$database_port_secret_name],
    ],
    settings     => {
      'Unit'      => {
        'Description' => 'Compliance SSG Import',
        'Wants'       => ["${service_name}-migrate.service", "${service_name}-ssg.service"],
        'After'       => ["${service_name}-migrate.service", "${service_name}-ssg.service"],
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => "${service_name}-import-ssg",
        'Network'       => 'iop-core-network',
        'Exec'          => 'sh -c "bundle exec rake ssg:import_rhel_supported --trace"',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env + ['APPLICATION_TYPE=compliance-import-ssg'],
        'Secret'        => $common_secrets,
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Type'        => 'oneshot',
        'RemainAfterExit' => 'true',
      },
      'Install'   => { 'WantedBy' => 'default.target' },
    },
  }

  podman::quadlet { "${service_name}-api":
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    require      => [
      Postgresql::Server::Db[$database_name],
      Podman::Quadlet["${service_name}-migrate"],
    ],
    subscribe    => [
      Podman::Secret[$database_username_secret_name],
      Podman::Secret[$database_password_secret_name],
      Podman::Secret[$database_name_secret_name],
      Podman::Secret[$database_host_secret_name],
      Podman::Secret[$database_port_secret_name],
    ],
    settings     => {
      'Unit'      => {
        'Description' => 'Compliance Backend API',
        'Wants'       => ["${service_name}-migrate.service", 'iop-core-host-inventory-api.service'],
        'After'       => ["${service_name}-migrate.service", 'iop-core-host-inventory-api.service'],
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => "${service_name}-api",
        'Network'       => 'iop-core-network',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env + ['APPLICATION_TYPE=compliance-backend'],
        'Secret'        => $common_secrets,
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Restart'     => 'on-failure',
      },
      'Install'   => { 'WantedBy' => 'default.target' },
    },
  }

  podman::quadlet { "${service_name}-consumer":
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    require      => [
      Postgresql::Server::Db[$database_name],
      Podman::Quadlet["${service_name}-migrate"],
    ],
    subscribe    => [
      Podman::Secret[$database_username_secret_name],
      Podman::Secret[$database_password_secret_name],
      Podman::Secret[$database_name_secret_name],
      Podman::Secret[$database_host_secret_name],
      Podman::Secret[$database_port_secret_name],
    ],
    settings     => {
      'Unit'      => {
        'Description' => 'Compliance Inventory Consumer',
        'Wants'       => ["${service_name}-migrate.service"],
        'After'       => ["${service_name}-migrate.service"],
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => "${service_name}-consumer",
        'Network'       => 'iop-core-network',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env + ['APPLICATION_TYPE=compliance-inventory'],
        'Secret'        => $common_secrets,
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Restart'     => 'on-failure',
      },
      'Install'   => { 'WantedBy' => 'default.target' },
    },
  }

  podman::quadlet { "${service_name}-sidekiq":
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    require      => [
      Postgresql::Server::Db[$database_name],
      Podman::Quadlet["${service_name}-migrate"],
    ],
    subscribe    => [
      Podman::Secret[$database_username_secret_name],
      Podman::Secret[$database_password_secret_name],
      Podman::Secret[$database_name_secret_name],
      Podman::Secret[$database_host_secret_name],
      Podman::Secret[$database_port_secret_name],
    ],
    settings     => {
      'Unit'      => {
        'Description' => 'Compliance Sidekiq Worker',
        'Wants'       => ["${service_name}-migrate.service"],
        'After'       => ["${service_name}-migrate.service"],
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => "${service_name}-sidekiq",
        'Network'       => 'iop-core-network',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env + [
          'APPLICATION_TYPE=compliance-sidekiq',
          'SIDEKIQ_CONCURRENCY=2',
        ],
        'Secret'        => $common_secrets,
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Restart'     => 'on-failure',
      },
      'Install'   => { 'WantedBy' => 'default.target' },
    },
  }
}
