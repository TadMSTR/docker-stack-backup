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

# The share is read AS ITS OWNER (#1089): archives are 0600 in 0700 run dirs since 0.8.0,
# and on an NFS export with root squash root cannot read them. Under BACKUP_BASE as its
# owner, under a host dir as the host dir's owner (lib.sh as_owner_of). As a non-root
# user, everything runs as is.

# names <owner_path> <dir> <find tests...> — NUL-separated, sorted names directly in <dir>.
# Dot-names are left out, as the globs this replaces did.
names() {
    local owner="$1" dir="$2"; shift 2
    as_owner_of "$owner" find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' "$@" -printf '%f\0' 2>/dev/null | sort -z
}

# hsize <owner_path> <path> — du -sh's number only (never the rest of a name).
hsize() {
    local out
    out=$(as_owner_of "$1" du -sh -- "$2" 2>/dev/null) || true
    out="${out%%[[:space:]]*}"
    echo "${out:-0}"
}

hosts() {
    local -a h=()
    share_dir_readable "$BACKUP_BASE" "$BACKUP_BASE" \
        || printf '%b✗ cannot read %s as its owner%b\n' "$RED" "$(printable "$BACKUP_BASE")" "$NC" >&2
    mapfile -d '' -t h < <(names "$BACKUP_BASE" "$BACKUP_BASE" -type d)
    printf '%s\0' "${h[@]+"${h[@]}"}"
}

list_backups() {
    local hostname_filter="$1"
    
    echo -e "${BLUE}=== Backup Listing ===${NC}\n"
    
    local -a hostnames=()
    mapfile -d '' -t hostnames < <(hosts)
    local hostname
    for hostname in "${hostnames[@]+"${hostnames[@]}"}"; do
        local host_dir="$BACKUP_BASE/$hostname"
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        printf '%bHost: %s%b\n' "$GREEN" "$(printable "$hostname")" "$NC"
        
        local -a runs=()
        mapfile -d '' -t runs < <(names "$host_dir" "$host_dir" -type d)
        local timestamp
        for timestamp in "${runs[@]+"${runs[@]}"}"; do
            local backup_dir="$host_dir/$timestamp"
            local backup_count; backup_count=$(as_owner_of "$host_dir" find "$backup_dir" \( -name "*.tar.*" -o -name "*.tar" \) -printf x 2>/dev/null | wc -c) || backup_count=0
            local total_size; total_size=$(hsize "$host_dir" "$backup_dir")
            
            echo "  $(printable "$timestamp") - $backup_count stacks - $total_size"
            
            local -a files=()
            mapfile -d '' -t files < <(names "$host_dir" "$backup_dir" -type f \( -name '*.tar.*' -o -name '*.tar' \))
            local fname
            for fname in "${files[@]+"${files[@]}"}"; do
                local stack_name="${fname%.tar.*}"; stack_name="${stack_name%.tar}"
                local file_size; file_size=$(hsize "$host_dir" "$backup_dir/$fname")
                echo "    - $(printable "$stack_name") ($file_size)"
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
    
    local -a hostnames=()
    mapfile -d '' -t hostnames < <(hosts)
    local hostname
    for hostname in "${hostnames[@]+"${hostnames[@]}"}"; do
        local host_dir="$BACKUP_BASE/$hostname"
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        printf '%bVerifying: %s%b\n' "$GREEN" "$(printable "$hostname")" "$NC"
        # An unreadable host or run dir is a failure, never an empty one (SH-15).
        local -a unreadable=()
        mapfile -d '' -t unreadable < <(
            share_dir_readable "$host_dir" "$host_dir" || printf '%s\0' "$host_dir"
            local r
            while IFS= read -r -d '' r; do
                share_dir_readable "$host_dir" "$host_dir/$r" || printf '%s\0' "$host_dir/$r"
            done < <(names "$host_dir" "$host_dir" -type d))
        local u
        for u in "${unreadable[@]+"${unreadable[@]}"}"; do
            printf '  %b✗%b cannot read %s as its owner\n' "$RED" "$NC" "$(printable "${u#"$BACKUP_BASE"/}")"
            total_checked=$((total_checked + 1))
            total_invalid=$((total_invalid + 1))
        done
        
        local -a archives=()
        mapfile -d '' -t archives < <(as_owner_of "$host_dir" find "$host_dir" -mindepth 2 -maxdepth 2 \
            -type f \( -name '*.tar.*' -o -name '*.tar' \) ! -path "$host_dir/.*" ! -name '.*' -print0 2>/dev/null | sort -z)
        local backup_file
        for backup_file in "${archives[@]+"${archives[@]}"}"; do
            total_checked=$((total_checked + 1))
            
            local relative_path="${backup_file#"$BACKUP_BASE"/}"
            
            # tar runs as the archive's owner too: a listing needs no root.
            if as_owner_of "$host_dir" tar -tf "$backup_file" &>/dev/null; then
                printf '  %b✓%b %s\n' "$GREEN" "$NC" "$(printable "$relative_path")"
                total_valid=$((total_valid + 1))
            else
                printf '  %b✗%b %s\n' "$RED" "$NC" "$(printable "$relative_path")"
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
    
    local -a hostnames=()
    mapfile -d '' -t hostnames < <(hosts)
    local hostname
    for hostname in "${hostnames[@]+"${hostnames[@]}"}"; do
        local host_dir="$BACKUP_BASE/$hostname"
        
        if [[ -n "$hostname_filter" && "$hostname" != "$hostname_filter" ]]; then
            continue
        fi
        
        local backup_sets; backup_sets=$(as_owner_of "$host_dir" find "$host_dir" -mindepth 1 -maxdepth 1 -type d -printf x 2>/dev/null | wc -c) || backup_sets=0
        local total_size; total_size=$(hsize "$host_dir" "$host_dir")

        # One pass: count, oldest and newest mtime (as YYYY-MM-DD) from a single find.
        # awk reads to EOF. `sort | head -1` here died of SIGPIPE (rc 141 under
        # pipefail) once the listing outgrew the pipe buffer — forge's share, ~930
        # archives, every time (#1099).
        local total_backups=0 oldest_backup="" newest_backup=""
        read -r total_backups oldest_backup newest_backup < <(
            as_owner_of "$host_dir" find "$host_dir" \( -name "*.tar.*" -o -name "*.tar" \) -printf '%T@ %TY-%Tm-%Td\n' 2>/dev/null |
                awk 'NR == 1 || $1 < min { min = $1; old = $2 }
                     NR == 1 || $1 > max { max = $1; new = $2 }
                     END { print NR, old, new }'
        ) || true
        
        printf '%b%s%b\n' "$GREEN" "$(printable "$hostname")" "$NC"
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
