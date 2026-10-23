#!/bin/bash

#######################################
# Shared library for docker-stack-backup scripts
# Source this file; do not execute directly.
#######################################

[[ "${BASH_SOURCE[0]}" == "$0" ]] && echo "lib.sh: source this file, do not execute directly" && exit 1

# Release version, logged in every run header and included in notifications.
# shellcheck disable=SC2034  # used in sourcing scripts
DSB_VERSION="0.8.0"

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
# printable <text...> — the text with every control byte (LF, ESC, BEL, …) replaced by
# '?'. For names read from the backup share on their way to a log line or the terminal:
# printf %s stops escape *interpretation* but passes raw bytes, so a share name holding a
# real LF or ESC could still forge a log line or drive root's terminal (audit p3a R2-01).
# UTF-8-encoded C1 controls (C2 80-9F, e.g. U+009B CSI) are replaced too, byte-wise under
# LC_ALL=C: in the C/POSIX locale [[:cntrl:]] does not see them (round 3, F-04). A lone
# 0x80-0x9f byte is left alone; it is invalid UTF-8 that UTF-8 terminals ignore, and
# stripping such bytes would corrupt valid characters like "—" (E2 80 94).
printable() {
    local s="$*"
    s="${s//[[:cntrl:]]/?}"
    local LC_ALL=C
    printf '%s' "${s//$'\xc2'[$'\x80'-$'\x9f']/?}"
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $(printable "$@")" | tee -a "${LOG_FILE:-/dev/stderr}"
}

# Coloured line on the terminal, plain line in LOG_FILE: tee-ing the coloured line put
# raw escape codes into every log reader's input. With no LOG_FILE, the coloured line
# goes to stdout and stderr, as before. Escapes are interpreted in the colour codes
# only; the message is printed as data (%s), with control bytes made visible (printable). Messages carry names read from the backup
# share, and `echo -e` turned a literal "\n" in an archive filename into a forged log
# line (audit p3a F-02).
_log_tagged() {
    local color="$1" tag="$2"; shift 2
    local msg; msg=$(printable "$@")
    if [[ -z "${LOG_FILE:-}" ]]; then
        printf '%b%s%b %s\n' "$color" "$tag" "$NC" "$msg" | tee -a /dev/stderr
        return
    fi
    printf '%b%s%b %s\n' "$color" "$tag" "$NC" "$msg"
    printf '%s %s\n' "$tag" "$msg" >> "$LOG_FILE"
}

log_error() {
    _log_tagged "$RED" "[ERROR]" "$@"
}

log_success() {
    _log_tagged "$GREEN" "[SUCCESS]" "$@"
}

log_warning() {
    _log_tagged "$YELLOW" "[WARNING]" "$@"
}

#######################################
# File locking
# Requires: LOCK_FILE, LOCK_FD to be set by caller
#######################################
# open_lock_file — opens LOCK_FILE on fd LOCK_FD, read-write, without truncating it and
# without following a symlink (#1186). The lock dir is often the backup user's own
# (~/run): with `exec 200>file`, a symlink planted there made a root run truncate its
# target. So: refuse a symlink or a non-regular file, open with `<>` (O_CREAT, no
# O_TRUNC), then check that the open fd and an lstat of the path name the same inode, so
# a swap between the check and the open is refused too. The PID is written through the
# fd's /proc link only after that check. Residuals (bash has no O_NOFOLLOW): a device node
# swapped in between the lstat and the open still has its open handler run, and a
# dangling symlink swapped in there makes the open create an empty file at its target
# before the inode check refuses it. The lock dir must not be writable by anyone the
# backup user does not trust; a root run should use a root-owned LOCK_FILE dir.
open_lock_file() {
    [[ "${LOCK_FD:-200}" =~ ^[0-9]+$ ]] || LOCK_FD=200
    : "${LOCK_FD:=200}" "${LOCK_FILE:=/var/run/docker-stack-backup.lock}"
    if [[ -L "$LOCK_FILE" ]]; then
        log_error "Lock file is a symlink, refusing to open it: $LOCK_FILE"
        return 1
    fi
    if [[ -e "$LOCK_FILE" && ! -f "$LOCK_FILE" ]]; then
        log_error "Lock file is not a regular file, refusing to open it: $LOCK_FILE"
        return 1
    fi
    # shellcheck disable=SC2016  # $LOCK_FILE is expanded by eval, as a quoted word
    eval "exec $LOCK_FD"'<>"$LOCK_FILE"' || return 1
    local path_id fd_id
    path_id=$(stat -c '%d:%i' -- "$LOCK_FILE" 2>/dev/null) || path_id=""
    fd_id=$(stat -L -c '%d:%i' -- "/proc/$$/fd/$LOCK_FD" 2>/dev/null) || fd_id=""
    if [[ -z "$path_id" || "$path_id" != "$fd_id" ]]; then
        eval "exec $LOCK_FD>&-"
        log_error "Lock file was replaced while it was being opened, refusing it: $LOCK_FILE"
        return 1
    fi
    # What was opened must be a regular file too: a FIFO swapped in before the open, and
    # left there, passes the inode check.
    if [[ ! -f "/proc/$$/fd/$LOCK_FD" ]]; then
        eval "exec $LOCK_FD>&-"
        log_error "Lock file is not a regular file, refusing it: $LOCK_FILE"
        return 1
    fi
}

acquire_lock() {
    open_lock_file || exit 1

    if ! flock -n "$LOCK_FD"; then
        log_error "Another backup is already running (lock file: $LOCK_FILE)"
        log_error "If you're sure no backup is running, remove: $LOCK_FILE"
        exit 1
    fi

    # Through the fd's own /proc link: the inode just checked, truncated, then the PID.
    printf '%s\n' "$$" > "/proc/$$/fd/$LOCK_FD" 2>/dev/null || true
    LOCK_HELD=true
    log "Lock acquired (PID: $$)"
}

# Only the process that holds the lock releases it. A run that found the lock held used
# to `rm -f` the lock file on its way out: the running backup kept its flock on an inode
# with no name, and a third run then created a new file, got the lock, and ran
# alongside the first (vikunja#1158).
release_lock() {
    [[ "${LOCK_HELD:-false}" == true ]] || return 0
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u $LOCK_FD 2>/dev/null || true
    fi
    rm -f "${LOCK_FILE:-}" 2>/dev/null || true
    LOCK_HELD=false
    log "Lock released"
}

#######################################
# Running services
# Prints the services `docker compose ps` reports as running for the stack at $1.
# Returns:
#   0 — the answer can be trusted (the list may be empty: genuinely nothing running)
#   1 — it cannot be determined: `docker compose ps` failed (YAML error, unset
#       ${VAR:?}, …) or the cross-check below failed. Callers must treat the stack as
#       FAILED, never as stopped — an empty list from a failed `ps` once sent a running
#       stack down the "archive as-is" path.
#   3 — compose reports nothing running, but `docker ps` sees running containers whose
#       compose working_dir label is this stack dir. Same treatment as 1.
# The cross-check reads container labels only, so it does not depend on the compose
# file parsing. Label filters with the same key are ANDed by docker, hence one query per
# spelling of the path (as given, and symlink-resolved).
# A third, path-independent query asks docker for running containers that bind-mount
# $APPDATA_PATH/<stack> itself (docker matches a bind mount's source, or a mount
# destination, against `--filter volume=`). It catches a stack started under a different
# project name AND through a different path spelling, e.g. via a symlink: compose
# stores the unresolved path in the label, so neither label query matches (#1090
# R2-02). It misses containers that mount only subdirectories of the appdata dir. A hit
# from another stack's container that binds this stack's appdata also returns 3: that
# appdata is live, so archiving it "stopped" would not be consistent either.
# Requires: LOG_FILE (compose/docker stderr is appended there); APPDATA_PATH for the
# third query (skipped when unset)
#######################################
get_running_services() {
    local stack_path="$1"
    local out rc=0
    out=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>>"${LOG_FILE:-/dev/null}") || rc=$?
    if [[ $rc -ne 0 ]]; then
        return 1
    fi

    if [[ -z "$out" ]]; then
        local resolved; resolved=$(cd "$stack_path" && pwd -P) || resolved="$stack_path"
        local dir live
        for dir in "$stack_path" "$resolved"; do
            live=$(docker ps -q --filter "label=com.docker.compose.project.working_dir=$dir" --filter "status=running" 2>>"${LOG_FILE:-/dev/null}") || return 1
            if [[ -n "$live" ]]; then
                return 3
            fi
            [[ "$resolved" == "$stack_path" ]] && break
        done
        if [[ -n "${APPDATA_PATH:-}" ]]; then
            live=$(docker ps -q --filter "volume=$APPDATA_PATH/$(basename "$stack_path")" --filter "status=running" 2>>"${LOG_FILE:-/dev/null}") || return 1
            if [[ -n "$live" ]]; then
                return 3
            fi
        fi
    fi

    printf '%s' "$out"
}

#######################################
# Numeric config validation
# validate_uint <VAR_NAME> <min> <max>: VAR must be a plain decimal integer within
# [min, max]. The value is normalised with 10# so a leading zero is never read as octal
# by bash arithmetic ("08" is an error there, "010" is 8), and the length cap rules out
# int64 overflow. Logs and returns 1 on failure; the caller exits.
#######################################
validate_uint() {
    local name="$1" min="$2" max="$3"
    local val="${!name:-}"
    if [[ ! "$val" =~ ^[0-9]+$ || ${#val} -gt 15 ]]; then
        log_error "$name must be a non-negative integer between $min and $max (got: '$val')"
        return 1
    fi
    val=$((10#$val))
    if (( val < min || val > max )); then
        log_error "$name must be between $min and $max (got: $val)"
        return 1
    fi
    printf -v "$name" '%s' "$val"
}

# Validates every numeric setting the backup scripts do arithmetic with. A typo must
# stop the run, not silently disable a check (e.g. MIN_FREE_GB=5G used to make the
# free-space preflight pass).
validate_numeric_config() {
    local ok=0
    validate_uint MIN_FREE_GB 0 1048576 || ok=1
    validate_uint MAX_RESTART_ATTEMPTS 1 100 || ok=1
    validate_uint RESTART_RETRY_DELAY 0 3600 || ok=1
    validate_uint PARALLEL_THREADS 0 1024 || ok=1
    validate_uint FULL_RUN_DAY 1 7 || ok=1
    return $ok
}

#######################################
# Run kind
# full on FULL_RUN_DAY (1 = Monday … 7 = Sunday, `date +%u`) or with --full
# (FORCE_FULL_RUN=true); daily otherwise. On a daily run the x-backup `weekly` paths are
# left out (deferred); on a full run only the `exclude` paths are. The weekly tar (p5b)
# keys off this same function: keep it the one place the rule lives.
#######################################
FULL_RUN_DAY="${FULL_RUN_DAY:-7}"

resolve_run_kind() {
    # Compared as numbers: "07" is day 7 (validate_uint accepts and normalises it, but this
    # may run before the validation, e.g. for --coverage-report). A value that is not 1-2
    # digits never matches, and validate_numeric_config then stops the run.
    local day="${FULL_RUN_DAY:-7}" today
    today=$(date +%u)
    if [[ "${FORCE_FULL_RUN:-false}" == true ]] || \
       { [[ "$day" =~ ^[0-9]{1,2}$ ]] && (( 10#$day == 10#$today )); }; then
        echo full
    else
        echo daily
    fi
}

#######################################
# Backends (USAGE.md "Backends", RESTIC.md)
# BACKENDS: "tar", "restic" or "tar restic" (a space-separated string). TAR_SCHEDULE:
# daily (every run) or full (only on a full run, resolve_run_kind). restic, when enabled,
# runs on every run. Defaults keep 0.7.0's behaviour: tar only, every run.
# The restic repository, its password, the user it runs as and the binary are constants
# of the root helper (RESTIC_HELPER_PATH), never config.sh keys: config.sh is writable by
# the backup user, and on some hosts tracked in git.
#######################################
BACKENDS="${BACKENDS:-tar}"
TAR_SCHEDULE="${TAR_SCHEDULE:-daily}"
RESTIC_HELPER_PATH="${RESTIC_HELPER_PATH:-}"
RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-7}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-4}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-6}"
# full | daily | never: on which runs prune and check run (after every stack).
RESTIC_PRUNE_ON="${RESTIC_PRUNE_ON:-full}"
RESTIC_CHECK_ON="${RESTIC_CHECK_ON:-full}"
# auto (rotating n/12, see restic_check_subset), n/N, or x% (restic --read-data-subset).
RESTIC_CHECK_SUBSET="${RESTIC_CHECK_SUBSET:-auto}"
RESTIC_CHECK_PARTS=12

# backend_enabled <tar|restic>
backend_enabled() {
    [[ " $BACKENDS " == *" $1 "* ]]
}

# tar_scheduled <run_kind> — tar runs on this run.
tar_scheduled() {
    backend_enabled tar && { [[ "$TAR_SCHEDULE" == daily ]] || [[ "$1" == full ]]; }
}

# schedule_due <full|daily|never> <run_kind>
schedule_due() {
    case "$1" in
        daily) return 0 ;;
        full)  [[ "$2" == full ]] ;;
        *)     return 1 ;;
    esac
}

# Logs and returns 1 for any invalid backend setting. Run before anything is stopped.
validate_backends() {
    local ok=0 b seen=" "
    local -a words=()
    read -r -a words <<< "${BACKENDS:-}"
    if [[ ${#words[@]} -eq 0 ]]; then
        log_error "BACKENDS must name tar, restic or both (got: '$(printable "${BACKENDS:-}")')"
        return 1
    fi
    for b in "${words[@]}"; do
        if [[ "$b" != tar && "$b" != restic ]] || [[ "$seen" == *" $b "* ]]; then
            log_error "BACKENDS must be tar, restic or \"tar restic\" (got: '$(printable "$BACKENDS")')"
            return 1
        fi
        seen+="$b "
    done
    BACKENDS="${seen# }"; BACKENDS="${BACKENDS% }"
    case "${TAR_SCHEDULE:-}" in
        daily) ;;
        full)
            if ! backend_enabled tar; then
                log_error "TAR_SCHEDULE=full needs tar in BACKENDS"
                ok=1
            elif ! backend_enabled restic; then
                # Daily runs would then back up nothing at all.
                log_error "TAR_SCHEDULE=full needs restic in BACKENDS too: daily runs would back up nothing"
                ok=1
            fi
            ;;
        *) log_error "TAR_SCHEDULE must be daily or full (got: '$(printable "${TAR_SCHEDULE:-}")')"; ok=1 ;;
    esac
    if backend_enabled restic; then
        if [[ -z "${RESTIC_HELPER_PATH:-}" ]]; then
            log_error "BACKENDS includes restic but RESTIC_HELPER_PATH is not set (RESTIC.md)"
            ok=1
        elif [[ ! -f "$RESTIC_HELPER_PATH" ]]; then
            log_error "RESTIC_HELPER_PATH not found: $(printable "$RESTIC_HELPER_PATH")"
            ok=1
        fi
        validate_uint RESTIC_KEEP_DAILY 0 1000 || ok=1
        validate_uint RESTIC_KEEP_WEEKLY 0 1000 || ok=1
        validate_uint RESTIC_KEEP_MONTHLY 0 1000 || ok=1
        local key
        for key in RESTIC_PRUNE_ON RESTIC_CHECK_ON; do
            case "${!key:-}" in
                full|daily|never) ;;
                *) log_error "$key must be full, daily or never (got: '$(printable "${!key:-}")')"; ok=1 ;;
            esac
        done
        local LC_ALL=C pattern
        # The helpers' rule for a global exclude: one that restic's helper would refuse
        # would fail every stack's restic backup, so stop here instead.
        for pattern in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
            if [[ ! "$pattern" =~ ^[A-Za-z0-9._/*-]+$ || "$pattern" == -* ]]; then
                log_error "EXCLUDE_PATTERNS entry '$(printable "$pattern")' is not allowed with restic: only A-Z a-z 0-9 . _ / * - (one pattern per array entry)"
                ok=1
            fi
        done
        # restic's own range rule (0.18 checkFlags), as the helper applies it, so a bad value
        # stops the run here and not at every full run's check: n/N with 1 <= n <= N <= 256,
        # or x% above 0 and at most 100 (audit p5b CR-02, R2-01).
        local subset="${RESTIC_CHECK_SUBSET:-}" subset_ok=false
        if [[ "$subset" == auto ]]; then
            subset_ok=true
        elif [[ "$subset" =~ ^([0-9]{1,4})/([0-9]{1,4})$ ]]; then
            (( 10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= 10#${BASH_REMATCH[2]} \
               && 10#${BASH_REMATCH[2]} <= 256 )) && subset_ok=true
        elif [[ "$subset" =~ ^([0-9]{1,3})(\.([0-9]{1,2}))?%$ ]]; then
            local whole=$((10#${BASH_REMATCH[1]})) frac="${BASH_REMATCH[3]:-0}"
            if { (( whole > 0 )) || [[ ! "$frac" =~ ^0+$ ]]; } \
               && { (( whole < 100 )) || { (( whole == 100 )) && [[ "$frac" =~ ^0+$ ]]; }; }; then
                subset_ok=true
            fi
        fi
        if [[ "$subset_ok" != true ]]; then
            log_error "RESTIC_CHECK_SUBSET must be auto, n/N (1 <= n <= N <= 256) or x% (above 0, at most 100) (got: '$(printable "$subset")')"
            ok=1
        fi
    fi
    return $ok
}

# restic_check_subset <full|daily> — the --read-data-subset for this run's check. auto:
# n/12 with n rotating once per check period (a week when checks run on full runs, a
# day when daily), counted from the Unix epoch, so twelve consecutive checks read every
# pack once whatever the run day (USAGE.md "restic check").
restic_check_subset() {
    if [[ "$RESTIC_CHECK_SUBSET" != auto ]]; then
        echo "$RESTIC_CHECK_SUBSET"
        return
    fi
    local period=604800
    [[ "$RESTIC_CHECK_ON" == daily ]] && period=86400
    echo "$(( $(date +%s) / period % RESTIC_CHECK_PARTS + 1 ))/$RESTIC_CHECK_PARTS"
}

# restic_helper <verb> [args...] — the root-owned docker-backup-restic.sh, through
# ELEVATION_CMD, or directly when already root (ELEVATION_CMD=none). As snapshot_helper.
restic_helper() {
    case "${ELEVATION_CMD:-none}" in
        # Already root: the helper must see root as its invoker, not a SUDO_UID left in
        # the environment by `sudo -i` or a wrapper (it would refuse root's temp dir).
        none)      env -u SUDO_UID -u SUDO_GID -u SUDO_USER -u DOAS_USER "$RESTIC_HELPER_PATH" "$@" ;;
        sudo|doas) "$ELEVATION_CMD" "$RESTIC_HELPER_PATH" "$@" ;;
        *) log_error "Unsupported ELEVATION_CMD: '$(printable "${ELEVATION_CMD:-}")' (expected: none | sudo | doas)"; return 2 ;;
    esac
}

# restic_problem_for_rc <exit code> — the run-level reason for a restic helper failure.
restic_problem_for_rc() {
    case "$1" in
        10) echo restic-repo-missing ;;
        11) echo restic-repo-locked ;;
        12) echo restic-password-wrong ;;
        2)  echo restic-helper-refused ;;
        *)  echo restic-repo-error ;;
    esac
}

#######################################
# Reading the backup share as its owner (#1089)
# Archives are written 0600 and run dirs 0700, so on an NFS export with root squash,
# root (squashed to nobody) can read neither. Restore and verify, which run as root, read
# the share AS THE OWNER of what they read: `as_owner_of <path> <cmd...>` runs cmd with
# the uid/gid that own <path> (setpriv, no supplementary groups, no new privileges) when
# root and the owner is not root, and as is otherwise. Only the read runs as the owner;
# extracting still runs as root, so restored files keep their recorded owners.
#######################################
as_owner_of() {
    local path="$1"; shift
    if [[ $EUID -ne 0 ]]; then
        "$@"
        return
    fi
    local owner
    owner=$(stat -c '%u:%g' -- "$path" 2>/dev/null) || owner=""
    if [[ ! "$owner" =~ ^[0-9]+:[0-9]+$ ]]; then
        log_error "Cannot stat $(printable "$path") to read it as its owner"
        return 1
    fi
    if [[ "${owner%%:*}" == 0 ]]; then
        "$@"
        return
    fi
    setpriv --reuid="${owner%%:*}" --regid="${owner##*:}" --clear-groups --no-new-privs -- "$@"
}

# share_dir_readable <owner_path> <dir> — <dir> can be listed as <owner_path>'s owner. The
# listings run with stderr discarded, so without this an unreadable dir would look empty.
share_dir_readable() {
    as_owner_of "$1" test -d "$2" -a -r "$2" -a -x "$2" 2>/dev/null
}

#######################################
# Platform profiles
# PLATFORM=auto|debian|truenas. A profile sets defaults only: a value set in config.sh
# or the environment always wins. Call after detect_os and config.sh, before the
# scripts' own ${VAR:-default} lines.
#   debian:  ELEVATION_CMD=sudo (only when not root and ELEVATION_HELPER_PATH is set:
#            otherwise the run stops at the privilege check, as before),
#            SNAPSHOT_BACKEND=auto
#   truenas: ELEVATION_CMD=none (runs as root), SNAPSHOT_BACKEND=zfs
#   generic: no defaults (an OS neither profile recognises)
# A snapshot backend that comes from a profile is a preference, not a demand: with no
# usable snapshot helper it resolves to none (reported), where the same value set in
# config.sh fails the preflight.
# TrueNAS SCALE's /etc/os-release says ID=debian, so it is recognised by its middleware
# client (midclt) or by detect_os's /etc/version check; see OS_COMPATIBILITY.md.
#######################################
detect_platform() {
    if [[ "${OS_TYPE:-}" == truenas ]] || command -v midclt >/dev/null 2>&1; then
        echo truenas
    else
        case "${OS_TYPE:-}" in
            debian|ubuntu|proxmox) echo debian ;;
            *) echo generic ;;
        esac
    fi
}

apply_platform_defaults() {
    PLATFORM="${PLATFORM:-auto}"
    PLATFORM_INVALID=false
    case "$PLATFORM" in
        auto)           RESOLVED_PLATFORM=$(detect_platform) ;;
        debian|truenas) RESOLVED_PLATFORM="$PLATFORM" ;;
        *)              RESOLVED_PLATFORM=generic; PLATFORM_INVALID=true ;;
    esac
    if [[ -n "${SNAPSHOT_BACKEND:-}" ]]; then
        SNAPSHOT_BACKEND_SOURCE=config
    else
        SNAPSHOT_BACKEND_SOURCE=profile
    fi
    case "$RESOLVED_PLATFORM" in
        debian)
            if [[ -z "${ELEVATION_CMD:-}" && $EUID -ne 0 && -n "${ELEVATION_HELPER_PATH:-}" ]]; then
                ELEVATION_CMD=sudo
            fi
            SNAPSHOT_BACKEND="${SNAPSHOT_BACKEND:-auto}"
            ;;
        truenas)
            ELEVATION_CMD="${ELEVATION_CMD:-none}"
            SNAPSHOT_BACKEND="${SNAPSHOT_BACKEND:-zfs}"
            ;;
    esac
    SNAPSHOT_BACKEND="${SNAPSHOT_BACKEND:-none}"
}

# Logs and returns 1 for a PLATFORM value apply_platform_defaults did not recognise.
validate_platform() {
    if [[ "${PLATFORM_INVALID:-false}" == true ]]; then
        log_error "PLATFORM must be auto, debian or truenas (got: '$(printable "$PLATFORM")')"
        return 1
    fi
}

#######################################
# Restart with retry
# Starts the services that were running before the backup stopped them. Uses
# `docker compose start`, which restarts the existing (stopped) containers: no image
# pull, no recreation, no compose-file changes applied, container writable layers
# kept. Only if `start` fails (e.g. a container was removed between stop and start)
# does it fall back to `up -d --no-recreate --pull never --no-build --no-deps`, which
# creates the missing containers of exactly these services from images already present
# locally: no existing container is recreated, nothing is pulled, no `build:` service is
# built (a build would fetch its base image and apply the working-tree Dockerfile), and
# no dependency that was not running before is started. A missing image therefore fails
# the fallback (-> CRITICAL notification) instead of being fetched.
# Defaults are applied with ${VAR:-…} so the environment or config.sh can override.
# Requires: LOG_FILE
#######################################
MAX_RESTART_ATTEMPTS="${MAX_RESTART_ATTEMPTS:-3}"
RESTART_RETRY_DELAY="${RESTART_RETRY_DELAY:-5}"

restart_stack_with_retry() {
    local stack_path="$1"
    local stack_name; stack_name=$(basename "$stack_path")
    local running_containers="$2"
    local attempt=1

    while [[ $attempt -le $MAX_RESTART_ATTEMPTS ]]; do
        log "Starting containers (attempt $attempt/$MAX_RESTART_ATTEMPTS)..."

        # SECURITY[accepted]: $running_containers is intentionally unquoted — word-splitting
        # passes each service name as a separate argument to docker compose. Values come from
        # `docker compose ps --services` (operator-controlled). Audit: 2026-06-19/docker-stack-backup-2026-06.
        local started=false
        # shellcheck disable=SC2086
        if (cd "$stack_path" && docker compose start $running_containers 2>&1 | tee -a "$LOG_FILE"); then
            started=true
        else
            log_warning "docker compose start failed for $stack_name — falling back to the deploy path: up -d --no-recreate --pull never --no-build --no-deps"
            # shellcheck disable=SC2086
            if (cd "$stack_path" && docker compose up -d --no-recreate --pull never --no-build --no-deps $running_containers 2>&1 | tee -a "$LOG_FILE"); then
                started=true
            fi
        fi

        if [[ "$started" == true ]]; then
            sleep 2
            local now_running; now_running=$(cd "$stack_path" && docker compose ps --services --filter "status=running" 2>/dev/null) || now_running=""
            local expected_count; expected_count=$(echo "$running_containers" | wc -w)
            # Count the expected services that are running. A dependency compose
            # started on its own is not one of them and must not skew the count.
            local started_count=0 svc
            for svc in $running_containers; do
                if grep -qxF "$svc" <<< "$now_running"; then
                    started_count=$((started_count + 1))
                fi
            done

            if [[ $started_count -eq $expected_count ]]; then
                log_success "All containers started successfully"
                return 0
            else
                log_warning "Only $started_count of $expected_count containers started"
            fi
        fi

        if [[ $attempt -lt $MAX_RESTART_ATTEMPTS ]]; then
            log_warning "Restart failed, waiting ${RESTART_RETRY_DELAY}s before retry..."
            sleep "$RESTART_RETRY_DELAY"
        fi

        attempt=$((attempt + 1))
    done

    log_error "Failed to restart stack after $MAX_RESTART_ATTEMPTS attempts"
    log_error "Stack: $stack_name"
    log_error "Containers that should be running: $running_containers"
    log_error "Manual intervention required!"
    log_error "To restart manually: cd $stack_path && docker compose start $running_containers"

    send_critical_restart_failure "$stack_name" "$stack_path" "$running_containers"

    return 1
}

#######################################
# Post-restart hooks
# Runs each entry in POST_RESTART_HOOKS after a stack's containers restart. Each entry
# is a shell function name (defined in config.sh) or a command name, invoked as:
#   <hook> <stack_name> <stack_path>
# A non-zero hook exit is logged as a warning and does NOT abort the backup — a broken
# hook must not fail an otherwise-successful run. See HOOKS.md.
# Requires: POST_RESTART_HOOKS array, LOG_FILE
#######################################
run_post_restart_hooks() {
    local stack_name="$1"
    local stack_path="$2"

    local hook rc
    for hook in "${POST_RESTART_HOOKS[@]+"${POST_RESTART_HOOKS[@]}"}"; do
        [[ -z "$hook" ]] && continue
        log "Running post-restart hook: $hook ($stack_name)"
        rc=0
        "$hook" "$stack_name" "$stack_path" || rc=$?
        if [[ $rc -eq 0 ]]; then
            log_success "Post-restart hook succeeded: $hook ($stack_name)"
        else
            log_warning "Post-restart hook failed (exit $rc): $hook ($stack_name) — continuing"
        fi
    done
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
Version: ${DSB_VERSION}

Manual restart command:
cd $stack_path && docker compose start $containers

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

    # Pass token via --config/-K to keep it off the process table (ps aux)
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        curl_args+=(-K <(printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN"))
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

    # Build POST body via python3 to keep token/user_key off the process table.
    # python3 is already required for Matrix URL encoding (see README).
    if command -v python3 &>/dev/null; then
        local post_data
        post_data=$(python3 -c "
import urllib.parse, sys
token, user, title, message, priority = sys.argv[1:6]
print(urllib.parse.urlencode({'token': token, 'user': user,
    'title': title, 'message': message, 'priority': priority}))
" "$PUSHOVER_API_TOKEN" "$PUSHOVER_USER_KEY" "$title" "$message" "$priority")
        if ! printf '%s' "$post_data" | curl -s -XPOST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data-binary @- \
            https://api.pushover.net/1/messages.json >/dev/null 2>&1; then
            log_error "Failed to send Pushover notification"
        fi
    else
        # SECURITY[control]: fallback only on hosts without python3; secrets visible in ps.
        # README lists python3 as a requirement. Audit: 2026-06-19/docker-stack-backup-2026-06.
        if ! curl -s \
            --form-string "token=$PUSHOVER_API_TOKEN" \
            --form-string "user=$PUSHOVER_USER_KEY" \
            --form-string "title=$title" \
            --form-string "message=$message" \
            --form-string "priority=$priority" \
            https://api.pushover.net/1/messages.json >/dev/null 2>&1; then
            log_error "Failed to send Pushover notification"
        fi
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

    # Pass credentials via --config/-K to keep them off the process table (ps aux)
    if [[ -n "${SMTP_USER:-}" ]] && [[ -n "${SMTP_PASSWORD:-}" ]]; then
        curl_args+=(-K <(printf 'user = "%s:%s"\n' "$SMTP_USER" "$SMTP_PASSWORD"))
    fi

    if [[ "${SMTP_INSECURE:-false}" == true ]]; then
        # SECURITY[accepted]: --insecure disables TLS cert verification. Opt-in only (default false).
        # Documented use case: Proton Mail Bridge self-signed cert. Audit: 2026-06-19/docker-stack-backup-2026-06.
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

    # Pass token via --config/-K to keep it off the process table (ps aux)
    curl -s -XPUT \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$MATRIX_ACCESS_TOKEN") \
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
    local details="${6:-}"

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
⊘ Skipped: $skipped
✗ Failed: $failed
━━━━━━━━━━━━━━━━━━━━
Total stacks: $total
Host: $HOSTNAME
Version: ${DSB_VERSION}
Time: $(date +'%Y-%m-%d %H:%M:%S')"
    else
        title="Docker Backup FAILED - $HOSTNAME"
        priority="high"
        tags="x,backup,warning"
        message="Backup completed with errors

✓ Successfully backed up: $backed_up
⊘ Skipped: $skipped
✗ FAILED: $failed
━━━━━━━━━━━━━━━━━━━━
Total stacks: $total
Host: $HOSTNAME
Version: ${DSB_VERSION}
Time: $(date +'%Y-%m-%d %H:%M:%S')

Check logs: ${LOG_FILE:-}"
    fi

    # SECURITY[accepted]: the per-stack details (stack names, skip reasons, stopped and
    # failed stacks) go to every enabled notification channel, third-party ones included.
    # Names are operator-controlled directory names; every channel passes the body as data
    # (python argv JSON, --form-string, -d body, mail body). Audit: 2026-10-13/docker-stack-backup-2026-10-p1-correctness (F-05).
    if [[ -n "$details" ]]; then
        message="$message"$'\n\n'"$details"
    fi

    # Ntfy honors NTFY_URGENT_ONLY: when true, ntfy fires on failure only — even if
    # NOTIFY_ON_SUCCESS is true. Every other channel still follows the global toggles
    # above. This supports "one loud channel (e.g. Matrix), one urgent-only channel".
    if [[ "$status" == "success" && "${NTFY_URGENT_ONLY:-false}" == true ]]; then
        log "Ntfy: skipping success notification (NTFY_URGENT_ONLY=true)"
    else
        send_ntfy "$title" "$message" "$priority" "$tags"
    fi
    send_pushover "$title" "$message" "$([ "$status" == "failure" ] && echo 1 || echo 0)"
    send_email "${EMAIL_SUBJECT_PREFIX:-[Docker Backup]} $title" "$message"
    send_matrix "$title" "$message"
}

#######################################
# x-backup declared paths (USAGE.md "Backup tiers")
# DECLARED_EXCLUDES holds this stack's paths to leave out of this run, relative to
# $APPDATA_PATH/<stack>. dsb_status.py validated them; they are checked again here, and
# again by the root helper, because they end up as tar arguments.
#######################################
DECLARED_EXCLUDES=()

# valid_declared_path <path> — the same rule as dsb_status.py xb_path_error and the tar
# helper: '/'-separated components of [A-Za-z0-9._-], none empty, '.', '..' or starting
# with '-', at most 255 bytes, relative.
valid_declared_path() {
    local p="$1" c
    local -a comps=()
    # [A-Za-z] is ASCII only in the C locale: in en_US.UTF-8 it matches 'é' too.
    local LC_ALL=C
    # The whole string first: no glob, space or control byte ever reaches the split.
    [[ "$p" =~ ^[A-Za-z0-9._/-]+$ && ${#p} -le 255 ]] || return 1
    [[ "$p" != /* && "$p" != */ && "$p" != *//* ]] || return 1
    IFS=/ read -r -a comps <<< "$p"
    for c in "${comps[@]}"; do
        [[ "$c" =~ ^[A-Za-z0-9._-]+$ && "$c" != -* && "$c" != . && "$c" != .. ]] || return 1
    done
    return 0
}

# read_xbackup <stack_path> <stack_name> <run_kind> <out_file> — fills DECLARED_EXCLUDES.
# Any failure leaves it empty: the stack is backed up in full (a declaration may only
# narrow a backup, and one that cannot be read narrows nothing). Diagnostics go to the
# log. Requires: SCRIPT_DIR, APPDATA_PATH, LOG_FILE
read_xbackup() {
    local stack_path="$1" stack_name="$2" run_kind="$3" out="$4"
    DECLARED_EXCLUDES=()
    command -v python3 >/dev/null 2>&1 || return 0
    local -a paths=()
    local diag; diag=$(mktemp) || return 0
    local list; list=$(mktemp) || { rm -f -- "$diag"; return 0; }
    # Through a file, not a process substitution, so python's exit status is seen: a
    # reader that failed part-way (a truncated last path would still be a valid path)
    # excludes nothing.
    local rc=0
    python3 -I "$SCRIPT_DIR/dsb_status.py" xbackup \
        --stack-path "$stack_path" --appdata-dir "$APPDATA_PATH/$stack_name" \
        --run-kind "$run_kind" --out "$out" > "$list" 2>"$diag" || rc=$?
    if [[ $rc -eq 0 ]]; then
        mapfile -d '' -t paths < "$list" || paths=()
    else
        log_warning "$stack_name: x-backup reader failed (exit $rc); backing up in full"
        rm -f -- "$out"
    fi
    local line
    while IFS= read -r line; do
        log_warning "$stack_name: $line"
    done < "$diag"
    rm -f -- "$diag" "$list"
    local p
    for p in "${paths[@]+"${paths[@]}"}"; do
        if ! valid_declared_path "$p"; then
            log_error "$stack_name: x-backup reader returned an invalid path; backing up in full"
            DECLARED_EXCLUDES=()
            return 0
        fi
        DECLARED_EXCLUDES+=("$p")
    done
}

#######################################
# Snapshot-assisted backup (USAGE.md "Snapshots")
# Every snapshot operation goes through the root-owned helper docker-backup-snapshot.sh,
# whose own constants decide every path. The caller passes verbs, a stack name and the
# run timestamp only. Called through ELEVATION_CMD, or directly when already root
# (ELEVATION_CMD=none): one code path.
# Requires: SNAPSHOT_HELPER_PATH, ELEVATION_CMD
#######################################
snapshot_helper() {
    case "${ELEVATION_CMD:-none}" in
        none)      "$SNAPSHOT_HELPER_PATH" "$@" ;;
        sudo|doas) "$ELEVATION_CMD" "$SNAPSHOT_HELPER_PATH" "$@" ;;
        *) log_error "Unsupported ELEVATION_CMD: '$(printable "${ELEVATION_CMD:-}")' (expected: none | sudo | doas)"; return 2 ;;
    esac
}

# resolve_snapshot_backend — sets SNAPSHOT_RESOLVED (none|btrfs|zfs) and SNAPSHOT_NOTE
# (why a requested backend resolved to none). Returns 1 only when SNAPSHOT_BACKEND was
# set explicitly (config.sh / environment) to something unusable: that fails the
# preflight. auto, and a backend that came from a platform profile, fall back to none.
# Requires: SNAPSHOT_BACKEND, SNAPSHOT_BACKEND_SOURCE, APPDATA_PATH
# shellcheck disable=SC2034  # SNAPSHOT_RESOLVED / SNAPSHOT_NOTE are read by the scripts
resolve_snapshot_backend() {
    SNAPSHOT_RESOLVED=none
    SNAPSHOT_NOTE=""
    local want="${SNAPSHOT_BACKEND:-none}" explicit=false
    case "$want" in
        none) return 0 ;;
        auto) ;;
        btrfs|zfs) [[ "${SNAPSHOT_BACKEND_SOURCE:-config}" == config ]] && explicit=true ;;
        *)
            log_error "SNAPSHOT_BACKEND must be none, auto, btrfs or zfs (got: '$(printable "$want")')"
            return 1
            ;;
    esac
    local fs; fs=$(stat -f -c %T -- "$APPDATA_PATH" 2>/dev/null) || fs=""
    if [[ "$want" == auto ]]; then
        case "$fs" in
            btrfs|zfs) want="$fs" ;;
            *)
                SNAPSHOT_NOTE="auto: $APPDATA_PATH is on ${fs:-an unknown filesystem}, not btrfs or zfs"
                return 0
                ;;
        esac
    fi
    local problem=""
    if [[ "$fs" != "$want" ]]; then
        problem="$APPDATA_PATH is on ${fs:-an unknown filesystem}, not $want"
    elif [[ -z "${SNAPSHOT_HELPER_PATH:-}" ]]; then
        problem="SNAPSHOT_HELPER_PATH is not set"
    elif [[ ! -f "$SNAPSHOT_HELPER_PATH" ]]; then
        problem="SNAPSHOT_HELPER_PATH not found: $SNAPSHOT_HELPER_PATH"
    else
        local info="" key val h_backend="" h_appdata=""
        if info=$(snapshot_helper info 2>>"${LOG_FILE:-/dev/null}"); then
            while IFS='=' read -r key val; do
                case "$key" in
                    backend) h_backend="$val" ;;
                    appdata) h_appdata="$val" ;;
                esac
            done <<< "$info"
            if [[ "$h_backend" != "$want" ]]; then
                problem="the snapshot helper is set up for '$h_backend', not $want"
            elif [[ "$h_appdata" != "$APPDATA_PATH" ]]; then
                problem="the snapshot helper's ALLOWED_APPDATA_PATH ($h_appdata) is not APPDATA_PATH"
            fi
        else
            problem="the snapshot helper's 'info' check failed (see $LOG_FILE)"
        fi
    fi
    if [[ -n "$problem" ]]; then
        if [[ "$explicit" == true ]]; then
            log_error "SNAPSHOT_BACKEND=$want: $problem"
            return 1
        fi
        SNAPSHOT_NOTE="$want: $problem"
        return 0
    fi
    SNAPSHOT_RESOLVED="$want"
}

# The run timestamp of the snapshot the next archive is made from (empty: archive the
# live appdata). Set by backup_stack around create_archive_atomic only.
ARCHIVE_SNAPSHOT_TS=""

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

    # Elevated path: when ELEVATION_CMD is set, hand archive creation to a root-owned,
    # argument-validating helper rather than running tar directly (or, worse, prefixing
    # tar with sudo — which would let crafted exclude patterns smuggle tar flags such as
    # --checkpoint-action=exec). The helper builds the tar invocation itself from a fixed
    # shape; its validation is what makes elevation safe. See ELEVATION.md / SECURITY.md.
    if [[ "${ELEVATION_CMD:-none}" != none ]]; then
        create_compressed_archive_elevated "$output_file" "${tar_args[@]}"
        return $?
    fi

    setup_compression_environment

    # Global EXCLUDE_PATTERNS first, in tar's default (unanchored, wildcard) mode, exactly
    # as before; declared paths after them. --anchored/--no-wildcards are positional:
    # they change only the --exclude options that follow, so put the other way round they
    # would turn the global globs anchored too (tests/xbackup-tar.bats).
    local exclude_args=()
    for pattern in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
        exclude_args+=(--exclude="$pattern")
    done
    if [[ ${#DECLARED_EXCLUDES[@]} -gt 0 || -n "$ARCHIVE_SNAPSHOT_TS" ]]; then
        if ! standard_layout "${tar_args[@]}"; then
            log_error "Declared excludes and snapshots need the standard layout: -C <temp_dir> . -C <appdata_path> <stack_name>"
            return 1
        fi
    fi
    if [[ ${#DECLARED_EXCLUDES[@]} -gt 0 ]]; then
        exclude_args+=(--anchored --no-wildcards)
        local p
        for p in "${DECLARED_EXCLUDES[@]}"; do
            valid_declared_path "$p" || { log_error "Invalid declared path refused"; return 1; }
            exclude_args+=(--exclude="${tar_args[5]}/$p")
        done
    fi
    if [[ -n "$ARCHIVE_SNAPSHOT_TS" ]]; then
        # Root (ELEVATION_CMD=none) reads the snapshot itself; the helper says where.
        local src; src=$(snapshot_helper source "${tar_args[5]}" "$ARCHIVE_SNAPSHOT_TS") || {
            log_error "Snapshot helper could not resolve the snapshot of ${tar_args[5]}"
            return 1
        }
        if [[ "$src" != /* || ! -d "$src/${tar_args[5]}" ]]; then
            log_error "Snapshot source for ${tar_args[5]} is not a directory"
            return 1
        fi
        tar_args[4]="$src"
    fi

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
                # NFS-safe: write via stdout redirect (the caller's shell opens the
                # output file), never `tar -cf` (tar opens it itself — fails under NFS
                # root_squash when tar runs as root).
                tar -c "${exclude_args[@]}" "${tar_args[@]}" > "$output_file"
                return $?
                ;;
        esac

        if [[ "${USE_PARALLEL:-false}" == true ]] && [[ -n "$compressor" ]]; then
            tar -c "${exclude_args[@]}" "${tar_args[@]}" | "$compressor" "${compressor_args[@]}" > "$output_file"
            return $?
        fi
    fi

    local compression_flag; compression_flag=$(get_tar_compression_flag)

    # NFS-safe: every path writes via a stdout redirect (the caller's shell opens the
    # output file) rather than `tar -f` (which makes the tar process open it — and fails
    # under NFS root_squash when that process is root). No downside for local disks.
    if [[ "$compression_flag" == "--zstd" ]]; then
        if ! check_compression_tool zstd; then
            log_error "zstd compression selected but zstd not found"
            return 1
        fi
        tar -c --zstd "${exclude_args[@]}" "${tar_args[@]}" > "$output_file"
    elif [[ -n "$compression_flag" ]]; then
        tar -c"${compression_flag}" "${exclude_args[@]}" "${tar_args[@]}" > "$output_file"
    else
        tar -c "${exclude_args[@]}" "${tar_args[@]}" > "$output_file"
    fi

    return $?
}

#######################################
# Elevated archive creation
# Routes tar through a root-owned, argument-validating helper so it can read
# root-owned appdata (and write NFS-safely) without granting a raw `sudo tar`.
# Requires: ELEVATION_CMD, ELEVATION_HELPER_PATH, COMPRESSION_METHOD, EXCLUDE_PATTERNS
#
# The helper is invoked with a fixed, structured argument list:
#   <compression> <temp_dir> <appdata_path> <stack_name> [exclude_pattern...]
# and writes the archive to stdout (no -f), which this function redirects to
# "$output_file" — the redirect runs in the *caller's* (unprivileged) context, which
# is what keeps writes to an NFS root_squash export working.
#######################################
create_compressed_archive_elevated() {
    local output_file="$1"; shift
    local tar_args=("$@")

    case "${ELEVATION_CMD:-none}" in
        sudo|doas) ;;
        *) log_error "Unsupported ELEVATION_CMD: '${ELEVATION_CMD:-}' (expected: sudo | doas)"; return 1 ;;
    esac

    if [[ -z "${ELEVATION_HELPER_PATH:-}" ]]; then
        log_error "ELEVATION_CMD=${ELEVATION_CMD} but ELEVATION_HELPER_PATH is not set"
        return 1
    fi
    # Test existence only, NOT caller-executability. The helper is installed
    # root:root 0750 by design (see SECURITY.md/ELEVATION.md), so the unprivileged
    # caller deliberately has no execute bit on it — that is the whole reason
    # ELEVATION_CMD exists. A `[[ -x ]]` test here runs from the caller's
    # perspective and so ALWAYS fails for a correctly-installed helper, aborting
    # every backup before sudo is ever reached (DSBAK-10 / #23). Whether root can
    # execute the helper is what matters; let ELEVATION_CMD surface any genuine
    # exec failure with a clear error.
    if [[ ! -f "$ELEVATION_HELPER_PATH" ]]; then
        log_error "ELEVATION_HELPER_PATH not found: $ELEVATION_HELPER_PATH"
        return 1
    fi

    # The helper only accepts the fixed archive layout this project produces:
    #   -C <temp_dir> . -C <appdata_path> <stack_name>
    # Fail closed on anything else rather than mis-invoking a privileged command.
    if ! standard_layout "${tar_args[@]}"; then
        log_error "Elevated archive creation requires the standard layout: -C <temp_dir> . -C <appdata_path> <stack_name>"
        return 1
    fi

    local temp_dir="${tar_args[1]}"
    local appdata_path="${tar_args[4]}"
    local stack_name="${tar_args[5]}"

    # With no snapshot and no declared path, the argument list is exactly 0.6.0's, so a
    # 0.6.0 helper keeps working until it is updated (CHANGELOG 0.7.0).
    local -a extra=() declared=()
    [[ -n "$ARCHIVE_SNAPSHOT_TS" ]] && extra=(--from-snapshot "$ARCHIVE_SNAPSHOT_TS")
    local p
    for p in "${DECLARED_EXCLUDES[@]+"${DECLARED_EXCLUDES[@]}"}"; do
        valid_declared_path "$p" || { log_error "Invalid declared path refused"; return 1; }
        declared+=("$stack_name/$p")
    done
    [[ ${#declared[@]} -gt 0 ]] && declared=(-- "${declared[@]}")

    "$ELEVATION_CMD" "$ELEVATION_HELPER_PATH" \
        "${COMPRESSION_METHOD:-none}" "$temp_dir" "$appdata_path" "$stack_name" \
        "${extra[@]+"${extra[@]}"}" \
        "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}" \
        "${declared[@]+"${declared[@]}"}" > "$output_file"
}

# standard_layout <tar args> — 0 if they are exactly -C <dir> . -C <dir> <stack_name>.
standard_layout() {
    [[ $# -eq 6 && "$1" == "-C" && "$3" == "." && "$4" == "-C" ]]
}

#######################################
# Atomic archive creation
# Writes the archive to <name>.incomplete next to the final file and renames it into
# place only when create_compressed_archive succeeds; on failure the partial file is
# deleted. The temporary name deliberately does not match `*.tar` / `*.tar.*`, the
# globs backup-verify.sh and docker-stack-restore.sh use to find backups, so an
# interrupted or failed archive is never mistaken for a backup.
#   $1 = final archive path (ending in get_compression_extension), rest = tar args
#######################################
# Archives (and the .incomplete file) take the process umask: the backup and manual
# scripts set umask 077 (0.8.0, #1089), so archives are 0600 and run dirs 0700. Restore
# and verify read them as their owner (as_owner_of), which also works when root is
# squashed on an NFS destination. Archives written before 0.8.0 keep their 0664 until the
# one-time chmod in RESTIC.md "Upgrading to 0.8.0".
create_archive_atomic() {
    local final_file="$1"; shift
    local ext; ext=$(get_compression_extension)
    local partial_file="${final_file%"$ext"}.incomplete"

    rm -f "$partial_file"
    if create_compressed_archive "$partial_file" "$@" && mv -f "$partial_file" "$final_file"; then
        return 0
    fi
    rm -f "$partial_file"
    return 1
}

#######################################
# Free-space requirement
# Prints the free space a run needs, in bytes: the larger of MIN_FREE_GB and 1.2 x the
# size of this host's most recent previous run dir under BACKUP_DEST/HOSTNAME (run dirs
# are named YYYYMMDD_HHMMSS, so the last in sort order is the newest). With no previous
# run, MIN_FREE_GB alone applies.
# Requires: BACKUP_DEST, HOSTNAME, TIMESTAMP; optional MIN_FREE_GB (default 5)
#######################################
required_free_bytes() {
    local min_bytes=$(( ${MIN_FREE_GB:-5} * 1024 * 1024 * 1024 ))
    local host_dir="$BACKUP_DEST/$HOSTNAME"
    local prev_dir=""

    if [[ -d "$host_dir" ]]; then
        prev_dir=$(find "$host_dir" -mindepth 1 -maxdepth 1 -type d \
            -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]' \
            ! -name "${TIMESTAMP:-}" 2>/dev/null | sort | tail -n1) || prev_dir=""
    fi

    local estimate=0
    if [[ -n "$prev_dir" ]]; then
        local prev_bytes; prev_bytes=$(du -sb "$prev_dir" 2>/dev/null | cut -f1) || prev_bytes=0
        estimate=$(( ${prev_bytes:-0} * 12 / 10 ))
    fi

    if [[ $estimate -gt $min_bytes ]]; then
        echo "$estimate"
    else
        echo "$min_bytes"
    fi
}

#######################################
# du_size <path> [-h]
# Prints the size of <path> in bytes (or human-readable with -h), and never aborts the
# caller: `$(du -sb … | cut -f1)` under pipefail killed the script whenever du met a
# path it could not read, i.e. on every root-owned appdata dir when run as a user (#1092).
# du still prints a total in that case. Returns 1 when that total excludes unreadable
# paths (an estimate), 0 when it is complete. Prints 0 if du printed nothing.
#######################################
du_size() {
    local flag="-sb"
    [[ "${2:-}" == -h ]] && flag="-sh"
    local out rc=0
    out=$(du "$flag" -- "$1" 2>/dev/null) || rc=$?
    out="${out%%[[:space:]]*}"
    echo "${out:-0}"
    [[ $rc -eq 0 ]]
}

#######################################
# Privilege check
# Requires root UNLESS ELEVATION_CMD is configured — in that case the script is
# expected to run unprivileged and elevate only the one operation the helper covers
# (archive creation). Callers whose privileged operation isn't covered by any helper
# (e.g. restore, which writes directly into appdata) should NOT use this function —
# they have no unprivileged path and must keep requiring root unconditionally.
#######################################
require_privileged_or_elevated() {
    if [[ $EUID -ne 0 && "${ELEVATION_CMD:-none}" == none ]]; then
        log_error "This script must be run as root, or configure ELEVATION_CMD/ELEVATION_HELPER_PATH to run unprivileged (see ELEVATION.md)"
        return 1
    fi
    return 0
}

#######################################
# Appdata content check
# Returns 0 ("has content, attempt backup") or 1 ("empty, skip"). Under ELEVATION_CMD,
# always returns 0 rather than testing readability directly: the unprivileged caller
# usually cannot read a root-owned appdata dir it needs elevation for in the first
# place, and `ls -A`'s permission-denied output is indistinguishable from a truly
# empty directory — treating that as "empty" would silently skip backing up exactly
# the appdata layout ELEVATION_CMD exists to handle. Let the elevated archive-creation
# call (which goes through the validated helper, running as root) be authoritative
# instead. Requires: ELEVATION_CMD
#######################################
appdata_has_content() {
    local appdata_dir="$1"
    if [[ "${ELEVATION_CMD:-none}" != none ]]; then
        return 0
    fi
    [[ -n "$(ls -A "$appdata_dir" 2>/dev/null)" ]]
}

#######################################
# Dockhand stack base path
# Returns the effective stacks root: $DOCKHAND_BASE/<hostname> by default (a shared
# stacks root nested by machine hostname, e.g. a centralized Dockhand deployment
# serving a fleet), or bare $DOCKHAND_BASE when DOCKHAND_APPEND_HOSTNAME=false (a flat
# single-host layout with no per-host subdirectory — DOCKHAND_BASE need not actually be
# managed by Dockhand; it's just "the directory containing one subdirectory per
# stack"). Optional $1 overrides which hostname to append (default: $HOSTNAME) — used
# by docker-stack-restore.sh, which restores into a possibly different host's
# subdirectory than the one it's running on.
# Requires: DOCKHAND_BASE, HOSTNAME, DOCKHAND_APPEND_HOSTNAME
#######################################
dockhand_stack_base() {
    local hostname="${1:-$HOSTNAME}"
    if [[ "${DOCKHAND_APPEND_HOSTNAME:-true}" == true ]]; then
        echo "$DOCKHAND_BASE/$hostname"
    else
        echo "$DOCKHAND_BASE"
    fi
}

#######################################
# join_by <sep> <items...> — prints items joined by sep
#######################################
join_by() {
    local sep="$1"; shift
    local out="" item
    for item in "$@"; do
        out+="${out:+$sep}$item"
    done
    printf '%s' "$out"
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
