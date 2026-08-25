# == Class: iop::service_compliance
#
# Compliance containers, database, and secrets are managed by foremanctl.
# See foremanctl src/roles/iop_compliance and src/roles/iop_compliance_frontend.
#
class iop::service_compliance (
  Enum['present', 'absent'] $ensure = 'present',
) inherits iop::params {
}
