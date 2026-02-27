# Frequently Asked Questions

---

### Why a single VPS instead of Kubernetes?

Kubernetes solves problems you don't have at this scale. K8s is designed for multi-node clusters, auto-scaling, and teams of operators. For a solo developer running 21 containers on one server, K8s adds:

- ~2GB RAM overhead for the control plane
- Significant learning curve (RBAC, Ingress controllers, PVCs, etc.)
- More failure modes to debug

Docker Compose on a single VPS gives you everything K8s does at this scale: container orchestration, restart policies, networking, and health checks — without the overhead.

**When to switch:** When you need auto-scaling across multiple nodes, or when your team grows beyond 3-4 people deploying independently.

---

### How much does this cost?

A VPS capable of running 21 containers:

| Provider | Spec | Monthly Cost |
|----------|------|-------------|
| Hetzner CX31 | 4 vCPU, 16GB RAM, 160GB SSD | ~$15/mo |
| DigitalOcean | 4 vCPU, 16GB RAM, 320GB SSD | ~$48/mo |
| AWS EC2 t3.xlarge | 4 vCPU, 16GB RAM | ~$120/mo |
| Contabo VPS L | 6 vCPU, 16GB RAM, 400GB SSD | ~$12/mo |

For most side projects and small businesses, $15-50/month covers everything. Compare that to running 21 separate services on Heroku, Render, or Railway.

---

### Can I use this with ARM servers (Raspberry Pi, Oracle Cloud free tier)?

Yes, with caveats:

- All official Docker images used in this playbook have ARM variants (Nginx, Redis, ChromaDB)
- Your custom app images need multi-arch builds or ARM-native builds
- ML tier images (PyTorch, sentence-transformers) may have limited ARM support
- Oracle Cloud's free-tier ARM instances (4 OCPU, 24GB RAM) are excellent for this setup

Add `platform: linux/arm64` to your compose services if building on x86 for ARM deployment.

---

### What if I need more than one VPS?

Start with one VPS. When metrics show you need more (see [Chapter 04, Section 6](./04-multi-app-architecture/#6-scaling-decisions)):

1. **Add a second VPS** for compute-heavy services (Ollama, ML tier apps)
2. **Connect them with WireGuard** for a private network
3. Keep Nginx and lightweight services on VPS 1
4. Route traffic from Nginx to VPS 2 via WireGuard IP

This is simpler than it sounds and avoids the complexity of container orchestration across nodes.

---

### How do I handle database migrations?

For apps with databases (PostgreSQL, SQLite):

1. **Version your migrations** in the app's codebase
2. **Run migrations on deploy**, not on container start:

```bash
# In deploy.sh, after building:
docker compose run --rm app-name python manage.py migrate
docker compose up -d app-name
```

3. **Never run destructive migrations automatically** — review them manually

---

### Should I use Docker Swarm instead of plain Compose?

For a single VPS: no. Docker Swarm's benefits (multi-node orchestration, rolling updates, service discovery) don't add value on one server. Plain Compose is simpler and has better tooling support.

---

### How do I update the base Docker images?

```bash
# 1. Rebuild base images
cd /opt/apps/images/base
docker build -t myregistry/base:latest .

cd /opt/apps/images/ml
docker build -t myregistry/ml:latest .

# 2. Rebuild all app images (they inherit from base/ml)
docker compose build

# 3. Restart services
docker compose up -d
```

Schedule this monthly for security patches. The base image rarely changes, so downstream app rebuilds are fast (~50MB per app).

---

### Can I run Windows containers?

No. This playbook is Linux-only. Windows containers require Windows Server, have different networking, and don't support the Docker Compose patterns used here.

---

### How do I add a new domain (not a subdomain)?

Same as adding a subdomain — Nginx doesn't care if it's `app.example.com` or `otherdomain.com`:

1. Point the new domain's DNS A record to your VPS IP
2. Get an SSL certificate: `sudo certbot certonly --standalone -d otherdomain.com`
3. Add a server block to Nginx config
4. Reload Nginx: `docker exec infra-nginx nginx -s reload`

---

### What about IPv6?

Docker supports IPv6 but it's not enabled by default. For most VPS deployments, IPv4 is sufficient. If you need IPv6:

```json
// /etc/docker/daemon.json
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80"
}
```

Then configure your firewall and Nginx to listen on both protocols.

---

### How do I handle secrets rotation?

1. Update the secret in `.env`
2. Restart only the affected services:

```bash
docker compose up -d --force-recreate app-chatbot app-portfolio
```

`--force-recreate` ensures the container picks up new environment variables even if the image hasn't changed.

---

### Is this production-ready?

Yes — with the caveats that "production" for a solo operator's side projects has different requirements than a Fortune 500 deployment. This playbook gives you:

- SSL encryption
- Firewall protection
- Container isolation
- Health monitoring
- Automated backups
- Selective deployments

What it doesn't give you (and you probably don't need):
- Multi-region failover
- Auto-scaling
- 99.99% SLA infrastructure
- SOC 2 compliance tooling

For 99% of side projects, indie products, and small business apps — this is production-ready.
