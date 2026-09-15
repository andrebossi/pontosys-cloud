data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_id
}

data "oci_core_images" "os" {
  count = var.app_image_id == "" ? 1 : 0

  compartment_id           = var.compartment_id
  operating_system         = var.image_os
  operating_system_version = var.image_os_version
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  availability_domain = coalesce(
    var.availability_domain,
    data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name,
  )

  image_id = var.app_image_id != "" ? var.app_image_id : [
    for image in data.oci_core_images.os[0].images : image.id
    if !can(regex("Minimal|GPU", image.display_name))
  ][0]

  pools = {
    stable = var.stable_fault_domains
    canary = var.canary_fault_domains
  }
}

resource "oci_load_balancer_load_balancer" "this" {
  compartment_id             = var.compartment_id
  display_name               = "${var.label_prefix}-lb"
  shape                      = "flexible"
  subnet_ids                 = [var.lb_subnet_id]
  network_security_group_ids = var.lb_nsg_ids
  is_private                 = var.is_private
  freeform_tags              = merge(var.freeform_tags, { pscloud_component = "app-lb" })

  shape_details {
    minimum_bandwidth_in_mbps = var.lb_bandwidth_mbps.minimum
    maximum_bandwidth_in_mbps = var.lb_bandwidth_mbps.maximum
  }
}

resource "oci_load_balancer_backend_set" "app" {
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = "${var.label_prefix}-bes-app"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = var.backend_port
    url_path          = var.health_check.url_path
    return_code       = var.health_check.return_code
    interval_ms       = var.health_check.interval_ms
    timeout_in_millis = var.health_check.timeout_ms
    retries           = var.health_check.retries
  }
}

resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "http"
  default_backend_set_name = oci_load_balancer_backend_set.app.name
  port                     = 80
  protocol                 = "HTTP"

  connection_configuration {
    idle_timeout_in_seconds = 60
  }
}

resource "oci_load_balancer_certificate" "this" {
  count = var.lb_certificate == null ? 0 : 1

  load_balancer_id   = oci_load_balancer_load_balancer.this.id
  certificate_name   = var.lb_certificate.certificate_name
  public_certificate = var.lb_certificate.public_certificate
  private_key        = var.lb_certificate.private_key
  ca_certificate     = var.lb_certificate.ca_certificate

  lifecycle {
    create_before_destroy = true
  }
}

resource "oci_load_balancer_listener" "https" {
  count = var.lb_certificate == null ? 0 : 1

  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "https"
  default_backend_set_name = oci_load_balancer_backend_set.app.name
  port                     = 443
  protocol                 = "HTTP"

  ssl_configuration {
    certificate_name        = oci_load_balancer_certificate.this[0].certificate_name
    verify_peer_certificate = false
  }

  connection_configuration {
    idle_timeout_in_seconds = 60
  }
}

resource "oci_load_balancer_backend_set" "grafana" {
  count = var.grafana_backend_ip == null ? 0 : 1

  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = "${var.label_prefix}-bes-grafana"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = var.grafana_backend_port
    url_path          = var.grafana_health_check.url_path
    return_code       = var.grafana_health_check.return_code
    interval_ms       = var.grafana_health_check.interval_ms
    timeout_in_millis = var.grafana_health_check.timeout_ms
    retries           = var.grafana_health_check.retries
  }
}

resource "oci_load_balancer_backend" "grafana" {
  count = var.grafana_backend_ip == null ? 0 : 1

  load_balancer_id = oci_load_balancer_load_balancer.this.id
  backendset_name  = oci_load_balancer_backend_set.grafana[0].name
  ip_address       = var.grafana_backend_ip
  port             = var.grafana_backend_port
}

resource "oci_load_balancer_listener" "grafana" {
  count = var.grafana_backend_ip == null ? 0 : 1

  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "grafana"
  default_backend_set_name = oci_load_balancer_backend_set.grafana[0].name
  port                     = var.grafana_listener_port
  protocol                 = "HTTP"

  connection_configuration {
    idle_timeout_in_seconds = 60
  }
}

resource "oci_core_instance_configuration" "baseline" {
  compartment_id = var.compartment_id
  display_name   = "${var.label_prefix}-ic-app-baseline"
  freeform_tags  = merge(var.freeform_tags, { pscloud_component = "app-ic" })

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id = var.compartment_id
      display_name   = "${var.label_prefix}-app"
      shape          = var.shape

      shape_config {
        ocpus         = var.ocpus
        memory_in_gbs = var.memory_in_gbs
      }

      source_details {
        source_type             = "image"
        image_id                = local.image_id
        boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
      }

      create_vnic_details {
        subnet_id        = var.app_subnet_id
        assign_public_ip = false
        nsg_ids          = var.app_nsg_ids
      }

      metadata = {
        ssh_authorized_keys = var.ssh_public_key
      }

      agent_config {
        are_all_plugins_disabled = false
        is_management_disabled   = false
        is_monitoring_disabled   = false

        plugins_config {
          name          = "Bastion"
          desired_state = "ENABLED"
        }
        plugins_config {
          name          = "Compute Instance Monitoring"
          desired_state = "ENABLED"
        }
      }

      defined_tags = var.defined_tags
    }
  }

  lifecycle {
    ignore_changes = [instance_details[0].launch_details[0].source_details[0].image_id]
  }
}

resource "oci_core_instance_pool" "app" {
  for_each = local.pools

  compartment_id            = var.compartment_id
  instance_configuration_id = oci_core_instance_configuration.baseline.id
  display_name              = "${var.label_prefix}-pool-${each.key}"
  size                      = each.key == "stable" ? var.pool_min_size : 0

  freeform_tags = merge(var.freeform_tags, {
    pscloud_component = "app-pool"
    pscloud_pool      = each.key
  })

  dynamic "placement_configurations" {
    for_each = each.value
    content {
      availability_domain = local.availability_domain
      primary_subnet_id   = var.app_subnet_id
      fault_domains       = [placement_configurations.value]
    }
  }

  load_balancers {
    backend_set_name = oci_load_balancer_backend_set.app.name
    load_balancer_id = oci_load_balancer_load_balancer.this.id
    port             = var.backend_port
    vnic_selection   = "PrimaryVnic"
  }

  lifecycle_management {
    lifecycle_actions {
      pre_termination {
        is_enabled = true
        timeout    = var.drain_timeout_seconds

        on_timeout {
          preserve_boot_volume_mode  = "DELETE"
          preserve_block_volume_mode = "DELETE"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [size, instance_configuration_id]
  }
}

resource "oci_autoscaling_auto_scaling_configuration" "app" {
  count = var.autoscaling == null ? 0 : 1

  compartment_id       = var.compartment_id
  display_name         = "${var.label_prefix}-as-app"
  cool_down_in_seconds = var.autoscaling.cool_down_in_seconds
  is_enabled           = var.autoscaling.is_enabled
  freeform_tags        = merge(var.freeform_tags, { pscloud_component = "app-autoscaling" })

  auto_scaling_resources {
    id   = oci_core_instance_pool.app["stable"].id
    type = "instancePool"
  }

  policies {
    display_name = "cpu"
    policy_type  = "threshold"

    capacity {
      initial = var.pool_min_size
      min     = var.pool_min_size
      max     = var.pool_max_size
    }

    rules {
      display_name = "scale-out"

      action {
        type  = "CHANGE_COUNT_BY"
        value = var.autoscaling.step
      }

      metric {
        metric_type      = "CPU_UTILIZATION"
        pending_duration = var.autoscaling.pending_duration

        threshold {
          operator = "GT"
          value    = var.autoscaling.scale_out_cpu
        }
      }
    }

    rules {
      display_name = "scale-in"

      action {
        type  = "CHANGE_COUNT_BY"
        value = -var.autoscaling.step
      }

      metric {
        metric_type      = "CPU_UTILIZATION"
        pending_duration = var.autoscaling.pending_duration

        threshold {
          operator = "LT"
          value    = var.autoscaling.scale_in_cpu
        }
      }
    }
  }
}
