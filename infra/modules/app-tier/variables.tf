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
  description = "Golden Packer image. It is based on the Ubuntu base image; useful only for the initial application."
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
variable "is_private" { type = bool }

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
  description = "Drainage window before terminating an instance removed from the pool, used during canary promotion."
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
  description = "Namespace for defined tags. Used by cloud-init to discover the instance's role."
  type        = string
  default     = "pscloud"
}

variable "autoscaling" {
  description = "Scales the stable pool on CPU. Null disables it and the pool stays at pool_min_size."
  type = object({
    is_enabled           = optional(bool, true)
    cool_down_in_seconds = optional(number, 300)
    step                 = optional(number, 1)
    scale_out_cpu        = optional(number, 70)
    scale_in_cpu         = optional(number, 25)
    pending_duration     = optional(string, "PT5M")
  })
  default = null
}
