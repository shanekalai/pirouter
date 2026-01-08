# Raspberry Pi Twingate Setup Guide

This guide provides step-by-step instructions for installing Twingate in a Docker container on Raspberry Pi OS Lite (Trixie/Debian 13 ARM64).

---

## Prerequisites

- Raspberry Pi with fresh Raspberry Pi OS Lite (Trixie) installed
- Internet connection
- SSH access or direct terminal access
- A [Twingate account](https://www.twingate.com/) (free tier available)

---

## Step 1: Update Your System

First, ensure your Raspberry Pi is fully updated:

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Step 2: Install Required Dependencies

Install packages needed for Docker installation:

```bash
sudo apt install -y ca-certificates curl gnupg
```

---

## Step 3: Add Docker's Official GPG Key

Create the keyrings directory and add Docker's GPG key:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

---

## Step 4: Add Docker Repository

Add the Docker repository to your apt sources:

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

---

## Step 5: Install Docker

Update apt and install Docker packages:

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

---

## Step 6: Add Your User to Docker Group (Optional)

This allows you to run Docker commands without `sudo`:

```bash
sudo usermod -aG docker $USER
```

**Important:** You must reboot for this to take effect:

```bash
sudo reboot
```

---

## Step 7: Verify Docker Installation

After rebooting, verify Docker is working:

```bash
docker --version
docker run hello-world
```

---

## Step 8: Get Twingate Connector Tokens

1. Log in to your [Twingate Admin Console](https://www.twingate.com/)
2. Navigate to **Remote Networks** in the left sidebar
3. Select your Remote Network (or create a new one)
4. Scroll down and click **Add Connector**
5. Select **Docker** as the deployment method
6. Click **Generate Tokens** in Step 2
7. **Copy and save** both:
   - `TWINGATE_ACCESS_TOKEN`
   - `TWINGATE_REFRESH_TOKEN`
   - Your network name (e.g., `yournetwork` from `yournetwork.twingate.com`)

---

## Step 9: Create Docker Compose File

Create a directory for Twingate and the compose file:

```bash
mkdir -p ~/twingate
cd ~/twingate
```

Create the `docker-compose.yml` file:

```bash
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  twingate-connector:
    image: twingate/connector:1
    container_name: twingate-connector
    restart: unless-stopped
    pull_policy: always
    sysctls:
      - net.ipv4.ping_group_range=0 2147483647
    environment:
      - TWINGATE_NETWORK=${TWINGATE_NETWORK}
      - TWINGATE_ACCESS_TOKEN=${TWINGATE_ACCESS_TOKEN}
      - TWINGATE_REFRESH_TOKEN=${TWINGATE_REFRESH_TOKEN}
      - TWINGATE_LABEL_HOSTNAME=${HOSTNAME}
      - TWINGATE_LOG_ANALYTICS=v2
EOF
```

---

## Step 10: Create Environment File

Create a `.env` file to store your credentials securely:

```bash
cat > .env << 'EOF'
TWINGATE_NETWORK=YOUR_NETWORK_NAME
TWINGATE_ACCESS_TOKEN=YOUR_ACCESS_TOKEN
TWINGATE_REFRESH_TOKEN=YOUR_REFRESH_TOKEN
EOF
```

**Replace the placeholder values** with your actual credentials:

```bash
nano .env
```

Edit the file with:
- `YOUR_NETWORK_NAME` → Your Twingate network slug (e.g., `mycompany`)
- `YOUR_ACCESS_TOKEN` → The access token from Step 8
- `YOUR_REFRESH_TOKEN` → The refresh token from Step 8

Save and exit (`Ctrl+X`, then `Y`, then `Enter`).

**Secure the file:**

```bash
chmod 600 .env
```

---

## Step 11: Start Twingate Connector

Launch the Twingate connector:

```bash
cd ~/twingate
docker compose up -d
```

---

## Step 12: Verify Connector Status

Check that the connector is running:

```bash
docker compose ps
docker compose logs -f
```

You should see output indicating the connector has connected successfully.

In your Twingate Admin Console, the connector should show as **Online** (green status).

---

## Optional Configurations

### Custom DNS Server

If you need to use a specific DNS server for resolving internal resources, add to your environment:

```yaml
environment:
  - TWINGATE_DNS=192.168.1.1  # Your internal DNS server
```

### Enable Peer-to-Peer Connections

If clients may be on the same local network as the connector, remove the `sysctls` section to allow peer-to-peer connections:

```yaml
services:
  twingate-connector:
    image: twingate/connector:1
    # Remove sysctls section for local network access
    environment:
      # ... your environment variables
```

### Multiple Connectors for Redundancy

For high availability, deploy a second connector on another device. Twingate will automatically load-balance between them.

---

## Useful Commands

### View Logs

```bash
cd ~/twingate
docker compose logs -f
```

### Restart Connector

```bash
cd ~/twingate
docker compose restart
```

### Stop Connector

```bash
cd ~/twingate
docker compose down
```

### Update Connector

```bash
cd ~/twingate
docker compose pull
docker compose up -d
```

### Check Connector Status

```bash
docker ps | grep twingate
```

---

## Troubleshooting

### Connector Shows Offline

1. Check logs: `docker compose logs -f`
2. Verify tokens are correct in `.env`
3. Ensure outbound internet access is available
4. Check firewall isn't blocking outbound connections

### Docker Permission Denied

If you get permission errors, ensure you're in the docker group and have rebooted:

```bash
groups $USER  # Should show 'docker'
```

If not, run Step 6 again and reboot.

### Container Won't Start

Check Docker is running:

```bash
sudo systemctl status docker
sudo systemctl start docker  # If not running
```

---

## Security Notes

- **Never commit `.env` files to source control** - they contain sensitive tokens
- The `.env` file should have restricted permissions (`chmod 600`)
- Tokens should be treated as secrets
- No inbound firewall rules are required - only outbound internet access

---

## Quick Start (All Commands)

For convenience, here's a condensed version you can run sequentially:

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install dependencies
sudo apt install -y ca-certificates curl gnupg

# Add Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add user to docker group
sudo usermod -aG docker $USER

# Reboot (required!)
sudo reboot
```

After reboot:

```bash
# Create Twingate directory
mkdir -p ~/twingate && cd ~/twingate

# Create docker-compose.yml
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  twingate-connector:
    image: twingate/connector:1
    container_name: twingate-connector
    restart: unless-stopped
    pull_policy: always
    sysctls:
      - net.ipv4.ping_group_range=0 2147483647
    environment:
      - TWINGATE_NETWORK=${TWINGATE_NETWORK}
      - TWINGATE_ACCESS_TOKEN=${TWINGATE_ACCESS_TOKEN}
      - TWINGATE_REFRESH_TOKEN=${TWINGATE_REFRESH_TOKEN}
      - TWINGATE_LABEL_HOSTNAME=${HOSTNAME}
      - TWINGATE_LOG_ANALYTICS=v2
EOF

# Create .env file (EDIT THIS with your actual values!)
cat > .env << 'EOF'
TWINGATE_NETWORK=YOUR_NETWORK_NAME
TWINGATE_ACCESS_TOKEN=YOUR_ACCESS_TOKEN
TWINGATE_REFRESH_TOKEN=YOUR_REFRESH_TOKEN
EOF

# Secure and edit the .env file
chmod 600 .env
nano .env  # Edit with your credentials

# Start Twingate
docker compose up -d

# Verify
docker compose logs -f
```

---

## Sources

- [Twingate Docker Compose Deployment](https://www.twingate.com/docs/deploy-connector-with-docker-compose)
- [Twingate Connector Docker Hub](https://hub.docker.com/r/twingate/connector)
- [Docker Installation on Debian](https://docs.docker.com/engine/install/debian/)
- [Twingate ARM64 Support](https://www.twingate.com/changelog/linux-arm)
- [Twingate Raspberry Pi Guide](https://www.twingate.com/blog/raspberry-pi-home-assistant)
