#!/bin/bash

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
ORANGE='\033[0;33m'
NC='\033[0m' # No Color

# Logging function with visual symbols
log() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
    exit 1
}

warn() {
    echo -e "${ORANGE}⚠${NC} $1"
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# 1. Detect OS architecture
info "Checking system architecture..."
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]]; then
    error "Unsupported architecture: $ARCH. This script requires AMD64/x86_64 architecture."
fi
log "Architecture check passed: $ARCH"

# 2. Get Daytona API URL
if [[ -z "$API_URL" ]]; then
    read -p "Enter Daytona API URL (example: https://app.daytona.io): " API_URL < /dev/tty
    if [[ -z "$API_URL" ]]; then
        error "API URL is required"
    fi
fi
log "Using API URL: $API_URL"

# 3. Get Daytona Admin API Key
if [[ -z "$API_KEY" ]]; then
    read -s -p "Enter Daytona Admin API Key: " API_KEY < /dev/tty
    echo  # New line after hidden input
    if [[ -z "$API_KEY" ]]; then
        error "API Key is required"
    fi
fi
log "API Key configured"

# 4. Fetch version from API
info "Fetching version information from API..."

# Fetch config with proper error handling
set +e  # Temporarily disable exit on error
CONFIG_RESPONSE=$(curl -s -f --max-time 10 -H "Authorization: Bearer $API_KEY" "$API_URL/api/config" 2>&1)
CURL_EXIT_CODE=$?
set -e  # Re-enable exit on error

# Check if curl failed
if [ $CURL_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch config from API. Please check:
  - API URL is correct and accessible
  - API Key is valid"
fi

# Extract SSH key
SSH_GATEWAY_PUBLIC_KEY=$(echo "$CONFIG_RESPONSE" | grep -o '"sshGatewayPublicKey":"[^"]*"' | cut -d'"' -f4)
SSH_GATEWAY_ENABLE="true"

if [[ -z "$SSH_GATEWAY_PUBLIC_KEY" ]]; then
    SSH_GATEWAY_ENABLE="false"
fi

# 5. Download runner binary
RUNNER_DIR="/opt/daytona-runner"
RUNNER_BINARY="$RUNNER_DIR/daytona-runner"

# If binary exists, print to use runner update instead
if [ -f "$RUNNER_BINARY" ]; then
    info "Runner binary already exists. For instructions on how to update the runner, please visit https://docs.daytona.io/docs/runner/installation"
    # Check if the user wants to proceed with the rest of the installation
    read -p "Do you want to proceed with the rest of the installation? ([y]/n): " PROCEED < /dev/tty
    PROCEED=${PROCEED:-y}
    # Convert to lowercase and accept both y/yes and n/no
    PROCEED=$(echo "$PROCEED" | tr '[:upper:]' '[:lower:]')
    if [[ "$PROCEED" != "y" && "$PROCEED" != "yes" ]]; then
        log "Exiting installation..."
        exit 0
    fi
fi

if [ ! -f "$RUNNER_BINARY" ]; then
    DOWNLOAD_URL="$API_URL/runner-amd64"

    info "Creating runner directory: $RUNNER_DIR"
    sudo mkdir -p "$RUNNER_DIR"

    info "Downloading runner binary from: $DOWNLOAD_URL"
    if ! curl -L -f -s -o "$RUNNER_BINARY" "$DOWNLOAD_URL"; then
        error "Failed to download runner binary from $DOWNLOAD_URL"
    fi

    sudo chmod +x "$RUNNER_BINARY"
    log "Runner binary downloaded and made executable"
fi

# Function to install Sysbox
install_sysbox() {
    info "Installing Sysbox..."

    # Check if Docker is running and has containers
    if command -v docker &> /dev/null; then
        CONTAINER_COUNT=$(sudo docker ps -a -q | wc -l)
        if [ "$CONTAINER_COUNT" -gt 0 ]; then
            warn "Found $CONTAINER_COUNT Docker container(s) on the system."
            warn "Sysbox installation requires stopping and removing all existing containers."
            echo ""
            echo "This will:"
            echo "  - Stop all running containers"
            echo "  - Remove all containers (running and stopped)"
            echo "  - This action cannot be undone"
            echo ""
            read -p "Do you want to continue? This will remove ALL Docker containers. (Y/n): " CONFIRM < /dev/tty
            CONFIRM=${CONFIRM:-y}
            CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')

            if [[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]]; then
                error "Installation cancelled. Please backup your containers and run the script again."
            fi

            # Stop and remove all Docker containers (recommended by Sysbox docs)
            info "Stopping and removing existing Docker containers..."
            # Stop all running containers
            sudo docker stop $(sudo docker ps -a -q) 2>/dev/null || true
            # Remove all containers
            sudo docker rm $(sudo docker ps -a -q) -f 2>/dev/null || true
            log "Docker containers stopped and removed"
        else
            log "No Docker containers found, proceeding with Sysbox installation"
        fi
    fi

    # Install Sysbox prerequisites
    info "Installing Sysbox prerequisites (jq and linux-headers)..."
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y jq linux-headers-$(uname -r) > /dev/null 2>&1

    # Download and install Sysbox
    curl -fsSL https://downloads.nestybox.com/sysbox/releases/v0.6.7/sysbox-ce_0.6.7-0.linux_amd64.deb -o /tmp/sysbox.deb

    sudo dpkg -i /tmp/sysbox.deb > /dev/null 2>&1
    sudo apt-get install -f -y > /dev/null 2>&1  # Fix any dependency issues

    # Start Sysbox service
    sudo systemctl start sysbox
    sudo systemctl enable sysbox > /dev/null 2>&1

    # Verify Sysbox is working
    if ! sudo sysbox-runc --version > /dev/null 2>&1; then
        error "Sysbox installation failed - sysbox-runc not found"
    fi

    # Clean up
    rm -f /tmp/sysbox.deb

    log "Sysbox installed and verified successfully"
}

# 7. Check and install Docker and Sysbox
log "Checking if Docker is installed..."
if ! command -v docker &> /dev/null; then
    warn "Docker not found. Installing Docker and Sysbox..."

    info "Updating package index..."
    # Update package index (suppress output)
    sudo apt-get update > /dev/null 2>&1

    info "Installing Docker prerequisites..."
    # Install prerequisites (suppress output)
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release > /dev/null 2>&1

    info "Adding Docker's official GPG key..."
    # Add Docker's official GPG key (suppress output)
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null

    info "Setting up Docker repository..."
    # Set up stable repository
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    info "Installing Docker Engine..."
    # Install Docker (suppress output)
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io > /dev/null 2>&1

    info "Starting and enabling Docker service..."
    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker > /dev/null 2>&1

    log "Docker installed successfully"

    # Install Sysbox after Docker
    install_sysbox

    # Restart Docker to work with Sysbox
    info "Restarting Docker to work with Sysbox..."
    sudo systemctl restart docker

else
    log "Docker is already installed"

    # Check if Sysbox is installed
    if ! command -v sysbox &> /dev/null; then
        warn "Sysbox not found. Installing Sysbox..."
        install_sysbox

        # Restart Docker to work with Sysbox
        info "Restarting Docker to work with Sysbox..."
        sudo systemctl restart docker
    else
        log "Sysbox is already installed"

        # Verify Sysbox is working
        if ! sudo sysbox-runc --version > /dev/null 2>&1; then
            warn "Sysbox appears to be installed but not working properly. Reinstalling..."
            install_sysbox
            sudo systemctl restart docker
        else
            log "Sysbox is working correctly"
        fi
    fi
fi

# Gather system information for runner registration
info "Gathering system information..."

# Get system specs
CPU_COUNT=$(nproc)
MEMORY_GB=$(free -g | awk '/^Mem:/{print $2}')
DISK_GB=$(df / | awk 'NR==2{printf "%.0f", $2/1024/1024}')

echo "System information:"
echo "  CPU Count: $CPU_COUNT"
echo "  Memory: $MEMORY_GB GB"
echo "  Disk: $DISK_GB GB"

# Let the user confirm the system information
read -p "Allocate all for Daytona? ([y]/n): " CONFIRM < /dev/tty
CONFIRM=${CONFIRM:-y}
# Convert to lowercase and accept both y/yes and n/no
CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]]; then
    # Enter custom CPU, mem and disk
    read -p "Enter custom CPU count: " CUSTOM_CPU_COUNT < /dev/tty
    # Check if more than total CPU count
    if [ "$CUSTOM_CPU_COUNT" -gt "$CPU_COUNT" ]; then
        error "Custom CPU count is more than total CPU count"
    fi
    read -p "Enter custom memory in GB: " CUSTOM_MEMORY_GB < /dev/tty
    # Check if more than total memory
    if [ "$CUSTOM_MEMORY_GB" -gt "$MEMORY_GB" ]; then
        error "Custom memory is more than total memory"
    fi
    read -p "Enter custom disk in GB: " CUSTOM_DISK_GB < /dev/tty
    # Check if more than total disk
    if [ "$CUSTOM_DISK_GB" -gt "$DISK_GB" ]; then
        error "Custom disk is more than total disk"
    fi
    CPU_COUNT=$CUSTOM_CPU_COUNT
    MEMORY_GB=$CUSTOM_MEMORY_GB
    DISK_GB=$CUSTOM_DISK_GB

    echo "Allocated resources:"
    echo "  CPU Count: $CPU_COUNT"
    echo "  Memory: $MEMORY_GB GB"
    echo "  Disk: $DISK_GB GB"
fi

# Function to get public IP
get_public_ip() {
    # Try multiple services to get public IP
    local ip=""

    # Try different services in order
    for service in "https://ipinfo.io/ip" "https://api.ipify.org" "https://checkip.amazonaws.com" "https://icanhazip.com"; do
        ip=$(curl -s --max-time 5 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done

    return 1
}

# Get domain name or IP address
log "Detecting public IP address..."
PUBLIC_IP=$(get_public_ip)
if [[ -n "$PUBLIC_IP" ]]; then
    info "Detected public IP: $PUBLIC_IP"
    read -p "Enter domain name or IP address for this runner [$PUBLIC_IP]: " DOMAIN_OR_IP < /dev/tty
    DOMAIN_OR_IP=${DOMAIN_OR_IP:-$PUBLIC_IP}
else
    warn "Could not detect public IP automatically"
    read -p "Enter domain name or IP address for this runner: " DOMAIN_OR_IP < /dev/tty
fi

if [[ -z "$DOMAIN_OR_IP" ]]; then
    error "Domain name or IP address is required"
fi

log "Using domain/IP: $DOMAIN_OR_IP"

# Smart URL construction function
construct_api_url() {
    local input="$1"
    local protocol="http"
    local host=""
    local port="3000"

    # Check if input already contains protocol
    if [[ "$input" =~ ^https?:// ]]; then
        # Extract protocol
        protocol=$(echo "$input" | sed -n 's/^\(https\?\):\/\/.*/\1/p')
        # Remove protocol from input
        input=$(echo "$input" | sed 's/^https\?:\/\///')
    fi

    # Check if input contains port
    if [[ "$input" =~ :[0-9]+$ ]]; then
        # Extract host and port
        host=$(echo "$input" | sed 's/:[0-9]*$//')
        port=$(echo "$input" | sed -n 's/.*:\([0-9]*\)$/\1/p')
    else
        host="$input"
    fi

    echo "${protocol}://${host}:${port}"
}

# Construct default API URL and let user confirm or modify
DEFAULT_API_URL=$(construct_api_url "$DOMAIN_OR_IP")
read -p "Enter runner API URL [$DEFAULT_API_URL]: " RUNNER_API_URL < /dev/tty
RUNNER_API_URL=${RUNNER_API_URL:-$DEFAULT_API_URL}
PROXY_URL="$RUNNER_API_URL"

log "Runner API URL set to: $RUNNER_API_URL"
log "Proxy URL also set to: $PROXY_URL"

read -p "Enter region [default: us]: " REGION < /dev/tty
REGION=${REGION:-us}

read -p "Enter runner capacity [default: 1000]: " CAPACITY < /dev/tty
CAPACITY=${CAPACITY:-1000}

read -p "Enter runner API key [default: auto-generated]: " RUNNER_API_KEY < /dev/tty
RUNNER_API_KEY=${RUNNER_API_KEY:-$(openssl rand -hex 32)}

# 8. Register runner with API
log "Registering runner with Daytona API..."

RUNNER_PAYLOAD=$(cat <<EOF
{
    "domain": "$DOMAIN_OR_IP",
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

# Register runner with proper error handling
REGISTRATION_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$RUNNER_PAYLOAD" \
    "$API_URL/api/runners")

# Extract HTTP status code (last line) and response body (everything else)
HTTP_STATUS=$(echo "$REGISTRATION_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$REGISTRATION_RESPONSE" | head -n -1)

echo "$RESPONSE_BODY"

# Check if registration was successful
if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    log "Runner registered successfully with API"
elif [[ "$HTTP_STATUS" == 409 || "$RESPONSE_BODY" == *"duplicate key"* ]]; then
    warn "Runner with this domain already exists - this may be expected if re-running the installation"
    info "Continuing with installation..."
else
    error "Failed to register runner with API (HTTP $HTTP_STATUS): $RESPONSE_BODY"
fi

# 6. Set up systemd service
SERVICE_FILE="/etc/systemd/system/daytona-runner.service"
RUNNER_LOG_PATH="/var/log/daytona-runner.log"

info "Creating systemd service file: $SERVICE_FILE"

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
Environment=TLS_CERT_FILE=/etc/letsencrypt/live/$DOMAIN_OR_IP/fullchain.pem
Environment=TLS_KEY_FILE=/etc/letsencrypt/live/$DOMAIN_OR_IP/privkey.pem
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
Environment=SERVER_URL=$API_URL/api
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
info "Reloading systemd daemon..."
sudo systemctl daemon-reload

info "Enabling daytona-runner service..."
sudo systemctl enable daytona-runner

# 9. Start the runner service
info "Starting daytona-runner service..."
sudo systemctl start daytona-runner

# Check service status
sleep 2
if sudo systemctl is-active --quiet daytona-runner; then
    log "Daytona Runner service started successfully!"
    log "Service running: YES"
else
    error "Failed to start Daytona Runner service. Check logs with: sudo journalctl -u daytona-runner -f"
fi

log "Setup completed successfully!"
log "Runner is now running and registered with Daytona API"
info "To check service status: sudo systemctl status daytona-runner"
info "To view logs: sudo journalctl -u daytona-runner -f"
info "To stop service: sudo systemctl stop daytona-runner"
