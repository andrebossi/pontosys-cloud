variable "compartment_id" { type = string }
variable "name" { type = string }

variable "local_peering_gateway_id" { type = string }
variable "peer_vcn_id" { type = string }

variable "peer_route_rules" {
  type    = any
  default = {}
}

variable "peer_subnet_ids" {
  type    = map(string)
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
