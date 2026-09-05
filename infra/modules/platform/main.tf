resource "oci_kms_vault" "this" {
  compartment_id = var.compartment_id
  display_name   = "${var.label_prefix}-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = var.freeform_tags
}

resource "oci_kms_key" "this" {
  compartment_id      = var.compartment_id
  display_name        = "${var.label_prefix}-key"
  management_endpoint = oci_kms_vault.this.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  freeform_tags = var.freeform_tags
}

resource "tls_private_key" "ssh" {
  for_each = toset(var.ssh_key_roles)

  algorithm = var.ssh_key_algorithm
  rsa_bits  = var.ssh_key_algorithm == "RSA" ? 4096 : null
}

resource "oci_vault_secret" "ssh_private_key" {
  for_each = tls_private_key.ssh

  compartment_id = var.compartment_id
  vault_id       = oci_kms_vault.this.id
  key_id         = oci_kms_key.this.id
  secret_name    = "${var.label_prefix}-ssh-${each.key}"
  description    = "Private SSH key for role ${each.key}"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(each.value.private_key_openssh)
  }

  freeform_tags = var.freeform_tags
}

resource "random_password" "db_admin" {
  length           = 28
  special          = true
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#%*+-=?_"
}

resource "oci_vault_secret" "db_admin" {
  compartment_id = var.compartment_id
  vault_id       = oci_kms_vault.this.id
  key_id         = oci_kms_key.this.id
  secret_name    = "${var.label_prefix}-mysql-admin"
  description    = "MySQL HeatWave administrative credential"

  secret_content {
    content_type = "BASE64"
    content = base64encode(jsonencode({
      username = var.db_admin_username
      password = random_password.db_admin.result
      host     = var.db_private_ip
      port     = 3306
    }))
  }

  freeform_tags = var.freeform_tags
}

resource "random_password" "app_db" {
  for_each = var.applications

  length           = 28
  special          = true
  override_special = "!#%*+-=?_"
}

resource "oci_vault_secret" "app_db" {
  for_each = var.applications

  compartment_id = var.compartment_id
  vault_id       = oci_kms_vault.this.id
  key_id         = oci_kms_key.this.id
  secret_name    = "${var.label_prefix}-db-${each.key}"
  description    = "MariaDB credential for application ${each.key}"

  secret_content {
    content_type = "BASE64"
    content = base64encode(jsonencode({
      host     = var.db_private_ip
      port     = 3306
      database = each.value.db_name
      username = each.value.db_user
      password = random_password.app_db[each.key].result
      grants   = each.value.grants
      host_acl = each.value.db_host
    }))
  }

  freeform_tags = var.freeform_tags
}

resource "oci_bastion_bastion" "this" {
  count = var.bastion_target_subnet_id == "" ? 0 : 1

  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_id
  target_subnet_id             = var.bastion_target_subnet_id
  name                         = replace("${var.label_prefix}bastion", "-", "")
  client_cidr_block_allow_list = var.admin_cidrs

  freeform_tags = var.freeform_tags
}
data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_id
}

resource "oci_objectstorage_bucket" "backups" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.label_prefix}-artifacts"

  access_type   = "NoPublicAccess"
  storage_tier  = "Standard"
  kms_key_id    = oci_kms_key.this.id
  freeform_tags = var.freeform_tags

  versioning = "Enabled"

  object_events_enabled = true

  dynamic "retention_rules" {
    for_each = var.immutable_retention_days > 0 ? [1] : []
    content {
      display_name = "worm-${var.immutable_retention_days}d"
      duration {
        time_amount = var.immutable_retention_days
        time_unit   = "DAYS"
      }
    }
  }
}

resource "oci_objectstorage_object_lifecycle_policy" "backups" {
  bucket    = oci_objectstorage_bucket.backups.name
  namespace = data.oci_objectstorage_namespace.this.namespace

  rules {
    name        = "archive-old"
    action      = "ARCHIVE"
    time_amount = var.backup_retention.archive_after_days
    time_unit   = "DAYS"
    is_enabled  = true
    target      = "objects"
  }
}
