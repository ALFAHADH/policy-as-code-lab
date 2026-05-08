output "vpc_name" {
  value = google_compute_network.lab_vpc.name
}

output "bucket_name" {
  value = google_storage_bucket.lab_bucket.name
}

output "vm_name" {
  value = google_compute_instance.lab_vm.name
}


/*
output "vm_public_ip" {
  value = google_compute_instance.lab_vm.network_interface[0].access_config[0].nat_ip
}
*/
