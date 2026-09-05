variable "compartment_id" { type = string }
variable "tenancy_id" { type = string }
variable "label_prefix" { type = string }

variable "roles" {
  description = "Operational roles. Each one gets a role tag value, a dynamic group and a policy."
  type = map(object({
    capabilities = optional(list(string), [])
    statements   = optional(list(string), [])
  }))
  default = {
    app = {
      capabilities = ["read_secrets"]
    }
    monitoring = {
      capabilities = ["read_secrets", "read_inventory", "read_metrics", "artifacts_bucket"]
    }
  }
}

variable "environments" {
  description = "Accepted values for the environment tag."
  type        = list(string)
  default     = ["prod", "rc", "staging", "dev"]
}

variable "tiers" {
  description = "Accepted values for the tier tag."
  type        = list(string)
  default     = ["web", "data", "ops"]
}

variable "artifacts_bucket_name" {
  description = "Artifacts bucket. Required by the artifacts_bucket capability."
  type        = string
  default     = ""
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}
