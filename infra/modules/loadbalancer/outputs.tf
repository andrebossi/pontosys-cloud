output "load_balancer_id" { value = oci_load_balancer_load_balancer.this.id }
output "ip_address" { value = oci_load_balancer_load_balancer.this.ip_address_details[0].ip_address }
output "backend_set_name" { value = oci_load_balancer_backend_set.this.name }
