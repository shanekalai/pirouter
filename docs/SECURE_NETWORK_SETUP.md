# Secure Network Setup Guide

Complete step-by-step instructions for configuring a Raspberry Pi 3B as a secure router using RaspAP with WireGuard VPN and DNS-over-HTTPS.

## Network Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Hitron CODA5834 ISP Modem                                │
│                        192.168.0.1 (Gateway)                                 │
│                     DHCP Range: 192.168.0.x                                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Ethernet
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Raspberry Pi 3B (RaspAP)                                │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  eth0 (WAN) ─────────────────────────────────────────────────────── │    │
│  │    • DHCP Client (gets IP from Hitron: 192.168.0.x)                 │    │
│  │    • Gateway to Internet                                             │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                          WireGuard VPN Tunnel                                │
│                            (wg0: 10.2.0.2)                                   │
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  eth1 (LAN) ────────────────────────────────────────────────────────│    │
│  │    • Static IP: 10.3.141.1/24                                        │    │
│  │    • DHCP Server: 10.3.141.50-149                                    │    │
│  │    • Primary LAN interface (wired devices)                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  wlan0 (AP) ────────────────────────────────────────────────────────│    │
│  │    • Static IP: 10.3.141.1/24                                        │    │
│  │    • DHCP Server: 10.3.141.150-249                                   │    │
│  │    • WiFi Access Point (backup/wireless devices)                     │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
┌───────────────────────────────────┐   ┌─────────────────────────────────────┐
│   TP-Link TL-SG108E Switch        │   │        WiFi Clients                 │
│   • Management IP: 10.3.141.250   │   │   • Phones, Laptops, IoT            │
│   • Gateway: 10.3.141.1           │   │   • DHCP: 10.3.141.150-249          │
│   • Ports 1-8: Wired LAN devices  │   │   • SSID: "SecureAP"                │
└───────────────────────────────────┘   └─────────────────────────────────────┘
            │
            ▼
┌───────────────────────────────────┐
│      Wired LAN Devices            │
│   • Desktop PCs, NAS, etc.        │
│   • DHCP: 10.3.141.50-149         │
│   • Or static in 10.3.141.2-49    │
└───────────────────────────────────┘
```

## Hardware Requirements

| Device | Model | Purpose |
|--------|-------|---------|
| Router | Raspberry Pi 3B | Main router running RaspAP |
| ISP Modem | Hitron CODA5834 | Internet gateway |
| USB Ethernet | ASIX AX88179 Gigabit | eth1 - LAN port to switch |
| Switch | TP-Link TL-SG108E | Wired LAN distribution |
| MicroSD | 16GB+ Class 10 | Raspberry Pi storage |

## IP Address Allocation

| Range | Purpose |
|-------|---------|
| 10.3.141.1 | Router (eth1 + wlan0 gateway) |
| 10.3.141.2-49 | Reserved for static IPs |
| 10.3.141.50-149 | DHCP for wired devices (eth1) |
| 10.3.141.150-249 | DHCP for WiFi devices (wlan0) |
| 10.3.141.250 | TP-Link Switch management |
| 10.3.141.251-254 | Reserved for infrastructure |

---

## Part 1: Hitron CODA5834 Modem Configuration

### Step 1.1: Access Modem Admin Panel

1. Connect a computer directly to the Hitron modem via Ethernet
2. Open browser and navigate to `http://192.168.0.1`
3. Login with default credentials (check modem label or ISP documentation)
   - Default is often `cusadmin` / `password` or similar

### Step 1.2: Configure Modem Settings

**Option A: Standard Router Mode (Recommended for beginners)**

Keep the Hitron in router mode. The Pi will perform double-NAT but this is simpler to configure.

1. Go to **Basic** → **DHCP**
2. Ensure DHCP is enabled
3. Note the DHCP range (usually 192.168.0.2 - 192.168.0.253)

**Option B: Bridge Mode (Advanced - Single NAT)**

Puts modem in passthrough mode. Your Pi gets the public IP directly.

1. Go to **Basic** → **Gateway Function**
2. Set **Residential Gateway Function** to **Disabled**
3. Save and reboot modem
4. Note: You may lose access to modem admin panel after this

### Step 1.3: Reserve IP for Raspberry Pi (Router Mode Only)

1. Go to **Basic** → **DHCP** → **Reserved IPs**
2. Add reservation:
   - **MAC Address**: (eth0 MAC from Pi, e.g., `b8:27:eb:f8:27:82`)
   - **IP Address**: `192.168.0.10`
3. Save settings

---

## Part 2: Raspberry Pi Initial Setup

### Step 2.1: Install Raspberry Pi OS

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Flash **Raspberry Pi OS Lite (32-bit)** - Debian Bookworm or Trixie
3. Before ejecting, enable SSH:
   ```bash
   # On the boot partition, create empty file
   touch /Volumes/boot/ssh    # macOS
   touch /media/$USER/boot/ssh # Linux
   ```

### Step 2.2: Initial Boot and Update

1. Connect Pi to Hitron modem via eth0 (onboard Ethernet)
2. Connect USB Ethernet adapter (eth1) - leave disconnected from switch for now
3. Boot Pi and find its IP:
   ```bash
   # From another computer on the network
   nmap -sn 192.168.0.0/24 | grep -i raspberry
   # Or check Hitron DHCP leases
   ```

4. SSH into the Pi:
   ```bash
   ssh pi@192.168.0.x
   # Default password: raspberry
   ```

5. Change default password immediately:
   ```bash
   passwd
   ```

6. Update system:
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo reboot
   ```

### Step 2.3: Identify Network Interfaces

After reboot, identify your interfaces:

```bash
ip link show
```

Expected output:
```
1: lo: <LOOPBACK,UP,LOWER_UP> ...
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...    # Onboard - to Hitron (WAN)
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> ...    # USB adapter - to Switch (LAN)
4: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...   # Onboard WiFi - AP
```

Verify USB adapter is detected:
```bash
lsusb | grep -i ethernet
# Should show: ASIX Electronics Corp. AX88179 Gigabit Ethernet
```

---

## Part 3: Install RaspAP

### Step 3.1: Run RaspAP Installer

```bash
curl -sL https://install.raspap.com | bash
```

During installation:
- **Install ad blocking?** → Y (optional but recommended)
- **Install OpenVPN?** → N (we'll use WireGuard)
- **Install WireGuard?** → Y
- **Enable HttpOnly for cookies?** → Y
- **Enable PHP OPCache?** → Y
- **Reboot now?** → Y

### Step 3.2: Initial RaspAP Access

1. After reboot, the Pi creates a WiFi network:
   - SSID: `raspi-webgui`
   - Password: `ChangeMe`

2. Connect to this WiFi network

3. Open browser: `http://10.3.141.1`

4. Login:
   - Username: `admin`
   - Password: `secret`

5. **Immediately change admin password:**
   - Go to **System** → **Authentication**
   - Set new secure password

---

## Part 4: Configure Network Interfaces

### Step 4.1: Configure eth0 as WAN (DHCP Client)

**Via SSH** (recommended for initial setup):

```bash
sudo nano /etc/dhcpcd.conf
```

Find and modify/add the eth0 section:

```bash
# ===========================================
# WAN Interface (eth0) - Internet from Hitron
# ===========================================
interface eth0
# DHCP client - gets IP from ISP modem
# Do NOT set static IP here

# Optional: Set metric to prefer wired WAN
metric 100
```

**Remove any static IP configuration for eth0** if present.

### Step 4.2: Configure eth1 as LAN (Static IP)

Continue editing `/etc/dhcpcd.conf`:

```bash
# ===========================================
# LAN Interface (eth1) - To Switch
# ===========================================
interface eth1
static ip_address=10.3.141.1/24
nogateway
```

### Step 4.3: Configure wlan0 as AP (Static IP)

Continue editing `/etc/dhcpcd.conf`:

```bash
# ===========================================
# WiFi AP Interface (wlan0) - Wireless Clients
# ===========================================
interface wlan0
static ip_address=10.3.141.1/24
nogateway
```

### Step 4.4: Complete dhcpcd.conf Example

Your complete `/etc/dhcpcd.conf` should look like:

```bash
# RaspAP dhcpcd configuration
hostname
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, host_name
option classless_static_routes
option ntp_servers
require dhcp_server_identifier
slaac private
nohook lookup-hostname

# ===========================================
# WAN Interface (eth0) - Internet from Hitron
# ===========================================
interface eth0
metric 100

# ===========================================
# LAN Interface (eth1) - To Switch
# ===========================================
interface eth1
static ip_address=10.3.141.1/24
nogateway

# ===========================================
# WiFi AP Interface (wlan0) - Wireless Clients
# ===========================================
interface wlan0
static ip_address=10.3.141.1/24
nogateway
```

### Step 4.5: Apply Network Changes

```bash
sudo systemctl restart dhcpcd
```

Verify configuration:
```bash
ip addr show
```

Expected:
- `eth0`: Should have 192.168.0.x (DHCP from Hitron)
- `eth1`: Should have 10.3.141.1/24
- `wlan0`: Should have 10.3.141.1/24

---

## Part 5: Configure DHCP Server (dnsmasq)

### Step 5.1: Remove Conflicting dnsmasq Configs

```bash
# Remove any existing eth0 DHCP config (eth0 is WAN, not LAN!)
sudo rm -f /etc/dnsmasq.d/090_eth0.conf
```

### Step 5.2: Configure eth1 DHCP (Wired LAN)

```bash
sudo nano /etc/dnsmasq.d/090_eth1.conf
```

```bash
# RaspAP eth1 configuration (Wired LAN)
interface=eth1
dhcp-range=10.3.141.50,10.3.141.149,255.255.255.0,12h

# Static lease for TP-Link switch
dhcp-host=XX:XX:XX:XX:XX:XX,10.3.141.250,switch

# Optional: Static leases for other devices
# dhcp-host=AA:BB:CC:DD:EE:FF,10.3.141.51,desktop-pc
```

Replace `XX:XX:XX:XX:XX:XX` with your switch's MAC address.

### Step 5.3: Configure wlan0 DHCP (WiFi)

```bash
sudo nano /etc/dnsmasq.d/090_wlan0.conf
```

```bash
# RaspAP wlan0 configuration (WiFi AP)
interface=wlan0
dhcp-range=10.3.141.150,10.3.141.249,255.255.255.0,12h
domain-needed
```

### Step 5.4: Configure Main dnsmasq Settings

```bash
sudo nano /etc/dnsmasq.d/090_raspap.conf
```

```bash
# RaspAP dnsmasq configuration
log-facility=/var/log/dnsmasq.log
conf-dir=/etc/dnsmasq.d

# DNS Settings
domain-needed
bogus-priv
no-resolv

# Use Cloudflare DNS (will be replaced by DoH proxy later)
server=1.1.1.1
server=1.0.0.1

# Performance
cache-size=10000

# Security
stop-dns-rebind
rebind-localhost-ok
```

### Step 5.5: Restart dnsmasq

```bash
sudo systemctl restart dnsmasq
sudo systemctl status dnsmasq
```

---

## Part 6: Configure WiFi Access Point

### Step 6.1: Configure via RaspAP Web UI

1. Go to **Hotspot** → **Basic**
2. Configure:
   - **Interface**: wlan0
   - **SSID**: `SecureAP` (or your preferred name)
   - **Wireless Mode**: 802.11n - 2.4GHz
   - **Channel**: Auto or specific channel (1, 6, or 11 recommended)

3. Go to **Hotspot** → **Security**
4. Configure:
   - **Security Type**: WPA2 Personal
   - **PSK**: Strong password (12+ characters)

5. Go to **Hotspot** → **Advanced**
6. Configure:
   - **Country Code**: Your country (US, GB, etc.)
   - **Maximum Clients**: 20

7. Click **Save settings**

### Step 6.2: Restart hostapd

```bash
sudo systemctl restart hostapd
```

### Step 6.3: Verify AP is Running

```bash
# Check hostapd status
sudo systemctl status hostapd

# Check AP is broadcasting
iw dev wlan0 info
```

---

## Part 7: Configure IP Forwarding and NAT

### Step 7.1: Enable IP Forwarding

```bash
sudo nano /etc/sysctl.conf
```

Uncomment or add:
```bash
net.ipv4.ip_forward=1
```

Apply:
```bash
sudo sysctl -p
```

### Step 7.2: Configure iptables NAT Rules

Create firewall script:

```bash
sudo nano /etc/raspap/networking/firewall.sh
```

```bash
#!/bin/bash
#
# RaspAP Firewall Rules
# NAT from LAN (eth1 + wlan0) to WAN (eth0)
#

# Variables
WAN="eth0"
LAN="eth1"
WLAN="wlan0"
LAN_NET="10.3.141.0/24"

# Flush existing rules
iptables -F
iptables -t nat -F
iptables -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow LAN to router (DNS, DHCP, HTTP, SSH)
iptables -A INPUT -i $LAN -j ACCEPT
iptables -A INPUT -i $WLAN -j ACCEPT

# Allow forwarding between LAN interfaces
iptables -A FORWARD -i $LAN -o $WLAN -j ACCEPT
iptables -A FORWARD -i $WLAN -o $LAN -j ACCEPT

# Allow LAN to WAN (internet access)
iptables -A FORWARD -i $LAN -o $WAN -j ACCEPT
iptables -A FORWARD -i $WLAN -o $WAN -j ACCEPT

# NAT - Masquerade outgoing traffic
iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE

# Block WAN to LAN (except established)
iptables -A INPUT -i $WAN -m conntrack --ctstate NEW -j DROP

echo "Firewall rules applied"
```

Make executable and run:
```bash
sudo chmod +x /etc/raspap/networking/firewall.sh
sudo /etc/raspap/networking/firewall.sh
```

### Step 7.3: Persist iptables Rules

```bash
sudo apt install iptables-persistent -y
# Answer "Yes" to save current rules
```

Or manually save:
```bash
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

### Step 7.4: Create Systemd Service for Firewall

```bash
sudo nano /etc/systemd/system/raspap-firewall.service
```

```ini
[Unit]
Description=RaspAP Firewall Rules
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/raspap/networking/firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
sudo systemctl enable raspap-firewall
sudo systemctl start raspap-firewall
```

---

## Part 8: Configure TP-Link TL-SG108E Switch

### Step 8.1: Initial Switch Access

1. Connect computer directly to switch
2. Default switch IP: `192.168.0.1`
3. Open browser: `http://192.168.0.1`
4. Default login: `admin` / `admin`

### Step 8.2: Change Switch IP Address

1. Go to **System** → **System Info**
2. Change:
   - **IP Address**: `10.3.141.250`
   - **Subnet Mask**: `255.255.255.0`
   - **Default Gateway**: `10.3.141.1`
3. Click **Apply**

**Important**: After changing IP, you'll lose connection. Reconnect via the Pi network.

### Step 8.3: Connect Switch to Pi

1. Connect switch Port 1 to Pi's eth1 (USB adapter)
2. Wait for Pi to assign DHCP or use static IP

### Step 8.4: Access Switch via New IP

From a device on the LAN:
```bash
# Browser
http://10.3.141.250

# Or ping to verify
ping 10.3.141.250
```

### Step 8.5: Optional Switch Configuration

**Port-based VLAN** (if needed for isolation):
1. Go to **VLAN** → **Port Based VLAN**
2. Configure VLANs as needed

**QoS** (Quality of Service):
1. Go to **QoS** → **Basic**
2. Enable QoS if needed for prioritizing traffic

**Monitoring**:
1. Go to **Monitoring** → **Port Statistics**
2. View traffic on each port

---

## Part 9: Configure WireGuard VPN

### Step 9.1: Get ProtonVPN WireGuard Configuration

1. Log in to [ProtonVPN Account](https://account.protonvpn.com)
2. Go to **Downloads** → **WireGuard configuration**
3. Select a server and download the `.conf` file
4. Note these values:
   - `PrivateKey`
   - `Address`
   - `PublicKey` (from [Peer] section)
   - `Endpoint`

### Step 9.2: Create WireGuard Configuration

```bash
sudo nano /etc/wireguard/wg0.conf
```

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
Address = 10.2.0.2/32
DNS = 10.2.0.1

# Kill switch - block traffic if VPN fails
PostUp = iptables -I FORWARD -i eth1 -o eth0 -j DROP
PostUp = iptables -I FORWARD -i wlan0 -o eth0 -j DROP
PostUp = iptables -I FORWARD -i eth1 -o wg0 -j ACCEPT
PostUp = iptables -I FORWARD -i wlan0 -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

PostDown = iptables -D FORWARD -i eth1 -o eth0 -j DROP
PostDown = iptables -D FORWARD -i wlan0 -o eth0 -j DROP
PostDown = iptables -D FORWARD -i eth1 -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wlan0 -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
PublicKey = VPN_SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
Endpoint = VPN_SERVER_IP:51820
PersistentKeepalive = 25
```

### Step 9.3: Secure the Configuration

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

### Step 9.4: Test WireGuard Connection

```bash
# Start WireGuard
sudo wg-quick up wg0

# Check status
sudo wg show

# Check your public IP (should be VPN server IP)
curl ifconfig.me
```

### Step 9.5: Enable WireGuard on Boot

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
```

### Step 9.6: Configure via RaspAP Web UI (Alternative)

1. Go to **VPN** → **WireGuard**
2. Enable WireGuard
3. Paste your configuration
4. Save and activate

---

## Part 10: Configure DNS-over-HTTPS

### Step 10.1: Install cloudflared

```bash
# Download cloudflared for ARM
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm
sudo mv cloudflared-linux-arm /usr/local/bin/cloudflared
sudo chmod +x /usr/local/bin/cloudflared
```

### Step 10.2: Create cloudflared Configuration

```bash
sudo mkdir -p /etc/cloudflared
sudo nano /etc/cloudflared/config.yml
```

```yaml
proxy-dns: true
proxy-dns-port: 5053
proxy-dns-address: 127.0.0.1
proxy-dns-upstream:
  - https://1.1.1.1/dns-query
  - https://1.0.0.1/dns-query
```

### Step 10.3: Create Systemd Service

```bash
sudo nano /etc/systemd/system/cloudflared.service
```

```ini
[Unit]
Description=Cloudflare DNS-over-HTTPS Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --config /etc/cloudflared/config.yml
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

### Step 10.4: Configure dnsmasq to Use DoH Proxy

Edit `/etc/dnsmasq.d/090_raspap.conf`:

```bash
sudo nano /etc/dnsmasq.d/090_raspap.conf
```

Change DNS servers to local DoH proxy:

```bash
# DNS-over-HTTPS via cloudflared
no-resolv
server=127.0.0.1#5053
```

Restart dnsmasq:
```bash
sudo systemctl restart dnsmasq
```

### Step 10.5: Verify DoH is Working

```bash
# Test DNS resolution
nslookup example.com 127.0.0.1

# Check cloudflared status
sudo systemctl status cloudflared
```

---

## Part 11: Final Firewall Configuration (with VPN Kill Switch)

### Step 11.1: Update Firewall Script

Replace `/etc/raspap/networking/firewall.sh`:

```bash
sudo nano /etc/raspap/networking/firewall.sh
```

```bash
#!/bin/bash
#
# RaspAP Secure Firewall with VPN Kill Switch
#

# Variables
WAN="eth0"
LAN="eth1"
WLAN="wlan0"
VPN="wg0"
LAN_NET="10.3.141.0/24"

# Flush existing rules
iptables -F
iptables -t nat -F
iptables -X

# Default policies - DROP everything
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow LAN to router (for DNS, DHCP, Web UI, SSH)
iptables -A INPUT -i $LAN -j ACCEPT
iptables -A INPUT -i $WLAN -j ACCEPT

# Allow forwarding between LAN interfaces
iptables -A FORWARD -i $LAN -o $WLAN -j ACCEPT
iptables -A FORWARD -i $WLAN -o $LAN -j ACCEPT

# ===========================================
# VPN KILL SWITCH
# Only allow LAN traffic through VPN, not direct WAN
# ===========================================

# Check if VPN interface exists
if ip link show $VPN &>/dev/null; then
    echo "VPN interface $VPN detected - routing through VPN"

    # Allow LAN to VPN
    iptables -A FORWARD -i $LAN -o $VPN -j ACCEPT
    iptables -A FORWARD -i $WLAN -o $VPN -j ACCEPT

    # NAT through VPN
    iptables -t nat -A POSTROUTING -o $VPN -j MASQUERADE

    # BLOCK direct WAN access (kill switch)
    iptables -A FORWARD -i $LAN -o $WAN -j DROP
    iptables -A FORWARD -i $WLAN -o $WAN -j DROP

    echo "Kill switch ACTIVE - LAN blocked from direct WAN"
else
    echo "WARNING: VPN not connected - enabling fallback WAN access"

    # Fallback: Allow LAN to WAN (no VPN protection!)
    iptables -A FORWARD -i $LAN -o $WAN -j ACCEPT
    iptables -A FORWARD -i $WLAN -o $WAN -j ACCEPT
    iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE
fi

# Allow router to reach WAN (for VPN handshake, NTP, updates)
# WireGuard port
iptables -A OUTPUT -o $WAN -p udp --dport 51820 -j ACCEPT
# DNS for initial connection (before DoH starts)
iptables -A OUTPUT -o $WAN -p udp --dport 53 -j ACCEPT
# HTTPS for DoH
iptables -A OUTPUT -o $WAN -p tcp --dport 443 -j ACCEPT
# NTP
iptables -A OUTPUT -o $WAN -p udp --dport 123 -j ACCEPT

# Block incoming from WAN
iptables -A INPUT -i $WAN -m conntrack --ctstate NEW -j DROP

echo "Firewall rules applied successfully"
```

### Step 11.2: Apply and Persist

```bash
sudo /etc/raspap/networking/firewall.sh
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

---

## Part 12: Verification and Testing

### Step 12.1: Network Connectivity Test

From a device on the LAN (wired or WiFi):

```bash
# Check local gateway
ping 10.3.141.1

# Check internet (via VPN)
ping 8.8.8.8

# Check DNS
nslookup google.com
```

### Step 12.2: Verify VPN is Working

```bash
# On the Pi
sudo wg show

# Check public IP (should show VPN server location)
curl ifconfig.me

# From a LAN client, check their public IP
# Should also show VPN server location
```

### Step 12.3: Test Kill Switch

```bash
# Temporarily disconnect VPN
sudo wg-quick down wg0

# Try to ping from LAN client - should FAIL (kill switch active)
ping 8.8.8.8

# Reconnect VPN
sudo wg-quick up wg0

# Should work again
ping 8.8.8.8
```

### Step 12.4: Verify DNS-over-HTTPS

```bash
# Check cloudflared is running
sudo systemctl status cloudflared

# Test DoH resolution
dig @127.0.0.1 -p 5053 example.com

# Verify from LAN client that DNS is encrypted
# (Use Wireshark on WAN to confirm no plaintext DNS)
```

---

## Part 13: Troubleshooting

### No Internet on LAN Devices

```bash
# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward
# Should be 1

# Check NAT rules
sudo iptables -t nat -L -v -n

# Check routing
ip route

# Verify WAN has internet
ping -I eth0 8.8.8.8
```

### WiFi AP Not Broadcasting

```bash
# Check hostapd status
sudo systemctl status hostapd

# Check for errors
sudo journalctl -u hostapd -n 50

# Verify wireless interface
iw dev wlan0 info
```

### WireGuard Not Connecting

```bash
# Check config syntax
sudo wg-quick up wg0

# View detailed errors
sudo journalctl -u wg-quick@wg0

# Verify endpoint is reachable
ping VPN_SERVER_IP

# Check firewall allows WireGuard
sudo iptables -L OUTPUT -v -n | grep 51820
```

### DNS Not Resolving

```bash
# Test local DNS
nslookup example.com 127.0.0.1

# Test DoH proxy directly
nslookup example.com 127.0.0.1#5053

# Check cloudflared
sudo systemctl status cloudflared
sudo journalctl -u cloudflared -n 50

# Check dnsmasq
sudo systemctl status dnsmasq
cat /var/log/dnsmasq.log
```

### DHCP Not Assigning IPs

```bash
# Check dnsmasq is running
sudo systemctl status dnsmasq

# Check leases
cat /var/lib/misc/dnsmasq.leases

# Check dnsmasq config
dnsmasq --test

# View dnsmasq logs
tail -f /var/log/dnsmasq.log
```

### eth1 (USB Adapter) Not Working

```bash
# Check if detected
lsusb | grep -i ethernet
ip link show eth1

# Check for driver issues
dmesg | grep -i eth1
dmesg | grep -i asix

# Restart interface
sudo ip link set eth1 down
sudo ip link set eth1 up
```

---

## Part 14: Maintenance

### Regular Updates

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Update RaspAP
sudo apt install raspap -y
```

### Backup Configuration

```bash
# Backup critical configs
sudo tar -czvf raspap-backup-$(date +%Y%m%d).tar.gz \
    /etc/dhcpcd.conf \
    /etc/dnsmasq.d/ \
    /etc/hostapd/hostapd.conf \
    /etc/wireguard/wg0.conf \
    /etc/raspap/ \
    /etc/cloudflared/
```

### Monitor System

```bash
# Check system resources
htop

# Check network traffic
vnstat

# View active connections
ss -tuln

# Check firewall hits
sudo iptables -L -v -n
```

### Log Rotation

Logs are automatically rotated, but you can check:
```bash
ls -la /var/log/dnsmasq.log*
ls -la /var/log/syslog*
```

---

## Quick Reference

### Service Commands

| Service | Start | Stop | Status | Restart |
|---------|-------|------|--------|---------|
| hostapd | `sudo systemctl start hostapd` | `sudo systemctl stop hostapd` | `sudo systemctl status hostapd` | `sudo systemctl restart hostapd` |
| dnsmasq | `sudo systemctl start dnsmasq` | `sudo systemctl stop dnsmasq` | `sudo systemctl status dnsmasq` | `sudo systemctl restart dnsmasq` |
| dhcpcd | `sudo systemctl start dhcpcd` | `sudo systemctl stop dhcpcd` | `sudo systemctl status dhcpcd` | `sudo systemctl restart dhcpcd` |
| WireGuard | `sudo wg-quick up wg0` | `sudo wg-quick down wg0` | `sudo wg show` | `sudo systemctl restart wg-quick@wg0` |
| cloudflared | `sudo systemctl start cloudflared` | `sudo systemctl stop cloudflared` | `sudo systemctl status cloudflared` | `sudo systemctl restart cloudflared` |

### Important Files

| File | Purpose |
|------|---------|
| `/etc/dhcpcd.conf` | Network interface configuration |
| `/etc/dnsmasq.d/*.conf` | DHCP and DNS settings |
| `/etc/hostapd/hostapd.conf` | WiFi access point settings |
| `/etc/wireguard/wg0.conf` | VPN configuration |
| `/etc/cloudflared/config.yml` | DNS-over-HTTPS settings |
| `/etc/raspap/networking/firewall.sh` | Firewall rules |

### Network Quick Check

```bash
# All-in-one status check
echo "=== Interfaces ===" && ip -br addr && \
echo "=== Routes ===" && ip route && \
echo "=== WireGuard ===" && sudo wg show && \
echo "=== Services ===" && systemctl is-active hostapd dnsmasq dhcpcd wg-quick@wg0 cloudflared
```
