# Chapter 03 — Nginx Subdomain Routing

> One Nginx instance, many apps. Route `app-a.example.com` to container A, `app-b.example.com` to container B — all through ports 80 and 443.

---

## Table of Contents

1. [Why Nginx as Reverse Proxy](#1-why-nginx-as-reverse-proxy)
2. [Running Nginx in Docker](#2-running-nginx-in-docker)
3. [Subdomain Routing Pattern](#3-subdomain-routing-pattern)
4. [SSL/TLS with Let's Encrypt](#4-ssltls-with-lets-encrypt)
5. [Adding a New App in 2 Minutes](#5-adding-a-new-app-in-2-minutes)
6. [Rate Limiting](#6-rate-limiting)
7. [Performance Tuning](#7-performance-tuning)

---

## 1. Why Nginx as Reverse Proxy

Without a reverse proxy, you'd need to expose each container on a different port:

```
app-a.example.com:8080
app-b.example.com:8081
app-c.example.com:8082
```

That's ugly, hard to remember, and SSL becomes a nightmare (one cert per port).

With Nginx as a reverse proxy:

```
app-a.example.com  →  Nginx :443  →  container app-a:8080
app-b.example.com  →  Nginx :443  →  container app-b:8080
app-c.example.com  →  Nginx :443  →  container app-c:8080
```

One entry point. One SSL certificate (wildcard). Clean URLs. Nginx handles TLS termination, so your containers don't need to know anything about HTTPS.

---

## 2. Running Nginx in Docker

Nginx runs as a container on the same `app-network` as everything else. See the [docker-compose.yml](./docker-compose.yml) in this directory.

Key points about the Nginx container:

- **Ports 80 and 443** are the only ports exposed to the host. No other container exposes ports.
- **Config is bind-mounted** from the host, so you can edit it without rebuilding the container.
- **Certbot volumes** are shared between Nginx and the certbot container for SSL certificate management.

```yaml
nginx:
  image: nginx:alpine
  container_name: nginx
  restart: unless-stopped
  ports:
    - "80:80"
    - "443:443"
  volumes:
    - ./nginx.conf:/etc/nginx/nginx.conf:ro
    - ./conf.d:/etc/nginx/conf.d:ro
    - /etc/letsencrypt:/etc/letsencrypt:ro
    - /var/www/certbot:/var/www/certbot:ro
  networks:
    - app-network
```

---

## 3. Subdomain Routing Pattern

The core pattern is simple: one `server` block per subdomain, each proxying to a different container.

See the full [nginx.conf](./nginx.conf) for a working example. Here's the anatomy of a single route:

```nginx
server {
    listen 80;
    server_name app-a.example.com;

    # Redirect HTTP to HTTPS
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name app-a.example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    location / {
        proxy_pass http://app-a:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### How `proxy_pass http://app-a:8080` works

Because Nginx is on the same Docker network (`app-network`) as the `app-a` container, Docker's embedded DNS resolves `app-a` to the container's internal IP. No hardcoded IPs. No port mapping to the host.

### The proxy headers — why they matter

| Header | Purpose |
|--------|---------|
| `Host` | Preserves the original hostname so the app knows which domain was requested |
| `X-Real-IP` | Passes the client's real IP (not Nginx's internal IP) |
| `X-Forwarded-For` | Chain of proxies the request has passed through |
| `X-Forwarded-Proto` | Tells the app whether the original request was HTTP or HTTPS |

Without these, your app sees every request coming from `172.20.0.2` (Nginx's container IP) over HTTP. That breaks IP-based rate limiting, logging, and HTTPS redirect loops.

---

## 4. SSL/TLS with Let's Encrypt

### Initial certificate setup

Use certbot in standalone mode for the first certificate, then switch to webroot for renewals.

```bash
# Install certbot
sudo apt install -y certbot

# Get a wildcard certificate (covers *.example.com)
sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d "example.com" \
  -d "*.example.com"
```

For wildcard certs, certbot asks you to add a DNS TXT record. Do it through your DNS provider's dashboard.

### Alternative: per-subdomain certs (easier, no DNS verification)

If you don't want wildcard certs, get individual certs via HTTP challenge:

```bash
# Stop Nginx temporarily (certbot needs port 80)
docker stop nginx

sudo certbot certonly --standalone -d app-a.example.com
sudo certbot certonly --standalone -d app-b.example.com

# Restart Nginx
docker start nginx
```

### Auto-renewal

Certbot installs a systemd timer by default:

```bash
# Verify the timer is active
sudo systemctl list-timers | grep certbot
```

For renewal to work with Nginx running, use the webroot method. Add this to your certbot renewal config:

```bash
# /etc/letsencrypt/renewal/example.com.conf
[renewalparams]
authenticator = webroot
webroot_path = /var/www/certbot

[[ post-renewal-hooks ]]
deploy = docker exec nginx nginx -s reload
```

### SSL configuration best practices

Add these to your `nginx.conf` `http` block:

```nginx
# Modern SSL configuration
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;

# HSTS (tell browsers to always use HTTPS)
add_header Strict-Transport-Security "max-age=63072000" always;

# OCSP stapling (faster SSL handshakes)
ssl_stapling on;
ssl_stapling_verify on;

# SSL session caching
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;
```

---

## 5. Adding a New App in 2 Minutes

When you have a new containerized app to deploy, the process is:

### Step 1: Add the container to docker-compose.yml

```yaml
  app-new:
    build: ./app-new
    container_name: app-new
    restart: unless-stopped
    networks:
      - app-network
```

### Step 2: Add a server block to Nginx config

Copy an existing server block, change the `server_name` and `proxy_pass`:

```nginx
server {
    listen 80;
    server_name app-new.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name app-new.example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    location / {
        proxy_pass http://app-new:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Step 3: Add DNS record

In your DNS provider, add an A record:
```
app-new.example.com  →  YOUR_VPS_IP
```

Or if you have a wildcard DNS record (`*.example.com → YOUR_VPS_IP`), skip this step entirely.

### Step 4: Deploy

```bash
# Start the new container
docker compose up -d app-new

# Test Nginx config and reload
docker exec nginx nginx -t
docker exec nginx nginx -s reload
```

Total time: 2 minutes (plus DNS propagation if you don't have a wildcard record).

---

## 6. Rate Limiting

Protect your apps from abuse and DoS attacks with Nginx rate limiting.

### Basic rate limiting

Add to the `http` block in `nginx.conf`:

```nginx
# Define rate limit zones
# 10 requests per second per IP, with a 10MB zone (handles ~160,000 IPs)
limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;

# Stricter limit for API endpoints
limit_req_zone $binary_remote_addr zone=api:10m rate=5r/s;
```

Apply to specific locations:

```nginx
server {
    # ...

    location / {
        limit_req zone=general burst=20 nodelay;
        proxy_pass http://app-a:8080;
        # ... proxy headers
    }

    location /api/ {
        limit_req zone=api burst=10 nodelay;
        proxy_pass http://app-a:8080;
        # ... proxy headers
    }
}
```

### What `burst` and `nodelay` mean

- **`rate=10r/s`** — Allow 10 requests per second on average.
- **`burst=20`** — Allow bursts of up to 20 requests before rate limiting kicks in.
- **`nodelay`** — Don't queue excess requests; reject them immediately with 503.

Without `burst`, legitimate users get 503 errors on page loads that trigger multiple requests simultaneously (CSS, JS, images).

### Custom error page for rate-limited requests

```nginx
# Return 429 Too Many Requests instead of 503
limit_req_status 429;

error_page 429 /429.html;
location = /429.html {
    internal;
    return 429 '{"error": "Rate limit exceeded. Try again later."}';
    add_header Content-Type application/json;
}
```

---

## 7. Performance Tuning

### Worker processes and connections

```nginx
# Auto-detect CPU cores
worker_processes auto;

events {
    worker_connections 1024;
    multi_accept on;
}
```

### Gzip compression

```nginx
gzip on;
gzip_vary on;
gzip_min_length 256;
gzip_types
    text/plain
    text/css
    text/javascript
    application/javascript
    application/json
    application/xml
    image/svg+xml;
```

### Proxy buffering

For large responses (file uploads, API responses):

```nginx
proxy_buffer_size 128k;
proxy_buffers 4 256k;
proxy_busy_buffers_size 256k;
```

### WebSocket support

If any of your apps use WebSockets:

```nginx
location /ws {
    proxy_pass http://app-a:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
}
```

---

## What's Next?

Nginx is routing traffic to your containers. In [Chapter 04](../04-multi-app-architecture/), we dive into the image layering strategy that keeps 21 containers manageable — the 500MB base tier vs 2.5GB ML tier approach.

---

[← Chapter 02: Docker Foundation](../02-docker-foundation/) | [Chapter 04: Multi-App Architecture →](../04-multi-app-architecture/)
