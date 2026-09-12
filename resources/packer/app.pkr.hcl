# Golden image for the application layer.
#
# The build does nothing itself: it boots a stock Ubuntu, hands the instance to
# ansible/image.yml, and captures the result. Every decision about what goes on
# the machine lives in Ansible.
#
#   cd packer && packer init . && packer build app.pkr.hcl
#
# Run it from the monitoring VM: its instance principal is what mints the
# artifact download URLs, and it is already the Ansible executor.

packer {
  required_plugins {
    oracle  = { source = "github.com/hashicorp/oracle", version = "~> 1.1" }
    ansible = { source = "github.com/hashicorp/ansible", version = "~> 1.1" }
  }
}

variable "compartment_ocid" {
  type    = string
  default = env("OCI_COMPARTMENT_OCID")
}

variable "subnet_ocid" {
  type    = string
  default = env("OCI_SUBNET_OCID")
}

variable "availability_domain" {
  type    = string
  default = env("OCI_AVAILABILITY_DOMAIN")
}

# Which environment's manifest the applications come from. The image is a
# function of this repository plus that manifest.
variable "manifest_env" {
  type    = string
  default = "prod"
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

locals {
  release = formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "oracle-oci" "app" {
  compartment_ocid    = var.compartment_ocid
  availability_domain = var.availability_domain
  subnet_ocid         = var.subnet_ocid
  use_private_ip      = true

  shape = var.shape
  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  base_image_filter {
    operating_system         = "Canonical Ubuntu"
    operating_system_version = "24.04"
    shape                    = var.shape
  }

  ssh_username = "ubuntu"
  image_name   = "pscloud-app-${local.release}"

  # `pscloud images` lists on these, and `pscloud image-prune` protects what an
  # instance pool references.
  tags = {
    pscloud_family   = "app"
    pscloud_built_by = "packer"
    pscloud_release  = local.release
    pscloud_manifest = var.manifest_env
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
      "--extra-vars", "app_env=${var.manifest_env} app_release_tag=${local.release}",
      "--scp-extra-args", "-O",
    ]
  }

  post-processor "manifest" {
    output      = "${path.root}/manifest.json"
    strip_path  = true
    custom_data = { release = local.release }
  }
}
