#!/bin/bash

#######################################
# Docker Compose Stack Backup Script
# Backs up Docker Compose stacks that have appdata bind mounts
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
        
        # Detect specific distributions
        case "$OS_ID" in
            debian)
                OS_TYPE="debian"
                ;;
            ubuntu)
                OS_TYPE="ubuntu"
                ;;
            scale|truenas)
                OS_TYPE="truenas"
                ;;
            proxmox)
                OS_TYPE="proxmox"
                ;;
            *)
                # Check if it's TrueNAS by other means
                if [[ -f /etc/version ]] && grep -q "TrueNAS" /etc/version 2>/dev/null; then
                    OS_TYPE="truenas"
                # Debian-based fallback
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
    
    export OS_TYPE OS_NAME OS_ID OS_VERSION
}

# Detect OS on script start
detect_os

# Dry-run mode flag
DRY_RUN=false

# Configuration
DOCKHAND_BASE="/opt/dockhand/stacks"  # Base path where Dockhand stores stacks (hostname will be appended)
HOSTNAME=$(hostname)
APPDATA_PATH="/mnt/datastor/appdata"  # Path where stack appdata is stored
BACKUP_DEST="/mnt/backup/docker-backups"  # Destination on TrueNAS
LOG_FILE="/var/log/docker-backup.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Compression Configuration
COMPRESSION_METHOD="none"     # Options: gzip, bzip2, xz, zstd, none
COMPRESSION_LEVEL=6           # 1-9: 1=fastest/largest, 9=slowest/smallest (for gzip/bzip2/xz)
USE_PARALLEL=false            # Use parallel compression (pigz/pbzip2/pxz) - faster on multi-core systems
PARALLEL_THREADS=0            # 0=auto-detect cores, or specify number (e.g., 4)
# Exclude patterns (relative to appdata directory)
EXCLUDE_PATTERNS=(
    # "*/cache/*"
    # "*/tmp/*"
    # "*.log"
    # "*/Trash/*"
)

# Notification Configuration
NOTIFY_ON_SUCCESS=true   # Send notification when backup succeeds
NOTIFY_ON_FAILURE=true   # Send notification when backup fails

# Ntfy (https://ntfy.sh)
NTFY_ENABLED=false
NTFY_URL="https://ntfy.sh"  # Use your own server or ntfy.sh
NTFY_TOPIC="docker-backups"  # Your topic name
NTFY_PRIORITY="default"  # min, low, default, high, urgent
NTFY_TOKEN=""  # Optional: for authenticated topics

# Pushover (https://pushover.net)
PUSHOVER_ENABLED=false
PUSHOVER_USER_KEY=""  # Your user key
PUSHOVER_API_TOKEN=""  # Your application API token
PUSHOVER_PRIORITY=0  # -2=lowest, -1=low, 0=normal, 1=high, 2=emergency

# Email
EMAIL_ENABLED=false
EMAIL_TO=""  # Destination email address
EMAIL_FROM="docker-backup@$HOSTNAME"  # From address
EMAIL_SUBJECT_PREFIX="[Docker Backup]"  # Subject line prefix
# Email method: 'sendmail' or 'smtp'
EMAIL_METHOD="sendmail"
# SMTP settings (only needed if EMAIL_METHOD="smtp")
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASSWORD=""
SMTP_USE_TLS=true
SMTP_INSECURE=false  # Set to true for self-signed certificates (e.g., Proton Mail Bridge)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

#######################################
# Logging functions
#######################################
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

#######################################
# File locking functions
#######################################
LOCK_FILE="/var/run/docker-stack-backup.lock"
LOCK_FD=200

acquire_lock() {
    eval "exec $LOCK_FD>$LOCK_FILE"
    
    if ! flock -n $LOCK_FD; then
        log_error "Another backup is already running (lock file: $LOCK_FILE)"
        log_error "If you're sure no backup is running, remove: $LOCK_FILE"
        exit 1
    fi
    
    # Write PID to lock file
    echo $$ >&$LOCK_FD
    log "Lock acquired (PID: $$)"
}

release_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u $LOCK_FD 2>/dev/null || true
        rm -f "$LOCK_FILE" 2>/dev/null || true
        log "Lock released"
    fi
}

# Ensure lock is released on exit
trap release_lock EXIT INT TERM

#######################################
# Pre-flight checks
#######################################
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
    local stack_base="$DOCKHAND_BASE/$HOSTNAME"
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

#######################################
# Improved restart error handling
#######################################
MAX_RESTART_ATTEMPTS=3
RESTART_RETRY_DELAY=5  # seconds

restart_stack_with_retry() {
    local stack_path="$1"
    local stack_name; stack_name=$(basename "$stack_path")
    local running_containers="$2"
    local attempt=1
    
    while [[ $attempt -le $MAX_RESTART_ATTEMPTS ]]; do
        log "Starting containers (attempt $attempt/$MAX_RESTART_ATTEMPTS)..."
        
        if (cd "$stack_path" && docker compose up -d $running_containers 2>&1 | tee -a "$LOG_FILE"); then
            # Verify containers actually started
            sleep 2
            local started_count; started_count=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l)
            local expected_count; expected_count=$(echo "$running_containers" | wc -w)
            
            if [[ $started_count -eq $expected_count ]]; then
                log_success "All containers started successfully"
                return 0
            else
                log_warning "Only $started_count of $expected_count containers started"
            fi
        fi
        
        if [[ $attempt -lt $MAX_RESTART_ATTEMPTS ]]; then
            log_warning "Restart failed, waiting ${RESTART_RETRY_DELAY}s before retry..."
            sleep $RESTART_RETRY_DELAY
        fi
        
        ((attempt++))
    done
    
    log_error "Failed to restart stack after $MAX_RESTART_ATTEMPTS attempts"
    log_error "Stack: $stack_name"
    log_error "Containers that should be running: $running_containers"
    log_error "Manual intervention required!"
    log_error "To restart manually: cd $stack_path && docker compose up -d $running_containers"
    
    # Send immediate critical notification
    send_critical_restart_failure "$stack_name" "$stack_path" "$running_containers"
    
    return 1
}

send_critical_restart_failure() {
    local stack_name="$1"
    local stack_path="$2"
    local containers="$3"
    
    local title="CRITICAL: Stack Failed to Restart - $HOSTNAME"
    local message="Stack '$stack_name' failed to restart after backup!

⚠️  IMMEDIATE ACTION REQUIRED ⚠️

Stack: $stack_name
Host: $HOSTNAME
Containers: $containers

Manual restart command:
cd $stack_path && docker compose up -d $containers

Check logs:
$LOG_FILE"
    
    # Send with high priority regardless of normal settings
    if [[ "$NTFY_ENABLED" == true ]]; then
        send_ntfy "$title" "$message" "urgent" "warning,backup"
    fi
    
    if [[ "$PUSHOVER_ENABLED" == true ]]; then
        send_pushover "$title" "$message" 1  # High priority
    fi
    
    if [[ "$EMAIL_ENABLED" == true ]]; then
        send_email "[CRITICAL] $title" "$message"
    fi
}

#######################################
# Notification functions
#######################################
send_ntfy() {
    if [[ "$NTFY_ENABLED" != true ]]; then
        return 0
    fi
    
    local title="$1"
    local message="$2"
    local priority="${3:-$NTFY_PRIORITY}"
    local tags="${4:-backup}"
    
    local curl_args=(
        -X POST
        -H "Title: $title"
        -H "Priority: $priority"
        -H "Tags: $tags"
        -d "$message"
    )
    
    if [[ -n "$NTFY_TOKEN" ]]; then
        curl_args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    fi
    
    if ! curl -s "${curl_args[@]}" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1; then
        log_error "Failed to send Ntfy notification"
    fi
}

send_pushover() {
    if [[ "$PUSHOVER_ENABLED" != true ]]; then
        return 0
    fi
    
    if [[ -z "$PUSHOVER_USER_KEY" ]] || [[ -z "$PUSHOVER_API_TOKEN" ]]; then
        log_error "Pushover enabled but USER_KEY or API_TOKEN not configured"
        return 1
    fi
    
    local title="$1"
    local message="$2"
    local priority="${3:-$PUSHOVER_PRIORITY}"
    
    if ! curl -s \
        --form-string "token=$PUSHOVER_API_TOKEN" \
        --form-string "user=$PUSHOVER_USER_KEY" \
        --form-string "title=$title" \
        --form-string "message=$message" \
        --form-string "priority=$priority" \
        https://api.pushover.net/1/messages.json >/dev/null 2>&1; then
        log_error "Failed to send Pushover notification"
    fi
}

send_email_sendmail() {
    local subject="$1"
    local body="$2"
    
    if ! command -v sendmail &> /dev/null; then
        log_error "sendmail not found. Install with: apt-get install sendmail or postfix"
        return 1
    fi
    
    (
        echo "To: $EMAIL_TO"
        echo "From: $EMAIL_FROM"
        echo "Subject: $subject"
        echo ""
        echo "$body"
    ) | sendmail -t
}

send_email_smtp() {
    local subject="$1"
    local body="$2"
    
    if ! command -v curl &> /dev/null; then
        log_error "curl not found for SMTP email"
        return 1
    fi
    
    local smtp_url="smtp://$SMTP_SERVER:$SMTP_PORT"
    if [[ "$SMTP_USE_TLS" == true ]]; then
        smtp_url="smtps://$SMTP_SERVER:$SMTP_PORT"
    fi
    
    local email_content; email_content=$(cat <<EOF
From: $EMAIL_FROM
To: $EMAIL_TO
Subject: $subject

$body
EOF
)
    
    local curl_args=(
        --url "$smtp_url"
        --mail-from "$EMAIL_FROM"
        --mail-rcpt "$EMAIL_TO"
        --upload-file -
    )
    
    # Add authentication if credentials provided
    if [[ -n "$SMTP_USER" ]] && [[ -n "$SMTP_PASSWORD" ]]; then
        curl_args+=(--user "$SMTP_USER:$SMTP_PASSWORD")
    fi
    
    # Handle self-signed certificates
    if [[ "${SMTP_INSECURE:-false}" == true ]]; then
        curl_args+=(--insecure)
    fi
    
    if ! echo "$email_content" | curl -s "${curl_args[@]}" >/dev/null 2>&1; then
        log_error "Failed to send email via SMTP"
        return 1
    fi
}

send_email() {
    if [[ "$EMAIL_ENABLED" != true ]]; then
        return 0
    fi
    
    if [[ -z "$EMAIL_TO" ]]; then
        log_error "Email enabled but EMAIL_TO not configured"
        return 1
    fi
    
    local subject="$1"
    local body="$2"
    
    case "$EMAIL_METHOD" in
        sendmail)
            send_email_sendmail "$subject" "$body"
            ;;
        smtp)
            send_email_smtp "$subject" "$body"
            ;;
        *)
            log_error "Unknown email method: $EMAIL_METHOD"
            return 1
            ;;
    esac
}

send_notifications() {
    local status="$1"  # "success" or "failure"
    local backed_up="$2"
    local skipped="$3"
    local failed="$4"
    local total="$5"
    
    # Check if we should send notification
    if [[ "$status" == "success" ]] && [[ "$NOTIFY_ON_SUCCESS" != true ]]; then
        return 0
    fi
    
    if [[ "$status" == "failure" ]] && [[ "$NOTIFY_ON_FAILURE" != true ]]; then
        return 0
    fi
    
    # Build notification content
    local title
    local message
    local priority
    local tags
    
    if [[ "$status" == "success" ]]; then
        title="Docker Backup Complete - $HOSTNAME"
        priority="default"
        tags="white_check_mark,backup"
        message="Backup completed successfully

✓ Successfully backed up: $backed_up
⊘ Skipped (no appdata): $skipped
✗ Failed: $failed
━━━━━━━━━━━━━━━━━━━━
Total stacks: $total
Host: $HOSTNAME
Time: $(date +'%Y-%m-%d %H:%M:%S')"
    else
        title="Docker Backup FAILED - $HOSTNAME"
        priority="high"
        tags="x,backup,warning"
        message="Backup completed with errors

✓ Successfully backed up: $backed_up
⊘ Skipped (no appdata): $skipped
✗ FAILED: $failed
━━━━━━━━━━━━━━━━━━━━
Total stacks: $total
Host: $HOSTNAME
Time: $(date +'%Y-%m-%d %H:%M:%S')

Check logs: $LOG_FILE"
    fi
    
    # Send to all enabled services
    send_ntfy "$title" "$message" "$priority" "$tags"
    send_pushover "$title" "$message" "$([ "$status" == "failure" ] && echo 1 || echo 0)"
    send_email "$EMAIL_SUBJECT_PREFIX $title" "$message"
}

#######################################
# Compression functions
#######################################
get_compression_extension() {
    case "$COMPRESSION_METHOD" in
        gzip)   echo ".tar.gz" ;;
        bzip2)  echo ".tar.bz2" ;;
        xz)     echo ".tar.xz" ;;
        zstd)   echo ".tar.zst" ;;
        none)   echo ".tar" ;;
        *)      echo ".tar.gz" ;;
    esac
}

get_tar_compression_flag() {
    if [[ "$USE_PARALLEL" == true ]]; then
        echo ""  # We'll handle compression separately with parallel tools
    else
        case "$COMPRESSION_METHOD" in
            gzip)   echo "z" ;;
            bzip2)  echo "j" ;;
            xz)     echo "J" ;;
            zstd)   echo "--zstd" ;;
            none)   echo "" ;;
            *)      echo "z" ;;
        esac
    fi
}

check_compression_tool() {
    local tool="$1"
    if ! command -v "$tool" &> /dev/null; then
        log_warning "$tool not found. Install with: apt-get install $tool"
        return 1
    fi
    return 0
}

setup_compression_environment() {
    # Set compression level environment variable
    case "$COMPRESSION_METHOD" in
        gzip)
            export GZIP="-${COMPRESSION_LEVEL}"
            ;;
        bzip2)
            export BZIP2="-${COMPRESSION_LEVEL}"
            ;;
        xz)
            export XZ_OPT="-${COMPRESSION_LEVEL}"
            ;;
    esac
}

create_compressed_archive() {
    local output_file="$1"
    shift
    local tar_args=("$@")
    
    setup_compression_environment
    
    # Build exclude arguments
    local exclude_args=()
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args+=(--exclude="$pattern")
    done
    
    if [[ "$USE_PARALLEL" == true ]]; then
        # Use parallel compression
        local compressor=""
        local compressor_args=()
        
        case "$COMPRESSION_METHOD" in
            gzip)
                if check_compression_tool pigz; then
                    compressor="pigz"
                    compressor_args=("-${COMPRESSION_LEVEL}")
                    if [[ $PARALLEL_THREADS -gt 0 ]]; then
                        compressor_args+=("-p" "$PARALLEL_THREADS")
                    fi
                else
                    log_warning "pigz not found, falling back to standard gzip"
                    USE_PARALLEL=false
                fi
                ;;
            bzip2)
                if check_compression_tool pbzip2; then
                    compressor="pbzip2"
                    compressor_args=("-${COMPRESSION_LEVEL}")
                    if [[ $PARALLEL_THREADS -gt 0 ]]; then
                        compressor_args+=("-p${PARALLEL_THREADS}")
                    fi
                else
                    log_warning "pbzip2 not found, falling back to standard bzip2"
                    USE_PARALLEL=false
                fi
                ;;
            xz)
                if check_compression_tool pxz; then
                    compressor="pxz"
                    compressor_args=("-${COMPRESSION_LEVEL}")
                    if [[ $PARALLEL_THREADS -gt 0 ]]; then
                        compressor_args+=("-T${PARALLEL_THREADS}")
                    fi
                else
                    log_warning "pxz not found, falling back to standard xz"
                    USE_PARALLEL=false
                fi
                ;;
            zstd)
                if check_compression_tool zstd; then
                    compressor="zstd"
                    compressor_args=("-${COMPRESSION_LEVEL}")
                    if [[ $PARALLEL_THREADS -gt 0 ]]; then
                        compressor_args+=("-T${PARALLEL_THREADS}")
                    fi
                else
                    log_error "zstd not found"
                    return 1
                fi
                ;;
            none)
                # No compression needed
                tar -cf "$output_file" "${exclude_args[@]}" "${tar_args[@]}"
                return $?
                ;;
        esac
        
        if [[ "$USE_PARALLEL" == true ]] && [[ -n "$compressor" ]]; then
            tar -c "${exclude_args[@]}" "${tar_args[@]}" | "$compressor" "${compressor_args[@]}" > "$output_file"
            return $?
        fi
    fi
    
    # Fall back to standard tar compression
    local compression_flag; compression_flag=$(get_tar_compression_flag)
    
    if [[ "$compression_flag" == "--zstd" ]]; then
        # zstd uses different syntax
        if ! check_compression_tool zstd; then
            log_error "zstd compression selected but zstd not found"
            return 1
        fi
        tar -c $compression_flag -f "$output_file" "${exclude_args[@]}" "${tar_args[@]}"
    elif [[ -n "$compression_flag" ]]; then
        tar -c${compression_flag}f "$output_file" "${exclude_args[@]}" "${tar_args[@]}"
    else
        tar -cf "$output_file" "${exclude_args[@]}" "${tar_args[@]}"
    fi
    
    return $?
}

#######################################
# Check if stack has appdata bind mounts
#######################################
#######################################
# Check if stack has appdata bind mounts
#######################################
find_compose_file() {
    local stack_path="$1"
    
    # Check for various compose file names (in order of preference)
    local possible_names=(
        "compose.yaml"
        "compose.yml"
        "docker-compose.yaml"
        "docker-compose.yml"
    )
    
    for name in "${possible_names[@]}"; do
        if [[ -f "$stack_path/$name" ]]; then
            echo "$stack_path/$name"
            return 0
        fi
    done
    
    return 1
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
    local compose_file; compose_file=$(find_compose_file "$stack_path")
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
    local compose_file; compose_file=$(find_compose_file "$stack_path")
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
    
    # Check if directory has any content (direct files or subdirectories)
    if [[ -z "$(ls -A "$appdata_dir" 2>/dev/null)" ]]; then
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
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
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
    local stack_base="$DOCKHAND_BASE/$HOSTNAME"
    
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
            local compose_file; compose_file=$(find_compose_file "$stack_path")
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
                local compose_file; compose_file=$(find_compose_file "$stack_path")
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
        local compose_file; compose_file=$(find_compose_file "$stack_path")
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
