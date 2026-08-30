output "vcn_id" { value = module.vcn.vcn_id }

output "subnet_id_by_role" {
  value = {
    public      = local.subnets["${var.label_prefix}-sn-public"]
    private_app = local.subnets["${var.label_prefix}-sn-private-app"]
    private_db  = local.subnets["${var.label_prefix}-sn-private-db"]
  }
}

output "nsg_ids" { value = local.nsg_id }
output "nat_route_id" { value = module.vcn.nat_route_id }
output "ig_route_id" { value = module.vcn.ig_route_id }
