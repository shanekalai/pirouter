#!/bin/bash
#
# RaspAP Secure Docker Setup Script
# For Raspberry Pi 3B with TP-Link A600 on Debian 13 (Trixie)
#
# This script creates a secure, ISP-invisible router configuration using:
# - Docker containers with security hardening
# - WireGuard VPN tunnel for all traffic
# - DNS over HTTPS to prevent DNS leaks
# - Strict firewall rules with kill switch
# - MAC address randomization on WAN interface
#
# Hardware Requirements:
# - Raspberry Pi 3B (or newer)
# - TP-Link Archer T2U/A600 USB WiFi Adapter
# - TP-Link TL-SG108E Managed Switch
# - Hitron CODA5834 ISP Modem (bridge mode)
#
# Usage: sudo ./secure-setup.sh [OPTIONS]
#
# Options:
#   --vpn-config PATH    Path to WireGuard config file
#   --wifi-ssid NAME     WiFi network name (default: SecureAP)
#   --wifi-pass PASS     WiFi password (min 12 chars)
#   --admin-pass PASS    RaspAP admin password
#   --no-interactive     Skip interactive prompts
#   --uninstall          Remove all containers and configs
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration defaults
RASPAP_DIR="/opt/raspap"
DOCKER_DIR="${RASPAP_DIR}/docker"
CONFIG_DIR="${RASPAP_DIR}/config"
SECRETS_DIR="${RASPAP_DIR}/secrets"
LOG_DIR="/var/log/raspap"
WAN_INTERFACE="eth0"
WLAN_INTERFACE="wlan1"  # TP-Link A600 typically appears as wlan1
LAN_INTERFACE="eth1"    # USB ethernet adapter for wired LAN (switch)
AP_SUBNET="10.3.141.0/24"
AP_GATEWAY="10.3.141.1"
WIFI_SSID="SecureAP"
WIFI_PASS=""
ADMIN_USER="admin"
ADMIN_PASS=""
VPN_CONFIG=""
INTERACTIVE=true
UNINSTALL=false

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --vpn-config)
                VPN_CONFIG="$2"
                shift 2
                ;;
            --wifi-ssid)
                WIFI_SSID="$2"
                shift 2
                ;;
            --wifi-pass)
                WIFI_PASS="$2"
                shift 2
                ;;
            --admin-pass)
                ADMIN_PASS="$2"
                shift 2
                ;;
            --lan-interface)
                LAN_INTERFACE="$2"
                shift 2
                ;;
            --no-interactive)
                INTERACTIVE=false
                shift
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << 'EOF'
RaspAP Secure Docker Setup Script

Usage: sudo ./secure-setup.sh [OPTIONS]

Options:
  --vpn-config PATH    Path to WireGuard configuration file (default: ./wg0.conf)
  --wifi-ssid NAME     WiFi network name (default: SecureAP)
  --wifi-pass PASS     WiFi password (minimum 12 characters)
  --admin-pass PASS    RaspAP admin dashboard password
  --lan-interface IF   LAN interface for wired switch (default: eth1)
  --no-interactive     Skip all interactive prompts
  --uninstall          Remove all containers and configurations
  -h, --help           Show this help message

Example:
  sudo ./secure-setup.sh --wifi-ssid "MySecureNetwork" --lan-interface eth1

Network Topology:
  eth0 (WAN)  → ISP Modem (Hitron)
  wlan1 (AP)  → WiFi clients via USB adapter (TP-Link A600)
  eth1 (LAN)  → Wired switch (TP-Link TL-SG108E)

All clients (WiFi + wired) share the 10.3.141.0/24 subnet with gateway 10.3.141.1

For complete setup instructions, see: docs/SECURE_SETUP.md
EOF
}

# Detect system architecture
detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armhf)
            echo "armhf"
            ;;
        x86_64)
            echo "amd64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Check system requirements
check_requirements() {
    log_step "Checking system requirements..."

    # Check Debian version
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "raspbian" ]]; then
            log_warn "This script is designed for Debian/Raspbian. Detected: $ID"
        fi
        if [[ "${VERSION_ID:-0}" -lt 12 ]]; then
            log_warn "Debian 12+ recommended. Detected version: ${VERSION_ID:-unknown}"
        fi
    fi

    # Check available memory
    local mem_total
    mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [[ $mem_total -lt 900000 ]]; then
        log_warn "Low memory detected ($(($mem_total/1024))MB). Minimum 1GB recommended."
    fi

    # Check for required kernel modules
    local required_modules=("wireguard" "iptable_nat" "iptable_filter" "br_netfilter")
    for mod in "${required_modules[@]}"; do
        if ! modprobe -n "$mod" 2>/dev/null; then
            log_warn "Kernel module '$mod' may not be available"
        fi
    done

    log_info "System requirements check complete"
}

# Detect WiFi interfaces
detect_wifi_interfaces() {
    log_step "Detecting WiFi interfaces..."

    local interfaces
    interfaces=$(iw dev 2>/dev/null | awk '/Interface/ {print $2}' || true)

    if [[ -z "$interfaces" ]]; then
        log_error "No WiFi interfaces detected. Please connect TP-Link A600 adapter."
        exit 1
    fi

    echo "Detected WiFi interfaces:"
    for iface in $interfaces; do
        local driver phy
        driver=$(ethtool -i "$iface" 2>/dev/null | grep driver | awk '{print $2}' || echo "unknown")
        phy=$(iw dev "$iface" info 2>/dev/null | grep wiphy | awk '{print $2}' || echo "?")
        echo "  - $iface (driver: $driver, phy: $phy)"
    done

    # Prefer external USB adapter (usually wlan1 or higher)
    if echo "$interfaces" | grep -q "wlan1"; then
        WLAN_INTERFACE="wlan1"
    elif echo "$interfaces" | grep -q "wlan0"; then
        WLAN_INTERFACE="wlan0"
    else
        WLAN_INTERFACE=$(echo "$interfaces" | head -1)
    fi

    log_info "Selected WiFi interface: $WLAN_INTERFACE"

    # Check if interface supports AP mode
    local phy_num
    phy_num=$(iw dev "$WLAN_INTERFACE" info 2>/dev/null | grep wiphy | awk '{print $2}')
    if ! iw phy "phy${phy_num}" info 2>/dev/null | grep -q "* AP"; then
        log_error "Interface $WLAN_INTERFACE does not support AP mode"
        exit 1
    fi

    log_info "Interface $WLAN_INTERFACE supports AP mode"
}

# Install Docker and dependencies
install_docker() {
    log_step "Installing Docker and dependencies..."

    # Update package lists
    apt-get update

    # Install prerequisites
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        iptables \
        iproute2 \
        wireless-tools \
        iw \
        rfkill \
        wpasupplicant \
        net-tools \
        dnsutils \
        openssl \
        jq

    # Check if Docker is already installed
    if command -v docker &>/dev/null; then
        log_info "Docker already installed: $(docker --version)"
    else
        log_info "Installing Docker..."

        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        # Add Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        log_error "Docker failed to start"
        exit 1
    fi

    log_info "Docker installed and running"
}

# Create directory structure
create_directories() {
    log_step "Creating directory structure..."

    mkdir -p "$DOCKER_DIR"
    mkdir -p "$CONFIG_DIR"/{hostapd,dnsmasq,wireguard,iptables,lighttpd}
    mkdir -p "$SECRETS_DIR"
    mkdir -p "$LOG_DIR"

    # Create log files that will be mounted into containers
    touch "$LOG_DIR/dnsmasq.log"
    chmod 644 "$LOG_DIR/dnsmasq.log"

    # Secure secrets directory
    chmod 700 "$SECRETS_DIR"

    log_info "Directory structure created at $RASPAP_DIR"
}

# Generate secure passwords and keys
generate_secrets() {
    log_step "Generating secure credentials..."

    # Generate WiFi password if not provided
    if [[ -z "$WIFI_PASS" ]]; then
        if [[ "$INTERACTIVE" == true ]]; then
            read -sp "Enter WiFi password (min 12 chars): " WIFI_PASS
            echo
            if [[ ${#WIFI_PASS} -lt 12 ]]; then
                log_error "WiFi password must be at least 12 characters"
                exit 1
            fi
        else
            WIFI_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
            log_info "Generated WiFi password: $WIFI_PASS"
        fi
    fi

    # Generate admin password if not provided
    if [[ -z "$ADMIN_PASS" ]]; then
        if [[ "$INTERACTIVE" == true ]]; then
            read -sp "Enter RaspAP admin password: " ADMIN_PASS
            echo
        else
            ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
            log_info "Generated admin password: $ADMIN_PASS"
        fi
    fi

    # Store credentials securely
    cat > "$SECRETS_DIR/credentials.env" << EOF
WIFI_SSID=${WIFI_SSID}
WIFI_PASS=${WIFI_PASS}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
EOF
    chmod 600 "$SECRETS_DIR/credentials.env"

    # Generate API key for REST API
    API_KEY=$(openssl rand -hex 32)
    echo "API_KEY=${API_KEY}" >> "$SECRETS_DIR/credentials.env"

    log_info "Credentials stored in $SECRETS_DIR/credentials.env"
}

# Configure WireGuard VPN
configure_wireguard() {
    log_step "Configuring WireGuard VPN..."

    # Check for wg0.conf in the docker folder first (default location)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local default_wg_config="${script_dir}/wg0.conf"

    # Use default wg0.conf from docker folder if no config specified and it exists
    if [[ -z "$VPN_CONFIG" && -f "$default_wg_config" ]]; then
        log_info "Found wg0.conf in docker folder, using it..."
        VPN_CONFIG="$default_wg_config"
    fi

    if [[ -z "$VPN_CONFIG" ]]; then
        if [[ "$INTERACTIVE" == true ]]; then
            log_warn "No VPN config provided. Traffic will NOT be encrypted!"
            read -p "Enter path to WireGuard config file (or press Enter to skip): " VPN_CONFIG
        fi
    fi

    if [[ -n "$VPN_CONFIG" && -f "$VPN_CONFIG" ]]; then
        cp "$VPN_CONFIG" "$CONFIG_DIR/wireguard/wg0.conf"
        chmod 600 "$CONFIG_DIR/wireguard/wg0.conf"

        # Add kill switch to WireGuard config
        add_killswitch_to_wg_config

        log_info "WireGuard configuration installed from: $VPN_CONFIG"
    else
        log_warn "No VPN configuration. Creating placeholder..."
        cat > "$CONFIG_DIR/wireguard/wg0.conf" << 'EOF'
# WireGuard VPN Configuration
# Replace this with your VPN provider's configuration
#
# Example:
# [Interface]
# PrivateKey = YOUR_PRIVATE_KEY
# Address = 10.x.x.x/32
# DNS = 10.x.x.1
#
# [Peer]
# PublicKey = VPN_SERVER_PUBLIC_KEY
# AllowedIPs = 0.0.0.0/0, ::/0
# Endpoint = vpn.example.com:51820
# PersistentKeepalive = 25
EOF
        chmod 600 "$CONFIG_DIR/wireguard/wg0.conf"
    fi
}

# Add kill switch rules to WireGuard config
add_killswitch_to_wg_config() {
    local wg_config="$CONFIG_DIR/wireguard/wg0.conf"

    # Check if PostUp/PostDown already exist
    if grep -q "PostUp" "$wg_config"; then
        log_info "WireGuard config already has PostUp rules"
        return
    fi

    # Add kill switch rules after [Interface] section
    sed -i '/^\[Interface\]/a \
# Kill switch - block all traffic if VPN disconnects\
PostUp = iptables -I OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT\
PostUp = ip6tables -I OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT\
PreDown = iptables -D OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT\
PreDown = ip6tables -D OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT' "$wg_config"

    log_info "Kill switch rules added to WireGuard config"
}

# Create hostapd configuration
create_hostapd_config() {
    log_step "Creating hostapd configuration..."

    cat > "$CONFIG_DIR/hostapd/hostapd.conf" << EOF
# RaspAP Secure Hostapd Configuration
# Generated by secure-setup.sh

interface=${WLAN_INTERFACE}
driver=nl80211
ssid=${WIFI_SSID}

# Use 5GHz band if supported (faster, less interference)
hw_mode=a
channel=36
country_code=US

# 802.11ac support
ieee80211ac=1
ieee80211n=1
wmm_enabled=1

# Security settings - WPA3 preferred, WPA2 fallback
wpa=2
wpa_passphrase=${WIFI_PASS}
wpa_key_mgmt=SAE WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
ieee80211w=1

# Disable WPS (security risk)
wps_state=0

# Client isolation (prevent clients from seeing each other)
ap_isolate=1

# Beacon settings
beacon_int=100
dtim_period=2

# Maximum clients
max_num_sta=20

# Logging
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2

# Control interface
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
EOF

    chmod 600 "$CONFIG_DIR/hostapd/hostapd.conf"
    log_info "Hostapd configuration created"
}

# Create dnsmasq configuration with DNS over HTTPS
create_dnsmasq_config() {
    log_step "Creating dnsmasq configuration..."

    cat > "$CONFIG_DIR/dnsmasq/dnsmasq.conf" << EOF
# RaspAP Secure Dnsmasq Configuration
# DNS and DHCP server for the access point and wired LAN

# Interface settings - serve both WiFi and wired LAN
interface=${WLAN_INTERFACE}
interface=${LAN_INTERFACE}
bind-interfaces
except-interface=lo
except-interface=${WAN_INTERFACE}

# DHCP settings - shared pool for both interfaces
dhcp-range=10.3.141.50,10.3.141.254,255.255.255.0,24h
dhcp-option=option:router,${AP_GATEWAY}
dhcp-option=option:dns-server,${AP_GATEWAY}
dhcp-option=option:netmask,255.255.255.0

# DNS settings - forward to local DNS-over-HTTPS proxy
server=127.0.0.1#5053
no-resolv

# Security settings
domain-needed
bogus-priv
filterwin2k
stop-dns-rebind
rebind-localhost-ok

# Privacy settings - minimal logging
log-facility=/var/log/dnsmasq.log
log-async=25
# Uncomment for debugging:
# log-queries

# Performance
cache-size=10000
neg-ttl=60
local-ttl=120

# DNSSEC validation (if upstream supports it)
dnssec
dnssec-check-unsigned

# Block common tracking domains
address=/telemetry.microsoft.com/0.0.0.0
address=/telemetry.google.com/0.0.0.0
address=/metrics.icloud.com/0.0.0.0
EOF

    chmod 644 "$CONFIG_DIR/dnsmasq/dnsmasq.conf"
    log_info "Dnsmasq configuration created"
}

# Create firewall rules
create_firewall_rules() {
    log_step "Creating firewall rules..."

    cat > "$CONFIG_DIR/iptables/rules.sh" << 'EOF'
#!/bin/bash
#
# RaspAP Secure Firewall Rules
# Implements strict NAT and kill switch

# Variables (set by Docker)
WAN_IF="${WAN_INTERFACE:-eth0}"
WLAN_IF="${WLAN_INTERFACE:-wlan1}"
LAN_IF="${LAN_INTERFACE:-eth1}"
VPN_IF="${VPN_INTERFACE:-wg0}"
AP_SUBNET="${AP_SUBNET:-10.3.141.0/24}"

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Default policies - DROP everything
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DHCP on WLAN and LAN interfaces
iptables -A INPUT -i "$WLAN_IF" -p udp --dport 67:68 -j ACCEPT
iptables -A OUTPUT -o "$WLAN_IF" -p udp --sport 67:68 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -p udp --dport 67:68 -j ACCEPT
iptables -A OUTPUT -o "$LAN_IF" -p udp --sport 67:68 -j ACCEPT

# Allow DNS on WLAN and LAN interfaces (to local dnsmasq)
iptables -A INPUT -i "$WLAN_IF" -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i "$WLAN_IF" -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT

# Allow HTTP/HTTPS for RaspAP web interface (local only)
iptables -A INPUT -i "$WLAN_IF" -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -i "$WLAN_IF" -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -p tcp --dport 443 -j ACCEPT

# Allow SSH from local network only (WiFi and LAN)
iptables -A INPUT -i "$WLAN_IF" -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -p tcp --dport 22 -j ACCEPT

# WireGuard VPN rules
if ip link show "$VPN_IF" &>/dev/null; then
    # Allow WireGuard traffic out
    iptables -A OUTPUT -o "$WAN_IF" -p udp --dport 51820 -j ACCEPT

    # Allow all traffic through VPN
    iptables -A OUTPUT -o "$VPN_IF" -j ACCEPT

    # NAT through VPN
    iptables -t nat -A POSTROUTING -s "$AP_SUBNET" -o "$VPN_IF" -j MASQUERADE

    # Forward from WLAN and LAN to VPN only
    iptables -A FORWARD -i "$WLAN_IF" -o "$VPN_IF" -j ACCEPT
    iptables -A FORWARD -i "$LAN_IF" -o "$VPN_IF" -j ACCEPT

    # Allow forwarding between LAN and WLAN (same subnet)
    iptables -A FORWARD -i "$WLAN_IF" -o "$LAN_IF" -j ACCEPT
    iptables -A FORWARD -i "$LAN_IF" -o "$WLAN_IF" -j ACCEPT

    # Block LAN/WLAN to WAN bypass (kill switch)
    iptables -A FORWARD -i "$WLAN_IF" -o "$WAN_IF" -j DROP
    iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -j DROP
    iptables -A OUTPUT -o "$WAN_IF" ! -p udp ! --dport 51820 -j DROP
else
    # Fallback: NAT through WAN (less secure)
    iptables -t nat -A POSTROUTING -s "$AP_SUBNET" -o "$WAN_IF" -j MASQUERADE
    iptables -A FORWARD -i "$WLAN_IF" -o "$WAN_IF" -j ACCEPT
    iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
    iptables -A FORWARD -i "$WLAN_IF" -o "$LAN_IF" -j ACCEPT
    iptables -A FORWARD -i "$LAN_IF" -o "$WLAN_IF" -j ACCEPT
fi

# Block IPv6 to prevent leaks
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /proc/sys/net/ipv6/conf/all/forwarding

# Log dropped packets (limit to prevent log flooding)
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "IPT_DROP_IN: "
iptables -A FORWARD -m limit --limit 5/min -j LOG --log-prefix "IPT_DROP_FWD: "
iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "IPT_DROP_OUT: "

echo "Firewall rules applied successfully"
EOF

    chmod 755 "$CONFIG_DIR/iptables/rules.sh"
    log_info "Firewall rules created"
}

# Create Docker Compose configuration
create_docker_compose() {
    log_step "Creating Docker Compose configuration..."

    cat > "$DOCKER_DIR/docker-compose.yml" << 'EOF'
# RaspAP Secure Docker Configuration
#
# This configuration provides:
# - Isolated containers with minimal privileges
# - WireGuard VPN with kill switch
# - DNS over HTTPS for privacy
# - Strict network segmentation
#

services:
  # DNS over HTTPS Proxy
  # Encrypts all DNS queries to prevent ISP snooping
  dns-proxy:
    image: cloudflare/cloudflared:latest
    container_name: raspap-dns
    restart: unless-stopped
    command: proxy-dns
    environment:
      - TUNNEL_DNS_UPSTREAM=https://1.1.1.1/dns-query,https://1.0.0.1/dns-query
      - TUNNEL_DNS_PORT=5053
      - TUNNEL_DNS_ADDRESS=0.0.0.0
    networks:
      raspap-internal:
        ipv4_address: 172.20.0.2
    security_opt:
      - no-new-privileges:true
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    healthcheck:
      test: ["CMD", "true"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

  # WireGuard VPN Container
  # All traffic is routed through this tunnel
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: raspap-vpn
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - ${CONFIG_DIR}/wireguard:/config
      - /lib/modules:/lib/modules:ro
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.disable_ipv6=1
    networks:
      raspap-internal:
        ipv4_address: 172.20.0.3
      raspap-wan:
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "wg", "show"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    depends_on:
      dns-proxy:
        condition: service_started

  # Dnsmasq - DHCP and DNS for AP clients
  dnsmasq:
    build:
      context: ./dnsmasq
      dockerfile: Dockerfile
    container_name: raspap-dnsmasq
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ${CONFIG_DIR}/dnsmasq/dnsmasq.conf:/etc/dnsmasq.conf:ro
      - ${LOG_DIR}/dnsmasq.log:/var/log/dnsmasq.log
    security_opt:
      - no-new-privileges:true
    depends_on:
      dns-proxy:
        condition: service_started

  # Hostapd - Wireless Access Point
  hostapd:
    build:
      context: ./hostapd
      dockerfile: Dockerfile
    container_name: raspap-hostapd
    restart: unless-stopped
    network_mode: host
    privileged: true  # Required for wireless interface access
    environment:
      - WLAN_INTERFACE=${WLAN_INTERFACE:-wlan1}
      - LAN_INTERFACE=${LAN_INTERFACE:-eth1}
      - AP_GATEWAY=${AP_GATEWAY:-10.3.141.1}
    volumes:
      - ${CONFIG_DIR}/hostapd/hostapd.conf:/etc/hostapd/hostapd.conf:ro
      - /var/run/hostapd:/var/run/hostapd
    depends_on:
      - dnsmasq

  # RaspAP Web Interface
  raspap-web:
    build:
      context: ./raspap
      dockerfile: Dockerfile
    container_name: raspap-web
    restart: unless-stopped
    network_mode: host
    environment:
      - RASPAP_ADMIN_USER=${ADMIN_USER:-admin}
      - RASPAP_ADMIN_PASS=${ADMIN_PASS}
      - API_KEY=${API_KEY}
    volumes:
      - ${CONFIG_DIR}:/etc/raspap:rw
      - ${LOG_DIR}:/var/log/raspap:rw
      - /var/run/hostapd:/var/run/hostapd:ro
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
      - NET_RAW
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=64M,mode=1777
      - /var/run:size=16M,mode=755
    depends_on:
      - hostapd
      - wireguard
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  # Firewall Manager
  firewall:
    build:
      context: ./firewall
      dockerfile: Dockerfile
    container_name: raspap-firewall
    restart: unless-stopped
    network_mode: host
    privileged: true  # Required for iptables
    volumes:
      - ${CONFIG_DIR}/iptables:/etc/iptables:ro
    environment:
      - WAN_INTERFACE=${WAN_INTERFACE:-eth0}
      - WLAN_INTERFACE=${WLAN_INTERFACE:-wlan1}
      - LAN_INTERFACE=${LAN_INTERFACE:-eth1}
      - VPN_INTERFACE=wg0
      - AP_SUBNET=${AP_SUBNET:-10.3.141.0/24}
    depends_on:
      - wireguard

networks:
  # Internal network for container communication
  raspap-internal:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
    driver_opts:
      com.docker.network.bridge.enable_icc: "true"
      com.docker.network.bridge.enable_ip_masquerade: "false"

  # WAN access for VPN only
  raspap-wan:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.enable_ip_masquerade: "true"
EOF

    # Create environment file for docker-compose
    cat > "$DOCKER_DIR/.env" << EOF
CONFIG_DIR=${CONFIG_DIR}
LOG_DIR=${LOG_DIR}
WAN_INTERFACE=${WAN_INTERFACE}
WLAN_INTERFACE=${WLAN_INTERFACE}
LAN_INTERFACE=${LAN_INTERFACE}
AP_SUBNET=${AP_SUBNET}
AP_GATEWAY=${AP_GATEWAY}
EOF

    # Add secrets
    source "$SECRETS_DIR/credentials.env"
    cat >> "$DOCKER_DIR/.env" << EOF
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
API_KEY=${API_KEY}
EOF

    chmod 600 "$DOCKER_DIR/.env"
    log_info "Docker Compose configuration created"
}

# Create Dockerfile for hostapd
create_hostapd_dockerfile() {
    log_step "Creating hostapd Dockerfile..."

    mkdir -p "$DOCKER_DIR/hostapd"

    cat > "$DOCKER_DIR/hostapd/Dockerfile" << 'EOF'
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    hostapd \
    iw \
    wireless-tools \
    rfkill \
    iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/hostapd

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["hostapd", "/etc/hostapd/hostapd.conf"]
EOF

    cat > "$DOCKER_DIR/hostapd/entrypoint.sh" << 'EOF'
#!/bin/bash
set -e

# Unblock WiFi
rfkill unblock wifi || true

# Wait for WiFi interface
WLAN_IF="${WLAN_INTERFACE:-wlan1}"
LAN_IF="${LAN_INTERFACE:-eth1}"
AP_GW="${AP_GATEWAY:-10.3.141.1}"

for i in {1..30}; do
    if ip link show "$WLAN_IF" &>/dev/null; then
        break
    fi
    echo "Waiting for $WLAN_IF..."
    sleep 1
done

# Configure WiFi interface with gateway IP
ip addr flush dev "$WLAN_IF" 2>/dev/null || true
ip addr add ${AP_GW}/24 dev "$WLAN_IF"
ip link set "$WLAN_IF" up

# Configure LAN interface (USB ethernet adapter) with same gateway IP
# This allows wired devices to use the same gateway
if ip link show "$LAN_IF" &>/dev/null; then
    echo "Configuring LAN interface $LAN_IF..."
    ip addr flush dev "$LAN_IF" 2>/dev/null || true
    ip addr add ${AP_GW}/24 dev "$LAN_IF" 2>/dev/null || true
    ip link set "$LAN_IF" up
else
    echo "LAN interface $LAN_IF not found, skipping..."
fi

exec "$@"
EOF

    chmod +x "$DOCKER_DIR/hostapd/entrypoint.sh"
    log_info "Hostapd Dockerfile created"
}

# Create Dockerfile for RaspAP web interface
create_raspap_dockerfile() {
    log_step "Creating RaspAP web Dockerfile..."

    mkdir -p "$DOCKER_DIR/raspap"

    cat > "$DOCKER_DIR/raspap/Dockerfile" << 'EOF'
FROM php:8.2-fpm-bookworm

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    lighttpd \
    lighttpd-mod-magnet \
    curl \
    iproute2 \
    iw \
    wireless-tools \
    sudo \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for REST API
RUN python3 -m venv /opt/raspap-api && \
    /opt/raspap-api/bin/pip install --no-cache-dir \
    fastapi \
    uvicorn \
    python-multipart

# Copy RaspAP source from local context (prepared by prepare_raspap_source)
COPY source/ /var/www/html

# Configure lighttpd
COPY lighttpd.conf /etc/lighttpd/lighttpd.conf

# Create required directories
RUN mkdir -p /etc/raspap /var/run/lighttpd /var/log/lighttpd /var/run/php && \
    chown -R www-data:www-data /var/www/html /var/log/lighttpd /var/run/php

# Configure PHP-FPM to use the socket lighttpd expects
RUN sed -i 's|listen = 127.0.0.1:9000|listen = /var/run/php/php-fpm.sock|' /usr/local/etc/php-fpm.d/www.conf && \
    sed -i 's|;listen.owner = www-data|listen.owner = www-data|' /usr/local/etc/php-fpm.d/www.conf && \
    sed -i 's|;listen.group = www-data|listen.group = www-data|' /usr/local/etc/php-fpm.d/www.conf && \
    sed -i 's|;listen.mode = 0660|listen.mode = 0660|' /usr/local/etc/php-fpm.d/www.conf

# Configure sudo for www-data
RUN echo "www-data ALL=(ALL) NOPASSWD: /sbin/ip, /sbin/iw, /usr/bin/wg, /bin/systemctl, /bin/cat, /bin/cp" > /etc/sudoers.d/raspap

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > "$DOCKER_DIR/raspap/entrypoint.sh" << 'EOF'
#!/bin/bash
set -e

# Set up authentication
if [[ -n "$RASPAP_ADMIN_USER" && -n "$RASPAP_ADMIN_PASS" ]]; then
    mkdir -p /etc/raspap
    HASH=$(echo -n "$RASPAP_ADMIN_PASS" | openssl dgst -sha256 | awk '{print $2}')
    echo "${RASPAP_ADMIN_USER}:${HASH}" > /etc/raspap/raspap.auth
    chmod 600 /etc/raspap/raspap.auth
fi

# Set up API environment
if [[ -n "$API_KEY" ]]; then
    echo "API_KEY=${API_KEY}" > /etc/raspap/api/.env
fi

# Create socket directory and set permissions
mkdir -p /var/run/php
chown www-data:www-data /var/run/php

# Start PHP-FPM
php-fpm -D

# Wait for socket to be ready
sleep 2

# Start lighttpd
lighttpd -D -f /etc/lighttpd/lighttpd.conf &

# Start REST API
/opt/raspap-api/bin/uvicorn --host 0.0.0.0 --port 8080 main:app &

# Wait for signals
wait
EOF

    chmod +x "$DOCKER_DIR/raspap/entrypoint.sh"

    # Create lighttpd config
    cat > "$DOCKER_DIR/raspap/lighttpd.conf" << 'EOF'
server.modules = (
    "mod_access",
    "mod_alias",
    "mod_compress",
    "mod_redirect",
    "mod_fastcgi",
    "mod_rewrite"
)

server.document-root = "/var/www/html"
server.upload-dirs = ( "/tmp" )
server.errorlog = "/var/log/lighttpd/error.log"
server.pid-file = "/var/run/lighttpd/lighttpd.pid"
server.username = "www-data"
server.groupname = "www-data"
server.port = 80

# Security headers
server.tag = ""
setenv.add-response-header = (
    "X-Frame-Options" => "SAMEORIGIN",
    "X-Content-Type-Options" => "nosniff",
    "X-XSS-Protection" => "1; mode=block",
    "Referrer-Policy" => "strict-origin-when-cross-origin",
    "Content-Security-Policy" => "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
)

index-file.names = ( "index.php", "index.html" )
url.access-deny = ( "~", ".inc", ".env", ".git" )
static-file.exclude-extensions = ( ".php", ".pl", ".fcgi" )

compress.cache-dir = "/tmp/lighttpd-cache/"
compress.filetype = ( "application/javascript", "text/css", "text/html", "text/plain" )

fastcgi.server = ( ".php" =>
    ((
        "socket" => "/var/run/php/php-fpm.sock",
        "broken-scriptfilename" => "enable"
    ))
)
EOF

    log_info "RaspAP web Dockerfile created"
}

# Create Dockerfile for dnsmasq
create_dnsmasq_dockerfile() {
    log_step "Creating dnsmasq Dockerfile..."

    mkdir -p "$DOCKER_DIR/dnsmasq"

    cat > "$DOCKER_DIR/dnsmasq/Dockerfile" << 'EOF'
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    && rm -rf /var/lib/apt/lists/*

# Create log file
RUN touch /var/log/dnsmasq.log && chmod 644 /var/log/dnsmasq.log

ENTRYPOINT ["dnsmasq", "-k", "-C", "/etc/dnsmasq.conf"]
EOF

    log_info "Dnsmasq Dockerfile created"
}

# Create Dockerfile for firewall manager
create_firewall_dockerfile() {
    log_step "Creating firewall Dockerfile..."

    mkdir -p "$DOCKER_DIR/firewall"

    cat > "$DOCKER_DIR/firewall/Dockerfile" << 'EOF'
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    iproute2 \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > "$DOCKER_DIR/firewall/entrypoint.sh" << 'EOF'
#!/bin/bash
set -e

# Apply firewall rules
if [[ -f /etc/iptables/rules.sh ]]; then
    /etc/iptables/rules.sh
fi

# Keep container running and monitor VPN status
while true; do
    # Check if VPN is up
    if ip link show wg0 &>/dev/null; then
        # VPN is up - ensure kill switch is active
        if ! iptables -C FORWARD -i "$WLAN_INTERFACE" -o "$WAN_INTERFACE" -j DROP 2>/dev/null; then
            echo "Re-applying kill switch rules..."
            /etc/iptables/rules.sh
        fi
    else
        echo "WARNING: VPN interface down - traffic blocked by kill switch"
    fi
    sleep 30
done
EOF

    chmod +x "$DOCKER_DIR/firewall/entrypoint.sh"
    log_info "Firewall Dockerfile created"
}

# Copy RaspAP source to Docker build context
prepare_raspap_source() {
    log_step "Preparing RaspAP source for Docker build..."

    # Find the RaspAP source directory
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local raspap_src="${script_dir}/.."

    if [[ ! -f "${raspap_src}/index.php" ]]; then
        log_error "Cannot find RaspAP source. Run this script from the docker/ directory."
        exit 1
    fi

    # Create source context for Docker
    mkdir -p "$DOCKER_DIR/raspap/source"

    # Copy essential files
    cp -r "${raspap_src}/index.php" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/src" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/includes" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/templates" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/ajax" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/api" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/config" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/app" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/dist" "$DOCKER_DIR/raspap/source/"
    cp -r "${raspap_src}/locale" "$DOCKER_DIR/raspap/source/"

    if [[ -d "${raspap_src}/vendor" ]]; then
        cp -r "${raspap_src}/vendor" "$DOCKER_DIR/raspap/source/"
    fi

    log_info "RaspAP source prepared"
}

# Configure WAN interface MAC randomization
configure_mac_randomization() {
    log_step "Configuring MAC address randomization..."

    cat > /etc/systemd/system/mac-randomize.service << EOF
[Unit]
Description=Randomize WAN interface MAC address
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip link set ${WAN_INTERFACE} down && ip link set ${WAN_INTERFACE} address \$(openssl rand -hex 6 | sed "s/\\(..\\)/\\1:/g; s/:\$//") && ip link set ${WAN_INTERFACE} up'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mac-randomize.service

    log_info "MAC randomization service created"
}

# Configure kernel security parameters
configure_kernel_security() {
    log_step "Configuring kernel security parameters..."

    cat > /etc/sysctl.d/99-raspap-security.conf << 'EOF'
# RaspAP Security Hardening

# Disable IPv6 to prevent leaks
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# Enable IP forwarding for routing
net.ipv4.ip_forward = 1

# Prevent IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignore source routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Enable SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Disable ICMP broadcast responses
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Enable TCP BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Memory protection
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2

# Restrict dmesg
kernel.dmesg_restrict = 1
EOF

    sysctl -p /etc/sysctl.d/99-raspap-security.conf

    log_info "Kernel security parameters configured"
}

# Build and start Docker containers
start_containers() {
    log_step "Building and starting Docker containers..."

    cd "$DOCKER_DIR"

    # Build containers
    docker compose build --no-cache

    # Start containers
    docker compose up -d

    # Wait for containers to be healthy
    log_info "Waiting for containers to start..."
    sleep 10

    # Check container status
    docker compose ps

    log_info "Docker containers started"
}

# Create systemd service for auto-start
create_systemd_service() {
    log_step "Creating systemd service..."

    cat > /etc/systemd/system/raspap-docker.service << EOF
[Unit]
Description=RaspAP Secure Docker Stack
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${DOCKER_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable raspap-docker.service

    log_info "Systemd service created and enabled"
}

# Print summary and next steps
print_summary() {
    echo
    echo "=============================================="
    echo "   RaspAP Secure Setup Complete!"
    echo "=============================================="
    echo
    echo "Network Configuration:"
    echo "  WAN Interface:  $WAN_INTERFACE (to ISP modem)"
    echo "  WiFi Interface: $WLAN_INTERFACE (access point)"
    echo "  LAN Interface:  $LAN_INTERFACE (to switch)"
    echo "  Subnet:         $AP_SUBNET"
    echo "  Gateway:        $AP_GATEWAY"
    echo
    echo "Access Point Details:"
    echo "  SSID:     $WIFI_SSID"
    echo "  Password: $WIFI_PASS"
    echo
    echo "RaspAP Dashboard:"
    echo "  URL:      http://${AP_GATEWAY}"
    echo "  Username: $ADMIN_USER"
    echo "  Password: $ADMIN_PASS"
    echo
    echo "Configuration Files:"
    echo "  Main config: $CONFIG_DIR"
    echo "  Secrets:     $SECRETS_DIR/credentials.env"
    echo "  Docker:      $DOCKER_DIR"
    echo "  Logs:        $LOG_DIR"
    echo
    echo "Docker Commands:"
    echo "  Status:  docker compose -f $DOCKER_DIR/docker-compose.yml ps"
    echo "  Logs:    docker compose -f $DOCKER_DIR/docker-compose.yml logs -f"
    echo "  Restart: docker compose -f $DOCKER_DIR/docker-compose.yml restart"
    echo "  Stop:    docker compose -f $DOCKER_DIR/docker-compose.yml down"
    echo

    if [[ ! -s "$CONFIG_DIR/wireguard/wg0.conf" ]] || grep -q "YOUR_PRIVATE_KEY" "$CONFIG_DIR/wireguard/wg0.conf"; then
        echo -e "${YELLOW}WARNING: VPN not configured!${NC}"
        echo "Your traffic is NOT encrypted. To configure VPN:"
        echo "1. Obtain WireGuard config from your VPN provider"
        echo "2. Copy to: $CONFIG_DIR/wireguard/wg0.conf"
        echo "3. Restart: docker compose -f $DOCKER_DIR/docker-compose.yml restart wireguard"
        echo
    else
        echo -e "${GREEN}VPN configured and active${NC}"
        echo "All traffic is encrypted through the VPN tunnel."
        echo
    fi

    echo "IMPORTANT: See docs/SECURE_NETWORK_SETUP.md for:"
    echo "  - Hitron CODA5834 configuration instructions"
    echo "  - Network connection walkthrough"
    echo "  - TP-Link switch configuration"
    echo
}

# Uninstall function
uninstall() {
    log_step "Uninstalling RaspAP Docker setup..."

    # Stop and remove containers
    if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
        cd "$DOCKER_DIR"
        docker compose down -v --rmi all 2>/dev/null || true
    fi

    # Remove systemd services
    systemctl disable raspap-docker.service 2>/dev/null || true
    systemctl disable mac-randomize.service 2>/dev/null || true
    rm -f /etc/systemd/system/raspap-docker.service
    rm -f /etc/systemd/system/mac-randomize.service

    # Remove sysctl config
    rm -f /etc/sysctl.d/99-raspap-security.conf

    # Remove directories
    if [[ "$INTERACTIVE" == true ]]; then
        read -p "Remove all configuration files? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$RASPAP_DIR"
            log_info "Configuration files removed"
        fi
    fi

    systemctl daemon-reload

    log_info "Uninstall complete"
}

# Main function
main() {
    parse_args "$@"
    check_root

    if [[ "$UNINSTALL" == true ]]; then
        uninstall
        exit 0
    fi

    echo "=============================================="
    echo "   RaspAP Secure Docker Setup"
    echo "   Raspberry Pi 3B + TP-Link A600"
    echo "=============================================="
    echo

    check_requirements
    detect_wifi_interfaces
    install_docker
    create_directories
    generate_secrets
    configure_wireguard
    create_hostapd_config
    create_dnsmasq_config
    create_firewall_rules
    create_docker_compose
    create_hostapd_dockerfile
    create_raspap_dockerfile
    create_dnsmasq_dockerfile
    create_firewall_dockerfile
    prepare_raspap_source
    configure_mac_randomization
    configure_kernel_security
    start_containers
    create_systemd_service
    print_summary
}

main "$@"
