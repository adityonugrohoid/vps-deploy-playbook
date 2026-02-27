# Chapter 04 — Multi-App Architecture Patterns

> The crown jewel. How to run 21+ containerized apps on a single VPS without losing your mind or your disk space.

This chapter covers the architectural decisions that make a large container deployment sustainable: image layering, shared services, resource management, and organizational patterns.

---

## Table of Contents

1. [The Image Layering Strategy](#1-the-image-layering-strategy)
2. [Shared Services Pattern](#2-shared-services-pattern)
3. [Container Organization](#3-container-organization)
4. [Resource Limits & Allocation](#4-resource-limits--allocation)
5. [The Full Stack Compose Pattern](#5-the-full-stack-compose-pattern)
6. [Scaling Decisions](#6-scaling-decisions)

---

## 1. The Image Layering Strategy

This is the single most impactful decision for running many containers efficiently.

### The problem

You have 21 services. If each builds from `python:3.11-slim` and installs its own dependencies, you get:

```
21 images × ~800MB average = 16.8GB on disk
21 images × ~800MB to pull on updates = hours of downtime
```

### The solution: tiered base images

Build two base images that most services inherit from:

```
┌─────────────────────────────────────────────────────────────┐
│                    Base Tier (~500MB)                        │
│                                                             │
│  python:3.11-slim                                           │
│  + httpx, pydantic, uvicorn, fastapi                        │
│  + common utilities (jq, curl, ca-certificates)             │
│                                                             │
│  Used by: 15 services                                       │
│  Total disk: 500MB (shared layers)                          │
├─────────────────────────────────────────────────────────────┤
│                    ML Tier (~2.5GB)                          │
│                                                             │
│  Inherits from Base Tier                                    │
│  + torch, sentence-transformers                             │
│  + numpy, scipy, scikit-learn                               │
│                                                             │
│  Used by: 6 services                                        │
│  Total disk: 2.5GB (shared layers)                          │
└─────────────────────────────────────────────────────────────┘
```

### The math

**Without layering:**
```
15 base services × 800MB  = 12.0GB
 6 ML services   × 3.0GB  = 18.0GB
Total: 30.0GB
```

**With layering:**
```
Base image (shared):        0.5GB
ML image (shared):          2.5GB (includes base)
15 base app layers:  15 × ~50MB = 0.75GB  (only app-specific code)
 6 ML app layers:    6 × ~50MB  = 0.30GB  (only app-specific code)
Total: ~4.05GB
```

**That's a 7x reduction in disk usage.**

### Building the base images

```dockerfile
# Dockerfile.base — Base Tier
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.base.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.base.txt

# requirements.base.txt:
# fastapi==0.109.0
# uvicorn[standard]==0.27.0
# httpx==0.27.0
# pydantic==2.6.0
# pydantic-settings==2.1.0
# python-dotenv==1.0.0
```

```dockerfile
# Dockerfile.ml — ML Tier (inherits from base)
FROM myregistry/base:latest

COPY requirements.ml.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.ml.txt

# requirements.ml.txt:
# torch==2.2.0 --index-url https://download.pytorch.org/whl/cpu
# sentence-transformers==2.3.0
# numpy==1.26.0
# scipy==1.12.0
# scikit-learn==1.4.0
```

```dockerfile
# Dockerfile for an individual app (e.g., app-a)
FROM myregistry/base:latest

WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

### Update bandwidth savings

When you update one app, Docker only pulls the changed layers. Since the base and ML layers rarely change, a typical update pulls ~50MB instead of ~800MB:

```
15 base services updated: 15 × 50MB = 750MB  (vs 12GB without layering)
 6 ML services updated:    6 × 50MB = 300MB  (vs 18GB without layering)
Total bandwidth: ~1GB vs ~30GB — a 30x reduction
```

### When to rebuild base images

- **Monthly:** Security patches to the Python base image
- **When adding new shared dependencies:** Add to `requirements.base.txt`, rebuild, then rebuild all downstream apps
- **Never for app-specific changes:** Only the app layer gets rebuilt

---

## 2. Shared Services Pattern

### ChromaDB as a shared resource

Instead of running a vector database per app, run one ChromaDB instance that all apps connect to:

```
┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐
│ App 1  │  │ App 2  │  │ App 3  │  │ App 4  │
└───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘
    │           │           │           │
    └───────────┴─────┬─────┴───────────┘
                      │
               ┌──────▼──────┐
               │   ChromaDB   │
               │  :8000       │
               │              │
               │  Collections:│
               │  - app1_docs │
               │  - app2_docs │
               │  - app3_kb   │
               │  - app4_emb  │
               └──────────────┘
```

### Why shared is better

| Factor | 1 Shared Instance | 1 Per App (21 instances) |
|--------|-------------------|--------------------------|
| **Memory** | ~512MB | ~10.7GB |
| **Disk** | ~2GB (all collections) | ~2GB × 21 = ~42GB |
| **Backups** | 1 backup job | 21 backup jobs |
| **Monitoring** | 1 health check | 21 health checks |
| **Updates** | Update once | Update 21 times |

### Isolation via collections

Apps don't share data — they use separate ChromaDB collections. Each app only accesses its own collection(s):

```python
# In app-a
import chromadb

client = chromadb.HttpClient(host="chromadb", port=8000)
collection = client.get_or_create_collection("app_a_documents")
```

```python
# In app-b (same ChromaDB, different collection)
client = chromadb.HttpClient(host="chromadb", port=8000)
collection = client.get_or_create_collection("app_b_knowledge_base")
```

### The trade-off: single point of failure

If ChromaDB goes down, all apps that depend on it are affected. Mitigations:

1. **Health checks with auto-restart:**
```yaml
chromadb:
  image: chromadb/chroma:latest
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8000/api/v1/heartbeat"]
    interval: 30s
    timeout: 10s
    retries: 5
    start_period: 30s
```

2. **Graceful degradation:** Apps should handle ChromaDB being temporarily unavailable. Queue requests, retry with backoff, or serve cached results.

3. **Regular backups:** Bind-mount the data directory and back it up daily (covered in a future chapter).

### Other shareable services

The same pattern applies to:
- **Redis** — Session storage, caching, rate limiting across apps
- **PostgreSQL** — Shared database with per-app schemas
- **Ollama** — Shared LLM inference server (expensive to run multiple instances)

---

## 3. Container Organization

### Naming conventions

With 21 containers, naming matters. Use a consistent scheme:

```
{category}-{name}

Examples:
  app-portfolio          # Web applications
  app-chatbot
  app-knowledge-base
  svc-chromadb           # Shared services
  svc-redis
  svc-ollama
  infra-nginx            # Infrastructure
  infra-certbot
  tool-backup            # Utility containers
  tool-healthcheck
```

### Directory structure

```
/opt/apps/
├── docker-compose.yml          # Main compose (all services)
├── docker-compose.override.yml # Local development overrides
├── .env                        # Environment variables
├── .env.example                # Template for .env
│
├── images/                     # Base images
│   ├── base/
│   │   ├── Dockerfile
│   │   └── requirements.base.txt
│   └── ml/
│       ├── Dockerfile
│       └── requirements.ml.txt
│
├── apps/                       # Application code
│   ├── portfolio/
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── src/
│   ├── chatbot/
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── src/
│   └── ...
│
├── services/                   # Shared services config
│   ├── chromadb/
│   │   └── data/              # Persistent data
│   ├── redis/
│   │   └── redis.conf
│   └── ollama/
│       └── models/            # Persistent models
│
├── nginx/                      # Nginx configuration
│   ├── nginx.conf
│   └── conf.d/
│
└── scripts/                    # Deployment & maintenance
    ├── deploy.sh
    ├── backup.sh
    └── healthcheck.sh
```

---

## 4. Resource Limits & Allocation

### Why resource limits matter

Without limits, one runaway container can consume all CPU and memory, bringing down everything else. On a VPS with limited resources, this is catastrophic.

### Setting limits in Compose

```yaml
services:
  app-chatbot:
    deploy:
      resources:
        limits:
          cpus: "1.0"       # Max 1 CPU core
          memory: 512M      # Max 512MB RAM
        reservations:
          cpus: "0.25"      # Guaranteed 0.25 cores
          memory: 256M      # Guaranteed 256MB RAM
```

### Allocation strategy for a 4-core, 16GB VPS

```
┌──────────────────────────────────────────────────────────┐
│                    Memory Allocation                      │
├──────────────────────────────┬────────────┬───────────────┤
│ Category                     │ Per Unit   │ Total         │
├──────────────────────────────┼────────────┼───────────────┤
│ OS + Docker overhead         │     —      │ 1.5GB         │
│ Nginx                        │   128MB    │ 0.13GB        │
│ ChromaDB                     │   1GB      │ 1GB           │
│ Redis                        │   256MB    │ 0.25GB        │
│ Ollama (when active)         │   4GB      │ 4GB           │
│ Base tier apps (×15)         │   384MB    │ 5.6GB         │
│ ML tier apps (×6)            │   512MB    │ 3GB           │
│ Buffer                       │     —      │ 0.5GB         │
├──────────────────────────────┼────────────┼───────────────┤
│ Total                        │            │ ~16GB         │
└──────────────────────────────┴────────────┴───────────────┘
```

### CPU allocation tips

- **Don't over-allocate CPUs.** If you have 4 cores and give each of 21 containers 1 core, the math doesn't work. Use reservations (guarantees) sparingly and limits generously.
- **ML services are CPU-hungry but bursty.** Give them high limits but low reservations. They spike during inference but idle otherwise.
- **Nginx is lightweight.** 0.5 CPU limit is plenty for thousands of requests per second.

### Monitoring resource usage

```bash
# Real-time resource usage
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

# Sort by memory usage
docker stats --no-stream --format "{{.Name}}\t{{.MemUsage}}" | sort -k2 -h
```

---

## 5. The Full Stack Compose Pattern

See the [docker-compose.yml](./docker-compose.yml) for the complete template showing how 21+ services are organized in a single compose file.

### Key patterns in the full compose:

**Service grouping with comments:** Group related services with clear headers:

```yaml
services:
  # ── Infrastructure ─────────────────────
  nginx: ...
  certbot: ...

  # ── Shared Services ────────────────────
  chromadb: ...
  redis: ...
  ollama: ...

  # ── Base Tier Apps ─────────────────────
  app-portfolio: ...
  app-chatbot: ...

  # ── ML Tier Apps ───────────────────────
  app-embedder: ...
  app-classifier: ...
```

**Dependency ordering with `depends_on`:**

```yaml
app-chatbot:
  depends_on:
    chromadb:
      condition: service_healthy
    redis:
      condition: service_started
```

This ensures ChromaDB is healthy before the chatbot starts. Use `service_healthy` for critical dependencies (requires a healthcheck), `service_started` for nice-to-haves.

**Profiles for optional services:**

```yaml
# Only start these when explicitly requested
ollama:
  profiles: ["ml"]

# Start normally: docker compose up -d
# Start with ML: docker compose --profile ml up -d
```

---

## 6. Scaling Decisions

### When to add a second VPS

You don't need to — until you do. Signs it's time:

| Signal | Threshold | Action |
|--------|-----------|--------|
| CPU consistently >80% | During peak hours for 1+ week | Move CPU-heavy services |
| Memory consistently >90% | Can't add more services | Split base/ML tiers across VPS |
| Disk >80% | After pruning images | Add storage or second VPS |
| One service needs >4GB RAM | Ollama with large models | Dedicated ML VPS |

### How to split across VPS (when the time comes)

```
VPS 1 (General — 4 core, 16GB)        VPS 2 (ML — 8 core, 32GB)
├── Nginx                              ├── Ollama
├── ChromaDB                           ├── ML Tier Apps
├── Redis                              └── GPU-accelerated services
├── Base Tier Apps
└── All web traffic
```

Connect them with WireGuard for a private network between VPS instances. But that's a topic for a future chapter.

### The golden rule

**Start with one VPS. Add complexity only when metrics demand it.** Most side projects and small businesses will never outgrow a single well-configured VPS.

---

## What's Next?

You have the architecture. In [Chapter 05](../05-selective-updates/), we build the deployment scripts that let you update one container without touching the other twenty.

---

[← Chapter 03: Nginx Routing](../03-nginx-routing/) | [Chapter 05: Selective Updates →](../05-selective-updates/)
