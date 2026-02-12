#!/usr/bin/env bash
#
# Monlight Upgrade Script
#
# Pulls latest code, rebuilds Docker images, and restarts services
# one at a time with health verification after each restart.
#
# Usage:
#   ./upgrade.sh                     # Upgrade all services
#   ./upgrade.sh error-tracker       # Upgrade a single service
#   ./upgrade.sh log-viewer metrics-collector  # Upgrade specific services
#
# Options:
#   --no-pull       Skip git pull (use current code)
#   --no-backup     Skip pre-upgrade database backup
#   --force         Continue even if a health check fails
#
# Environment variables:
#   COMPOSE_FILE    - Path to docker-compose file (default: ./docker-compose.monitoring.yml)
#   HEALTH_TIMEOUT  - Seconds to wait for health check (default: 60)
#   HEALTH_INTERVAL - Seconds between health check attempts (default: 5)
#
# Rollback procedure:
#   If an upgrade fails, the script prints rollback instructions.
#   To manually rollback a single service:
#
#     1. Rebuild from the previous commit:
#        git checkout <previous-commit-sha>
#        docker compose -f docker-compose.monitoring.yml build <service>
#        docker compose -f docker-compose.monitoring.yml up -d <service>
#
#     2. Or, if images were tagged before the upgrade (this script does this
#        automatically), re-tag and restart:
#        docker tag monlight-<service>:rollback monlight-<service>:latest
#        docker compose -f docker-compose.monitoring.yml up -d <service>
#
#     3. Verify the rollback:
#        docker compose -f docker-compose.monitoring.yml ps <service>
#        curl -sf http://localhost:<port>/health
#
#   Service ports:
#     error-tracker:     5010
#     log-viewer:        5011
#     metrics-collector: 5012
#

set -euo pipefail

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/docker-compose.monitoring.yml}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"

DO_PULL=true
DO_BACKUP=true
FORCE=false

# Service name -> external port mapping
declare -A PORT_MAP=(
    [error-tracker]=5010
    [log-viewer]=5011
    [metrics-collector]=5012
)

ALL_SERVICES=("error-tracker" "log-viewer" "metrics-collector")

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
    log "WARNING: $*" >&2
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

# -------------------------------------------------------------------
# Parse arguments
# -------------------------------------------------------------------

TARGETS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --no-pull)
            DO_PULL=false
            shift
            ;;
        --no-backup)
            DO_BACKUP=false
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            head -46 "$0" | tail -45
            exit 0
            ;;
        -*)
            die "Unknown option: $1. Use --help for usage."
            ;;
        *)
            if [[ -v PORT_MAP[$1] ]]; then
                TARGETS+=("$1")
            else
                die "Unknown service: '$1'. Valid services: ${ALL_SERVICES[*]}"
            fi
            shift
            ;;
    esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    TARGETS=("${ALL_SERVICES[@]}")
fi

# -------------------------------------------------------------------
# Preflight checks
# -------------------------------------------------------------------

command -v docker >/dev/null 2>&1 || die "docker is not installed"
command -v git >/dev/null 2>&1 || die "git is not installed"
[ -f "$COMPOSE_FILE" ] || die "Compose file not found: $COMPOSE_FILE"

# -------------------------------------------------------------------
# Record current state for rollback
# -------------------------------------------------------------------

PREV_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
log "Current commit: ${PREV_COMMIT}"
log "Services to upgrade: ${TARGETS[*]}"

# Tag current images for rollback
for svc in "${TARGETS[@]}"; do
    # The compose project name may vary; use the container name from compose
    image_name="$(docker compose -f "$COMPOSE_FILE" images "$svc" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | head -1 || true)"
    if [ -n "$image_name" ] && [ "$image_name" != ":" ]; then
        repo="$(echo "$image_name" | cut -d: -f1)"
        docker tag "$image_name" "${repo}:rollback" 2>/dev/null && \
            log "Tagged ${image_name} as ${repo}:rollback (for rollback)" || \
            warn "Could not tag current image for ${svc} (service may not have been built yet)"
    else
        warn "No existing image found for ${svc} (first deploy?)"
    fi
done

# -------------------------------------------------------------------
# Pre-upgrade backup
# -------------------------------------------------------------------

if $DO_BACKUP; then
    if [ -x "${SCRIPT_DIR}/backup.sh" ]; then
        log "Running pre-upgrade backup..."
        if "${SCRIPT_DIR}/backup.sh"; then
            log "Pre-upgrade backup completed"
        else
            warn "Pre-upgrade backup failed"
            if ! $FORCE; then
                die "Backup failed. Use --no-backup to skip or --force to continue anyway."
            fi
        fi
    else
        warn "backup.sh not found or not executable, skipping pre-upgrade backup"
    fi
fi

# -------------------------------------------------------------------
# Pull latest code
# -------------------------------------------------------------------

if $DO_PULL; then
    log "Pulling latest code..."
    if git -C "$REPO_ROOT" pull --ff-only; then
        NEW_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
        log "Updated to commit: ${NEW_COMMIT}"
        if [ "$PREV_COMMIT" = "$NEW_COMMIT" ]; then
            log "Already up to date (no new commits)"
        fi
    else
        die "git pull failed. Resolve conflicts manually, then run with --no-pull."
    fi
else
    log "Skipping git pull (--no-pull)"
fi

# -------------------------------------------------------------------
# Health check function
# -------------------------------------------------------------------

wait_for_health() {
    local svc="$1"
    local port="${PORT_MAP[$svc]}"
    local elapsed=0

    log "Waiting for ${svc} to become healthy (port ${port})..."

    while [ $elapsed -lt "$HEALTH_TIMEOUT" ]; do
        if curl -sf "http://localhost:${port}/health" >/dev/null 2>&1; then
            local response
            response="$(curl -sf "http://localhost:${port}/health" 2>/dev/null || echo "{}")"
            log "OK: ${svc} is healthy: ${response}"
            return 0
        fi
        sleep "$HEALTH_INTERVAL"
        elapsed=$((elapsed + HEALTH_INTERVAL))
    done

    warn "${svc} did not become healthy within ${HEALTH_TIMEOUT} seconds"
    return 1
}

# -------------------------------------------------------------------
# Upgrade services one at a time
# -------------------------------------------------------------------

ERRORS=0
UPGRADED=()
FAILED=()

for svc in "${TARGETS[@]}"; do
    log "--- Upgrading ${svc} ---"

    # Build the new image
    log "Building ${svc}..."
    if docker compose -f "$COMPOSE_FILE" build "$svc"; then
        log "Build succeeded for ${svc}"
    else
        warn "Build failed for ${svc}"
        ERRORS=$((ERRORS + 1))
        FAILED+=("$svc")
        if ! $FORCE; then
            die "Build failed for ${svc}. Fix the issue and retry. Previous services upgraded: ${UPGRADED[*]:-none}"
        fi
        continue
    fi

    # Restart the service (recreates the container with the new image)
    log "Restarting ${svc}..."
    if docker compose -f "$COMPOSE_FILE" up -d --no-deps "$svc"; then
        log "Container restarted for ${svc}"
    else
        warn "Failed to restart ${svc}"
        ERRORS=$((ERRORS + 1))
        FAILED+=("$svc")
        if ! $FORCE; then
            die "Restart failed for ${svc}. Container may be in a bad state. Check: docker compose -f $COMPOSE_FILE ps $svc"
        fi
        continue
    fi

    # Wait for the service to become healthy
    if wait_for_health "$svc"; then
        UPGRADED+=("$svc")
        log "OK: ${svc} upgraded successfully"
    else
        ERRORS=$((ERRORS + 1))
        FAILED+=("$svc")

        if ! $FORCE; then
            log ""
            log "=== ROLLBACK INSTRUCTIONS ==="
            log "The ${svc} service failed its health check after upgrade."
            log ""
            log "To rollback ${svc} to the previous version:"
            log "  1. git -C ${REPO_ROOT} checkout ${PREV_COMMIT}"
            log "  2. docker compose -f ${COMPOSE_FILE} build ${svc}"
            log "  3. docker compose -f ${COMPOSE_FILE} up -d --no-deps ${svc}"
            log ""
            log "Or, using the tagged rollback image:"
            log "  docker compose -f ${COMPOSE_FILE} stop ${svc}"
            log "  # Manually re-tag the rollback image and restart"
            log ""
            log "To check logs:"
            log "  docker compose -f ${COMPOSE_FILE} logs --tail=50 ${svc}"
            log "=== END ROLLBACK INSTRUCTIONS ==="
            log ""
            die "Health check failed for ${svc}. See rollback instructions above."
        fi
    fi

    log ""
done

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------

log "=== Upgrade Summary ==="
if [ ${#UPGRADED[@]} -gt 0 ]; then
    log "Upgraded successfully: ${UPGRADED[*]}"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    log "Failed: ${FAILED[*]}"
fi

if [ $ERRORS -gt 0 ]; then
    log ""
    log "=== ROLLBACK INSTRUCTIONS ==="
    log "To rollback all services to the previous version:"
    log "  1. git -C ${REPO_ROOT} checkout ${PREV_COMMIT}"
    log "  2. docker compose -f ${COMPOSE_FILE} build"
    log "  3. docker compose -f ${COMPOSE_FILE} up -d"
    log ""
    log "To rollback a single service:"
    log "  1. git -C ${REPO_ROOT} checkout ${PREV_COMMIT}"
    log "  2. docker compose -f ${COMPOSE_FILE} build <service>"
    log "  3. docker compose -f ${COMPOSE_FILE} up -d --no-deps <service>"
    log ""
    log "To check service health:"
    for svc in "${ALL_SERVICES[@]}"; do
        log "  curl -sf http://localhost:${PORT_MAP[$svc]}/health"
    done
    log "=== END ROLLBACK INSTRUCTIONS ==="
    log ""
    log "Upgrade completed with ${ERRORS} error(s)"
    exit 1
else
    log "All services upgraded successfully"
    exit 0
fi
