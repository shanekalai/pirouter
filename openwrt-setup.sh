#!/bin/sh
#
# OpenWrt Secure Router Setup Script
# For Raspberry Pi 3B with WireGuard VPN + DNS-over-HTTPS
#
# This script configures:
# - WireGuard VPN tunnel (ProtonVPN compatible)
# - DNS-over-HTTPS via https-dns-proxy
# - nftables firewall with kill switch
# - WiFi access point
# - IPv6 disabled for privacy
#
# Usage:
#   1. Paste into OpenWrt Firmware Selector "Script to run on first boot" box
#   2. Or copy to /etc/uci-defaults/ on a running OpenWrt system
#
# IMPORTANT: Edit the CONFIGURATION section below before building!
#

# ============================================================================
# CONFIGURATION - EDIT THESE VALUES
# ============================================================================

# WiFi Access Point Settings
WIFI_SSID="SecureAP"
WIFI_PASSWORD="YourSecurePassword123"  # Minimum 8 characters
WIFI_CHANNEL="36"                       # 5GHz channel (36, 40, 44, 48, etc.)
WIFI_COUNTRY="US"                       # Country code for regulatory

# LAN Network Settings
LAN_IP="10.3.141.1"
LAN_NETMASK="255.255.255.0"
DHCP_START="50"
DHCP_LIMIT="200"
DHCP_LEASETIME="24h"

# WireGuard VPN Settings (from ProtonVPN config file)
# Get these values from: https://account.protonvpn.com/downloads → WireGuard config
# Or extract from your existing wg0.conf file:
#   PrivateKey = <WG_PRIVATE_KEY>
#   Address = <WG_ADDRESS>
#   [Peer] PublicKey = <WG_PEER_PUBLIC_KEY>
#   Endpoint = <WG_PEER_ENDPOINT>
#
WG_PRIVATE_KEY=""                    # [Interface] PrivateKey value
WG_ADDRESS="10.2.0.2/32"             # [Interface] Address value
WG_DNS="10.2.0.1"                    # [Interface] DNS value
WG_PEER_PUBLIC_KEY=""                # [Peer] PublicKey value
WG_PEER_ENDPOINT=""                  # [Peer] Endpoint (e.g., "95.173.217.65:51820")
WG_PEER_ALLOWED_IPS="0.0.0.0/0"      # Route all traffic through VPN

# DNS-over-HTTPS Settings
DOH_RESOLVER="cloudflare"   # Options: cloudflare, quad9, google, or custom URL
DOH_BOOTSTRAP_DNS="1.1.1.1" # Bootstrap DNS for initial DoH connection

# ============================================================================
# SCRIPT START - DO NOT EDIT BELOW UNLESS YOU KNOW WHAT YOU'RE DOING
# ============================================================================

log() {
    logger -t "openwrt-setup" "$1"
    echo ">>> $1"
}

log "Starting secure router configuration..."

# ----------------------------------------------------------------------------
# System Configuration
# ----------------------------------------------------------------------------

log "Configuring system settings..."

# Set hostname
uci set system.@system[0].hostname='securerouter'
uci set system.@system[0].timezone='UTC'
uci set system.@system[0].log_size='64'
uci commit system

# Disable IPv6 globally for privacy (prevents leaks)
log "Disabling IPv6..."
uci set 'network.lan.ipv6=0'
uci set 'network.wan.ipv6=0'
uci delete network.wan6 2>/dev/null || true
uci set 'dhcp.lan.dhcpv6=disabled'
uci set 'dhcp.lan.ra=disabled'
uci commit network
uci commit dhcp

# Kernel-level IPv6 disable
cat >> /etc/sysctl.conf << 'EOF'
# Disable IPv6 to prevent VPN leaks
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

# ----------------------------------------------------------------------------
# Network Configuration
# ----------------------------------------------------------------------------

log "Configuring network interfaces..."

# Configure LAN
uci set network.lan.ipaddr="$LAN_IP"
uci set network.lan.netmask="$LAN_NETMASK"
uci set network.lan.proto='static'

# Configure WAN (DHCP from ISP)
uci set network.wan.proto='dhcp'
uci set network.wan.peerdns='0'  # Don't use ISP DNS

uci commit network

# ----------------------------------------------------------------------------
# DHCP/DNS Configuration
# ----------------------------------------------------------------------------

log "Configuring DHCP server..."

uci set dhcp.lan.start="$DHCP_START"
uci set dhcp.lan.limit="$DHCP_LIMIT"
uci set dhcp.lan.leasetime="$DHCP_LEASETIME"

# Point dnsmasq to local https-dns-proxy
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].localuse='1'
uci set dhcp.@dnsmasq[0].cachesize='10000'

# Security settings for dnsmasq
uci set dhcp.@dnsmasq[0].domainneeded='1'
uci set dhcp.@dnsmasq[0].boguspriv='1'
uci set dhcp.@dnsmasq[0].filterwin2k='1'
uci set dhcp.@dnsmasq[0].rebind_protection='1'

uci commit dhcp

# ----------------------------------------------------------------------------
# DNS-over-HTTPS Configuration
# ----------------------------------------------------------------------------

log "Configuring DNS-over-HTTPS..."

# Configure https-dns-proxy
uci set https-dns-proxy.config.dnsmasq_config_update='*'

# Clear existing instances
while uci delete https-dns-proxy.@https-dns-proxy[0] 2>/dev/null; do :; done

# Add primary DoH resolver
uci add https-dns-proxy https-dns-proxy
case "$DOH_RESOLVER" in
    cloudflare)
        uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url='https://cloudflare-dns.com/dns-query'
        uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns='1.1.1.1,1.0.0.1'
        ;;
    quad9)
        uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url='https://dns.quad9.net/dns-query'
        uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns='9.9.9.9,149.112.112.112'
        ;;
    google)
        uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url='https://dns.google/dns-query'
        uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns='8.8.8.8,8.8.4.4'
        ;;
    *)
        uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url="$DOH_RESOLVER"
        uci set https-dns-proxy.@https-dns-proxy[-1].bootstrap_dns="$DOH_BOOTSTRAP_DNS"
        ;;
esac
uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_port='5053'

uci commit https-dns-proxy

# Enable https-dns-proxy service
/etc/init.d/https-dns-proxy enable

# ----------------------------------------------------------------------------
# WireGuard VPN Configuration
# ----------------------------------------------------------------------------

if [ -n "$WG_PRIVATE_KEY" ] && [ -n "$WG_PEER_PUBLIC_KEY" ]; then
    log "Configuring WireGuard VPN..."

    # Create WireGuard interface
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$WG_PRIVATE_KEY"
    uci add_list network.wg0.addresses="$WG_ADDRESS"

    # Don't use VPN DNS directly - we use https-dns-proxy
    # uci set network.wg0.dns="$WG_DNS"

    # Create WireGuard peer
    uci set network.wg_peer0=wireguard_wg0
    uci set network.wg_peer0.public_key="$WG_PEER_PUBLIC_KEY"
    uci set network.wg_peer0.endpoint_host="$(echo $WG_PEER_ENDPOINT | cut -d: -f1)"
    uci set network.wg_peer0.endpoint_port="$(echo $WG_PEER_ENDPOINT | cut -d: -f2)"
    uci set network.wg_peer0.persistent_keepalive='25'
    uci add_list network.wg_peer0.allowed_ips="$WG_PEER_ALLOWED_IPS"
    uci set network.wg_peer0.route_allowed_ips='1'

    uci commit network

    # Add WireGuard to WAN zone for firewall
    uci add_list firewall.@zone[1].network='wg0'
    uci commit firewall

    log "WireGuard VPN configured"
else
    log "WARNING: WireGuard not configured - no VPN credentials provided"
fi

# ----------------------------------------------------------------------------
# WiFi Access Point Configuration
# ----------------------------------------------------------------------------

log "Configuring WiFi access point..."

# Find and configure the radio
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country="$WIFI_COUNTRY"
uci set wireless.radio0.channel="$WIFI_CHANNEL"

# Try to use 5GHz if available (radio0 or radio1)
# Check if this is a 5GHz capable radio
if uci get wireless.radio0.hwmode 2>/dev/null | grep -q '11a'; then
    uci set wireless.radio0.htmode='VHT80'
    uci set wireless.radio0.band='5g'
elif uci get wireless.radio1 2>/dev/null; then
    # Second radio might be 5GHz
    uci set wireless.radio1.disabled='0'
    uci set wireless.radio1.country="$WIFI_COUNTRY"
    uci set wireless.radio1.channel="$WIFI_CHANNEL"
    uci set wireless.radio1.htmode='VHT80'
fi

# Configure default WiFi interface
uci set wireless.default_radio0.ssid="$WIFI_SSID"
uci set wireless.default_radio0.encryption='sae-mixed'  # WPA3/WPA2 mixed mode
uci set wireless.default_radio0.key="$WIFI_PASSWORD"
uci set wireless.default_radio0.network='lan'
uci set wireless.default_radio0.disabled='0'

# Enable client isolation for security
uci set wireless.default_radio0.isolate='1'

# Disable WPS (security risk)
uci set wireless.default_radio0.wps_pushbutton='0'

uci commit wireless

# ----------------------------------------------------------------------------
# Firewall Configuration with Kill Switch
# ----------------------------------------------------------------------------

log "Configuring firewall with kill switch..."

# Basic zone configuration should already exist
# Ensure LAN to WAN forwarding goes through VPN only

# Allow WireGuard traffic on WAN
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-WireGuard'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='51820'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Block non-VPN traffic (kill switch) - custom nftables rules
cat > /etc/nftables.d/99-killswitch.nft << 'EOF'
# VPN Kill Switch
# Prevents traffic from leaking if VPN disconnects

chain vpn_killswitch {
    type filter hook forward priority 0; policy accept;

    # Allow established connections
    ct state established,related accept

    # Allow LAN to LAN
    iifname "br-lan" oifname "br-lan" accept

    # Allow traffic through VPN tunnel
    iifname "br-lan" oifname "wg0" accept

    # Allow DHCP on WAN (to get IP)
    iifname "br-lan" oifname "eth0" udp dport 67 accept

    # Allow DNS to localhost (for https-dns-proxy)
    iifname "br-lan" ip daddr 127.0.0.1 accept

    # Block everything else from LAN to WAN (kill switch)
    iifname "br-lan" oifname "eth0" drop
}
EOF

# Restrict router itself from leaking
cat >> /etc/nftables.d/99-killswitch.nft << 'EOF'

chain router_killswitch {
    type filter hook output priority 0; policy accept;

    # Allow loopback
    oifname "lo" accept

    # Allow LAN traffic
    oifname "br-lan" accept

    # Allow VPN traffic
    oifname "wg0" accept

    # Allow WireGuard handshake on WAN
    oifname "eth0" udp dport 51820 accept

    # Allow DHCP on WAN
    oifname "eth0" udp dport 67 accept
    oifname "eth0" udp sport 68 accept

    # Allow established connections (for WireGuard)
    oifname "eth0" ct state established,related accept

    # Block other direct WAN access from router
    oifname "eth0" ct state new drop
}
EOF

uci commit firewall

# ----------------------------------------------------------------------------
# Additional Security Hardening
# ----------------------------------------------------------------------------

log "Applying security hardening..."

# Secure dropbear SSH
uci set dropbear.@dropbear[0].PasswordAuth='on'
uci set dropbear.@dropbear[0].RootPasswordAuth='on'
uci set dropbear.@dropbear[0].Port='22'
# Only allow SSH from LAN
uci set dropbear.@dropbear[0].Interface='lan'
uci commit dropbear

# Block SSH from WAN
uci add firewall rule
uci set firewall.@rule[-1].name='Block-SSH-WAN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='DROP'
uci commit firewall

# Disable unnecessary services
/etc/init.d/uhttpd disable 2>/dev/null || true  # Disable if using LuCI on different port

# Kernel security parameters
cat >> /etc/sysctl.conf << 'EOF'

# Security hardening
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.tcp_syncookies=1
net.ipv4.icmp_echo_ignore_broadcasts=1
kernel.randomize_va_space=2
EOF

# ----------------------------------------------------------------------------
# Enable Services
# ----------------------------------------------------------------------------

log "Enabling services..."

/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
/etc/init.d/https-dns-proxy restart

# Reload wireless
wifi reload

log "=========================================="
log "Secure router configuration complete!"
log "=========================================="
log ""
log "Network: $LAN_IP/24"
log "WiFi SSID: $WIFI_SSID"
log "DNS: Encrypted via $DOH_RESOLVER"
if [ -n "$WG_PRIVATE_KEY" ]; then
    log "VPN: WireGuard tunnel active"
else
    log "VPN: NOT CONFIGURED - Add credentials and rerun"
fi
log ""
log "Access LuCI at: http://$LAN_IP"
log ""

# Exit 0 to signal success (script will be deleted from uci-defaults)
exit 0
