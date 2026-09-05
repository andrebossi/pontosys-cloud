data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_id
}

data "oci_core_images" "this" {
  count = var.image_id == null ? 1 : 0

  compartment_id           = var.compartment_id
  operating_system         = var.image_os
  operating_system_version = var.image_os_version
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = ["^((?!Minimal|GPU).)*$"]
    regex  = true
  }
}

locals {
  availability_domains = [for ad in data.oci_identity_availability_domains.this.availability_domains : ad.name]
  image_id             = var.image_id != null ? var.image_id : data.oci_core_images.this[0].images[0].id
}

resource "oci_core_instance" "this" {
  for_each = var.instances

  compartment_id      = var.compartment_id
  display_name        = "${var.name}-${each.key}"
  availability_domain = element(local.availability_domains, lookup(each.value, "availability_domain_index", 0))
  fault_domain        = lookup(each.value, "fault_domain", null)
  shape               = lookup(each.value, "shape", var.shape)

  shape_config {
    ocpus         = lookup(each.value, "ocpus", var.ocpus)
    memory_in_gbs = lookup(each.value, "memory_in_gbs", var.memory_in_gbs)
  }

  source_details {
    source_type             = "image"
    source_id               = lookup(each.value, "image_id", local.image_id)
    boot_volume_size_in_gbs = lookup(each.value, "boot_volume_size_in_gbs", var.boot_volume_size_in_gbs)
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    nsg_ids          = var.nsg_ids
    assign_public_ip = lookup(each.value, "assign_public_ip", var.assign_public_ip)
    hostname_label   = replace("${var.name}${each.key}", "/[^a-zA-Z0-9]/", "")
    private_ip       = lookup(each.value, "private_ip", null)
  }

  metadata = merge(
    { ssh_authorized_keys = var.ssh_public_key },
    var.user_data == null ? {} : { user_data = base64encode(var.user_data) },
    lookup(each.value, "metadata", {}),
  )

  agent_config {
    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }

  freeform_tags = merge(var.freeform_tags, lookup(each.value, "freeform_tags", {}))
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [source_details[0].source_id, defined_tags]
  }
}

resource "oci_core_volume" "data" {
  for_each = { for key, instance in var.instances : key => instance if lookup(instance, "data_volume_size_in_gbs", 0) > 0 }

  compartment_id      = var.compartment_id
  availability_domain = oci_core_instance.this[each.key].availability_domain
  display_name        = "${var.name}-${each.key}-data"
  size_in_gbs         = each.value.data_volume_size_in_gbs
  vpus_per_gb         = lookup(each.value, "data_volume_vpus_per_gb", 10)

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_core_volume_attachment" "data" {
  for_each = oci_core_volume.data

  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.this[each.key].id
  volume_id       = each.value.id
}
