# == Class: iop::core_host_inventory
#
# Install and configure the core host-inventory
#
# === Parameters:
#
# $image::  The container image
#
# $ensure:: Ensure service is present or absent
#
# $database_user:: Username for the inventory database
#
# $database_name:: Name of the inventory database
#
# $database_password:: Password for the inventory database
#
# $database_host:: Host for the inventory database
#
# $database_port:: Port for the inventory database
#
class iop::core_host_inventory (
  String[1] $image = 'quay.io/iop/host-inventory:foreman-3.18',
  Enum['present', 'absent'] $ensure = 'present',
  String[1] $database_password = $iop::params::inventory_database_password,
  String[1] $database_user = 'inventory_user',
  String[1] $database_name = 'inventory_db',
  String[1] $database_host = '/var/run/postgresql/',
  Stdlib::Port $database_port = 5432,
) inherits iop::params {
  include podman
  include iop::core_network
  include iop::core_kafka
  include iop::database

  $service_name = 'iop-core-host-inventory'
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

  # Prevents errors if run from /root etc.
  Postgresql_psql {
    cwd => '/',
  }

  include postgresql::client, postgresql::server, postgresql::server::contrib

  postgresql::server::db { $database_name:
    user     => $database_user,
    password => postgresql::postgresql_password($database_user, $database_password),
    owner    => $database_user,
    encoding => 'utf8',
    locale   => 'en_US.utf8',
  }

  postgresql::server::extension { "${database_name}-fdw":
    ensure    => 'present',
    database  => $database_name,
    extension => 'postgres_fdw',
    require   => Postgresql::Server::Db[$database_name],
  }

  $psql_env = [
    "PGPASSWORD=${postgresql::postgresql_password($database_user, $database_password)}",
  ]

  postgresql::server::schema { 'inventory':
    db    => $database_name,
    owner => $database_user,
  }

  # TODO(RHINENG-26911): remove this view and the FDW define once Cyndi
  # decommission completes across all IoP services.
  #
  # Staleness intervals are hardcoded HBI defaults (29h, 7d, 30d).
  # Per-org custom staleness from hbi.staleness is not supported.
  $remote_view_expected_columns = "ARRAY['id','account','display_name','created','updated','stale_timestamp','stale_warning_timestamp','culled_timestamp','tags','system_profile','insights_id','reporter','per_reporter_staleness','org_id','groups','last_check_in']"

  $remote_view_command = @("EOM")
    CREATE OR REPLACE VIEW "inventory"."hosts" AS SELECT
      h.id,
      h.account,
      h.display_name,
      h.created_on as created,
      h.modified_on as updated,
      h.last_check_in + INTERVAL '29 hours' AS stale_timestamp,
      h.last_check_in + INTERVAL '7 days' AS stale_warning_timestamp,
      h.last_check_in + INTERVAL '30 days' AS culled_timestamp,
      h.tags_alt as tags,
      jsonb_build_object('operating_system', sps.operating_system, 'host_type', sps.host_type, 'owner_id', sps.owner_id) as system_profile,
      h.insights_id,
      h.reporter,
      h.per_reporter_staleness,
      h.org_id,
      h.groups,
      h.last_check_in
    FROM hbi.hosts h
    LEFT JOIN hbi.system_profiles_static sps ON sps.org_id = h.org_id AND sps.host_id = h.id
    WHERE h.insights_id != '00000000-0000-0000-0000-000000000000';
    | EOM

  postgresql_psql { 'create_or_replace_remote_view_inventory_hosts':
    db          => $database_name,
    command     => $remote_view_command,
    unless      => "SELECT 1 FROM (SELECT array_agg(column_name::text ORDER BY ordinal_position) AS cols FROM information_schema.columns WHERE table_schema = 'inventory' AND table_name = 'hosts') sub WHERE cols = ${remote_view_expected_columns}",
    environment => $psql_env,
    require     => [
      Postgresql::Server::Schema['inventory'],
      Podman::Quadlet['iop-core-host-inventory-migrate'],
    ],
  }

  podman::quadlet { 'iop-core-host-inventory-migrate':
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
        'Description' => 'Database Readiness and Migration Init Container',
      },
      'Service'   => {
        'Environment'     => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Type'            => 'oneshot',
        'RemainAfterExit' => 'true',
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-core-host-inventory-migrate',
        'Network'       => 'iop-core-network',
        'Exec'          => 'make upgrade_db',
        'Environment'   => [
          'KAFKA_BOOTSTRAP_SERVERS=PLAINTEXT://iop-core-kafka:9092',
          'USE_SUBMAN_ID=true',
        ],
        'Secret'        => [
          "${database_username_secret_name},type=env,target=INVENTORY_DB_USER",
          "${database_password_secret_name},type=env,target=INVENTORY_DB_PASS",
          "${database_name_secret_name},type=env,target=INVENTORY_DB_NAME",
          "${database_host_secret_name},type=env,target=INVENTORY_DB_HOST",
          "${database_port_secret_name},type=env,target=INVENTORY_DB_PORT",
        ],
        'Volume'        => $socket_volume,
      },
    },
  }

  podman::quadlet { 'iop-core-host-inventory':
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
        'Description' => 'IOP Core Host-Based Inventory Container',
        'After'       => ['network-online.target', 'iop-core-host-inventory-migrate.service'],
        'Requires'    => 'iop-core-host-inventory-migrate.service',
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-core-host-inventory',
        'Network'       => 'iop-core-network',
        'Exec'          => './inv_mq_service.py',
        'Environment'   => [
          'KAFKA_BOOTSTRAP_SERVERS=PLAINTEXT://iop-core-kafka:9092',
          'USE_SUBMAN_ID=true',
        ],
        'Volume'        => $socket_volume,
        'Secret'        => [
          "${database_username_secret_name},type=env,target=INVENTORY_DB_USER",
          "${database_password_secret_name},type=env,target=INVENTORY_DB_PASS",
          "${database_name_secret_name},type=env,target=INVENTORY_DB_NAME",
          "${database_host_secret_name},type=env,target=INVENTORY_DB_HOST",
          "${database_port_secret_name},type=env,target=INVENTORY_DB_PORT",
        ],
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Restart'     => 'on-failure',
      },
      'Install'   => {
        'WantedBy' => ['multi-user.target', 'default.target'],
      },
    },
  }

  podman::quadlet { 'iop-core-host-inventory-api':
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
        'Description' => 'IOP Core Host-Based Inventory Web Container',
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-core-host-inventory-api',
        'Network'       => 'iop-core-network',
        'Exec'          => 'python run_gunicorn.py',
        'Environment'   => [
          'KAFKA_BOOTSTRAP_SERVERS=iop-core-kafka:9092',
          'LISTEN_PORT=8081',
          'BYPASS_RBAC=true',
          'USE_SUBMAN_ID=true',
        ],
        'Volume'        => $socket_volume,
        'Secret'        => [
          "${database_username_secret_name},type=env,target=INVENTORY_DB_USER",
          "${database_password_secret_name},type=env,target=INVENTORY_DB_PASS",
          "${database_name_secret_name},type=env,target=INVENTORY_DB_NAME",
          "${database_host_secret_name},type=env,target=INVENTORY_DB_HOST",
          "${database_port_secret_name},type=env,target=INVENTORY_DB_PORT",
        ],
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Restart'     => 'on-failure',
      },
      'Install'   => {
        'WantedBy' => ['multi-user.target', 'default.target'],
      },
    },
  }

  podman::quadlet { 'iop-core-host-inventory-cleanup':
    ensure         => $ensure,
    quadlet_type   => 'container',
    user           => 'root',
    service_ensure => 'stopped',
    require        => [
      Postgresql::Server::Db[$database_name],
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
        'Description' => 'Host Inventory Access Tags Cleanup Job',
        'Wants'       => ['iop-core-host-inventory-api.service'],
        'After'       => ['iop-core-host-inventory-api.service'],
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-core-host-inventory-cleanup',
        'Network'       => 'iop-core-network',
        'Exec'          => 'make run_host_delete_access_tags',
        'Environment'   => [
          'KAFKA_BOOTSTRAP_SERVERS=PLAINTEXT://iop-core-kafka:9092',
          'USE_SUBMAN_ID=true',
          'PYTHONPATH=/opt/app-root/src',
        ],
        'Volume'        => $socket_volume,
        'Secret'        => [
          "${database_username_secret_name},type=env,target=INVENTORY_DB_USER",
          "${database_password_secret_name},type=env,target=INVENTORY_DB_PASS",
          "${database_name_secret_name},type=env,target=INVENTORY_DB_NAME",
          "${database_host_secret_name},type=env,target=INVENTORY_DB_HOST",
          "${database_port_secret_name},type=env,target=INVENTORY_DB_PORT",
        ],
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Type'        => 'oneshot',
        'Restart'     => 'on-failure',
      },
      'Install'   => {
        'WantedBy'        => [],
      },
    },
  }

  $cleanup_timer_ensure = $ensure ? { 'present' => true, default => false }

  systemd::timer { 'iop-core-host-inventory-cleanup.timer':
    ensure        => $ensure,
    enable        => $cleanup_timer_ensure,
    active        => $cleanup_timer_ensure,
    service_unit  => 'iop-core-host-inventory-cleanup.service',
    timer_content => file('iop/iop-core-host-inventory-cleanup.timer'),
    require       => Podman::Quadlet['iop-core-host-inventory-cleanup'],
  }
}
