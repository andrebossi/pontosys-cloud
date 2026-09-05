locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform_binary = "terraform"

remote_state {
  backend = "oci"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket     = local.env.state_bucket
    namespace  = local.env.objectstorage_namespace
    region     = local.env.region
    key        = "${path_relative_to_include()}/terraform.tfstate"
    kms_key_id = local.env.state_kms_key_id
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "oci" {
      region = "${local.env.region}"
    }
  EOF
}

inputs = {
  compartment_id = local.env.compartment_id
}
