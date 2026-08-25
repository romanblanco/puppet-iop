# @summary The IOP default parameters for shared credentials
# @api private
class iop::params {
  # Database passwords - centralized for cross-service access (FDW)
  $inventory_database_password = extlib::cache_data('iop_cache_data', 'host_inventory_db_password', extlib::random_password(32))
  $vulnerability_database_password = extlib::cache_data('iop_cache_data', 'vulnerability_db_password', extlib::random_password(32))
  $advisor_database_password = extlib::cache_data('iop_cache_data', 'advisor_db_password', extlib::random_password(32))
  $vmaas_database_password = extlib::cache_data('iop_cache_data', 'vmaas_db_password', extlib::random_password(32))
  $remediations_database_password = extlib::cache_data('iop_cache_data', 'remediations_db_password', extlib::random_password(32))
}
