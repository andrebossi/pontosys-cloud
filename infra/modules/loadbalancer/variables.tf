variable "compartment_id" { type = string }
variable "name" { type = string }

variable "subnet_id" { type = string }

variable "nsg_ids" {
  type    = list(string)
  default = []
}

variable "is_private" {
  type    = bool
  default = false
}

variable "bandwidth_mbps" {
  type = object({
    minimum = number
    maximum = number
  })
  default = {
    minimum = 10
    maximum = 10
  }
}

variable "backend_set_name" {
  type    = string
  default = "default"
}

variable "policy" {
  type    = string
  default = "ROUND_ROBIN"
}

variable "backend_port" {
  type    = number
  default = 8080
}

variable "backends" {
  type    = map(string)
  default = {}
}

variable "health_check" {
  type = object({
    protocol    = optional(string, "HTTP")
    url_path    = optional(string, "/")
    return_code = optional(number, 200)
    interval_ms = optional(number, 10000)
    timeout_ms  = optional(number, 3000)
    retries     = optional(number, 3)
  })
  default = {}
}

variable "listeners" {
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
