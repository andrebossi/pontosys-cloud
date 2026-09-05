resource "oci_load_balancer_load_balancer" "this" {
  compartment_id             = var.compartment_id
  display_name               = var.name
  shape                      = "flexible"
  subnet_ids                 = [var.subnet_id]
  network_security_group_ids = var.nsg_ids
  is_private                 = var.is_private

  shape_details {
    minimum_bandwidth_in_mbps = var.bandwidth_mbps.minimum
    maximum_bandwidth_in_mbps = var.bandwidth_mbps.maximum
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags
}

resource "oci_load_balancer_backend_set" "this" {
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = var.backend_set_name
  policy           = var.policy

  health_checker {
    protocol          = var.health_check.protocol
    port              = var.backend_port
    url_path          = var.health_check.url_path
    return_code       = var.health_check.return_code
    interval_ms       = var.health_check.interval_ms
    timeout_in_millis = var.health_check.timeout_ms
    retries           = var.health_check.retries
  }
}

resource "oci_load_balancer_backend" "this" {
  for_each = var.backends

  load_balancer_id = oci_load_balancer_load_balancer.this.id
  backendset_name  = oci_load_balancer_backend_set.this.name
  ip_address       = each.value
  port             = var.backend_port
}

resource "oci_load_balancer_listener" "this" {
  for_each = var.listeners

  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = each.key
  default_backend_set_name = oci_load_balancer_backend_set.this.name
  port                     = each.value.port
  protocol                 = lookup(each.value, "protocol", "HTTP")

  connection_configuration {
    idle_timeout_in_seconds = lookup(each.value, "idle_timeout_in_seconds", 60)
  }
}
