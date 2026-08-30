# ---------------------------------------------------------------------------
# BOOTSTRAP -- runs ONCE, with local state, before any terragrunt.
#
# Creates the bucket that will hold the state for all stacks. This
# directory's local state (terraform.tfstate) is disposable: if lost,
# `terraform import` of the bucket fixes it. What CANNOT be lost is the
# bucket's contents.
#
#   terraform -chdir=infra/bootstrap init
#   terraform -chdir=infra/bootstrap apply
#
# Then copy the outputs into infra/live/prod/env.hcl.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.12.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 8.14.0"
    }
  }
}

provider "oci" {
  region = var.home_region
}

variable "home_region" { type = string }
variable "compartment_id" { type = string }
variable "label_prefix" {
  type    = string
  default = "pscloud"
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_id
}

# Vault and key dedicated to the state. Deliberately separate from the
# application's vault: whoever operates Terraform and whoever operates the
# application don't need the same key, and rotating one doesn't affect the
# other.
resource "oci_kms_vault" "state" {
  compartment_id = var.compartment_id
  display_name   = "${var.label_prefix}-state-vault"
  vault_type     = "DEFAULT"
}

resource "oci_kms_key" "state" {
  compartment_id      = var.compartment_id
  display_name        = "${var.label_prefix}-state-key"
  management_endpoint = oci_kms_vault.state.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

resource "oci_objectstorage_bucket" "state" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.label_prefix}-tfstate"

  access_type = "NoPublicAccess"
  kms_key_id  = oci_kms_key.state.id

  # Mandatory, not optional: the state carries the private SSH key and
  # database password in plaintext. Versioning is what allows recovering from
  # an apply that corrupted or truncated the state.
  versioning = "Enabled"
}

output "objectstorage_namespace" { value = data.oci_objectstorage_namespace.this.namespace }
output "state_bucket" { value = oci_objectstorage_bucket.state.name }
output "state_kms_key_id" { value = oci_kms_key.state.id }
