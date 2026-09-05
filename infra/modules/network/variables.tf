variable "compartment_id" { type = string }
variable "name" { type = string }

variable "vcn_id" {
  type    = string
  default = null
}

variable "vcn_cidrs" {
  type    = list(string)
  default = []
}

variable "dns_label" {
  type    = string
  default = null
}

variable "create_internet_gateway" {
  type    = bool
  default = false
}

variable "create_nat_gateway" {
  type    = bool
  default = false
}

variable "create_service_gateway" {
  type    = bool
  default = false
}

variable "create_local_peering_gateway" {
  type    = bool
  default = false
}

variable "internet_gateway_id" {
  type    = string
  default = null
}

variable "nat_gateway_id" {
  type    = string
  default = null
}

variable "service_gateway_id" {
  type    = string
  default = null
}

variable "local_peering_gateway_id" {
  type    = string
  default = null
}

variable "drg_id" {
  type    = string
  default = null
}

variable "subnets" {
  type    = any
  default = {}
}

variable "nsgs" {
  type    = list(string)
  default = []
}

variable "nsg_rules" {
  type    = any
  default = {}
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}

variable "defined_tags" {
  type    = map(string)
  default = {}
}
