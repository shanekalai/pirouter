# Rock 5B+ OpenWRT Router Setup Guide

Complete setup guide for Radxa Rock 5B+ running Armbian as a secure router with OpenWRT, Twingate, and WireGuard VPN in Docker containers.

## Hardware Configuration

| Component | Interface | Purpose |
|-----------|-----------|---------|
| Onboard Ethernet | `enP4p65s0` | WAN (Hitron modem) |
| USB Ethernet | `enx9c69d33ab2f0` | LAN (TP-Link switch) |
| Built-in WiFi | `wlP2p33s0` | Wireless AP |
| TP-Link Switch | 10.3.141.250 | Wired LAN devices |

## Network Topology

```
Internet → Hitron (192.168.0.1) → Rock 5B+ (192.168.0.10)
                                        ↓
                    ┌───────────────────┼───────────────────┐
                    ↓                   ↓                   ↓
              WireGuard VPN      WiFi AP (wlP2p33s0)   USB Ethernet
              (ProtonVPN)        10.3.141.1            10.3.141.1
                    ↓                   ↓                   ↓
              All traffic         WiFi Clients      TP-Link Switch
              encrypted          10.3.141.x         10.3.141.250
                                                          ↓
                                                    Wired Clients
                                                    10.3.141.x
```

## IP Address Scheme

| Network | Subnet | Purpose |
|---------|--------|---------|
| WAN (Hitron) | 192.168.0.0/24 | ISP network |
| LAN | 10.3.141.0/24 | Internal network (WiFi + Wired) |
| Docker | 172.30.0.0/24 | Container network |
| VPN Tunnel | 10.2.0.2/32 | WireGuard tunnel |

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
    qrencode
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

### Step 2.1: Enable IP Forwarding

```bash
# Enable IP forwarding permanently
sudo tee /etc/sysctl.d/99-router.conf << 'EOF'
# Enable IP forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Disable IPv6 (optional, prevents leaks)
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

### Step 2.2: Configure Static IP for LAN Interface

```bash
# Create netplan configuration for the LAN interface
sudo tee /etc/netplan/01-router-config.yaml << 'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    # WAN - Hitron modem (DHCP or static)
    enP4p65s0:
      dhcp4: true
      # Uncomment for static IP:
      # addresses:
      #   - 192.168.0.10/24
      # routes:
      #   - to: default
      #     via: 192.168.0.1
      # nameservers:
      #   addresses: [1.1.1.1, 8.8.8.8]

    # LAN - USB Ethernet to switch
    enx9c69d33ab2f0:
      addresses:
        - 10.3.141.1/24
      dhcp4: false
EOF

# Apply netplan
sudo netplan apply
```

### Step 2.3: Verify Network Configuration

```bash
# Check interfaces
ip addr show enP4p65s0
ip addr show enx9c69d33ab2f0

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
sudo tee /opt/router/config/wireguard/wg0.conf << 'EOF'
[Interface]
# ProtonVPN Configuration
PrivateKey = OGoNbUSA5buvqsQeGvuqmoAhX82j6aduv531Hg8+6VY=
Address = 10.2.0.2/32
DNS = 10.2.0.1

# Firewall rules for routing LAN traffic through VPN
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -o enx9c69d33ab2f0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -A FORWARD -i enx9c69d33ab2f0 -o %i -j ACCEPT
PostUp = iptables -A FORWARD -i %i -o wlP2p33s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -A FORWARD -i wlP2p33s0 -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o enx9c69d33ab2f0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -i enx9c69d33ab2f0 -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -o wlP2p33s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -i wlP2p33s0 -o %i -j ACCEPT

[Peer]
# US-FREE#103
PublicKey = t00VQfd/5e18CVfZh7DuFSuwYl+TJ75I7NbQf+BcNQc=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 95.173.217.65:51820
PersistentKeepalive = 25
EOF

# Set proper permissions
sudo chmod 600 /opt/router/config/wireguard/wg0.conf
```

### Step 4.2: Enable WireGuard Service

```bash
# Create symlink for systemd
sudo ln -sf /opt/router/config/wireguard/wg0.conf /etc/wireguard/wg0.conf

# Enable and start WireGuard
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# Verify connection
sudo wg show
```

---

## Phase 5: WiFi Access Point Setup

### Step 5.1: Configure hostapd

```bash
# Stop and disable NetworkManager control of WiFi (if running)
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

# 802.11ac support (if available)
ieee80211ac=1

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
```

### Step 5.2: Configure WiFi Interface IP

```bash
# Add WiFi interface to netplan
sudo tee /etc/netplan/02-wifi-ap.yaml << 'EOF'
network:
  version: 2
  renderer: networkd
  wifis:
    wlP2p33s0:
      addresses:
        - 10.3.141.1/24
      dhcp4: false
      access-points: {}
EOF

# Apply netplan
sudo netplan apply
```

---

## Phase 6: DHCP Server Setup (dnsmasq)

### Step 6.1: Configure dnsmasq

```bash
# Backup original config
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.backup 2>/dev/null || true

# Create new dnsmasq config
sudo tee /etc/dnsmasq.conf << 'EOF'
# Interface binding - listen on LAN interfaces only
interface=enx9c69d33ab2f0
interface=wlP2p33s0
bind-interfaces

# Upstream DNS (use VPN's DNS or Cloudflare)
server=10.2.0.1
server=1.1.1.1
server=1.0.0.1

# DHCP range for LAN (shared pool for WiFi and wired)
dhcp-range=10.3.141.50,10.3.141.200,24h

# Gateway
dhcp-option=option:router,10.3.141.1

# DNS server
dhcp-option=option:dns-server,10.3.141.1

# Domain
domain=local
local=/local/

# Static IP reservations
# TP-Link Switch
dhcp-host=*:*:*:*:*:*,tp-link-switch,10.3.141.250

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

### Step 7.1: Create iptables Rules

```bash
# Create firewall script
sudo tee /opt/router/config/iptables/firewall.sh << 'EOF'
#!/bin/bash

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
iptables -A INPUT -i enx9c69d33ab2f0 -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -i wlP2p33s0 -p tcp --dport 22 -j ACCEPT

# Allow DHCP
iptables -A INPUT -i enx9c69d33ab2f0 -p udp --dport 67:68 -j ACCEPT
iptables -A INPUT -i wlP2p33s0 -p udp --dport 67:68 -j ACCEPT

# Allow DNS
iptables -A INPUT -i enx9c69d33ab2f0 -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i enx9c69d33ab2f0 -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -i wlP2p33s0 -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i wlP2p33s0 -p tcp --dport 53 -j ACCEPT

# Allow ICMP (ping) from LAN
iptables -A INPUT -i enx9c69d33ab2f0 -p icmp -j ACCEPT
iptables -A INPUT -i wlP2p33s0 -p icmp -j ACCEPT

# Allow WireGuard
iptables -A INPUT -p udp --dport 51820 -j ACCEPT

# Forward LAN traffic to VPN
iptables -A FORWARD -i enx9c69d33ab2f0 -o wg0 -j ACCEPT
iptables -A FORWARD -i wlP2p33s0 -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o enx9c69d33ab2f0 -j ACCEPT
iptables -A FORWARD -i wg0 -o wlP2p33s0 -j ACCEPT

# Allow LAN to LAN (WiFi <-> Wired)
iptables -A FORWARD -i enx9c69d33ab2f0 -o wlP2p33s0 -j ACCEPT
iptables -A FORWARD -i wlP2p33s0 -o enx9c69d33ab2f0 -j ACCEPT

# NAT for VPN tunnel
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

# KILL SWITCH: Block WAN access if VPN is down (except for VPN connection itself)
# Allow only VPN endpoint on WAN
iptables -A OUTPUT -o enP4p65s0 -p udp --dport 51820 -d 95.173.217.65 -j ACCEPT
iptables -A OUTPUT -o enP4p65s0 -m state --state ESTABLISHED,RELATED -j ACCEPT
# Block all other WAN traffic from LAN
iptables -A FORWARD -i enx9c69d33ab2f0 -o enP4p65s0 -j DROP
iptables -A FORWARD -i wlP2p33s0 -o enP4p65s0 -j DROP

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

---

## Phase 8: Docker Containers Setup

### Step 8.1: Create Docker Compose File

```bash
# Create docker-compose.yml
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
      - TWINGATE_ACCESS_TOKEN=${TWINGATE_ACCESS_TOKEN}
      - TWINGATE_REFRESH_TOKEN=${TWINGATE_REFRESH_TOKEN}
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

  # Portainer for container management (optional but helpful)
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
```

### Step 8.2: Create Environment File with Twingate Credentials

```bash
# Create .env file with Twingate tokens
tee /opt/router/docker/.env << 'EOF'
TWINGATE_ACCESS_TOKEN=eyJhbGciOiJFUzI1NiIsImtpZCI6ImF6cEZlX3FxQjdJdi0xUXBnUkxMWkw1akpldHhMdjFUckVSTzRvVDFYOUEiLCJ0eXAiOiJEQVQifQ.eyJhdWRzIjpudWxsLCJudCI6IkFOIiwiYWlkIjoiNzA0MDI3IiwiZGlkIjoiMjg2MTA3NSIsInJudyI6MTc2Nzk2Nzc4NywianRpIjoiYjgzNTFmNWQtYTk3MC00MTBlLWEzM2YtOTY2YjNhY2FlMTIzIiwiaXNzIjoidHdpbmdhdGUiLCJhdWQiOiJjbG91ZGJyYW5jaCIsImV4cCI6MTc2Nzk3MTA3NSwiaWF0IjoxNzY3OTY3NDc1LCJ2ZXIiOiI0IiwidGlkIjoiMTk5MTE0Iiwicm5ldGlkIjoiMjY1NTMyIn0.h6gtJHQp0Nx8E-x9_smmGE-qKRPRMWAtdKvMLICUTtRTtA1VHw7CPdHuemFKtvLbGmnitemcGPtH2zhtAJfr9Q
TWINGATE_REFRESH_TOKEN=YcE1UsCkpfyhHtdHxcYTUKSb5fQue_mxoBYICPzvNgOsFiUxPwCFrKdkQu0DHfODAID6GZFX1Ae58BjkyENuYxjTJjX43BzkD1P-Vg8awX6Fzc2LkbCYOEip3eVo_4dvhRCGAw
EOF

# Secure the .env file
chmod 600 /opt/router/docker/.env
```

### Step 8.3: Start Docker Containers

```bash
# Navigate to docker directory
cd /opt/router/docker

# Pull images and start containers
sudo docker compose up -d

# Check container status
sudo docker compose ps
```

---

## Phase 9: OpenWRT Container (Optional Advanced Setup)

If you want OpenWRT's web interface for advanced router management:

### Step 9.1: Add OpenWRT to Docker Compose

```bash
# Add OpenWRT service to docker-compose.yml
tee -a /opt/router/docker/docker-compose.yml << 'EOF'

  # OpenWRT Container (for web management UI)
  openwrt:
    image: openwrt/rootfs:latest
    container_name: openwrt
    restart: unless-stopped
    privileged: true
    cap_add:
      - NET_ADMIN
      - NET_RAW
    sysctls:
      - net.ipv4.ip_forward=1
    ports:
      - "8080:80"    # LuCI web interface
      - "8443:443"   # HTTPS
    volumes:
      - openwrt_config:/etc/config
    networks:
      - router-net
    command: /sbin/init

volumes:
  openwrt_config:
EOF

# Restart to add OpenWRT
cd /opt/router/docker
sudo docker compose up -d
```

**Note:** OpenWRT in Docker is limited compared to bare-metal. It works best as a management UI while the host handles actual routing.

---

## Phase 10: Create Systemd Service for Auto-Start

### Step 10.1: Create Router Service

```bash
# Create systemd service for the complete router stack
sudo tee /etc/systemd/system/router-stack.service << 'EOF'
[Unit]
Description=Router Stack (Docker Compose)
Requires=docker.service
After=docker.service network-online.target
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

### Step 10.2: Create Startup Script

```bash
# Create comprehensive startup script
sudo tee /opt/router/startup.sh << 'EOF'
#!/bin/bash
# Router Startup Script for Rock 5B+

echo "Starting Rock 5B+ Router Stack..."

# Wait for network
sleep 5

# Apply firewall rules
/opt/router/config/iptables/firewall.sh

# Ensure WireGuard is up
systemctl restart wg-quick@wg0

# Restart hostapd for WiFi AP
systemctl restart hostapd

# Restart dnsmasq for DHCP
systemctl restart dnsmasq

# Start Docker containers
cd /opt/router/docker
docker compose up -d

echo "Router stack started successfully!"

# Show status
echo ""
echo "=== WireGuard Status ==="
wg show

echo ""
echo "=== Docker Containers ==="
docker ps

echo ""
echo "=== Network Interfaces ==="
ip addr show enx9c69d33ab2f0 | grep inet
ip addr show wlP2p33s0 | grep inet
EOF

sudo chmod +x /opt/router/startup.sh
```

---

## Phase 11: Verification and Testing

### Step 11.1: Check All Services

```bash
# Run all checks
echo "=== System Services ===" && \
systemctl status wg-quick@wg0 --no-pager && \
echo "" && \
systemctl status hostapd --no-pager && \
echo "" && \
systemctl status dnsmasq --no-pager && \
echo "" && \
echo "=== Docker Containers ===" && \
sudo docker ps && \
echo "" && \
echo "=== WireGuard ===" && \
sudo wg show && \
echo "" && \
echo "=== Network ===" && \
ip addr show enx9c69d33ab2f0 | grep inet && \
ip addr show wlP2p33s0 | grep inet
```

### Step 11.2: Test VPN Connection

```bash
# Check public IP (should show VPN server IP)
curl -s https://ipinfo.io/ip
echo ""

# Check for DNS leaks
curl -s https://ipinfo.io/json | jq .
```

### Step 11.3: Test from a Client Device

1. Connect a device to WiFi (SSID: CloudBranch)
2. Check if it gets an IP in 10.3.141.x range
3. Try browsing the internet
4. Verify IP shows VPN location at https://whatismyipaddress.com

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

### No DHCP Addresses

```bash
# Check dnsmasq
sudo systemctl status dnsmasq
sudo journalctl -u dnsmasq -n 50

# Check leases
cat /var/lib/misc/dnsmasq.leases
```

### VPN Not Connecting

```bash
# Check WireGuard
sudo wg show
sudo journalctl -u wg-quick@wg0 -n 50

# Test endpoint connectivity
ping -c 3 95.173.217.65
```

### Twingate Not Connecting

```bash
# Check container logs
sudo docker logs twingate-connector

# Restart container
sudo docker restart twingate-connector
```

---

## Quick Reference Commands

```bash
# Restart all services
sudo systemctl restart wg-quick@wg0 hostapd dnsmasq && sudo docker compose -f /opt/router/docker/docker-compose.yml restart

# View logs
sudo journalctl -f -u wg-quick@wg0 -u hostapd -u dnsmasq

# Check connected WiFi clients
iw dev wlP2p33s0 station dump

# Check DHCP leases
cat /var/lib/misc/dnsmasq.leases

# Monitor firewall drops
sudo tail -f /var/log/syslog | grep IPT

# Restart Docker stack
cd /opt/router/docker && sudo docker compose down && sudo docker compose up -d
```

---

## Security Checklist

- [ ] Change default WiFi password in `/etc/hostapd/hostapd.conf`
- [ ] Verify VPN kill switch is working (disconnect VPN, verify no internet)
- [ ] Set static IP reservation on Hitron for 192.168.0.10
- [ ] Update system regularly: `sudo apt update && sudo apt upgrade`
- [ ] Review firewall logs periodically
- [ ] Backup configuration: `sudo tar -czvf router-backup.tar.gz /opt/router /etc/hostapd /etc/dnsmasq.conf`

---

## Access Points

| Service | URL | Notes |
|---------|-----|-------|
| Portainer | https://10.3.141.1:9443 | Container management |
| OpenWRT (optional) | http://10.3.141.1:8080 | Router management UI |
| SSH | ssh router@10.3.141.1 | Command line access |

---

## File Locations

| Purpose | Path |
|---------|------|
| WireGuard config | `/opt/router/config/wireguard/wg0.conf` |
| Hostapd config | `/etc/hostapd/hostapd.conf` |
| Dnsmasq config | `/etc/dnsmasq.conf` |
| Firewall rules | `/opt/router/config/iptables/firewall.sh` |
| Docker compose | `/opt/router/docker/docker-compose.yml` |
| Twingate tokens | `/opt/router/docker/.env` |
