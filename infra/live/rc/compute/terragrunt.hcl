include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules//compute"
}

dependency "network" {
  config_path = "../../prod/network"

  mock_outputs = {
    subnet_ids = { app = "ocid1.subnet.oc1..mock" }
    nsg_ids    = { app = "ocid1.networksecuritygroup.oc1..mock" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "platform" {
  config_path = "../../prod/platform"

  mock_outputs                            = { ssh_public_keys = { app = "ssh-rsa MOCK" } }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "identity" {
  config_path = "../../prod/identity"

  mock_outputs = {
    role_defined_tags = { app = { "pscloud.role" = "app" } }
    tag_keys          = { environment = "pscloud.environment", cost_center = "pscloud.cost_center" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  tenancy_id = local.env.tenancy_id

  name = "${local.env.prefix}-app"

  instances = {
    "01" = { fault_domain = "FAULT-DOMAIN-3" }
  }

  shape         = "VM.Standard.E4.Flex"
  ocpus         = 1
  memory_in_gbs = 6

  subnet_id = dependency.network.outputs.subnet_ids.app
  nsg_ids   = [dependency.network.outputs.nsg_ids.app]

  ssh_public_key = dependency.platform.outputs.ssh_public_keys.app

  defined_tags = merge(
    dependency.identity.outputs.role_defined_tags.app,
    {
      (dependency.identity.outputs.tag_keys.environment) = local.env.env_name
      (dependency.identity.outputs.tag_keys.cost_center) = local.env.tags.CostCenter
    },
  )

  freeform_tags = merge(local.env.tags, { Component = "app", Role = "app" })
}
