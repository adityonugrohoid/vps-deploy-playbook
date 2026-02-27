#!/bin/bash
##############################################################################
# deploy.sh — Selective container deployment via SSH
#
# Usage:
#   ./deploy.sh <service-name> [options]
#   ./deploy.sh <service-1> <service-2> [options]
#
# Options:
#   --build         Build from Dockerfile instead of pulling image
#   --health-check  Run health check after deployment
#   --dry-run       Show what would happen without executing
#
# Examples:
#   ./deploy.sh app-chatbot                     # Pull + restart
#   ./deploy.sh app-chatbot --build             # Build + restart
#   ./deploy.sh app-chatbot app-portfolio       # Deploy multiple
#   ./deploy.sh app-chatbot --build --health-check  # Build + verify
#
# Environment:
#   REMOTE    SSH target (default: deploy@your-vps-ip)
#   APP_DIR   Remote project directory (default: /opt/apps)
##############################################################################

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

REMOTE="${REMOTE:-deploy@your-vps-ip}"
APP_DIR="${APP_DIR:-/opt/apps}"
ROLLBACK_DIR="${APP_DIR}/.rollback"
HEALTH_CHECK_TIMEOUT=30
HEALTH_CHECK_INTERVAL=2

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ── Functions ────────────────────────────────────────────────────────────────

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    echo "Usage: $0 <service-name> [service-name...] [--build] [--health-check] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --build         Build from Dockerfile instead of pulling"
    echo "  --health-check  Verify service health after deployment"
    echo "  --dry-run       Preview commands without executing"
    exit 1
}

# ── Parse Arguments ──────────────────────────────────────────────────────────

SERVICES=()
BUILD=false
HEALTH_CHECK=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            BUILD=true
            shift
            ;;
        --health-check)
            HEALTH_CHECK=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            SERVICES+=("$1")
            shift
            ;;
    esac
done

if [ ${#SERVICES[@]} -eq 0 ]; then
    log_error "No service name provided."
    usage
fi

# ── Deploy Function ──────────────────────────────────────────────────────────

deploy_service() {
    local SERVICE=$1
    local START_TIME=$(date +%s)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Deploying: ${SERVICE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── Step 1: Save rollback snapshot ────────────────────────────────────

    log_info "Saving rollback snapshot..."
    if [ "$DRY_RUN" = false ]; then
        ssh "${REMOTE}" "mkdir -p ${ROLLBACK_DIR} && \
            docker inspect ${SERVICE} --format '{{.Config.Image}}' > ${ROLLBACK_DIR}/${SERVICE}.image 2>/dev/null || echo 'none'" \
            2>/dev/null || true
    else
        echo "  [DRY RUN] ssh ${REMOTE} 'docker inspect ${SERVICE} ...'"
    fi

    # ── Step 2: Build or pull ─────────────────────────────────────────────

    if [ "$BUILD" = true ]; then
        log_info "Building ${SERVICE}..."
        if [ "$DRY_RUN" = false ]; then
            ssh "${REMOTE}" "cd ${APP_DIR} && docker compose build ${SERVICE}"
        else
            echo "  [DRY RUN] ssh ${REMOTE} 'cd ${APP_DIR} && docker compose build ${SERVICE}'"
        fi
    else
        log_info "Pulling latest image for ${SERVICE}..."
        if [ "$DRY_RUN" = false ]; then
            ssh "${REMOTE}" "cd ${APP_DIR} && docker compose pull ${SERVICE}" 2>/dev/null || true
        else
            echo "  [DRY RUN] ssh ${REMOTE} 'cd ${APP_DIR} && docker compose pull ${SERVICE}'"
        fi
    fi

    # ── Step 3: Deploy ────────────────────────────────────────────────────

    log_info "Starting ${SERVICE}..."
    if [ "$DRY_RUN" = false ]; then
        ssh "${REMOTE}" "cd ${APP_DIR} && docker compose up -d --no-deps ${SERVICE}"
    else
        echo "  [DRY RUN] ssh ${REMOTE} 'cd ${APP_DIR} && docker compose up -d --no-deps ${SERVICE}'"
    fi

    # ── Step 4: Health check ──────────────────────────────────────────────

    if [ "$HEALTH_CHECK" = true ] && [ "$DRY_RUN" = false ]; then
        log_info "Running health check (timeout: ${HEALTH_CHECK_TIMEOUT}s)..."
        local ELAPSED=0

        while [ $ELAPSED -lt $HEALTH_CHECK_TIMEOUT ]; do
            STATUS=$(ssh "${REMOTE}" "docker inspect ${SERVICE} --format '{{.State.Status}}'" 2>/dev/null || echo "unknown")

            if [ "$STATUS" = "running" ]; then
                # Check if container has been running for at least 5 seconds (not crash-looping)
                UPTIME=$(ssh "${REMOTE}" "docker inspect ${SERVICE} --format '{{.State.StartedAt}}'" 2>/dev/null || echo "")
                log_ok "${SERVICE} is running (uptime check passed)"
                break
            elif [ "$STATUS" = "restarting" ]; then
                log_warn "${SERVICE} is restarting... waiting"
            fi

            sleep $HEALTH_CHECK_INTERVAL
            ELAPSED=$((ELAPSED + HEALTH_CHECK_INTERVAL))
        done

        if [ $ELAPSED -ge $HEALTH_CHECK_TIMEOUT ]; then
            log_error "Health check failed for ${SERVICE}!"
            log_warn "Attempting rollback..."

            PREV_IMAGE=$(ssh "${REMOTE}" "cat ${ROLLBACK_DIR}/${SERVICE}.image 2>/dev/null || echo 'none'")
            if [ "$PREV_IMAGE" != "none" ]; then
                ssh "${REMOTE}" "cd ${APP_DIR} && docker compose stop ${SERVICE}"
                log_error "Rollback: previous image was ${PREV_IMAGE}"
                log_error "Manual rollback needed. Check logs: docker logs ${SERVICE} --tail 50"
            fi
            return 1
        fi
    fi

    # ── Step 5: Status report ─────────────────────────────────────────────

    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))

    if [ "$DRY_RUN" = false ]; then
        log_info "Container status:"
        ssh "${REMOTE}" "docker ps --filter name=${SERVICE} --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
    fi

    log_ok "${SERVICE} deployed successfully (${DURATION}s)"
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              VPS Deploy Playbook                     ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Target:  ${REMOTE}"
echo "║  Dir:     ${APP_DIR}"
echo "║  Build:   ${BUILD}"
echo "║  Health:  ${HEALTH_CHECK}"
echo "║  Dry Run: ${DRY_RUN}"
echo "║  Services: ${SERVICES[*]}"
echo "╚══════════════════════════════════════════════════════╝"

FAILED=()

for SERVICE in "${SERVICES[@]}"; do
    if ! deploy_service "$SERVICE"; then
        FAILED+=("$SERVICE")
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ${#FAILED[@]} -eq 0 ]; then
    log_ok "All deployments completed successfully!"
else
    log_error "Failed deployments: ${FAILED[*]}"
    exit 1
fi
