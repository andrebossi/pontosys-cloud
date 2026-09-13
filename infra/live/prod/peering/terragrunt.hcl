include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules//peering"
}

dependency "network" {
  config_path = "../network"

  mock_outputs                            = { local_peering_gateway_id = "ocid1.localpeeringgateway.oc1..mock" }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  name = "${local.env.prefix}-lpg"

  local_peering_gateway_id = dependency.network.outputs.local_peering_gateway_id
  peer_vcn_id              = local.env.legacy.vcn_id

  peer_route_rules = {
    pscloud = { destination = local.env.vcn_cidr }
  }

  peer_subnet_ids = {}

  freeform_tags = merge(local.env.tags, { Component = "peering" })
}
