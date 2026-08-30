variable "compartment_id" { type = string }
variable "name" { type = string }
variable "tenancy_id" {
  description = "Only needed to list the tenancy's availability domains."
  type        = string
}

variable "availability_domain" {
  description = "Full AD name. Null = resolve via the index below."
  type        = string
  default     = null
}

variable "availability_domain_index" {
  description = "0 = first AD in the region. Sao Paulo only has 0."
  type        = number
  default     = 0
}

variable "fault_domain" {
  description = "Pinning the FD makes explicit which failure group the VM is in. Sao Paulo has 1 AD and 3 FDs."
  type        = string
  default     = null
}

variable "shape" { type = string }
variable "ocpus" { type = number }
variable "memory_in_gbs" { type = number }

variable "subnet_id" { type = string }
variable "nsg_ids" { type = list(string) }
variable "assign_public_ip" { type = bool }

variable "private_ip" {
  description = "Fixed private IP. The database needs one: the DSN in the secrets points to it."
  type        = string
  default     = null
}

variable "ssh_public_key" { type = string }

variable "boot_volume_size_in_gbs" {
  type    = number
  default = 50
}

variable "boot_volume_vpus_per_gb" {
  type    = number
  default = 10
}

variable "data_volume" {
  description = <<-EOT
    Data volume separate from boot. For the database this isn't a minor
    detail: it allows snapshotting just the data, resizing without recreating
    the VM, and reattaching the volume to a new instance if the original dies.
    vpus_per_gb: 10 = Balanced (60 IOPS/GB), 20 = Higher Performance (75 IOPS/GB),
    30+ = Ultra High.
  EOT
  type = object({
    size_in_gbs = number
    vpus_per_gb = number
  })
  default = null
}

variable "backup_policy" {
  description = "Oracle-managed backup policy for the volumes: bronze | silver | gold | none."
  type        = string
  default     = "bronze"
}

variable "role" {
  description = "app | db | monitoring. Becomes ROLE in /run/instance.env and a label in collection."
  type        = string
}

variable "dns_domain" {
  type    = string
  default = "vcn.oraclevcn.com"
}

variable "allow_port" {
  description = "Port opened in the local iptables on boot (the NSG is what actually governs access)."
  type        = number
  default     = 22
}

variable "defined_tags" {
  type    = map(string)
  default = {}
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}

variable "image_os" {
  type    = string
  default = "Canonical Ubuntu"
}

variable "image_os_version" {
  type    = string
  default = "24.04"
}

variable "tag_namespace" {
  description = "Namespace of the defined tags. Used by cloud-init to discover the instance's role."
  type        = string
  default     = "pscloud"
}
