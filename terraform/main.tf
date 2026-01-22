# ============================================================================
# Aiven Resources
# ============================================================================

# Get the existing Aiven project
data "aiven_project" "main" {
  project = var.aiven_project
}

# Create Aiven Project VPC in Google Cloud
resource "aiven_project_vpc" "main" {
  project      = data.aiven_project.main.project
  cloud_name   = var.kafka_cloud_name
  network_cidr = var.aiven_vpc_cidr

  lifecycle {
    create_before_destroy = true
  }
}

# Create Kafka service with Private Service Connect enabled
resource "aiven_kafka" "kafka" {
  project      = data.aiven_project.main.project
  cloud_name   = var.kafka_cloud_name
  plan         = var.kafka_plan
  service_name = var.kafka_service_name

  # Enable Private Service Connect for Kafka (v4 provider uses kafka_user_config block)
  kafka_user_config {
    privatelink_access {
      kafka = true
    }
    # Enable SASL authentication (username/password) for simpler demo
    kafka_authentication_methods {
      sasl = true
    }
  }

  # Kafka service must be created in the VPC
  project_vpc_id = aiven_project_vpc.main.id

  # Wait for service to be running before proceeding
  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    aiven_project_vpc.main
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Demo topic (messages are produced by the test VM when enable_demo_producer=true)
# -----------------------------------------------------------------------------
resource "aiven_kafka_topic" "demo_topic" {
  project      = data.aiven_project.main.project
  service_name = aiven_kafka.kafka.service_name
  topic_name   = var.demo_topic_name
  partitions   = var.demo_topic_partitions
  replication  = var.demo_topic_replication
}

# ============================================================================
# GCP Resources
# ============================================================================

# Get the existing GCP VPC network
data "google_compute_network" "main" {
  name    = var.gcp_network_name
  project = var.gcp_project_id
}

# Create PSC subnet in the existing GCP VPC network
# This subnet is dedicated for Private Service Connect endpoints
# Note: This subnet cannot be used for regular compute instances
resource "google_compute_subnetwork" "psc" {
  name          = "psc-subnet1"
  ip_cidr_range = var.psc_subnet_cidr
  region        = var.gcp_region
  network       = data.google_compute_network.main.id
  purpose       = "PRIVATE_SERVICE_CONNECT"

  description = "Subnet for Private Service Connect endpoints"
}

# ============================================================================
# PSC Connection Setup
# ============================================================================

# Data source to fetch Kafka service details after privatelink is set up
# This allows us to get the privatelink-specific hostname and port
data "aiven_kafka" "kafka_privatelink" {
  project      = data.aiven_project.main.project
  service_name = aiven_kafka.kafka.service_name

  depends_on = [
    aiven_gcp_privatelink.psc,
    aiven_gcp_privatelink_connection_approval.psc_approval
  ]
}

# PrivateLink endpoint configuration
# Extract the privatelink component which has the correct hostname for PSC connections
locals {
  # Find the privatelink component with certificate authentication
  privatelink_component = try(
    [for c in data.aiven_kafka.kafka_privatelink.components : c 
     if c.route == "privatelink" && try(c.kafka_authentication_method, "") == "certificate"][0],
    null
  )
  # Privatelink hostname (e.g., privatelink-kafka-xxx.g.aivencloud.com)
  privatelink_host = try(local.privatelink_component.host, aiven_kafka.kafka.service_host)
  # Privatelink port (typically 9706)
  privatelink_port = try(local.privatelink_component.port, 9706)
}

# Enable GCP Private Service Connect on the Kafka service
# This creates the service attachment on the Aiven side
resource "aiven_gcp_privatelink" "psc" {
  project      = data.aiven_project.main.project
  service_name = aiven_kafka.kafka.service_name

  depends_on = [aiven_kafka.kafka]
}

# Reserve an IP address for the PSC endpoint in the VM subnet
# Note: PSC subnets cannot be used for address reservation, so we use the VM subnet
resource "google_compute_address" "psc_endpoint" {
  name         = "${var.kafka_service_name}-psc-ip"
  project      = var.gcp_project_id
  region       = var.gcp_region
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
  subnetwork   = google_compute_subnetwork.vm.id
  address      = cidrhost(var.vm_subnet_cidr, 10)

  description = "IP address for PSC endpoint to Aiven Kafka"
}

# Create GCP Private Service Connect forwarding rule (endpoint)
# This creates the endpoint in GCP that connects to Aiven's service attachment
resource "google_compute_forwarding_rule" "psc_endpoint" {
  name                  = "${var.kafka_service_name}-psc-endpoint"
  project               = var.gcp_project_id
  region                = var.gcp_region
  network               = data.google_compute_network.main.id
  ip_address            = google_compute_address.psc_endpoint.self_link
  target                = aiven_gcp_privatelink.psc.google_service_attachment
  load_balancing_scheme = ""

  # PSC-specific settings
  allow_psc_global_access = false

  description = "Private Service Connect endpoint for Aiven Kafka service"

  depends_on = [
    aiven_gcp_privatelink.psc,
    google_compute_address.psc_endpoint
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# Approve the PSC connection from the GCP project
# This is required - Aiven does NOT auto-approve PSC connections
resource "aiven_gcp_privatelink_connection_approval" "psc_approval" {
  project      = data.aiven_project.main.project
  service_name = aiven_kafka.kafka.service_name
  user_ip_address = google_compute_address.psc_endpoint.address

  depends_on = [
    aiven_gcp_privatelink.psc,
    google_compute_forwarding_rule.psc_endpoint
  ]
}

# ============================================================================
# Test VM for PSC connectivity
# ============================================================================
# VM subnet (general compute; PSC subnet cannot host VMs)
resource "google_compute_subnetwork" "vm" {
  name          = "vm-subnet-psc-test"
  ip_cidr_range = var.vm_subnet_cidr
  region        = var.gcp_region
  network       = data.google_compute_network.main.id

  description = "Subnet for test VM to validate PSC connectivity to Kafka"
}

# Firewall: SSH from IAP and from anywhere (for direct SSH when VM has public IP)
resource "google_compute_firewall" "ssh_vm" {
  name    = "allow-ssh-kafka-psc-test-vm"
  network = data.google_compute_network.main.id
  project = var.gcp_project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0", "35.235.240.0/20"] # 35.235.240.0/20 = IAP
  target_tags   = ["kafka-psc-test-vm"]
}

# Test VM: same VPC as PSC, startup script installs kafkacat and /etc/hosts for Kafka
resource "google_compute_instance" "test_vm" {
  count        = var.enable_test_vm ? 1 : 0
  name         = "kafka-psc-test-vm"
  machine_type = var.vm_machine_type
  zone         = var.gcp_zone
  project      = var.gcp_project_id

  tags = ["kafka-psc-test-vm"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    network    = data.google_compute_network.main.id
    subnetwork = google_compute_subnetwork.vm.id

    dynamic "access_config" {
      for_each = var.vm_enable_public_ip ? [1] : []
      content {}
    }
  }

  metadata = merge(
    {
      "enable-oslogin" = "TRUE"
      "psc-ip"         = google_compute_forwarding_rule.psc_endpoint.ip_address
      # Use PrivateLink hostname and port (different from public endpoint)
      "kafka-hosts"    = local.privatelink_host
      "kafka-port"     = tostring(local.privatelink_port)
      "kafka-uri"      = "${local.privatelink_host}:${local.privatelink_port}"
      # Certificate-based authentication for Kafka PrivateLink
      "kafka-ca-cert"     = data.aiven_project.main.ca_cert
      "kafka-access-cert" = aiven_kafka.kafka.kafka[0].access_cert
      "kafka-access-key"  = aiven_kafka.kafka.kafka[0].access_key

      "demo-topic"             = var.demo_topic_name
      "demo-producer-enabled"  = var.enable_demo_producer ? "true" : "false"
      "demo-producer-interval" = tostring(var.demo_producer_interval_seconds)
      "demo-producer-prefix"   = var.demo_producer_message_prefix

      "startup-script" = <<-EOF
        #!/bin/bash
        # Install kafkacat/kcat for testing Kafka over PSC
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y kafkacat 2>/dev/null || apt-get install -y kcat 2>/dev/null || true

        # Resolve Kafka hostnames to PSC endpoint IP (for TLS SNI and connectivity)
        PSC_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/psc-ip" -H "Metadata-Flavor: Google")
        KAFKA_HOSTS=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/kafka-hosts" -H "Metadata-Flavor: Google")
        if [ -n "$PSC_IP" ] && [ -n "$KAFKA_HOSTS" ]; then
          for h in $KAFKA_HOSTS; do
            grep -qF "$h" /etc/hosts || echo "$PSC_IP $h" >> /etc/hosts
          done
        fi

        # Write Aiven certificates for mTLS authentication (PrivateLink requires certificates)
        mkdir -p /etc/kafka/certs
        MD_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
        MH="Metadata-Flavor: Google"
        curl -sf "$MD_URL/kafka-ca-cert" -H "$MH" > /etc/kafka/certs/ca.pem
        curl -sf "$MD_URL/kafka-access-cert" -H "$MH" > /etc/kafka/certs/access.crt
        curl -sf "$MD_URL/kafka-access-key" -H "$MH" > /etc/kafka/certs/access.key
        chmod 644 /etc/kafka/certs/ca.pem /etc/kafka/certs/access.crt
        chmod 600 /etc/kafka/certs/access.key

        # Install an always-on demo producer (systemd) that writes messages to the demo topic
        cat >/usr/local/bin/kafka-demo-producer.sh <<'SCRIPT'
        #!/bin/bash
        set -e

        MD="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
        H="Metadata-Flavor: Google"

        enabled=$(curl -sf "$MD/demo-producer-enabled" -H "$H" || true)
        [ "$enabled" = "true" ] || exit 0

        topic=$(curl -sf "$MD/demo-topic" -H "$H" || echo "psc-demo-topic")
        interval=$(curl -sf "$MD/demo-producer-interval" -H "$H" || echo "2")
        prefix=$(curl -sf "$MD/demo-producer-prefix" -H "$H" || echo "psc-demo")
        uri=$(curl -sf "$MD/kafka-uri" -H "$H" || true)
        bootstrap=$(echo "$uri" | sed 's|^kafka://||;s|/.*||')

        if command -v kafkacat >/dev/null 2>&1; then
          KCAT="kafkacat"
        elif command -v kcat >/dev/null 2>&1; then
          KCAT="kcat"
        else
          echo "kafkacat/kcat not installed"
          exit 1
        fi

        # Certificate paths for mTLS authentication (required for PrivateLink)
        CA_CERT="/etc/kafka/certs/ca.pem"
        CLIENT_CERT="/etc/kafka/certs/access.crt"
        CLIENT_KEY="/etc/kafka/certs/access.key"

        while true; do
          msg="{\"ts\":\"$(date -Is)\",\"host\":\"$(hostname)\",\"msg\":\"$${prefix}\"}"
          echo "$msg" | $KCAT -b "$bootstrap" -t "$topic" -P \
            -X security.protocol=SSL \
            -X ssl.ca.location="$CA_CERT" \
            -X ssl.certificate.location="$CLIENT_CERT" \
            -X ssl.key.location="$CLIENT_KEY" || true
          sleep "$interval"
        done
SCRIPT

        # Strip leading whitespace from heredoc
        sed -i 's/^        //' /usr/local/bin/kafka-demo-producer.sh
        chmod +x /usr/local/bin/kafka-demo-producer.sh

        cat >/etc/systemd/system/kafka-demo-producer.service <<'UNIT'
        [Unit]
        Description=Kafka demo producer (PSC)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        ExecStart=/usr/local/bin/kafka-demo-producer.sh
        Restart=always
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
UNIT

        # Strip leading whitespace from heredoc
        sed -i 's/^        //' /etc/systemd/system/kafka-demo-producer.service
        systemctl daemon-reload
        systemctl enable --now kafka-demo-producer.service || true
      EOF
    },
    var.ssh_public_key != null ? { "ssh-keys" = "ubuntu:${var.ssh_public_key}" } : {}
  )

  depends_on = [
    google_compute_subnetwork.vm,
    google_compute_firewall.ssh_vm,
    google_compute_forwarding_rule.psc_endpoint,
    aiven_kafka_topic.demo_topic
  ]
}
