# Chapter 01 — VPS Setup & Hardening

> Get a fresh Ubuntu server production-ready in 15 minutes.
> This chapter covers the security baseline every VPS needs before you deploy anything.

**Target OS:** Ubuntu 22.04 / 24.04 LTS

---

## Table of Contents

1. [Initial Access & Non-Root User](#1-initial-access--non-root-user)
2. [SSH Key Setup & Hardening](#2-ssh-key-setup--hardening)
3. [Firewall with UFW](#3-firewall-with-ufw)
4. [Fail2Ban — Brute Force Protection](#4-fail2ban--brute-force-protection)
5. [Timezone & Hostname](#5-timezone--hostname)
6. [Security Checklist](#6-security-checklist)

---

## 1. Initial Access & Non-Root User

Your VPS provider gives you root access. The first thing you do is **stop using root**.

### Connect as root (first and last time)

```bash
ssh root@YOUR_SERVER_IP
```

### Create a deploy user

```bash
adduser deploy
# Set a strong password — you'll disable password login soon anyway

# Give sudo privileges
usermod -aG sudo deploy
```

Why `deploy` and not your name? Convention. When you have scripts SSHing into the server, `deploy@server` reads clearly. Pick whatever you want, but be consistent.

### Verify sudo works

```bash
su - deploy
sudo whoami
# Should print: root
```

### Copy your SSH key to the new user

From your **local machine** (not the server):

```bash
ssh-copy-id deploy@YOUR_SERVER_IP
```

Now verify you can SSH as deploy:

```bash
ssh deploy@YOUR_SERVER_IP
```

If that works, you're ready to lock things down.

---

## 2. SSH Key Setup & Hardening

Password authentication is a liability. Bots will brute-force it 24/7. Disable it.

### Generate an SSH key (if you don't have one)

On your **local machine**:

```bash
ssh-keygen -t ed25519 -C "your@email.com"
# Ed25519 is shorter, faster, and more secure than RSA
# Accept the default path (~/.ssh/id_ed25519)
# Set a passphrase — it protects the key if your laptop is compromised
```

### Harden the SSH daemon

On the **server**, edit the SSH config:

```bash
sudo nano /etc/ssh/sshd_config
```

Change these settings (find each line, uncomment if needed):

```
# Disable root login
PermitRootLogin no

# Disable password authentication
PasswordAuthentication no

# Disable empty passwords
PermitEmptyPasswords no

# Only allow SSH protocol 2
Protocol 2

# Limit authentication attempts
MaxAuthTries 3

# Disable X11 forwarding (you don't need it on a server)
X11Forwarding no

# Set idle timeout (disconnect after 5 min of inactivity)
ClientAliveInterval 300
ClientAliveCountMax 2
```

### Restart SSH

```bash
sudo systemctl restart sshd
```

> **Warning:** Before you close your current SSH session, open a NEW terminal and verify you can still connect as `deploy`. If you locked yourself out, you'll need your VPS provider's console access.

### Test the lockdown

```bash
# This should FAIL:
ssh root@YOUR_SERVER_IP

# This should WORK:
ssh deploy@YOUR_SERVER_IP
```

---

## 3. Firewall with UFW

UFW (Uncomplicated Firewall) is the simplest way to manage iptables on Ubuntu. Default deny everything, then whitelist what you need.

### Install and configure

```bash
# UFW is usually pre-installed on Ubuntu, but just in case
sudo apt update && sudo apt install -y ufw

# Default policies: deny incoming, allow outgoing
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (CRITICAL — do this BEFORE enabling UFW)
sudo ufw allow 22/tcp comment 'SSH'

# Allow HTTP and HTTPS for web traffic
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'

# Enable the firewall
sudo ufw enable
```

### Verify rules

```bash
sudo ufw status verbose
```

Expected output:

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere        # SSH
80/tcp                     ALLOW IN    Anywhere        # HTTP
443/tcp                    ALLOW IN    Anywhere        # HTTPS
```

### What about other ports?

**Don't open them.** Your Docker containers will be accessed through Nginx on ports 80/443. No container needs a direct port exposed to the internet. If you're running something on port 8080 inside Docker, Nginx will proxy to it internally — the internet never sees port 8080.

The only exception: if you're running a non-HTTP service (like a database that remote clients need to connect to). Even then, consider SSH tunneling instead.

### If you use a non-standard SSH port

Some people change SSH from 22 to something like 2222. It's security through obscurity — not real security — but it does reduce log noise from bots:

```bash
# Change SSH port in sshd_config first, then:
sudo ufw delete allow 22/tcp
sudo ufw allow 2222/tcp comment 'SSH (custom port)'
sudo systemctl restart sshd
```

---

## 4. Fail2Ban — Brute Force Protection

Even with password auth disabled, bots will hammer your SSH port. Fail2Ban watches log files and temporarily bans IPs that fail authentication too many times.

### Install

```bash
sudo apt install -y fail2ban
```

### Configure

Don't edit `/etc/fail2ban/jail.conf` — it gets overwritten on updates. Create a local override:

```bash
sudo nano /etc/fail2ban/jail.local
```

```ini
[DEFAULT]
# Ban for 1 hour (3600 seconds)
bantime = 3600

# Time window to count failures
findtime = 600

# Max failures before ban
maxretry = 3

# Email notifications (optional — requires mail setup)
# destemail = your@email.com
# action = %(action_mwl)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
```

### Start and enable

```bash
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

### Check status

```bash
# See active jails
sudo fail2ban-client status

# See SSH jail details (banned IPs, etc.)
sudo fail2ban-client status sshd
```

### Unban an IP (if you accidentally ban yourself)

```bash
sudo fail2ban-client set sshd unbanip YOUR_IP
```

---

## 5. Timezone & Hostname

Small things that matter when you're reading logs at 3 AM and need timestamps to make sense.

### Set timezone

```bash
# List available timezones
timedatectl list-timezones | grep YOUR_REGION

# Set timezone (use UTC for servers — easier for log correlation)
sudo timedatectl set-timezone UTC
```

> **Opinion:** Use UTC for servers, always. When you have users in multiple timezones and your logs say "02:15 AM" — UTC removes ambiguity. Convert to local time in your monitoring dashboards, not on the server.

### Set hostname

```bash
# Set a meaningful hostname
sudo hostnamectl set-hostname vps-prod-01

# Update /etc/hosts to match
sudo nano /etc/hosts
```

Add this line:

```
127.0.1.1   vps-prod-01
```

### Verify

```bash
hostname
# vps-prod-01

timedatectl
# Should show your timezone
```

---

## 6. Security Checklist

Run through this after setup. Every item should be green.

| Check | Command | Expected |
|-------|---------|----------|
| Root login disabled | `grep "PermitRootLogin" /etc/ssh/sshd_config` | `PermitRootLogin no` |
| Password auth disabled | `grep "PasswordAuthentication" /etc/ssh/sshd_config` | `PasswordAuthentication no` |
| UFW active | `sudo ufw status` | `Status: active` |
| Only ports 22, 80, 443 open | `sudo ufw status` | Three rules listed |
| Fail2Ban running | `sudo systemctl status fail2ban` | `active (running)` |
| SSH key works | `ssh deploy@YOUR_SERVER_IP` | Login succeeds |
| Non-root user has sudo | `sudo whoami` | `root` |
| Timezone set | `timedatectl` | UTC (or your chosen tz) |
| System updated | `sudo apt update && sudo apt upgrade -y` | No pending updates |

### Bonus: Automatic security updates

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
# Select "Yes" to enable automatic security updates
```

This ensures critical security patches are applied automatically. You should still do full manual updates periodically, but this catches the urgent ones.

---

## What's Next?

Your server is hardened and ready. In [Chapter 02](../02-docker-foundation/), we install Docker and set up the networking foundation that all your containers will share.

---

**Time to complete:** ~15 minutes for a fresh server.

[← Back to Playbook](../README.md) | [Chapter 02: Docker Foundation →](../02-docker-foundation/)
