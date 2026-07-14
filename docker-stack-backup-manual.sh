#!/bin/bash

#######################################
# Docker Compose Stack Backup — Manual/Interactive Script
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

# Dry-run mode flag
DRY_RUN=false

# Configuration defaults (override via config.sh or environment variables)
DOCKHAND_BASE="${DOCKHAND_BASE:-/opt/dockhand/stacks}"
DOCKHAND_APPEND_HOSTNAME="${DOCKHAND_APPEND_HOSTNAME:-true}"
HOSTNAME=$(hostname)
APPDATA_PATH="${APPDATA_PATH:-/mnt/datastor/appdata}"
BACKUP_DEST="${BACKUP_DEST:-/mnt/backup/docker-backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# LOG_FILE default is based on actual writability, not on ELEVATION_CMD alone — the
# root-only /var/log default breaks for ANY unprivileged run (misconfigured
# ELEVATION_CMD or not); testing writability directly also gives a clean
# require_privileged_or_elevated() error message instead of a raw `tee` failure when
# someone simply forgot to run as root. Falls back to a home-relative path, same
# convention already used by cleanup-old-backups.sh. An explicit LOG_FILE override
# always wins.
if [[ -z "${LOG_FILE:-}" ]]; then
    if [[ -w /var/log ]]; then
        LOG_FILE="/var/log/docker-backup-manual.log"
    else
        LOG_FILE="${HOME}/logs/docker-backup-manual.log"
    fi
fi
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Compression
COMPRESSION_METHOD="${COMPRESSION_METHOD:-none}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
USE_PARALLEL="${USE_PARALLEL:-false}"
PARALLEL_THREADS="${PARALLEL_THREADS:-0}"
EXCLUDE_PATTERNS=(${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"})

# Notifications
NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-true}"
NOTIFY_ON_FAILURE="${NOTIFY_ON_FAILURE:-true}"
NTFY_ENABLED="${NTFY_ENABLED:-false}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-docker-backups}"
NTFY_PRIORITY="${NTFY_PRIORITY:-default}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
PUSHOVER_ENABLED="${PUSHOVER_ENABLED:-false}"
PUSHOVER_USER_KEY="${PUSHOVER_USER_KEY:-}"
PUSHOVER_API_TOKEN="${PUSHOVER_API_TOKEN:-}"
PUSHOVER_PRIORITY="${PUSHOVER_PRIORITY:-0}"
EMAIL_ENABLED="${EMAIL_ENABLED:-false}"
EMAIL_TO="${EMAIL_TO:-}"
EMAIL_FROM="${EMAIL_FROM:-docker-backup@$(hostname)}"
EMAIL_SUBJECT_PREFIX="${EMAIL_SUBJECT_PREFIX:-[Docker Backup]}"
EMAIL_METHOD="${EMAIL_METHOD:-sendmail}"
SMTP_SERVER="${SMTP_SERVER:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_USE_TLS="${SMTP_USE_TLS:-true}"
SMTP_INSECURE="${SMTP_INSECURE:-false}"
MATRIX_ENABLED="${MATRIX_ENABLED:-false}"
MATRIX_HOMESERVER="${MATRIX_HOMESERVER:-}"
MATRIX_ACCESS_TOKEN="${MATRIX_ACCESS_TOKEN:-}"
MATRIX_ROOM_ID="${MATRIX_ROOM_ID:-}"
NTFY_URGENT_ONLY="${NTFY_URGENT_ONLY:-false}"

# Elevation (privileged archive creation via a validated helper — see ELEVATION.md)
ELEVATION_CMD="${ELEVATION_CMD:-none}"
ELEVATION_HELPER_PATH="${ELEVATION_HELPER_PATH:-}"

# File locking (used by acquire_lock/release_lock in lib.sh). Default is based on
# actual writability of /var/run, matching the LOG_FILE convention (DSBAK-6) — /var/run
# is root-only, which would otherwise make the lock unacquirable for any
# ELEVATION_CMD-configured unprivileged run. Falls back to a home-relative path. An
# explicit LOCK_FILE override in config.sh always wins (previously this line
# unconditionally clobbered any config.sh value — now it doesn't).
if [[ -z "${LOCK_FILE:-}" ]]; then
    if [[ -w /var/run ]]; then
        LOCK_FILE="/var/run/docker-stack-backup-manual.lock"
    else
        LOCK_FILE="${HOME}/run/docker-stack-backup-manual.lock"
    fi
fi
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
# shellcheck disable=SC2034
LOCK_FD=200
trap release_lock EXIT INT TERM


print_header() {
    echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BOLD}${CYAN}  Docker Stack Manual Backup - DRY RUN${NC}"
        echo -e "${BOLD}${CYAN}  No changes will be made${NC}"
    else
        echo -e "${BOLD}${BLUE}  Docker Stack Manual Backup${NC}"
    fi
    echo -e "${BOLD}${BLUE}  Host: $HOSTNAME | OS: $OS_NAME${NC}"
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

check_docker_running() {
    if ! systemctl is-active --quiet docker 2>/dev/null && ! pgrep -x dockerd >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon not responding"
        return 1
    fi
    
    return 0
}

check_disk_space() {
    local path="$1"
    local min_free_gb="${2:-5}"
    
    mkdir -p "$path" 2>/dev/null || true
    
    if [[ ! -d "$path" ]]; then
        log_error "Backup destination does not exist: $path"
        return 1
    fi
    
    local available_kb; available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    local available_gb; available_gb=$((available_kb / 1024 / 1024))
    
    if [[ $available_gb -lt $min_free_gb ]]; then
        log_error "Insufficient disk space: ${available_gb}GB available, ${min_free_gb}GB required"
        return 1
    fi
    
    return 0
}

check_mount_point() {
    local path="$1"
    
    if [[ ! -d "$path" ]]; then
        return 0
    fi
    
    if ! touch "$path/.write-test" 2>/dev/null; then
        log_error "Cannot write to $path"
        return 1
    fi
    rm -f "$path/.write-test"
    
    return 0
}

run_preflight_checks() {
    echo -e "${CYAN}Running pre-flight checks...${NC}\n"
    
    local checks_passed=true
    
    if ! check_docker_running; then
        echo -e "${RED}✗${NC} Docker daemon not running"
        checks_passed=false
    else
        echo -e "${GREEN}✓${NC} Docker daemon running"
    fi
    
    local stack_base; stack_base=$(dockhand_stack_base)
    if [[ ! -d "$stack_base" ]]; then
        echo -e "${RED}✗${NC} Dockhand directory not found: $stack_base"
        checks_passed=false
    else
        echo -e "${GREEN}✓${NC} Dockhand directory found"
    fi
    
    if [[ ! -d "$APPDATA_PATH" ]]; then
        echo -e "${RED}✗${NC} Appdata directory not found: $APPDATA_PATH"
        checks_passed=false
    else
        echo -e "${GREEN}✓${NC} Appdata directory found"
    fi
    
    if ! check_mount_point "$BACKUP_DEST"; then
        echo -e "${RED}✗${NC} Cannot write to backup destination"
        checks_passed=false
    else
        echo -e "${GREEN}✓${NC} Backup destination writable"
    fi
    
    if ! check_disk_space "$BACKUP_DEST" 5; then
        echo -e "${RED}✗${NC} Insufficient disk space"
        checks_passed=false
    else
        local available_kb; available_kb=$(df -k "$BACKUP_DEST" | awk 'NR==2 {print $4}')
        local available_gb; available_gb=$((available_kb / 1024 / 1024))
        echo -e "${GREEN}✓${NC} Disk space: ${available_gb}GB available"
    fi
    
    if [[ "$checks_passed" == false ]]; then
        echo -e "\n${RED}Pre-flight checks failed!${NC}\n"
        return 1
    fi
    
    echo -e "\n${GREEN}✓ All checks passed${NC}\n"
    return 0
}

stack_has_appdata() {
    local compose_file="$1"
    
    if [[ ! -f "$compose_file" ]]; then
        return 1
    fi
    
    if grep -q "$APPDATA_PATH" "$compose_file"; then
        return 0
    fi
    
    return 1
}

#######################################
# Get stack information
#######################################
get_stack_info() {
    local stack_path="$1"
    local stack_name; stack_name=$(basename "$stack_path")
    local compose_file; compose_file=$(find_compose_file "$stack_path") || true

    local info=""

    # Check if has appdata
    if stack_has_appdata "$compose_file"; then
        local appdata_dir="$APPDATA_PATH/$stack_name"
        if [[ -d "$appdata_dir" ]]; then
            local size; size=$(du -sh "$appdata_dir" 2>/dev/null | cut -f1)
            info="appdata: $size"
        else
            info="appdata: (missing)"
        fi
    else
        info="no appdata"
    fi
    
    # Check running status
    local running_count=0
    if (cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | grep -q .); then
        running_count=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l) || running_count=0
        info="$info, ${GREEN}$running_count running${NC}"
    else
        info="$info, ${YELLOW}stopped${NC}"
    fi
    
    echo -e "$info"
}

#######################################
# Discover and select stacks
#######################################
select_stacks() {
    print_section "Step 1: Select Stacks to Backup"
    
    local stack_base; stack_base=$(dockhand_stack_base)
    
    if [[ ! -d "$stack_base" ]]; then
        log_error "Dockhand directory not found: $stack_base"
        exit 1
    fi
    
    # Build list of stacks
    declare -A stack_list
    declare -a stack_names
    local i=1
    
    for stack_path in "$stack_base"/*; do
        if [[ ! -d "$stack_path" ]]; then
            continue
        fi
        
        local stack_name; stack_name=$(basename "$stack_path")
        local compose_file; compose_file=$(find_compose_file "$stack_path") || true

        if [[ -z "$compose_file" ]]; then
            continue
        fi
        
        stack_list["$i"]="$stack_path"
        stack_names+=("$stack_name")
        
        local info; info=$(get_stack_info "$stack_path")
        echo -e "  ${GREEN}$i)${NC} ${BOLD}$stack_name${NC} ($info)"
        ((i++))
    done
    
    if [[ ${#stack_names[@]} -eq 0 ]]; then
        log_error "No stacks found in $stack_base"
        exit 1
    fi
    
    echo -e "\n${CYAN}Select stacks to backup:${NC}"
    echo "  - Enter numbers separated by spaces (e.g., '1 3 5')"
    echo "  - Enter 'all' to backup all stacks with appdata"
    echo "  - Enter ranges with dash (e.g., '1-3 5 7-9')"
    echo ""
    
    local selection; selection=$(prompt_input "Your selection")
    
    # Parse selection
    selected_stacks=()
    
    if [[ "$selection" == "all" ]]; then
        for idx in "${!stack_list[@]}"; do
            local stack_path="${stack_list[$idx]}"
            local all_cf; all_cf=$(find_compose_file "$stack_path") || true
            if [[ -n "$all_cf" ]] && stack_has_appdata "$all_cf"; then
                selected_stacks+=("$stack_path")
            fi
        done
    else
        # Parse numbers and ranges
        for item in $selection; do
            if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                # Range
                local start="${BASH_REMATCH[1]}"
                local end="${BASH_REMATCH[2]}"
                for ((idx=start; idx<=end; idx++)); do
                    if [[ -n "${stack_list[$idx]:-}" ]]; then
                        selected_stacks+=("${stack_list[$idx]}")
                    fi
                done
            elif [[ "$item" =~ ^[0-9]+$ ]]; then
                # Single number
                if [[ -n "${stack_list[$item]:-}" ]]; then
                    selected_stacks+=("${stack_list[$item]}")
                fi
            fi
        done
    fi
    
    if [[ ${#selected_stacks[@]} -eq 0 ]]; then
        log_error "No valid stacks selected"
        exit 1
    fi
    
    # Show selection summary
    echo -e "\n${GREEN}✓${NC} Selected ${BOLD}${#selected_stacks[@]}${NC} stack(s):"
    for stack_path in "${selected_stacks[@]}"; do
        local stack_name; stack_name=$(basename "$stack_path")
        echo "  - $stack_name"
    done
}

#######################################
# Show backup summary
#######################################
show_summary() {
    print_section "Step 2: Backup Summary"
    
    local total_size=0
    local stacks_with_appdata=0
    local running_stacks=0
    
    echo "Stacks to be backed up:"
    echo ""
    
    for stack_path in "${selected_stacks[@]}"; do
        local stack_name; stack_name=$(basename "$stack_path")
        local compose_file; compose_file=$(find_compose_file "$stack_path") || true

        echo -e "${BOLD}$stack_name${NC}"

        # Check appdata
        if [[ -n "$compose_file" ]] && stack_has_appdata "$compose_file"; then
            ((stacks_with_appdata++))
            local appdata_dir="$APPDATA_PATH/$stack_name"
            if [[ -d "$appdata_dir" ]]; then
                local size_bytes; size_bytes=$(du -sb "$appdata_dir" 2>/dev/null | cut -f1)
                local size_human; size_human=$(du -sh "$appdata_dir" 2>/dev/null | cut -f1)
                ((total_size+=size_bytes))
                echo "  └─ Appdata: $size_human"
            else
                log_warning "  └─ Appdata directory not found (will skip)"
            fi
        else
            log_warning "  └─ No appdata (will skip)"
        fi
        
        # Check running containers
        local running; running=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l) || running=0
        if [[ $running -gt 0 ]]; then
            ((running_stacks++))
            echo -e "  └─ Status: ${GREEN}$running container(s) running (will be stopped during backup)${NC}"
        else
            echo -e "  └─ Status: ${YELLOW}All containers stopped${NC}"
        fi
        
        echo ""
    done
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "Total estimated backup size: ${BOLD}$(numfmt --to=iec-i --suffix=B $total_size)${NC}"
    echo -e "Stacks with appdata: ${BOLD}$stacks_with_appdata${NC}"
    echo -e "Running stacks (will be stopped): ${BOLD}$running_stacks${NC}"
    echo -e "Backup destination: ${BOLD}$BACKUP_DEST/$HOSTNAME/$TIMESTAMP${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    
    echo ""
    if ! prompt_continue "Proceed with backup?"; then
        echo "Backup cancelled."
        exit 0
    fi
}

#######################################
# Backup a single stack
#######################################
backup_stack() {
    local stack_path="$1"
    local stack_name; stack_name=$(basename "$stack_path")
    local compose_file; compose_file=$(find_compose_file "$stack_path") || true

    echo -e "\n${CYAN}▶ Backing up: ${BOLD}$stack_name${NC}"

    if [[ -z "$compose_file" ]]; then
        log_warning "Stack $stack_name: no compose file found, skipping"
        return 0
    fi

    # Check if stack has appdata
    if ! stack_has_appdata "$compose_file"; then
        log_warning "Stack $stack_name has no appdata bind mounts, skipping"
        return 0
    fi
    
    local appdata_dir="$APPDATA_PATH/$stack_name"
    
    if [[ ! -d "$appdata_dir" ]]; then
        log_warning "Appdata directory $appdata_dir not found for stack $stack_name, skipping"
        return 0
    fi
    
    # Create backup directory structure
    local backup_dir="$BACKUP_DEST/$HOSTNAME/$TIMESTAMP"
    mkdir -p "$backup_dir"
    
    local backup_ext; backup_ext=$(get_compression_extension)
    local backup_file="$backup_dir/${stack_name}${backup_ext}"
    
    # Get list of running containers before stopping
    local running_containers; running_containers=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null || true)
    
    if [[ -z "$running_containers" ]]; then
        log_warning "No running containers in stack $stack_name"
    else
        echo "  └─ Running containers: $(echo "$running_containers" | tr '\n' ', ' | sed 's/,$//')"
        echo "  └─ Stopping stack..."
        if ! (cd "$stack_path" && docker compose down 2>&1 | sed 's/^/     /'); then
            log_error "Failed to stop stack $stack_name"
            return 1
        fi
    fi
    
    echo "  └─ Creating backup archive..."
    
    # Create a temporary directory for organizing backup contents
    local temp_dir; temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' RETURN
    
    # Copy compose file to temp directory
    cp "$compose_file" "$temp_dir/"
    
    # Copy any other files in the stack directory (env files, etc)
    if [[ -f "$stack_path/.env" ]]; then
        cp "$stack_path/.env" "$temp_dir/"
    fi
    
    # Create archive with configured compression
    echo "  └─ Creating ${COMPRESSION_METHOD} compressed backup (level ${COMPRESSION_LEVEL})..."
    if [[ "$USE_PARALLEL" == true ]]; then
        echo "  └─ Using parallel compression..."
    fi
    
    if create_compressed_archive "$backup_file" \
        -C "$temp_dir" . \
        -C "$APPDATA_PATH" "$stack_name" 2>&1 | sed 's/^/     /'; then
        local backup_size; backup_size=$(du -sh "$backup_file" | cut -f1)
        echo -e "  └─ ${GREEN}✓${NC} Backup created: $backup_size"
    else
        log_error "Failed to create backup for $stack_name"
        # Restore only previously running containers
        if [[ -n "$running_containers" ]]; then
            echo "  └─ Restoring previously running containers..."
            (cd "$stack_path" && docker compose up -d $running_containers 2>&1 | sed 's/^/     /')
        fi
        return 1
    fi
    
    # Start only the containers that were running before
    if [[ -n "$running_containers" ]]; then
        echo "  └─ Starting previously running containers..."
        if ! restart_stack_with_retry "$stack_path" "$running_containers"; then
            return 1
        fi
    fi
    
    return 0
}

#######################################
# Perform backup
#######################################
perform_backup() {
    if [[ "$DRY_RUN" == true ]]; then
        print_section "Dry Run Results"
        
        echo -e "${CYAN}Selected stacks:${NC}\n"
        
        local total_size=0
        for stack_path in "${selected_stacks[@]}"; do
            local stack_name; stack_name=$(basename "$stack_path")
            local appdata_dir="$APPDATA_PATH/$stack_name"
            
            if [[ -d "$appdata_dir" ]]; then
                local size; size=$(du -sh "$appdata_dir" 2>/dev/null | cut -f1)
                local size_bytes; size_bytes=$(du -sb "$appdata_dir" 2>/dev/null | cut -f1)
                ((total_size+=size_bytes))
                
                local running_count; running_count=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l) || running_count=0
                
                if [[ $running_count -gt 0 ]]; then
                    echo -e "  ${GREEN}✓${NC} $stack_name ($size, $running_count running)"
                else
                    echo -e "  ${YELLOW}○${NC} $stack_name ($size, stopped)"
                fi
            fi
        done
        
        local total_size_human; total_size_human=$(numfmt --to=iec-i --suffix=B $total_size 2>/dev/null || echo "${total_size} bytes")
        
        echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo -e "Total stacks: ${BOLD}${#selected_stacks[@]}${NC}"
        echo -e "Estimated backup size: ${BOLD}$total_size_human${NC}"
        echo -e "Compression: ${COMPRESSION_METHOD}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
        
        echo -e "\n${BOLD}${GREEN}DRY RUN COMPLETE - No actions taken${NC}\n"
        
        log "Dry run complete: ${#selected_stacks[@]} stacks would be backed up"
        log "Estimated size: $total_size_human"
        
        return 0
    fi
    
    print_section "Step 3: Performing Backup"
    
    local total=${#selected_stacks[@]}
    local successful=0
    local skipped=0
    local failed=0
    local current=0
    
    for stack_path in "${selected_stacks[@]}"; do
        ((current++))
        echo -e "\n${BLUE}[${current}/${total}]${NC}"
        
        if backup_stack "$stack_path"; then
            local stack_name; stack_name=$(basename "$stack_path")
            local perf_cf; perf_cf=$(find_compose_file "$stack_path") || true
            if [[ -n "$perf_cf" ]] && stack_has_appdata "$perf_cf" && [[ -d "$APPDATA_PATH/$stack_name" ]]; then
                ((successful++))
            else
                ((skipped++))
            fi
        else
            ((failed++))
        fi
    done
    
    print_section "Backup Complete!"
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "Total stacks processed: ${BOLD}$total${NC}"
    echo -e "Successfully backed up: ${GREEN}${BOLD}$successful${NC}"
    echo -e "Skipped (no appdata): ${YELLOW}${BOLD}$skipped${NC}"
    echo -e "Failed: ${RED}${BOLD}$failed${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    
    if [[ $successful -gt 0 ]]; then
        echo -e "\nBackups saved to: ${BOLD}$BACKUP_DEST/$HOSTNAME/$TIMESTAMP${NC}"
    fi
    
    if [[ $failed -gt 0 ]]; then
        echo -e "\n${RED}Some backups failed. Check the log: $LOG_FILE${NC}"
        return 1
    fi
    
    return 0
}

#######################################
# Main function
#######################################
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run|--dryrun|-n)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Interactive manual backup of Docker Compose stacks"
                echo ""
                echo "Options:"
                echo "  --dry-run, -n    Simulate backup without making changes"
                echo "  --help, -h       Show this help message"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    print_header
    
    log "========================================="
    if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN: Manual Docker stack backup simulation"
    else
        log "Starting manual Docker stack backup"
    fi
    log "Hostname: $HOSTNAME"
    log "OS: $OS_NAME ($OS_TYPE)"
    log "========================================="
    
    # Require root, unless ELEVATION_CMD is configured to elevate archive creation
    if ! require_privileged_or_elevated; then
        exit 1
    fi
    
    # Acquire lock (skip in dry-run)
    if [[ "$DRY_RUN" != true ]]; then
        acquire_lock
    fi
    
    # Run pre-flight checks
    if ! run_preflight_checks; then
        exit 1
    fi
    
    # Create backup destination if it doesn't exist
    mkdir -p "$BACKUP_DEST"
    
    # Interactive backup process
    select_stacks
    show_summary
    perform_backup
    
    log "========================================="
    log "Manual backup completed"
    log "========================================="
}

# Run main function
main "$@"
