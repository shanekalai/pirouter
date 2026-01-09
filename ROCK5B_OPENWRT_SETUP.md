# Rock 5B+ Router Setup Guide - Version 2

Complete setup guide for Radxa Rock 5B+ running Armbian as a secure router with WireGuard VPN, Twingate, and optional web management interfaces.

## Changes from Version 1

**Version 2 includes critical fixes and improvements:**

1. **Interface Assignment Swap**: USB ethernet now handles WAN (more tolerant of DHCP issues), onboard ethernet handles LAN (more reliable for local devices)
2. **Dual Subnet Design**: WiFi (10.3.141.0/24) and Wired LAN (10.3.142.0/24) are now separated to prevent routing conflicts
3. **WireGuard Fixes**: Removed DNS directive (caused resolvconf failures) and IPv6 from AllowedIPs (IPv6 disabled on system)
4. **systemd-resolved Disabled**: Prevents conflicts with dnsmasq
5. **USB Autosuspend Disabled**: Prevents ethernet adapter disconnections
6. **WireGuard Watchdog**: Automatically monitors and restores VPN routes if lost
7. **Firewall Consolidation**: Dedicated systemd service instead of WireGuard PostUp/PostDown
8. **Netplan Security**: Proper permissions (chmod 600) on network config files
9. **Improved Service Ordering**: Proper systemd dependencies for reliable startup

## Hardware Configuration

| Component | Interface | Purpose |
|-----------|-----------|---------|
| USB Ethernet | `enx9c69d33ab2f0` | WAN (Hitron modem) |
| Onboard Ethernet | `enP4p65s0` | LAN (TP-Link switch) |
| Built-in WiFi | `wlP2p33s0` | Wireless AP |
| TP-Link Switch | 10.3.142.250 | Wired LAN devices |

## Network Topology

```
Internet → Hitron (192.168.0.1) → Rock 5B+ WAN (DHCP)
                                        ↓
                    ┌───────────────────┼───────────────────┐
                    ↓                   ↓                   ↓
              WireGuard VPN      WiFi AP (wlP2p33s0)   Onboard Ethernet
              (ProtonVPN)        10.3.141.1            10.3.142.1
                    ↓                   ↓                   ↓
              All traffic         WiFi Clients      TP-Link Switch
              encrypted          10.3.141.x         10.3.142.250
                                                          ↓
                                                    Wired Clients
                                                    10.3.142.x
```

## IP Address Scheme

| Network | Subnet | Gateway | DHCP Range | Purpose |
|---------|--------|---------|------------|---------|
| WAN (Hitron) | 192.168.0.0/24 | 192.168.0.1 | N/A | ISP network |
| WiFi LAN | 10.3.141.0/24 | 10.3.141.1 | .50-.200 | Wireless devices |
| Wired LAN | 10.3.142.0/24 | 10.3.142.1 | .50-.200 | Wired devices |
| Docker | 172.30.0.0/24 | N/A | N/A | Container network |
| VPN Tunnel | 10.2.0.2/32 | 10.2.0.1 | N/A | WireGuard tunnel |

---

## Quick Start with Automated Script

The easiest way to set up your Rock 5B+ router is using the automated setup script:

```bash
# Download the setup script
cd /home/user/pirouter
chmod +x rock5b-setup.sh

# Edit configuration variables at the top of the script
sudo nano rock5b-setup.sh
# Change: WIFI_PASSWORD, TWINGATE_ACCESS_TOKEN, TWINGATE_REFRESH_TOKEN

# Run the script
sudo ./rock5b-setup.sh

# Reboot after completion
sudo reboot
```

The script automatically configures all components. For manual setup or troubleshooting, continue with the detailed phases below.

---

## Phase 1: System Preparation

### Step 1.1: Update System and Install Dependencies

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install -y \
    curl \
    wget \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    net-tools \
    bridge-utils \
    iptables \
    iptables-persistent \
    wireless-tools \
    hostapd \
    dnsmasq \
    wireguard-tools \
    qrencode \
    jq
```

### Step 1.2: Install Docker

```bash
# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository (Armbian is Debian-based)
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add current user to docker group
sudo usermod -aG docker $USER

# Enable Docker to start on boot
sudo systemctl enable docker
sudo systemctl start docker
```

### Step 1.3: Verify Docker Installation

```bash
# Test Docker (may need to log out/in for group changes)
sudo docker run --rm hello-world
```

---

## Phase 2: Network Configuration

### Step 2.1: Enable IP Forwarding and System Hardening

```bash
# Enable IP forwarding permanently with security hardening
sudo tee /etc/sysctl.d/99-router.conf << 'EOF'
# Enable IP forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Disable IPv6 (prevents leaks, optional)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# Security hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
EOF

# Apply settings
sudo sysctl --system
```

### Step 2.2: Disable USB Autosuspend (Critical for Stability)

```bash
# Prevent USB ethernet from disconnecting
sudo tee /etc/udev/rules.d/50-usb-ethernet-power.rules << 'EOF'
# Disable autosuspend for USB ethernet adapters
ACTION=="add", SUBSYSTEM=="usb", DRIVER=="r8152", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", DRIVER=="cdc_ether", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", DRIVER=="cdc_ncm", ATTR{power/control}="on"
EOF

# Apply rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### Step 2.3: Disable systemd-resolved

```bash
# systemd-resolved conflicts with dnsmasq
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved

# Create static resolv.conf
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
```

### Step 2.4: Configure Network Interfaces with Netplan

```bash
# Create netplan configuration with dual subnets
sudo tee /etc/netplan/01-router-config.yaml << 'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    # WAN interface - USB Ethernet to Hitron modem (DHCP)
    enx9c69d33ab2f0:
      dhcp4: true
      dhcp4-overrides:
        use-dns: false

    # LAN interface - Onboard Ethernet to TP-Link switch
    enP4p65s0:
      addresses:
        - 10.3.142.1/24
      dhcp4: false

  # WiFi Access Point interface
  wifis:
    wlP2p33s0:
      addresses:
        - 10.3.141.1/24
      dhcp4: false
      access-points: {}
EOF

# Set secure permissions (IMPORTANT)
sudo chmod 600 /etc/netplan/01-router-config.yaml

# Apply netplan
sudo netplan apply
```

### Step 2.5: Verify Network Configuration

```bash
# Check interfaces
ip addr show enx9c69d33ab2f0  # Should have ISP DHCP address
ip addr show enP4p65s0         # Should have 10.3.142.1/24
ip addr show wlP2p33s0         # Should have 10.3.141.1/24

# Verify routing
ip route show
```

---

## Phase 3: Create Project Directory Structure

```bash
# Create main directory structure
sudo mkdir -p /opt/router/{config,docker,logs,secrets}
sudo mkdir -p /opt/router/config/{wireguard,hostapd,dnsmasq,iptables}

# Set ownership
sudo chown -R $USER:$USER /opt/router

# Create docker-compose directory
mkdir -p /opt/router/docker
```

---

## Phase 4: WireGuard VPN Setup

### Step 4.1: Configure WireGuard

```bash
# Copy your ProtonVPN WireGuard config
# NOTE: DNS line removed (causes resolvconf failures)
# NOTE: IPv6 removed from AllowedIPs (IPv6 disabled)
sudo tee /opt/router/config/wireguard/wg0.conf << 'EOF'
[Interface]
# ProtonVPN Configuration
PrivateKey = OGoNbUSA5buvqsQeGvuqmoAhX82j6aduv531Hg8+6VY=
Address = 10.2.0.2/32

# Note: PostUp/PostDown removed - firewall managed by dedicated service

[Peer]
# US-FREE#103
PublicKey = t00VQfd/5e18CVfZh7DuFSuwYl+TJ75I7NbQf+BcNQc=
# Only IPv4 - IPv6 disabled on this system
AllowedIPs = 0.0.0.0/0
Endpoint = 95.173.217.65:51820
PersistentKeepalive = 25
EOF

# Set proper permissions
sudo chmod 600 /opt/router/config/wireguard/wg0.conf
```

### Step 4.2: Create WireGuard Watchdog Service

```bash
# Create watchdog script to monitor and restore routes
sudo tee /opt/router/config/wireguard/watchdog.sh << 'EOF'
#!/bin/bash
# WireGuard routing watchdog - monitors and restores routes if lost

while true; do
    sleep 60

    # Check if wg0 interface exists and has routes
    if ip link show wg0 &>/dev/null; then
        # Check if VPN route exists
        if ! ip route show | grep -q "default dev wg0"; then
            echo "$(date): WireGuard route lost, attempting to restore..."
            systemctl restart wg-quick@wg0
            sleep 5
            # Reapply firewall rules
            /opt/router/config/iptables/firewall.sh
        fi
    else
        echo "$(date): WireGuard interface down, restarting..."
        systemctl restart wg-quick@wg0
    fi
done
EOF

sudo chmod +x /opt/router/config/wireguard/watchdog.sh

# Create systemd service for watchdog
sudo tee /etc/systemd/system/wireguard-watchdog.service << 'EOF'
[Unit]
Description=WireGuard Route Watchdog
After=wg-quick@wg0.service
Requires=wg-quick@wg0.service

[Service]
Type=simple
ExecStart=/opt/router/config/wireguard/watchdog.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
```

### Step 4.3: Enable WireGuard Service

```bash
# Create symlink for systemd
sudo ln -sf /opt/router/config/wireguard/wg0.conf /etc/wireguard/wg0.conf

# Enable and start WireGuard
sudo systemctl enable wg-quick@wg0
sudo systemctl enable wireguard-watchdog
sudo systemctl start wg-quick@wg0

# Verify connection
sudo wg show
```

---

## Phase 5: WiFi Access Point Setup

### Step 5.1: Configure hostapd

```bash
# Stop NetworkManager control of WiFi (if running)
sudo systemctl stop NetworkManager 2>/dev/null || true

# Configure hostapd
sudo tee /etc/hostapd/hostapd.conf << 'EOF'
# Interface configuration
interface=wlP2p33s0
driver=nl80211

# WiFi settings
ssid=CloudBranch
hw_mode=g
channel=7
ieee80211n=1
wmm_enabled=1

# Security settings
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=YourSecurePassword123
rsn_pairwise=CCMP

# Country code (change to your country)
country_code=US

# Misc settings
ignore_broadcast_ssid=0
max_num_sta=20
EOF

# Set hostapd to use this config
sudo tee /etc/default/hostapd << 'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

# Unmask and enable hostapd
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl start hostapd
```

### Step 5.2: Verify WiFi AP

```bash
# Check hostapd status
sudo systemctl status hostapd

# Check WiFi interface
iw dev wlP2p33s0 info
```

---

## Phase 6: DHCP Server Setup (dnsmasq)

### Step 6.1: Configure dnsmasq for Dual Subnets

```bash
# Backup original config
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.backup 2>/dev/null || true

# Create new dnsmasq config with separate ranges for WiFi and Wired
sudo tee /etc/dnsmasq.conf << 'EOF'
# Interface binding - listen on LAN interfaces only
interface=enP4p65s0
interface=wlP2p33s0
bind-interfaces

# Upstream DNS servers
server=1.1.1.1
server=1.0.0.1

# DHCP range for Wired LAN (10.3.142.x)
dhcp-range=set:wired,10.3.142.50,10.3.142.200,24h

# DHCP range for WiFi (10.3.141.x)
dhcp-range=set:wifi,10.3.141.50,10.3.141.200,24h

# Gateway options (per subnet)
dhcp-option=tag:wired,option:router,10.3.142.1
dhcp-option=tag:wifi,option:router,10.3.141.1

# DNS server (router IP for both networks)
dhcp-option=tag:wired,option:dns-server,10.3.142.1
dhcp-option=tag:wifi,option:dns-server,10.3.141.1

# Static IP reservations
# TP-Link Switch on wired network
dhcp-host=set:wired,*:*:*:*:*:*,tp-link-switch,10.3.142.250

# Domain
domain=local
local=/local/

# Logging
log-queries
log-dhcp
log-facility=/var/log/dnsmasq.log

# Cache settings
cache-size=1000

# Security
bogus-priv
domain-needed
stop-dns-rebind
rebind-localhost-ok
EOF

# Enable and start dnsmasq
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq
```

---

## Phase 7: Firewall Configuration

### Step 7.1: Create iptables Firewall Script

```bash
# Create firewall script with VPN kill switch
sudo tee /opt/router/config/iptables/firewall.sh << 'EOF'
#!/bin/bash
# Firewall configuration for Rock 5B+ Router
# v2 - Updated for swapped interfaces and dual subnets

WAN_INTERFACE="enx9c69d33ab2f0"
LAN_INTERFACE="enP4p65s0"
WIFI_INTERFACE="wlP2p33s0"
VPN_ENDPOINT="95.173.217.65"
VPN_PORT="51820"

# Flush existing rules
iptables -F
iptables -t nat -F
iptables -t mangle -F

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH from LAN only
iptables -A INPUT -i ${LAN_INTERFACE} -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -i ${WIFI_INTERFACE} -p tcp --dport 22 -j ACCEPT

# Allow DHCP
iptables -A INPUT -i ${LAN_INTERFACE} -p udp --dport 67:68 -j ACCEPT
iptables -A INPUT -i ${WIFI_INTERFACE} -p udp --dport 67:68 -j ACCEPT

# Allow DNS
iptables -A INPUT -i ${LAN_INTERFACE} -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i ${LAN_INTERFACE} -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -i ${WIFI_INTERFACE} -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i ${WIFI_INTERFACE} -p tcp --dport 53 -j ACCEPT

# Allow ICMP (ping) from LAN
iptables -A INPUT -i ${LAN_INTERFACE} -p icmp -j ACCEPT
iptables -A INPUT -i ${WIFI_INTERFACE} -p icmp -j ACCEPT

# Allow WireGuard VPN port from WAN
iptables -A INPUT -i ${WAN_INTERFACE} -p udp --dport ${VPN_PORT} -j ACCEPT

# Forward LAN traffic to VPN (both WiFi and Wired)
iptables -A FORWARD -i ${LAN_INTERFACE} -o wg0 -j ACCEPT
iptables -A FORWARD -i ${WIFI_INTERFACE} -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o ${LAN_INTERFACE} -j ACCEPT
iptables -A FORWARD -i wg0 -o ${WIFI_INTERFACE} -j ACCEPT

# Allow LAN to LAN (WiFi <-> Wired communication)
iptables -A FORWARD -i ${LAN_INTERFACE} -o ${WIFI_INTERFACE} -j ACCEPT
iptables -A FORWARD -i ${WIFI_INTERFACE} -o ${LAN_INTERFACE} -j ACCEPT

# NAT for VPN tunnel
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

# VPN KILL SWITCH: Block WAN access if VPN is down
# Only allow VPN endpoint connection on WAN
iptables -A OUTPUT -o ${WAN_INTERFACE} -p udp --dport ${VPN_PORT} -d ${VPN_ENDPOINT} -j ACCEPT
iptables -A OUTPUT -o ${WAN_INTERFACE} -m state --state ESTABLISHED,RELATED -j ACCEPT
# Block all other WAN traffic from LAN (force through VPN)
iptables -A FORWARD -i ${LAN_INTERFACE} -o ${WAN_INTERFACE} -j DROP
iptables -A FORWARD -i ${WIFI_INTERFACE} -o ${WAN_INTERFACE} -j DROP

# Log dropped packets (rate limited)
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "IPT-INPUT-DROP: "
iptables -A FORWARD -m limit --limit 5/min -j LOG --log-prefix "IPT-FORWARD-DROP: "

echo "Firewall rules applied successfully"
EOF

# Make executable
sudo chmod +x /opt/router/config/iptables/firewall.sh

# Run firewall script
sudo /opt/router/config/iptables/firewall.sh

# Save rules persistently
sudo netfilter-persistent save
```

### Step 7.2: Create Firewall Systemd Service

```bash
# Create dedicated systemd service for firewall
sudo tee /etc/systemd/system/router-firewall.service << 'EOF'
[Unit]
Description=Router Firewall Rules
After=network-pre.target
Before=network.target wg-quick@wg0.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/opt/router/config/iptables/firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable firewall service
sudo systemctl daemon-reload
sudo systemctl enable router-firewall.service
```

---

## Phase 8: Docker Containers Setup

### Step 8.1: Create Docker Compose File

```bash
# Create docker-compose.yml with Twingate, Cloudflared, and Portainer
tee /opt/router/docker/docker-compose.yml << 'EOF'
services:
  # Twingate Connector
  twingate:
    image: twingate/connector:1
    container_name: twingate-connector
    restart: unless-stopped
    pull_policy: always
    sysctls:
      - net.ipv4.ping_group_range=0 2147483647
    environment:
      - TWINGATE_NETWORK=cloudbranch
      - TWINGATE_ACCESS_TOKEN=YOUR_ACCESS_TOKEN_HERE
      - TWINGATE_REFRESH_TOKEN=YOUR_REFRESH_TOKEN_HERE
      - TWINGATE_LABEL_HOSTNAME=rock5b-router
      - TWINGATE_LABEL_DEPLOYED_BY=docker-compose
    networks:
      - router-net

  # DNS-over-HTTPS Proxy (Cloudflare)
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared-dns
    restart: unless-stopped
    command: proxy-dns --address 0.0.0.0 --port 5053 --upstream https://1.1.1.1/dns-query --upstream https://1.0.0.1/dns-query
    ports:
      - "5053:5053/udp"
      - "5053:5053/tcp"
    networks:
      - router-net

  # Portainer for container management
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9443:9443"
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - router-net

networks:
  router-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/24

volumes:
  portainer_data:
EOF

# NOTE: Edit the file to add your Twingate tokens
nano /opt/router/docker/docker-compose.yml
```

### Step 8.2: Start Docker Containers

```bash
# Navigate to docker directory
cd /opt/router/docker

# Pull images and start containers
sudo docker compose up -d

# Check container status
sudo docker compose ps
```

---

## Phase 9: Web Management UI (Optional)

### Option 1: Portainer (Already Included)

Portainer provides Docker container management through a web interface.

- **Access**: https://10.3.141.1:9443 or https://10.3.142.1:9443
- **Features**: Container logs, resource monitoring, compose management

### Option 2: Cockpit (Recommended Alternative to OpenWRT)

**Why Cockpit Instead of OpenWRT?**

OpenWRT in Docker has significant limitations:
- Cannot directly manage host networking
- Performance overhead from containerization
- Limited access to kernel features
- Complex configuration required

**Cockpit** provides excellent web-based management for native Linux systems:

```bash
# Install Cockpit
sudo apt install -y cockpit

# Enable and start Cockpit
sudo systemctl enable --now cockpit.socket

# Access Cockpit at:
# https://10.3.141.1:9090 or https://10.3.142.1:9090

# Install additional modules
sudo apt install -y cockpit-networkmanager cockpit-packagekit cockpit-storaged
```

**Cockpit Features:**
- Network interface management
- System resource monitoring
- Service management
- Terminal access
- Log viewer
- Update management

### Option 3: OpenWRT (Not Recommended)

**IMPORTANT**: OpenWRT in Docker is NOT recommended for this setup because:
1. Native tools (netplan, iptables, dnsmasq) are more performant on the host
2. Docker adds unnecessary overhead
3. Limited kernel access restricts router functionality
4. Configuration complexity outweighs benefits

If you still want to run OpenWRT for web UI only (not actual routing):

```bash
# Add OpenWRT service to docker-compose.yml (UI only, not for routing)
tee -a /opt/router/docker/docker-compose.yml << 'EOF'

  # OpenWRT Container (UI only - NOT for actual routing)
  openwrt:
    image: openwrt/rootfs:latest
    container_name: openwrt
    restart: unless-stopped
    privileged: true
    cap_add:
      - NET_ADMIN
      - NET_RAW
    ports:
      - "8080:80"    # LuCI web interface
    networks:
      - router-net
EOF

# Restart containers
cd /opt/router/docker
sudo docker compose up -d
```

Access at: http://10.3.141.1:8080 or http://10.3.142.1:8080

---

## Phase 10: Create Systemd Service for Auto-Start

### Step 10.1: Create Router Service

```bash
# Create systemd service for the complete router stack
sudo tee /etc/systemd/system/router-stack.service << 'EOF'
[Unit]
Description=Router Stack (Docker Compose)
Requires=docker.service
After=docker.service network-online.target router-firewall.service wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/router/docker
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
sudo systemctl daemon-reload
sudo systemctl enable router-stack.service
```

---

## Phase 11: Verification and Testing

### Step 11.1: Check All Services

```bash
# Run all checks
echo "=== WireGuard ===" && sudo wg show && echo ""
echo "=== Hostapd ===" && sudo systemctl status hostapd --no-pager && echo ""
echo "=== Dnsmasq ===" && sudo systemctl status dnsmasq --no-pager && echo ""
echo "=== Docker Containers ===" && sudo docker ps && echo ""
echo "=== Network Interfaces ===" && ip addr show enP4p65s0 | grep inet && ip addr show wlP2p33s0 | grep inet
```

### Step 11.2: Test VPN Connection

```bash
# Check public IP (should show VPN server IP)
curl -s https://ipinfo.io/ip
echo ""

# Check for DNS leaks
curl -s https://ipinfo.io/json | jq .

# Verify kill switch (disconnect VPN, should have no internet)
sudo systemctl stop wg-quick@wg0
curl -s --max-time 5 https://ipinfo.io/ip || echo "Kill switch working - no internet without VPN"
sudo systemctl start wg-quick@wg0
```

### Step 11.3: Test from Client Devices

1. **WiFi Device**: Connect to "CloudBranch" WiFi
   - Should get IP in 10.3.141.50-200 range
   - Gateway should be 10.3.141.1
   - Should be able to browse internet through VPN

2. **Wired Device**: Connect to TP-Link switch
   - Should get IP in 10.3.142.50-200 range
   - Gateway should be 10.3.142.1
   - Should be able to browse internet through VPN

3. **Cross-subnet**: Test WiFi to Wired communication
   - WiFi device should be able to ping wired device
   - Wired device should be able to ping WiFi device

---

## Troubleshooting

### WiFi Not Starting

```bash
# Check hostapd status
sudo systemctl status hostapd
sudo journalctl -u hostapd -n 50

# Check if interface is available
iw dev wlP2p33s0 info

# Try starting manually for debug
sudo hostapd -dd /etc/hostapd/hostapd.conf
```

### No DHCP Addresses on WiFi or Wired

```bash
# Check dnsmasq
sudo systemctl status dnsmasq
sudo journalctl -u dnsmasq -n 50

# Check leases
cat /var/lib/misc/dnsmasq.leases

# Verify interfaces are up
ip addr show enP4p65s0  # Should have 10.3.142.1
ip addr show wlP2p33s0  # Should have 10.3.141.1
```

### VPN Not Connecting

```bash
# Check WireGuard
sudo wg show
sudo journalctl -u wg-quick@wg0 -n 50

# Test endpoint connectivity
ping -c 3 95.173.217.65

# Check for DNS issues (should not have DNS line in wg0.conf)
grep DNS /etc/wireguard/wg0.conf  # Should return nothing

# Check for IPv6 in AllowedIPs (should only have 0.0.0.0/0)
grep AllowedIPs /etc/wireguard/wg0.conf
```

### Routes Disappearing

```bash
# Check watchdog service
sudo systemctl status wireguard-watchdog
sudo journalctl -u wireguard-watchdog -n 50

# Manually check routes
ip route show

# Restart watchdog
sudo systemctl restart wireguard-watchdog
```

### USB Ethernet Disconnecting

```bash
# Check if autosuspend is disabled
cat /sys/bus/usb/devices/*/power/control  # Should show "on" for ethernet

# Check USB errors
sudo dmesg | grep -i usb | tail -20

# Verify udev rules
cat /etc/udev/rules.d/50-usb-ethernet-power.rules
```

### systemd-resolved Conflicts

```bash
# Verify systemd-resolved is disabled
sudo systemctl status systemd-resolved  # Should be inactive/disabled

# Check /etc/resolv.conf
cat /etc/resolv.conf  # Should have 1.1.1.1 and 1.0.0.1

# If still running, force disable
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo systemctl mask systemd-resolved
```

### Twingate Not Connecting

```bash
# Check container logs
sudo docker logs twingate-connector

# Verify tokens are set
sudo docker exec twingate-connector env | grep TWINGATE

# Restart container
sudo docker restart twingate-connector
```

### Clients Can't Communicate Between Subnets

```bash
# Check firewall rules
sudo iptables -L FORWARD -v -n | grep -E "10.3.141|10.3.142"

# Should see rules allowing traffic between interfaces
# If missing, rerun firewall script
sudo /opt/router/config/iptables/firewall.sh
```

---

## Quick Reference Commands

```bash
# Restart all services
sudo systemctl restart wg-quick@wg0 hostapd dnsmasq && sudo docker compose -f /opt/router/docker/docker-compose.yml restart

# View logs
sudo journalctl -f -u wg-quick@wg0 -u hostapd -u dnsmasq -u wireguard-watchdog

# Check connected WiFi clients
iw dev wlP2p33s0 station dump

# Check DHCP leases (both subnets)
cat /var/lib/misc/dnsmasq.leases

# Monitor firewall drops
sudo tail -f /var/log/syslog | grep IPT

# Restart Docker stack
cd /opt/router/docker && sudo docker compose down && sudo docker compose up -d

# Check interface status
ip addr show enx9c69d33ab2f0  # WAN
ip addr show enP4p65s0         # Wired LAN
ip addr show wlP2p33s0         # WiFi

# Check routing table
ip route show

# Test VPN
curl https://ipinfo.io/ip
```

---

## Security Checklist

- [ ] Change default WiFi password in `/etc/hostapd/hostapd.conf`
- [ ] Update Twingate tokens in `/opt/router/docker/docker-compose.yml`
- [ ] Verify VPN kill switch is working (disconnect VPN, verify no internet)
- [ ] Set static IP reservation on Hitron modem for USB ethernet interface
- [ ] Update system regularly: `sudo apt update && sudo apt upgrade`
- [ ] Review firewall logs periodically
- [ ] Backup configuration: `sudo tar -czvf router-backup-$(date +%Y%m%d).tar.gz /opt/router /etc/hostapd /etc/dnsmasq.conf /etc/netplan`
- [ ] Test failover scenarios (VPN disconnect, interface failure)
- [ ] Verify USB autosuspend is disabled
- [ ] Confirm systemd-resolved is disabled

---

## Access Points

| Service | URL | Notes |
|---------|-----|-------|
| Portainer (WiFi) | https://10.3.141.1:9443 | Container management |
| Portainer (Wired) | https://10.3.142.1:9443 | Container management |
| Cockpit (WiFi) | https://10.3.141.1:9090 | System management |
| Cockpit (Wired) | https://10.3.142.1:9090 | System management |
| SSH (WiFi) | ssh user@10.3.141.1 | Command line |
| SSH (Wired) | ssh user@10.3.142.1 | Command line |

---

## File Locations

| Purpose | Path |
|---------|------|
| WireGuard config | `/opt/router/config/wireguard/wg0.conf` |
| WireGuard watchdog | `/opt/router/config/wireguard/watchdog.sh` |
| Hostapd config | `/etc/hostapd/hostapd.conf` |
| Dnsmasq config | `/etc/dnsmasq.conf` |
| Firewall script | `/opt/router/config/iptables/firewall.sh` |
| Firewall service | `/etc/systemd/system/router-firewall.service` |
| Netplan config | `/etc/netplan/01-router-config.yaml` |
| Docker compose | `/opt/router/docker/docker-compose.yml` |
| USB power rules | `/etc/udev/rules.d/50-usb-ethernet-power.rules` |
| System config | `/etc/sysctl.d/99-router.conf` |

---

## Performance Tips

1. **Monitor Resource Usage**: Use Cockpit or `htop` to monitor CPU/RAM
2. **Check Network Throughput**: Use `iperf3` for bandwidth testing
3. **Review Logs Regularly**: Check for errors in journalctl
4. **Update Docker Images**: `cd /opt/router/docker && sudo docker compose pull && sudo docker compose up -d`
5. **Clean Docker**: `sudo docker system prune -a` (removes unused images)

---

## Migration from v1

If you're upgrading from v1 of this setup:

1. **Backup existing configuration**:
   ```bash
   sudo tar -czvf router-backup-v1.tar.gz /opt/router /etc/hostapd /etc/dnsmasq.conf /etc/wireguard
   ```

2. **Note your current setup**: Document interface names, IP addresses, VPN credentials

3. **Physical cable swap**: Move cables to match new interface assignments
   - Move Hitron modem cable to USB ethernet (enx9c69d33ab2f0)
   - Move TP-Link switch cable to onboard ethernet (enP4p65s0)

4. **Run updated setup script**: The v2 script is idempotent and can be run multiple times

5. **Update client expectations**: WiFi clients will now be on 10.3.141.x, wired clients on 10.3.142.x

6. **Test thoroughly**: Verify VPN, DHCP, inter-subnet communication before relying on new setup

---

## Additional Resources

- [WireGuard Documentation](https://www.wireguard.com/)
- [Netplan Reference](https://netplan.io/reference)
- [Dnsmasq Manual](https://thekelleys.org.uk/dnsmasq/doc.html)
- [Cockpit Project](https://cockpit-project.org/)
- [Portainer Documentation](https://docs.portainer.io/)
- [Rock 5B+ Documentation](https://wiki.radxa.com/Rock5/5b)

---

## Support and Contributions

For issues or improvements, please review logs carefully and check the troubleshooting section. Common issues are almost always related to:

1. Interface names (verify with `ip addr`)
2. systemd-resolved conflicts (verify it's disabled)
3. USB autosuspend (verify udev rules)
4. WireGuard DNS/IPv6 issues (verify config is clean)
5. Service ordering (verify systemd dependencies)

This setup emphasizes reliability, security, and maintainability over complexity. All components are standard Linux tools with extensive community support.
