#!/usr/bin/env bash
#
# Monlight Database Backup Script
#
# Safely backs up all SQLite databases (errors.db, logs.db, metrics.db)
# using SQLite's .backup command, which creates a consistent snapshot
# even while the databases are in use (WAL mode safe).
#
# Retains the last 7 daily backups per database and deletes older ones.
#
# Usage:
#   ./backup.sh                  # Back up all databases
#   ./backup.sh errors           # Back up only errors.db
#   ./backup.sh logs metrics     # Back up specific databases
#
# Setup:
#   1. Ensure sqlite3 CLI is installed: apt install sqlite3
#   2. Make executable: chmod +x backup.sh
#   3. Add to crontab for daily backups:
#      0 3 * * * /path/to/deploy/backup.sh >> /var/log/monlight-backup.log 2>&1
#
# Environment variables:
#   BACKUP_DIR      - Where to store backups (default: ./backups)
#   DATA_DIR        - Where databases live (default: ./data)
#   RETENTION_COUNT - Number of daily backups to keep (default: 7)
#

set -euo pipefail

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/backups}"
DATA_DIR="${DATA_DIR:-${SCRIPT_DIR}/data}"
RETENTION_COUNT="${RETENTION_COUNT:-7}"
DATE_STAMP="$(date +%Y-%m-%d_%H%M%S)"

# Database name -> subdirectory and filename mapping
declare -A DB_MAP=(
    [errors]="errors/errors.db"
    [logs]="logs/logs.db"
    [metrics]="metrics/metrics.db"
)

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

# -------------------------------------------------------------------
# Preflight checks
# -------------------------------------------------------------------

command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is not installed. Install with: apt install sqlite3"

# -------------------------------------------------------------------
# Determine which databases to back up
# -------------------------------------------------------------------

if [ $# -gt 0 ]; then
    TARGETS=("$@")
    for target in "${TARGETS[@]}"; do
        [[ -v DB_MAP[$target] ]] || die "Unknown database: '$target'. Valid names: ${!DB_MAP[*]}"
    done
else
    TARGETS=("errors" "logs" "metrics")
fi

# -------------------------------------------------------------------
# Perform backups
# -------------------------------------------------------------------

ERRORS=0

for db_name in "${TARGETS[@]}"; do
    db_rel="${DB_MAP[$db_name]}"
    db_path="${DATA_DIR}/${db_rel}"
    backup_subdir="${BACKUP_DIR}/${db_name}"
    backup_file="${backup_subdir}/${db_name}_${DATE_STAMP}.db"

    # Skip if source database doesn't exist (service may not have run yet)
    if [ ! -f "$db_path" ]; then
        log "SKIP: ${db_path} does not exist (service may not have run yet)"
        continue
    fi

    # Create backup directory
    mkdir -p "$backup_subdir"

    # Use SQLite .backup command for a consistent, WAL-safe snapshot
    log "Backing up ${db_name}: ${db_path} -> ${backup_file}"
    if sqlite3 "$db_path" ".backup '${backup_file}'"; then
        # Verify the backup is a valid SQLite database
        if sqlite3 "$backup_file" "PRAGMA integrity_check;" | grep -q "^ok$"; then
            size=$(du -h "$backup_file" | cut -f1)
            log "OK: ${db_name} backed up successfully (${size})"
        else
            log "WARNING: ${db_name} backup integrity check failed"
            ERRORS=$((ERRORS + 1))
        fi
    else
        log "ERROR: Failed to back up ${db_name}"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # -------------------------------------------------------------------
    # Retention: keep only the last N backups
    # -------------------------------------------------------------------

    backup_count=$(find "$backup_subdir" -maxdepth 1 -name "${db_name}_*.db" -type f | wc -l)
    if [ "$backup_count" -gt "$RETENTION_COUNT" ]; then
        delete_count=$((backup_count - RETENTION_COUNT))
        log "Pruning ${delete_count} old ${db_name} backup(s) (keeping ${RETENTION_COUNT})"
        find "$backup_subdir" -maxdepth 1 -name "${db_name}_*.db" -type f -printf '%T@ %p\n' \
            | sort -n \
            | head -n "$delete_count" \
            | cut -d' ' -f2- \
            | xargs rm -f
    fi
done

# -------------------------------------------------------------------
# Optional: Upload to S3
# -------------------------------------------------------------------
#
# Uncomment the section below to upload backups to an S3-compatible
# storage provider (e.g., AWS S3, Contabo Object Storage, MinIO).
#
# Prerequisites:
#   1. Install AWS CLI: apt install awscli  (or pip install awscli)
#   2. Configure credentials:
#      export AWS_ACCESS_KEY_ID="your-access-key"
#      export AWS_SECRET_ACCESS_KEY="your-secret-key"
#   3. For non-AWS S3 providers, set the endpoint:
#      export S3_ENDPOINT="https://eu2.contabostorage.com"
#   4. Set the bucket name:
#      export S3_BUCKET="monlight-backups"
#
# S3_ENDPOINT="${S3_ENDPOINT:-}"
# S3_BUCKET="${S3_BUCKET:-monlight-backups}"
# S3_PREFIX="${S3_PREFIX:-backups}"
#
# if [ -n "$S3_BUCKET" ] && command -v aws >/dev/null 2>&1; then
#     S3_ARGS=""
#     if [ -n "$S3_ENDPOINT" ]; then
#         S3_ARGS="--endpoint-url $S3_ENDPOINT"
#     fi
#
#     for db_name in "${TARGETS[@]}"; do
#         backup_subdir="${BACKUP_DIR}/${db_name}"
#         latest=$(find "$backup_subdir" -maxdepth 1 -name "${db_name}_*.db" -type f -printf '%T@ %p\n' \
#             | sort -rn | head -1 | cut -d' ' -f2-)
#
#         if [ -n "$latest" ]; then
#             s3_key="${S3_PREFIX}/${db_name}/$(basename "$latest")"
#             log "Uploading ${db_name} to s3://${S3_BUCKET}/${s3_key}"
#             if aws s3 cp "$latest" "s3://${S3_BUCKET}/${s3_key}" $S3_ARGS; then
#                 log "OK: ${db_name} uploaded to S3"
#             else
#                 log "WARNING: Failed to upload ${db_name} to S3"
#                 ERRORS=$((ERRORS + 1))
#             fi
#         fi
#     done
# fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------

if [ $ERRORS -gt 0 ]; then
    log "Backup completed with ${ERRORS} error(s)"
    exit 1
else
    log "All backups completed successfully"
    exit 0
fi
