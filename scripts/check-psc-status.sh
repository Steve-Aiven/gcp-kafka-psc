#!/bin/bash
# check-psc-status.sh - Check PSC connectivity status from the test VM
#
# Usage: ./scripts/check-psc-status.sh [--consume N]
#   --consume N  Also consume N messages from the demo topic (default: skip)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CONSUME_COUNT=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --consume)
      CONSUME_COUNT="${2:-5}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--consume N]"
      exit 1
      ;;
  esac
done

# Get terraform outputs
cd "$(dirname "$0")/../terraform"

echo "=========================================="
echo "Fetching Terraform outputs..."
echo "=========================================="

VM_NAME=$(terraform output -raw vm_name 2>/dev/null || echo "")
VM_ZONE=$(terraform output -raw vm_zone 2>/dev/null || echo "")
GCP_PROJECT=$(terraform output -raw psc_forwarding_rule_id 2>/dev/null | cut -d'/' -f2 || echo "")
PSC_IP=$(terraform output -raw psc_endpoint_ip 2>/dev/null || echo "")
PRIVATELINK_HOST=$(terraform output -raw privatelink_host 2>/dev/null || echo "")
PRIVATELINK_PORT=$(terraform output -raw privatelink_port 2>/dev/null || echo "9706")
CONNECTION_STATE=$(terraform output -raw connection_state 2>/dev/null || echo "UNKNOWN")
DEMO_TOPIC=$(terraform output -raw demo_topic_name 2>/dev/null || echo "psc-demo-topic")

if [[ -z "$VM_NAME" || -z "$VM_ZONE" || -z "$GCP_PROJECT" ]]; then
  echo -e "${RED}Error: Could not get VM details from Terraform outputs${NC}"
  echo "Make sure you've run 'terraform apply' first"
  exit 1
fi

echo ""
echo "Configuration:"
echo "  VM: $VM_NAME (zone: $VM_ZONE, project: $GCP_PROJECT)"
echo "  PSC IP: $PSC_IP"
echo "  Privatelink Host: $PRIVATELINK_HOST"
echo "  Privatelink Port: $PRIVATELINK_PORT"
echo "  Connection State: $CONNECTION_STATE"
echo "  Demo Topic: $DEMO_TOPIC"
echo ""

# Check PSC connection state
echo "=========================================="
echo "1. PSC Connection State"
echo "=========================================="
if [[ "$CONNECTION_STATE" == "ACCEPTED" ]]; then
  echo -e "${GREEN}✓ PSC connection is ACCEPTED${NC}"
else
  echo -e "${RED}✗ PSC connection state: $CONNECTION_STATE${NC}"
  echo "  The connection needs to be approved. Run 'terraform apply' to create the approval resource."
fi
echo ""

# SSH into VM and run checks
echo "=========================================="
echo "2. Connecting to VM and running checks..."
echo "=========================================="

# Build the remote script
REMOTE_SCRIPT=$(cat <<'SCRIPT'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PSC_IP="__PSC_IP__"
PRIVATELINK_HOST="__PRIVATELINK_HOST__"
PRIVATELINK_PORT="__PRIVATELINK_PORT__"
DEMO_TOPIC="__DEMO_TOPIC__"
CONSUME_COUNT="__CONSUME_COUNT__"

echo ""
echo "--- /etc/hosts mapping ---"
if grep -q "$PRIVATELINK_HOST" /etc/hosts; then
  echo -e "${GREEN}✓ Privatelink hostname is mapped in /etc/hosts${NC}"
  grep "$PRIVATELINK_HOST" /etc/hosts
else
  echo -e "${RED}✗ Privatelink hostname NOT found in /etc/hosts${NC}"
  echo "  Current /etc/hosts entries:"
  cat /etc/hosts
fi
echo ""

echo "--- TCP Connectivity ---"
if nc -zv "$PSC_IP" "$PRIVATELINK_PORT" -w 5 2>&1 | grep -q succeeded; then
  echo -e "${GREEN}✓ TCP connection to $PSC_IP:$PRIVATELINK_PORT succeeded${NC}"
else
  echo -e "${RED}✗ TCP connection to $PSC_IP:$PRIVATELINK_PORT failed${NC}"
fi
echo ""

echo "--- TLS Handshake ---"
TLS_RESULT=$(echo | openssl s_client -connect "$PSC_IP:$PRIVATELINK_PORT" -servername "$PRIVATELINK_HOST" 2>&1)
if echo "$TLS_RESULT" | grep -q "Verify return code: 0"; then
  echo -e "${GREEN}✓ TLS handshake successful${NC}"
elif echo "$TLS_RESULT" | grep -q "BEGIN CERTIFICATE"; then
  echo -e "${GREEN}✓ TLS handshake successful (certificate received)${NC}"
else
  echo -e "${RED}✗ TLS handshake failed${NC}"
  echo "$TLS_RESULT" | head -10
fi
echo ""

echo "--- Kafka Producer Service ---"
SERVICE_STATUS=$(systemctl is-active kafka-demo-producer.service 2>/dev/null || echo "inactive")
if [[ "$SERVICE_STATUS" == "active" ]]; then
  echo -e "${GREEN}✓ kafka-demo-producer.service is running${NC}"
else
  echo -e "${YELLOW}○ kafka-demo-producer.service is $SERVICE_STATUS${NC}"
fi

# Show recent logs
echo ""
echo "--- Recent Producer Logs (last 5 lines) ---"
sudo journalctl -u kafka-demo-producer.service -n 5 --no-pager 2>/dev/null || echo "No logs available"
echo ""

# Optionally consume messages
if [[ "$CONSUME_COUNT" -gt 0 ]]; then
  echo "--- Consuming $CONSUME_COUNT messages from $DEMO_TOPIC ---"
  if [[ -f /etc/kafka/certs/ca.pem ]]; then
    timeout 10 sudo kafkacat -b "$PRIVATELINK_HOST:$PRIVATELINK_PORT" -t "$DEMO_TOPIC" -C \
      -X security.protocol=SSL \
      -X ssl.ca.location=/etc/kafka/certs/ca.pem \
      -X ssl.certificate.location=/etc/kafka/certs/access.crt \
      -X ssl.key.location=/etc/kafka/certs/access.key \
      -o beginning -c "$CONSUME_COUNT" 2>/dev/null || echo -e "${YELLOW}No messages or connection failed${NC}"
  else
    echo -e "${RED}✗ Certificates not found at /etc/kafka/certs/${NC}"
  fi
  echo ""
fi

echo "--- Summary ---"
echo "PSC connectivity check complete."
SCRIPT
)

# Substitute variables
REMOTE_SCRIPT="${REMOTE_SCRIPT//__PSC_IP__/$PSC_IP}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__PRIVATELINK_HOST__/$PRIVATELINK_HOST}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__PRIVATELINK_PORT__/$PRIVATELINK_PORT}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__DEMO_TOPIC__/$DEMO_TOPIC}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__CONSUME_COUNT__/$CONSUME_COUNT}"

# Execute on VM
gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE" --project="$GCP_PROJECT" --command="$REMOTE_SCRIPT"

echo ""
echo "=========================================="
echo "Check complete!"
echo "=========================================="
