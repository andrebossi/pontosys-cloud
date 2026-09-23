output "vault_id" { value = oci_kms_vault.this.id }
output "kms_key_id" { value = oci_kms_key.this.id }

output "ssh_public_keys" {
  description = "Go into authorized_keys via cloud-init."
  value       = { for k, v in tls_private_key.ssh : k => v.public_key_openssh }
}

output "ssh_private_key_secret_ids" {
  description = "Ansible fetches the private key here, never from the state."
  value       = { for k, v in oci_vault_secret.ssh_private_key : k => v.id }
}

output "ssh_public_key_secret_ids" {
  description = "Public key mirrored into the vault alongside the private key, for access/audit tooling that only needs the public half."
  value       = { for k, v in oci_vault_secret.ssh_public_key : k => v.id }
}

output "ssh_private_keys" {
  value     = { for k, v in tls_private_key.ssh : k => v.private_key_openssh }
  sensitive = true
}

output "db_admin_secret_id" { value = oci_vault_secret.db_admin.id }
output "db_admin_username" { value = var.db_admin_username }

output "db_admin_password" {
  value     = random_password.db_admin.result
  sensitive = true
}

output "bastion_id" {
  value = try(oci_bastion_bastion.this[0].id, null)
}
