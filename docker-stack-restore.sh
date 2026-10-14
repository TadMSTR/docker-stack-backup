#!/bin/bash

#######################################
# Docker Stack Restore Script
# Interactive restoration of Docker Compose stacks from backup
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
DOCKHAND_BASE="${DOCKHAND_BASE:-/opt/dockhand/stacks}"
DOCKHAND_APPEND_HOSTNAME="${DOCKHAND_APPEND_HOSTNAME:-true}"
APPDATA_PATH="${APPDATA_PATH:-/mnt/datastor/appdata}"
LOG_FILE="${LOG_FILE:-/var/log/docker-restore.log}"


print_header() {
    echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  Docker Stack Restore Wizard${NC}"
    echo -e "${BOLD}${BLUE}  Current Host: $HOSTNAME | OS: $OS_NAME${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${CYAN}▶ $1${NC}\n"
}

prompt_continue() {
    local message="${1:-Continue?}"
    echo -e -n "${YELLOW}$message [y/N]: ${NC}"
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    
    # Prompt to stderr: this function's stdout is captured via $(prompt_input ...),
    # so writing the prompt to stdout would concatenate it into the returned value
    # and corrupt every selection (same class as DSBAK-11 / #22 in the manual script).
    if [[ -n "$default" ]]; then
        echo -e -n "${CYAN}$prompt [$default]: ${NC}" >&2
    else
        echo -e -n "${CYAN}$prompt: ${NC}" >&2
    fi
    
    read -r input
    echo "${input:-$default}"
}

#######################################
# Select hostname
#######################################
select_hostname() {
    print_section "Step 1: Select Host"
    
    local -a hostnames=()
    local i=1
    
    for host_dir in "$BACKUP_BASE"/*; do
        if [[ -d "$host_dir" ]]; then
            hostnames+=("$(basename "$host_dir")")
        fi
    done
    
    if [[ ${#hostnames[@]} -eq 0 ]]; then
        log_error "No backup hosts found in $BACKUP_BASE"
        exit 1
    fi
    
    echo "Available hosts:"
    for hostname in "${hostnames[@]}"; do
        echo -e "  ${GREEN}$i)${NC} $hostname"
        ((i++))
    done
    
    echo ""
    local selection; selection=$(prompt_input "Select host number" "1")
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#hostnames[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    selected_hostname="${hostnames[$((selection-1))]}"
    echo -e "\n${GREEN}✓${NC} Selected host: ${BOLD}$selected_hostname${NC}"
}

#######################################
# Select backup timestamp
#######################################
select_timestamp() {
    print_section "Step 2: Select Backup Date"
    
    local host_dir="$BACKUP_BASE/$selected_hostname"
    local -a timestamps=()
    local i=1
    
    # mapfile from a process substitution, not `for … done | sort -r`: the pipe ran the
    # loop in a subshell, so the parent's array was never set and `set -u` aborted at the
    # count below ("timestamps: unbound variable"). The wizard never got past this step
    # (#1094).
    mapfile -t timestamps < <(
        for backup_dir in "$host_dir"/*; do
            if [[ -d "$backup_dir" ]]; then
                basename "$backup_dir"
            fi
        done | sort -r
    )
    
    if [[ ${#timestamps[@]} -eq 0 ]]; then
        log_error "No backups found for host $selected_hostname"
        exit 1
    fi
    
    echo "Available backups (newest first):"
    for timestamp in "${timestamps[@]}"; do
        local date_part="${timestamp%_*}"
        local time_part="${timestamp#*_}"
        local formatted_date; formatted_date=$(date -d "${date_part:0:4}-${date_part:4:2}-${date_part:6:2}" +"%B %d, %Y" 2>/dev/null || echo "$date_part")
        local formatted_time="${time_part:0:2}:${time_part:2:2}:${time_part:4:2}"
        # Guard against set -e/pipefail abort: a find or wc failure (e.g. a timestamp
        # dir that became unreadable between listing and now) must not kill the whole
        # preview — fall back to 0 (DSBAK-9 / #24, same class as DSBAK-8).
        local stack_count; stack_count=$(find "$host_dir/$timestamp" \( -name "*.tar.*" -o -name "*.tar" \) | wc -l) || stack_count=0
        
        echo -e "  ${GREEN}$i)${NC} $formatted_date at $formatted_time (${stack_count} stacks)"
        ((i++))
    done
    
    echo ""
    local selection; selection=$(prompt_input "Select backup number" "1")
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#timestamps[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    selected_timestamp="${timestamps[$((selection-1))]}"
    echo -e "\n${GREEN}✓${NC} Selected backup: ${BOLD}$selected_timestamp${NC}"
}

#######################################
# Select stack
#######################################
select_stack() {
    print_section "Step 3: Select Stack to Restore"
    
    local backup_dir="$BACKUP_BASE/$selected_hostname/$selected_timestamp"
    local -a stacks=()
    local -a stack_files=()
    local i=1

    for backup_file in "$backup_dir"/*.tar.* "$backup_dir"/*.tar; do
        if [[ -f "$backup_file" ]]; then
            local fname; fname=$(basename "$backup_file")
            local stack_name="${fname%.tar.*}"; stack_name="${stack_name%.tar}"
            stacks+=("$stack_name")
            stack_files+=("$backup_file")
        fi
    done

    if [[ ${#stacks[@]} -eq 0 ]]; then
        log_error "No stack backups found"
        exit 1
    fi

    echo "Available stacks:"
    for stack in "${stacks[@]}"; do
        local size; size=$(du -h "${stack_files[$((i-1))]}" | cut -f1)
        echo -e "  ${GREEN}$i)${NC} $stack (${size})"
        ((i++))
    done

    echo ""
    local selection; selection=$(prompt_input "Select stack number" "1")

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#stacks[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi

    selected_stack="${stacks[$((selection-1))]}"
    selected_backup_file="${stack_files[$((selection-1))]}"
    echo -e "\n${GREEN}✓${NC} Selected stack: ${BOLD}$selected_stack${NC}"
}

#######################################
# Preview backup contents
# One pass over the archive (#1095): `tar -tvf` feeds awk, which prints the first 20
# entries and, reading to EOF, the entry count and the sum of member sizes. The sum is
# the space an extract needs, which perform_restore checks before writing anything.
# awk never exits early, so a non-zero pipeline status is tar's: the archive could not
# be read (an early-exiting `head` here aborted every real archive under pipefail, #1094).
#######################################
preview_backup() {
    print_section "Step 4: Preview Backup Contents"
    
    echo "Contents of backup:"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    local out list_rc=0
    out=$(tar -tvf "$selected_backup_file" | awk '
        NR <= 20 { print }
        $3 ~ /^[0-9]+$/ { bytes += $3 }
        END { printf "%d %.0f\n", NR, bytes }') || list_rc=$?
    local summary="${out##*$'\n'}"
    if [[ "$out" == *$'\n'* ]]; then
        printf '%s\n' "${out%$'\n'*}"
    fi
    local total_files="${summary% *}"
    if [[ $list_rc -ne 0 ]]; then
        log_warning "Could not list $selected_backup_file (tar exit $list_rc) — the archive may be corrupt or truncated"
        archive_extract_bytes=""
    else
        archive_extract_bytes="${summary#* }"
    fi

    if [[ $total_files -gt 20 ]]; then
        echo -e "${YELLOW}... and $((total_files - 20)) more files${NC}"
    fi
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}\n"
    
    if ! prompt_continue "Proceed with restore?"; then
        echo "Restore cancelled."
        exit 0
    fi
}

#######################################
# Check for conflicts
#######################################
check_conflicts() {
    print_section "Step 5: Check for Conflicts"
    
    local stack_dir; stack_dir="$(dockhand_stack_base "$selected_hostname")/$selected_stack"
    local appdata_dir="$APPDATA_PATH/$selected_stack"
    local has_conflicts=false
    
    # Check if stack directory exists
    if [[ -d "$stack_dir" ]]; then
        log_warning "Stack directory already exists: $stack_dir"
        has_conflicts=true
        
        # Check if stack is running. get_running_services, not `ps | grep -q .`: an
        # early-exiting grep under pipefail, and a failed `ps` read as "not running".
        local running ps_rc=0
        running=$(get_running_services "$stack_dir") || ps_rc=$?
        if [[ $ps_rc -ne 0 ]]; then
            log_warning "Could not determine whether the stack is running — treat it as running"
        elif [[ -n "$running" ]]; then
            log_warning "Stack has running containers!"
        fi
    fi
    
    # Check if appdata exists
    if [[ -d "$appdata_dir" ]]; then
        local appdata_size; appdata_size=$(du_size "$appdata_dir" -h) || true
        log_warning "Appdata directory already exists: $appdata_dir ($appdata_size)"
        has_conflicts=true
    fi
    
    if [[ "$has_conflicts" == true ]]; then
        echo -e "\n${YELLOW}⚠ Conflicts detected!${NC}\n"
        echo "Choose how to proceed:"
        echo -e "  ${GREEN}1)${NC} Stop containers and overwrite everything (destructive)"
        echo -e "  ${GREEN}2)${NC} Backup existing data first, then restore"
        echo -e "  ${GREEN}3)${NC} Cancel restore"
        
        local choice; choice=$(prompt_input "Select option" "3")
        
        case $choice in
            1)
                echo -e "\n${RED}⚠ WARNING: This will permanently overwrite existing data!${NC}"
                if ! prompt_continue "Are you absolutely sure?"; then
                    echo "Restore cancelled."
                    exit 0
                fi
                restore_mode="overwrite"
                ;;
            2)
                restore_mode="backup_first"
                ;;
            3|*)
                echo "Restore cancelled."
                exit 0
                ;;
        esac
    else
        echo -e "${GREEN}✓${NC} No conflicts detected"
        restore_mode="clean"
    fi
}

#######################################
# Free space
# fs_free <dir> — prints "<free bytes> <mount point>" for the filesystem holding <dir>
#######################################
fs_free() {
    df -PB1 -- "$1" 2>/dev/null | awk 'NR == 2 { print $4, $6 }'
}

#######################################
# Space check, before Step 6 writes anything
# The extract is staged under TMPDIR (mktemp -d) and, in backup_first mode, the old
# stack dir + appdata are copied under RESTORE_SAFETY_DIR. Both must fit, summed when
# they share a filesystem. The extract size is the sum of member sizes from Step 4's
# listing; if that was unavailable, the archive's own size (a compressed archive will
# extract larger).
#######################################
check_restore_space() {
    local stack_dir="$1" appdata_dir="$2" safety_base="$3"
    local temp_base="${TMPDIR:-/tmp}"

    local need_extract="${archive_extract_bytes:-}"
    if [[ ! "$need_extract" =~ ^[0-9]+$ ]]; then
        need_extract=$(stat -c %s -- "$selected_backup_file" 2>/dev/null) || need_extract=0
    fi
    local need_safety=0
    if [[ "$restore_mode" == "backup_first" ]]; then
        local sz
        if [[ -d "$stack_dir" ]]; then
            sz=$(du_size "$stack_dir") || true
            need_safety=$((need_safety + sz))
        fi
        if [[ -d "$appdata_dir" ]]; then
            sz=$(du_size "$appdata_dir") || true
            need_safety=$((need_safety + sz))
        fi
    fi

    local temp_free temp_mnt safety_free safety_mnt
    read -r temp_free temp_mnt <<< "$(fs_free "$temp_base")" || true
    read -r safety_free safety_mnt <<< "$(fs_free "$safety_base")" || true
    if [[ ! "${temp_free:-}" =~ ^[0-9]+$ ]]; then
        log_error "Cannot read free space for TMPDIR ($temp_base)"
        return 1
    fi

    local -a checks=()
    if [[ $need_safety -gt 0 && -n "${safety_mnt:-}" && "$safety_mnt" != "$temp_mnt" ]]; then
        checks+=("$temp_mnt $temp_free $need_extract" "$safety_mnt ${safety_free:-0} $need_safety")
    else
        checks+=("$temp_mnt $temp_free $((need_extract + need_safety))")
    fi

    local c mnt free need ok=true
    for c in "${checks[@]}"; do
        read -r mnt free need <<< "$c"
        if [[ $free -lt $need ]]; then
            log_error "Not enough space on $mnt for the restore: need $(numfmt --to=iec-i --suffix=B "$need"), $(numfmt --to=iec-i --suffix=B "$free") free"
            ok=false
        fi
    done
    if [[ "$ok" != true ]]; then
        log_error "Nothing was changed. Point TMPDIR (extract: $temp_base) and/or RESTORE_SAFETY_DIR (pre-restore copy: $safety_base) at a filesystem with room."
        return 1
    fi
    return 0
}

#######################################
# Replace the stack's config and appdata with the extracted backup.
# Returns non-zero at the first failed step; the caller reports it (the stack is down
# by then, so the operator needs to know where things stand).
#######################################
replace_stack_files() {
    local temp_restore="$1" stack_dir="$2" appdata_dir="$3"

    log "Restoring stack configuration..."
    mkdir -p "$stack_dir" || return 1

    # The backup archives whichever compose file the stack uses (find_compose_file), so
    # restore whichever is there, not only docker-compose.yml.
    local name restored_compose=false
    for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml .env; do
        if [[ -f "$temp_restore/$name" ]]; then
            cp -p "$temp_restore/$name" "$stack_dir/" || return 1
            [[ "$name" != .env ]] && restored_compose=true
        fi
    done
    if [[ "$restored_compose" != true ]]; then
        log_warning "The backup holds no compose file; kept the stack dir's existing one"
    fi

    log "Restoring appdata..."
    if [[ ! -d "$temp_restore/$selected_stack" ]]; then
        # Never delete the live appdata when there is nothing to put in its place.
        log_warning "The backup holds no $selected_stack/ appdata; existing appdata left as is"
        return 0
    fi
    if [[ -d "$appdata_dir" ]]; then
        rm -rf "$appdata_dir" || return 1
    fi
    cp -a "$temp_restore/$selected_stack" "$APPDATA_PATH/" || return 1
    return 0
}

#######################################
# Perform restore
#######################################
perform_restore() {
    print_section "Step 6: Performing Restore"
    
    local stack_dir; stack_dir="$(dockhand_stack_base "$selected_hostname")/$selected_stack"
    local appdata_dir="$APPDATA_PATH/$selected_stack"
    local safety_base="${RESTORE_SAFETY_DIR:-${TMPDIR:-/tmp}}"

    check_restore_space "$stack_dir" "$appdata_dir" "$safety_base" || return 1

    local temp_restore; temp_restore=$(mktemp -d)
    # Disarm the trap once it has fired. Without `trap - RETURN`, it stays installed and
    # fires again on the NEXT function return (print_section in main), where
    # $temp_restore is out of scope — aborting under `set -u` with "temp_restore:
    # unbound variable" and exiting 1 after a successful restore (#1098; the same class
    # PR #11 fixed in backup_stack).
    trap 'rm -rf "$temp_restore"; trap - RETURN' RETURN
    
    # Extract first, while the stack is still up: a corrupt archive or a full disk
    # then costs no downtime and changes nothing.
    log "Extracting backup..."
    if ! tar -xf "$selected_backup_file" -C "$temp_restore"; then
        log_error "Could not extract $selected_backup_file — nothing was changed"
        return 1
    fi

    # Stop existing containers if any
    if [[ -d "$stack_dir" ]]; then
        log "Stopping existing stack"
        (cd "$stack_dir" && docker compose down 2>/dev/null) || true
    fi

    # Safety copy after the stop, so it is a consistent copy of the old data.
    if [[ "$restore_mode" == "backup_first" ]]; then
        # mktemp: a fresh 0700 dir, never an existing (or planted) path in a shared /tmp.
        if ! mkdir -p -- "$safety_base" || ! safety_backup_dir=$(mktemp -d "$safety_base/docker-restore-backup-${selected_stack}-$(date +%Y%m%d_%H%M%S).XXXXXX"); then
            safety_backup_dir=""
            log_error "Cannot create a safety backup dir under $safety_base — existing data NOT replaced. The stack is stopped; start it again with:"
            echo "  cd $stack_dir && docker compose up -d"
            return 1
        fi
        log "Creating safety backup in $safety_backup_dir"
        if ! { { [[ ! -d "$stack_dir" ]] || cp -a "$stack_dir" "$safety_backup_dir/stack"; } \
                && { [[ ! -d "$appdata_dir" ]] || cp -a "$appdata_dir" "$safety_backup_dir/appdata"; }; }; then
            log_error "Safety backup failed — existing data NOT replaced. The stack is stopped; start it again with:"
            echo "  cd $stack_dir && docker compose up -d"
            return 1
        fi
        log_success "Safety backup created"
    fi

    if ! replace_stack_files "$temp_restore" "$stack_dir" "$appdata_dir"; then
        log_error "Restore failed while replacing files in $stack_dir / $appdata_dir"
        if [[ -n "${safety_backup_dir:-}" ]]; then
            log_error "The pre-restore copy is in $safety_backup_dir"
        fi
        return 1
    fi
    
    log_success "Files restored successfully"
    
    # Ask about starting stack
    echo ""
    if prompt_continue "Start the stack now?"; then
        log "Starting stack..."
        if (cd "$stack_dir" && docker compose up -d); then
            log_success "Stack started successfully"
            
            echo -e "\n${GREEN}Container status:${NC}"
            (cd "$stack_dir" && docker compose ps) || true
        else
            log_error "Failed to start stack. The files are restored; start it manually with:"
            echo "  cd $stack_dir && docker compose up -d"
            return 1
        fi
    else
        echo -e "\n${YELLOW}Stack not started. You can start it manually with:${NC}"
        echo "  cd $stack_dir && docker compose up -d"
    fi
}

#######################################
# Main function
#######################################
main() {
    print_header
    
    log "========================================="
    log "Starting Docker stack restore wizard"
    log "Current Host: $HOSTNAME"
    log "OS: $OS_NAME ($OS_TYPE)"
    log "========================================="
    
    # Unlike docker-stack-backup.sh/-manual.sh, this check is NOT relaxed by
    # ELEVATION_CMD: restore writes directly into appdata (tar -x, cp -a, rm -rf —
    # see perform_restore()) and no helper exists for that direction. ELEVATION_CMD
    # only covers archive *creation* (read of appdata via docker-backup-tar-create.sh).
    # Relaxing this check without a matching privileged-write helper would let restore
    # start (stopping the stack, taking a safety backup) and then fail mid-restore with
    # permission-denied once it hits root-owned appdata — a worse failure mode than
    # rejecting upfront. See ELEVATION.md.
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (ELEVATION_CMD does not apply to restore — see ELEVATION.md)"
        exit 1
    fi
    
    # Check if backup directory exists
    if [[ ! -d "$BACKUP_BASE" ]]; then
        log_error "Backup directory not found: $BACKUP_BASE"
        exit 1
    fi
    
    # Interactive selection process
    select_hostname
    select_timestamp
    select_stack
    preview_backup
    check_conflicts
    perform_restore
    
    print_section "Restore Complete!"
    
    log_success "Stack '$selected_stack' has been restored from backup"
    if [[ -n "${safety_backup_dir:-}" ]]; then
        log "Pre-restore copy of the old data: $safety_backup_dir"
    fi
    echo -e "\n${GREEN}✓ All done!${NC}\n"
    
    log "========================================="
    log "Restore completed successfully"
    log "========================================="
}

# Run main function — only when executed, so tests can source the script and drive
# the steps without root (main's EUID check).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
