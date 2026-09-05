resource "oci_core_vcn" "this" {
  count = var.vcn_id == null ? 1 : 0

  compartment_id = var.compartment_id
  cidr_blocks    = var.vcn_cidrs
  display_name   = var.name
  dns_label      = var.dns_label
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags
}

data "oci_core_vcn" "this" {
  count = var.vcn_id == null ? 0 : 1

  vcn_id = var.vcn_id
}

locals {
  vcn_id = var.vcn_id != null ? var.vcn_id : one(oci_core_vcn.this[*].id)
}

resource "oci_core_internet_gateway" "this" {
  count = var.create_internet_gateway ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "${var.name}-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags
}

resource "oci_core_nat_gateway" "this" {
  count = var.create_nat_gateway ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "${var.name}-natgw"
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags
}

data "oci_core_services" "this" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "this" {
  count = var.create_service_gateway ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "${var.name}-sgw"
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags

  services {
    service_id = data.oci_core_services.this.services[0].id
  }
}

resource "oci_core_local_peering_gateway" "this" {
  count = var.create_local_peering_gateway ? 1 : 0

  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "${var.name}-lpg"
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags
}

locals {
  gateway_id = {
    internet_gateway = coalesce(var.internet_gateway_id, one(oci_core_internet_gateway.this[*].id), "unset")
    nat_gateway      = coalesce(var.nat_gateway_id, one(oci_core_nat_gateway.this[*].id), "unset")
    service_gateway  = coalesce(var.service_gateway_id, one(oci_core_service_gateway.this[*].id), "unset")
    local_peering    = coalesce(var.local_peering_gateway_id, one(oci_core_local_peering_gateway.this[*].id), "unset")
    drg              = coalesce(var.drg_id, "unset")
  }

  services_cidr = data.oci_core_services.this.services[0].cidr_block

  route_rules = {
    for key, subnet in var.subnets : key => {
      for rule_key, rule in lookup(subnet, "route_rules", {}) : rule_key => {
        destination       = rule.destination == "all-services" ? local.services_cidr : rule.destination
        destination_type  = rule.destination == "all-services" ? "SERVICE_CIDR_BLOCK" : "CIDR_BLOCK"
        network_entity_id = lookup(local.gateway_id, rule.target, rule.target)
      }
    }
  }
}

resource "oci_core_route_table" "this" {
  for_each = var.subnets

  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "${var.name}-rt-${each.key}"
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags

  dynamic "route_rules" {
    for_each = local.route_rules[each.key]

    content {
      description       = route_rules.key
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = route_rules.value.network_entity_id
    }
  }
}

resource "oci_core_subnet" "this" {
  for_each = var.subnets

  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  cidr_block     = each.value.cidr_block
  display_name   = "${var.name}-sn-${each.key}"
  dns_label      = lookup(each.value, "dns_label", each.key)
  route_table_id = oci_core_route_table.this[each.key].id

  prohibit_public_ip_on_vnic = !lookup(each.value, "public", false)
  prohibit_internet_ingress  = !lookup(each.value, "public", false)

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags
}

resource "oci_core_network_security_group" "this" {
  for_each = toset(var.nsgs)

  compartment_id = var.compartment_id
  vcn_id         = local.vcn_id
  display_name   = "${var.name}-nsg-${each.key}"
  freeform_tags  = var.freeform_tags
  defined_tags   = var.defined_tags
}

locals {
  nsg_id = { for key, nsg in oci_core_network_security_group.this : key => nsg.id }

  nsg_rules = merge([
    for key, rule in var.nsg_rules : {
      for pair in setproduct(rule.remotes, lookup(rule, "ports", [0])) :
      "${key}|${pair[0]}|${pair[1]}" => {
        nsg       = rule.nsg
        direction = lookup(rule, "direction", "INGRESS")
        protocol  = lookup(rule, "protocol", "6")
        remote    = pair[0]
        port      = pair[1]
        icmp      = lookup(rule, "icmp", null)
      }
    }
  ]...)
}

resource "oci_core_network_security_group_security_rule" "this" {
  for_each = local.nsg_rules

  network_security_group_id = local.nsg_id[each.value.nsg]
  description               = each.key
  direction                 = each.value.direction
  protocol                  = each.value.protocol

  source      = each.value.direction == "INGRESS" ? lookup(local.nsg_id, each.value.remote, each.value.remote) : null
  source_type = each.value.direction == "INGRESS" ? (contains(keys(local.nsg_id), each.value.remote) ? "NETWORK_SECURITY_GROUP" : "CIDR_BLOCK") : null

  destination      = each.value.direction == "EGRESS" ? lookup(local.nsg_id, each.value.remote, each.value.remote) : null
  destination_type = each.value.direction == "EGRESS" ? (contains(keys(local.nsg_id), each.value.remote) ? "NETWORK_SECURITY_GROUP" : "CIDR_BLOCK") : null

  dynamic "tcp_options" {
    for_each = each.value.protocol == "6" && each.value.port > 0 ? [each.value.port] : []

    content {
      destination_port_range {
        min = tcp_options.value
        max = tcp_options.value
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "17" && each.value.port > 0 ? [each.value.port] : []

    content {
      destination_port_range {
        min = udp_options.value
        max = udp_options.value
      }
    }
  }

  dynamic "icmp_options" {
    for_each = each.value.icmp == null ? [] : [each.value.icmp]

    content {
      type = icmp_options.value.type
      code = lookup(icmp_options.value, "code", null)
    }
  }
}
