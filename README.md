# 🚀 VPS Deploy Playbook

> Deploy multiple apps on a single VPS with Docker — from zero to production.
> Battle-tested patterns from running 21+ containers in production.

Most Docker tutorials teach you commands. This playbook teaches you **architecture decisions** — the kind you only learn after things break at 3 AM.

## Who This Is For

- Indie hackers deploying multiple side projects on one VPS
- Engineers consolidating microservices without Kubernetes overhead
- Anyone tired of "just use K8s" being the answer to everything

## What You'll Learn

| Chapter | Topic | Key Takeaway |
|---------|-------|--------------|
| [01 - VPS Setup](./01-vps-setup/) | SSH hardening, firewall, initial config | Secure foundation in 15 minutes |
| [02 - Docker Foundation](./02-docker-foundation/) | Install, networking, compose basics | Single network for all containers |
| [03 - Nginx Routing](./03-nginx-routing/) | Subdomain → container routing | One entry point, many apps |
| [04 - Multi-App Architecture](./04-multi-app-architecture/) | Image layering, shared services | 500MB base vs 2.5GB ML tier strategy |
| [05 - Selective Updates](./05-selective-updates/) | Per-app deploy scripts | Update one container, not twenty-one |
| [06 - Monitoring](./06-monitoring/) | Logs, health checks, alerts | Know before your users do |
| [07 - Automated Backups](./07-automated-backups/) | Volume backups, off-site storage | Protect data you can't rebuild |
| [08 - CI/CD](./08-ci-cd/) | GitHub Actions, auto-deploy | Push to main, deploy to VPS |

## Architecture Overview

```
                    ┌─────────────┐
                    │   Internet   │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │    Nginx     │
                    │  (Reverse    │
                    │   Proxy)     │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼────┐ ┌────▼─────┐ ┌────▼─────┐
        │  App A   │ │  App B   │ │  App C   │
        │ (500MB)  │ │ (500MB)  │ │ (2.5GB)  │
        │  base    │ │  base    │ │  ML tier  │
        └─────┬────┘ └────┬─────┘ └────┬─────┘
              │            │            │
              └────────────┼────────────┘
                           │
                    ┌──────▼──────┐
                    │  ChromaDB   │
                    │  (Shared)   │
                    └─────────────┘

        ── All on a single Docker network ──
```

## Philosophy

1. **Shared infrastructure over duplication** — One ChromaDB instance, not twenty-one
2. **Lean base, heavy only where needed** — 500MB base image; ML dependencies only on services that need them
3. **Selective updates over full redeployments** — SSH + targeted `docker compose up -d service-name`
4. **Simple over clever** — If Nginx and Docker Compose solve it, don't reach for K8s

## Quick Start

```bash
# Clone this playbook
git clone https://github.com/adityonugrohoid/vps-deploy-playbook.git
cd vps-deploy-playbook

# Start with Chapter 01
cd 01-vps-setup
```

## About

Built from real production experience running 21+ containerized services on a single VPS. Every recommendation here has been tested under load, debugged at odd hours, and refined over multiple iterations.

**Author:** [Adityo Nugroho](https://github.com/adityonugrohoid) — AI Solutions Engineer with 18+ years in high-throughput network operations.

## Reference Docs

| Document | Description |
|----------|-------------|
| [Troubleshooting](./TROUBLESHOOTING.md) | Common issues and fixes |
| [Security Checklist](./SECURITY_CHECKLIST.md) | Hardening audit reference |
| [FAQ](./FAQ.md) | Frequently asked questions |
| [Environment Variables](./docker-compose.env.md) | All config variables |
| [Makefile](./Makefile) | Common operations (`make deploy s=app`) |

## Contributing

Found a better pattern? See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines. Open a PR or an issue — this playbook improves with community input.

## License

MIT — Use it, fork it, deploy it.
