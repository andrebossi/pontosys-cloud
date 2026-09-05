variable "compartment_id" { type = string }
variable "tenancy_id" { type = string }
variable "label_prefix" { type = string }

variable "availability_domain" {
  type    = string
  default = null
}

variable "availability_domain_index" {
  type    = number
  default = 0
}

variable "fault_domain" {
  type    = string
  default = "FAULT-DOMAIN-3"
}

variable "shape_name" {
  description = "Shapes ECPU: MySQL.Free, MySQL.2, MySQL.4, MySQL.8."
  type        = string
  default     = "MySQL.2"
}

variable "mysql_version" {
  type    = string
  default = null
}

variable "data_storage_size_in_gb" {
  type    = number
  default = 50
}

variable "is_highly_available" {
  type    = bool
  default = false
}

variable "admin_username" {
  type    = string
  default = "admin"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "db_subnet_id" { type = string }
variable "nlb_subnet_id" { type = string }
variable "nlb_nsg_ids" { type = list(string) }

variable "expose_nlb" {
  description = "MySQL HeatWave does not accept public IPs. External access via a /32 allowlist goes through a Network Load Balancer."
  type        = bool
  default     = true
}

variable "db_port" {
  type    = number
  default = 3306
}

variable "db_listener_port" {
  type    = number
  default = 55336
}

variable "backup" {
  type = object({
    retention_in_days = optional(number, 7)
    window_start_time = optional(string, "04:00-00:00")
    pitr_enabled      = optional(bool, true)
  })
  default = {}
}

variable "defined_tags" {
  type    = map(string)
  default = {}
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}
