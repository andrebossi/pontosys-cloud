module "vcn" {
  source  = "oracle-terraform-modules/vcn/oci"
  version = "4.0.0"

  compartment_id = var.compartment_id
  tenancy_id     = var.tenancy_id
  label_prefix   = var.label_prefix
  vcn_name       = "vcn"
  vcn_dns_label  = "vcn"
  vcn_cidrs      = [var.vcn_cidr]

  create_internet_gateway = true
  create_nat_gateway      = true
  create_service_gateway  = true

  lockdown_default_seclist = true

  subnets = {
    public = {
      name       = "${var.label_prefix}-sn-public"
      cidr_block = var.subnet_cidrs.public
      type       = "public"
      dns_label  = "public"
    }
    private_app = {
      name       = "${var.label_prefix}-sn-private-app"
      cidr_block = var.subnet_cidrs.private_app
      type       = "private"
      dns_label  = "app"
    }
    private_db = {
      name       = "${var.label_prefix}-sn-private-db"
      cidr_block = var.subnet_cidrs.private_db
      type       = "private"
      dns_label  = "db"
    }
  }

  freeform_tags = var.freeform_tags
}

locals {
  subnets = module.vcn.subnet_id

  nsgs = {
    lb         = "${var.label_prefix}-nsg-lb"
    nlb        = "${var.label_prefix}-nsg-nlb"
    app        = "${var.label_prefix}-nsg-app"
    db         = "${var.label_prefix}-nsg-db"
    monitoring = "${var.label_prefix}-nsg-monitoring"
  }
}

resource "oci_core_network_security_group" "this" {
  for_each = local.nsgs

  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id
  display_name   = each.value
  freeform_tags  = var.freeform_tags
}

locals {
  nsg_id = { for k, v in oci_core_network_security_group.this : k => v.id }
}

resource "oci_core_network_security_group_security_rule" "lb_ingress" {
  for_each = {
    for pair in setproduct(var.lb_ingress_cidrs, [80, 443]) :
    "${pair[0]}-${pair[1]}" => { cidr = pair[0], port = pair[1] }
  }

  network_security_group_id = local.nsg_id.lb
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value.cidr
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_egress_app" {
  network_security_group_id = local.nsg_id.lb
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.nsg_id.app
  destination_type          = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = var.app_backend_port
      max = var.app_backend_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "app_ingress_lb" {
  network_security_group_id = local.nsg_id.app
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.nsg_id.lb
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = var.app_backend_port
      max = var.app_backend_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "app_ingress_ssh" {
  network_security_group_id = local.nsg_id.app
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.nsg_id.monitoring
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "app_egress_db" {
  network_security_group_id = local.nsg_id.app
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.nsg_id.db
  destination_type          = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = var.db_port
      max = var.db_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "app_egress_monitoring" {
  for_each = toset([for p in var.monitoring_ingest_ports : tostring(p)])

  network_security_group_id = local.nsg_id.app
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.nsg_id.monitoring
  destination_type          = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "app_egress_internet" {
  network_security_group_id = local.nsg_id.app
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# The database's external allowlist lives here. MySQL still has no public IP:
# the one with a public address is the Network Load Balancer, and only these
# /32s can reach it.
resource "oci_core_network_security_group_security_rule" "nlb_ingress_clients" {
  for_each = toset(var.db_client_cidrs)

  network_security_group_id = local.nsg_id.nlb
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = var.db_port
      max = var.db_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_egress_db" {
  network_security_group_id = local.nsg_id.nlb
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.nsg_id.db
  destination_type          = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = var.db_port
      max = var.db_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "db_ingress" {
  for_each = toset(["app", "monitoring", "nlb"])

  network_security_group_id = local.nsg_id.db
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.nsg_id[each.value]
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = var.db_port
      max = var.db_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mon_ingress_ssh" {
  for_each = toset(var.admin_cidrs)

  network_security_group_id = local.nsg_id.monitoring
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# Monitoring VM's nginx: 80 for certbot's HTTP-01 challenge and for the
# redirect, 443 for Grafana. No backend port is exposed here --
# VictoriaMetrics and VictoriaLogs only publish on 127.0.0.1 in the compose
# file, and ingestion comes in through the NSG-to-NSG rules below.
resource "oci_core_network_security_group_security_rule" "mon_ingress_http" {
  for_each = {
    for pair in setproduct(var.monitoring_http_cidrs, [80, 443]) :
    "${pair[0]}-${pair[1]}" => { cidr = pair[0], port = pair[1] }
  }

  network_security_group_id = local.nsg_id.monitoring
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value.cidr
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mon_ingress_agents" {
  for_each = toset([for p in var.monitoring_ingest_ports : tostring(p)])

  network_security_group_id = local.nsg_id.monitoring
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.nsg_id.app
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mon_egress" {
  network_security_group_id = local.nsg_id.monitoring
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "icmp_pmtu" {
  for_each = local.nsgs

  network_security_group_id = local.nsg_id[each.key]
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = var.vcn_cidr
  source_type               = "CIDR_BLOCK"
  icmp_options {
    type = 3
    code = 4
  }
}
