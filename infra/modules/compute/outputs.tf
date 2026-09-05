output "instance_ids" {
  value = { for key, instance in oci_core_instance.this : key => instance.id }
}

output "private_ips" {
  value = { for key, instance in oci_core_instance.this : key => instance.private_ip }
}

output "public_ips" {
  value = { for key, instance in oci_core_instance.this : key => instance.public_ip }
}

output "image_id" { value = local.image_id }
