#!/bin/bash

#######################################
# Docker Stack Manual Backup Script
# Interactive backup of selected Docker Compose stacks
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
LOG_FILE="/var/log/docker-backup-manual.log"
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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
# UI Helper functions
#######################################
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

#######################################
# File locking functions
#######################################
LOCK_FILE="/var/run/docker-stack-backup-manual.lock"
LOCK_FD=200

acquire_lock() {
    eval "exec $LOCK_FD>$LOCK_FILE"
    
    if ! flock -n $LOCK_FD; then
        log_error "Another backup is already running (lock file: $LOCK_FILE)"
        log_error "If you're sure no backup is running, remove: $LOCK_FILE"
        exit 1
    fi
    
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

trap release_lock EXIT INT TERM

#######################################
# Pre-flight checks
#######################################
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
    
    local available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))
    
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
    
    local stack_base="$DOCKHAND_BASE/$HOSTNAME"
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
        local available_kb=$(df -k "$BACKUP_DEST" | awk 'NR==2 {print $4}')
        local available_gb=$((available_kb / 1024 / 1024))
        echo -e "${GREEN}✓${NC} Disk space: ${available_gb}GB available"
    fi
    
    if [[ "$checks_passed" == false ]]; then
        echo -e "\n${RED}Pre-flight checks failed!${NC}\n"
        return 1
    fi
    
    echo -e "\n${GREEN}✓ All checks passed${NC}\n"
    return 0
}

#######################################
# Improved restart handling
#######################################
MAX_RESTART_ATTEMPTS=3
RESTART_RETRY_DELAY=5

restart_stack_with_retry() {
    local stack_path="$1"
    local stack_name=$(basename "$stack_path")
    local running_containers="$2"
    local attempt=1
    
    while [[ $attempt -le $MAX_RESTART_ATTEMPTS ]]; do
        echo "  └─ Starting containers (attempt $attempt/$MAX_RESTART_ATTEMPTS)..."
        
        if (cd "$stack_path" && docker compose up -d $running_containers 2>&1 | sed 's/^/     /'); then
            sleep 2
            local started_count=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l)
            local expected_count=$(echo "$running_containers" | wc -w)
            
            if [[ $started_count -eq $expected_count ]]; then
                echo -e "  └─ ${GREEN}✓${NC} All containers started"
                return 0
            else
                echo -e "  └─ ${YELLOW}⚠${NC} Only $started_count of $expected_count started"
            fi
        fi
        
        if [[ $attempt -lt $MAX_RESTART_ATTEMPTS ]]; then
            echo "  └─ Waiting ${RESTART_RETRY_DELAY}s before retry..."
            sleep $RESTART_RETRY_DELAY
        fi
        
        ((attempt++))
    done
    
    echo -e "  └─ ${RED}✗${NC} Failed to restart after $MAX_RESTART_ATTEMPTS attempts"
    log_error "Stack $stack_name failed to restart"
    log_error "Manual command: cd $stack_path && docker compose up -d $running_containers"
    
    return 1
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
    local compression_flag=$(get_tar_compression_flag)
    
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
    local stack_name=$(basename "$stack_path")
    local compose_file="$stack_path/docker-compose.yml"
    
    local info=""
    
    # Check if has appdata
    if stack_has_appdata "$compose_file"; then
        local appdata_dir="$APPDATA_PATH/$stack_name"
        if [[ -d "$appdata_dir" ]]; then
            local size=$(du -sh "$appdata_dir" 2>/dev/null | cut -f1)
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
        running_count=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l)
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
    
    local stack_base="$DOCKHAND_BASE/$HOSTNAME"
    
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
        
        local stack_name=$(basename "$stack_path")
        local compose_file="$stack_path/docker-compose.yml"
        
        if [[ ! -f "$compose_file" ]]; then
            continue
        fi
        
        stack_list["$i"]="$stack_path"
        stack_names+=("$stack_name")
        
        local info=$(get_stack_info "$stack_path")
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
    
    local selection=$(prompt_input "Your selection")
    
    # Parse selection
    selected_stacks=()
    
    if [[ "$selection" == "all" ]]; then
        for idx in "${!stack_list[@]}"; do
            local stack_path="${stack_list[$idx]}"
            if stack_has_appdata "$stack_path/docker-compose.yml"; then
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
        local stack_name=$(basename "$stack_path")
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
        local stack_name=$(basename "$stack_path")
        local compose_file="$stack_path/docker-compose.yml"
        
        echo -e "${BOLD}$stack_name${NC}"
        
        # Check appdata
        if stack_has_appdata "$compose_file"; then
            ((stacks_with_appdata++))
            local appdata_dir="$APPDATA_PATH/$stack_name"
            if [[ -d "$appdata_dir" ]]; then
                local size_bytes=$(du -sb "$appdata_dir" 2>/dev/null | cut -f1)
                local size_human=$(du -sh "$appdata_dir" 2>/dev/null | cut -f1)
                ((total_size+=size_bytes))
                echo "  └─ Appdata: $size_human"
            else
                log_warning "  └─ Appdata directory not found (will skip)"
            fi
        else
            log_warning "  └─ No appdata (will skip)"
        fi
        
        # Check running containers
        local running=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l)
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
    local stack_name=$(basename "$stack_path")
    local compose_file="$stack_path/docker-compose.yml"
    
    echo -e "\n${CYAN}▶ Backing up: ${BOLD}$stack_name${NC}"
    
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
    
    local backup_ext=$(get_compression_extension)
    local backup_file="$backup_dir/${stack_name}${backup_ext}"
    
    # Get list of running containers before stopping
    local running_containers=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null || true)
    
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
    local temp_dir=$(mktemp -d)
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
        local backup_size=$(du -sh "$backup_file" | cut -f1)
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
            local stack_name=$(basename "$stack_path")
            local appdata_dir="$APPDATA_PATH/$stack_name"
            
            if [[ -d "$appdata_dir" ]]; then
                local size=$(du -sh "$appdata_dir" 2>/dev/null | cut -f1)
                local size_bytes=$(du -sb "$appdata_dir" 2>/dev/null | cut -f1)
                ((total_size+=size_bytes))
                
                local running_count=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null | wc -l)
                
                if [[ $running_count -gt 0 ]]; then
                    echo -e "  ${GREEN}✓${NC} $stack_name ($size, $running_count running)"
                else
                    echo -e "  ${YELLOW}○${NC} $stack_name ($size, stopped)"
                fi
            fi
        done
        
        local total_size_human=$(numfmt --to=iec-i --suffix=B $total_size 2>/dev/null || echo "${total_size} bytes")
        
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
            local stack_name=$(basename "$stack_path")
            if stack_has_appdata "$stack_path/docker-compose.yml" && [[ -d "$APPDATA_PATH/$stack_name" ]]; then
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
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
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
