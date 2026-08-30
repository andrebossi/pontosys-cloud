output "db_system_id" { value = oci_mysql_mysql_db_system.this.id }
output "private_ip" { value = oci_mysql_mysql_db_system.this.ip_address }
output "port" { value = var.db_port }
output "admin_username" { value = var.admin_username }

output "public_endpoint" {
  description = "IP publico do Network Load Balancer, alcancavel apenas pelos /32 em db_client_cidrs."
  value       = try(oci_network_load_balancer_network_load_balancer.this[0].ip_addresses[0].ip_address, null)
}
