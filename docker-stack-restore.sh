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

BACKUP_BASE="${BACKUP_BASE:-/mnt/backup/docker-backups}"
DOCKHAND_BASE="${DOCKHAND_BASE:-/opt/dockhand/stacks}"
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
    
    if [[ -n "$default" ]]; then
        echo -e -n "${CYAN}$prompt [$default]: ${NC}"
    else
        echo -e -n "${CYAN}$prompt: ${NC}"
    fi
    
    read -r input
    echo "${input:-$default}"
}

#######################################
# Select hostname
#######################################
select_hostname() {
    print_section "Step 1: Select Host"
    
    local -a hostnames
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
    local -a timestamps
    local i=1
    
    for backup_dir in "$host_dir"/*; do
        if [[ -d "$backup_dir" ]]; then
            timestamps+=("$(basename "$backup_dir")")
        fi
    done | sort -r
    
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
        local stack_count; stack_count=$(find "$host_dir/$timestamp" \( -name "*.tar.*" -o -name "*.tar" \) | wc -l)
        
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
    local -a stacks
    local -a stack_files
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
#######################################
preview_backup() {
    print_section "Step 4: Preview Backup Contents"
    
    echo "Contents of backup:"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    tar -tf "$selected_backup_file" | head -20

    local total_files; total_files=$(tar -tf "$selected_backup_file" | wc -l)
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
    
    local stack_dir="$DOCKHAND_BASE/$selected_hostname/$selected_stack"
    local appdata_dir="$APPDATA_PATH/$selected_stack"
    local has_conflicts=false
    
    # Check if stack directory exists
    if [[ -d "$stack_dir" ]]; then
        log_warning "Stack directory already exists: $stack_dir"
        has_conflicts=true
        
        # Check if stack is running
        if (cd "$stack_dir" && docker compose ps --services --filter "status=running" 2>/dev/null | grep -q .); then
            log_warning "Stack has running containers!"
            has_conflicts=true
        fi
    fi
    
    # Check if appdata exists
    if [[ -d "$appdata_dir" ]]; then
        local appdata_size; appdata_size=$(du -sh "$appdata_dir" | cut -f1)
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
# Perform restore
#######################################
perform_restore() {
    print_section "Step 6: Performing Restore"
    
    local stack_dir="$DOCKHAND_BASE/$selected_hostname/$selected_stack"
    local appdata_dir="$APPDATA_PATH/$selected_stack"
    local temp_restore; temp_restore=$(mktemp -d)
    
    trap 'rm -rf "$temp_restore"' RETURN
    
    # Handle existing data based on mode
    if [[ "$restore_mode" == "backup_first" ]]; then
        local safety_backup_dir; safety_backup_dir="/tmp/docker-restore-backup-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$safety_backup_dir"
        
        log "Creating safety backup in $safety_backup_dir"
        
        if [[ -d "$stack_dir" ]]; then
            cp -a "$stack_dir" "$safety_backup_dir/stack"
        fi
        
        if [[ -d "$appdata_dir" ]]; then
            cp -a "$appdata_dir" "$safety_backup_dir/appdata"
        fi
        
        log_success "Safety backup created"
    fi
    
    # Stop existing containers if any
    if [[ -d "$stack_dir" ]]; then
        log "Stopping existing stack"
        (cd "$stack_dir" && docker compose down 2>/dev/null) || true
    fi
    
    # Extract backup to temp directory
    log "Extracting backup..."
    tar -xf "$selected_backup_file" -C "$temp_restore"
    
    # Restore compose files
    log "Restoring stack configuration..."
    mkdir -p "$stack_dir"
    
    if [[ -f "$temp_restore/docker-compose.yml" ]]; then
        cp "$temp_restore/docker-compose.yml" "$stack_dir/"
    fi
    
    if [[ -f "$temp_restore/.env" ]]; then
        cp "$temp_restore/.env" "$stack_dir/"
    fi
    
    # Restore appdata
    log "Restoring appdata..."
    
    if [[ -d "$appdata_dir" ]]; then
        rm -rf "$appdata_dir"
    fi
    
    if [[ -d "$temp_restore/$selected_stack" ]]; then
        cp -a "$temp_restore/$selected_stack" "$APPDATA_PATH/"
    fi
    
    log_success "Files restored successfully"
    
    # Ask about starting stack
    echo ""
    if prompt_continue "Start the stack now?"; then
        log "Starting stack..."
        if (cd "$stack_dir" && docker compose up -d); then
            log_success "Stack started successfully"
            
            echo -e "\n${GREEN}Container status:${NC}"
            (cd "$stack_dir" && docker compose ps)
        else
            log_error "Failed to start stack"
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
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
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
    echo -e "\n${GREEN}✓ All done!${NC}\n"
    
    log "========================================="
    log "Restore completed successfully"
    log "========================================="
}

# Run main function
main "$@"
