# Chapter 07 — Automated Backups

> The container you can rebuild. The data you cannot. Automate backups before you learn this the hard way.

Running 21 containers means managing persistent data across volumes, databases, and configuration files. This chapter covers a practical, automated backup strategy that works for single-VPS deployments.

---

## Table of Contents

1. [What to Back Up (and What Not To)](#1-what-to-back-up-and-what-not-to)
2. [Backup Script](#2-backup-script)
3. [Database Dumps](#3-database-dumps)
4. [Off-Site Storage with rclone](#4-off-site-storage-with-rclone)
5. [Automated Scheduling](#5-automated-scheduling)
6. [Restore Procedures](#6-restore-procedures)
7. [Testing Your Backups](#7-testing-your-backups)

---

## 1. What to Back Up (and What Not To)

### Back up

| Data | Location | Why |
|------|----------|-----|
| ChromaDB data | `./services/chromadb/data/` | Vector embeddings, collections — expensive to regenerate |
| Redis AOF/RDB | `./services/redis/data/` | Session data, cache state |
| App configs | `.env`, `docker-compose.yml` | Your entire architecture definition |
| Nginx config | `./nginx/nginx.conf`, `./nginx/conf.d/` | Routing rules, SSL settings |
| SSL certificates | `/etc/letsencrypt/` | Takes time to regenerate, rate limited |
| Ollama models | `./services/ollama/models/` | Large downloads, slow to re-pull |
| Custom scripts | `./scripts/` | Your deployment automation |

### Don't back up

| Data | Why |
|------|-----|
| Docker images | Rebuild from Dockerfile or pull from registry |
| Container logs | Ephemeral, rotated automatically |
| Build cache | Regenerated on next build |
| `/var/lib/docker/` | Managed by Docker, not portable |

### The golden rule

**Back up data that's hard to recreate. Skip everything you can rebuild.**

---

## 2. Backup Script

A single script that handles all backup operations:

```bash
#!/bin/bash
##############################################################################
# backup.sh — Automated backup for Docker volumes and configs
#
# Usage:
#   ./backup.sh                    # Full backup
#   ./backup.sh --volumes-only     # Only persistent data
#   ./backup.sh --configs-only     # Only configuration files
#   ./backup.sh --upload           # Backup + upload to off-site
#
# Environment:
#   BACKUP_DIR     Local backup directory (default: /opt/backups)
#   APP_DIR        Application directory (default: /opt/apps)
#   RETENTION_DAYS Number of days to keep local backups (default: 7)
##############################################################################

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

BACKUP_DIR="${BACKUP_DIR:-/opt/backups}"
APP_DIR="${APP_DIR:-/opt/apps}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "[INFO]  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Parse Arguments ──────────────────────────────────────────────────────────

VOLUMES_ONLY=false
CONFIGS_ONLY=false
UPLOAD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --volumes-only) VOLUMES_ONLY=true; shift ;;
        --configs-only) CONFIGS_ONLY=true; shift ;;
        --upload)       UPLOAD=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Setup ────────────────────────────────────────────────────────────────────

mkdir -p "${BACKUP_PATH}"
log_info "Backup started: ${BACKUP_NAME}"
log_info "Backup directory: ${BACKUP_PATH}"

# ── Backup Volumes ───────────────────────────────────────────────────────────

backup_volumes() {
    log_info "Backing up persistent volumes..."

    # ChromaDB
    if [ -d "${APP_DIR}/services/chromadb/data" ]; then
        tar -czf "${BACKUP_PATH}/chromadb_data.tar.gz" \
            -C "${APP_DIR}/services/chromadb" data/
        log_ok "ChromaDB data backed up ($(du -sh "${BACKUP_PATH}/chromadb_data.tar.gz" | cut -f1))"
    else
        log_warn "ChromaDB data directory not found, skipping"
    fi

    # Redis
    if [ -d "${APP_DIR}/services/redis/data" ]; then
        # Trigger Redis BGSAVE before backup for consistency
        docker exec svc-redis redis-cli BGSAVE 2>/dev/null || true
        sleep 2
        tar -czf "${BACKUP_PATH}/redis_data.tar.gz" \
            -C "${APP_DIR}/services/redis" data/
        log_ok "Redis data backed up"
    fi

    # Ollama models
    if [ -d "${APP_DIR}/services/ollama/models" ]; then
        tar -czf "${BACKUP_PATH}/ollama_models.tar.gz" \
            -C "${APP_DIR}/services/ollama" models/
        log_ok "Ollama models backed up ($(du -sh "${BACKUP_PATH}/ollama_models.tar.gz" | cut -f1))"
    fi

    # App-specific volumes (any app with a data/ directory)
    for APP_DATA in "${APP_DIR}"/apps/*/data; do
        if [ -d "$APP_DATA" ]; then
            APP_NAME=$(basename "$(dirname "$APP_DATA")")
            tar -czf "${BACKUP_PATH}/${APP_NAME}_data.tar.gz" \
                -C "$(dirname "$APP_DATA")" data/
            log_ok "${APP_NAME} data backed up"
        fi
    done
}

# ── Backup Configs ───────────────────────────────────────────────────────────

backup_configs() {
    log_info "Backing up configuration files..."

    # Docker Compose and env files
    tar -czf "${BACKUP_PATH}/configs.tar.gz" \
        -C "${APP_DIR}" \
        docker-compose.yml \
        .env \
        2>/dev/null || true
    log_ok "Compose + env files backed up"

    # Nginx configuration
    if [ -d "${APP_DIR}/nginx" ]; then
        tar -czf "${BACKUP_PATH}/nginx_config.tar.gz" \
            -C "${APP_DIR}" nginx/
        log_ok "Nginx config backed up"
    fi

    # SSL certificates
    if [ -d "/etc/letsencrypt" ]; then
        sudo tar -czf "${BACKUP_PATH}/letsencrypt.tar.gz" \
            -C /etc letsencrypt/
        log_ok "SSL certificates backed up"
    fi

    # Custom scripts
    if [ -d "${APP_DIR}/scripts" ]; then
        tar -czf "${BACKUP_PATH}/scripts.tar.gz" \
            -C "${APP_DIR}" scripts/
        log_ok "Scripts backed up"
    fi
}

# ── Execute ──────────────────────────────────────────────────────────────────

if [ "$CONFIGS_ONLY" = true ]; then
    backup_configs
elif [ "$VOLUMES_ONLY" = true ]; then
    backup_volumes
else
    backup_volumes
    backup_configs
fi

# ── Create manifest ─────────────────────────────────────────────────────────

log_info "Creating backup manifest..."
{
    echo "Backup: ${BACKUP_NAME}"
    echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Host: $(hostname)"
    echo ""
    echo "Files:"
    ls -lh "${BACKUP_PATH}/" | tail -n +2
    echo ""
    echo "Total size: $(du -sh "${BACKUP_PATH}" | cut -f1)"
    echo ""
    echo "Running containers at backup time:"
    docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || echo "(docker not available)"
} > "${BACKUP_PATH}/manifest.txt"

log_ok "Manifest created"

# ── Upload (optional) ───────────────────────────────────────────────────────

if [ "$UPLOAD" = true ]; then
    log_info "Uploading to off-site storage..."
    if command -v rclone &> /dev/null; then
        rclone copy "${BACKUP_PATH}" "offsite:vps-backups/${BACKUP_NAME}" --progress
        log_ok "Uploaded to off-site storage"
    else
        log_warn "rclone not installed. Skipping upload."
        log_warn "Install: curl https://rclone.org/install.sh | sudo bash"
    fi
fi

# ── Cleanup old backups ─────────────────────────────────────────────────────

log_info "Cleaning backups older than ${RETENTION_DAYS} days..."
DELETED=$(find "${BACKUP_DIR}" -maxdepth 1 -name "backup_*" -type d -mtime +${RETENTION_DAYS} -print -exec rm -rf {} \; | wc -l)
log_ok "Removed ${DELETED} old backup(s)"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_ok "Backup complete: ${BACKUP_NAME}"
log_info "Size: $(du -sh "${BACKUP_PATH}" | cut -f1)"
log_info "Location: ${BACKUP_PATH}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

---

## 3. Database Dumps

### ChromaDB

ChromaDB uses SQLite + Parquet files internally. The file-level backup from the script above works, but for consistency you should pause writes:

```bash
# Option A: Backup while running (usually fine for ChromaDB)
tar -czf chromadb_backup.tar.gz -C /opt/apps/services/chromadb data/

# Option B: Stop, backup, start (guarantees consistency)
docker compose stop chromadb
tar -czf chromadb_backup.tar.gz -C /opt/apps/services/chromadb data/
docker compose start chromadb
# Downtime: ~10 seconds
```

### Redis

Redis has two persistence mechanisms:

```bash
# Trigger a point-in-time snapshot
docker exec svc-redis redis-cli BGSAVE

# Wait for save to complete
docker exec svc-redis redis-cli LASTSAVE

# Copy the dump file
cp /opt/apps/services/redis/data/dump.rdb /opt/backups/redis_dump.rdb
```

If you enabled AOF (append-only file):

```bash
# The AOF file provides point-in-time recovery
cp /opt/apps/services/redis/data/appendonly.aof /opt/backups/redis_aof.aof
```

### PostgreSQL (if you use it)

```bash
# Dump a specific database
docker exec svc-postgres pg_dump -U postgres mydb > /opt/backups/mydb_$(date +%Y%m%d).sql

# Dump all databases
docker exec svc-postgres pg_dumpall -U postgres > /opt/backups/all_dbs_$(date +%Y%m%d).sql

# Compressed dump
docker exec svc-postgres pg_dump -U postgres -Fc mydb > /opt/backups/mydb_$(date +%Y%m%d).dump
```

---

## 4. Off-Site Storage with rclone

Local backups are useless if your VPS dies. Use [rclone](https://rclone.org/) to sync backups to cloud storage.

### Install rclone

```bash
curl https://rclone.org/install.sh | sudo bash
```

### Configure a remote

```bash
rclone config
# Follow the wizard:
# n) New remote
# name> offsite
# Storage> Choose your provider (e.g., s3, b2, gdrive, dropbox)
# Follow provider-specific prompts
```

### Popular free/cheap options

| Provider | Free Tier | Best For |
|----------|-----------|----------|
| Backblaze B2 | 10GB free | Best $/GB for large backups |
| Cloudflare R2 | 10GB free, no egress fees | If you use Cloudflare already |
| Google Drive | 15GB free | Quick setup, familiar |
| Wasabi | No free tier, $7/TB/mo | Serious backup storage |

### Upload backups

```bash
# Upload a specific backup
rclone copy /opt/backups/backup_20240115_030000 offsite:vps-backups/backup_20240115_030000

# Sync entire backup directory (mirror)
rclone sync /opt/backups offsite:vps-backups

# With progress and bandwidth limit (don't saturate your VPS)
rclone copy /opt/backups/latest offsite:vps-backups/latest \
    --progress \
    --bwlimit 10M
```

### Verify uploads

```bash
# List remote backups
rclone ls offsite:vps-backups

# Check sizes match
rclone size offsite:vps-backups
```

---

## 5. Automated Scheduling

### Cron setup

```bash
crontab -e
```

```cron
# Daily backup at 3 AM UTC
0 3 * * * /opt/apps/scripts/backup.sh --upload >> /var/log/backup.log 2>&1

# Weekly full backup with extended retention (Sundays)
0 4 * * 0 RETENTION_DAYS=30 /opt/apps/scripts/backup.sh --upload >> /var/log/backup.log 2>&1

# Monthly config-only backup (1st of each month)
0 5 1 * * /opt/apps/scripts/backup.sh --configs-only >> /var/log/backup.log 2>&1
```

### Verify cron is working

```bash
# Check cron logs
grep CRON /var/log/syslog | tail -20

# Check backup logs
tail -50 /var/log/backup.log

# List existing backups
ls -la /opt/backups/
```

### Monitoring backup health

Add to your alerting script (from Chapter 06):

```bash
# Alert if no backup in the last 25 hours
LATEST_BACKUP=$(find /opt/backups -maxdepth 1 -name "backup_*" -type d -mmin -1500 | head -1)
if [ -z "$LATEST_BACKUP" ]; then
    send_alert "No backup found in the last 25 hours!"
fi
```

---

## 6. Restore Procedures

### Full restore to a fresh VPS

```bash
# 1. Set up the new VPS (Chapter 01)
# 2. Install Docker (Chapter 02)

# 3. Download backups from off-site
rclone copy offsite:vps-backups/backup_LATEST /opt/restore/

# 4. Restore configs
cd /opt/apps
tar -xzf /opt/restore/configs.tar.gz
tar -xzf /opt/restore/nginx_config.tar.gz

# 5. Restore SSL certs
sudo tar -xzf /opt/restore/letsencrypt.tar.gz -C /etc/

# 6. Create the Docker network
docker network create app-network

# 7. Restore data volumes
tar -xzf /opt/restore/chromadb_data.tar.gz -C /opt/apps/services/chromadb/
tar -xzf /opt/restore/redis_data.tar.gz -C /opt/apps/services/redis/

# 8. Start everything
docker compose up -d

# 9. Verify
docker ps
```

### Restore a single service

```bash
# Stop the service
docker compose stop app-chatbot

# Restore its data
tar -xzf /opt/backups/backup_latest/app-chatbot_data.tar.gz \
    -C /opt/apps/apps/chatbot/

# Restart
docker compose up -d app-chatbot
```

### Restore Redis from dump

```bash
docker compose stop redis
cp /opt/backups/redis_dump.rdb /opt/apps/services/redis/data/dump.rdb
docker compose start redis
```

---

## 7. Testing Your Backups

> A backup you haven't tested is not a backup. It's a hope.

### Monthly restore drill

Schedule a monthly test where you restore to a local Docker environment:

```bash
#!/bin/bash
# test-restore.sh — Verify backup integrity

BACKUP_PATH=$1
TEMP_DIR=$(mktemp -d)

echo "Testing backup: ${BACKUP_PATH}"

# Test 1: All archive files are valid
echo "Checking archive integrity..."
for ARCHIVE in "${BACKUP_PATH}"/*.tar.gz; do
    if tar -tzf "$ARCHIVE" > /dev/null 2>&1; then
        echo "  OK: $(basename $ARCHIVE)"
    else
        echo "  FAIL: $(basename $ARCHIVE)"
        exit 1
    fi
done

# Test 2: Configs can be extracted
echo "Testing config extraction..."
tar -xzf "${BACKUP_PATH}/configs.tar.gz" -C "${TEMP_DIR}"
if [ -f "${TEMP_DIR}/docker-compose.yml" ]; then
    echo "  OK: docker-compose.yml present"
else
    echo "  FAIL: docker-compose.yml missing"
    exit 1
fi

# Test 3: Manifest exists and is readable
echo "Checking manifest..."
if [ -f "${BACKUP_PATH}/manifest.txt" ]; then
    echo "  OK: Manifest present"
    cat "${BACKUP_PATH}/manifest.txt"
else
    echo "  WARN: No manifest found"
fi

# Cleanup
rm -rf "${TEMP_DIR}"
echo ""
echo "Backup verification: PASSED"
```

### Backup health checklist

| Check | Frequency | How |
|-------|-----------|-----|
| Backup runs daily | Daily | Check `/var/log/backup.log` |
| Archives are valid | Weekly | Run `test-restore.sh` |
| Off-site upload succeeds | Weekly | `rclone ls offsite:vps-backups` |
| Full restore works | Monthly | Restore to test environment |
| Retention policy works | Monthly | Verify old backups are deleted |

---

## What's Next?

Your data is protected. In [Chapter 08](../08-ci-cd/), we set up GitHub Actions for automated deployments — push to main, deploy to VPS.

---

[← Chapter 06: Monitoring](../06-monitoring/) | [Chapter 08: CI/CD →](../08-ci-cd/)
