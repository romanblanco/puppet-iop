# == Class: iop::service_compliance
#
# Install and configure the Compliance Engine services
#
# === Parameters:
#
# $image::                     The Compliance service container image
#
# $ssg_image::                 The SCAP Security Guide (SSG) server container image
#
# $ensure::                    Ensure service is present or absent
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
  # TODO: Replace with quay.io/iop/compliance-backend:<tag> once RHINENG-24701 lands
  String[1] $image                    = 'quay.io/rblanco/compliance-backend:iop-devel',
  # TODO: Replace with quay.io/iop/compliance-ssg:<tag> once RHINENG-24701 lands
  String[1] $ssg_image                = 'quay.io/rblanco/compliance-ssg-upstream:latest',
  Enum['present', 'absent'] $ensure   = 'present',
  String[1] $database_name            = 'compliance_db',
  String[1] $database_user            = 'compliance_admin',
  String[1] $database_password        = $iop::params::compliance_database_password,
  String[1] $database_host            = '/var/run/postgresql',
  Stdlib::Port $database_port         = 5432,
) inherits iop::params {
  include podman
  include iop::database
  include iop::core_kafka
  include iop::core_network
  include iop::core_host_inventory

  $service_name = 'iop-service-compliance'
  $ssg_container_name = 'iop-service-compliance-backend-ssg'
  $ssg_port = 8088
  $host_inventory_url = "http://${iop::core_host_inventory::service_name}-api:${iop::core_host_inventory::api_port}"
  $ssg_url = "http://${ssg_container_name}:${ssg_port}"
  $database_username_secret_name = "${service_name}-database-username"
  $database_password_secret_name = "${service_name}-database-password"
  $database_name_secret_name = "${service_name}-database-name"
  $database_host_secret_name = "${service_name}-database-host"
  $database_port_secret_name = "${service_name}-database-port"

  $socket_volume = $database_host ? {
    /^\/var\/run\/postgresql/ => ['/var/run/postgresql:/var/run/postgresql:rw'],
    default                   => [],
  }

  $kafka_topics_env = [
    'KAFKA_TOPIC_INVENTORY_EVENTS=platform.inventory.events',
    'KAFKA_TOPIC_UPLOAD_COMPLIANCE=platform.upload.compliance',
    'KAFKA_TOPIC_PAYLOAD_STATUS=platform.payload-status',
    'KAFKA_TOPIC_NOTIFICATIONS_INGRESS=platform.notifications.ingress',
    'KAFKA_TOPIC_REMEDIATION_UPDATES=platform.remediation-updates.compliance',
    'KAFKA_TOPIC_INVENTORY_HOST_APPS=platform.inventory.host-apps',
  ]

  $common_secrets = [
    "${database_username_secret_name},type=env,target=POSTGRESQL_USER",
    "${database_password_secret_name},type=env,target=POSTGRESQL_PASSWORD",
    "${database_name_secret_name},type=env,target=POSTGRESQL_DATABASE",
    "${database_host_secret_name},type=env,target=POSTGRESQL_HOST",
    "${database_port_secret_name},type=env,target=POSTGRESQL_PORT",
  ]

  $common_env = [
    'DISABLE_RBAC=true',
    'RAILS_ENV=foreman',
    'RAILS_LOG_TO_STDOUT=true',
    'PATH_PREFIX=/api',
    'APP_NAME=compliance-backend',
    'SECRET_KEY_BASE=foreman-iop-dev-secret-key-base-not-for-production-use',
    'RUBY_YJIT_ENABLE=true',
    'SETTINGS__REPORT_DOWNLOAD_SSL_ONLY=false',
    'MAX_INIT_TIMEOUT_SECONDS=120',
    'KAFKA_BROKERS=iop-core-kafka:9092',
    'KAFKA_SECURITY_PROTOCOL=plaintext',
    "HOST_INVENTORY_URL=${host_inventory_url}",
    "COMPLIANCE_SSG_URL=${ssg_url}",
  ] + $kafka_topics_env

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

  # Prevents errors if run from /root etc.
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

  podman::quadlet { 'iop-service-compliance-backend-migrate':
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    require      => [
      Postgresql::Server::Db[$database_name],
      Iop::Postgresql_fdw['compliance'],
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
        'Description' => 'Compliance Database Upgrade Init Container',
      },
      'Service'   => {
        'Environment'     => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Type'            => 'oneshot',
        'RemainAfterExit' => 'true',
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-service-compliance-backend-migrate',
        'Network'       => 'iop-core-network',
        'Exec'          => 'sh -c "bundle exec rake db:migrate --trace"',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env + [
          'RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR=2.0',
        ],
        'Secret'        => $common_secrets,
      },
    },
  }

  podman::quadlet { 'iop-service-compliance-backend-api':
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    require      => [
      Postgresql::Server::Db[$database_name],
      Iop::Postgresql_fdw['compliance'],
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
        'Description' => 'Compliance Service',
        'Wants'       => ['iop-service-compliance-backend-migrate.service'],
        'After'       => ['iop-service-compliance-backend-migrate.service'],
        'Requires'    => ['iop-service-compliance-backend-migrate.service'],
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-service-compliance-backend-api',
        'Network'       => 'iop-core-network',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env + [
          'APPLICATION_TYPE=compliance-backend',
          'RAILS_LOGLEVEL=info',
          'PUMA_WORKERS=3',
          'PUMA_MIN_THREADS=1',
          'PUMA_MAX_THREADS=3',
          'MALLOC_ARENA_MAX=2',
          'OLD_PATH_PREFIX=/r/insights/platform',
          'RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR=1.2',
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

  podman::quadlet { 'iop-service-compliance-backend-ssg':
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    settings     => {
      'Unit'      => {
        'Description' => 'Compliance SSG Service',
      },
      'Container' => {
        'Image'         => $ssg_image,
        'ContainerName' => $ssg_container_name,
        'Network'       => 'iop-core-network',
        'Volume'        => $socket_volume,
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Restart'     => 'on-failure',
      },
      'Install'   => { 'WantedBy' => 'default.target' },
    },
  }

  podman::quadlet { 'iop-service-compliance-backend-consumer':
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    require      => [
      Postgresql::Server::Db[$database_name],
      Iop::Postgresql_fdw['compliance'],
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
        'Description' => 'Compliance Inventory Consumer Service',
        'Wants'       => ['iop-service-compliance-backend-migrate.service'],
        'After'       => ['iop-service-compliance-backend-migrate.service', 'iop-core-kafka.service'],
        'Requires'    => ['iop-service-compliance-backend-migrate.service'],
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-service-compliance-backend-consumer',
        'Network'       => 'iop-core-network',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env + [
          'APPLICATION_TYPE=compliance-inventory',
          'MALLOC_ARENA_MAX=2',
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

  podman::quadlet { 'iop-service-compliance-backend-import-ssg':
    ensure         => $ensure,
    quadlet_type   => 'container',
    user           => 'root',
    service_ensure => 'stopped',
    require        => [
      Postgresql::Server::Db[$database_name],
      Iop::Postgresql_fdw['compliance'],
    ],
    subscribe      => [
      Podman::Secret[$database_username_secret_name],
      Podman::Secret[$database_password_secret_name],
      Podman::Secret[$database_name_secret_name],
      Podman::Secret[$database_host_secret_name],
      Podman::Secret[$database_port_secret_name],
    ],
    settings       => {
      'Unit'      => {
        'Description' => 'Compliance Import SSG Job',
        'Wants'       => ['iop-service-compliance-backend-migrate.service'],
        'After'       => ['iop-service-compliance-backend-migrate.service'],
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-service-compliance-backend-import-ssg',
        'Network'       => 'iop-core-network',
        'Volume'        => $socket_volume,
        'Environment'   => $common_env + [
          'APPLICATION_TYPE=compliance-import-ssg',
        ],
        'Secret'        => $common_secrets,
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Type'        => 'oneshot',
      },
      'Install'   => {
        'WantedBy' => [],
      },
    },
  }

  $timer_ensure = $ensure ? { 'present' => true, default => false }

  systemd::timer { 'iop-service-compliance-backend-import-ssg.timer':
    ensure        => $ensure,
    enable        => $timer_ensure,
    active        => $timer_ensure,
    service_unit  => 'iop-service-compliance-backend-import-ssg.service',
    timer_content => file('iop/iop-service-compliance-backend-import-ssg.timer'),
    require       => Podman::Quadlet['iop-service-compliance-backend-import-ssg'],
  }
}
