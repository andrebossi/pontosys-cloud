# ---------------------------------------------------------------------------
# NAMESPACE DE TAGS DEFINIDAS
#
# Tag definida e nao freeform por dois motivos concretos:
#   1. regra de dynamic group SO enxerga tag definida -- `tag.pscloud.role.value`
#      funciona, freeform nao;
#   2. tag definida aceita VALIDADOR de valores. Com a lista de valores
#      permitidos, um `terraform apply` com role = "database" (em vez de "db")
#      falha no plano. Com freeform tag ele aplicaria, a VM subiria fora de todo
#      dynamic group, o instance principal nao leria segredo nenhum e o erro
#      apareceria como "Ansible nao consegue autenticar no Vault".
# ---------------------------------------------------------------------------
resource "oci_identity_tag_namespace" "this" {
  compartment_id = var.compartment_id
  name           = var.label_prefix
  description    = "Taxonomia de recursos do ambiente ${var.label_prefix}"
  is_retired     = false
}

locals {
  tag_keys = {
    role = {
      description      = "Papel operacional. Alimenta dynamic group de IAM e o inventario do Ansible."
      values           = keys(var.roles)
      is_cost_tracking = false
    }
    tier = {
      description      = "Camada da arquitetura."
      values           = ["web", "data", "ops"]
      is_cost_tracking = false
    }
    environment = {
      description      = "Ambiente."
      values           = ["prod", "staging", "dev"]
      is_cost_tracking = true
    }
    data_classification = {
      description      = "Sensibilidade do dado em repouso no recurso."
      values           = ["public", "internal", "confidential", "restricted"]
      is_cost_tracking = false
    }
    backup = {
      description      = "Politica de backup esperada. Auditavel: recurso com backup=required e sem assignment e achado de conformidade."
      values           = ["none", "bronze", "silver", "gold"]
      is_cost_tracking = false
    }
    # Sem lista de valores: texto livre, mas rastreado em custo.
    cost_center = {
      description      = "Centro de custo para rateio."
      values           = null
      is_cost_tracking = true
    }
    owner = {
      description      = "Time responsavel por acordar as 3h da manha."
      values           = null
      is_cost_tracking = false
    }
  }
}

resource "oci_identity_tag" "this" {
  for_each = local.tag_keys

  tag_namespace_id = oci_identity_tag_namespace.this.id
  name             = each.key
  description      = each.value.description
  is_cost_tracking = each.value.is_cost_tracking

  dynamic "validator" {
    for_each = each.value.values == null ? [] : [1]
    content {
      validator_type = "ENUM"
      values         = each.value.values
    }
  }
}

# ---------------------------------------------------------------------------
# IDENTIDADE DAS INSTANCIAS (instance principals)
#
# A tag `role` e uma fonte de verdade para tres coisas: placement e NSG no
# Terraform, permissao de IAM aqui, e agrupamento do inventario dinamico do
# Ansible. Nao ha um segundo lugar onde "esta VM e o monitoramento" esteja
# escrito.
# ---------------------------------------------------------------------------
resource "oci_identity_dynamic_group" "role" {
  for_each = var.roles

  compartment_id = var.tenancy_id
  name           = "${var.label_prefix}-dg-${each.key}"
  description    = "Instancias com ${var.label_prefix}.role = ${each.key}"
  matching_rule  = "ALL {instance.compartment.id = '${var.compartment_id}', tag.${var.label_prefix}.role.value = '${each.key}'}"

  depends_on = [oci_identity_tag.this]
}

locals {
  dg = { for k, v in oci_identity_dynamic_group.role : k => v.name }
  c  = var.compartment_id

  # Cada capability e um conjunto de statements com proposito unico. Adicionar
  # um papel novo e escolher capabilities, nao escrever statement solto.
  capability_statements = {
    # Le o proprio segredo (credencial de banco, chave SSH) do Vault.
    read_secrets = [
      "to read secret-bundles in compartment id ${local.c}",
    ]

    # Monta o inventario dinamico do Ansible e resolve IP das instancias.
    read_inventory = [
      "to read instance-family in compartment id ${local.c}",
      "to read virtual-network-family in compartment id ${local.c}",
    ]

    read_metrics = [
      "to read metrics in compartment id ${local.c}",
    ]

    artifacts_bucket = [
      "to manage objects in compartment id ${local.c} where target.bucket.name = '${var.artifacts_bucket_name}'",
      "to read buckets in compartment id ${local.c}",
    ]

    # O que o canary.py e o image.py precisam: mover weight de backend,
    # redimensionar pool, criar instance configuration e podar imagem.
    deploy_executor = [
      "to manage instance-pools in compartment id ${local.c}",
      "to manage instance-configurations in compartment id ${local.c}",
      "to manage load-balancers in compartment id ${local.c}",
      "to manage instance-images in compartment id ${local.c}",
      "to use volume-family in compartment id ${local.c}",
      "to use virtual-network-family in compartment id ${local.c}",
      "to read limits in tenancy",
      # O escopo por tag e o que impede o executor de terminar a propria VM de
      # monitoramento ou qualquer coisa fora da camada de aplicacao.
      "to manage instance-family in compartment id ${local.c} where target.resource.tag.${var.label_prefix}.role = '${var.managed_role_tag_value}'",
    ]
  }

  role_statements = {
    for name, r in var.roles : name => concat(
      flatten([for cap in r.capabilities : [
        for st in local.capability_statements[cap] :
        "Allow dynamic-group ${local.dg[name]} ${st}"
      ]]),
      r.statements,
    )
  }
}

# Uma policy por papel. `app` nao ganha nada de deploy; `monitoring` nao ganha
# permissao que nao use.
resource "oci_identity_policy" "role" {
  for_each = { for k, v in local.role_statements : k => v if length(v) > 0 }

  compartment_id = var.compartment_id
  name           = "${var.label_prefix}-policy-${each.key}"
  description    = "Permissoes de instance principal do papel ${each.key}"
  statements     = each.value

  freeform_tags = var.freeform_tags
}
