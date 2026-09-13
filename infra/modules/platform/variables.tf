variable "compartment_id" { type = string }
variable "label_prefix" { type = string }

variable "ssh_key_algorithm" {
  description = "RSA 4096 for compatibility with OCI Bastion and the serial console."
  type        = string
  default     = "RSA"
}

variable "ssh_key_roles" {
  description = "One keypair per role: compromising the app VM doesn't hand over the database."
  type        = list(string)
  default     = ["app", "db", "monitoring"]
}

variable "db_admin_username" {
  type    = string
  default = "pscloudadm"
}

variable "db_private_ip" {
  description = "MariaDB's private IP, written inside each application's secret."
  type        = string
  default     = ""
}

variable "bastion_target_subnet_id" {
  description = "Target subnet for OCI Bastion (the private app subnet). Empty disables the bastion."
  type        = string
  default     = ""
}

variable "admin_cidrs" {
  type = list(string)
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}
