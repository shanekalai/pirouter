# Raspberry Pi Secure Router

A secure router setup for Raspberry Pi 3B using OpenWrt with WireGuard VPN and DNS-over-HTTPS.

## Overview

This project creates a privacy-focused router by:

1. Routing all traffic through a WireGuard VPN tunnel (ProtonVPN compatible)
2. Encrypting DNS queries with DNS-over-HTTPS (Cloudflare/Quad9)
3. Implementing a kill switch that blocks traffic if VPN disconnects
4. Running a lean OpenWrt image optimized for Raspberry Pi 3B
5. Disabling IPv6 to prevent VPN leaks

## Quick Start (OpenWrt)

### Option 1: Pre-built Firmware with Script

1. Go to [OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/?version=24.10.4)
2. Search for "Raspberry Pi 3"
3. Add these packages to "Installed Packages":
   ```
   wireguard-tools luci-proto-wireguard https-dns-proxy luci-app-https-dns-proxy
   ```
4. Remove these packages (optional, saves resources):
   ```
   -kmod-sound-arm-bcm2835 -kmod-sound-core -ppp -ppp-mod-pppoe -odhcp6c -odhcpd-ipv6only
   ```
5. Copy contents of `openwrt-setup.sh` into "Script to run on first boot"
6. **Edit the configuration variables** at the top of the script
7. Click "Request Build" and flash the resulting image

### Option 2: Manual Setup on Running OpenWrt

```sh
# Copy script to router
scp openwrt-setup.sh root@192.168.1.1:/etc/uci-defaults/

# SSH in and run
ssh root@192.168.1.1
sh /etc/uci-defaults/openwrt-setup.sh
```

## Requirements

- Raspberry Pi 3B/3B+/4 (64-bit)
- MicroSD card (8GB+)
- Ethernet connection to ISP modem
- WireGuard config from VPN provider (ProtonVPN, Mullvad, etc.)

## Recommended Package List

```
base-files bcm27xx-gpu-fw bcm27xx-utils ca-bundle dnsmasq dropbear e2fsprogs firewall4 fstools kmod-fs-vfat kmod-nft-offload kmod-nls-cp437 kmod-nls-iso8859-1 kmod-usb-hid libc libgcc libustream-mbedtls logd mkf2fs mtd netifd nftables opkg partx-utils procd-ujail uci uclient-fetch urandom-seed cypress-firmware-43430-sdio brcmfmac-nvram-43430-sdio cypress-firmware-43455-sdio brcmfmac-nvram-43455-sdio kmod-brcmfmac wpad-basic-mbedtls kmod-i2c-bcm2835 kmod-spi-bcm2835 kmod-spi-bcm2835-aux iwinfo luci wireguard-tools luci-proto-wireguard https-dns-proxy luci-app-https-dns-proxy
```

## Legacy: Docker-based Setup (Debian/Raspberry Pi OS)

For systems running Debian 13 or Raspberry Pi OS, see the Docker-based approach:

```bash
sudo ./secure-setup.sh --vpn-config ./wg0.conf
```

## Files

| File | Description |
|------|-------------|
| `openwrt-setup.sh` | OpenWrt first-boot configuration script |
| `secure-setup.sh` | Legacy Docker-based setup (Debian/Pi OS) |
| `wg0.conf` | WireGuard config template |

## Architecture (OpenWrt)

```
┌─────────────────────────────────────────────────────────┐
│                     OpenWrt Router                       │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  WAN (eth0) → ISP Modem                          │   │
│  │       ↓                                           │   │
│  │  WireGuard (wg0) → VPN Tunnel → Internet         │   │
│  │       ↓                                           │   │
│  │  nftables Kill Switch (blocks non-VPN traffic)   │   │
│  └──────────────────────────────────────────────────┘   │
│                         ↓                                │
│  ┌──────────────────────────────────────────────────┐   │
│  │  dnsmasq (DHCP + DNS cache)                      │   │
│  │       ↓                                           │   │
│  │  https-dns-proxy → Cloudflare/Quad9 DoH          │   │
│  └──────────────────────────────────────────────────┘   │
│                         ↓                                │
│  ┌──────────────────────────────────────────────────┐   │
│  │  LAN (br-lan) + WiFi AP (wlan0)                  │   │
│  │       ↓                                           │   │
│  │  Client Devices (10.3.141.0/24)                  │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Security Features

### Network Security

- **VPN Kill Switch**: nftables rules block all traffic if WireGuard disconnects
- **IPv6 Disabled**: Prevents IPv6 leak attacks that bypass VPN
- **DNS Encryption**: All DNS queries go through DoH (Cloudflare/Quad9)
- **WiFi Client Isolation**: Clients cannot see each other on the network
- **WPA3/WPA2 Mixed Mode**: Modern WiFi encryption with legacy fallback

### System Hardening

- Kernel security parameters (rp_filter, syncookies, etc.)
- SSH restricted to LAN interface only
- Reverse path filtering enabled
- ICMP redirects disabled

## Configuration

Edit the variables at the top of `openwrt-setup.sh` before building:

```sh
# WiFi Settings
WIFI_SSID="SecureAP"
WIFI_PASSWORD="YourSecurePassword123"

# Network
LAN_IP="10.3.141.1"

# WireGuard (from ProtonVPN config)
WG_PRIVATE_KEY="your_private_key_here"
WG_ADDRESS="10.2.0.2/32"
WG_PEER_PUBLIC_KEY="vpn_server_public_key"
WG_PEER_ENDPOINT="vpn.server.com:51820"

# DNS-over-HTTPS
DOH_RESOLVER="cloudflare"  # or: quad9, google
```

### Getting WireGuard Credentials

1. Log in to [ProtonVPN Account](https://account.protonvpn.com/downloads)
2. Go to Downloads → WireGuard configuration
3. Download a config file for your preferred server
4. Copy the values into the script variables

## Commands

```sh
# Check WireGuard status
wg show

# View system logs
logread -f

# Restart network
/etc/init.d/network restart

# Restart WireGuard
ifdown wg0 && ifup wg0

# Check DNS-over-HTTPS status
/etc/init.d/https-dns-proxy status

# Test DNS is working through DoH
nslookup example.com 127.0.0.1

# Check firewall rules
nft list ruleset
```

## Troubleshooting

### VPN Not Connecting
```sh
# Check WireGuard interface
wg show wg0

# Check logs for errors
logread | grep -i wireguard
```

### No Internet After VPN Disconnect (Kill Switch Working)
This is expected behavior. Restart WireGuard:
```sh
ifdown wg0 && ifup wg0
```

### DNS Not Resolving
```sh
# Check https-dns-proxy is running
ps | grep https-dns-proxy

# Restart DNS services
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq restart
```

## Documentation

- [OpenWrt WireGuard Guide](https://openwrt.org/docs/guide-user/services/vpn/wireguard/client)
- [https-dns-proxy Docs](https://docs.openwrt.melmac.ca/https-dns-proxy/)
- [ProtonVPN OpenWrt Setup](https://protonvpn.com/support/openwrt-wireguard)
- [WireGuard Documentation](https://www.wireguard.com/)
