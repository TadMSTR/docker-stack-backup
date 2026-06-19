#!/bin/bash

#######################################
# Docker Backup Verification Script
# Lists and verifies backup integrity
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

BACKUP_BASE="/mnt/backup/docker-backups"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -l, --list              List all backups
    -v, --verify            Verify backup integrity (test tar files)
    -s, --stats             Show backup statistics
    -h HOSTNAME            Filter by hostname
    --help                  Show this help message

Examples:
    $(basename "$0") --list
    $(basename "$0") --verify
    $(basename "$0") --stats -h debian-docker
EOF
}

list_backups() {
    local hostname_filter="$1"
    
    echo -e "${BLUE}=== Backup Listing ===${NC}\n"
    
    for host_dir in "$BACKUP_BASE"/*; do
        if [[ ! -d "$host_dir" ]]; then
            continue
        fi
        
        local hostname=$(basename "$host_dir")
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        echo -e "${GREEN}Host: $hostname${NC}"
        
        for backup_dir in "$host_dir"/*; do
            if [[ ! -d "$backup_dir" ]]; then
                continue
            fi
            
            local timestamp=$(basename "$backup_dir")
            local backup_count=$(find "$backup_dir" -name "*.tar.gz" | wc -l)
            local total_size=$(du -sh "$backup_dir" | cut -f1)
            
            echo "  $timestamp - $backup_count stacks - $total_size"
            
            for backup_file in "$backup_dir"/*.tar.gz; do
                if [[ -f "$backup_file" ]]; then
                    local stack_name=$(basename "$backup_file" .tar.gz)
                    local file_size=$(du -sh "$backup_file" | cut -f1)
                    echo "    - $stack_name ($file_size)"
                fi
            done
        done
        echo
    done
}

verify_backups() {
    local hostname_filter="$1"
    
    echo -e "${BLUE}=== Backup Verification ===${NC}\n"
    
    local total_checked=0
    local total_valid=0
    local total_invalid=0
    
    for host_dir in "$BACKUP_BASE"/*; do
        if [[ ! -d "$host_dir" ]]; then
            continue
        fi
        
        local hostname=$(basename "$host_dir")
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        echo -e "${GREEN}Verifying: $hostname${NC}"
        
        for backup_file in "$host_dir"/*/*.tar.gz; do
            if [[ ! -f "$backup_file" ]]; then
                continue
            fi
            
            ((total_checked++))
            
            local relative_path="${backup_file#$BACKUP_BASE/}"
            
            if tar -tzf "$backup_file" &>/dev/null; then
                echo -e "  ${GREEN}✓${NC} $relative_path"
                ((total_valid++))
            else
                echo -e "  ${RED}✗${NC} $relative_path"
                ((total_invalid++))
            fi
        done
        echo
    done
    
    echo -e "${BLUE}=== Verification Summary ===${NC}"
    echo "Total backups checked: $total_checked"
    echo -e "Valid: ${GREEN}$total_valid${NC}"
    echo -e "Invalid: ${RED}$total_invalid${NC}"
}

show_stats() {
    local hostname_filter="$1"
    
    echo -e "${BLUE}=== Backup Statistics ===${NC}\n"
    
    for host_dir in "$BACKUP_BASE"/*; do
        if [[ ! -d "$host_dir" ]]; then
            continue
        fi
        
        local hostname=$(basename "$host_dir")
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        local backup_sets=$(find "$host_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)
        local total_backups=$(find "$host_dir" -name "*.tar.gz" | wc -l)
        local total_size=$(du -sh "$host_dir" 2>/dev/null | cut -f1)
        
        local oldest_backup=$(find "$host_dir" -name "*.tar.gz" -printf '%T+ %p\n' 2>/dev/null | sort | head -1 | cut -d' ' -f1)
        local newest_backup=$(find "$host_dir" -name "*.tar.gz" -printf '%T+ %p\n' 2>/dev/null | sort | tail -1 | cut -d' ' -f1)
        
        echo -e "${GREEN}$hostname${NC}"
        echo "  Backup sets: $backup_sets"
        echo "  Total backups: $total_backups"
        echo "  Total size: $total_size"
        
        if [[ -n "$oldest_backup" ]]; then
            echo "  Oldest: $(date -d "${oldest_backup%T*}" +'%Y-%m-%d')"
            echo "  Newest: $(date -d "${newest_backup%T*}" +'%Y-%m-%d')"
        fi
        echo
    done
}

main() {
    if [[ ! -d "$BACKUP_BASE" ]]; then
        echo -e "${RED}Error: Backup directory not found: $BACKUP_BASE${NC}"
        exit 1
    fi
    
    local action=""
    local hostname_filter=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--list)
                action="list"
                shift
                ;;
            -v|--verify)
                action="verify"
                shift
                ;;
            -s|--stats)
                action="stats"
                shift
                ;;
            -h)
                hostname_filter="$2"
                shift 2
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$action" ]]; then
        show_usage
        exit 1
    fi
    
    case $action in
        list)
            list_backups "$hostname_filter"
            ;;
        verify)
            verify_backups "$hostname_filter"
            ;;
        stats)
            show_stats "$hostname_filter"
            ;;
    esac
}

main "$@"
