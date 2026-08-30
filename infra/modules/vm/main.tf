locals {
  user_data = templatefile("${path.module}/../cloud-init/common.yaml.tftpl", {
    hostname              = var.name
    dns_domain            = var.dns_domain
    role                  = var.role
    allow_port            = var.allow_port
    tag_namespace         = var.tag_namespace
    install_base_packages = true
  })
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_id
}

locals {
  availability_domain = coalesce(
    var.availability_domain,
    data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name,
  )
}

data "oci_core_images" "os" {
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

data "oci_core_volume_backup_policies" "oracle" {
  count = var.backup_policy == "none" ? 0 : 1

  filter {
    name   = "display_name"
    values = [var.backup_policy]
  }
}

resource "oci_core_instance" "this" {
  compartment_id      = var.compartment_id
  display_name        = var.name
  availability_domain = local.availability_domain
  fault_domain        = var.fault_domain
  shape               = var.shape

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.os.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
    boot_volume_vpus_per_gb = var.boot_volume_vpus_per_gb
  }

  create_vnic_details {
    subnet_id                 = var.subnet_id
    assign_public_ip          = var.assign_public_ip
    assign_private_dns_record = true
    hostname_label            = replace(var.name, "/[^a-zA-Z0-9]/", "")
    private_ip                = var.private_ip
    nsg_ids                   = var.nsg_ids
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.user_data)
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

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags

  lifecycle {
    ignore_changes = [source_details[0].source_id, defined_tags]
  }
}

resource "oci_core_volume" "data" {
  count = var.data_volume == null ? 0 : 1

  compartment_id      = var.compartment_id
  availability_domain = local.availability_domain
  display_name        = "${var.name}-data"
  size_in_gbs         = var.data_volume.size_in_gbs
  vpus_per_gb         = var.data_volume.vpus_per_gb

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_core_volume_attachment" "data" {
  count = var.data_volume == null ? 0 : 1

  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.this.id
  volume_id       = oci_core_volume.data[0].id
  display_name    = "${var.name}-data-attach"
}

resource "oci_core_volume_backup_policy_assignment" "boot" {
  count = var.backup_policy == "none" ? 0 : 1

  asset_id  = oci_core_instance.this.boot_volume_id
  policy_id = data.oci_core_volume_backup_policies.oracle[0].volume_backup_policies[0].id
}

resource "oci_core_volume_backup_policy_assignment" "data" {
  count = var.backup_policy == "none" || var.data_volume == null ? 0 : 1

  asset_id  = oci_core_volume.data[0].id
  policy_id = data.oci_core_volume_backup_policies.oracle[0].volume_backup_policies[0].id
}
