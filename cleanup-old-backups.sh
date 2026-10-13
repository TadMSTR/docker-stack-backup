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
# Never delete the newest KEEP_MIN run dirs under each parent (one parent per host in
# the depth-2 layout), whatever their age. Only dirs holding at least one completed
# archive (*.tar / *.tar.*) count toward the minimum. 0 disables the floor.
KEEP_MIN="${KEEP_MIN:-7}"
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

# validate_uint <VAR_NAME> <min> <max>: VAR must be a plain decimal integer within
# [min, max]. Normalised with 10#, so a leading zero is never read as octal by bash
# arithmetic: KEEP_MIN=08 used to pass the format check, then fail `-gt` as invalid
# octal and silently disable the floor. The length cap rules out int64 overflow.
validate_uint() {
    local name="$1" min="$2" max="$3"
    local val="${!name:-}"
    if [[ ! "$val" =~ ^[0-9]+$ || ${#val} -gt 15 ]]; then
        log_error "$name must be a non-negative integer between $min and $max (got: '$val')"
        return 1
    fi
    val=$((10#$val))
    if (( val < min || val > max )); then
        log_error "$name must be between $min and $max (got: $val)"
        return 1
    fi
    printf -v "$name" '%s' "$val"
}

# True if $1 directly holds at least one completed archive
dir_has_archive() {
    [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.*' \) -print -quit 2>/dev/null)" ]]
}

main() {
    mkdir -p "$(dirname "$LOG_FILE")"

    # Validate before anything is deleted.
    local config_ok=0
    validate_uint KEEP_MIN 0 100000 || config_ok=1
    validate_uint RETENTION_DAYS 0 36500 || config_ok=1
    validate_uint SEARCH_DEPTH 1 10 || config_ok=1
    if [[ $config_ok -ne 0 ]]; then
        exit 1
    fi

    log "========================================="
    log "Starting backup cleanup (OS: ${OS_TYPE})"
    log "Backup base:  $BACKUP_BASE"
    log "Retention:    $RETENTION_DAYS days"
    log "Search depth: $SEARCH_DEPTH"
    log "Keep minimum: $KEEP_MIN per parent dir"
    log "========================================="

    if [[ ! -d "$BACKUP_BASE" ]]; then
        log_error "Backup directory not found: $BACKUP_BASE"
        exit 1
    fi

    local total_removed=0
    local total_size=0
    local kept_by_min=0

    # Protected set: per parent dir, the newest KEEP_MIN run dirs (by mtime, the same
    # clock retention uses) that hold a completed archive. Empty or failed-run dirs
    # never take a slot.
    declare -A protected=()
    if [[ $KEEP_MIN -gt 0 ]]; then
        local parent entry dir kept
        while IFS= read -r -d '' parent; do
            kept=0
            while IFS= read -r -d '' entry; do
                dir="${entry#* }"
                if dir_has_archive "$dir"; then
                    protected["$dir"]=1
                    kept=$((kept + 1))
                    [[ $kept -ge $KEEP_MIN ]] && break
                fi
            done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\0' | sort -z -r -n)
        done < <(find "$BACKUP_BASE" -mindepth "$((SEARCH_DEPTH - 1))" -maxdepth "$((SEARCH_DEPTH - 1))" -type d -print0)
    fi

    while IFS= read -r -d '' backup_dir; do
        if [[ -n "${protected["$backup_dir"]:-}" ]]; then
            log "Keeping past retention (KEEP_MIN): $backup_dir"
            kept_by_min=$((kept_by_min + 1))
            continue
        fi

        local size
        size=$(du -sb "$backup_dir" | cut -f1)
        log "Removing old backup: $backup_dir ($(numfmt --to=iec-i --suffix=B "$size"))"

        if rm -rf "$backup_dir"; then
            total_removed=$((total_removed + 1))
            total_size=$((total_size + size))
        else
            log_error "Failed to remove: $backup_dir"
        fi
    done < <(find "$BACKUP_BASE" -mindepth "$SEARCH_DEPTH" -maxdepth "$SEARCH_DEPTH" -type d -mtime +"$RETENTION_DAYS" -print0)

    log "========================================="
    log "Cleanup Summary:"
    log "Directories removed: $total_removed"
    log "Kept $kept_by_min past retention by KEEP_MIN ($KEEP_MIN)"
    log "Space freed: $(numfmt --to=iec-i --suffix=B "$total_size")"
    log "========================================="
}

main
