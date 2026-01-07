# Secure Home Network Setup Guide

This guide provides detailed instructions for setting up a privacy-focused home network using RaspAP in Docker containers. The goal is to create a network that protects your traffic from ISP monitoring while providing a secure wireless access point.

## Table of Contents

- [Overview](#overview)
- [Hardware Requirements](#hardware-requirements)
- [Network Topology](#network-topology)
- [Physical Connections](#physical-connections)
- [Hitron CODA5834 Configuration](#hitron-coda5834-configuration)
- [TP-Link TL-SG108E Switch Configuration](#tp-link-tl-sg108e-switch-configuration)
- [Raspberry Pi Setup](#raspberry-pi-setup)
- [Security Architecture](#security-architecture)
- [VPN Provider Setup](#vpn-provider-setup)
- [Verification Steps](#verification-steps)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)

---

## Overview

This setup creates a privacy-focused router using:

| Component | Role |
|-----------|------|
| Hitron CODA5834 | ISP modem in bridge/DMZ mode |
| Raspberry Pi 3B | Main router running RaspAP in Docker |
| TP-Link TL-SG108E | Managed switch for wired devices |
| TP-Link Archer T2U/A600 | USB WiFi adapter for access point |

### Privacy Features

- **VPN Tunnel**: All traffic encrypted through WireGuard VPN
- **DNS over HTTPS**: Encrypted DNS queries (Cloudflare 1.1.1.1)
- **Kill Switch**: Blocks all traffic if VPN disconnects
- **MAC Randomization**: WAN interface MAC changed on boot
- **IPv6 Disabled**: Prevents IPv6 leak attacks
- **Client Isolation**: WiFi clients cannot see each other
- **Container Isolation**: Services run in hardened Docker containers

---

## Hardware Requirements

### Required Equipment

| Item | Model | Purpose |
|------|-------|---------|
| Single Board Computer | Raspberry Pi 3B/3B+/4/5 | Main router |
| USB WiFi Adapter | TP-Link Archer T2U (A600) | 5GHz/2.4GHz Access Point |
| Managed Switch | TP-Link TL-SG108E | VLAN support, wired devices |
| ISP Modem | Hitron CODA5834 | Internet connection |
| MicroSD Card | 16GB+ Class 10 | Raspberry Pi storage |
| Ethernet Cables | Cat5e or better | Network connections |
| Power Supply | 5V 2.5A+ for Pi 3B | Raspberry Pi power |

### Recommended Additions

- UPS or battery backup for continuous operation
- Heatsinks/fan for Raspberry Pi (especially Pi 4/5)
- Secure enclosure for the Raspberry Pi

---

## Network Topology

```
                    INTERNET
                        │
                        ▼
            ┌───────────────────────┐
            │   Hitron CODA5834     │
            │   ISP Modem/Router    │
            │   (Bridge Mode)       │
            │                       │
            │   IP: 192.168.0.1     │
            │   DMZ: 192.168.0.10   │
            └───────────┬───────────┘
                        │ Ethernet (WAN)
                        ▼
            ┌───────────────────────┐
            │   Raspberry Pi 3B     │
            │   RaspAP Router       │
            │                       │
            │   eth0: 192.168.0.10  │◄── WAN (from Hitron)
            │   wlan1: 10.3.141.1   │◄── LAN WiFi (TP-Link A600)
            │   wg0: 10.x.x.x       │◄── VPN Tunnel
            │                       │
            │ ┌─────────────────┐   │
            │ │ Docker Stack    │   │
            │ │ ├─ WireGuard    │   │
            │ │ ├─ DNS-over-HTTPS│  │
            │ │ ├─ hostapd      │   │
            │ │ ├─ dnsmasq      │   │
            │ │ ├─ RaspAP Web   │   │
            │ │ └─ Firewall     │   │
            │ └─────────────────┘   │
            └───────────┬───────────┘
                        │ Ethernet (Optional LAN)
                        ▼
            ┌───────────────────────┐
            │  TP-Link TL-SG108E    │
            │  Managed Switch       │
            │                       │
            │  Port 1: Raspberry Pi │
            │  Port 2-8: Devices    │
            └───────────────────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
      ┌───────┐    ┌───────┐    ┌───────┐
      │  PC   │    │  NAS  │    │ Other │
      └───────┘    └───────┘    └───────┘

                    WiFi (5GHz)
            ┌───────────────────────┐
            │     Secure AP         │
            │   SSID: SecureAP      │
            │   10.3.141.0/24       │
            └───────────────────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
      ┌───────┐    ┌───────┐    ┌───────┐
      │ Phone │    │Laptop │    │Tablet │
      └───────┘    └───────┘    └───────┘
```

### IP Address Scheme

| Network | Subnet | Description |
|---------|--------|-------------|
| ISP/WAN | 192.168.0.0/24 | Hitron modem network |
| WiFi LAN | 10.3.141.0/24 | Wireless devices |
| Docker | 172.20.0.0/24 | Container network |
| VPN | (Provider assigned) | VPN tunnel interface |

---

## Physical Connections

### Step-by-Step Connection Guide

#### Step 1: Prepare the Raspberry Pi

1. Flash Debian 13 (Trixie) to microSD card:
   - Download: https://raspi.debian.net/tested/20231111_raspi_4_trixie.img.xz
   - Use Raspberry Pi Imager or balenaEtcher

2. Insert microSD card into Raspberry Pi

3. Connect TP-Link A600 USB adapter to USB port
   - Use a USB 2.0 port for better compatibility
   - Pi 3B: Use one of the 4 USB ports on the right side

4. **Do NOT power on yet**

#### Step 2: Connect Hitron CODA5834

1. Locate the Hitron's ethernet ports on the back
2. Connect an ethernet cable from **Hitron LAN Port 1** to **Raspberry Pi eth0**
3. The Pi's eth0 is the single ethernet port on the board

#### Step 3: Set Up the Switch (Optional for Wired Devices)

If you want wired devices on your secure network:

1. Connect ethernet from **Raspberry Pi eth0** through a **USB Ethernet adapter** to **Switch Port 1**
   - Note: Pi 3B only has one ethernet port, so you'd need a USB ethernet adapter for this configuration
   - Alternatively, use WiFi only

2. Connect wired devices to Switch Ports 2-8

#### Step 4: Power On Sequence

**Important**: Power on devices in this order:

1. Hitron CODA5834 (wait 2 minutes for full boot)
2. TP-Link TL-SG108E switch (wait 30 seconds)
3. Raspberry Pi (wait 2 minutes for full boot)

---

## Hitron CODA5834 Configuration

### Accessing the Admin Interface

1. Connect a computer directly to Hitron LAN port 2-4
2. Open browser and go to: `http://192.168.0.1`
3. Login with credentials:
   - Default username: `cusadmin`
   - Default password: (on modem label or provided by ISP)

### Option A: DMZ Mode (Recommended)

DMZ mode forwards all incoming traffic to the Raspberry Pi, letting it handle all routing and firewall functions.

#### Configuration Steps:

1. Navigate to **Basic** > **DHCP**
2. Note the DHCP range (usually 192.168.0.2 - 192.168.0.254)

3. Navigate to **Basic** > **DHCP Reservation** (or Static Leases)
4. Add a reservation for the Raspberry Pi:
   - MAC Address: (found on Pi ethernet port label or run `ip link show eth0`)
   - IP Address: `192.168.0.10`
   - Description: `RaspAP Router`

5. Navigate to **Advanced** > **DMZ**
6. Enable DMZ:
   - Status: **Enabled**
   - DMZ Host IP: `192.168.0.10`
7. Click **Apply**

8. Navigate to **Advanced** > **Firewall**
9. Set firewall to **Minimum** or **Custom** with all inbound rules removed
   - The Raspberry Pi will handle firewall duties

10. Navigate to **Wireless** > **Radio**
11. **Disable both 2.4GHz and 5GHz radios**
    - Your Pi will provide WiFi instead
    - This prevents interference and confusion

12. Navigate to **Advanced** > **Remote Management**
13. **Disable remote management** to prevent ISP access:
    - Remote Management: **Disabled**
    - TR-069: **Disabled** (if available)

### Option B: Bridge Mode (Advanced)

Bridge mode disables all router functions in the Hitron, passing the public IP directly to the Pi.

**Warning**: Bridge mode may require ISP support and could affect other services.

#### Configuration Steps:

1. Navigate to **Basic** > **Setup**
2. Look for **Gateway Mode** or **Operation Mode**
3. Change to **Bridge Mode**
4. Click **Apply**

5. The modem will reboot
6. After reboot, access may change to `192.168.100.1`

7. Configure PPPoE on Raspberry Pi if required by your ISP

### Disable Unnecessary Services

Regardless of mode, disable these for security:

| Setting | Location | Action |
|---------|----------|--------|
| UPnP | Advanced > UPnP | Disable |
| WPS | Wireless > WPS | Disable |
| Guest Network | Wireless > Guest | Disable |
| Remote Management | Advanced > Remote | Disable |
| Parental Controls | Advanced > Parental | Disable (Pi will handle) |
| IPv6 | Basic > IPv6 | Disable (prevents leaks) |

### Verify Hitron Configuration

After configuration:

1. Check that DMZ shows Raspberry Pi IP (192.168.0.10)
2. Verify WiFi radios are off
3. Confirm remote management is disabled
4. Note the WAN IP (shown on Status page) for VPN setup

---

## TP-Link TL-SG108E Switch Configuration

The TL-SG108E is a smart managed switch with VLAN support. For this setup, basic configuration is sufficient.

### Accessing the Switch

1. Connect computer directly to any switch port
2. Default IP: `192.168.0.1` (may conflict with Hitron)
3. If conflict, disconnect from Hitron first, or:
   - Use TP-Link Easy Smart Configuration Utility (download from TP-Link)

4. Default credentials:
   - Username: `admin`
   - Password: `admin`

### Basic Configuration

1. **Change the switch IP** to avoid conflicts:
   - Navigate to **System** > **System Info**
   - Change IP to: `10.3.141.250`
   - Subnet: `255.255.255.0`
   - Gateway: `10.3.141.1` (Raspberry Pi)

2. **Change admin password**:
   - Navigate to **System** > **User Account**
   - Set a strong password

3. **Enable IGMP Snooping** (optional, for multicast):
   - Navigate to **Switching** > **IGMP Snooping**
   - Enable globally

4. **Enable Loop Prevention**:
   - Navigate to **Switching** > **Loop Prevention**
   - Enable on all ports

5. **Save configuration**:
   - Navigate to **System** > **System Tools**
   - Click **Save Config**

### Optional: VLAN Configuration

For network segmentation (IoT devices, guest network):

```
VLAN 1 (Default): Ports 1-4 - Trusted devices
VLAN 10 (IoT):    Ports 5-6 - IoT devices
VLAN 20 (Guest):  Ports 7-8 - Guest/untrusted
```

This requires additional configuration on the Raspberry Pi to handle inter-VLAN routing.

---

## Raspberry Pi Setup

### Initial Debian Setup

1. Boot the Raspberry Pi with Debian 13

2. Find the Pi's IP address:
   - Check Hitron's DHCP client list, or
   - Use `nmap -sn 192.168.0.0/24` from another computer

3. SSH into the Pi:
   ```bash
   ssh pi@192.168.0.x
   # Default password varies by image
   ```

4. Change the default password:
   ```bash
   passwd
   ```

5. Update the system:
   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo reboot
   ```

### Install RaspAP with Docker

1. Clone the repository:
   ```bash
   git clone https://github.com/RaspAP/raspap-webgui.git
   cd raspap-webgui/docker
   ```

2. Make the setup script executable:
   ```bash
   chmod +x secure-setup.sh
   ```

3. Run the secure setup (interactive):
   ```bash
   sudo ./secure-setup.sh
   ```

4. Or run with options:
   ```bash
   sudo ./secure-setup.sh \
     --vpn-config /path/to/wireguard.conf \
     --wifi-ssid "MySecureNetwork" \
     --wifi-pass "MyStrongPassword123" \
     --admin-pass "AdminPassword456"
   ```

### Post-Installation

After installation completes:

1. Connect to the new WiFi network:
   - SSID: As configured (default: `SecureAP`)
   - Password: As configured

2. Access RaspAP dashboard:
   - URL: `http://10.3.141.1`
   - Username: `admin`
   - Password: As configured

3. Verify VPN is active:
   - Dashboard should show WireGuard connection status
   - Check "VPN Status" section

---

## Security Architecture

### Traffic Flow

```
Device → WiFi (wlan1) → dnsmasq → WireGuard VPN → eth0 → Hitron → Internet
                            ↓
                    DNS-over-HTTPS (1.1.1.1)
```

### Security Layers

1. **Layer 1: Network Isolation**
   - ISP sees only encrypted VPN traffic
   - MAC address randomized on WAN interface
   - IPv6 completely disabled

2. **Layer 2: Encrypted Transport**
   - WireGuard VPN encrypts all traffic
   - Kill switch blocks traffic if VPN fails
   - DNS queries encrypted via DoH

3. **Layer 3: Container Security**
   - Services run in isolated Docker containers
   - Minimal privileges (no-new-privileges)
   - Read-only filesystems where possible
   - Dropped unnecessary capabilities

4. **Layer 4: Firewall Rules**
   - Default deny policy
   - Only VPN traffic allowed outbound
   - Client isolation on WiFi
   - Rate limiting on management ports

### What Your ISP Can See

| With This Setup | Without This Setup |
|-----------------|-------------------|
| Encrypted VPN traffic to VPN server | All website URLs visited |
| Volume of data transferred | DNS queries (all sites) |
| Times of activity | Unencrypted content |
| VPN server IP address | Device fingerprints |

### What Your ISP Cannot See

- Websites you visit
- Content of your communications
- DNS queries
- Number/type of devices on your network
- Your actual MAC addresses

---

## VPN Provider Setup

### Recommended VPN Providers

Choose a provider that:
- Supports WireGuard protocol
- Has a no-logs policy (independently audited)
- Offers port forwarding (if needed)
- Has servers in privacy-friendly jurisdictions

Popular options:
- Mullvad VPN
- ProtonVPN
- IVPN
- Windscribe

### Getting Your WireGuard Configuration

#### Mullvad VPN

1. Log into https://mullvad.net/account
2. Navigate to **WireGuard configuration**
3. Generate a new key
4. Download the configuration file
5. Copy to Pi: `scp mullvad-wg.conf pi@192.168.0.10:~/`

#### ProtonVPN

1. Log into https://protonvpn.com
2. Navigate to **Downloads** > **WireGuard configuration**
3. Select a server and download config
4. Copy to Pi

#### Generic WireGuard Config Format

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
Address = 10.x.x.x/32
DNS = 10.x.x.1

[Peer]
PublicKey = SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
```

### Installing VPN Configuration

```bash
# Copy config to the secure location
sudo cp ~/wireguard.conf /opt/raspap/config/wireguard/wg0.conf
sudo chmod 600 /opt/raspap/config/wireguard/wg0.conf

# Restart the VPN container
cd /opt/raspap/docker
sudo docker compose restart wireguard
```

---

## Verification Steps

### Test 1: VPN Connection

```bash
# Check WireGuard interface
sudo docker exec raspap-vpn wg show

# Should show:
# interface: wg0
#   public key: ...
#   private key: (hidden)
#   listening port: ...
#
# peer: ...
#   endpoint: ...
#   allowed ips: 0.0.0.0/0
#   latest handshake: X seconds ago
#   transfer: X received, X sent
```

### Test 2: IP Address Check

From a connected device:

1. Visit https://whatismyipaddress.com
2. IP should show VPN server location, NOT your real location
3. Visit https://ipleak.net for comprehensive leak test

### Test 3: DNS Leak Test

1. Visit https://dnsleaktest.com
2. Run extended test
3. All DNS servers should be VPN provider's or Cloudflare's
4. Should NOT show ISP DNS servers

### Test 4: Kill Switch Test

```bash
# Temporarily stop VPN
sudo docker compose stop wireguard

# Try to access internet from connected device
# Should NOT work (kill switch active)

# Restart VPN
sudo docker compose start wireguard
```

### Test 5: Container Health

```bash
cd /opt/raspap/docker
sudo docker compose ps

# All containers should show "healthy" or "running"
```

---

## Troubleshooting

### WiFi Not Broadcasting

```bash
# Check hostapd status
sudo docker logs raspap-hostapd

# Common issues:
# - WiFi adapter not detected
# - Channel not supported
# - Driver issues

# Check interface
iw dev

# Unblock WiFi
sudo rfkill unblock wifi
```

### VPN Won't Connect

```bash
# Check VPN logs
sudo docker logs raspap-vpn

# Verify config
sudo cat /opt/raspap/config/wireguard/wg0.conf

# Common issues:
# - Invalid private key
# - Wrong endpoint
# - Firewall blocking UDP 51820
```

### No Internet Access

```bash
# Check if VPN is up
sudo docker exec raspap-vpn wg show

# Check routing
ip route

# Check firewall
sudo iptables -L -n

# Check DNS
nslookup google.com 127.0.0.1
```

### Slow Performance

```bash
# Check CPU usage
top

# Check memory
free -h

# Consider:
# - Using wired connection for heavy users
# - Upgrading to Pi 4/5
# - Choosing closer VPN server
```

### Container Crashes

```bash
# View all container status
sudo docker compose ps -a

# View specific logs
sudo docker logs --tail 100 raspap-web

# Restart all containers
sudo docker compose restart

# Full restart
sudo docker compose down && sudo docker compose up -d
```

---

## Maintenance

### Regular Updates

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Update Docker images
cd /opt/raspap/docker
sudo docker compose pull
sudo docker compose up -d
```

### Backup Configuration

```bash
# Backup all configs
sudo tar -czf raspap-backup-$(date +%Y%m%d).tar.gz /opt/raspap/

# Store backup securely off-device
```

### Monitor Logs

```bash
# View real-time logs
sudo docker compose logs -f

# Check specific service
sudo docker compose logs -f wireguard

# Check firewall drops
sudo journalctl -f | grep IPT_DROP
```

### Security Audit

Monthly checklist:
- [ ] Verify VPN is active and no leaks
- [ ] Check for system updates
- [ ] Review connected devices list
- [ ] Rotate WiFi password if needed
- [ ] Check container health
- [ ] Verify kill switch is working
- [ ] Review firewall logs for anomalies

---

## Additional Resources

- [RaspAP Documentation](https://docs.raspap.com/)
- [WireGuard Documentation](https://www.wireguard.com/)
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [Debian Security Guide](https://www.debian.org/doc/manuals/securing-debian-manual/)

## Support

For issues specific to this secure setup:
1. Check the [Troubleshooting](#troubleshooting) section
2. Review container logs
3. Open an issue on GitHub with:
   - Hardware details
   - Error messages
   - Steps to reproduce
