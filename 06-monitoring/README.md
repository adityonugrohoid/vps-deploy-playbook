# Chapter 06 — Monitoring & Health Checks

> Know before your users do. Set up health checks, log management, and lightweight alerting without the overhead of a full observability stack.

Running 21 containers without monitoring is like driving at night without headlights. Everything seems fine — until it isn't.

---

## Table of Contents

1. [Docker Health Checks](#1-docker-health-checks)
2. [Log Management](#2-log-management)
3. [Resource Monitoring](#3-resource-monitoring)
4. [Lightweight Alerting](#4-lightweight-alerting)
5. [Disk Space Management](#5-disk-space-management)
6. [When to Upgrade to Prometheus/Grafana](#6-when-to-upgrade-to-prometheusgrafana)

---

## 1. Docker Health Checks

Health checks tell Docker whether a container is actually working — not just running. A container can be "running" but completely unresponsive (deadlocked, out of memory, broken dependency).

### Adding health checks to Compose

```yaml
services:
  app-chatbot:
    build: ./apps/chatbot
    container_name: app-chatbot
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/health"]
      interval: 30s      # Check every 30 seconds
      timeout: 10s       # Fail if no response in 10 seconds
      retries: 3         # Mark unhealthy after 3 consecutive failures
      start_period: 30s  # Grace period for startup
    networks:
      - app-network
```

### Health check patterns by service type

**HTTP API (FastAPI, Flask, Express):**
```yaml
healthcheck:
  test: ["CMD", "curl", "-sf", "http://localhost:8080/health"]
  interval: 30s
  timeout: 10s
  retries: 3
```

Your app needs a `/health` endpoint:
```python
# FastAPI example
@app.get("/health")
async def health():
    return {"status": "ok"}
```

**For a deeper health check** (verifies dependencies too):
```python
@app.get("/health")
async def health():
    checks = {}

    # Check ChromaDB
    try:
        chromadb_client.heartbeat()
        checks["chromadb"] = "ok"
    except Exception:
        checks["chromadb"] = "error"

    # Check Redis
    try:
        redis_client.ping()
        checks["redis"] = "ok"
    except Exception:
        checks["redis"] = "error"

    all_ok = all(v == "ok" for v in checks.values())
    status_code = 200 if all_ok else 503

    return JSONResponse(
        status_code=status_code,
        content={"status": "ok" if all_ok else "degraded", "checks": checks}
    )
```

**Database (ChromaDB, Redis, PostgreSQL):**
```yaml
# ChromaDB
healthcheck:
  test: ["CMD", "curl", "-sf", "http://localhost:8000/api/v1/heartbeat"]
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 30s

# Redis
healthcheck:
  test: ["CMD", "redis-cli", "ping"]
  interval: 30s
  timeout: 5s
  retries: 3

# PostgreSQL
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U postgres"]
  interval: 30s
  timeout: 5s
  retries: 3
```

**Nginx:**
```yaml
healthcheck:
  test: ["CMD", "nginx", "-t"]
  interval: 60s
  timeout: 5s
  retries: 3
```

### Checking health status

```bash
# See health status for all containers
docker ps --format "table {{.Names}}\t{{.Status}}"

# Output:
# NAMES           STATUS
# app-chatbot     Up 2 hours (healthy)
# app-portfolio   Up 2 hours (healthy)
# svc-chromadb    Up 3 hours (healthy)
# svc-redis       Up 3 hours (healthy)
# app-embedder    Up 1 hour (unhealthy)    ← Problem!

# Inspect health check details
docker inspect app-embedder --format '{{json .State.Health}}' | jq
```

### Using health checks with depends_on

```yaml
services:
  app-chatbot:
    depends_on:
      chromadb:
        condition: service_healthy  # Wait until ChromaDB passes health check
      redis:
        condition: service_healthy
```

This prevents your app from starting before its dependencies are ready — no more "connection refused" errors on startup.

---

## 2. Log Management

### Viewing logs

```bash
# Follow logs for a single service
docker compose logs -f app-chatbot

# Last 100 lines
docker compose logs --tail 100 app-chatbot

# Logs from multiple services
docker compose logs -f app-chatbot svc-chromadb

# All logs with timestamps
docker compose logs -f --timestamps

# Logs since a specific time
docker compose logs --since "2024-01-15T10:00:00" app-chatbot
```

### Log rotation (critical!)

Without log rotation, container logs grow unbounded. A chatty app can fill your disk in days.

This should already be configured from [Chapter 02](../02-docker-foundation/), but verify:

```bash
# Check Docker daemon config
cat /etc/docker/daemon.json
```

Expected:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

This limits each container to 30MB of logs (3 files x 10MB). For 21 containers, that's a max of 630MB of logs.

### Per-container log overrides

For chatty services, you can set stricter limits:

```yaml
services:
  app-chatbot:
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "2"
```

### Where logs live on disk

```bash
# Find log files for a container
docker inspect app-chatbot --format '{{.LogPath}}'
# /var/lib/docker/containers/<container-id>/<container-id>-json.log

# Check total log size
sudo du -sh /var/lib/docker/containers/*/
```

### Log aggregation (lightweight)

For 21 containers, tailing individual logs gets tedious. A simple solution without external tools:

```bash
#!/bin/bash
# watch-logs.sh — Tail important services in parallel

tmux new-session -d -s logs

# Create panes for key services
tmux split-window -h
tmux split-window -v
tmux select-pane -t 0
tmux split-window -v

# Assign each pane a service
tmux send-keys -t 0 "docker compose logs -f --tail 20 infra-nginx" Enter
tmux send-keys -t 1 "docker compose logs -f --tail 20 svc-chromadb" Enter
tmux send-keys -t 2 "docker compose logs -f --tail 20 app-chatbot" Enter
tmux send-keys -t 3 "docker compose logs -f --tail 20 app-portfolio" Enter

tmux attach-session -t logs
```

---

## 3. Resource Monitoring

### Real-time monitoring with docker stats

```bash
# All containers, one snapshot
docker stats --no-stream

# Formatted output
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}"
```

Example output:
```
NAME              CPU %     MEM USAGE / LIMIT     MEM %     NET I/O
infra-nginx       0.02%     15.2MiB / 128MiB      11.88%    1.2GB / 890MB
svc-chromadb      1.30%     412MiB / 1GiB         40.23%    56MB / 120MB
svc-redis         0.15%     28MiB / 256MiB        10.94%    12MB / 8.5MB
app-chatbot       0.45%     180MiB / 384MiB       46.88%    230MB / 450MB
app-portfolio     0.12%     95MiB / 384MiB        24.74%    45MB / 89MB
app-embedder      12.50%    1.8GiB / 2GiB         90.00%    890MB / 2.1GB  ← Watch this
```

### Automated monitoring script

```bash
#!/bin/bash
# monitor.sh — Check all containers and alert on issues
# Run via cron: */5 * * * * /opt/apps/scripts/monitor.sh

LOG_FILE="/var/log/container-monitor.log"
ALERT_MEM_PERCENT=85
ALERT_CPU_PERCENT=80

echo "=== Container Health Check: $(date) ===" >> "$LOG_FILE"

# Check for unhealthy containers
UNHEALTHY=$(docker ps --filter health=unhealthy --format "{{.Names}}" 2>/dev/null)
if [ -n "$UNHEALTHY" ]; then
    echo "ALERT: Unhealthy containers: ${UNHEALTHY}" >> "$LOG_FILE"
    # Send alert (see Section 4)
fi

# Check for restarting containers (crash loops)
RESTARTING=$(docker ps --filter status=restarting --format "{{.Names}}" 2>/dev/null)
if [ -n "$RESTARTING" ]; then
    echo "ALERT: Restarting containers: ${RESTARTING}" >> "$LOG_FILE"
fi

# Check for stopped containers that should be running
EXITED=$(docker ps -a --filter status=exited --format "{{.Names}}" 2>/dev/null)
if [ -n "$EXITED" ]; then
    echo "WARN: Exited containers: ${EXITED}" >> "$LOG_FILE"
fi

# Check memory usage
docker stats --no-stream --format "{{.Name}} {{.MemPerc}}" 2>/dev/null | while read NAME MEM; do
    MEM_NUM=${MEM%\%}
    if (( $(echo "$MEM_NUM > $ALERT_MEM_PERCENT" | bc -l) )); then
        echo "ALERT: ${NAME} memory at ${MEM}" >> "$LOG_FILE"
    fi
done

echo "Check complete." >> "$LOG_FILE"
```

### System-level monitoring

Don't forget the host itself:

```bash
# Disk usage
df -h /
df -h /var/lib/docker

# Memory
free -h

# CPU load
uptime

# Network connections
ss -tunlp
```

---

## 4. Lightweight Alerting

### Option 1: Cron + curl to webhook

The simplest alerting: a cron job that checks health and sends a webhook on failure.

```bash
#!/bin/bash
# alert.sh — Send alerts via webhook
# Works with Discord, Slack, Telegram, or any webhook URL

WEBHOOK_URL="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"

send_alert() {
    local MESSAGE=$1
    curl -s -H "Content-Type: application/json" \
        -d "{\"content\": \"**VPS Alert:** ${MESSAGE}\"}" \
        "$WEBHOOK_URL" > /dev/null
}

# Check for unhealthy containers
UNHEALTHY=$(docker ps --filter health=unhealthy --format "{{.Names}}" | tr '\n' ', ')
if [ -n "$UNHEALTHY" ]; then
    send_alert "Unhealthy containers: ${UNHEALTHY}"
fi

# Check disk usage
DISK_USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
if [ "$DISK_USAGE" -gt 85 ]; then
    send_alert "Disk usage at ${DISK_USAGE}%"
fi

# Check if critical services are running
for SERVICE in infra-nginx svc-chromadb svc-redis; do
    STATUS=$(docker inspect "$SERVICE" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    if [ "$STATUS" != "running" ]; then
        send_alert "${SERVICE} is ${STATUS}!"
    fi
done
```

Add to cron:
```bash
# Run every 5 minutes
crontab -e
*/5 * * * * /opt/apps/scripts/alert.sh
```

### Option 2: Telegram bot alerts

```bash
# alert-telegram.sh
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"

send_telegram() {
    local MESSAGE=$1
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${MESSAGE}" \
        -d "parse_mode=Markdown" > /dev/null
}

# Same checks as above, using send_telegram instead of send_alert
```

### Option 3: Email (using msmtp)

```bash
# Install lightweight mail client
sudo apt install -y msmtp msmtp-mta

# Configure ~/.msmtprc
cat > ~/.msmtprc << 'EOF'
defaults
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account gmail
host smtp.gmail.com
port 587
from your@gmail.com
auth on
user your@gmail.com
password your-app-password

account default : gmail
EOF

chmod 600 ~/.msmtprc

# Send alert email
echo "Subject: VPS Alert - Container Down
Container app-chatbot is unhealthy. Check logs immediately." | msmtp your@email.com
```

---

## 5. Disk Space Management

### The #1 cause of VPS failures: disk full

Docker is a disk hog. Images, build cache, container logs, and volumes accumulate silently.

### Check what's using space

```bash
# Docker-specific disk usage
docker system df

# Output:
# TYPE            TOTAL   ACTIVE  SIZE      RECLAIMABLE
# Images          45      21      12.5GB    5.2GB (41%)
# Containers      21      21      890MB     0B (0%)
# Local Volumes   8       8       2.1GB     0B (0%)
# Build Cache     —       —       3.4GB     3.4GB

# Detailed image usage
docker system df -v
```

### Cleanup strategies

```bash
# Remove dangling images (untagged, unused)
docker image prune -f

# Remove all unused images (not just dangling)
docker image prune -a -f

# Remove build cache
docker builder prune -f

# Nuclear option: remove everything unused
docker system prune -a --volumes -f
# WARNING: This removes stopped containers, unused networks,
# unused images, AND unused volumes. Be careful with --volumes.
```

### Automated cleanup with cron

```bash
#!/bin/bash
# cleanup.sh — Weekly Docker cleanup
# Cron: 0 3 * * 0 /opt/apps/scripts/cleanup.sh

echo "=== Docker Cleanup: $(date) ===" >> /var/log/docker-cleanup.log

# Before
BEFORE=$(docker system df --format "{{.Size}}" | head -1)
echo "Before: ${BEFORE}" >> /var/log/docker-cleanup.log

# Remove dangling images and build cache
docker image prune -f >> /var/log/docker-cleanup.log 2>&1
docker builder prune -f --keep-storage 2GB >> /var/log/docker-cleanup.log 2>&1

# After
AFTER=$(docker system df --format "{{.Size}}" | head -1)
echo "After: ${AFTER}" >> /var/log/docker-cleanup.log
echo "Cleanup complete." >> /var/log/docker-cleanup.log
```

### Monitoring disk proactively

Add this to your alert script:

```bash
# Alert if Docker is using more than 80% of available disk
DOCKER_DIR="/var/lib/docker"
USAGE=$(df "${DOCKER_DIR}" --output=pcent | tail -1 | tr -d ' %')

if [ "$USAGE" -gt 80 ]; then
    send_alert "Docker disk at ${USAGE}%. Run cleanup."
fi
```

---

## 6. When to Upgrade to Prometheus/Grafana

### You DON'T need Prometheus/Grafana when:

- You have ≤30 containers
- You're a solo operator
- Cron + webhook alerts are sufficient
- You don't need historical metrics or dashboards
- Your VPS has limited RAM (<2GB free)

The scripts in this chapter handle monitoring for most single-VPS setups. Prometheus + Grafana adds ~1GB RAM overhead and significant configuration complexity.

### You DO need Prometheus/Grafana when:

- You have multiple VPS instances to monitor
- You need historical metrics (CPU/memory trends over weeks)
- Multiple team members need dashboards
- You need alerting rules more complex than "is it healthy?"
- You're running customer-facing services with SLAs

### Middle ground: Uptime Kuma

If you want a dashboard without the Prometheus/Grafana complexity, consider [Uptime Kuma](https://github.com/louislam/uptime-kuma):

```yaml
uptime-kuma:
  image: louislam/uptime-kuma:latest
  container_name: tool-uptime-kuma
  restart: unless-stopped
  volumes:
    - ./tools/uptime-kuma/data:/app/data
  networks:
    - app-network
```

It gives you:
- HTTP/TCP/DNS monitoring
- Beautiful dashboard
- Notifications (Discord, Slack, Telegram, email)
- Status pages
- ~100MB RAM

For most single-VPS deployments, Uptime Kuma + the cron scripts from this chapter is the sweet spot.

---

## Summary: The Monitoring Stack

```
┌──────────────────────────────────────────────────────┐
│                Monitoring Stack                       │
├──────────────────────────────────────────────────────┤
│                                                       │
│  Docker Health Checks (built-in)                      │
│  └─ Per-container health endpoints                    │
│  └─ Auto-restart on failure                           │
│                                                       │
│  Cron Scripts (every 5 min)                           │
│  └─ Check container health status                     │
│  └─ Monitor resource usage                            │
│  └─ Check disk space                                  │
│  └─ Send alerts via webhook/Telegram/email            │
│                                                       │
│  Weekly Cleanup (cron, Sundays 3 AM)                  │
│  └─ Prune dangling images                             │
│  └─ Clear build cache                                 │
│  └─ Log results                                       │
│                                                       │
│  Optional: Uptime Kuma                                │
│  └─ Dashboard for all services                        │
│  └─ External availability monitoring                  │
│  └─ Status page for stakeholders                      │
│                                                       │
│  Cost: $0 (or ~100MB RAM for Uptime Kuma)             │
│  Complexity: Low                                      │
│  Effectiveness: Covers 95% of solo-operator needs     │
│                                                       │
└──────────────────────────────────────────────────────┘
```

---

## What's Next?

You now have a complete, battle-tested playbook for running multiple apps on a single VPS:

1. **Hardened server** (Chapter 01)
2. **Docker foundation** (Chapter 02)
3. **Nginx routing** (Chapter 03)
4. **Multi-app architecture** (Chapter 04)
5. **Selective deployments** (Chapter 05)
6. **Monitoring & alerts** (Chapter 06)

Future chapters will cover automated backups, CI/CD with GitHub Actions, and scaling to multiple VPS instances.

---

[← Chapter 05: Selective Updates](../05-selective-updates/) | [Back to Playbook →](../README.md)
