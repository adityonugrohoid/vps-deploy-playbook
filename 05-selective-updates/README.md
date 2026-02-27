# Chapter 05 — Selective Update Scripts

> Update one container, not twenty-one. Deploy with confidence using targeted scripts and rollback strategies.

When you're running 21 containers, redeploying everything for a one-line fix in one app is wasteful, slow, and risky. This chapter covers the per-app deployment pattern that lets you surgically update individual services.

---

## Table of Contents

1. [Why Selective Updates](#1-why-selective-updates)
2. [The Deploy Script](#2-the-deploy-script)
3. [SSH-Based Remote Deployment](#3-ssh-based-remote-deployment)
4. [Rollback Strategy](#4-rollback-strategy)
5. [Blue-Green Deployment Lite](#5-blue-green-deployment-lite)
6. [Deployment Checklist](#6-deployment-checklist)

---

## 1. Why Selective Updates

### The naive approach

```bash
# "Just redeploy everything"
docker compose down && docker compose up -d --build
```

What actually happens:
- All 21 containers stop simultaneously (downtime for everything)
- All 21 images rebuild (even if only 1 changed)
- All 21 containers restart (competing for CPU during startup)
- If one container fails to start, you're debugging 21 services at once
- Total time: 5-15 minutes of downtime

### The selective approach

```bash
# Update only what changed
docker compose up -d --build app-chatbot
```

What happens:
- 1 container rebuilds (~30 seconds)
- 1 container restarts (other 20 are untouched)
- If it fails, only 1 service is affected
- Total time: ~30 seconds, zero downtime for other services

### The math at scale

| Action | Full Redeploy | Selective |
|--------|---------------|-----------|
| Build time | 5-15 min | 10-30 sec |
| Downtime | All services | 1 service |
| Risk | Cascading failures | Isolated |
| Bandwidth | Pull all images | Pull 1 layer |
| Rollback | Complex | Simple |

---

## 2. The Deploy Script

See the [deploy.sh](./deploy.sh) script in this directory. Here's how it works:

### Basic usage

```bash
# Deploy a single service (pull latest image + restart)
./deploy.sh app-chatbot

# Deploy with rebuild (for services built from local Dockerfiles)
./deploy.sh app-chatbot --build

# Deploy multiple services
./deploy.sh app-chatbot app-portfolio app-api-gateway

# Deploy with pre-deploy health check
./deploy.sh app-chatbot --health-check
```

### What the script does

1. **Validates** the service name exists in `docker-compose.yml`
2. **Takes a snapshot** of the current container state (for rollback)
3. **Builds or pulls** the updated image
4. **Stops** only the target container
5. **Starts** the new container
6. **Runs a health check** to verify the deployment
7. **Rolls back** automatically if the health check fails

### Key design decisions

**Why SSH instead of CI/CD?** For solo operators managing a single VPS, SSH is simpler, faster, and has no external dependencies. You don't need GitHub Actions, Jenkins, or ArgoCD for 21 containers on one server. `ssh + docker compose up -d` is the entire pipeline.

**Why not use Watchtower?** Watchtower auto-updates containers when new images are available. Sounds great — until it updates a broken image at 3 AM. Explicit deployments let you control when and what gets updated.

---

## 3. SSH-Based Remote Deployment

### From your local machine

The most common workflow: you develop locally, push code to a registry (or build on the server), then deploy via SSH.

```bash
# Option A: Build on the server (no registry needed)
ssh deploy@vps "cd /opt/apps && git pull && docker compose build app-chatbot && docker compose up -d app-chatbot"

# Option B: Push to registry, pull on server
docker build -t myregistry/app-chatbot:latest ./apps/chatbot
docker push myregistry/app-chatbot:latest
ssh deploy@vps "cd /opt/apps && docker compose pull app-chatbot && docker compose up -d app-chatbot"
```

### SSH config for convenience

Add to `~/.ssh/config` on your local machine:

```
Host vps
    HostName YOUR_SERVER_IP
    User deploy
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

Now you can just:

```bash
ssh vps "cd /opt/apps && docker compose up -d --build app-chatbot"
```

### Multi-command deployment

For more complex deployments that need pre/post steps:

```bash
ssh vps << 'DEPLOY'
  set -euo pipefail
  cd /opt/apps

  echo "=== Pulling latest code ==="
  git pull

  echo "=== Building app-chatbot ==="
  docker compose build app-chatbot

  echo "=== Deploying app-chatbot ==="
  docker compose up -d app-chatbot

  echo "=== Verifying ==="
  sleep 5
  docker ps --filter name=app-chatbot --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

  echo "=== Done ==="
DEPLOY
```

---

## 4. Rollback Strategy

### Image-based rollback

Docker keeps previous image layers. You can roll back by restarting with the previous image:

```bash
# See image history
docker images myregistry/app-chatbot --format "table {{.Tag}}\t{{.CreatedAt}}\t{{.Size}}"

# Roll back to previous image
docker compose stop app-chatbot
docker compose up -d --no-build app-chatbot  # Uses the previously running image
```

### Tag-based rollback (recommended)

Instead of using `latest`, tag your images with version numbers or git hashes:

```bash
# Build with a version tag
GIT_HASH=$(git rev-parse --short HEAD)
docker build -t myregistry/app-chatbot:${GIT_HASH} ./apps/chatbot
docker push myregistry/app-chatbot:${GIT_HASH}

# Deploy specific version
ssh vps "cd /opt/apps && sed -i 's|app-chatbot:.*|app-chatbot:${GIT_HASH}|' docker-compose.yml && docker compose up -d app-chatbot"

# Roll back to specific version
ssh vps "cd /opt/apps && sed -i 's|app-chatbot:.*|app-chatbot:abc1234|' docker-compose.yml && docker compose up -d app-chatbot"
```

### Snapshot before deploy

The deploy script automatically records the current state:

```bash
# Manual snapshot
docker inspect app-chatbot --format '{{.Config.Image}}' > /opt/apps/.rollback/app-chatbot.image
docker inspect app-chatbot --format '{{json .Config.Env}}' > /opt/apps/.rollback/app-chatbot.env

# Rollback
PREV_IMAGE=$(cat /opt/apps/.rollback/app-chatbot.image)
docker stop app-chatbot
docker run -d --name app-chatbot --network app-network ${PREV_IMAGE}
```

---

## 5. Blue-Green Deployment Lite

For critical services where even 5 seconds of downtime is unacceptable.

### The pattern

1. Start a **new** container alongside the existing one
2. Health check the new container
3. Switch Nginx to point to the new container
4. Stop the old container

```bash
#!/bin/bash
# blue-green-deploy.sh — Zero-downtime deployment for critical services
set -euo pipefail

SERVICE=$1
NEW_NAME="${SERVICE}-green"
OLD_NAME="${SERVICE}"

echo "=== Starting new container ==="
docker compose run -d --name ${NEW_NAME} --no-deps ${SERVICE}

echo "=== Waiting for health check ==="
for i in {1..30}; do
    if docker exec ${NEW_NAME} curl -sf http://localhost:8080/health > /dev/null 2>&1; then
        echo "Health check passed!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Health check failed. Aborting."
        docker stop ${NEW_NAME} && docker rm ${NEW_NAME}
        exit 1
    fi
    sleep 2
done

echo "=== Switching Nginx ==="
# Update Nginx upstream to point to new container
docker exec infra-nginx nginx -s reload

echo "=== Stopping old container ==="
docker stop ${OLD_NAME}
docker rename ${NEW_NAME} ${OLD_NAME}

echo "=== Done! Zero-downtime deployment complete ==="
```

### When to use this

- Payment processing services
- Authentication services
- API gateways that other services depend on

For most apps? Regular `docker compose up -d` is fine. The restart takes <5 seconds.

---

## 6. Deployment Checklist

Use this checklist before and after every deployment.

### Pre-deploy

```
[ ] Code tested locally
[ ] Environment variables verified
[ ] No breaking changes to shared services (ChromaDB, Redis)
[ ] Disk space available (docker system df)
[ ] Other services healthy (docker ps)
```

### Deploy

```bash
# 1. SSH to server
ssh vps

# 2. Pull latest code (if building on server)
cd /opt/apps && git pull

# 3. Build
docker compose build app-name

# 4. Deploy
docker compose up -d app-name

# 5. Verify
docker ps --filter name=app-name
docker logs app-name --tail 20
```

### Post-deploy

```
[ ] Container is running (docker ps)
[ ] No crash loops (check status for "Restarting")
[ ] Logs show clean startup (docker logs app-name --tail 50)
[ ] HTTP endpoint responds (curl -s https://app-name.example.com)
[ ] Dependent services unaffected
```

### Emergency rollback

```bash
# Stop the broken deployment
docker compose stop app-name

# Rebuild from previous commit
git log --oneline -5  # Find the last good commit
git checkout PREVIOUS_COMMIT -- apps/app-name/
docker compose build app-name
docker compose up -d app-name

# Or pull the previous image
docker compose pull app-name  # If using versioned tags
docker compose up -d app-name
```

---

## What's Next?

You can now deploy individual services with confidence. In [Chapter 06](../06-monitoring/), we set up monitoring and health checks so you know when something goes wrong — before your users do.

---

[← Chapter 04: Multi-App Architecture](../04-multi-app-architecture/) | [Chapter 06: Monitoring →](../06-monitoring/)
