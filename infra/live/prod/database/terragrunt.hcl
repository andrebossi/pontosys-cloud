include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules//database"
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    subnet_ids = { db = "ocid1.subnet.oc1..mock", public = "ocid1.subnet.oc1..mock" }
    nsg_ids    = { db = "ocid1.networksecuritygroup.oc1..mock" }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "platform" {
  config_path = "../platform"

  mock_outputs = {
    db_admin_username = "pscloudadm"
    db_admin_password = "mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  tenancy_id = local.env.tenancy_id

  label_prefix = local.env.prefix

  shape_name              = "MySQL.2"
  data_storage_size_in_gb = 50
  is_highly_available     = false

  admin_username = dependency.platform.outputs.db_admin_username
  admin_password = dependency.platform.outputs.db_admin_password

  db_subnet_id  = dependency.network.outputs.subnet_ids.db
  nlb_subnet_id = dependency.network.outputs.subnet_ids.public
  nlb_nsg_ids   = [dependency.network.outputs.nsg_ids.db]
  db_port       = local.env.db_port
  expose_nlb    = false

  # Databases, users and grants are Ansible's: it is the only thing that runs
  # inside the VCN and can reach the DB system, so it is the only thing that
  # can create a credential and the account it belongs to together.
  manage_databases = false
  db_host          = local.env.db_fqdn

  backup = {
    retention_in_days = 7
    window_start_time = "04:00-00:00"
    pitr_enabled      = true
  }

  freeform_tags = merge(local.env.tags, { Component = "database" })
}
