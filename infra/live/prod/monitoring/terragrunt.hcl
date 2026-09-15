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
  config_path = "../network"

  mock_outputs = {
    subnet_ids = { app = "ocid1.subnet.oc1..mock" }
    nsg_ids    = { monitoring = "ocid1.networksecuritygroup.oc1..mock" }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "platform" {
  config_path = "../platform"

  mock_outputs                            = { ssh_public_keys = { monitoring = "ssh-rsa MOCK" } }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "identity" {
  config_path = "../identity"

  mock_outputs = {
    role_defined_tags = { monitoring = { "pscloud.role" = "monitoring" } }
    tag_keys          = { environment = "pscloud.environment", cost_center = "pscloud.cost_center" }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  tenancy_id = local.env.tenancy_id

  name = "${local.env.prefix}-monitoring"

  instances = {
    "01" = {}
  }

  shape         = "VM.Standard.A1.Flex"
  ocpus         = 1
  memory_in_gbs = 8

  image_id = null

  subnet_id = dependency.network.outputs.subnet_ids.app
  nsg_ids   = [dependency.network.outputs.nsg_ids.monitoring]

  ssh_public_key = dependency.platform.outputs.ssh_public_keys.monitoring

  defined_tags = merge(
    dependency.identity.outputs.role_defined_tags.monitoring,
    {
      (dependency.identity.outputs.tag_keys.environment) = local.env.env_name
      (dependency.identity.outputs.tag_keys.cost_center) = local.env.tags.CostCenter
    },
  )

  freeform_tags = merge(local.env.tags, { Component = "monitoring", Role = "monitoring" })
}
