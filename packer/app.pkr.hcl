packer {
  required_plugins {
    oracle = {
      source  = "github.com/hashicorp/oracle"
      version = "~> 1.1"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1"
    }
  }
}

variable "compartment_ocid" { type = string }
variable "subnet_ocid" { type = string }
variable "nsg_ocid" { type = string }
variable "availability_domain" { type = string }

variable "base_os_version" {
  type    = string
  default = "24.04"
}

variable "shape" {
  type    = string
  default = "VM.Standard.E4.Flex"
}

variable "ocpus" {
  type    = number
  default = 1
}

variable "memory_in_gbs" {
  type    = number
  default = 6
}

variable "release_id" {
  type    = string
  default = ""
}

# Which environment's manifest the image is built from. The image is a
# function of this repository plus that manifest -- never a snapshot of a
# machine that has served traffic.
variable "manifest_env" {
  type    = string
  default = "prod"
}

# Bake the applications in. false produces a base-layer-only image: the
# runtimes, nginx, the agent and the unit files, with no application code.
variable "bake_apps" {
  type    = bool
  default = true
}

locals {
  release = var.release_id != "" ? var.release_id : formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "oracle-oci" "app" {
  availability_domain     = var.availability_domain
  compartment_ocid        = var.compartment_ocid
  subnet_ocid             = var.subnet_ocid
  use_private_ip          = true
  create_vnic_details {
    nsg_ids = [var.nsg_ocid]
  }

  shape = var.shape
  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  base_image_filter {
    operating_system         = "Canonical Ubuntu"
    operating_system_version = var.base_os_version
    shape                    = var.shape
  }

  ssh_username = "ubuntu"

  image_name = "pscloud-app-${local.release}"

  tags = {
    pscloud_family   = "app"
    pscloud_built_by = "packer"
    pscloud_release  = local.release
    pscloud_base_os  = var.base_os_version
    # Which manifest went in. `image prune` protects images an instance pool
    # references; this is what lets a human tell two builds apart.
    pscloud_manifest = var.manifest_env
    pscloud_has_apps = tostring(var.bake_apps)
  }

  instance_tags = {
    pscloud_built_by = "packer"
  }
}

build {
  sources = ["source.oracle-oci.app"]

  provisioner "shell" {
    inline = [
      "cloud-init status --wait || true",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt",
    ]
  }

  provisioner "ansible" {
    playbook_file = "${path.root}/../ansible/image.yml"
    user          = "ubuntu"
    extra_arguments = [
      "--extra-vars",
      "packer_build=true release_id=${local.release} image_manifest_env=${var.manifest_env} image_bake_apps=${var.bake_apps}",
      "--scp-extra-args", "-O",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
    custom_data = {
      release = local.release
    }
  }
}
