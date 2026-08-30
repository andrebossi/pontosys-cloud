output "tag_namespace" { value = oci_identity_tag_namespace.this.name }

output "tag_keys" {
  description = "Chaves completas, prontas para defined_tags: pscloud.role, pscloud.tier, ..."
  value       = { for k, v in oci_identity_tag.this : k => "${oci_identity_tag_namespace.this.name}.${v.name}" }
}

output "role_tag_key" {
  value = "${oci_identity_tag_namespace.this.name}.${oci_identity_tag.this["role"].name}"
}

output "dynamic_group_names" {
  value = { for k, v in oci_identity_dynamic_group.role : k => v.name }
}

output "policy_names" {
  value = { for k, v in oci_identity_policy.role : k => v.name }
}

output "role_statements" {
  description = "O que cada papel pode, para revisao sem abrir o console."
  value       = local.role_statements
}
