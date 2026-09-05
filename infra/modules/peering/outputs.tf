output "peer_peering_gateway_id" { value = oci_core_local_peering_gateway.peer.id }
output "peer_route_table_id" { value = one(oci_core_route_table.peer[*].id) }
