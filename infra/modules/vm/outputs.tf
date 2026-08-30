output "instance_id" { value = oci_core_instance.this.id }
output "private_ip" { value = oci_core_instance.this.private_ip }
output "public_ip" { value = oci_core_instance.this.public_ip }
output "image_id" { value = data.oci_core_images.os.images[0].id }
output "data_volume_id" { value = try(oci_core_volume.data[0].id, null) }
