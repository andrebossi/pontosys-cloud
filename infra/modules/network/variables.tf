variable "compartment_id" { type = string }
variable "tenancy_id" { type = string }
variable "label_prefix" { type = string }

variable "vcn_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_cidrs" {
  type = object({
    public      = string
    private_app = string
    private_db  = string
  })
  default = {
    public      = "10.20.0.0/24"
    private_app = "10.20.16.0/20"
    private_db  = "10.20.32.0/24"
  }
}

variable "admin_cidrs" {
  description = "Source of administrative SSH. Never 0.0.0.0/0."
  type        = list(string)
}

variable "monitoring_http_cidrs" {
  description = <<-EOT
    Who can reach nginx's 80/443 on the monitoring VM. 80 needs to stay open
    for Let's Encrypt's HTTP-01 challenge; what protects 443 is fail2ban
    combined with the Grafana login.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_client_cidrs" {
  description = "Allowlist /32 for external MySQL access through the Network Load Balancer."
  type        = list(string)
  default     = []
}

variable "lb_ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "app_backend_port" {
  type    = number
  default = 8080
}

variable "db_port" {
  type    = number
  default = 3306
}

variable "monitoring_ingest_ports" {
  description = "8428 = VictoriaMetrics (remote write), 9428 = VictoriaLogs."
  type        = list(number)
  default     = [8428, 9428]
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}
