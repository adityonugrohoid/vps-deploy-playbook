# Chapter 02 — Docker Foundation & Networking

> Install Docker the right way, understand networking, and set up the compose patterns that will carry you through 21+ containers.

---

## Table of Contents

1. [Installing Docker (The Modern Way)](#1-installing-docker-the-modern-way)
2. [Post-Install Setup](#2-post-install-setup)
3. [Docker Networking — The Single Network Strategy](#3-docker-networking--the-single-network-strategy)
4. [Docker Compose Fundamentals](#4-docker-compose-fundamentals)
5. [Volume Management](#5-volume-management)
6. [Common Gotchas](#6-common-gotchas)

---

## 1. Installing Docker (The Modern Way)

**Do not** run `sudo apt install docker.io`. That gives you an outdated version from Ubuntu's repos. Install from Docker's official repository.

### Remove old versions

```bash
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
```

### Add Docker's official GPG key and repo

```bash
# Prerequisites
sudo apt update
sudo apt install -y ca-certificates curl gnupg

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### Install Docker Engine + Compose

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### Verify installation

```bash
docker --version
# Docker version 27.x.x

docker compose version
# Docker Compose version v2.x.x
```

> **Note:** It's `docker compose` (with a space), not `docker-compose` (with a hyphen). The old standalone `docker-compose` binary is deprecated. The new one is a Docker CLI plugin.

---

## 2. Post-Install Setup

### Run Docker without sudo

```bash
# Add your user to the docker group
sudo usermod -aG docker deploy

# Log out and back in for the group change to take effect
exit
ssh deploy@YOUR_SERVER_IP

# Verify
docker ps
# Should work without sudo
```

### Enable Docker on boot

```bash
sudo systemctl enable docker
sudo systemctl enable containerd
```

### Configure Docker daemon

Create `/etc/docker/daemon.json` for sane defaults:

```bash
sudo nano /etc/docker/daemon.json
```

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-address-pools": [
    {
      "base": "172.20.0.0/16",
      "size": 24
    }
  ]
}
```

This does two critical things:
- **Log rotation:** Without this, container logs grow unbounded and will eat your disk. 10MB per file, 3 files max per container.
- **Address pool:** Prevents subnet conflicts when you have 20+ networks.

```bash
sudo systemctl restart docker
```

---

## 3. Docker Networking — The Single Network Strategy

This is the most important architectural decision in this chapter.

### The problem with default networking

By default, every `docker compose up` creates its own isolated network. With 21 services spread across multiple compose files, containers can't talk to each other.

You end up with:
```
network_app-a_default    (172.18.0.0/16)
network_app-b_default    (172.19.0.0/16)
network_chromadb_default (172.20.0.0/16)
```

App A can't reach ChromaDB. App B can't reach ChromaDB. Nothing works.

### The solution: One shared bridge network

Create a single Docker network that all services join:

```bash
docker network create --driver bridge app-network
```

Now every service in every compose file connects to `app-network`. They can reach each other by container name:

```
App A → http://chromadb:8000  ✅
App B → http://chromadb:8000  ✅
App C → http://app-a:8080     ✅
```

### Why a single network works at 21 containers

You might think "that won't scale." It does — for this use case. Here's why:

- **Bridge networks are fast.** Traffic between containers on the same bridge doesn't leave the host. It's effectively localhost speed.
- **DNS resolution is built in.** Docker's embedded DNS resolves container names automatically within a network.
- **21 containers is not 2,100.** At this scale, network segmentation adds complexity without meaningful security benefit. Your real security boundary is the VPS firewall + Nginx.

### When to use multiple networks

If you're running multi-tenant services where strict isolation between tenants is required — use separate networks. For a single operator running their own services? One network is fine.

---

## 4. Docker Compose Fundamentals

### Project structure

Here's how we organize compose files for multi-app deployments:

```
/opt/apps/
├── docker-compose.yml          # Main compose file
├── .env                        # Environment variables
├── app-a/
│   ├── Dockerfile
│   └── ...
├── app-b/
│   ├── Dockerfile
│   └── ...
└── shared/
    └── chromadb/
        └── data/               # Persistent volume mount
```

### The base compose pattern

See [docker-compose.base.yml](./docker-compose.base.yml) for the foundational template.

Key patterns in the base file:

**External network:** The `app-network` is created manually (not by compose), so it persists across `docker compose down` / `up` cycles:

```yaml
networks:
  app-network:
    external: true
```

**Restart policy:** `unless-stopped` means containers restart after a crash or reboot, but stay down if you explicitly stopped them:

```yaml
restart: unless-stopped
```

**Container naming:** Always set `container_name`. Without it, Docker generates names like `apps-app-a-1`, which makes logs and debugging harder:

```yaml
container_name: app-a
```

### Environment variables

Use a `.env` file at the project root. Docker Compose automatically reads it:

```env
# .env
CHROMADB_HOST=chromadb
CHROMADB_PORT=8000
APP_A_PORT=8080
APP_B_PORT=8081
```

Reference in compose:

```yaml
services:
  app-a:
    environment:
      - CHROMADB_HOST=${CHROMADB_HOST}
      - CHROMADB_PORT=${CHROMADB_PORT}
    ports:
      - "${APP_A_PORT}:8080"
```

> **Never commit `.env` files.** They belong in `.gitignore`. Use `.env.example` to document required variables.

---

## 5. Volume Management

### Named volumes vs bind mounts

| | Named Volumes | Bind Mounts |
|---|---|---|
| **Syntax** | `my-data:/app/data` | `./data:/app/data` |
| **Managed by** | Docker | You |
| **Location** | `/var/lib/docker/volumes/` | Wherever you put it |
| **Backup** | Requires `docker cp` or volume commands | Standard file system tools |
| **Best for** | Databases, persistent storage | Config files, development |

### Our strategy: bind mounts for everything

**Opinion:** Use bind mounts. Named volumes are a black box — the data lives in `/var/lib/docker/volumes/` with opaque directory names. When you need to backup ChromaDB data, you want to know exactly where it is.

```yaml
services:
  chromadb:
    image: chromadb/chroma:latest
    container_name: chromadb
    volumes:
      - /opt/apps/shared/chromadb/data:/chroma/chroma
    networks:
      - app-network
```

Now ChromaDB data lives at `/opt/apps/shared/chromadb/data/`. You can `tar` it, `rsync` it, or inspect it directly.

### Volume permissions

The #1 cause of "container starts then immediately dies" is volume permission errors. The user inside the container doesn't match the user who owns the host directory.

```bash
# Check what user the container runs as
docker inspect chromadb --format '{{.Config.User}}'

# Fix permissions on the host
sudo chown -R 1000:1000 /opt/apps/shared/chromadb/data/
```

---

## 6. Common Gotchas

### Container DNS resolution fails

**Symptom:** `curl http://app-a:8080` from inside app-b returns "could not resolve host."

**Cause:** The containers are on different networks, or you're using `docker run` instead of compose (which doesn't auto-join the network).

**Fix:** Ensure both services have `networks: [app-network]` in their compose config.

### Port conflicts

**Symptom:** `Bind for 0.0.0.0:8080 failed: port is already allocated`

**Cause:** Two containers are trying to expose the same host port.

**Fix:** Remember — containers have their own internal ports. Only the HOST port needs to be unique:

```yaml
# This works fine:
app-a:
  ports:
    - "8080:8080"   # Host 8080 → Container 8080
app-b:
  ports:
    - "8081:8080"   # Host 8081 → Container 8080 (same internal port, different host port)
```

But with Nginx in front, you often don't need to expose host ports at all. Just let Nginx proxy to the container's internal port via the Docker network.

### Compose file changes not taking effect

**Symptom:** You changed `docker-compose.yml` but the running container doesn't reflect the change.

**Fix:** `docker compose up -d` only recreates containers whose configuration has changed. But it's smart, not psychic. If you changed environment variables in `.env`, you need:

```bash
docker compose up -d --force-recreate service-name
```

### Container restarts in a loop

**Symptom:** `docker ps` shows a container with status "Restarting (1) 5 seconds ago."

**Debug:**
```bash
# Check the logs
docker logs container-name --tail 50

# Common causes:
# 1. Missing environment variable
# 2. Volume permission error
# 3. Port already in use inside the container
# 4. Application crash (check the app's error output)
```

### Disk space disappears

**Symptom:** Server runs out of disk. `df -h` shows /var at 95%.

**Cause:** Docker images, build cache, and container logs.

**Fix:**
```bash
# See what's using space
docker system df

# Remove unused images, containers, and build cache
docker system prune -a --volumes

# Or be more selective:
docker image prune -a  # Remove unused images only
```

Set up the log rotation from Section 2 to prevent this proactively.

---

## What's Next?

Docker is installed, networking is configured, and you understand the compose patterns. In [Chapter 03](../03-nginx-routing/), we set up Nginx as a reverse proxy to route subdomains to containers.

---

[← Chapter 01: VPS Setup](../01-vps-setup/) | [Chapter 03: Nginx Routing →](../03-nginx-routing/)
