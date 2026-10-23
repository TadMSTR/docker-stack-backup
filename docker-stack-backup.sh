#!/bin/bash

#######################################
# Docker Compose Stack Backup Script
# Backs up Docker Compose stacks that have appdata bind mounts
#######################################

set -euo pipefail
# Archives hold full appdata: 0600 archives, 0700 run dirs (#1089). Restore and verify read
# them as their owner (lib.sh as_owner_of). status.json and the .prom set their own 0644.
umask 077

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
# Platform profile defaults (PLATFORM=auto|debian|truenas): ELEVATION_CMD and
# SNAPSHOT_BACKEND, when config.sh leaves them unset. Before the defaults below.
apply_platform_defaults

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

# Stacks with appdata but no running containers: archive them as they are (true), or
# skip them with reason "not-running" (false). Their data is already quiescent, so
# archiving them stops and starts nothing.
BACKUP_STOPPED_STACKS="${BACKUP_STOPPED_STACKS:-true}"

# Free-space floor in GB. The preflight requires max(MIN_FREE_GB, 1.2 x the previous run).
MIN_FREE_GB="${MIN_FREE_GB:-5}"

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

# Snapshot-assisted backup (USAGE.md "Snapshots"). SNAPSHOT_BACKEND=none|auto|btrfs|zfs;
# none unless config.sh or the platform profile says otherwise. Snapshots also need the
# root-owned snapshot helper (ELEVATION.md).
SNAPSHOT_HELPER_PATH="${SNAPSHOT_HELPER_PATH:-}"
SNAPSHOT_RESOLVED=none
SNAPSHOT_NOTE=""
# Stack whose snapshot (dsb-<stack>-<TIMESTAMP>) exists right now; on_exit deletes it.
SNAPSHOT_INFLIGHT=""
# Snapshot cleanup this run: deletes that failed (+1 if the start-of-run sweep failed),
# and leftovers the sweep removed. Both go to status.json, the .prom and the notification.
SNAPSHOT_CLEANUP_FAILED=0
SNAPSHOT_SWEPT=0
STACK_SNAPSHOT_DELETE_FAILED=0

# Run kind (lib.sh resolve_run_kind): full on FULL_RUN_DAY or with --full, else daily.
FORCE_FULL_RUN=false
RUN_KIND=daily

# Backends (lib.sh validate_backends; RESTIC.md). Which run this run, set in main.
TAR_THIS_RUN=false
RESTIC_THIS_RUN=false
# Why restic cannot be used this run (restic-repo-missing, restic-password-wrong, …):
# every stack's restic backup then fails with this reason, and tar still runs.
RESTIC_PROBLEM=""
RESTIC_REPO_ID=""
RESTIC_FLOOR_DAILY=0
RESTIC_FLOOR_WEEKLY=0
RESTIC_FLOOR_MONTHLY=0
# prune / check this run: ok, failed, or empty (not scheduled / not run).
RESTIC_PRUNE_RESULT=""
RESTIC_CHECK_RESULT=""
RESTIC_CHECK_SUBSET_USED=""
# Per-stack forget results this run.
RESTIC_FORGET_FAILED=0

# Status contract (see STATUS.md). status.json is a regular file next to the run dirs:
# restore, verify and cleanup enumerate only directories there, so a file is invisible
# to them, where a directory would be counted as a run and deleted by retention.
STATUS_ENABLED="${STATUS_ENABLED:-true}"
STATUS_FILE="${STATUS_FILE:-$BACKUP_DEST/$HOSTNAME/status.json}"
PROM_TEXTFILE_DIR="${PROM_TEXTFILE_DIR:-}"
COVERAGE_EXEMPTIONS_FILE="${COVERAGE_EXEMPTIONS_FILE:-$SCRIPT_DIR/coverage-exemptions.conf}"
COVERAGE_IGNORE_PATHS="${COVERAGE_IGNORE_PATHS:-}"
# Secret-bearing (a Healthchecks ping URL carries its key): never logged, never on argv.
PING_URL="${PING_URL:-}"

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

# Run status, written once per real run: by finalize_run_status at the end, or by the
# EXIT handler on an abort path. STATUS_ARMED is set only after argument parsing, for a
# real run, so a dry run or --help never replaces the nightly's record.
STATUS_ARMED=false
STATUS_DONE=false
ABORT_REASON=""
RUN_TMP=""
RUN_STARTED=""
STACK_TMP=""

# The status files and the ping belong to whoever holds the run lock. An abort before
# the lock was taken (not privileged, invalid config) takes it here just to write its
# record; if another run holds it, that run's status and ping are left alone.
lock_for_status() {
    [[ "${LOCK_HELD:-false}" == true ]] && return 0
    [[ -n "${LOCK_FILE:-}" ]] || return 1
    open_lock_file || return 1
    flock -n "$LOCK_FD" || return 1
    LOCK_HELD=true
}

# Deletes the in-flight snapshot, if any. A failure is logged; the next run's sweep
# removes what is left.
delete_inflight_snapshot() {
    [[ -n "$SNAPSHOT_INFLIGHT" ]] || return 0
    local stack="$SNAPSHOT_INFLIGHT"
    SNAPSHOT_INFLIGHT=""
    if snapshot_helper delete "$stack" "$TIMESTAMP" 2>>"$LOG_FILE"; then
        log "Snapshot deleted: dsb-$stack-$TIMESTAMP"
    else
        log_warning "Could not delete snapshot dsb-$stack-$TIMESTAMP; the next run's sweep removes it"
        # Reported in status.json, the .prom and the notification: a snapshot that is
        # never deleted pins disk and keeps a frozen copy of the whole subvolume.
        SNAPSHOT_CLEANUP_FAILED=$((SNAPSHOT_CLEANUP_FAILED + 1))
        STACK_SNAPSHOT_DELETE_FAILED=1
        return 1
    fi
}

# One EXIT handler: write the abort status (if the run was armed and never finished),
# then release the lock. A second `trap ... EXIT` would silently replace the first, so
# everything that must happen at exit goes here.
on_exit() {
    local rc=$?
    trap - EXIT
    # Before the abort record is written, so a failed delete is counted in it (CR-03).
    delete_inflight_snapshot || true
    if [[ "$STATUS_ARMED" == true && "$STATUS_DONE" != true ]]; then
        if lock_for_status 2>/dev/null; then
            write_run_status "${ABORT_REASON:-interrupted}" || true
            send_ping fail || true
        else
            log_warning "Another run holds the lock: its status.json, .prom and ping are left alone"
        fi
    fi
    if [[ -n "$RUN_TMP" ]]; then
        rm -rf -- "$RUN_TMP" || true
    fi
    if [[ -n "${STACK_TMP:-}" ]]; then
        rm -rf -- "$STACK_TMP" || true
    fi
    release_lock || true
    exit "$rc"
}
trap on_exit EXIT

# INT/TERM. Outside a stack, exit now (through on_exit). While a stack is being backed
# up, its services may be stopped: exiting there would leave them down. So the signal is
# noted, the stack runs to the end of its stop/archive/start, and the loop stops before
# the next stack. A second signal exits at once. (With 0.5.x's `trap release_lock INT`
# bash released the lock and then carried on with the whole run, unlocked.)
IN_STACK=false
PENDING_SIGNAL=""
CURRENT_STACK=""
CURRENT_STACK_STARTED=""
on_signal() {
    local code="$1"
    if [[ "$IN_STACK" == true && -z "$PENDING_SIGNAL" ]]; then
        PENDING_SIGNAL="$code"
        log_warning "Signal received: finishing the current stack (its services are started again), then stopping"
        return 0
    fi
    if [[ "$IN_STACK" == true ]]; then
        # A second signal mid-stack: exit now, but name the stack whose services may be
        # down, in the log and in the abort record (audit F-04).
        log_error "Second signal: exiting during $CURRENT_STACK; its services may be stopped. Check: cd $(dockhand_stack_base)/$CURRENT_STACK && docker compose ps"
        record_stack "$CURRENT_STACK" failed interrupted "" "" "" \
            "$CURRENT_STACK_STARTED" "$(date +%s)" ""
        IN_STACK=false
    fi
    exit "$code"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM


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
    
    # Create directory if it doesn't exist
    mkdir -p "$path" 2>/dev/null || true
    
    if [[ ! -d "$path" ]]; then
        log_error "Backup destination does not exist: $path"
        return 1
    fi
    
    # Required: max(MIN_FREE_GB, 1.2 x previous run) — see required_free_bytes in lib.sh.
    # An unusable requirement fails the check; it must never compare as 0.
    local required_bytes; required_bytes=$(required_free_bytes) || required_bytes=""
    if [[ ! "$required_bytes" =~ ^[0-9]+$ ]]; then
        log_error "Could not compute the free-space requirement (MIN_FREE_GB='${MIN_FREE_GB:-}')"
        return 1
    fi
    local available_kb; available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    local available_bytes=$((available_kb * 1024))
    local available_gb=$((available_kb / 1024 / 1024))
    local required_gb=$(( (required_bytes + 1024 * 1024 * 1024 - 1) / 1024 / 1024 / 1024 ))
    
    if [[ $available_bytes -lt $required_bytes ]]; then
        log_error "Insufficient disk space on $path"
        log_error "Available: ${available_gb}GB, Required: ${required_gb}GB"
        return 1
    fi
    
    log "✓ Disk space: ${available_gb}GB available on $path (required: ${required_gb}GB)"
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
    
    # Check disk space (MIN_FREE_GB, or 1.2x the previous run if larger)
    if ! check_disk_space "$BACKUP_DEST"; then
        checks_passed=false
    fi

    # Snapshot backend: an explicit SNAPSHOT_BACKEND that cannot work fails here; auto or
    # a profile default falls back to none, reported.
    if ! resolve_snapshot_backend; then
        checks_passed=false
    elif [[ "$SNAPSHOT_RESOLVED" != none ]]; then
        log "✓ Snapshot backend: $SNAPSHOT_RESOLVED (helper: $SNAPSHOT_HELPER_PATH)"
    elif [[ -n "$SNAPSHOT_NOTE" ]]; then
        log_warning "Snapshots not used ($SNAPSHOT_NOTE); stacks are archived while stopped"
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
# Status contract helpers (dsb_status.py does the encoding; bash never builds JSON)
#######################################
dsb_status() {
    python3 -I "$SCRIPT_DIR/dsb_status.py" "$@"
}

# Log each line the helper wrote to stderr (it makes them printable; log does too).
log_status_diagnostics() {
    local file="$1" line
    [[ -s "$file" ]] || return 0
    while IFS= read -r line; do
        log_warning "status: $line"
    done < "$file"
}

# record_stack <name> <result> <reason> <mode> <archive> <bytes> <started> <finished> <downtime>
#              [--xbackup FILE] [--snapshot-backend B --snapshot-used 0|1 ...]
record_stack() {
    [[ "$STATUS_ARMED" == true && -n "$RUN_TMP" ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0   # write_run_status reports it
    if ! dsb_status record "$RUN_TMP/records.jsonl" "$@" 2>>"$RUN_TMP/diag"; then
        log_warning "status: could not record the result for $1"
    fi
}

# write_run_status [abort_reason] — status.json and/or the .prom file. Returns 1 if a
# requested file could not be written.
write_run_status() {
    local aborted="${1:-}"
    local status_file=""
    [[ "$STATUS_ENABLED" == true ]] && status_file="$STATUS_FILE"
    [[ -n "$status_file" || -n "$PROM_TEXTFILE_DIR" ]] || return 0
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "python3 not found: status.json / .prom not written. Install python3, or set STATUS_ENABLED=false and leave PROM_TEXTFILE_DIR empty (STATUS.md)"
        return 1
    fi
    local diag="${RUN_TMP:-/tmp}/diag.finalize"
    [[ -n "$RUN_TMP" ]] || diag=/dev/null
    local summary rc=0
    summary=$(dsb_status finalize \
        --records "${RUN_TMP:-/nonexistent}/records.jsonl" \
        --stack-base "$(dockhand_stack_base)" \
        --appdata "$APPDATA_PATH" \
        --exemptions "$COVERAGE_EXEMPTIONS_FILE" \
        --ignore-paths "$COVERAGE_IGNORE_PATHS" \
        --status-file "$status_file" \
        --run-dir "$BACKUP_DEST/$HOSTNAME/$TIMESTAMP" \
        --prom-dir "$PROM_TEXTFILE_DIR" \
        --host "$HOSTNAME" --run-id "$TIMESTAMP" --version "$DSB_VERSION" \
        --started "${RUN_STARTED:-}" --dest "$BACKUP_DEST" \
        --run-kind "$RUN_KIND" --platform "${RESOLVED_PLATFORM:-}" \
        --snapshot-backend "$SNAPSHOT_RESOLVED" --snapshot-note "$SNAPSHOT_NOTE" \
        --snapshot-cleanup-failed "$SNAPSHOT_CLEANUP_FAILED" --snapshot-swept "$SNAPSHOT_SWEPT" \
        --backends "$BACKENDS" --tar-schedule "$TAR_SCHEDULE" --tar-ran "$TAR_THIS_RUN" \
        --restic-ran "$RESTIC_THIS_RUN" --restic-problem "$RESTIC_PROBLEM" \
        --restic-repo-id "$RESTIC_REPO_ID" \
        --restic-prune "$RESTIC_PRUNE_RESULT" --restic-check "$RESTIC_CHECK_RESULT" \
        --restic-check-subset "$RESTIC_CHECK_SUBSET_USED" \
        --restic-snapshots "${RUN_TMP:-/nonexistent}/restic-snapshots.json" \
        --restic-stats "${RUN_TMP:-/nonexistent}/restic-stats.json" \
        --restore-verified "$BACKUP_DEST/$HOSTNAME/restore-verified.json" \
        --aborted "$aborted" 2>"$diag") || rc=$?
    [[ -n "$RUN_TMP" ]] && log_status_diagnostics "$RUN_TMP/diag"
    [[ -n "$RUN_TMP" ]] && log_status_diagnostics "$diag"
    if [[ -n "$summary" ]]; then
        log "$summary"
    fi
    if [[ $rc -ne 0 ]]; then
        log_error "Could not write the run status (status.json / .prom); see the warnings above"
        return 1
    fi
    [[ -n "$status_file" ]] && log "Status written: $status_file"
    return 0
}

# The normal end of a real run. Preflight has passed, so the share is mounted and the
# host dir may be created (a run that archived nothing never made it). The abort path
# never creates it: an unmounted share must not get a local stand-in.
# STATUS_DONE is set only once the write has returned: a signal that kills the finalize
# step leaves STATUS_DONE false, so on_exit still writes the abort record and pings /fail
# (audit F-04). A write that fails is done too: on_exit must not write a second record.
finalize_run_status() {
    if [[ "$STATUS_ARMED" != true ]]; then
        STATUS_DONE=true
        return 0
    fi
    if [[ "$STATUS_ENABLED" == true ]]; then
        mkdir -p -- "$(dirname -- "$STATUS_FILE")" 2>/dev/null || true
    fi
    local rc=0
    write_run_status "" || rc=$?
    STATUS_DONE=true
    return "$rc"
}

# send_ping start|success|fail — Healthchecks-style liveness ping, if PING_URL is set.
# The URL goes to curl through a config on a file descriptor (-K), not argv, so `ps`
# never shows its key, and it is never logged. A ping error never fails the run.
send_ping() {
    [[ -n "${PING_URL:-}" ]] || return 0
    local url="${PING_URL%/}"
    case "$1" in
        start) url+="/start" ;;
        fail)  url+="/fail" ;;
    esac
    if [[ ! "$url" =~ ^https?:// || "$url" == *[[:cntrl:]]* ]]; then
        log_warning "PING_URL is not an http(s) URL; liveness ping skipped"
        return 0
    fi
    local esc="${url//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    if ! curl -fsS -o /dev/null -m 10 --retry 2 \
        -K <(printf 'url = "%s"\n' "$esc") >/dev/null 2>&1; then
        log_warning "Liveness ping failed ($1)"
    fi
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
    STACK_SKIP_REASON=""
    STACK_FAIL_REASON=""
    STACK_SIZE_BYTES=0
    
    # Find compose file
    local compose_file; compose_file=$(find_compose_file "$stack_path") || true
    if [[ -z "$compose_file" ]]; then
        STACK_SKIP_REASON="no-compose-file"
        return 2  # Skip - no compose file
    fi
    
    # Check if stack has appdata
    if ! stack_has_appdata "$compose_file"; then
        STACK_SKIP_REASON="no-appdata-reference"
        return 2  # Skip
    fi
    
    local appdata_dir="$APPDATA_PATH/$stack_name"
    
    if [[ ! -d "$appdata_dir" ]]; then
        STACK_SKIP_REASON="appdata-missing"
        return 2  # Skip
    fi
    
    if ! appdata_has_content "$appdata_dir"; then
        STACK_SKIP_REASON="appdata-empty"
        return 2  # Skip
    fi
    
    # Get appdata size
    local size; size=$(du_size "$appdata_dir" -h) || size="~$size"
    local size_bytes; size_bytes=$(du_size "$appdata_dir") || true
    
    # Get running containers. A failed check is a would-fail, never "stopped".
    local running ps_rc=0
    running=$(get_running_services "$stack_path") || ps_rc=$?
    if [[ $ps_rc -eq 1 ]]; then
        STACK_FAIL_REASON="compose-ps-failed"
        return 1
    elif [[ $ps_rc -eq 3 ]]; then
        STACK_FAIL_REASON="running-state-mismatch"
        return 1
    fi
    local running_count=0
    if [[ -n "$running" ]]; then
        running_count=$(wc -l <<< "$running")
    fi
    
    if [[ $running_count -eq 0 && "$BACKUP_STOPPED_STACKS" != true ]]; then
        STACK_SKIP_REASON="not-running"
        return 2  # Skip
    fi
    
    # Output stack info
    if [[ $running_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $stack_name ($size appdata, $running_count running)"
    else
        echo -e "  ${YELLOW}○${NC} $stack_name ($size appdata, stopped — archived without stop/start)"
    fi

    # x-backup tiers, as this run would apply them (sizes above are before exclusion)
    local xb_file; xb_file=$(mktemp "$RUN_TMP/xbackup.XXXXXX")
    read_xbackup "$stack_path" "$stack_name" "$RUN_KIND" "$xb_file"
    local line
    while IFS= read -r line; do
        echo "      $line"
    done < <(dsb_status xbackup-describe "$xb_file" 2>/dev/null)

    # Backends
    local plan=""
    [[ "$TAR_THIS_RUN" == true ]] && plan="tar"
    if [[ "$RESTIC_THIS_RUN" == true ]]; then
        plan+="${plan:+ + }restic${RESTIC_PROBLEM:+ (would fail: $RESTIC_PROBLEM)}"
    fi
    if [[ "$BACKENDS" != tar || "$TAR_SCHEDULE" != daily ]]; then
        echo "      backends: $plan"
    fi

    # Snapshot plan
    if [[ "$SNAPSHOT_RESOLVED" != none && $running_count -gt 0 ]]; then
        local check_out=""
        check_out=$(snapshot_helper check "$stack_name" 2>/dev/null) || check_out="fallback check-failed"
        if [[ "$check_out" == ok ]]; then
            echo "      snapshot: $SNAPSHOT_RESOLVED (stopped only while the snapshot is taken)"
        else
            echo "      snapshot: no, $(printable "${check_out#fallback }") (archived while stopped)"
        fi
    fi
    
    # Size for the total, through a global like STACK_SKIP_REASON. It used to go through
    # /tmp/stack_size_$$, a predictable name: a file planted there by another user survives
    # root's write (fs.protected_regular) and its content was then evaluated in $(( )),
    # which runs command substitutions in array subscripts (audit p3a F-01).
    STACK_SIZE_BYTES="$size_bytes"
    
    return 0  # Success
}

#######################################
# Backup a single stack
#######################################
# Return codes: 0 = backed up, 1 = failed, 2 = skipped. On 2, STACK_SKIP_REASON holds
# one of: no-compose-file, no-appdata-reference, appdata-missing, appdata-empty,
# not-running. On 1, STACK_FAIL_REASON may hold compose-ps-failed or
# running-state-mismatch (these appear in the log and notifications); otherwise
# STACK_FAIL_POINT holds stop-failed, archive-failed or restart-failed (status contract
# only, so the "Failed stacks:" text stays as it was). On 0, STACK_BACKUP_MODE is "running"
# (stopped, archived, started) or "stopped" (already stopped; archived without
# stop/start). For the status contract it also sets STACK_ARCHIVE (path relative to
# BACKUP_DEST/HOSTNAME), STACK_ARCHIVE_BYTES and STACK_DOWNTIME_S (stop -> started;
# 0 for a stopped stack; empty if never stopped or never started again).
backup_stack() {
    local stack_path="$1"
    local stack_name; stack_name=$(basename "$stack_path")
    STACK_SKIP_REASON=""
    STACK_FAIL_REASON=""
    STACK_BACKUP_MODE=""
    STACK_FAIL_POINT=""
    STACK_ARCHIVE=""
    STACK_ARCHIVE_BYTES=""
    STACK_DOWNTIME_S=""
    STACK_RECORD_OPTS=()
    DECLARED_EXCLUDES=()
    STACK_SNAPSHOT_DELETE_FAILED=0
    STACK_XB_FILE=""
    # Per backend this run: ok, failed, or empty when not scheduled.
    STACK_TAR_RESULT=""
    STACK_RESTIC_RESULT=""
    STACK_RESTIC_REASON=""
    STACK_RESTIC_SUMMARY=""
    STACK_RESTIC_S=""
    
    # Find compose file
    local compose_file; compose_file=$(find_compose_file "$stack_path") || true
    if [[ -z "$compose_file" ]]; then
        log_warning "No compose file found for stack $stack_name"
        STACK_SKIP_REASON="no-compose-file"
        return 2
    fi
    
    log "Processing stack: $stack_name"
    
    # Check if stack has appdata
    if ! stack_has_appdata "$compose_file"; then
        log_warning "Stack $stack_name has no appdata bind mounts, skipping"
        STACK_SKIP_REASON="no-appdata-reference"
        return 2  # Return 2 for skipped
    fi
    
    local appdata_dir="$APPDATA_PATH/$stack_name"
    
    # Check if appdata directory exists or if it has subdirectories
    # (some stacks have container-specific folders like dashboards/heimdall, dashboards/homepage)
    if [[ ! -d "$appdata_dir" ]]; then
        log_warning "Appdata directory $appdata_dir not found for stack $stack_name"
        STACK_SKIP_REASON="appdata-missing"
        return 2  # Return 2 for skipped
    fi
    
    # Check if directory has any content (direct files or subdirectories).
    # Skipped/deferred under ELEVATION_CMD — see appdata_has_content() in lib.sh.
    if ! appdata_has_content "$appdata_dir"; then
        log_warning "Appdata directory $appdata_dir is empty for stack $stack_name, skipping"
        STACK_SKIP_REASON="appdata-empty"
        return 2
    fi
    
    local backup_dir="$BACKUP_DEST/$HOSTNAME/$TIMESTAMP"
    local backup_ext; backup_ext=$(get_compression_extension)
    local backup_file="$backup_dir/${stack_name}${backup_ext}"
    
    # Get list of running containers before stopping
    log "Checking container states for stack: $stack_name"
    local running_containers ps_rc=0
    running_containers=$(get_running_services "$stack_path") || ps_rc=$?
    # An undeterminable state is a failure, never "stopped": archiving a stack that is in
    # fact running, without stopping it, gives a crash-inconsistent archive reported as
    # a clean backup.
    if [[ $ps_rc -eq 1 ]]; then
        log_error "Cannot determine running state of $stack_name: docker compose ps failed (compose file error or unset variable? see $LOG_FILE). Not archiving."
        STACK_FAIL_REASON="compose-ps-failed"
        return 1
    elif [[ $ps_rc -eq 3 ]]; then
        log_error "docker compose ps reports no running services for $stack_name, but docker has running containers for this stack dir. Not archiving a live stack."
        STACK_FAIL_REASON="running-state-mismatch"
        return 1
    fi
    
    if [[ -z "$running_containers" ]]; then
        if [[ "$BACKUP_STOPPED_STACKS" != true ]]; then
            log_warning "No running containers in stack $stack_name, skipping (BACKUP_STOPPED_STACKS=false)"
            STACK_SKIP_REASON="not-running"
            return 2
        fi
        log "No running containers in stack $stack_name — archiving as-is (nothing to stop or start)"
    else
        log "Running containers: $(echo "$running_containers" | tr '\n' ', ' | sed 's/,$//')"
    fi
    
    # The stack's x-backup tiers (USAGE.md "Backup tiers"), read once, before anything is
    # stopped. Any problem leaves DECLARED_EXCLUDES empty: a full backup.
    local xb_file; xb_file=$(mktemp "$RUN_TMP/xbackup.XXXXXX")
    read_xbackup "$stack_path" "$stack_name" "$RUN_KIND" "$xb_file"
    STACK_RECORD_OPTS+=(--xbackup "$xb_file")
    STACK_XB_FILE="$xb_file"
    if [[ ${#DECLARED_EXCLUDES[@]} -gt 0 ]]; then
        log "x-backup ($RUN_KIND run): leaving out $(join_by ', ' "${DECLARED_EXCLUDES[@]}")"
    fi

    # restic cannot be used this run (restic_preflight): its backup fails, counted. With
    # no tar to make either, there is nothing to stop the stack for.
    if [[ "$RESTIC_THIS_RUN" == true && -n "$RESTIC_PROBLEM" ]]; then
        STACK_RESTIC_RESULT=failed
        STACK_RESTIC_REASON="$RESTIC_PROBLEM"
        if [[ "$TAR_THIS_RUN" != true ]]; then
            log_error "restic: $stack_name not backed up ($RESTIC_PROBLEM)"
            STACK_FAIL_POINT="$RESTIC_PROBLEM"
            backend_record_opts
            return 1
        fi
    fi

    # Snapshot, or the old way? Decided before the stop, so the stack is stopped once.
    # A stopped stack is archived live: there is nothing to quiesce.
    local use_snapshot=false snap_fallback="" snap_s=""
    if [[ "$SNAPSHOT_RESOLVED" != none && -n "$running_containers" ]]; then
        local check_out=""
        if check_out=$(snapshot_helper check "$stack_name" 2>>"$LOG_FILE"); then
            case "$check_out" in
                ok) use_snapshot=true ;;
                "fallback nested-subvolume"|"fallback nested-dataset"|"fallback mountpoint"|"fallback snapdir-disabled")
                    snap_fallback="${check_out#fallback }" ;;
                *) snap_fallback=check-failed ;;
            esac
        else
            snap_fallback=check-failed
        fi
        if [[ -n "$snap_fallback" ]]; then
            log_warning "No snapshot for $stack_name ($snap_fallback): archiving while it is stopped"
        fi
    fi

    [[ "$TAR_THIS_RUN" == true ]] && mkdir -p "$backup_dir"
    
    # `stop`, not `down`: the containers are kept, so the restart below is a plain
    # `start` — no recreation, no image pull, no pending compose change applied.
    local stop_epoch=""
    if [[ -n "$running_containers" ]]; then
        log "Stopping stack: $stack_name"
        stop_epoch=$(date +%s)
        if ! (cd "$stack_path" && docker compose stop); then
            log_error "Failed to stop stack $stack_name"
            STACK_FAIL_POINT="stop-failed"
            # No snapshot was taken: the stop failed before it (CR-04).
            snapshot_record_opts false "$snap_fallback" ""
            # A partial stop leaves some services down; bring back what was running.
            restart_stack_with_retry "$stack_path" "$running_containers" || true
            return 1
        fi
    fi

    # stop -> snapshot -> start: the archive is then read from the snapshot while the
    # stack runs again. A failed snapshot leaves the stack stopped: archive it the old way
    # (it is never stopped twice).
    if [[ "$use_snapshot" == true ]]; then
        local snap_t0; snap_t0=$(date +%s)
        SNAPSHOT_INFLIGHT="$stack_name"
        local create_out="" create_rc=0
        create_out=$(snapshot_helper create "$stack_name" "$TIMESTAMP" 2>>"$LOG_FILE") || create_rc=$?
        if [[ $create_rc -eq 0 ]]; then
            snap_s=$(( $(date +%s) - snap_t0 ))
            log "Snapshot taken: dsb-$stack_name-$TIMESTAMP (${snap_s}s)"
        else
            use_snapshot=false
            # Exit 3: a boundary appeared after the check (the helper has removed any
            # snapshot it took); 4: the same, or a snapshot walk failure, but the snapshot
            # it took is still there. Anything else: the snapshot itself failed.
            case "$create_rc:$create_out" in
                [34]":fallback nested-subvolume"|"3:fallback nested-dataset"|"3:fallback mountpoint")
                    snap_fallback="${create_out#fallback }" ;;
                *)  snap_fallback=create-failed ;;
            esac
            log_warning "Snapshot of $stack_name not used ($snap_fallback): archiving while it is stopped"
            if [[ $create_rc -eq 4 ]]; then
                # The helper took a snapshot and could not delete it: one more try, and a
                # failure is counted like any other (audit p5a R2-02).
                delete_inflight_snapshot || true
            else
                # In case it was half made; quietly, as there is usually nothing to delete.
                snapshot_helper delete "$stack_name" "$TIMESTAMP" 2>/dev/null || true
                SNAPSHOT_INFLIGHT=""
            fi
        fi
    fi

    local restart_failed=false
    if [[ "$use_snapshot" == true ]]; then
        log "Starting previously running containers: $(echo "$running_containers" | tr '\n' ', ' | sed 's/,$//')"
        if restart_stack_with_retry "$stack_path" "$running_containers"; then
            STACK_DOWNTIME_S=$(( $(date +%s) - stop_epoch ))
            run_post_restart_hooks "$stack_name" "$stack_path"
        else
            # restart_stack_with_retry already logged and notified. The snapshot holds the
            # quiesced data, so the archive is still made.
            restart_failed=true
            STACK_FAIL_POINT="restart-failed"
        fi
    fi
    
    # The stack's compose file and .env, for both backends: each helper reads them as the
    # invoking user from this private dir.
    local temp_dir; temp_dir=$(mktemp -d)
    # Also kept globally: an exit from a signal trap never returns from this function,
    # so the RETURN trap below does not run, and the exit handler removes it instead.
    # It holds a copy of the stack's .env (audit p3c R2-01).
    STACK_TMP="$temp_dir"
    # Bash RETURN traps are global: an un-disarmed `trap ... RETURN` set here stays
    # armed after backup_stack() returns and then re-fires on every later function
    # return (e.g. main()), where $temp_dir is out of scope — aborting under `set -u`
    # with "temp_dir: unbound variable" and forcing a nonzero exit even on a fully
    # successful backup (latent until a real elevated run first reached this point).
    # Disarm the trap as part of its own action so it fires exactly once, for this
    # function's return, and never leaks to outer frames.
    trap 'rm -rf "$temp_dir"; STACK_TMP=""; trap - RETURN' RETURN
    
    # Copy compose file to temp directory. -p: the archive records the file's own mode,
    # not one masked by this script's umask 077 (a 0644 compose file stays 0644).
    cp -p "$compose_file" "$temp_dir/"
    
    # Copy any other files in the stack directory (env files, etc)
    if [[ -f "$stack_path/.env" ]]; then
        cp -p "$stack_path/.env" "$temp_dir/"
    fi
    
    # tar: written to <stack>.incomplete and renamed on success — see
    # create_archive_atomic. From the snapshot, the member names are the same <stack>/…
    # as from the live dir.
    if [[ "$TAR_THIS_RUN" == true ]]; then
        log "Creating backup: $backup_file"
        log "Creating ${COMPRESSION_METHOD} compressed backup (level ${COMPRESSION_LEVEL})..."
        if [[ "$USE_PARALLEL" == true ]]; then
            log "Using parallel compression"
        fi
        STACK_TAR_RESULT=failed
        # shellcheck disable=SC2034  # ARCHIVE_SNAPSHOT_TS is read by create_compressed_archive (lib.sh)
        [[ "$use_snapshot" == true ]] && ARCHIVE_SNAPSHOT_TS="$TIMESTAMP"
        if create_archive_atomic "$backup_file" \
            -C "$temp_dir" . \
            -C "$APPDATA_PATH" "$stack_name" 2>&1 | tee -a "$LOG_FILE"; then
            STACK_TAR_RESULT=ok
        fi
        # shellcheck disable=SC2034  # read by create_compressed_archive (lib.sh)
        ARCHIVE_SNAPSHOT_TS=""
        if [[ "$STACK_TAR_RESULT" == ok ]]; then
            log_success "Backup created: $backup_file"
            STACK_ARCHIVE="$TIMESTAMP/${stack_name}${backup_ext}"
            STACK_ARCHIVE_BYTES=$(stat -c %s -- "$backup_file" 2>/dev/null) || STACK_ARCHIVE_BYTES=""
        else
            log_error "Failed to create backup for $stack_name"
        fi
    fi

    # restic: the same source (the snapshot, or the live dir while the stack is still
    # stopped), the same excludes, one snapshot of this stack.
    if [[ "$RESTIC_THIS_RUN" == true && -z "$RESTIC_PROBLEM" ]]; then
        if restic_backup_stack "$temp_dir" "$stack_name" "$use_snapshot"; then
            STACK_RESTIC_RESULT=ok
        else
            STACK_RESTIC_RESULT=failed
        fi
    fi
    DECLARED_EXCLUDES=()
    if [[ "$use_snapshot" == true ]]; then
        delete_inflight_snapshot || true
    fi
    snapshot_record_opts "$use_snapshot" "$snap_fallback" "$snap_s"
    backend_record_opts

    # A backend failed: tar's reason first, then restic's (each is in the record).
    local backend_failed=""
    if [[ "$STACK_TAR_RESULT" == failed ]]; then
        backend_failed=archive-failed
    elif [[ "$STACK_RESTIC_RESULT" == failed ]]; then
        backend_failed="${STACK_RESTIC_REASON:-restic-backup-failed}"
    fi

    if [[ "$use_snapshot" == true ]]; then
        # Started again right after the snapshot.
        if [[ "$restart_failed" == true ]]; then
            return 1
        fi
        if [[ -n "$backend_failed" ]]; then
            STACK_FAIL_POINT="$backend_failed"
            return 1
        fi
        STACK_BACKUP_MODE="running"
        log_success "Stack $stack_name backed up from a snapshot and restarted successfully"
        return 0
    fi

    if [[ -n "$backend_failed" ]]; then
        STACK_FAIL_POINT="$backend_failed"
        # Restore only previously running containers.
        if [[ -n "$running_containers" ]]; then
            log "Restoring previously running containers"
            restart_stack_with_retry "$stack_path" "$running_containers" || true
        fi
        return 1
    fi
    
    if [[ -z "$running_containers" ]]; then
        STACK_BACKUP_MODE="stopped"
        STACK_DOWNTIME_S=0
        log_success "Stack $stack_name backed up (stopped; not started)"
        return 0
    fi
    
    # Start only the containers that were running before
    log "Starting previously running containers: $(echo "$running_containers" | tr '\n' ', ' | sed 's/,$//')"
    if ! restart_stack_with_retry "$stack_path" "$running_containers"; then
        # restart_stack_with_retry already logged and notified
        STACK_FAIL_POINT="restart-failed"
        return 1
    fi
    STACK_DOWNTIME_S=$(( $(date +%s) - stop_epoch ))
    
    # Run any configured post-restart hooks (non-fatal on hook failure)
    run_post_restart_hooks "$stack_name" "$stack_path"
    
    STACK_BACKUP_MODE="running"
    log_success "Stack $stack_name backed up and restarted successfully"
    return 0
}

# backend_record_opts — the per-backend part of this stack's status record.
backend_record_opts() {
    [[ -n "$STACK_TAR_RESULT" ]] && STACK_RECORD_OPTS+=(--tar-result "$STACK_TAR_RESULT")
    if [[ -n "$STACK_RESTIC_RESULT" ]]; then
        STACK_RECORD_OPTS+=(--restic-result "$STACK_RESTIC_RESULT"
            --restic-reason "$STACK_RESTIC_REASON"
            --restic-summary "$STACK_RESTIC_SUMMARY" --restic-s "$STACK_RESTIC_S")
    fi
    return 0
}

# snapshot_record_opts <used:true|false> <fallback_reason> <snapshot_s> — the snapshot
# part of this stack's status record, when a snapshot backend is in use.
snapshot_record_opts() {
    [[ "$SNAPSHOT_RESOLVED" != none ]] || return 0
    local used=0
    [[ "$1" == true ]] && used=1
    STACK_RECORD_OPTS+=(--snapshot-backend "$SNAPSHOT_RESOLVED" --snapshot-used "$used"
        --snapshot-fallback "$2" --snapshot-s "$3"
        --snapshot-delete-failed "$STACK_SNAPSHOT_DELETE_FAILED")
}

#######################################
# restic (RESTIC.md). Everything goes through the root helper (lib.sh restic_helper).
#######################################
# restic_preflight — reads the helper's constants and the repository. A setting below the
# helper's retention floors stops the run (invalid config). Anything that makes restic
# unusable sets RESTIC_PROBLEM instead: each stack's restic backup then fails with it,
# counted, and tar still runs where scheduled.
restic_preflight() {
    local info="" key val h_appdata="" rc=0
    if ! info=$(restic_helper info 2>>"$LOG_FILE"); then
        RESTIC_PROBLEM=restic-helper-failed
        log_error "restic: the helper's 'info' failed (see $LOG_FILE); restic is not used this run"
        return 0
    fi
    while IFS='=' read -r key val; do
        case "$key" in
            appdata)       h_appdata="$val" ;;
            floor_daily)   [[ "$val" =~ ^[0-9]{1,4}$ ]] && RESTIC_FLOOR_DAILY=$((10#$val)) ;;
            floor_weekly)  [[ "$val" =~ ^[0-9]{1,4}$ ]] && RESTIC_FLOOR_WEEKLY=$((10#$val)) ;;
            floor_monthly) [[ "$val" =~ ^[0-9]{1,4}$ ]] && RESTIC_FLOOR_MONTHLY=$((10#$val)) ;;
        esac
    done <<< "$info"
    if [[ "$h_appdata" != "$APPDATA_PATH" ]]; then
        RESTIC_PROBLEM=restic-helper-failed
        log_error "restic: the helper's ALLOWED_APPDATA_PATH ($(printable "$h_appdata")) is not APPDATA_PATH; restic is not used this run"
        return 0
    fi
    if (( RESTIC_KEEP_DAILY < RESTIC_FLOOR_DAILY || RESTIC_KEEP_WEEKLY < RESTIC_FLOOR_WEEKLY \
          || RESTIC_KEEP_MONTHLY < RESTIC_FLOOR_MONTHLY )); then
        log_error "RESTIC_KEEP_DAILY/WEEKLY/MONTHLY ($RESTIC_KEEP_DAILY/$RESTIC_KEEP_WEEKLY/$RESTIC_KEEP_MONTHLY) are below the restic helper's floors ($RESTIC_FLOOR_DAILY/$RESTIC_FLOOR_WEEKLY/$RESTIC_FLOOR_MONTHLY)"
        return 1
    fi
    local out=""
    out=$(restic_helper repo 2>>"$LOG_FILE") || rc=$?
    if [[ $rc -ne 0 ]]; then
        RESTIC_PROBLEM=$(restic_problem_for_rc "$rc")
        log_error "restic: the repository cannot be used ($RESTIC_PROBLEM, exit $rc); every stack's restic backup fails this run"
        return 0
    fi
    [[ "$out" =~ ^id=([0-9a-f]{64})$ ]] && RESTIC_REPO_ID="${BASH_REMATCH[1]}"
    log "✓ restic repository ${RESTIC_REPO_ID:0:10} (helper: $RESTIC_HELPER_PATH)"
    return 0
}

# restic_backup_stack <temp_dir> <stack> <from_snapshot:true|false> — one restic snapshot
# of the stack, from the same source tar reads, with the same excludes. Sets
# STACK_RESTIC_SUMMARY (the helper's JSON summary file), STACK_RESTIC_S, and
# STACK_RESTIC_REASON on failure. Returns 0 on success.
restic_backup_stack() {
    local temp_dir="$1" stack="$2"
    local -a from=() declared=()
    [[ "$3" == true ]] && from=(--from-snapshot)
    local p
    for p in "${DECLARED_EXCLUDES[@]+"${DECLARED_EXCLUDES[@]}"}"; do
        valid_declared_path "$p" || { log_error "Invalid declared path refused"; STACK_RESTIC_REASON=restic-backup-failed; return 1; }
        declared+=("$stack/$p")
    done
    [[ ${#declared[@]} -gt 0 ]] && declared=(-- "${declared[@]}")
    STACK_RESTIC_SUMMARY="$RUN_TMP/restic-$stack.json"
    log "restic: backing up $stack${from[0]:+ from its snapshot}"
    local t0 rc=0
    t0=$(date +%s)
    restic_helper backup "$temp_dir" "$stack" "$TIMESTAMP" "$RUN_KIND" \
        "${from[@]+"${from[@]}"}" \
        "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}" \
        "${declared[@]+"${declared[@]}"}" > "$STACK_RESTIC_SUMMARY" 2>>"$LOG_FILE" || rc=$?
    STACK_RESTIC_S=$(( $(date +%s) - t0 ))
    if [[ $rc -ne 0 ]]; then
        if [[ $rc -eq 11 ]]; then
            STACK_RESTIC_REASON=restic-repo-locked
        else
            STACK_RESTIC_REASON=restic-backup-failed
        fi
        log_error "restic: backup of $stack failed (exit $rc; 3 = some files could not be read, 11 = repository locked)"
        return 1
    fi
    log_success "restic: $stack backed up (${STACK_RESTIC_S}s)"
    return 0
}

# restic_forget_stack <stack> <xbackup_file> — retention for one stack: x-backup.retention,
# key by key, else RESTIC_KEEP_*. Counts below the helper's floors are refused here (and
# by the helper), never raised. Adds the result to STACK_RECORD_OPTS.
restic_forget_stack() {
    local stack="$1" xb_file="$2" keep d w m result=ok
    keep=$(dsb_status retention "$xb_file" "$RESTIC_KEEP_DAILY" "$RESTIC_KEEP_WEEKLY" "$RESTIC_KEEP_MONTHLY" 2>/dev/null) \
        || keep="$RESTIC_KEEP_DAILY $RESTIC_KEEP_WEEKLY $RESTIC_KEEP_MONTHLY"
    read -r d w m <<< "$keep"
    local out="$RUN_TMP/forget-$stack.json"
    : > "$out"
    if [[ ! "${d:-}" =~ ^[0-9]+$ || ! "${w:-}" =~ ^[0-9]+$ || ! "${m:-}" =~ ^[0-9]+$ ]]; then
        log_error "restic: cannot tell $stack's retention; nothing forgotten"
        result=failed
        d="" w="" m=""
    elif (( d < RESTIC_FLOOR_DAILY || w < RESTIC_FLOOR_WEEKLY || m < RESTIC_FLOOR_MONTHLY )); then
        log_error "restic: $stack's x-backup.retention ($d/$w/$m) is below the helper's floors ($RESTIC_FLOOR_DAILY/$RESTIC_FLOOR_WEEKLY/$RESTIC_FLOOR_MONTHLY); nothing forgotten"
        result=refused
    elif ! restic_helper forget "$stack" "$d" "$w" "$m" > "$out" 2>>"$LOG_FILE"; then
        log_error "restic: forget for $stack failed"
        result=failed
    fi
    [[ "$result" == ok ]] || RESTIC_FORGET_FAILED=$((RESTIC_FORGET_FAILED + 1))
    STACK_RECORD_OPTS+=(--forget-result "$result" --forget-file "$out" --retention "$d $w $m")
}

# restic_maintenance — after every stack: prune and check when scheduled, then the
# snapshot list (for orphan stacks) and the repository stats, for the status contract.
restic_maintenance() {
    [[ "$RESTIC_THIS_RUN" == true && -z "$RESTIC_PROBLEM" ]] || return 0
    if schedule_due "$RESTIC_PRUNE_ON" "$RUN_KIND"; then
        log "restic: prune"
        if restic_helper prune >> "$LOG_FILE" 2>&1; then
            RESTIC_PRUNE_RESULT=ok
        else
            RESTIC_PRUNE_RESULT=failed
            log_error "restic: prune failed (see $LOG_FILE)"
        fi
    fi
    if schedule_due "$RESTIC_CHECK_ON" "$RUN_KIND"; then
        RESTIC_CHECK_SUBSET_USED=$(restic_check_subset)
        log "restic: check --read-data-subset=$RESTIC_CHECK_SUBSET_USED"
        if restic_helper check "$RESTIC_CHECK_SUBSET_USED" >> "$LOG_FILE" 2>&1; then
            RESTIC_CHECK_RESULT=ok
        else
            RESTIC_CHECK_RESULT=failed
            log_error "restic: check failed (see $LOG_FILE): the repository may be damaged"
        fi
    fi
    restic_helper snapshots > "$RUN_TMP/restic-snapshots.json" 2>>"$LOG_FILE" \
        || { log_warning "restic: could not list snapshots"; rm -f -- "$RUN_TMP/restic-snapshots.json"; }
    restic_helper stats > "$RUN_TMP/restic-stats.json" 2>>"$LOG_FILE" \
        || { log_warning "restic: could not read the repository stats"; rm -f -- "$RUN_TMP/restic-stats.json"; }
}

#######################################
# Main function
#######################################
main() {
    local coverage_report=false
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run|--dryrun|-n)
                DRY_RUN=true
                shift
                ;;
            --coverage-report)
                coverage_report=true
                shift
                ;;
            --full)
                # shellcheck disable=SC2034  # read by resolve_run_kind (lib.sh)
                FORCE_FULL_RUN=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --dry-run, -n       Simulate backup without making changes"
                echo "  --coverage-report   Print the coverage classifier's JSON for every stack"
                echo "                      (read-only: stops, archives and writes nothing)"
                echo "  --full              A full run: x-backup weekly-tier paths are backed up"
                echo "                      too (default: full on FULL_RUN_DAY, else daily)"
                echo "  --help, -h          Show this help message"
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
    
    RUN_KIND=$(resolve_run_kind)
    tar_scheduled "$RUN_KIND" && TAR_THIS_RUN=true
    backend_enabled restic && RESTIC_THIS_RUN=true

    if [[ "$coverage_report" == true ]]; then
        # stdout is the JSON only: no lock is taken, so release_lock logs nothing at exit.
        run_coverage_report
        exit $?
    fi

    # Private scratch for the run: per-stack x-backup results and status records.
    # on_exit removes it.
    RUN_TMP=$(mktemp -d)

    # A real run records its outcome, aborts included; a dry run never does.
    if [[ "$DRY_RUN" != true ]] && \
       [[ "$STATUS_ENABLED" == true || -n "$PROM_TEXTFILE_DIR" || -n "$PING_URL" ]]; then
        RUN_STARTED=$(date +%s)
        STATUS_ARMED=true
    fi

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
    log "Version: docker-stack-backup $DSB_VERSION"
    log "Hostname: $HOSTNAME"
    log "OS: $OS_NAME ($OS_TYPE)"
    log "Platform: ${RESOLVED_PLATFORM:-generic} (PLATFORM=$(printable "${PLATFORM:-auto}"))"
    log "Run kind: $RUN_KIND (full on day $(printable "${FULL_RUN_DAY:-7}") of the week, or with --full)"
    log "Backends: $(printable "$BACKENDS") (tar: $(printable "$TAR_SCHEDULE"); this run: tar $TAR_THIS_RUN, restic $RESTIC_THIS_RUN)"
    log "========================================="
    
    # Require root, unless ELEVATION_CMD is configured to elevate archive creation
    if ! require_privileged_or_elevated; then
        ABORT_REASON="not-privileged"
        exit 1
    fi
    
    if ! validate_numeric_config || ! validate_platform || ! validate_backends; then
        ABORT_REASON="invalid-config"
        exit 1
    fi
    
    # Acquire lock to prevent concurrent runs (skip in dry-run)
    if [[ "$DRY_RUN" != true ]]; then
        ABORT_REASON="lock-held"   # acquire_lock exits on failure
        acquire_lock
        ABORT_REASON=""
    fi
    
    # Run pre-flight checks
    if ! run_preflight_checks; then
        log_error "Pre-flight checks failed, aborting"
        ABORT_REASON="preflight-failed"
        exit 1
    fi
    # restic: the helper's floors are config validation; an unusable repository is not
    # an abort (RESTIC_PROBLEM), so tar still runs.
    if [[ "$RESTIC_THIS_RUN" == true ]] && ! restic_preflight; then
        ABORT_REASON="invalid-config"
        exit 1
    fi

    # Snapshots left by an earlier run that died before deleting them. Only after the
    # lock is held: never one of a run still going.
    if [[ "$DRY_RUN" != true && "$SNAPSHOT_RESOLVED" != none ]]; then
        local swept="" name
        if swept=$(snapshot_helper sweep 2>>"$LOG_FILE"); then
            :
        else
            log_warning "Snapshot sweep did not finish (see above); continuing"
            SNAPSHOT_CLEANUP_FAILED=$((SNAPSHOT_CLEANUP_FAILED + 1))
        fi
        while IFS= read -r name; do
            if [[ -n "$name" ]]; then
                log_warning "Removed leftover snapshot: $(printable "$name")"
                SNAPSHOT_SWEPT=$((SNAPSHOT_SWEPT + 1))
            fi
        done <<< "$swept"
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
        
        # Collect skip and fail lists
        local -a skip_list=() fail_list=()
        
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
            local sim_rc=0
            simulate_backup_stack "$stack_path" || sim_rc=$?
            local stack_name; stack_name=$(basename "$stack_path")
            if [[ $sim_rc -eq 0 ]]; then
                backed_up=$((backed_up + 1))
                # Digits only before arithmetic: $(( )) evaluates its operand's content.
                if [[ "${STACK_SIZE_BYTES:-}" =~ ^[0-9]+$ ]]; then
                    total_size=$((total_size + STACK_SIZE_BYTES))
                fi
            elif [[ $sim_rc -eq 2 ]]; then
                skip_list+=("$stack_name (${STACK_SKIP_REASON:-unknown})")
                skipped=$((skipped + 1))
            else
                fail_list+=("$stack_name (${STACK_FAIL_REASON:-unknown})")
                failed=$((failed + 1))
            fi
        done
        
        if [[ ${#skip_list[@]} -gt 0 ]]; then
            echo -e "\n${YELLOW}Would skip:${NC}\n"
            for stack_name in "${skip_list[@]}"; do
                echo -e "  ${YELLOW}○${NC} $stack_name"
            done
        fi
        
        if [[ ${#fail_list[@]} -gt 0 ]]; then
            echo -e "\n${RED}Would fail:${NC}\n"
            for stack_name in "${fail_list[@]}"; do
                echo -e "  ${RED}✗${NC} $stack_name"
            done
        fi
        
        local total_size_human; total_size_human=$(numfmt --to=iec-i --suffix=B $total_size 2>/dev/null || echo "${total_size} bytes")
        local backup_ext; backup_ext=$(get_compression_extension)
        
        echo -e "\n${CYAN}=========================================${NC}"
        echo -e "${BOLD}Summary:${NC}"
        echo "  Total stacks found: $total_stacks"
        echo -e "  Would backup: ${GREEN}$backed_up${NC}"
        echo -e "  Would skip: ${YELLOW}$skipped${NC}"
        if [[ $failed -gt 0 ]]; then
            echo -e "  Would fail: ${RED}$failed${NC}"
        fi
        echo ""
        echo -e "  Estimated backup size: ${BOLD}$total_size_human${NC}"
        echo "  Compression method: ${COMPRESSION_METHOD}"
        echo "  Backup extension: ${backup_ext}"
        echo "  Run kind: ${RUN_KIND}"
        echo "  Backends: ${BACKENDS} (tar: ${TAR_SCHEDULE}; this run: tar ${TAR_THIS_RUN}, restic ${RESTIC_THIS_RUN}${RESTIC_PROBLEM:+, $RESTIC_PROBLEM})"
        if [[ "$TAR_THIS_RUN" != true ]]; then
            echo "  (no tar archives this run: the size estimate is what restic reads)"
        fi
        echo "  Snapshot backend: ${SNAPSHOT_RESOLVED}${SNAPSHOT_NOTE:+ ($SNAPSHOT_NOTE)}"
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
        log "Run kind: $RUN_KIND; snapshot backend: $SNAPSHOT_RESOLVED"
        log "========================================="
        
        return 0
    fi
    
    # Normal backup mode
    
    send_ping start
    local -a stopped_names=() skipped_entries=() failed_names=()
    
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
        local stack_name; stack_name=$(basename "$stack_path")
        local stack_started; stack_started=$(date +%s)
        CURRENT_STACK="$stack_name"
        CURRENT_STACK_STARTED="$stack_started"
        IN_STACK=true
        backup_stack "$stack_path" || result=$?
        IN_STACK=false
        # Retention right after the stack's own snapshot, once its services are back.
        if [[ "${STACK_RESTIC_RESULT:-}" == ok && -z "$PENDING_SIGNAL" ]]; then
            restic_forget_stack "$stack_name" "$STACK_XB_FILE"
        fi
        local stack_finished; stack_finished=$(date +%s)
        local rec_result=failed rec_reason="${STACK_FAIL_REASON:-${STACK_FAIL_POINT:-}}"
        if [[ $result -eq 0 ]]; then
            rec_result=backed_up; rec_reason=""
        elif [[ $result -eq 2 ]]; then
            rec_result=skipped; rec_reason="${STACK_SKIP_REASON:-}"
        fi
        record_stack "$stack_name" "$rec_result" "$rec_reason" "${STACK_BACKUP_MODE:-}" \
            "${STACK_ARCHIVE:-}" "${STACK_ARCHIVE_BYTES:-}" "$stack_started" \
            "$stack_finished" "${STACK_DOWNTIME_S:-}" \
            "${STACK_RECORD_OPTS[@]+"${STACK_RECORD_OPTS[@]}"}"
        if [[ -n "$PENDING_SIGNAL" ]]; then
            log_error "Stopping after $stack_name on a signal; the remaining stacks are not backed up"
            ABORT_REASON="interrupted"
            exit "$PENDING_SIGNAL"
        fi
        
        if [[ $result -eq 0 ]]; then
            # Successfully backed up
            backed_up=$((backed_up + 1))
            if [[ "${STACK_BACKUP_MODE:-}" == stopped ]]; then
                stopped_names+=("$stack_name (stopped)")
            fi
        elif [[ $result -eq 2 ]]; then
            # Skipped — reason recorded by backup_stack
            skipped=$((skipped + 1))
            skipped_entries+=("$stack_name (${STACK_SKIP_REASON:-unknown})")
        else
            # Failed
            failed=$((failed + 1))
            failed_names+=("$stack_name${STACK_FAIL_REASON:+ ($STACK_FAIL_REASON)}")
        fi
    done
    
    # Remove this run's timestamp dir if nothing was archived into it (rmdir only
    # removes an empty dir, so a dir holding any archive is left alone).
    rmdir "$BACKUP_DEST/$HOSTNAME/$TIMESTAMP" 2>/dev/null || true

    restic_maintenance
    
    local details=""
    if [[ ${#stopped_names[@]} -gt 0 ]]; then
        details+="Backed up while stopped: $(join_by ', ' "${stopped_names[@]}")"$'\n'
    fi
    if [[ ${#skipped_entries[@]} -gt 0 ]]; then
        details+="Skipped: $(join_by ', ' "${skipped_entries[@]}")"$'\n'
    fi
    if [[ ${#failed_names[@]} -gt 0 ]]; then
        details+="Failed: $(join_by ', ' "${failed_names[@]}")"$'\n'
    fi
    if [[ $SNAPSHOT_CLEANUP_FAILED -gt 0 ]]; then
        details+="Snapshot cleanup failed: $SNAPSHOT_CLEANUP_FAILED (leftover snapshots pin disk; see the log)"$'\n'
    fi
    # restic maintenance: none of it fails a stack, but each failure fails the run.
    local -a restic_issues=()
    [[ -n "$RESTIC_PROBLEM" ]] && restic_issues+=("repository unusable ($RESTIC_PROBLEM)")
    [[ $RESTIC_FORGET_FAILED -gt 0 ]] && restic_issues+=("forget failed for $RESTIC_FORGET_FAILED stack(s)")
    [[ "$RESTIC_PRUNE_RESULT" == failed ]] && restic_issues+=("prune failed")
    [[ "$RESTIC_CHECK_RESULT" == failed ]] && restic_issues+=("check failed (subset $RESTIC_CHECK_SUBSET_USED)")
    if [[ ${#restic_issues[@]} -gt 0 ]]; then
        details+="restic: $(join_by '; ' "${restic_issues[@]}")"$'\n'
    fi
    details="${details%$'\n'}"
    
    # The count lines keep their pre-0.5.0 wording so existing log readers still
    # match; the per-stack names and reasons follow them.
    log "========================================="
    log "Backup Summary:"
    log "Total stacks found: $total_stacks"
    log "Successfully backed up: $backed_up"
    log "Skipped (no appdata): $skipped"
    log "Failed: $failed"
    if [[ ${#stopped_names[@]} -gt 0 ]]; then
        log "Backed up while stopped: $(join_by ', ' "${stopped_names[@]}")"
    fi
    if [[ ${#skipped_entries[@]} -gt 0 ]]; then
        log "Skipped stacks: $(join_by ', ' "${skipped_entries[@]}")"
    fi
    if [[ ${#failed_names[@]} -gt 0 ]]; then
        log "Failed stacks: $(join_by ', ' "${failed_names[@]}")"
    fi
    if [[ $SNAPSHOT_CLEANUP_FAILED -gt 0 ]]; then
        log_warning "Snapshot cleanup failed: $SNAPSHOT_CLEANUP_FAILED"
    fi
    if [[ ${#restic_issues[@]} -gt 0 ]]; then
        log_error "restic: $(join_by '; ' "${restic_issues[@]}")"
    fi
    log "========================================="
    
    # Send notifications
    local rc=0
    if [[ $failed -gt 0 || ${#restic_issues[@]} -gt 0 ]]; then
        send_notifications "failure" "$backed_up" "$skipped" "$failed" "$total_stacks" "$details"
        rc=1
    else
        send_notifications "success" "$backed_up" "$skipped" "$failed" "$total_stacks" "$details"
    fi
    
    # Status after notifications: coverage runs here, once, after every stack is back up,
    # and a status write failure makes the run exit non-zero without holding back the
    # notifications.
    local status_rc=0
    finalize_run_status || status_rc=1
    [[ $status_rc -ne 0 ]] && rc=1
    # A run whose status could not be written is not reported healthy: the record the
    # alerts read is now stale.
    if [[ $failed -eq 0 && $status_rc -eq 0 && ${#restic_issues[@]} -eq 0 ]]; then
        send_ping success
    else
        send_ping fail
    fi
    exit "$rc"
}

#######################################
# --coverage-report: the classifier's JSON for every stack, read-only. Same stack
# enumeration as the backup loop (a dir under the stack base with a compose file).
#######################################
run_coverage_report() {
    local stack_base; stack_base=$(dockhand_stack_base)
    local -a names=()
    local stack_path
    for stack_path in "$stack_base"/*; do
        [[ -d "$stack_path" ]] || continue
        find_compose_file "$stack_path" >/dev/null || continue
        names+=("$(basename "$stack_path")")
    done
    dsb_status coverage-report \
        --stack-base "$stack_base" --appdata "$APPDATA_PATH" --run-kind "$RUN_KIND" \
        --exemptions "$COVERAGE_EXEMPTIONS_FILE" \
        --ignore-paths "$COVERAGE_IGNORE_PATHS" \
        -- "${names[@]+"${names[@]}"}"
}

# Run main function
main "$@"
