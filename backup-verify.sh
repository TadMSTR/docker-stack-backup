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

# The backup writes BACKUP_DEST; read the same place unless BACKUP_BASE overrides it.
# Reading only BACKUP_BASE sent this script to a default path a config that sets
# BACKUP_DEST (as config.example.sh does) never wrote to (#1091).
BACKUP_BASE="${BACKUP_BASE:-${BACKUP_DEST:-/mnt/backup/docker-backups}}"
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
            local backup_count; backup_count=$(find "$backup_dir" \( -name "*.tar.*" -o -name "*.tar" \) | wc -l) || backup_count=0
            local total_size; total_size=$(du_size "$backup_dir" -h) || true
            
            echo "  $timestamp - $backup_count stacks - $total_size"
            
            for backup_file in "$backup_dir"/*.tar.* "$backup_dir"/*.tar; do
                if [[ -f "$backup_file" ]]; then
                    local fname; fname=$(basename "$backup_file")
                    local stack_name="${fname%.tar.*}"; stack_name="${stack_name%.tar}"
                    local file_size; file_size=$(du_size "$backup_file" -h) || true
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
        
        local backup_sets; backup_sets=$(find "$host_dir" -mindepth 1 -maxdepth 1 -type d | wc -l) || backup_sets=0
        local total_size; total_size=$(du_size "$host_dir" -h) || true

        # One pass: count, oldest and newest mtime (as YYYY-MM-DD) from a single find.
        # awk reads to EOF. `sort | head -1` here died of SIGPIPE (rc 141 under
        # pipefail) once the listing outgrew the pipe buffer — forge's share, ~930
        # archives, every time (#1099).
        local total_backups=0 oldest_backup="" newest_backup=""
        read -r total_backups oldest_backup newest_backup < <(
            find "$host_dir" \( -name "*.tar.*" -o -name "*.tar" \) -printf '%T@ %TY-%Tm-%Td\n' 2>/dev/null |
                awk 'NR == 1 || $1 < min { min = $1; old = $2 }
                     NR == 1 || $1 > max { max = $1; new = $2 }
                     END { print NR, old, new }'
        ) || true
        
        echo -e "${GREEN}$hostname${NC}"
        echo "  Backup sets: $backup_sets"
        echo "  Total backups: ${total_backups:-0}"
        echo "  Total size: $total_size"
        
        if [[ -n "$oldest_backup" ]]; then
            echo "  Oldest: $oldest_backup"
            echo "  Newest: $newest_backup"
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
