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

variable "stable_fault_domains" {
  type    = list(string)
  default = ["FAULT-DOMAIN-1", "FAULT-DOMAIN-2", "FAULT-DOMAIN-3"]
}

variable "canary_fault_domains" {
  type    = list(string)
  default = ["FAULT-DOMAIN-3"]
}

variable "pool_min_size" {
  type    = number
  default = 2
}

variable "pool_max_size" {
  type    = number
  default = 3
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

variable "app_image_id" {
  description = "Imagem dourada do Packer. Vazio cai na imagem base do Ubuntu, util so no primeiro apply."
  type        = string
  default     = ""
}

variable "image_os" {
  type    = string
  default = "Canonical Ubuntu"
}

variable "image_os_version" {
  type    = string
  default = "24.04"
}

variable "app_subnet_id" { type = string }
variable "lb_subnet_id" { type = string }
variable "app_nsg_ids" { type = list(string) }
variable "lb_nsg_ids" { type = list(string) }

variable "ssh_public_key" { type = string }

variable "boot_volume_size_in_gbs" {
  type    = number
  default = 60
}

variable "backend_port" {
  type    = number
  default = 8080
}

variable "health_check" {
  type = object({
    url_path    = optional(string, "/healthz")
    return_code = optional(number, 200)
    interval_ms = optional(number, 10000)
    timeout_ms  = optional(number, 3000)
    retries     = optional(number, 3)
  })
  default = {}
}

variable "lb_bandwidth_mbps" {
  type = object({
    minimum = number
    maximum = number
  })
  default = {
    minimum = 10
    maximum = 10
  }
}

variable "lb_certificate" {
  type = object({
    certificate_name   = string
    public_certificate = string
    private_key        = string
    ca_certificate     = optional(string)
  })
  default   = null
  sensitive = true
}

variable "drain_timeout_seconds" {
  description = "Janela de drenagem antes de terminar instancia removida do pool, usada na promocao do canario."
  type        = number
  default     = 120
}

variable "defined_tags" {
  type    = map(string)
  default = {}
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}

variable "tag_namespace" {
  description = "Namespace das tags definidas. Usado pelo cloud-init para descobrir o papel da instancia."
  type        = string
  default     = "pscloud"
}
