#!/bin/bash

#######################################
# Docker Backup Cleanup Script
# Manages backup retention and removes old backups
#######################################

set -euo pipefail

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        OS_TYPE="unknown"
        export OS_TYPE
        return
    fi

    . /etc/os-release
    case "$ID" in
        debian)        OS_TYPE="debian" ;;
        ubuntu)        OS_TYPE="ubuntu" ;;
        scale|truenas) OS_TYPE="truenas" ;;
        *)
            if [[ -f /etc/version ]] && grep -q "TrueNAS" /etc/version 2>/dev/null; then
                OS_TYPE="truenas"
            elif [[ -f /etc/debian_version ]]; then
                OS_TYPE="debian"
            else
                OS_TYPE="unknown"
            fi
            ;;
    esac
    export OS_TYPE
}

detect_os

# Configuration — all vars can be overridden via env; BACKUP_BASE also accepts $1
# CLI arg takes precedence over env var, env var takes precedence over default.
BACKUP_BASE="${1:-${BACKUP_BASE:-/mnt/backup/docker-backups}}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
# Depth of dated backup dirs inside BACKUP_BASE.
# 1 = BACKUP_BASE/YYYY-MM-DD/, 2 = BACKUP_BASE/stack/YYYY-MM-DD/
SEARCH_DEPTH="${SEARCH_DEPTH:-2}"
LOG_FILE="${LOG_FILE:-${HOME}/logs/docker-backup-cleanup.log}"

# Colors — suppressed when stdout is not a terminal (avoids escape codes in log files)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

main() {
    mkdir -p "$(dirname "$LOG_FILE")"

    log "========================================="
    log "Starting backup cleanup (OS: ${OS_TYPE})"
    log "Backup base:  $BACKUP_BASE"
    log "Retention:    $RETENTION_DAYS days"
    log "Search depth: $SEARCH_DEPTH"
    log "========================================="

    if [[ ! -d "$BACKUP_BASE" ]]; then
        log_error "Backup directory not found: $BACKUP_BASE"
        exit 1
    fi

    local total_removed=0
    local total_size=0

    while IFS= read -r backup_dir; do
        local size
        size=$(du -sb "$backup_dir" | cut -f1)
        log "Removing old backup: $backup_dir ($(numfmt --to=iec-i --suffix=B "$size"))"

        if rm -rf "$backup_dir"; then
            total_removed=$((total_removed + 1))
            total_size=$((total_size + size))
        else
            log_error "Failed to remove: $backup_dir"
        fi
    done < <(find "$BACKUP_BASE" -mindepth "$SEARCH_DEPTH" -maxdepth "$SEARCH_DEPTH" -type d -mtime +"$RETENTION_DAYS")

    log "========================================="
    log "Cleanup Summary:"
    log "Directories removed: $total_removed"
    log "Space freed: $(numfmt --to=iec-i --suffix=B "$total_size")"
    log "========================================="
}

main
