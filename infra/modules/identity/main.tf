resource "oci_identity_tag_namespace" "this" {
  compartment_id = var.compartment_id
  name           = var.label_prefix
  description    = "Resource taxonomy for the ${var.label_prefix} environment"
  is_retired     = false
}

locals {
  tag_keys = {
    role = {
      description      = "Operational role. Feeds the IAM dynamic groups and the Ansible inventory."
      values           = keys(var.roles)
      is_cost_tracking = false
    }
    tier = {
      description      = "Architecture tier."
      values           = var.tiers
      is_cost_tracking = false
    }
    environment = {
      description      = "Environment."
      values           = var.environments
      is_cost_tracking = true
    }
    data_classification = {
      description      = "Sensitivity of the data at rest on the resource."
      values           = ["public", "internal", "confidential", "restricted"]
      is_cost_tracking = false
    }
    backup = {
      description      = "Expected backup policy. Auditable: a resource tagged backup=required with no assignment is a compliance finding."
      values           = ["none", "bronze", "silver", "gold"]
      is_cost_tracking = false
    }
    cost_center = {
      description      = "Cost center for chargeback."
      values           = null
      is_cost_tracking = true
    }
    owner = {
      description      = "Team that gets woken up at 3am."
      values           = null
      is_cost_tracking = false
    }
  }
}

resource "oci_identity_tag" "this" {
  for_each = local.tag_keys

  tag_namespace_id = oci_identity_tag_namespace.this.id
  name             = each.key
  description      = each.value.description
  is_cost_tracking = each.value.is_cost_tracking

  dynamic "validator" {
    for_each = each.value.values == null ? [] : [1]
    content {
      validator_type = "ENUM"
      values         = each.value.values
    }
  }
}

resource "oci_identity_dynamic_group" "role" {
  for_each = var.roles

  compartment_id = var.tenancy_id
  name           = "${var.label_prefix}-dg-${each.key}"
  description    = "Instances tagged ${var.label_prefix}.role = ${each.key}"
  matching_rule  = "ALL {instance.compartment.id = '${var.compartment_id}', tag.${var.label_prefix}.role.value = '${each.key}'}"

  depends_on = [oci_identity_tag.this]
}

locals {
  dg = { for k, v in oci_identity_dynamic_group.role : k => v.name }
  c  = var.compartment_id

  capability_statements = {
    read_secrets = [
      "to read secret-bundles in compartment id ${local.c}",
    ]

    manage_secrets = [
      "to manage secret-family in compartment id ${local.c}",
      "to read secret-bundles in compartment id ${local.c}",
      "to use keys in compartment id ${local.c}",
      "to use vaults in compartment id ${local.c}",
    ]

    read_inventory = [
      "to inspect compartments in compartment id ${local.c}",
      "to read instance-family in compartment id ${local.c}",
      "to read virtual-network-family in compartment id ${local.c}",
    ]

    read_metrics = [
      "to read metrics in compartment id ${local.c}",
    ]

    artifacts_bucket = [
      "to manage objects in compartment id ${local.c} where target.bucket.name = '${var.artifacts_bucket_name}'",
      "to read buckets in compartment id ${local.c}",
    ]

    manage_compute = [
      "to manage instance-family in compartment id ${local.c}",
      "to manage load-balancers in compartment id ${local.c}",
    ]
  }

  role_statements = {
    for name, r in var.roles : name => concat(
      flatten([for cap in r.capabilities : [
        for st in local.capability_statements[cap] :
        "Allow dynamic-group ${local.dg[name]} ${st}"
      ]]),
      r.statements,
    )
  }
}

resource "oci_identity_policy" "role" {
  for_each = { for k, v in local.role_statements : k => v if length(v) > 0 }

  compartment_id = var.compartment_id
  name           = "${var.label_prefix}-policy-${each.key}"
  description    = "Instance principal permissions for the ${each.key} role"
  statements     = each.value

  freeform_tags = var.freeform_tags
}
