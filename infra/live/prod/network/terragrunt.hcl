include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules//network"
}

inputs = {
  name      = local.env.prefix
  vcn_cidrs = [local.env.vcn_cidr]
  dns_label = "vcn"

  create_internet_gateway      = true
  create_nat_gateway           = true
  create_service_gateway       = true
  create_local_peering_gateway = true

  subnets = {
    public = {
      cidr_block = local.env.subnet_cidrs.public
      public     = true
      route_rules = {
        internet = { destination = "0.0.0.0/0", target = "internet_gateway" }
        legacy   = { destination = local.env.legacy.vcn_cidr, target = "local_peering" }
      }
    }

    app = {
      cidr_block = local.env.subnet_cidrs.app
      route_rules = {
        internet     = { destination = "0.0.0.0/0", target = "nat_gateway" }
        oci-services = { destination = "all-services", target = "service_gateway" }
        legacy       = { destination = local.env.legacy.vcn_cidr, target = "local_peering" }
      }
    }

    db = {
      cidr_block = local.env.subnet_cidrs.db
      route_rules = {
        oci-services = { destination = "all-services", target = "service_gateway" }
        legacy       = { destination = local.env.legacy.vcn_cidr, target = "local_peering" }
      }
    }
  }

  nsgs = ["lb", "app", "db"]

  nsg_rules = {
    lb-in-web    = { nsg = "lb", remotes = local.env.lb_ingress_cidrs, ports = [80, 443] }
    lb-out-app   = { nsg = "lb", direction = "EGRESS", remotes = ["app"], ports = [local.env.app_port] }
    app-in-lb    = { nsg = "app", remotes = ["lb"], ports = [local.env.app_port] }
    app-in-ssh   = { nsg = "app", remotes = local.env.admin_cidrs, ports = [22] }
    app-in-peer  = { nsg = "app", remotes = [local.env.legacy.vcn_cidr], ports = [local.env.app_port, 22] }
    app-out-db   = { nsg = "app", direction = "EGRESS", remotes = ["db"], ports = [local.env.db_port] }
    app-out-any  = { nsg = "app", direction = "EGRESS", protocol = "all", remotes = ["0.0.0.0/0"] }
    db-in-app    = { nsg = "db", remotes = ["app"], ports = [local.env.db_port] }
    db-in-peer   = { nsg = "db", remotes = [local.env.legacy.vcn_cidr], ports = [local.env.db_port] }
    db-in-client = { nsg = "db", remotes = local.env.db_client_cidrs, ports = [local.env.db_port] }
  }

  freeform_tags = merge(local.env.tags, { Component = "network" })
}
