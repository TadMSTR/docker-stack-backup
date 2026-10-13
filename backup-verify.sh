#!/bin/bash

#######################################
# Docker Backup Verification Script
# Lists and verifies backup integrity
#######################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -eq 0 ]]; then
    _dir_owner=$(stat -c '%U' "$SCRIPT_DIR" 2>/dev/null || echo "unknown")
    if [[ "$_dir_owner" != "root" ]]; then
        echo "[WARNING] Running as root but $SCRIPT_DIR is owned by '$_dir_owner'." >&2
        echo "[WARNING] lib.sh and config.sh will be sourced as root. For cron/production" >&2
        echo "[WARNING] use, deploy to a root-owned directory: sudo cp -r . /opt/docker-stack-backup" >&2
        echo "[WARNING]   && sudo chown -R root:root /opt/docker-stack-backup" >&2
    fi
    unset _dir_owner
fi

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/config.sh" ]] && source "$SCRIPT_DIR/config.sh"

detect_os

BACKUP_BASE="${BACKUP_BASE:-/mnt/backup/docker-backups}"
LOG_FILE="${LOG_FILE:-/dev/null}"


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
        
        local hostname; hostname=$(basename "$host_dir")
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        echo -e "${GREEN}Host: $hostname${NC}"
        
        for backup_dir in "$host_dir"/*; do
            if [[ ! -d "$backup_dir" ]]; then
                continue
            fi
            
            local timestamp; timestamp=$(basename "$backup_dir")
            local backup_count; backup_count=$(find "$backup_dir" \( -name "*.tar.*" -o -name "*.tar" \) | wc -l)
            local total_size; total_size=$(du -sh "$backup_dir" | cut -f1)
            
            echo "  $timestamp - $backup_count stacks - $total_size"
            
            for backup_file in "$backup_dir"/*.tar.* "$backup_dir"/*.tar; do
                if [[ -f "$backup_file" ]]; then
                    local fname; fname=$(basename "$backup_file")
                    local stack_name="${fname%.tar.*}"; stack_name="${stack_name%.tar}"
                    local file_size; file_size=$(du -sh "$backup_file" | cut -f1)
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
        
        local hostname; hostname=$(basename "$host_dir")
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        echo -e "${GREEN}Verifying: $hostname${NC}"
        
        for backup_file in "$host_dir"/*/*.tar.* "$host_dir"/*/*.tar; do
            if [[ ! -f "$backup_file" ]]; then
                continue
            fi
            
            total_checked=$((total_checked + 1))
            
            local relative_path="${backup_file#$BACKUP_BASE/}"
            
            if tar -tf "$backup_file" &>/dev/null; then
                echo -e "  ${GREEN}✓${NC} $relative_path"
                total_valid=$((total_valid + 1))
            else
                echo -e "  ${RED}✗${NC} $relative_path"
                total_invalid=$((total_invalid + 1))
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
        
        local hostname; hostname=$(basename "$host_dir")
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        local backup_sets; backup_sets=$(find "$host_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)
        local total_backups; total_backups=$(find "$host_dir" \( -name "*.tar.*" -o -name "*.tar" \) | wc -l)
        local total_size; total_size=$(du -sh "$host_dir" 2>/dev/null | cut -f1)
        
        local oldest_backup; oldest_backup=$(find "$host_dir" \( -name "*.tar.*" -o -name "*.tar" \) -printf '%T+ %p\n' 2>/dev/null | sort | head -1 | cut -d' ' -f1)
        local newest_backup; newest_backup=$(find "$host_dir" \( -name "*.tar.*" -o -name "*.tar" \) -printf '%T+ %p\n' 2>/dev/null | sort | tail -1 | cut -d' ' -f1)
        
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
