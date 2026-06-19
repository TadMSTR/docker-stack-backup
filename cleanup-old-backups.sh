#!/bin/bash

#######################################
# Docker Backup Cleanup Script
# Manages backup retention and removes old backups
#######################################

set -euo pipefail

#######################################
# OS Detection
#######################################
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        
        case "$OS_ID" in
            debian) OS_TYPE="debian" ;;
            ubuntu) OS_TYPE="ubuntu" ;;
            scale|truenas) OS_TYPE="truenas" ;;
            proxmox) OS_TYPE="proxmox" ;;
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
    else
        OS_TYPE="unknown"
        OS_NAME="Unknown"
    fi
    
    export OS_TYPE OS_NAME
}

detect_os

# Configuration
BACKUP_BASE="/mnt/backup/docker-backups"
RETENTION_DAYS=30  # Keep backups for this many days
LOG_FILE="/var/log/docker-backup-cleanup.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
    log "========================================="
    log "Starting backup cleanup"
    log "Retention: $RETENTION_DAYS days"
    log "========================================="
    
    if [[ ! -d "$BACKUP_BASE" ]]; then
        log_error "Backup directory not found: $BACKUP_BASE"
        exit 1
    fi
    
    local total_removed=0
    local total_size=0
    
    # Find and remove old backup directories
    while IFS= read -r backup_dir; do
        local size=$(du -sb "$backup_dir" | cut -f1)
        log "Removing old backup: $backup_dir ($(numfmt --to=iec-i --suffix=B $size))"
        
        if rm -rf "$backup_dir"; then
            total_removed=$((total_removed + 1))
            total_size=$((total_size + size))
        else
            log_error "Failed to remove: $backup_dir"
        fi
    done < <(find "$BACKUP_BASE" -mindepth 2 -maxdepth 2 -type d -mtime +$RETENTION_DAYS)
    
    log "========================================="
    log "Cleanup Summary:"
    log "Directories removed: $total_removed"
    log "Space freed: $(numfmt --to=iec-i --suffix=B $total_size)"
    log "========================================="
}

main "$@"
