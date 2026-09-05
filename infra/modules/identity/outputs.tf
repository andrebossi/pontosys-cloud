output "tag_namespace" { value = oci_identity_tag_namespace.this.name }

output "tag_keys" {
  description = "Full tag keys, ready for defined_tags: pscloud.role, pscloud.tier, ..."
  value       = { for k, v in oci_identity_tag.this : k => "${oci_identity_tag_namespace.this.name}.${v.name}" }
}

output "role_tag_key" {
  value = "${oci_identity_tag_namespace.this.name}.${oci_identity_tag.this["role"].name}"
}

output "role_defined_tags" {
  description = "Defined tags to put on an instance so it joins the dynamic group of that role."
  value = {
    for name in keys(var.roles) : name => {
      "${oci_identity_tag_namespace.this.name}.${oci_identity_tag.this["role"].name}" = name
    }
  }
}

output "dynamic_group_names" {
  value = { for k, v in oci_identity_dynamic_group.role : k => v.name }
}

output "policy_names" {
  value = { for k, v in oci_identity_policy.role : k => v.name }
}

output "role_statements" {
  description = "What each role is allowed to do, reviewable without opening the console."
  value       = local.role_statements
}
