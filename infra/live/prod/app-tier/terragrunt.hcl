include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules//app-tier"
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    subnet_ids = { app = "ocid1.subnet.oc1..mock", public = "ocid1.subnet.oc1..mock" }
    nsg_ids    = { app = "ocid1.networksecuritygroup.oc1..mock", lb = "ocid1.networksecuritygroup.oc1..mock" }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "identity" {
  config_path = "../identity"

  mock_outputs = {
    tag_namespace     = "pscloud"
    role_defined_tags = { app = { "pscloud.role" = "app" } }
    tag_keys          = { environment = "pscloud.environment", cost_center = "pscloud.cost_center" }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "platform" {
  config_path = "../platform"

  mock_outputs                            = { ssh_public_keys = { app = "ssh-rsa MOCK" } }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "monitoring" {
  config_path = "../monitoring"

  mock_outputs                            = { private_ips = { "01" = "10.20.16.30" } }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependencies {
  paths = ["../database"]
}

inputs = {
  tenancy_id   = local.env.tenancy_id
  label_prefix = local.env.prefix

  shape         = "VM.Standard.E4.Flex"
  ocpus         = 1
  memory_in_gbs = 6

  app_image_id = get_env("PSCLOUD_APP_IMAGE_ID", "")

  app_subnet_id = dependency.network.outputs.subnet_ids.app
  lb_subnet_id  = dependency.network.outputs.subnet_ids.public
  app_nsg_ids   = [dependency.network.outputs.nsg_ids.app]
  lb_nsg_ids    = [dependency.network.outputs.nsg_ids.lb]
  is_private    = false

  ssh_public_key = dependency.platform.outputs.ssh_public_keys.app

  backend_port = local.env.app_port

  grafana_backend_ip    = dependency.monitoring.outputs.private_ips["01"]
  grafana_backend_port  = local.env.grafana_port
  grafana_listener_port = local.env.grafana_port

  pool_min_size = 1
  pool_max_size = 1

  stable_fault_domains = ["FAULT-DOMAIN-1", "FAULT-DOMAIN-2", "FAULT-DOMAIN-3"]
  canary_fault_domains = ["FAULT-DOMAIN-3"]

  autoscaling = {
    is_enabled           = true
    cool_down_in_seconds = 300
    step                 = 1
    scale_out_cpu        = 70
    scale_in_cpu         = 25
    pending_duration     = "PT5M"
  }

  health_check = {
    url_path    = "/healthz"
    return_code = 200
    interval_ms = 10000
    timeout_ms  = 3000
    retries     = 3
  }

  lb_bandwidth_mbps = {
    minimum = 10
    maximum = 10
  }

  drain_timeout_seconds = 120

  defined_tags = merge(
    dependency.identity.outputs.role_defined_tags.app,
    {
      (dependency.identity.outputs.tag_keys.environment) = local.env.env_name
      (dependency.identity.outputs.tag_keys.cost_center) = local.env.tags.CostCenter
    },
  )

  freeform_tags = merge(local.env.tags, { Component = "app", Role = "app" })
}
