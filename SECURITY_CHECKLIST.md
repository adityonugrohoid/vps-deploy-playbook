# Security Hardening Checklist

A standalone reference for securing your VPS and Docker deployment. Use this as a pre-launch checklist or periodic security audit.

---

## Server Level

### SSH

- [ ] Root login disabled (`PermitRootLogin no`)
- [ ] Password authentication disabled (`PasswordAuthentication no`)
- [ ] SSH key is Ed25519 (not RSA)
- [ ] SSH key has a passphrase
- [ ] MaxAuthTries set to 3
- [ ] X11Forwarding disabled
- [ ] Only one non-root user has SSH access
- [ ] Idle timeout configured (`ClientAliveInterval 300`)

```bash
# Verify SSH config
sudo sshd -T | grep -E "permitrootlogin|passwordauthentication|maxauthtries|x11forwarding"
```

### Firewall

- [ ] UFW enabled
- [ ] Default deny incoming
- [ ] Only ports 22, 80, 443 open
- [ ] No database ports exposed (5432, 6379, 27017, etc.)
- [ ] No Docker ports exposed directly

```bash
# Verify firewall
sudo ufw status verbose
```

### System

- [ ] Automatic security updates enabled (`unattended-upgrades`)
- [ ] Fail2Ban running and configured
- [ ] System timezone set to UTC
- [ ] Non-root deploy user created
- [ ] Kernel and packages up to date

```bash
# Check for pending updates
sudo apt update && apt list --upgradable
# Check fail2ban
sudo fail2ban-client status
```

---

## Docker Level

### Daemon

- [ ] Docker runs as non-root group (user in `docker` group)
- [ ] Log rotation configured in `/etc/docker/daemon.json`
- [ ] Default address pool configured (avoid subnet conflicts)
- [ ] Docker socket not exposed to containers

```bash
# Verify daemon config
cat /etc/docker/daemon.json
```

### Images

- [ ] Base images use specific tags (not `latest` in production)
- [ ] Images built from official base images
- [ ] No secrets baked into images
- [ ] Images scanned for vulnerabilities

```bash
# Scan an image (requires Docker Scout or Trivy)
docker scout cves image-name:tag
# Or with Trivy
trivy image image-name:tag
```

### Containers

- [ ] Containers run as non-root user where possible
- [ ] Resource limits set (CPU + memory)
- [ ] Read-only filesystem where possible (`:ro` mounts)
- [ ] No `--privileged` flag used
- [ ] No `--net=host` used
- [ ] Health checks defined for all services
- [ ] `restart: unless-stopped` policy set

```bash
# Check for privileged containers
docker ps --format '{{.Names}}' | while read name; do
  PRIV=$(docker inspect "$name" --format '{{.HostConfig.Privileged}}')
  if [ "$PRIV" = "true" ]; then
    echo "WARNING: $name is privileged!"
  fi
done

# Check for containers running as root
docker ps --format '{{.Names}}' | while read name; do
  USER=$(docker inspect "$name" --format '{{.Config.User}}')
  echo "$name: user=${USER:-root}"
done
```

### Networking

- [ ] Only Nginx exposes ports to the host (80, 443)
- [ ] All other containers communicate via internal Docker network
- [ ] No container has `ports` mapping to `0.0.0.0` except Nginx
- [ ] Inter-container traffic uses service names (not IPs)

```bash
# List all port mappings
docker ps --format '{{.Names}}\t{{.Ports}}' | sort
# Only infra-nginx should show 0.0.0.0:80 and 0.0.0.0:443
```

---

## Nginx Level

- [ ] HTTP redirects to HTTPS (`return 301 https://...`)
- [ ] TLS 1.2+ only (no TLS 1.0/1.1)
- [ ] HSTS header set (`Strict-Transport-Security`)
- [ ] X-Frame-Options set (`SAMEORIGIN`)
- [ ] X-Content-Type-Options set (`nosniff`)
- [ ] X-XSS-Protection set
- [ ] Referrer-Policy set
- [ ] Default server block returns 444 (reject unknown hosts)
- [ ] Rate limiting configured
- [ ] Client max body size set (`client_max_body_size`)
- [ ] Server tokens hidden (`server_tokens off`)
- [ ] SSL certificates valid and auto-renewing

```bash
# Test SSL configuration
docker exec infra-nginx nginx -t

# Check certificate expiry
sudo certbot certificates

# Test headers
curl -sI https://your-domain.com | grep -E "Strict|X-Frame|X-Content|X-XSS|Referrer"
```

---

## Application Level

- [ ] API keys and secrets in `.env` (never in code or Dockerfiles)
- [ ] `.env` in `.gitignore`
- [ ] No credentials in `docker-compose.yml`
- [ ] Application health endpoints don't leak sensitive info
- [ ] CORS configured correctly (not `*` in production)
- [ ] Input validation on all user-facing endpoints
- [ ] Error messages don't expose internal details

---

## Secrets & Credentials

- [ ] No secrets in git history (check with `git log --all -p | grep -i "password\|secret\|key"`)
- [ ] SSH keys are per-purpose (separate deploy key for CI/CD)
- [ ] API keys are scoped to minimum required permissions
- [ ] Database passwords are strong and unique
- [ ] Secrets rotated periodically

```bash
# Scan for accidentally committed secrets
# Install trufflehog or gitleaks
gitleaks detect --source . --verbose
```

---

## Backup & Recovery

- [ ] Automated daily backups running
- [ ] Backups stored off-site (not just on the same VPS)
- [ ] Backup restore tested within the last 30 days
- [ ] SSL certificates backed up
- [ ] Docker Compose and `.env` backed up
- [ ] Backup encryption enabled for sensitive data

---

## Monitoring & Alerting

- [ ] Health checks for all critical containers
- [ ] Disk usage alerts (>80%)
- [ ] Container crash alerts
- [ ] SSL certificate expiry alerts
- [ ] Failed SSH login monitoring (Fail2Ban)

---

## Periodic Audit (Monthly)

```bash
#!/bin/bash
# security-audit.sh — Monthly security check

echo "=== Security Audit: $(date) ==="

echo -e "\n--- SSH Config ---"
sudo sshd -T 2>/dev/null | grep -E "permitrootlogin|passwordauthentication|maxauthtries"

echo -e "\n--- Firewall ---"
sudo ufw status

echo -e "\n--- Exposed Ports ---"
docker ps --format '{{.Names}}\t{{.Ports}}' | grep "0.0.0.0"

echo -e "\n--- Privileged Containers ---"
docker ps --format '{{.Names}}' | while read name; do
  PRIV=$(docker inspect "$name" --format '{{.HostConfig.Privileged}}' 2>/dev/null)
  [ "$PRIV" = "true" ] && echo "  WARNING: $name"
done
echo "(none is good)"

echo -e "\n--- SSL Certificates ---"
sudo certbot certificates 2>/dev/null | grep -E "Domains:|Expiry"

echo -e "\n--- System Updates ---"
apt list --upgradable 2>/dev/null | tail -5

echo -e "\n--- Fail2Ban ---"
sudo fail2ban-client status sshd 2>/dev/null | grep -E "Currently|Total"

echo -e "\n=== Audit Complete ==="
```

---

**Reference:** Cross-references [Chapter 01](./01-vps-setup/) (server hardening), [Chapter 03](./03-nginx-routing/) (Nginx security), and [Chapter 06](./06-monitoring/) (monitoring).
