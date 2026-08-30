locals {
  env      = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env_name = local.env.locals.env_name

  unit_file       = "${get_terragrunt_dir()}/unit.hcl"
  unit            = fileexists(local.unit_file) ? read_terragrunt_config(local.unit_file).locals : {}
  provider_region = lookup(local.unit, "provider_region", local.env.locals.region)
}

terraform_binary = "terraform"

remote_state {
  backend = "oci"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket    = local.env.locals.state_bucket
    namespace = local.env.locals.objectstorage_namespace
    region    = local.env.locals.backend_region
    key       = "${local.env_name}/${path_relative_to_include()}/terraform.tfstate"

    kms_key_id = local.env.locals.state_kms_key_id
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "oci" {
      region = "${local.provider_region}"
    }
  EOF
}

inputs = merge(
  local.env.locals,
  {
    freeform_tags = {
      environment = local.env_name
      managed_by  = "terragrunt"
      project     = local.env.locals.label_prefix
    }
  }
)
