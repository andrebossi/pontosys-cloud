output "vcn_id" { value = local.vcn_id }

output "subnet_ids" {
  value = { for key, subnet in oci_core_subnet.this : key => subnet.id }
}

output "route_table_ids" {
  value = { for key, table in oci_core_route_table.this : key => table.id }
}

output "nsg_ids" { value = local.nsg_id }

output "internet_gateway_id" { value = one(oci_core_internet_gateway.this[*].id) }
output "nat_gateway_id" { value = one(oci_core_nat_gateway.this[*].id) }
output "service_gateway_id" { value = one(oci_core_service_gateway.this[*].id) }
output "services_cidr" { value = local.services_cidr }
output "local_peering_gateway_id" { value = one(oci_core_local_peering_gateway.this[*].id) }
