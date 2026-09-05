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

variable "applications" {
  description = <<-EOT
    Application catalog. Each entry generates:
      - a dedicated MariaDB user with a random password
      - an OCI Vault secret with the full DSN
    Adding an application = adding a key to this map. Nothing else changes.
  EOT
  type = map(object({
    db_name   = string
    db_user   = string
    db_host   = optional(string, "%")
    grants    = optional(list(string), ["SELECT", "INSERT", "UPDATE", "DELETE"])
    databases = optional(list(string), [])
  }))
  default = {}
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

variable "backup_retention" {
  type = object({
    archive_after_days = optional(number, 30)
    delete_after_days  = optional(number, 365)
  })
  default = {}
}

variable "immutable_retention_days" {
  description = "Timed retention rule: for N days nobody can delete or overwrite an object. 0 disables it."
  type        = number
  default     = 0
}
