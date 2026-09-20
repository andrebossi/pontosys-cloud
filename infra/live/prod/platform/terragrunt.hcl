include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules//platform"
}

dependency "network" {
  config_path = "../network"

  mock_outputs                            = { subnet_ids = { app = "ocid1.subnet.oc1..mock" } }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  label_prefix  = local.env.prefix
  ssh_key_roles = ["app", "db", "monitoring"]
  admin_cidrs   = local.env.admin_cidrs

  db_admin_username = "pscloudadm"
  db_private_ip     = local.env.db_fqdn

  bastion_target_subnet_id = dependency.network.outputs.subnet_ids.app

  freeform_tags = { CostCenter = local.env.tags.CostCenter }
}
