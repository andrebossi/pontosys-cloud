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

output "app_db_secret_ids" {
  value = { for k, v in oci_vault_secret.app_db : k => v.id }
}

output "bastion_id" {
  value = try(oci_bastion_bastion.this[0].id, null)
}
output "namespace" { value = data.oci_objectstorage_namespace.this.namespace }
output "bucket_name" { value = oci_objectstorage_bucket.backups.name }
output "bucket_id" { value = oci_objectstorage_bucket.backups.bucket_id }

output "app_db_passwords" {
  description = "Password per application, consumed by the database module to create the MySQL users."
  value       = { for key, password in random_password.app_db : key => password.result }
  sensitive   = true
}
