include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules//loadbalancer"
}

dependency "network" {
  config_path = "../../prod/network"

  mock_outputs = {
    subnet_ids = { public = "ocid1.subnet.oc1..mock" }
    nsg_ids    = { lb = "ocid1.networksecuritygroup.oc1..mock" }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "compute" {
  config_path = "../compute"

  mock_outputs                            = { private_ips = { "01" = "10.20.16.20" } }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  name = "${local.env.prefix}-lb"

  subnet_id = dependency.network.outputs.subnet_ids.public
  nsg_ids   = [dependency.network.outputs.nsg_ids.lb]

  backend_port = local.env.app_port
  backends     = dependency.compute.outputs.private_ips

  health_check = { url_path = "/healthz" }

  listeners = {
    http = { port = 80 }
  }

  freeform_tags = { CostCenter = local.env.tags.CostCenter }
}
