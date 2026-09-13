locals {
  env_name = "prod"
  prefix   = "pscloud"

  region     = "sa-saopaulo-1"
  tenancy_id = "ocid1.tenancy.oc1..aaaaaaaa5lalh56ffqq2aorknmx3aokh5pekgj5hkplpbroue6ljcpdwqrtq"

  compartment_id = "ocid1.tenancy.oc1..aaaaaaaa5lalh56ffqq2aorknmx3aokh5pekgj5hkplpbroue6ljcpdwqrtq"

  objectstorage_namespace = "grkmcm7puhc0"
  state_bucket            = "pscloud-tfstate"
  state_kms_key_id        = null

  vcn_cidr = "10.20.0.0/16"

  subnet_cidrs = {
    public = "10.20.0.0/24"
    app    = "10.20.16.0/20"
    db     = "10.20.32.0/24"
  }

  legacy = {
    vcn_id         = "ocid1.vcn.oc1.sa-saopaulo-1.amaaaaaayr5h27aaudqj7ndd3klx3d5mvodrqhyyykii5joz4mh7wydoz27a"
    vcn_cidr       = "10.0.0.0/16"
    subnet_id      = "ocid1.subnet.oc1.sa-saopaulo-1.aaaaaaaadzylb5yjig5aolxsspyvbwh4rphumcisvyhunv2clfxhqedsnnja"
    route_table_id = "ocid1.routetable.oc1.sa-saopaulo-1.aaaaaaaayh47ermhj5djwm3l2lbv23xzquk4c2swdaywtitvyppb7ubt7uoa"
    security_list  = "ocid1.securitylist.oc1.sa-saopaulo-1.aaaaaaaacbtvukbiuf6sjbnqn3mvkqok473ykdsrhawffnr6gl557figx7wa"
    internet_gw    = "ig-rustdesk"
  }

  admin_cidrs      = ["0.0.0.0/0"]
  lb_ingress_cidrs = ["0.0.0.0/0"]
  db_client_cidrs  = ["0.0.0.0/0"]

  app_port = 80
  db_port  = 3306

  # Where the applications reach the database. OCI composes it from the labels,
  # so it is known before the DB system exists.
  db_fqdn = "${local.prefix}mysql.db.vcn.oraclevcn.com"

  # One MySQL user per application, with a generated password and a vault
  # secret. Databases are shared: several apps read virtualstoreglobal.
  applications = {
    virtualstore = {
      db_user   = "virtualstore_app"
      db_name   = "virtualstoreglobal"
      databases = ["virtualstoreglobal", "cep"]
    }
    entradaapi = {
      db_user   = "entradaapi_app"
      db_name   = "virtualstoreglobal"
      databases = ["virtualstoreglobal", "cep"]
    }
    cadastrosapi = {
      db_user   = "cadastrosapi_app"
      db_name   = "cep"
      databases = ["cep"]
    }
    geradorrelatoriosapi = {
      db_user   = "geradorrelatorios_app"
      db_name   = "virtualstoreglobal"
      databases = ["virtualstoreglobal"]
    }
    monitorclientesapi = {
      db_user   = "monitorclientes_app"
      db_name   = "virtualstoreglobal"
      databases = ["virtualstoreglobal"]
    }
  }

  tags = {
    Project     = "pscloud"
    Environment = "prod"
    Owner       = "platform"
    CostCenter  = "CC-1001"
    ManagedBy   = "terragrunt"
  }
}
