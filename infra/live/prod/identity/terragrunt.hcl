include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules//identity"
}

inputs = {
  tenancy_id = local.env.tenancy_id

  label_prefix          = local.env.prefix
  artifacts_bucket_name = "${local.env.prefix}-releases"

  roles = {
    app        = { capabilities = ["manage_secrets"] }
    monitoring = { capabilities = ["manage_secrets", "read_inventory", "read_metrics", "artifacts_bucket", "manage_compute"] }
  }

  freeform_tags = { CostCenter = local.env.tags.CostCenter }
}
