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

  create_internet_gateway = true
  create_nat_gateway      = true
  create_service_gateway  = true

  subnets = {
    public = {
      cidr_block = local.env.subnet_cidrs.public
      public     = true
      route_rules = {
        internet = { destination = "0.0.0.0/0", target = "internet_gateway" }
      }
    }

    app = {
      cidr_block = local.env.subnet_cidrs.app
      route_rules = {
        internet     = { destination = "0.0.0.0/0", target = "nat_gateway" }
        oci-services = { destination = "all-services", target = "service_gateway" }
      }
    }

    db = {
      cidr_block = local.env.subnet_cidrs.db
      route_rules = {
        oci-services = { destination = "all-services", target = "service_gateway" }
      }
    }
  }

  nsgs = ["lb", "app", "db", "monitoring"]

  nsg_rules = {
    lb-in-web    = { nsg = "lb", remotes = local.env.lb_ingress_cidrs, ports = [80, 443] }
    lb-out-app   = { nsg = "lb", direction = "EGRESS", remotes = ["app"], ports = [local.env.app_port] }

    app-in-lb    = { nsg = "app", remotes = ["lb"], ports = [local.env.app_port] }
    app-in-ssh   = { nsg = "app", remotes = ["monitoring"], ports = [22] }
    app-out-db   = { nsg = "app", direction = "EGRESS", remotes = ["db"], ports = [local.env.db_port] }
    app-out-any  = { nsg = "app", direction = "EGRESS", protocol = "all", remotes = ["0.0.0.0/0"] }

    db-in-app    = { nsg = "db", remotes = ["app"], ports = [local.env.db_port] }
    db-in-client = { nsg = "db", remotes = local.env.db_client_cidrs, ports = [local.env.db_port] }

    monitoring-in-ssh     = { nsg = "monitoring", remotes = ["0.0.0.0/0"], ports = [22] }
    monitoring-in-grafana = { nsg = "monitoring", remotes = ["0.0.0.0/0"], ports = [local.env.grafana_port] }
    monitoring-out-any    = { nsg = "monitoring", direction = "EGRESS", protocol = "all", remotes = ["0.0.0.0/0"] }
  }

  freeform_tags = { CostCenter = local.env.tags.CostCenter }
}
