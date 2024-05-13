#!/bin/bash

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 1. Detect OS architecture
log "Checking system architecture..."
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]]; then
    error "Unsupported architecture: $ARCH. This script requires AMD64/x86_64 architecture."
fi
log "Architecture check passed: $ARCH"

# 2. Get Daytona API URL
if [[ -z "$API_URL" ]]; then
    read -p "Enter Daytona API URL: " API_URL
    if [[ -z "$API_URL" ]]; then
        error "API URL is required"
    fi
fi
log "Using API URL: $API_URL"

# 3. Get Daytona Admin API Key
if [[ -z "$API_KEY" ]]; then
    read -s -p "Enter Daytona Admin API Key: " API_KEY
    echo  # New line after hidden input
    if [[ -z "$API_KEY" ]]; then
        error "API Key is required"
    fi
fi
log "API Key configured"

# 4. Fetch version from API
log "Fetching version information from API..."
VERSION_RESPONSE=$(curl -s -f -H "Authorization: Bearer $API_KEY" "$API_URL/config" || error "Failed to fetch config from API")
VERSION=$(echo "$VERSION_RESPONSE" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
SSH_GATEWAY_PUBLIC_KEY=$(echo "$VERSION_RESPONSE" | grep -o '"sshGatewayPublicKey":"[^"]*"' | cut -d'"' -f4)
SSH_GATEWAY_ENABLE="true"

if [[ -z "$SSH_GATEWAY_PUBLIC_KEY" ]]; then
    SSH_GATEWAY_ENABLE="false"
fi

if [[ -z "$VERSION" ]]; then
    error "Could not extract version from API response"
fi
log "Retrieved version: $VERSION"

# 5. Download runner binary
RUNNER_DIR="/opt/daytona-runner"
RUNNER_BINARY="$RUNNER_DIR/daytona-runner"

# If binary exists, print to use runner update instead
if [ -f "$RUNNER_BINARY" ]; then
    log "Runner binary already exists. For instructions on how to update the runner, please visit https://docs.daytona.io/docs/runner/installation"
    # Check if the user wants to proceed with the rest of the installation
    read -p "Do you want to proceed with the rest of the installation? ([y]/n): " PROCEED
    PROCEED=${PROCEED:-y}
    if [ "$PROCEED" != "y" ]; then
        log "Exiting installation..."
        exit 0
    fi
fi

if [ ! -f "$RUNNER_BINARY" ]; then
    DOWNLOAD_URL="https://github.com/daytonaio/daytona/releases/download/$VERSION/runner-amd64"

    log "Creating runner directory: $RUNNER_DIR"
    sudo mkdir -p "$RUNNER_DIR"

    log "Downloading runner binary from: $DOWNLOAD_URL"
    if ! curl -L -f -o "$RUNNER_BINARY" "$DOWNLOAD_URL"; then
        error "Failed to download runner binary from $DOWNLOAD_URL"
    fi

    sudo chmod +x "$RUNNER_BINARY"
    log "Runner binary downloaded and made executable"
fi

# 7. Check and install Docker
log "Checking if Docker is installed..."
if ! command -v docker &> /dev/null; then
    warn "Docker not found. Installing Docker..."
    
    # Update package index
    sudo apt-get update
    
    # Install prerequisites
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Set up stable repository
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    
    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker
    
    log "Docker installed successfully"
else
    log "Docker is already installed"
fi

# Gather system information for runner registration
log "Gathering system information..."

# Get system specs
CPU_COUNT=$(nproc)
MEMORY_GB=$(free -g | awk '/^Mem:/{print $2}')
DISK_GB=$(df / | awk 'NR==2{printf "%.0f", $2/1024/1024}')

log "System information:"
log "CPU Count: $CPU_COUNT"
log "Memory: $MEMORY_GB GB"
log "Disk: $DISK_GB GB"

# Let the user confirm the system information
read -p "Allocate all for Daytona? ([y]/n): " CONFIRM
CONFIRM=${CONFIRM:-y}
if [ "$CONFIRM" != "y" ]; then
    # Enter custom CPU, mem and disk
    read -p "Enter custom CPU count: " CUSTOM_CPU_COUNT
    # Check if more than total CPU count
    if [ "$CUSTOM_CPU_COUNT" -gt "$CPU_COUNT" ]; then
        error "Custom CPU count is more than total CPU count"
    fi
    read -p "Enter custom memory in GB: " CUSTOM_MEMORY_GB
    # Check if more than total memory
    if [ "$CUSTOM_MEMORY_GB" -gt "$MEMORY_GB" ]; then
        error "Custom memory is more than total memory"
    fi
    read -p "Enter custom disk in GB: " CUSTOM_DISK_GB
    # Check if more than total disk
    if [ "$CUSTOM_DISK_GB" -gt "$DISK_GB" ]; then
        error "Custom disk is more than total disk"
    fi
    CPU_COUNT=$CUSTOM_CPU_COUNT
    MEMORY_GB=$CUSTOM_MEMORY_GB
    DISK_GB=$CUSTOM_DISK_GB

    log "Allocated resources:"
    log "CPU Count: $CPU_COUNT"
    log "Memory: $MEMORY_GB GB"
    log "Disk: $DISK_GB GB"
fi

# Get domain/hostname
read -p "Enter domain name for this runner: " DOMAIN

# Get runner api url
read -p "Enter runner API URL: " RUNNER_API_URL

# Get additional configuration
read -p "Enter proxy URL (or press Enter to use runner api url): " PROXY_URL
PROXY_URL=${PROXY_URL:-$RUNNER_API_URL}

read -p "Enter region [default: us]: " REGION
REGION=${REGION:-us}

read -p "Enter runner capacity [default: 1000]: " CAPACITY
CAPACITY=${CAPACITY:-1000}

read -p "Enter runner API key [default: auto-generated]: " RUNNER_API_KEY
RUNNER_API_KEY=${RUNNER_API_KEY:-$(openssl rand -hex 32)}

# 8. Register runner with API
log "Registering runner with Daytona API..."

RUNNER_PAYLOAD=$(cat <<EOF
{
    "domain": "$DOMAIN",
    "apiUrl": "$RUNNER_API_URL",
    "proxyUrl": "$PROXY_URL",
    "apiKey": "$RUNNER_API_KEY",
    "cpu": $CPU_COUNT,
    "memoryGiB": $MEMORY_GB,
    "diskGiB": $DISK_GB,
    "gpu": 0,
    "gpuType": "",
    "class": "small",
    "capacity": $CAPACITY,
    "region": "$REGION",
    "version": "0"
}
EOF
)

echo "$RUNNER_PAYLOAD"

curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$RUNNER_PAYLOAD" \
    "$API_URL/runners"

if [ $? -ne 0 ]; then
    error "Failed to register runner with API"
fi

log "Runner registered successfully with API"

# 6. Set up systemd service
SERVICE_FILE="/etc/systemd/system/daytona-runner.service"
RUNNER_LOG_PATH="/var/log/daytona-runner.log"

log "Creating systemd service file: $SERVICE_FILE"

# Note: Some environment variables are placeholders and may need to be configured based on your setup
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Daytona Runner Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$RUNNER_DIR
ExecStart=$RUNNER_BINARY
Environment=NODE_ENV=production
Environment=CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-"sysbox-runc"}
Environment=API_TOKEN=$RUNNER_API_KEY
Environment=TLS_CERT_FILE=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
Environment=TLS_KEY_FILE=/etc/letsencrypt/live/$DOMAIN/privkey.pem
Environment=ENABLE_TLS=${ENABLE_TLS:-"false"}
Environment=API_PORT=${API_PORT:-3000}
Environment=LOG_FILE_PATH=$RUNNER_LOG_PATH
Environment=LOG_LEVEL=info
Environment=AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-"https://s3.us-east-1.amazonaws.com"}
Environment=AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
Environment=AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
Environment=AWS_REGION=${AWS_REGION:-us-east-1}
Environment=AWS_DEFAULT_BUCKET=${AWS_DEFAULT_BUCKET:-"daytona"}
Environment=SSH_GATEWAY_ENABLE=${SSH_GATEWAY_ENABLE:-"false"}
Environment=SSH_PUBLIC_KEY=$SSH_GATEWAY_PUBLIC_KEY
Environment=SSH_HOST_KEY_PATH=${SSH_HOST_KEY_PATH:-"/etc/ssh/ssh_host_rsa_key"}
Environment=SERVER_URL=$API_URL
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

log "Enabling daytona-runner service..."
sudo systemctl enable daytona-runner

# 9. Start the runner service
log "Starting daytona-runner service..."
sudo systemctl start daytona-runner

# Check service status
sleep 2
if sudo systemctl is-active --quiet daytona-runner; then
    log "Daytona Runner service started successfully!"
    log "Service status:"
    sudo systemctl status daytona-runner --no-pager -l
else
    error "Failed to start Daytona Runner service. Check logs with: sudo journalctl -u daytona-runner -f"
fi

log "Setup completed successfully!"
log "Runner is now running and registered with Daytona API"
log "To check service status: sudo systemctl status daytona-runner"
log "To view logs: sudo journalctl -u daytona-runner -f"
log "To stop service: sudo systemctl stop daytona-runner"