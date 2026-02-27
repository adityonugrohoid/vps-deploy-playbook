# Chapter 08 — CI/CD with GitHub Actions

> Push to main, deploy to VPS. Automate the boring parts without overcomplicating the simple parts.

You've been deploying with SSH and `deploy.sh`. That works great for manual operations. But when you want "merge PR → auto-deploy," GitHub Actions bridges the gap without requiring Jenkins, ArgoCD, or any external CI/CD platform.

---

## Table of Contents

1. [When You Need CI/CD (and When You Don't)](#1-when-you-need-cicd-and-when-you-dont)
2. [SSH Deploy Workflow](#2-ssh-deploy-workflow)
3. [Build and Push to Registry](#3-build-and-push-to-registry)
4. [Multi-Service Deployment](#4-multi-service-deployment)
5. [Secrets Management](#5-secrets-management)
6. [Workflow Patterns](#6-workflow-patterns)
7. [Rollback via GitHub Actions](#7-rollback-via-github-actions)

---

## 1. When You Need CI/CD (and When You Don't)

### You DON'T need CI/CD when:

- You deploy once a week or less
- You're the only developer
- SSH + `deploy.sh` is fast enough
- You enjoy the control of manual deployment

### You DO need CI/CD when:

- Multiple people push code
- You want automatic deployment after PR merge
- You need automated testing before deploy
- You want a deployment audit trail (who deployed what, when)

### The sweet spot for solo operators

A single GitHub Actions workflow that:
1. Runs on push to `main`
2. SSHs into your VPS
3. Pulls the latest code
4. Rebuilds and restarts the changed service

That's it. No Docker registries, no Kubernetes, no ArgoCD.

---

## 2. SSH Deploy Workflow

The simplest and most practical workflow for single-VPS deployments.

### Setup GitHub Secrets

In your repo → Settings → Secrets → Actions, add:

| Secret | Value |
|--------|-------|
| `VPS_HOST` | Your server IP |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Private key content (from `~/.ssh/id_ed25519`) |
| `VPS_PORT` | `22` (or custom SSH port) |

### The workflow

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to VPS

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      service:
        description: 'Service to deploy (leave empty for auto-detect)'
        required: false
        type: string

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          fetch-depth: 2  # Need previous commit for diff

      - name: Detect changed services
        id: changes
        run: |
          if [ -n "${{ github.event.inputs.service }}" ]; then
            echo "services=${{ github.event.inputs.service }}" >> $GITHUB_OUTPUT
          else
            # Auto-detect which app directories changed
            CHANGED=$(git diff --name-only HEAD~1 HEAD | grep "^apps/" | cut -d'/' -f2 | sort -u | tr '\n' ' ')
            echo "services=${CHANGED}" >> $GITHUB_OUTPUT
          fi
          echo "Deploying: ${CHANGED:-${{ github.event.inputs.service }}}"

      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER }}
          key: ${{ secrets.VPS_SSH_KEY }}
          port: ${{ secrets.VPS_PORT }}
          script: |
            cd /opt/apps
            git pull origin main

            SERVICES="${{ steps.changes.outputs.services }}"

            if [ -z "$SERVICES" ]; then
              echo "No app changes detected. Skipping deploy."
              exit 0
            fi

            for SERVICE in $SERVICES; do
              echo "=== Deploying $SERVICE ==="
              docker compose build "$SERVICE"
              docker compose up -d --no-deps "$SERVICE"
              echo "=== $SERVICE deployed ==="
            done

            # Verify all services are healthy
            sleep 10
            docker ps --format "table {{.Names}}\t{{.Status}}" | head -25

      - name: Notify on failure
        if: failure()
        run: |
          echo "::error::Deployment failed! Check the logs above."
```

### How it works

1. **Push to main** → workflow triggers
2. **Detect changes** → compares files changed in the last commit, extracts app names
3. **SSH to VPS** → pulls code, builds and restarts only changed services
4. **Manual trigger** → use `workflow_dispatch` to deploy a specific service on demand

---

## 3. Build and Push to Registry

For teams or when you want image versioning, build on GitHub Actions and push to a registry.

### Using GitHub Container Registry (GHCR)

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_PREFIX: ghcr.io/${{ github.repository_owner }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    strategy:
      matrix:
        service: [app-chatbot, app-portfolio, app-api-gateway]

    steps:
      - uses: actions/checkout@v4

      - name: Check if service changed
        id: filter
        run: |
          CHANGED=$(git diff --name-only HEAD~1 HEAD | grep "^apps/${{ matrix.service }}/" | wc -l)
          echo "changed=${CHANGED}" >> $GITHUB_OUTPUT

      - name: Log in to GHCR
        if: steps.filter.outputs.changed != '0'
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        if: steps.filter.outputs.changed != '0'
        uses: docker/build-push-action@v5
        with:
          context: ./apps/${{ matrix.service }}
          push: true
          tags: |
            ${{ env.IMAGE_PREFIX }}/${{ matrix.service }}:latest
            ${{ env.IMAGE_PREFIX }}/${{ matrix.service }}:${{ github.sha }}

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER }}
          key: ${{ secrets.VPS_SSH_KEY }}
          script: |
            cd /opt/apps
            docker compose pull
            docker compose up -d
```

### Why GHCR over Docker Hub

- **Free for public repos** — unlimited pulls
- **Integrated** — same auth as GitHub, no extra accounts
- **Versioned** — every image tagged with git SHA for rollback

---

## 4. Multi-Service Deployment

### Deploy only what changed

The key insight: don't redeploy all 21 services when only one changed.

```yaml
      - name: Detect changed services
        id: detect
        run: |
          SERVICES=""
          CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD)

          # Check each app directory
          for DIR in apps/*/; do
            APP=$(basename "$DIR")
            if echo "$CHANGED_FILES" | grep -q "^apps/${APP}/"; then
              SERVICES="${SERVICES} ${APP}"
            fi
          done

          # Check shared configs
          if echo "$CHANGED_FILES" | grep -q "^docker-compose.yml\|^\.env"; then
            SERVICES="ALL"
          fi

          # Check nginx
          if echo "$CHANGED_FILES" | grep -q "^nginx/"; then
            SERVICES="${SERVICES} nginx-reload"
          fi

          echo "services=${SERVICES}" >> $GITHUB_OUTPUT
```

### Nginx config changes

When only Nginx config changes, don't restart — just reload:

```yaml
      - name: Reload Nginx if config changed
        if: contains(steps.detect.outputs.services, 'nginx-reload')
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER }}
          key: ${{ secrets.VPS_SSH_KEY }}
          script: |
            cd /opt/apps
            git pull origin main
            docker exec infra-nginx nginx -t && docker exec infra-nginx nginx -s reload
```

---

## 5. Secrets Management

### GitHub Secrets best practices

```
VPS_HOST          → Server IP (never commit this)
VPS_USER          → deploy
VPS_SSH_KEY       → Full private key content
VPS_PORT          → 22

# App-specific secrets (if needed)
CHROMADB_API_KEY  → For authenticated ChromaDB
OPENAI_API_KEY    → If any app uses OpenAI
DISCORD_WEBHOOK   → For deployment notifications
```

### Generating a deploy-only SSH key

Don't use your personal SSH key. Create a dedicated deploy key:

```bash
# On your local machine
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/deploy_key

# Add the PUBLIC key to your VPS
ssh-copy-id -i ~/.ssh/deploy_key.pub deploy@YOUR_VPS_IP

# Add the PRIVATE key content to GitHub Secrets as VPS_SSH_KEY
cat ~/.ssh/deploy_key
```

### Restricting the deploy key

On your VPS, limit what the deploy key can do:

```bash
# In ~deploy/.ssh/authorized_keys, prefix the key with restrictions:
command="/opt/apps/scripts/deploy-allowed.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...
```

```bash
#!/bin/bash
# /opt/apps/scripts/deploy-allowed.sh
# Only allow specific commands from the deploy key

case "$SSH_ORIGINAL_COMMAND" in
    "cd /opt/apps"*)
        eval "$SSH_ORIGINAL_COMMAND"
        ;;
    *)
        echo "Command not allowed: $SSH_ORIGINAL_COMMAND"
        exit 1
        ;;
esac
```

---

## 6. Workflow Patterns

### Pattern: Deploy with approval

For production services, require manual approval:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... build steps

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment: production  # Requires approval in GitHub settings
    steps:
      # ... deploy steps
```

Configure in repo → Settings → Environments → production → Required reviewers.

### Pattern: Deploy notification

```yaml
      - name: Notify Discord
        if: always()
        run: |
          STATUS="${{ job.status }}"
          COLOR=$([[ "$STATUS" == "success" ]] && echo "3066993" || echo "15158332")

          curl -H "Content-Type: application/json" \
            -d "{\"embeds\": [{
              \"title\": \"Deployment ${STATUS}\",
              \"description\": \"Services: ${{ steps.changes.outputs.services }}\nCommit: ${{ github.sha }}\",
              \"color\": ${COLOR}
            }]}" \
            ${{ secrets.DISCORD_WEBHOOK }}
```

### Pattern: Scheduled health check

```yaml
name: Health Check

on:
  schedule:
    - cron: '*/15 * * * *'  # Every 15 minutes

jobs:
  health:
    runs-on: ubuntu-latest
    steps:
      - name: Check services
        run: |
          for URL in \
            "https://app-a.example.com/health" \
            "https://app-b.example.com/health" \
            "https://api.example.com/health"; do
            STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "$URL" || echo "000")
            if [ "$STATUS" != "200" ]; then
              echo "::error::${URL} returned ${STATUS}"
            fi
          done
```

---

## 7. Rollback via GitHub Actions

### Manual rollback workflow

```yaml
name: Rollback

on:
  workflow_dispatch:
    inputs:
      service:
        description: 'Service to rollback'
        required: true
        type: string
      commit:
        description: 'Git commit SHA to rollback to'
        required: true
        type: string

jobs:
  rollback:
    runs-on: ubuntu-latest
    steps:
      - name: Rollback via SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER }}
          key: ${{ secrets.VPS_SSH_KEY }}
          script: |
            cd /opt/apps
            git fetch origin
            git checkout ${{ github.event.inputs.commit }} -- apps/${{ github.event.inputs.service }}/
            docker compose build ${{ github.event.inputs.service }}
            docker compose up -d --no-deps ${{ github.event.inputs.service }}
            echo "Rolled back ${{ github.event.inputs.service }} to ${{ github.event.inputs.commit }}"
```

Trigger from GitHub → Actions → Rollback → Run workflow. Enter the service name and the commit SHA you want to revert to.

---

## Summary: The CI/CD Stack

```
┌──────────────────────────────────────────────────┐
│              GitHub Actions CI/CD                 │
├──────────────────────────────────────────────────┤
│                                                   │
│  Push to main                                     │
│  └─ Detect changed services                       │
│  └─ SSH to VPS                                    │
│  └─ Pull, build, restart (only changed)           │
│  └─ Notify via Discord/Telegram                   │
│                                                   │
│  Manual deploy (workflow_dispatch)                │
│  └─ Deploy specific service on demand             │
│                                                   │
│  Rollback (workflow_dispatch)                     │
│  └─ Revert specific service to a commit           │
│                                                   │
│  Health check (scheduled, every 15 min)           │
│  └─ Curl all service health endpoints             │
│                                                   │
│  Cost: $0 (2,000 free minutes/month)              │
│  Complexity: 1 YAML file                          │
│  Setup time: ~20 minutes                          │
│                                                   │
└──────────────────────────────────────────────────┘
```

---

[← Chapter 07: Automated Backups](../07-automated-backups/) | [Back to Playbook →](../README.md)
