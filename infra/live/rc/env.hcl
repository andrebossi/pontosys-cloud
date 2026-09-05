locals {
  env_name = "rc"
  prefix   = "pscloud-rc"

  region     = "sa-saopaulo-1"
  tenancy_id = "ocid1.tenancy.oc1..aaaaaaaa5lalh56ffqq2aorknmx3aokh5pekgj5hkplpbroue6ljcpdwqrtq"

  compartment_id = "ocid1.tenancy.oc1..aaaaaaaa5lalh56ffqq2aorknmx3aokh5pekgj5hkplpbroue6ljcpdwqrtq"

  objectstorage_namespace = "grkmcm7puhc0"
  state_bucket            = "pscloud-tfstate"
  state_kms_key_id        = null

  app_port = 80

  tags = {
    Project     = "pscloud"
    Environment = "rc"
    Owner       = "platform"
    CostCenter  = "CC-1001"
    ManagedBy   = "terragrunt"
  }
}
