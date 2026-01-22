# =============================================================================
# Required Variables (no defaults - must be provided)
# =============================================================================

variable "aiven_token" {
  description = "Aiven API token for authentication. Set via TF_VAR_aiven_token environment variable."
  type        = string
  sensitive   = true
}

variable "aiven_project" {
  description = "Aiven project name where resources will be created"
  type        = string
}

variable "gcp_project_id" {
  description = "Google Cloud Platform project ID"
  type        = string
}

variable "gcp_network_name" {
  description = "Name of the existing GCP VPC network"
  type        = string
}

variable "kafka_service_name" {
  description = "Name of the Aiven Kafka service"
  type        = string
}

# =============================================================================
# Optional Variables (have sensible defaults)
# =============================================================================

variable "gcp_region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone for the test VM"
  type        = string
  default     = "us-central1-a"
}

variable "kafka_plan" {
  description = "Aiven service plan for Kafka"
  type        = string
  default     = "business-4"
}

variable "kafka_cloud_name" {
  description = "Aiven cloud name where Kafka service will be deployed"
  type        = string
  default     = "google-us-central1"
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------

variable "aiven_vpc_cidr" {
  description = "CIDR block for the Aiven Project VPC"
  type        = string
  default     = "10.10.0.0/24"
}

variable "psc_subnet_cidr" {
  description = "CIDR block for the GCP Private Service Connect subnet"
  type        = string
  default     = "10.100.0.0/24"
}

variable "vm_subnet_cidr" {
  description = "CIDR for the VM subnet (must not overlap with psc_subnet_cidr or existing subnets)"
  type        = string
  default     = "10.100.1.0/24"
}

# -----------------------------------------------------------------------------
# Test VM Configuration
# -----------------------------------------------------------------------------

variable "enable_test_vm" {
  description = "Create a GCP VM in the VPC for testing PSC connectivity to Kafka"
  type        = bool
  default     = true
}

variable "vm_machine_type" {
  description = "Machine type for the test VM"
  type        = string
  default     = "e2-micro"
}

variable "vm_enable_public_ip" {
  description = "Assign a public IP to the test VM for direct SSH (if false, use --tunnel-through-iap)"
  type        = bool
  default     = true
}

variable "ssh_public_key" {
  description = "Optional SSH public key for the ubuntu user (if not set, use OS Login with gcloud compute ssh)"
  type        = string
  default     = null
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Demo Topic and Producer Configuration
# -----------------------------------------------------------------------------

variable "demo_topic_name" {
  description = "Kafka topic name used for the PSC demo producer"
  type        = string
  default     = "demo-topic"
}

variable "demo_topic_partitions" {
  description = "Number of partitions for the demo topic"
  type        = number
  default     = 3
}

variable "demo_topic_replication" {
  description = "Replication factor for the demo topic (must be <= number of Kafka brokers)"
  type        = number
  default     = 2
}

variable "enable_demo_producer" {
  description = "Enable a systemd service on the test VM that continuously produces demo messages"
  type        = bool
  default     = true
}

variable "demo_producer_interval_seconds" {
  description = "Seconds between demo messages produced by the VM"
  type        = number
  default     = 2
}

variable "demo_producer_message_prefix" {
  description = "Prefix string included in each demo message payload"
  type        = string
  default     = "psc-demo"
}
