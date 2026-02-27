##############################################################################
# Makefile — Common operations for multi-app VPS deployment
#
# Usage:
#   make help          Show all available commands
#   make status        Show container status
#   make deploy s=app  Deploy a specific service
#   make logs s=app    Tail logs for a service
#   make backup        Run backup
#   make cleanup       Clean unused Docker resources
#
# Prerequisites:
#   - Docker and Docker Compose installed
#   - Running from the project root (/opt/apps)
##############################################################################

.PHONY: help status deploy logs backup cleanup health restart \
        stop start build pull network audit stats

# Default target
help: ## Show this help message
	@echo "VPS Deploy Playbook — Available Commands"
	@echo "========================================="
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Pass service name with s=<name>, e.g.: make deploy s=app-chatbot"

# ── Status & Monitoring ──────────────────────────────────────────────────────

status: ## Show all container status
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort

stats: ## Show resource usage for all containers
	@docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

health: ## Show health status of all containers
	@docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "healthy|unhealthy|starting" || echo "No containers with health checks found"

logs: ## Tail logs for a service (usage: make logs s=app-chatbot)
	@if [ -z "$(s)" ]; then \
		echo "Usage: make logs s=<service-name>"; \
		echo "Available services:"; \
		docker ps --format "  {{.Names}}"; \
	else \
		docker compose logs -f --tail 50 $(s); \
	fi

# ── Deployment ───────────────────────────────────────────────────────────────

deploy: ## Deploy a service (usage: make deploy s=app-chatbot)
	@if [ -z "$(s)" ]; then \
		echo "Usage: make deploy s=<service-name>"; \
		exit 1; \
	fi
	@echo "=== Deploying $(s) ==="
	docker compose build $(s)
	docker compose up -d --no-deps $(s)
	@sleep 3
	@echo "=== Status ==="
	@docker ps --filter name=$(s) --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

deploy-all: ## Rebuild and restart all services
	docker compose build
	docker compose up -d
	@echo "=== All services deployed ==="
	@make status

restart: ## Restart a service (usage: make restart s=app-chatbot)
	@if [ -z "$(s)" ]; then \
		echo "Usage: make restart s=<service-name>"; \
		exit 1; \
	fi
	docker compose restart $(s)
	@echo "$(s) restarted"

stop: ## Stop a service (usage: make stop s=app-chatbot)
	@if [ -z "$(s)" ]; then \
		echo "Usage: make stop s=<service-name>"; \
		exit 1; \
	fi
	docker compose stop $(s)
	@echo "$(s) stopped"

start: ## Start a stopped service (usage: make start s=app-chatbot)
	@if [ -z "$(s)" ]; then \
		echo "Usage: make start s=<service-name>"; \
		exit 1; \
	fi
	docker compose start $(s)
	@echo "$(s) started"

build: ## Build a service image (usage: make build s=app-chatbot)
	@if [ -z "$(s)" ]; then \
		docker compose build; \
	else \
		docker compose build $(s); \
	fi

pull: ## Pull latest images for a service (usage: make pull s=app-chatbot)
	@if [ -z "$(s)" ]; then \
		docker compose pull; \
	else \
		docker compose pull $(s); \
	fi

# ── Infrastructure ───────────────────────────────────────────────────────────

network: ## Create the shared Docker network
	docker network create --driver bridge app-network 2>/dev/null || echo "Network 'app-network' already exists"

nginx-reload: ## Test and reload Nginx config
	@docker exec infra-nginx nginx -t && \
		docker exec infra-nginx nginx -s reload && \
		echo "Nginx reloaded successfully" || \
		echo "Nginx config test FAILED - not reloaded"

nginx-logs: ## Tail Nginx access and error logs
	docker compose logs -f --tail 50 nginx

# ── Maintenance ──────────────────────────────────────────────────────────────

backup: ## Run backup script
	@if [ -f scripts/backup.sh ]; then \
		bash scripts/backup.sh; \
	else \
		echo "backup.sh not found in scripts/"; \
	fi

cleanup: ## Remove unused Docker images and build cache
	@echo "=== Docker disk usage before ==="
	@docker system df
	@echo ""
	docker image prune -f
	docker builder prune -f
	@echo ""
	@echo "=== Docker disk usage after ==="
	@docker system df

cleanup-all: ## Aggressive cleanup (removes ALL unused images)
	@echo "WARNING: This removes all unused images, not just dangling ones."
	@echo "Press Ctrl+C to cancel, or wait 5 seconds..."
	@sleep 5
	docker system prune -a -f
	@docker system df

disk: ## Show disk usage summary
	@echo "=== System Disk ==="
	@df -h / | tail -1
	@echo ""
	@echo "=== Docker Disk ==="
	@docker system df
	@echo ""
	@echo "=== Backup Directory ==="
	@du -sh /opt/backups 2>/dev/null || echo "No backup directory found"

# ── Security ─────────────────────────────────────────────────────────────────

audit: ## Run security audit checks
	@echo "=== Exposed Ports ==="
	@docker ps --format '{{.Names}}\t{{.Ports}}' | grep "0.0.0.0" | sort
	@echo ""
	@echo "=== Privileged Containers ==="
	@docker ps --format '{{.Names}}' | while read name; do \
		PRIV=$$(docker inspect "$$name" --format '{{.HostConfig.Privileged}}' 2>/dev/null); \
		[ "$$PRIV" = "true" ] && echo "  WARNING: $$name is privileged"; \
	done || true
	@echo "(none is good)"
	@echo ""
	@echo "=== SSL Certificates ==="
	@sudo certbot certificates 2>/dev/null | grep -E "Domains:|Expiry" || echo "certbot not installed"
	@echo ""
	@echo "=== Firewall ==="
	@sudo ufw status 2>/dev/null || echo "UFW not installed"
