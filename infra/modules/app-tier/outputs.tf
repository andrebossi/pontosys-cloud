output "load_balancer_id" { value = oci_load_balancer_load_balancer.this.id }
output "load_balancer_ip" { value = oci_load_balancer_load_balancer.this.ip_address_details[0].ip_address }
output "backend_set_name" { value = oci_load_balancer_backend_set.app.name }
output "instance_configuration_ids" {
  value = { for k, v in oci_core_instance_configuration.app : k => v.id }
}

output "instance_pool_ids" {
  value = { for k, v in oci_core_instance_pool.app : k => v.id }
}

output "canary_context" {
  description = "Consumed by the app_canary role through terragrunt output."
  value = {
    load_balancer_id = oci_load_balancer_load_balancer.this.id
    backend_set_name = oci_load_balancer_backend_set.app.name
    stable_pool_id   = oci_core_instance_pool.app["stable"].id
    canary_pool_id   = oci_core_instance_pool.app["canary"].id
    backend_port     = var.backend_port
    pool_min_size    = var.pool_min_size
    pool_max_size    = var.pool_max_size
    compartment_id   = var.compartment_id
    subnet_id        = var.app_subnet_id
  }
}

output "autoscaling_configuration_id" {
  value = one(oci_autoscaling_auto_scaling_configuration.app[*].id)
}
