output "kafka_service_uri" {
  description = "Kafka service URI for connection"
  value       = aiven_kafka.kafka.service_uri
  sensitive   = true
}

output "kafka_service_name" {
  description = "Kafka service name"
  value       = aiven_kafka.kafka.service_name
}

output "kafka_service_id" {
  description = "Kafka service ID"
  value       = aiven_kafka.kafka.id
}

output "aiven_vpc_id" {
  description = "Aiven Project VPC ID"
  value       = aiven_project_vpc.main.id
}

output "aiven_vpc_cidr" {
  description = "Aiven Project VPC CIDR block"
  value       = aiven_project_vpc.main.network_cidr
}

output "google_service_attachment" {
  description = "Google Cloud Service Attachment URL from Aiven"
  value       = aiven_gcp_privatelink.psc.google_service_attachment
}

output "psc_endpoint_ip" {
  description = "IP address of the PSC endpoint in GCP"
  value       = google_compute_forwarding_rule.psc_endpoint.ip_address
}

output "psc_forwarding_rule_name" {
  description = "Name of the PSC forwarding rule"
  value       = google_compute_forwarding_rule.psc_endpoint.name
}

output "psc_forwarding_rule_id" {
  description = "ID of the PSC forwarding rule"
  value       = google_compute_forwarding_rule.psc_endpoint.id
}

output "psc_subnet_name" {
  description = "Name of the PSC subnet"
  value       = google_compute_subnetwork.psc.name
}

output "psc_subnet_cidr" {
  description = "CIDR block of the PSC subnet"
  value       = google_compute_subnetwork.psc.ip_cidr_range
}

output "connection_state" {
  description = "State of the PSC connection"
  value       = google_compute_forwarding_rule.psc_endpoint.psc_connection_status
}

output "kafka_hosts" {
  description = "Kafka service hostname (public)"
  value       = aiven_kafka.kafka.service_host
}

output "privatelink_host" {
  description = "Kafka privatelink hostname (use this for PSC connections)"
  value       = local.privatelink_host
}

output "privatelink_port" {
  description = "Kafka privatelink port"
  value       = local.privatelink_port
}

output "privatelink_uri" {
  description = "Full privatelink connection URI"
  value       = "${local.privatelink_host}:${local.privatelink_port}"
}

output "kafka_username" {
  description = "Kafka service username (SASL)"
  value       = aiven_kafka.kafka.service_username
}

output "kafka_password" {
  description = "Kafka service password (SASL)"
  value       = aiven_kafka.kafka.service_password
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Demo topic
# -----------------------------------------------------------------------------

output "demo_topic_name" {
  description = "Demo topic that the test VM producer writes to"
  value       = aiven_kafka_topic.demo_topic.topic_name
}

# -----------------------------------------------------------------------------
# Test VM (only when enable_test_vm = true)
# -----------------------------------------------------------------------------

output "vm_name" {
  description = "Name of the PSC test VM"
  value       = try(google_compute_instance.test_vm[0].name, null)
}

output "vm_zone" {
  description = "Zone of the PSC test VM"
  value       = try(google_compute_instance.test_vm[0].zone, null)
}

output "vm_internal_ip" {
  description = "Internal IP of the PSC test VM"
  value       = try(google_compute_instance.test_vm[0].network_interface[0].network_ip, null)
}

output "vm_external_ip" {
  description = "External IP of the PSC test VM (null if vm_enable_public_ip = false)"
  value       = try(google_compute_instance.test_vm[0].network_interface[0].access_config[0].nat_ip, null)
}

output "ssh_command" {
  description = "Example gcloud command to SSH to the test VM"
  value       = var.enable_test_vm ? "gcloud compute ssh kafka-psc-test-vm --zone=${var.gcp_zone} --project=${var.gcp_project_id}${var.vm_enable_public_ip ? "" : " --tunnel-through-iap"}" : null
}
