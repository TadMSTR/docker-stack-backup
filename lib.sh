#!/bin/bash

#######################################
# Shared library for docker-stack-backup scripts
# Source this file; do not execute directly.
#######################################

[[ "${BASH_SOURCE[0]}" == "$0" ]] && echo "lib.sh: source this file, do not execute directly" && exit 1

#######################################
# OS Detection
#######################################
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        OS_VERSION="${VERSION_ID:-}"

        case "$OS_ID" in
            debian)      OS_TYPE="debian" ;;
            ubuntu)      OS_TYPE="ubuntu" ;;
            scale|truenas) OS_TYPE="truenas" ;;
            proxmox)     OS_TYPE="proxmox" ;;
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
        OS_VERSION=""
    fi

    export OS_TYPE OS_NAME OS_ID OS_VERSION
}

#######################################
# Colors (initialized before log_* calls)
#######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
# shellcheck disable=SC2034  # used in sourcing scripts
BLUE='\033[0;34m'
# shellcheck disable=SC2034
CYAN='\033[0;36m'
# shellcheck disable=SC2034
BOLD='\033[1m'
NC='\033[0m'

#######################################
# Logging functions
# Requires: LOG_FILE to be set by caller
#######################################
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE:-/dev/stderr}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE:-/dev/stderr}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE:-/dev/stderr}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "${LOG_FILE:-/dev/stderr}"
}

#######################################
# File locking
# Requires: LOCK_FILE, LOCK_FD to be set by caller
#######################################
acquire_lock() {
    [[ "${LOCK_FD:-200}" =~ ^[0-9]+$ ]] || LOCK_FD=200
    eval "exec ${LOCK_FD:=200}>${LOCK_FILE:=/var/run/docker-stack-backup.lock}"

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
        rm -f "${LOCK_FILE:-}" 2>/dev/null || true
        log "Lock released"
    fi
}

#######################################
# Restart with retry
# Requires: MAX_RESTART_ATTEMPTS, RESTART_RETRY_DELAY, LOG_FILE
#######################################
MAX_RESTART_ATTEMPTS=3
RESTART_RETRY_DELAY=5

restart_stack_with_retry() {
    local stack_path="$1"
    local stack_name; stack_name=$(basename "$stack_path")
    local running_containers="$2"
    local attempt=1

    while [[ $attempt -le $MAX_RESTART_ATTEMPTS ]]; do
        log "Starting containers (attempt $attempt/$MAX_RESTART_ATTEMPTS)..."

        if (cd "$stack_path" && docker compose up -d $running_containers 2>&1 | tee -a "$LOG_FILE"); then
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

    send_critical_restart_failure "$stack_name" "$stack_path" "$running_containers"

    return 1
}

#######################################
# Notification functions
# Requires: NTFY_*, PUSHOVER_*, EMAIL_*, MATRIX_* vars, HOSTNAME, LOG_FILE
#######################################
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

    if [[ "${NTFY_ENABLED:-false}" == true ]]; then
        send_ntfy "$title" "$message" "urgent" "warning,backup"
    fi

    if [[ "${PUSHOVER_ENABLED:-false}" == true ]]; then
        send_pushover "$title" "$message" 1
    fi

    if [[ "${EMAIL_ENABLED:-false}" == true ]]; then
        send_email "[CRITICAL] $title" "$message"
    fi

    if [[ "${MATRIX_ENABLED:-false}" == true ]]; then
        send_matrix "$title" "$message"
    fi
}

send_ntfy() {
    [[ "${NTFY_ENABLED:-false}" != true ]] && return 0

    local title="$1"
    local message="$2"
    local priority="${3:-${NTFY_PRIORITY:-default}}"
    local tags="${4:-backup}"

    local curl_args=(
        -X POST
        -H "Title: $title"
        -H "Priority: $priority"
        -H "Tags: $tags"
        -d "$message"
    )

    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        curl_args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    fi

    if ! curl -s "${curl_args[@]}" "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC:-docker-backups}" >/dev/null 2>&1; then
        log_error "Failed to send Ntfy notification"
    fi
}

send_pushover() {
    [[ "${PUSHOVER_ENABLED:-false}" != true ]] && return 0

    if [[ -z "${PUSHOVER_USER_KEY:-}" ]] || [[ -z "${PUSHOVER_API_TOKEN:-}" ]]; then
        log_error "Pushover enabled but USER_KEY or API_TOKEN not configured"
        return 1
    fi

    local title="$1"
    local message="$2"
    local priority="${3:-${PUSHOVER_PRIORITY:-0}}"

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
        echo "From: ${EMAIL_FROM:-docker-backup@$(hostname)}"
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

    local smtp_url="smtp://${SMTP_SERVER:-smtp.gmail.com}:${SMTP_PORT:-587}"
    if [[ "${SMTP_USE_TLS:-true}" == true ]]; then
        smtp_url="smtps://${SMTP_SERVER:-smtp.gmail.com}:${SMTP_PORT:-587}"
    fi

    local email_content; email_content=$(cat <<EOF
From: ${EMAIL_FROM:-docker-backup@$(hostname)}
To: $EMAIL_TO
Subject: $subject

$body
EOF
)

    local curl_args=(
        --url "$smtp_url"
        --mail-from "${EMAIL_FROM:-docker-backup@$(hostname)}"
        --mail-rcpt "$EMAIL_TO"
        --upload-file -
    )

    if [[ -n "${SMTP_USER:-}" ]] && [[ -n "${SMTP_PASSWORD:-}" ]]; then
        curl_args+=(--user "$SMTP_USER:$SMTP_PASSWORD")
    fi

    if [[ "${SMTP_INSECURE:-false}" == true ]]; then
        curl_args+=(--insecure)
    fi

    if ! echo "$email_content" | curl -s "${curl_args[@]}" >/dev/null 2>&1; then
        log_error "Failed to send email via SMTP"
        return 1
    fi
}

send_email() {
    [[ "${EMAIL_ENABLED:-false}" != true ]] && return 0

    if [[ -z "${EMAIL_TO:-}" ]]; then
        log_error "Email enabled but EMAIL_TO not configured"
        return 1
    fi

    local subject="$1"
    local body="$2"

    case "${EMAIL_METHOD:-sendmail}" in
        sendmail) send_email_sendmail "$subject" "$body" ;;
        smtp)     send_email_smtp "$subject" "$body" ;;
        *)        log_error "Unknown email method: ${EMAIL_METHOD}"; return 1 ;;
    esac
}

send_matrix() {
    [[ "${MATRIX_ENABLED:-false}" != true ]] && return 0

    if [[ -z "${MATRIX_ACCESS_TOKEN:-}" ]] || [[ -z "${MATRIX_ROOM_ID:-}" ]] || [[ -z "${MATRIX_HOMESERVER:-}" ]]; then
        log_error "Matrix enabled but MATRIX_ACCESS_TOKEN, MATRIX_ROOM_ID, or MATRIX_HOMESERVER not set"
        return 1
    fi

    local title="$1"
    local message="$2"
    local txn_id; txn_id="backup-$$-$(date +%s)"
    local encoded_room

    if command -v python3 &>/dev/null; then
        encoded_room=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$MATRIX_ROOM_ID")
    else
        encoded_room=$(printf '%s' "$MATRIX_ROOM_ID" | sed 's/!/%21/g; s/:/%3A/g')
    fi

    local body_text="${title}"$'\n\n'"${message}"
    local body_html="<b>${title}</b><br><pre>${message}</pre>"
    local payload
    if command -v python3 &>/dev/null; then
        payload=$(python3 -c "
import json, sys
title, message = sys.argv[1], sys.argv[2]
body_text = title + '\n\n' + message
body_html = '<b>' + title + '</b><br><pre>' + message + '</pre>'
print(json.dumps({'msgtype': 'm.text', 'body': body_text,
    'format': 'org.matrix.custom.html', 'formatted_body': body_html}))
" "$title" "$message")
    else
        # Fallback: flatten newlines into spaces to keep JSON valid
        payload=$(printf '{"msgtype":"m.text","body":"%s","format":"org.matrix.custom.html","formatted_body":"%s"}' \
            "$(printf '%s' "$body_text" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')" \
            "$(printf '%s' "$body_html" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')")
    fi

    curl -s -XPUT \
        -H "Authorization: Bearer $MATRIX_ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${MATRIX_HOMESERVER}/_matrix/client/v3/rooms/${encoded_room}/send/m.room.message/${txn_id}" \
        >/dev/null 2>&1 || log_error "Failed to send Matrix notification"
}

send_notifications() {
    local status="$1"
    local backed_up="$2"
    local skipped="$3"
    local failed="$4"
    local total="$5"

    if [[ "$status" == "success" ]] && [[ "${NOTIFY_ON_SUCCESS:-true}" != true ]]; then
        return 0
    fi

    if [[ "$status" == "failure" ]] && [[ "${NOTIFY_ON_FAILURE:-true}" != true ]]; then
        return 0
    fi

    local title message priority tags

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

Check logs: ${LOG_FILE:-}"
    fi

    send_ntfy "$title" "$message" "$priority" "$tags"
    send_pushover "$title" "$message" "$([ "$status" == "failure" ] && echo 1 || echo 0)"
    send_email "${EMAIL_SUBJECT_PREFIX:-[Docker Backup]} $title" "$message"
    send_matrix "$title" "$message"
}

#######################################
# Compression functions
# Requires: COMPRESSION_METHOD, COMPRESSION_LEVEL, USE_PARALLEL, PARALLEL_THREADS, EXCLUDE_PATTERNS
#######################################
get_compression_extension() {
    case "${COMPRESSION_METHOD:-none}" in
        gzip)   echo ".tar.gz" ;;
        bzip2)  echo ".tar.bz2" ;;
        xz)     echo ".tar.xz" ;;
        zstd)   echo ".tar.zst" ;;
        none)   echo ".tar" ;;
        *)      echo ".tar.gz" ;;
    esac
}

get_tar_compression_flag() {
    if [[ "${USE_PARALLEL:-false}" == true ]]; then
        echo ""
    else
        case "${COMPRESSION_METHOD:-none}" in
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
    case "${COMPRESSION_METHOD:-none}" in
        gzip)  export GZIP="-${COMPRESSION_LEVEL:-6}" ;;
        bzip2) export BZIP2="-${COMPRESSION_LEVEL:-6}" ;;
        xz)    export XZ_OPT="-${COMPRESSION_LEVEL:-6}" ;;
    esac
}

create_compressed_archive() {
    local output_file="$1"
    shift
    local tar_args=("$@")

    setup_compression_environment

    local exclude_args=()
    for pattern in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
        exclude_args+=(--exclude="$pattern")
    done

    if [[ "${USE_PARALLEL:-false}" == true ]]; then
        local compressor=""
        local compressor_args=()

        case "${COMPRESSION_METHOD:-none}" in
            gzip)
                if check_compression_tool pigz; then
                    compressor="pigz"
                    compressor_args=("-${COMPRESSION_LEVEL:-6}")
                    [[ ${PARALLEL_THREADS:-0} -gt 0 ]] && compressor_args+=("-p" "$PARALLEL_THREADS")
                else
                    log_warning "pigz not found, falling back to standard gzip"
                    USE_PARALLEL=false
                fi
                ;;
            bzip2)
                if check_compression_tool pbzip2; then
                    compressor="pbzip2"
                    compressor_args=("-${COMPRESSION_LEVEL:-6}")
                    [[ ${PARALLEL_THREADS:-0} -gt 0 ]] && compressor_args+=("-p${PARALLEL_THREADS}")
                else
                    log_warning "pbzip2 not found, falling back to standard bzip2"
                    USE_PARALLEL=false
                fi
                ;;
            xz)
                if check_compression_tool pxz; then
                    compressor="pxz"
                    compressor_args=("-${COMPRESSION_LEVEL:-6}")
                    [[ ${PARALLEL_THREADS:-0} -gt 0 ]] && compressor_args+=("-T${PARALLEL_THREADS}")
                else
                    log_warning "pxz not found, falling back to standard xz"
                    USE_PARALLEL=false
                fi
                ;;
            zstd)
                if check_compression_tool zstd; then
                    compressor="zstd"
                    compressor_args=("-${COMPRESSION_LEVEL:-6}")
                    [[ ${PARALLEL_THREADS:-0} -gt 0 ]] && compressor_args+=("-T${PARALLEL_THREADS}")
                else
                    log_error "zstd not found"
                    return 1
                fi
                ;;
            none)
                tar -cf "$output_file" "${exclude_args[@]}" "${tar_args[@]}"
                return $?
                ;;
        esac

        if [[ "${USE_PARALLEL:-false}" == true ]] && [[ -n "$compressor" ]]; then
            tar -c "${exclude_args[@]}" "${tar_args[@]}" | "$compressor" "${compressor_args[@]}" > "$output_file"
            return $?
        fi
    fi

    local compression_flag; compression_flag=$(get_tar_compression_flag)

    if [[ "$compression_flag" == "--zstd" ]]; then
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
# Compose file discovery
#######################################
find_compose_file() {
    local stack_path="$1"

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
