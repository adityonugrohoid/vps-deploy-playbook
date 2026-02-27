# Architecture Diagrams

Visual reference for the multi-app VPS architecture.

---

## Image Layer Hierarchy

Shows how Docker images are tiered to minimize disk usage and update bandwidth.

```
┌──────────────────────────────────────────────────────────────────┐
│                         python:3.11-slim                         │
│                           (~150MB)                               │
│                    Base OS + Python runtime                       │
└───────────────────────────┬──────────────────────────────────────┘
                            │
                ┌───────────▼───────────────┐
                │      Base Tier Image       │
                │         (~500MB)           │
                │                           │
                │  + fastapi, uvicorn       │
                │  + httpx, pydantic        │
                │  + common utilities       │
                └─────┬─────────────┬───────┘
                      │             │
        ┌─────────────▼──┐   ┌─────▼──────────────────┐
        │                │   │     ML Tier Image        │
        │  App Layers    │   │       (~2.5GB)           │
        │  (~50MB each)  │   │                          │
        │                │   │  + torch (CPU)           │
        │  ┌──────────┐  │   │  + sentence-transformers │
        │  │ app-1    │  │   │  + numpy, scipy          │
        │  ├──────────┤  │   │  + scikit-learn           │
        │  │ app-2    │  │   └─────┬────────────────────┘
        │  ├──────────┤  │         │
        │  │ app-3    │  │   ┌─────▼──────────┐
        │  ├──────────┤  │   │  App Layers    │
        │  │  ...     │  │   │  (~50MB each)  │
        │  ├──────────┤  │   │                │
        │  │ app-15   │  │   │  ┌──────────┐  │
        │  └──────────┘  │   │  │ ml-app-1 │  │
        │                │   │  ├──────────┤  │
        │  15 services   │   │  │ ml-app-2 │  │
        │  Total: ~750MB │   │  ├──────────┤  │
        └────────────────┘   │  │  ...     │  │
                             │  ├──────────┤  │
                             │  │ ml-app-6 │  │
                             │  └──────────┘  │
                             │                │
                             │  6 services    │
                             │  Total: ~300MB │
                             └────────────────┘

  Disk Usage Summary:
  ───────────────────────────────────────────
  Base image (shared):              0.5 GB
  ML image (shared):                2.5 GB
  15 base app layers (50MB each):   0.75 GB
  6 ML app layers (50MB each):      0.30 GB
  ───────────────────────────────────────────
  TOTAL:                           ~4.05 GB
  Without layering:               ~30.0 GB
  Savings:                           ~7x
```

---

## Service Dependency Graph

Shows which services depend on shared infrastructure.

```
                         ┌──────────┐
                         │ Internet │
                         └────┬─────┘
                              │
                         ┌────▼─────┐
                         │  Nginx   │
                         │  :80/443 │
                         └────┬─────┘
                              │
           ┌──────────────────┼──────────────────┐
           │                  │                  │
     ┌─────▼──────┐    ┌─────▼──────┐    ┌─────▼──────┐
     │ Base Tier  │    │ Base Tier  │    │  ML Tier   │
     │  Apps      │    │  Apps      │    │  Apps      │
     │ (×15)      │    │ (w/ Redis) │    │ (×6)       │
     └─────┬──────┘    └──┬────┬───┘    └─────┬──────┘
           │              │    │              │
           │              │    │              │
     ┌─────▼──────────────▼────│──────────────▼──────┐
     │                         │                     │
     │       ChromaDB          │       Ollama        │
     │       :8000             │      :11434         │
     │  (vector storage)       │   (LLM inference)   │
     │                         │                     │
     └─────────────────────────│─────────────────────┘
                               │
                        ┌──────▼──────┐
                        │    Redis    │
                        │    :6379    │
                        │  (cache +   │
                        │   sessions) │
                        └─────────────┘
```

---

## Network Topology

All containers on a single Docker bridge network.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Docker Bridge Network                       │
│                        (app-network)                             │
│                      172.20.0.0/24                               │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ infra-   │  │ svc-     │  │ svc-     │  │ svc-     │        │
│  │ nginx    │  │ chromadb │  │ redis    │  │ ollama   │        │
│  │ .2       │  │ .3       │  │ .4       │  │ .5       │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ app-     │  │ app-     │  │ app-     │  │ app-     │        │
│  │ portfolio│  │ chatbot  │  │ kb       │  │ api-gw   │        │
│  │ .10      │  │ .11      │  │ .12      │  │ .13      │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                      │
│  │ app-     │  │ app-     │  │ app-     │  ... (21 total)       │
│  │ embedder │  │ classify │  │ summary  │                       │
│  │ .20      │  │ .21      │  │ .22      │                       │
│  └──────────┘  └──────────┘  └──────────┘                      │
│                                                                  │
│  Only Nginx exposes ports to the host (80, 443)                  │
│  All inter-container traffic stays on the bridge                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Update Workflow

How selective updates flow through the system.

```
Developer Machine                          VPS
─────────────────                ─────────────────────────

  ┌──────────┐     SSH          ┌──────────────────────┐
  │ deploy.sh│ ──────────────── │ /opt/apps/           │
  │          │  "update app-a"  │                      │
  └──────────┘                  │  docker compose      │
                                │    build app-a       │
                                │         │            │
                                │         ▼            │
                                │  ┌──────────────┐    │
                                │  │ Build app-a  │    │
                                │  │ (only ~50MB  │    │
                                │  │  app layer)  │    │
                                │  └──────┬───────┘    │
                                │         │            │
                                │         ▼            │
                                │  docker compose      │
                                │    up -d app-a       │
                                │         │            │
                                │         ▼            │
                                │  ┌──────────────┐    │
                                │  │ Replace only │    │
                                │  │ app-a        │    │
                                │  │ container    │    │
                                │  └──────────────┘    │
                                │                      │
                                │  Other 20 containers │
                                │  UNTOUCHED           │
                                └──────────────────────┘
```
