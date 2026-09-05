terraform {
  required_version = ">= 1.12.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.0.0"
    }
    mysql = {
      source  = "zph/mysql"
      version = "~> 3.0"
    }
  }
}
