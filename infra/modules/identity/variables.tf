variable "compartment_id" { type = string }
variable "tenancy_id" { type = string }
variable "label_prefix" { type = string }

# ---------------------------------------------------------------------------
# PAPEIS E O QUE CADA UM PODE
#
# Uma policy por papel, não uma policy grande com tudo dentro: assim `oci iam
# policy get` de um papel mostra exatamente o que aquela VM pode, e revogar uma
# capacidade não mexe nas outras.
#
# `capabilities` são conjuntos nomeados (ver locals.capability_statements).
# `statements` é escape hatch para o que não couber neles.
# ---------------------------------------------------------------------------
variable "roles" {
  type = map(object({
    capabilities = optional(list(string), [])
    statements   = optional(list(string), [])
  }))
  default = {
    # VM de aplicação: lê o próprio segredo de banco e nada mais.
    app = {
      capabilities = ["read_secrets"]
    }
    # VM de monitoramento: além de coletar, é o executor do Ansible, do canário
    # e do ciclo de imagem.
    monitoring = {
      capabilities = ["read_secrets", "read_inventory", "read_metrics", "artifacts_bucket", "deploy_executor"]
    }
  }
}

variable "artifacts_bucket_name" {
  description = "Bucket de artefatos. Exigido pela capability artifacts_bucket."
  type        = string
  default     = ""
}

variable "managed_role_tag_value" {
  description = "Valor da tag role que o deploy_executor pode criar e terminar."
  type        = string
  default     = "app"
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}
