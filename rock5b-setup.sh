#!/bin/bash
#
# Rock 5B+ Router Setup Script
# Configures Armbian as a secure router with WireGuard VPN, WiFi AP, and Twingate
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Rock 5B+ Router Setup Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Configuration variables - EDIT THESE
WIFI_SSID="CloudBranch"
WIFI_PASSWORD="YourSecurePassword123"  # CHANGE THIS!
WAN_INTERFACE="enP4p65s0"
LAN_INTERFACE="enx9c69d33ab2f0"
WIFI_INTERFACE="wlP2p33s0"
LAN_IP="10.3.141.1"
LAN_SUBNET="10.3.141.0/24"
DHCP_START="10.3.141.50"
DHCP_END="10.3.141.200"
VPN_ENDPOINT="95.173.217.65"
VPN_PORT="51820"

# Twingate Configuration
TWINGATE_NETWORK="cloudbranch"
TWINGATE_ACCESS_TOKEN="eyJhbGciOiJFUzI1NiIsImtpZCI6ImF6cEZlX3FxQjdJdi0xUXBnUkxMWkw1akpldHhMdjFUckVSTzRvVDFYOUEiLCJ0eXAiOiJEQVQifQ.eyJhdWRzIjpudWxsLCJudCI6IkFOIiwiYWlkIjoiNzA0MDI3IiwiZGlkIjoiMjg2MTA3NSIsInJudyI6MTc2Nzk2Nzc4NywianRpIjoiYjgzNTFmNWQtYTk3MC00MTBlLWEzM2YtOTY2YjNhY2FlMTIzIiwiaXNzIjoidHdpbmdhdGUiLCJhdWQiOiJjbG91ZGJyYW5jaCIsImV4cCI6MTc2Nzk3MTA3NSwiaWF0IjoxNzY3OTY3NDc1LCJ2ZXIiOiI0IiwidGlkIjoiMTk5MTE0Iiwicm5ldGlkIjoiMjY1NTMyIn0.h6gtJHQp0Nx8E-x9_smmGE-qKRPRMWAtdKvMLICUTtRTtA1VHw7CPdHuemFKtvLbGmnitemcGPtH2zhtAJfr9Q"
TWINGATE_REFRESH_TOKEN="YcE1UsCkpfyhHtdHxcYTUKSb5fQue_mxoBYICPzvNgOsFiUxPwCFrKdkQu0DHfODAID6GZFX1Ae58BjkyENuYxjTJjX43BzkD1P-Vg8awX6Fzc2LkbCYOEip3eVo_4dvhRCGAw"

echo -e "${YELLOW}Configuration:${NC}"
echo "  WiFi SSID: $WIFI_SSID"
echo "  WAN Interface: $WAN_INTERFACE"
echo "  LAN Interface: $LAN_INTERFACE"
echo "  WiFi Interface: $WIFI_INTERFACE"
echo "  LAN IP: $LAN_IP"
echo ""
echo -e "${YELLOW}Press Enter to continue or Ctrl+C to cancel...${NC}"
read

# ============================================
# PHASE 1: System Update and Dependencies
# ============================================
echo -e "${GREEN}[Phase 1] Installing dependencies...${NC}"

apt update
apt install -y \
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

echo -e "${GREEN}[Phase 1] Dependencies installed${NC}"

# ============================================
# PHASE 2: Install Docker
# ============================================
echo -e "${GREEN}[Phase 2] Installing Docker...${NC}"

if ! command -v docker &> /dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}[Phase 2] Docker installed${NC}"
else
    echo -e "${YELLOW}[Phase 2] Docker already installed, skipping${NC}"
fi

# ============================================
# PHASE 3: System Configuration
# ============================================
echo -e "${GREEN}[Phase 3] Configuring system...${NC}"

# Enable IP forwarding and security hardening
cat > /etc/sysctl.d/99-router.conf << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
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

sysctl --system

echo -e "${GREEN}[Phase 3] System configured${NC}"

# ============================================
# PHASE 4: Create Directory Structure
# ============================================
echo -e "${GREEN}[Phase 4] Creating directory structure...${NC}"

mkdir -p /opt/router/{config,docker,logs,secrets}
mkdir -p /opt/router/config/{wireguard,hostapd,dnsmasq,iptables}

echo -e "${GREEN}[Phase 4] Directories created${NC}"

# ============================================
# PHASE 5: Network Configuration
# ============================================
echo -e "${GREEN}[Phase 5] Configuring network interfaces...${NC}"

# Configure LAN interface
cat > /etc/netplan/01-router-config.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN_INTERFACE}:
      dhcp4: true
    ${LAN_INTERFACE}:
      addresses:
        - ${LAN_IP}/24
      dhcp4: false
EOF

netplan apply
sleep 2

echo -e "${GREEN}[Phase 5] Network configured${NC}"

# ============================================
# PHASE 6: WireGuard VPN Setup
# ============================================
echo -e "${GREEN}[Phase 6] Configuring WireGuard VPN...${NC}"

cat > /opt/router/config/wireguard/wg0.conf << EOF
[Interface]
# ProtonVPN Configuration
PrivateKey = OGoNbUSA5buvqsQeGvuqmoAhX82j6aduv531Hg8+6VY=
Address = 10.2.0.2/32
DNS = 10.2.0.1

PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -o ${LAN_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -A FORWARD -i ${LAN_INTERFACE} -o %i -j ACCEPT
PostUp = iptables -A FORWARD -i %i -o ${WIFI_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -A FORWARD -i ${WIFI_INTERFACE} -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o ${LAN_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -i ${LAN_INTERFACE} -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -o ${WIFI_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -i ${WIFI_INTERFACE} -o %i -j ACCEPT

[Peer]
# US-FREE#103
PublicKey = t00VQfd/5e18CVfZh7DuFSuwYl+TJ75I7NbQf+BcNQc=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${VPN_ENDPOINT}:${VPN_PORT}
PersistentKeepalive = 25
EOF

chmod 600 /opt/router/config/wireguard/wg0.conf
ln -sf /opt/router/config/wireguard/wg0.conf /etc/wireguard/wg0.conf

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0 || echo -e "${YELLOW}WireGuard may need manual start after reboot${NC}"

echo -e "${GREEN}[Phase 6] WireGuard configured${NC}"

# ============================================
# PHASE 7: WiFi Access Point Setup
# ============================================
echo -e "${GREEN}[Phase 7] Configuring WiFi Access Point...${NC}"

# Stop NetworkManager from managing WiFi
if systemctl is-active --quiet NetworkManager; then
    nmcli device set ${WIFI_INTERFACE} managed no 2>/dev/null || true
fi

cat > /etc/hostapd/hostapd.conf << EOF
interface=${WIFI_INTERFACE}
driver=nl80211
ssid=${WIFI_SSID}
hw_mode=g
channel=7
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=${WIFI_PASSWORD}
rsn_pairwise=CCMP
country_code=US
ignore_broadcast_ssid=0
max_num_sta=20
EOF

echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

# Set WiFi interface IP manually (hostapd handles the wireless part)
ip addr add ${LAN_IP}/24 dev ${WIFI_INTERFACE} 2>/dev/null || true
ip link set ${WIFI_INTERFACE} up

systemctl unmask hostapd
systemctl enable hostapd
systemctl restart hostapd || echo -e "${YELLOW}Hostapd may need manual start${NC}"

echo -e "${GREEN}[Phase 7] WiFi AP configured${NC}"

# ============================================
# PHASE 8: DHCP Server Setup
# ============================================
echo -e "${GREEN}[Phase 8] Configuring DHCP server...${NC}"

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.backup 2>/dev/null || true

cat > /etc/dnsmasq.conf << EOF
interface=${LAN_INTERFACE}
interface=${WIFI_INTERFACE}
bind-interfaces

server=10.2.0.1
server=1.1.1.1
server=1.0.0.1

dhcp-range=${DHCP_START},${DHCP_END},24h
dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}

domain=local
local=/local/

log-queries
log-dhcp
log-facility=/var/log/dnsmasq.log

cache-size=1000
bogus-priv
domain-needed
stop-dns-rebind
rebind-localhost-ok
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

echo -e "${GREEN}[Phase 8] DHCP configured${NC}"

# ============================================
# PHASE 9: Firewall Configuration
# ============================================
echo -e "${GREEN}[Phase 9] Configuring firewall...${NC}"

cat > /opt/router/config/iptables/firewall.sh << EOF
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

# Allow WireGuard
iptables -A INPUT -p udp --dport 51820 -j ACCEPT

# Forward LAN traffic to VPN
iptables -A FORWARD -i ${LAN_INTERFACE} -o wg0 -j ACCEPT
iptables -A FORWARD -i ${WIFI_INTERFACE} -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o ${LAN_INTERFACE} -j ACCEPT
iptables -A FORWARD -i wg0 -o ${WIFI_INTERFACE} -j ACCEPT

# Allow LAN to LAN (WiFi <-> Wired)
iptables -A FORWARD -i ${LAN_INTERFACE} -o ${WIFI_INTERFACE} -j ACCEPT
iptables -A FORWARD -i ${WIFI_INTERFACE} -o ${LAN_INTERFACE} -j ACCEPT

# NAT for VPN tunnel
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

# KILL SWITCH: Block WAN access if VPN is down
iptables -A OUTPUT -o ${WAN_INTERFACE} -p udp --dport ${VPN_PORT} -d ${VPN_ENDPOINT} -j ACCEPT
iptables -A OUTPUT -o ${WAN_INTERFACE} -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i ${LAN_INTERFACE} -o ${WAN_INTERFACE} -j DROP
iptables -A FORWARD -i ${WIFI_INTERFACE} -o ${WAN_INTERFACE} -j DROP

# Log dropped packets
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "IPT-INPUT-DROP: "
iptables -A FORWARD -m limit --limit 5/min -j LOG --log-prefix "IPT-FORWARD-DROP: "

echo "Firewall rules applied"
EOF

chmod +x /opt/router/config/iptables/firewall.sh
/opt/router/config/iptables/firewall.sh
netfilter-persistent save

echo -e "${GREEN}[Phase 9] Firewall configured${NC}"

# ============================================
# PHASE 10: Docker Containers Setup
# ============================================
echo -e "${GREEN}[Phase 10] Setting up Docker containers...${NC}"

cat > /opt/router/docker/docker-compose.yml << EOF
services:
  twingate:
    image: twingate/connector:1
    container_name: twingate-connector
    restart: unless-stopped
    pull_policy: always
    sysctls:
      - net.ipv4.ping_group_range=0 2147483647
    environment:
      - TWINGATE_NETWORK=${TWINGATE_NETWORK}
      - TWINGATE_ACCESS_TOKEN=\${TWINGATE_ACCESS_TOKEN}
      - TWINGATE_REFRESH_TOKEN=\${TWINGATE_REFRESH_TOKEN}
      - TWINGATE_LABEL_HOSTNAME=rock5b-router
      - TWINGATE_LABEL_DEPLOYED_BY=docker-compose
    networks:
      - router-net

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

cat > /opt/router/docker/.env << EOF
TWINGATE_ACCESS_TOKEN=${TWINGATE_ACCESS_TOKEN}
TWINGATE_REFRESH_TOKEN=${TWINGATE_REFRESH_TOKEN}
EOF

chmod 600 /opt/router/docker/.env

cd /opt/router/docker
docker compose pull
docker compose up -d

echo -e "${GREEN}[Phase 10] Docker containers started${NC}"

# ============================================
# PHASE 11: Create Systemd Service
# ============================================
echo -e "${GREEN}[Phase 11] Creating systemd service...${NC}"

cat > /etc/systemd/system/router-stack.service << EOF
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

systemctl daemon-reload
systemctl enable router-stack.service

echo -e "${GREEN}[Phase 11] Systemd service created${NC}"

# ============================================
# COMPLETE - Show Status
# ============================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Services Status:${NC}"
echo ""

echo "WireGuard:"
wg show 2>/dev/null || echo "  (Not connected yet - may need reboot)"
echo ""

echo "Docker Containers:"
docker ps --format "table {{.Names}}\t{{.Status}}"
echo ""

echo "Network Interfaces:"
echo "  LAN (${LAN_INTERFACE}): $(ip addr show ${LAN_INTERFACE} 2>/dev/null | grep 'inet ' | awk '{print $2}')"
echo "  WiFi (${WIFI_INTERFACE}): $(ip addr show ${WIFI_INTERFACE} 2>/dev/null | grep 'inet ' | awk '{print $2}')"
echo ""

echo -e "${YELLOW}Important Next Steps:${NC}"
echo "1. Change WiFi password in /etc/hostapd/hostapd.conf"
echo "2. Reserve IP 192.168.0.10 for this device on Hitron"
echo "3. Reboot to verify everything starts automatically"
echo "4. Access Portainer at https://${LAN_IP}:9443"
echo ""
echo -e "${YELLOW}To verify VPN:${NC}"
echo "  curl https://ipinfo.io/ip"
echo ""
echo -e "${GREEN}Reboot recommended: sudo reboot${NC}"
