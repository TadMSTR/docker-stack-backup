#!/bin/bash

#######################################
# Docker Compose Stack Backup Script
# Backs up Docker Compose stacks that have appdata bind mounts
#######################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# When running as root, warn if scripts are not root-owned (local privesc path).
# For cron/production use, deploy to a root-owned directory — see README.
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
        LOG_FILE="/var/log/docker-backup.log"
    else
        LOG_FILE="${HOME}/logs/docker-backup.log"
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

# Post-restart hooks (see HOOKS.md)
# shellcheck disable=SC2034  # consumed by run_post_restart_hooks in lib.sh
POST_RESTART_HOOKS=(${POST_RESTART_HOOKS[@]+"${POST_RESTART_HOOKS[@]}"})

# File locking (used by acquire_lock/release_lock in lib.sh). Default is based on
# actual writability of /var/run, matching the LOG_FILE convention (DSBAK-6) — /var/run
# is root-only, which would otherwise make the lock unacquirable for any
# ELEVATION_CMD-configured unprivileged run. Falls back to a home-relative path. An
# explicit LOCK_FILE override in config.sh always wins (previously this line
# unconditionally clobbered any config.sh value — now it doesn't).
if [[ -z "${LOCK_FILE:-}" ]]; then
    if [[ -w /var/run ]]; then
        LOCK_FILE="/var/run/docker-stack-backup.lock"
    else
        LOCK_FILE="${HOME}/run/docker-stack-backup.lock"
    fi
fi
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
# shellcheck disable=SC2034
LOCK_FD=200
trap release_lock EXIT INT TERM


check_docker_running() {
    if ! systemctl is-active --quiet docker 2>/dev/null && ! pgrep -x dockerd >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        log_error "Start with: systemctl start docker"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon not responding"
        return 1
    fi
    
    log "✓ Docker daemon is running"
    return 0
}

check_disk_space() {
    local path="$1"
    local min_free_gb="${2:-5}"  # Default: require 5GB free
    
    # Create directory if it doesn't exist
    mkdir -p "$path" 2>/dev/null || true
    
    if [[ ! -d "$path" ]]; then
        log_error "Backup destination does not exist: $path"
        return 1
    fi
    
    # Get available space in GB
    local available_kb; available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    local available_gb; available_gb=$((available_kb / 1024 / 1024))
    
    if [[ $available_gb -lt $min_free_gb ]]; then
        log_error "Insufficient disk space on $path"
        log_error "Available: ${available_gb}GB, Required: ${min_free_gb}GB"
        return 1
    fi
    
    log "✓ Disk space: ${available_gb}GB available on $path"
    return 0
}

check_mount_point() {
    local path="$1"
    
    # Check if path is accessible
    if [[ ! -d "$path" ]]; then
        log_warning "Path does not exist: $path (will be created)"
        return 0
    fi
    
    # Check if we can write to it
    if ! touch "$path/.write-test" 2>/dev/null; then
        log_error "Cannot write to $path"
        log_error "Check permissions and mount status"
        return 1
    fi
    rm -f "$path/.write-test"
    
    # Check if it's a mount point (optional, informational)
    if mountpoint -q "$path" 2>/dev/null; then
        log "✓ $path is a mount point ($(df -h "$path" | awk 'NR==2 {print $1}')"
    else
        log "✓ $path is accessible (local filesystem)"
    fi
    
    return 0
}

check_required_paths() {
    log "Checking required paths..."
    
    # Check Dockhand directory
    local stack_base; stack_base=$(dockhand_stack_base)
    if [[ ! -d "$stack_base" ]]; then
        log_error "Dockhand directory not found: $stack_base"
        return 1
    fi
    log "✓ Dockhand directory exists: $stack_base"
    
    # Check appdata directory
    if [[ ! -d "$APPDATA_PATH" ]]; then
        log_error "Appdata directory not found: $APPDATA_PATH"
        return 1
    fi
    log "✓ Appdata directory exists: $APPDATA_PATH"
    
    return 0
}

run_preflight_checks() {
    log "========================================="
    log "Running pre-flight checks..."
    log "========================================="
    
    local checks_passed=true
    
    # Check Docker
    if ! check_docker_running; then
        checks_passed=false
    fi
    
    # Check required paths
    if ! check_required_paths; then
        checks_passed=false
    fi
    
    # Check backup destination
    if ! check_mount_point "$BACKUP_DEST"; then
        checks_passed=false
    fi
    
    # Check disk space (require at least 5GB free)
    if ! check_disk_space "$BACKUP_DEST" 5; then
        checks_passed=false
    fi
    
    if [[ "$checks_passed" == false ]]; then
        log_error "Pre-flight checks failed!"
        return 1
    fi
    
    log "========================================="
    log "✓ All pre-flight checks passed"
    log "========================================="
    return 0
}

stack_has_appdata() {
    local compose_file="$1"
    
    if [[ ! -f "$compose_file" ]]; then
        return 1
    fi
    
    # Check if any volume is a bind mount to APPDATA_PATH
    if grep -q "$APPDATA_PATH" "$compose_file"; then
        return 0
    fi
    
    return 1
}

#######################################
# Dry-run backup simulation
#######################################
simulate_backup_stack() {
    local stack_path="$1"
    local stack_name; stack_name=$(basename "$stack_path")
    
    # Find compose file
    local compose_file; compose_file=$(find_compose_file "$stack_path") || true
    if [[ -z "$compose_file" ]]; then
        return 2  # Skip - no compose file
    fi
    
    # Check if stack has appdata
    if ! stack_has_appdata "$compose_file"; then
        return 2  # Skip
    fi
    
    local appdata_dir="$APPDATA_PATH/$stack_name"
    
    if [[ ! -d "$appdata_dir" ]]; then
        return 2  # Skip
    fi
    
    # Get appdata size
    local size; size=$(du -sh "$appdata_dir" 2>/dev/null | cut -f1)
    local size_bytes; size_bytes=$(du -sb "$appdata_dir" 2>/dev/null | cut -f1)
    
    # Get running containers
    local running_count=0
    if (cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | grep -q .); then
        running_count=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l) || running_count=0
    fi
    
    # Output stack info
    if [[ $running_count -gt 0 ]]; then
        echo "  ${GREEN}✓${NC} $stack_name ($size appdata, $running_count running)"
    else
        echo "  ${YELLOW}○${NC} $stack_name ($size appdata, stopped)"
    fi
    
    # Return size in bytes for calculation
    echo "$size_bytes" > /tmp/stack_size_$$
    
    return 0  # Success
}

#######################################
# Backup a single stack
#######################################
backup_stack() {
    local stack_path="$1"
    local stack_name; stack_name=$(basename "$stack_path")
    
    # Find compose file
    local compose_file; compose_file=$(find_compose_file "$stack_path") || true
    if [[ -z "$compose_file" ]]; then
        log_warning "No compose file found for stack $stack_name"
        return 0
    fi
    
    log "Processing stack: $stack_name"
    
    # Check if stack has appdata
    if ! stack_has_appdata "$compose_file"; then
        log_warning "Stack $stack_name has no appdata bind mounts, skipping"
        return 2  # Return 2 for skipped
    fi
    
    local appdata_dir="$APPDATA_PATH/$stack_name"
    
    # Check if appdata directory exists or if it has subdirectories
    # (some stacks have container-specific folders like dashboards/heimdall, dashboards/homepage)
    if [[ ! -d "$appdata_dir" ]]; then
        log_warning "Appdata directory $appdata_dir not found for stack $stack_name"
        return 2  # Return 2 for skipped
    fi
    
    # Check if directory has any content (direct files or subdirectories).
    # Skipped/deferred under ELEVATION_CMD — see appdata_has_content() in lib.sh.
    if ! appdata_has_content "$appdata_dir"; then
        log_warning "Appdata directory $appdata_dir is empty for stack $stack_name"
        return 0
    fi
    
    # Create backup directory structure
    local backup_dir="$BACKUP_DEST/$HOSTNAME/$TIMESTAMP"
    mkdir -p "$backup_dir"
    
    local backup_ext; backup_ext=$(get_compression_extension)
    local backup_file="$backup_dir/${stack_name}${backup_ext}"
    
    # Get list of running containers before stopping
    log "Checking container states for stack: $stack_name"
    local running_containers; running_containers=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null || true)
    
    if [[ -z "$running_containers" ]]; then
        log_warning "No running containers in stack $stack_name, skipping backup"
        return 0
    fi
    
    log "Running containers: $(echo "$running_containers" | tr '\n' ', ' | sed 's/,$//')"
    
    log "Stopping stack: $stack_name"
    if ! (cd "$stack_path" && docker compose down); then
        log_error "Failed to stop stack $stack_name"
        return 1
    fi
    
    log "Creating backup: $backup_file"
    
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
    log "Creating ${COMPRESSION_METHOD} compressed backup (level ${COMPRESSION_LEVEL})..."
    if [[ "$USE_PARALLEL" == true ]]; then
        log "Using parallel compression"
    fi
    
    if create_compressed_archive "$backup_file" \
        -C "$temp_dir" . \
        -C "$APPDATA_PATH" "$stack_name" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Backup created: $backup_file"
    else
        log_error "Failed to create backup for $stack_name"
        # Restore only previously running containers
        if [[ -n "$running_containers" ]]; then
            log "Restoring previously running containers"
            (cd "$stack_path" && docker compose up -d $running_containers)
        fi
        return 1
    fi
    
    # Start only the containers that were running before
    # Docker Compose will automatically start any dependencies even if they weren't running
    if [[ -n "$running_containers" ]]; then
        log "Starting previously running containers: $(echo "$running_containers" | tr '\n' ', ' | sed 's/,$//')"
        log "(Docker Compose will auto-start any dependencies as needed)"
        
        if ! restart_stack_with_retry "$stack_path" "$running_containers"; then
            # restart_stack_with_retry already logged and notified
            return 1
        fi
    else
        log "No containers to restart (none were running before backup)"
    fi
    
    # Run any configured post-restart hooks (non-fatal on hook failure)
    run_post_restart_hooks "$stack_name" "$stack_path"
    
    log_success "Stack $stack_name backed up and restarted successfully"
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
                echo "Options:"
                echo "  --dry-run, -n    Simulate backup without making changes"
                echo "  --help, -h       Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0                Run backup normally"
                echo "  $0 --dry-run      Show what would be backed up"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BOLD}${CYAN}=========================================${NC}"
        echo -e "${BOLD}${CYAN}DRY RUN MODE - No changes will be made${NC}"
        echo -e "${BOLD}${CYAN}=========================================${NC}\n"
    fi
    
    log "========================================="
    if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN: Docker stack backup simulation"
    else
        log "Starting Docker stack backup"
    fi
    log "Hostname: $HOSTNAME"
    log "OS: $OS_NAME ($OS_TYPE)"
    log "========================================="
    
    # Require root, unless ELEVATION_CMD is configured to elevate archive creation
    if ! require_privileged_or_elevated; then
        exit 1
    fi
    
    # Acquire lock to prevent concurrent runs (skip in dry-run)
    if [[ "$DRY_RUN" != true ]]; then
        acquire_lock
    fi
    
    # Run pre-flight checks
    if ! run_preflight_checks; then
        log_error "Pre-flight checks failed, aborting"
        exit 1
    fi
    
    # Counter for statistics
    local total_stacks=0
    local backed_up=0
    local skipped=0
    local failed=0
    local total_size=0
    
    # Get stack base directory
    local stack_base; stack_base=$(dockhand_stack_base)
    
    # Dry-run mode
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}Stacks that would be backed up:${NC}\n"
        
        # Collect skip list
        local -a skip_list
        
        for stack_path in "$stack_base"/*; do
            if [[ ! -d "$stack_path" ]]; then
                continue
            fi
            
            # Check if stack has a compose file
            local compose_file; compose_file=$(find_compose_file "$stack_path") || true
            if [[ -z "$compose_file" ]]; then
                continue
            fi
            
            total_stacks=$((total_stacks + 1))
            if simulate_backup_stack "$stack_path"; then
                backed_up=$((backed_up + 1))
                if [[ -f /tmp/stack_size_$$ ]]; then
                    local stack_size; stack_size=$(cat /tmp/stack_size_$$)
                    total_size=$((total_size + stack_size))
                    rm -f /tmp/stack_size_$$
                fi
            else
                local stack_name; stack_name=$(basename "$stack_path")
                
                # Only add to skip list if it has a compose file but no appdata
                local compose_file; compose_file=$(find_compose_file "$stack_path") || true
                if [[ -n "$compose_file" ]]; then
                    skip_list+=("$stack_name")
                fi
                
                skipped=$((skipped + 1))
            fi
        done
        
        if [[ ${#skip_list[@]} -gt 0 ]]; then
            echo -e "\n${YELLOW}Would skip (no appdata):${NC}\n"
            for stack_name in "${skip_list[@]}"; do
                echo "  ${YELLOW}○${NC} $stack_name"
            done
        fi
        
        local total_size_human; total_size_human=$(numfmt --to=iec-i --suffix=B $total_size 2>/dev/null || echo "${total_size} bytes")
        local backup_ext; backup_ext=$(get_compression_extension)
        
        echo -e "\n${CYAN}=========================================${NC}"
        echo -e "${BOLD}Summary:${NC}"
        echo "  Total stacks found: $total_stacks"
        echo "  Would backup: ${GREEN}$backed_up${NC}"
        echo "  Would skip: ${YELLOW}$skipped${NC}"
        echo ""
        echo "  Estimated backup size: ${BOLD}$total_size_human${NC}"
        echo "  Compression method: ${COMPRESSION_METHOD}"
        echo "  Backup extension: ${backup_ext}"
        echo ""
        
        # Check if there's enough space
        local available_kb; available_kb=$(df -k "$BACKUP_DEST" | awk 'NR==2 {print $4}')
        local available_bytes; available_bytes=$((available_kb * 1024))
        local available_human; available_human=$(numfmt --to=iec-i --suffix=B $available_bytes)
        
        echo "  Space available: ${available_human}"
        
        if [[ $available_bytes -gt $total_size ]]; then
            echo -e "  ${GREEN}✓ Sufficient space available${NC}"
        else
            echo -e "  ${RED}✗ Insufficient space!${NC}"
        fi
        
        echo -e "${CYAN}=========================================${NC}\n"
        echo -e "${BOLD}${GREEN}DRY RUN COMPLETE - No actions taken${NC}\n"
        
        log "========================================="
        log "Dry run complete"
        log "Would backup: $backed_up stacks"
        log "Estimated size: $total_size_human"
        log "========================================="
        
        return 0
    fi
    
    # Normal backup mode
    
    # Iterate through all stacks
    for stack_path in "$stack_base"/*; do
        if [[ ! -d "$stack_path" ]]; then
            continue
        fi
        
        # Check if stack has a compose file
        local compose_file; compose_file=$(find_compose_file "$stack_path") || true
        if [[ -z "$compose_file" ]]; then
            continue
        fi
        
        total_stacks=$((total_stacks + 1))
        
        local result=0
        backup_stack "$stack_path" || result=$?
        
        if [[ $result -eq 0 ]]; then
            # Successfully backed up
            backed_up=$((backed_up + 1))
        elif [[ $result -eq 2 ]]; then
            # Skipped (no appdata)
            skipped=$((skipped + 1))
        else
            # Failed
            failed=$((failed + 1))
        fi
    done
    
    log "========================================="
    log "Backup Summary:"
    log "Total stacks found: $total_stacks"
    log "Successfully backed up: $backed_up"
    log "Skipped (no appdata): $skipped"
    log "Failed: $failed"
    log "========================================="
    
    # Send notifications
    if [[ $failed -gt 0 ]]; then
        send_notifications "failure" "$backed_up" "$skipped" "$failed" "$total_stacks"
        exit 1
    else
        send_notifications "success" "$backed_up" "$skipped" "$failed" "$total_stacks"
    fi
}

# Run main function
main "$@"
