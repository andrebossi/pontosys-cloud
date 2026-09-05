variable "compartment_id" { type = string }
variable "tenancy_id" { type = string }
variable "name" { type = string }

variable "instances" {
  type    = any
  default = {}
}

variable "shape" {
  type    = string
  default = "VM.Standard.E4.Flex"
}

variable "ocpus" {
  type    = number
  default = 1
}

variable "memory_in_gbs" {
  type    = number
  default = 6
}

variable "boot_volume_size_in_gbs" {
  type    = number
  default = 50
}

variable "image_id" {
  type    = string
  default = null
}

variable "image_os" {
  type    = string
  default = "Canonical Ubuntu"
}

variable "image_os_version" {
  type    = string
  default = "24.04"
}

variable "subnet_id" { type = string }

variable "nsg_ids" {
  type    = list(string)
  default = []
}

variable "assign_public_ip" {
  type    = bool
  default = false
}

variable "ssh_public_key" { type = string }

variable "user_data" {
  type    = string
  default = null
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}

variable "defined_tags" {
  type    = map(string)
  default = {}
}
