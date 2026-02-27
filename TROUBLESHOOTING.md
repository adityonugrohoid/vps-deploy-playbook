# Troubleshooting Guide

Quick reference for the most common issues when running multi-container deployments on a VPS. Organized by symptom — find what's broken, get the fix.

---

## Docker Issues

### Container won't start / restarts in a loop

**Symptom:** `docker ps` shows `Restarting (1) 5 seconds ago`

```bash
# Step 1: Check the logs
docker logs container-name --tail 50

# Step 2: Check the exit code
docker inspect container-name --format '{{.State.ExitCode}}'
# Exit 0 = clean exit (check entrypoint/CMD)
# Exit 1 = application error (check logs)
# Exit 137 = OOM killed (increase memory limit)
# Exit 139 = segfault (bad image or binary)

# Step 3: Check resource limits
docker stats --no-stream container-name
```

**Common causes:**
| Exit Code | Cause | Fix |
|-----------|-------|-----|
| 1 | Missing env var | Check `.env` and `docker-compose.yml` |
| 1 | Dependency not ready | Add `depends_on` with `condition: service_healthy` |
| 137 | Out of memory | Increase `deploy.resources.limits.memory` |
| 126 | Permission denied | Check file permissions in container |
| 127 | Command not found | Check `CMD` or `ENTRYPOINT` in Dockerfile |

### Container can't connect to another container

**Symptom:** `Connection refused` or `Could not resolve host`

```bash
# Verify both containers are on the same network
docker network inspect app-network --format '{{range .Containers}}{{.Name}} {{end}}'

# Test DNS resolution from inside a container
docker exec app-a nslookup chromadb
docker exec app-a curl -v http://chromadb:8000

# If DNS fails, check the network configuration
docker inspect app-a --format '{{json .NetworkSettings.Networks}}' | jq
```

**Fix:** Ensure both services have `networks: [app-network]` in `docker-compose.yml`.

### "Port already in use" error

**Symptom:** `Bind for 0.0.0.0:8080 failed: port is already allocated`

```bash
# Find what's using the port
sudo ss -tlnp | grep 8080

# Or find the container using it
docker ps --format "{{.Names}} {{.Ports}}" | grep 8080
```

**Fix:** Change the host port mapping. Remember: internal ports can be the same, only host ports must be unique.

### Docker disk full

**Symptom:** `no space left on device`

```bash
# Check Docker disk usage
docker system df

# Quick cleanup (safe)
docker image prune -f
docker builder prune -f

# Aggressive cleanup (removes all unused images)
docker system prune -a -f

# Check what's eating disk
sudo du -sh /var/lib/docker/*
```

### Image build fails

**Symptom:** Build step fails during `docker compose build`

```bash
# Build with verbose output
docker compose build --no-cache --progress=plain service-name

# Check if it's a network issue (can't pull base image)
docker pull python:3.11-slim

# Check if it's a disk issue
df -h /var/lib/docker
```

---

## Nginx Issues

### 502 Bad Gateway

**Symptom:** Browser shows "502 Bad Gateway"

The most common Nginx error. It means Nginx is running but can't reach the upstream container.

```bash
# Step 1: Is the target container running?
docker ps | grep container-name

# Step 2: Can Nginx reach the container?
docker exec infra-nginx wget -qO- http://container-name:8080/health

# Step 3: Check Nginx error log
docker logs infra-nginx --tail 20
```

**Common causes:**
- Container is down or restarting → start the container
- Wrong port in `proxy_pass` → verify the container's internal port
- Container not on `app-network` → add network to compose config
- App hasn't started yet → add `start_period` to health check

### 504 Gateway Timeout

**Symptom:** Request hangs, then returns 504

```bash
# Increase proxy timeout in nginx.conf
proxy_connect_timeout 60s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;
```

Usually means the backend app is too slow. Check if the app is overloaded:
```bash
docker stats --no-stream container-name
```

### SSL certificate errors

**Symptom:** Browser shows "Your connection is not private"

```bash
# Check certificate expiry
sudo certbot certificates

# Renew if expired
sudo certbot renew

# Test nginx config after renewal
docker exec infra-nginx nginx -t

# Reload nginx
docker exec infra-nginx nginx -s reload
```

### Nginx config syntax error

```bash
# Test config without reloading
docker exec infra-nginx nginx -t

# Common mistakes:
# - Missing semicolon at end of directive
# - Mismatched braces
# - Invalid directive name
# - Duplicate server_name
```

---

## SSH Issues

### "Connection refused" after lockdown

**Symptom:** Can't SSH in after changing `sshd_config`

**Prevention:** Always test in a new terminal before closing your current session.

**Recovery:**
1. Use your VPS provider's web console (KVM/VNC)
2. Login as root (most providers have console access)
3. Fix `/etc/ssh/sshd_config`
4. Restart: `systemctl restart sshd`

### "Permission denied (publickey)"

```bash
# Check key permissions on your local machine
ls -la ~/.ssh/id_ed25519
# Should be: -rw------- (600)

chmod 600 ~/.ssh/id_ed25519

# Check authorized_keys on server
ssh root@server  # via console if needed
cat /home/deploy/.ssh/authorized_keys

# Check SSH daemon allows key auth
grep "PubkeyAuthentication" /etc/ssh/sshd_config
# Should be: PubkeyAuthentication yes
```

---

## Resource Issues

### Server is slow / high load

```bash
# Check what's consuming resources
top -o %MEM   # Sort by memory
top -o %CPU   # Sort by CPU

# Docker-specific resource check
docker stats --no-stream

# Check for runaway processes
ps aux --sort=-%mem | head -20

# Check disk I/O
iostat -x 1 5
```

### OOM Killer striking containers

**Symptom:** Container randomly dies, `dmesg` shows OOM messages

```bash
# Check kernel OOM events
dmesg | grep -i "oom\|out of memory" | tail -10

# See which containers were killed
journalctl -k | grep -i "oom\|killed" | tail -10
```

**Fix:** Set memory limits in docker-compose.yml so Docker handles it before the kernel OOM killer does:

```yaml
deploy:
  resources:
    limits:
      memory: 512M
```

### Swap usage is high

```bash
# Check swap
free -h

# If swap is heavily used, you need more RAM or fewer containers
# Adding swap as emergency buffer:
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make permanent
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## Quick Diagnostic Commands

```bash
# Everything at a glance
docker ps -a                                    # All containers
docker stats --no-stream                        # Resource usage
df -h                                           # Disk space
free -h                                         # Memory
uptime                                          # Load average
docker system df                                # Docker disk usage
docker ps --filter health=unhealthy             # Problem containers
docker logs --tail 50 container-name            # Recent logs
sudo journalctl -u docker --since "1 hour ago" # Docker daemon logs
```
