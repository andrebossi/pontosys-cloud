data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_id
}

locals {
  availability_domain = coalesce(
    var.availability_domain,
    data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name,
  )
  nlb_count = var.expose_via_nlb ? 1 : 0
}

resource "oci_mysql_mysql_db_system" "this" {
  compartment_id      = var.compartment_id
  display_name        = "${var.label_prefix}-mysql"
  availability_domain = local.availability_domain
  fault_domain        = var.fault_domain
  shape_name          = var.shape_name
  mysql_version       = var.mysql_version

  subnet_id      = var.db_subnet_id
  hostname_label = replace("${var.label_prefix}mysql", "-", "")
  port           = var.db_port

  data_storage_size_in_gb = var.data_storage_size_in_gb
  is_highly_available     = var.is_highly_available

  admin_username = var.admin_username
  admin_password = var.admin_password

  backup_policy {
    is_enabled        = true
    retention_in_days = var.backup.retention_in_days
    window_start_time = var.backup.window_start_time

    pitr_policy {
      is_enabled = var.backup.pitr_enabled
    }
  }

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags

  lifecycle {
    ignore_changes = [admin_password, defined_tags]
  }
}

resource "oci_network_load_balancer_network_load_balancer" "this" {
  count = local.nlb_count

  compartment_id                 = var.compartment_id
  display_name                   = "${var.label_prefix}-nlb-mysql"
  subnet_id                      = var.nlb_subnet_id
  network_security_group_ids     = var.nlb_nsg_ids
  is_private                     = false
  is_preserve_source_destination = false

  freeform_tags = var.freeform_tags
}

resource "oci_network_load_balancer_backend_set" "mysql" {
  count = local.nlb_count

  name                     = "mysql"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.this[0].id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false

  health_checker {
    protocol = "TCP"
    port     = var.db_port
  }
}

resource "oci_network_load_balancer_backend" "mysql" {
  count = local.nlb_count

  name                     = "mysql-primary"
  backend_set_name         = oci_network_load_balancer_backend_set.mysql[0].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.this[0].id
  ip_address               = oci_mysql_mysql_db_system.this.ip_address
  port                     = var.db_port
}

resource "oci_network_load_balancer_listener" "mysql" {
  count = local.nlb_count

  name                     = "mysql"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.this[0].id
  default_backend_set_name = oci_network_load_balancer_backend_set.mysql[0].name
  port                     = var.db_port
  protocol                 = "TCP"
}
