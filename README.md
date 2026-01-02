# RaspAP Secure Docker Setup

This directory contains a Docker-based deployment for RaspAP with enhanced privacy and security features.

## Overview

The secure setup creates an ISP-invisible router by:

1. Routing all traffic through a WireGuard VPN tunnel
2. Encrypting DNS queries with DNS-over-HTTPS
3. Implementing a kill switch that blocks traffic if VPN fails
4. Running services in hardened Docker containers
5. Randomizing MAC addresses on the WAN interface

## Quick Start

```bash
# Interactive setup (recommended for first-time users)
sudo ./secure-setup.sh

# Non-interactive with VPN config
sudo ./secure-setup.sh \
  --vpn-config /path/to/wireguard.conf \
  --wifi-ssid "MyNetwork" \
  --wifi-pass "SecurePassword123" \
  --no-interactive
```

## Requirements

- Raspberry Pi 3B or newer (Pi 4/5 recommended)
- Debian 13 (Trixie) or Raspberry Pi OS Bookworm
- USB WiFi adapter with AP mode support (e.g., TP-Link A600)
- WireGuard configuration from your VPN provider

## Files

| File | Description |
|------|-------------|
| `secure-setup.sh` | Main installation script |
| `docker-compose.yml` | Docker Compose configuration (generated) |
| `.env` | Environment variables (generated) |
| `hostapd/` | Hostapd container build files |
| `raspap/` | RaspAP web interface container |
| `firewall/` | Firewall manager container |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Docker Network                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │DNS Proxy │  │WireGuard │  │ Dnsmasq  │  │ Hostapd  │ │
│  │(DoH)     │  │  VPN     │  │DHCP/DNS  │  │   AP     │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘ │
│       │             │             │             │       │
│       └─────────────┴─────────────┴─────────────┘       │
│                         │                                │
│  ┌──────────────────────┴───────────────────────────┐   │
│  │              RaspAP Web Interface                 │   │
│  │                  (PHP/Lighttpd)                   │   │
│  └───────────────────────────────────────────────────┘   │
│                                                          │
│  ┌───────────────────────────────────────────────────┐   │
│  │              Firewall Manager                      │   │
│  │          (iptables with kill switch)               │   │
│  └───────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Security Features

### Container Hardening

- `no-new-privileges`: Prevents privilege escalation
- `read_only`: Containers use read-only root filesystems
- `cap_drop: ALL`: All capabilities dropped by default
- Minimal capability grants for each service

### Network Security

- Kill switch blocks all non-VPN traffic
- IPv6 completely disabled to prevent leaks
- DNS queries encrypted via Cloudflare DoH
- Client isolation on WiFi network

### Host Security

- Kernel hardening via sysctl
- MAC address randomization on WAN
- Rate-limited firewall logging

## Configuration

### Environment Variables

Create `/opt/raspap/docker/.env`:

```bash
# Network interfaces
WAN_INTERFACE=eth0
WLAN_INTERFACE=wlan1

# Subnet configuration
AP_SUBNET=10.3.141.0/24

# Credentials (set during installation)
ADMIN_USER=admin
ADMIN_PASS=your_password
API_KEY=generated_key
```

### WireGuard Configuration

Place your VPN provider's WireGuard config at:
`/opt/raspap/config/wireguard/wg0.conf`

## Commands

```bash
# Start all containers
docker compose up -d

# View logs
docker compose logs -f

# Stop all containers
docker compose down

# Restart specific service
docker compose restart wireguard

# View container status
docker compose ps

# Uninstall
sudo ./secure-setup.sh --uninstall
```

## Troubleshooting

See [Secure Network Setup Guide](../docs/SECURE_NETWORK_SETUP.md#troubleshooting) for detailed troubleshooting steps.

## Documentation

- [Full Setup Guide](../docs/SECURE_NETWORK_SETUP.md)
- [RaspAP Documentation](https://docs.raspap.com/)
- [WireGuard Documentation](https://www.wireguard.com/)
