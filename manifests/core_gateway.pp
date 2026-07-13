# == Class: iop::core_gateway
#
# Install and configure the core gateway
#
# === Parameters:
#
# $foreman_servername:: FQDN of the Foreman server
#
# $image::              The container image
#
# $ensure::             Ensure service is present or absent
#
class iop::core_gateway (
  Stdlib::Fqdn $foreman_servername = $facts['networking']['fqdn'],
  String[1] $image = 'quay.io/rblanco/iop-gateway:iop-devel',
  Enum['present', 'absent'] $ensure = 'present',
) {
  include podman
  include iop::core_network
  include certs::iop

  $service_name = 'iop-core-gateway'
  $relay_conf_secret_name = "${service_name}-relay-conf"

  $server_cert_secret_name = "${service_name}-server-cert"
  $server_key_secret_name = "${service_name}-server-key"
  $server_ca_cert_secret_name = "${service_name}-server-ca-cert"

  $client_cert_secret_name = "${service_name}-client-cert"
  $client_key_secret_name = "${service_name}-client-key"
  $client_ca_cert_secret_name = "${service_name}-client-ca-cert"

  podman::secret { $server_cert_secret_name:
    ensure => $ensure,
    path   => $certs::iop::server_cert,
  }

  podman::secret { $server_key_secret_name:
    ensure => $ensure,
    path   => $certs::iop::server_key,
  }

  podman::secret { $server_ca_cert_secret_name:
    ensure => $ensure,
    path   => $certs::iop::server_ca_cert,
  }

  podman::secret { $client_cert_secret_name:
    ensure => $ensure,
    path   => $certs::iop::client_cert,
  }

  podman::secret { $client_key_secret_name:
    ensure => $ensure,
    path   => $certs::iop::client_key,
  }

  podman::secret { $client_ca_cert_secret_name:
    ensure => $ensure,
    path   => $certs::iop::client_ca_cert,
  }

  podman::secret { $relay_conf_secret_name:
    ensure => $ensure,
    secret => Sensitive(
      epp('iop/gateway/relay.conf.epp', { 'foreman_servername' => $foreman_servername }),
    ),
  }

  podman::quadlet { 'iop-core-gateway':
    ensure       => $ensure,
    quadlet_type => 'container',
    user         => 'root',
    defaults     => {},
    subscribe    => [
      Podman::Secret[$server_cert_secret_name],
      Podman::Secret[$server_key_secret_name],
      Podman::Secret[$server_ca_cert_secret_name],
      Podman::Secret[$client_cert_secret_name],
      Podman::Secret[$client_key_secret_name],
      Podman::Secret[$client_ca_cert_secret_name],
      Podman::Secret[$relay_conf_secret_name],
    ],
    settings     => {
      'Unit'      => {
        'Description' => 'IOP Core Gateway Container',
      },
      'Container' => {
        'Image'         => $image,
        'ContainerName' => 'iop-core-gateway',
        'Network'       => 'iop-core-network',
        'PublishPort'   => [
          '127.0.0.1:24443:8443',
        ],
        'Secret'        => [
          "${server_cert_secret_name},target=/etc/nginx/certs/nginx.crt,mode=0440,type=mount,uid=998,gid=998",
          "${server_key_secret_name},target=/etc/nginx/certs/nginx.key,mode=0440,type=mount,uid=998,gid=998",
          "${server_ca_cert_secret_name},target=/etc/nginx/certs/ca.crt,mode=0440,type=mount,uid=998,gid=998",
          "${client_cert_secret_name},target=/etc/nginx/smart-proxy-relay/certs/proxy.crt,mode=0440,type=mount,uid=998,gid=998",
          "${client_key_secret_name},target=/etc/nginx/smart-proxy-relay/certs/proxy.key,mode=0440,type=mount,uid=998,gid=998",
          "${client_ca_cert_secret_name},target=/etc/nginx/smart-proxy-relay/certs/ca.crt,mode=0440,type=mount,uid=998,gid=998",
          "${relay_conf_secret_name},target=/etc/nginx/smart-proxy-relay/relay.conf,mode=0440,type=mount,uid=998,gid=998",
        ],
      },
      'Service'   => {
        'Environment' => 'REGISTRY_AUTH_FILE=/etc/foreman/registry-auth.json',
        'Restart'     => 'on-failure',
      },
      'Install'   => {
        'WantedBy' => [
          'multi-user.target',
          'default.target',
        ],
      },
    },
  }
}
