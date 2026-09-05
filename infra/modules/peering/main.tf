resource "oci_core_local_peering_gateway" "peer" {
  compartment_id = var.compartment_id
  vcn_id         = var.peer_vcn_id
  display_name   = var.name
  peer_id        = var.local_peering_gateway_id
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags
}

resource "oci_core_route_table" "peer" {
  count = length(var.peer_route_rules) > 0 ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = var.peer_vcn_id
  display_name   = "${var.name}-rt"
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags

  dynamic "route_rules" {
    for_each = var.peer_route_rules

    content {
      description       = route_rules.key
      destination       = route_rules.value.destination
      destination_type  = lookup(route_rules.value, "destination_type", "CIDR_BLOCK")
      network_entity_id = lookup(route_rules.value, "network_entity_id", oci_core_local_peering_gateway.peer.id)
    }
  }
}

resource "oci_core_route_table_attachment" "peer" {
  for_each = var.peer_subnet_ids

  subnet_id      = each.value
  route_table_id = oci_core_route_table.peer[0].id
}
