# Environment Variables Reference

Quick reference for all environment variables used across the playbook.

## Required Variables

| Variable | Used By | Example | Description |
|----------|---------|---------|-------------|
| `CHROMADB_HOST` | All apps with RAG | `chromadb` | ChromaDB container hostname |
| `CHROMADB_PORT` | All apps with RAG | `8000` | ChromaDB API port |
| `DOMAIN` | Nginx, Certbot | `example.com` | Base domain for subdomain routing |

## Optional Variables

| Variable | Used By | Default | Description |
|----------|---------|---------|-------------|
| `REDIS_HOST` | Apps with caching | `redis` | Redis container hostname |
| `REDIS_PORT` | Apps with caching | `6379` | Redis port |
| `OLLAMA_HOST` | ML tier apps | `ollama` | Ollama container hostname |
| `OLLAMA_PORT` | ML tier apps | `11434` | Ollama API port |
| `OLLAMA_MODEL` | ML tier apps | `llama3.2` | Default LLM model |
| `BACKUP_DIR` | backup.sh | `/opt/backups` | Local backup directory |
| `RETENTION_DAYS` | backup.sh | `7` | Days to keep local backups |

## Secrets (Never Commit)

| Variable | Description |
|----------|-------------|
| `OPENAI_API_KEY` | OpenAI API key (if using OpenAI) |
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `DISCORD_WEBHOOK_URL` | Discord webhook for alerts |
| `TELEGRAM_BOT_TOKEN` | Telegram bot for alerts |
| `REDIS_PASSWORD` | Redis auth password |

## Usage in Docker Compose

```yaml
services:
  app-chatbot:
    env_file: .env
    environment:
      # Override or add to .env values
      - CHROMADB_HOST=${CHROMADB_HOST}
      - EXTRA_VAR=specific-to-this-service
```

## Per-Environment Overrides

```bash
# Development
cp .env.example .env
# Edit with dev values

# Production (on VPS)
cp .env.example .env
# Edit with production values, real API keys
```
