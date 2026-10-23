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

# Where the backup comes from: tar (a run dir on the share) or restic (a snapshot in the
# repository behind RESTIC_HELPER_PATH, RESTIC.md). Steps 4-6 are the same for both: each
# reads one tar stream (archive_read).
restore_source=tar
selected_backup_file=""
selected_restic_id=""


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
# Names read from the share go into root's rm -rf / cp / mkdir paths. Hold them to the
# rule the tar-create helper applies to stack names. The dotfile-skipping globs already
# keep . and .. out, but a `shopt -s dotglob` in config.sh would silently lift that
# (audit p3a F-04).
#######################################
require_plain_name() {
    local what="$1" name="$2"
    # C locale: under en_US.UTF-8 the ranges also match é, ß, fullwidth letters (R2-02).
    local LC_ALL=C
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ || "$name" == -* || "$name" == . || "$name" == .. ]]; then
        # %q, never the raw name: the refusal must not be the way a forged line gets in
        # (R2-01).
        log_error "Refusing $what name $(printf '%q' "$name"): only ASCII letters, digits, '.', '_' and '-' are allowed"
        exit 1
    fi
}

# Run dirs are named by the backup as YYYYMMDD_HHMMSS; anything else on the share is not
# one of ours. Checked before the name reaches a path, a log line or the terminal (R2-01).
require_timestamp_name() {
    local name="$1"
    local LC_ALL=C
    if [[ ! "$name" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
        log_error "Refusing backup dir $(printf '%q' "$name"): expected YYYYMMDD_HHMMSS"
        exit 1
    fi
}

#######################################
# Select the source (only when a restic helper is configured)
#######################################
select_source() {
    restore_source=tar
    if [[ -z "${RESTIC_HELPER_PATH:-}" || ! -f "${RESTIC_HELPER_PATH:-}" ]]; then
        return 0
    fi
    print_section "Step 0: Select Backup Source"
    echo -e "  ${GREEN}1)${NC} tar archives on the share ($BACKUP_BASE)"
    echo -e "  ${GREEN}2)${NC} restic snapshots of this host"
    echo ""
    local selection; selection=$(prompt_input "Select source" "1")
    case "$selection" in
        1) restore_source=tar ;;
        2) restore_source=restic ;;
        *) log_error "Invalid selection"; exit 1 ;;
    esac
}

# The restic helper, directly: restore runs as root.
restore_restic_helper() {
    "$RESTIC_HELPER_PATH" "$@"
}

#######################################
# restic: select stack, then snapshot (Steps 2-3 of a restic restore)
#######################################
select_restic_snapshot() {
    print_section "Step 2: Select Stack (restic)"
    # The repository is this host's (the helper only lists RESTIC_HOST's snapshots).
    selected_hostname="$HOSTNAME"
    require_plain_name "host" "$selected_hostname"
    local list; list=$(mktemp)
    if ! restore_restic_helper snapshots > "$list"; then
        rm -f -- "$list"
        log_error "Could not list the restic snapshots (see the helper's message above)"
        exit 1
    fi
    # stack<TAB>id<TAB>time<TAB>kind, newest first; names and ids checked by the parser.
    local -a rows=()
    mapfile -t rows < <(python3 -I "$SCRIPT_DIR/dsb_status.py" restic-snapshots "$list")
    rm -f -- "$list"
    if [[ ${#rows[@]} -eq 0 ]]; then
        log_error "No restic snapshots found for this host"
        exit 1
    fi
    local -a stacks=()
    local row name seen=" "
    for row in "${rows[@]}"; do
        name="${row%%$'\t'*}"
        if [[ "$seen" != *" $name "* ]]; then
            stacks+=("$name")
            seen+="$name "
        fi
    done
    echo "Stacks with restic snapshots:"
    local i=1 n
    for name in "${stacks[@]}"; do
        n=$(printf '%s\n' "${rows[@]}" | grep -c "^$name"$'\t') || n=0
        printf '  %b%s)%b %s (%s snapshots)\n' "$GREEN" "$i" "$NC" "$(printable "$name")" "$n"
        ((i++))
    done
    echo ""
    local selection; selection=$(prompt_input "Select stack number" "1")
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#stacks[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    selected_stack="${stacks[$((selection-1))]}"
    require_plain_name "stack" "$selected_stack"

    print_section "Step 3: Select Snapshot (newest first)"
    local -a ids=()
    i=1
    local id t kind
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r name id t kind <<< "$row"
        [[ "$name" == "$selected_stack" ]] || continue
        ids+=("$id")
        printf '  %b%s)%b %s  %s  (%s run)\n' "$GREEN" "$i" "$NC" "${id:0:8}" "$(printable "$t")" "$(printable "$kind")"
        ((i++))
    done
    echo ""
    selection=$(prompt_input "Select snapshot number" "1")
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#ids[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    selected_restic_id="${ids[$((selection-1))]}"
    if [[ ! "$selected_restic_id" =~ ^[0-9a-f]{64}$ ]]; then
        log_error "Invalid snapshot id"
        exit 1
    fi
    printf '\n%b✓%b Selected: %b%s%b snapshot %s\n' "$GREEN" "$NC" "$BOLD" "$(printable "$selected_stack")" "$NC" "${selected_restic_id:0:8}"
}

#######################################
# The selected backup as one tar stream (Steps 4 and 6)
# archive_read <tar args...> — runs `tar <args> -f -` on the archive or the restic dump.
# A tar archive is read AS ITS OWNER, the owner of the host dir it is under (#1089): with
# root squash on the share, root cannot read a 0600 archive in a 0700 run dir. tar itself
# still runs as root, so an extract keeps the recorded owners. A restic snapshot comes from
# the helper's dump, which has the tar archive's member layout (RESTIC.md "Restore").
#######################################
archive_read() {
    if [[ "$restore_source" == restic ]]; then
        restore_restic_helper dump "$selected_stack" "$selected_restic_id" | tar "$@" -f -
        return
    fi
    # tar does not detect compression on a pipe: take it from the suffix Step 3 allowed.
    local -a z=()
    case "$selected_backup_file" in
        *.tar.gz)  z=(-z) ;;
        *.tar.bz2) z=(-j) ;;
        *.tar.xz)  z=(-J) ;;
        *.tar.zst) z=(--zstd) ;;
    esac
    as_owner_of "$(share_owner_path)" cat -- "$selected_backup_file" | tar "${z[@]+"${z[@]}"}" "$@" -f -
}

# The path whose owner reads the share: the selected host's dir (stat-able as root even
# when the run dirs below it are 0700 on a root-squashed export), else BACKUP_BASE.
share_owner_path() {
    if [[ -n "${selected_hostname:-}" ]]; then
        echo "$BACKUP_BASE/$selected_hostname"
    else
        echo "$BACKUP_BASE"
    fi
}

# share_list <dir> <find tests...> — NUL-separated names (%f) under <dir>, listed as the
# share's owner.
share_list() {
    local dir="$1"; shift
    # ! -name '.*': the globs this replaces never matched dot-names.
    as_owner_of "$(share_owner_path)" find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' "$@" -printf '%f\0' 2>/dev/null
}

#######################################
# Select hostname
#######################################
select_hostname() {
    print_section "Step 1: Select Host"
    
    local -a hostnames=()
    local i=1
    
    # Read as the share's owner (#1089); sorted, as the glob was.
    selected_hostname=""
    if ! share_dir_readable "$BACKUP_BASE" "$BACKUP_BASE"; then
        log_error "Cannot read $BACKUP_BASE as its owner"
        exit 1
    fi
    mapfile -d '' -t hostnames < <(share_list "$BACKUP_BASE" -type d | sort -z)
    
    if [[ ${#hostnames[@]} -eq 0 ]]; then
        log_error "No backup hosts found in $BACKUP_BASE"
        exit 1
    fi
    
    echo "Available hosts:"
    for hostname in "${hostnames[@]}"; do
        printf '  %b%s)%b %s\n' "$GREEN" "$i" "$NC" "$(printable "$hostname")"
        ((i++))
    done
    
    echo ""
    local selection; selection=$(prompt_input "Select host number" "1")
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#hostnames[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    selected_hostname="${hostnames[$((selection-1))]}"
    require_plain_name "host" "$selected_hostname"
    printf '\n%b✓%b Selected host: %b%s%b\n' "$GREEN" "$NC" "$BOLD" "$(printable "$selected_hostname")" "$NC"
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
    # As the share's owner (#1089): run dirs are 0700 since 0.8.0.
    if ! share_dir_readable "$(share_owner_path)" "$host_dir"; then
        log_error "Cannot read $host_dir as its owner"
        exit 1
    fi
    mapfile -d '' -t timestamps < <(share_list "$host_dir" -type d | sort -z -r)
    
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
        local stack_count; stack_count=$(as_owner_of "$(share_owner_path)" find "$host_dir/$timestamp" \( -name "*.tar.*" -o -name "*.tar" \) -printf x 2>/dev/null | wc -c) || stack_count=0
        
        printf '  %b%s)%b %s at %s (%s stacks)\n' "$GREEN" "$i" "$NC" "$(printable "$formatted_date")" "$(printable "$formatted_time")" "$stack_count"
        ((i++))
    done
    
    echo ""
    local selection; selection=$(prompt_input "Select backup number" "1")
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#timestamps[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    selected_timestamp="${timestamps[$((selection-1))]}"
    require_timestamp_name "$selected_timestamp"
    printf '\n%b✓%b Selected backup: %b%s%b\n' "$GREEN" "$NC" "$BOLD" "$(printable "$selected_timestamp")" "$NC"
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

    # Only the suffixes the backup writes (get_compression_extension), so the archive
    # path is built from validated parts plus a known suffix (round 3, F-05).
    # Listed as the share's owner (#1089), sorted, as the glob was.
    local -a sizes=()
    local -a entries=()
    if ! share_dir_readable "$(share_owner_path)" "$backup_dir"; then
        log_error "Cannot read $backup_dir as its owner"
        exit 1
    fi
    mapfile -d '' -t entries < <(as_owner_of "$(share_owner_path)" find "$backup_dir" -mindepth 1 -maxdepth 1 \
        -type f ! -name '.*' -printf '%s %f\0' 2>/dev/null | sort -z -k2)
    local ext entry fname
    for ext in .tar.gz .tar.bz2 .tar.xz .tar.zst .tar; do
        for entry in "${entries[@]+"${entries[@]}"}"; do
            fname="${entry#* }"
            if [[ "$fname" == *"$ext" && "$fname" != "$ext" ]]; then
                stacks+=("${fname%"$ext"}")
                stack_files+=("$backup_dir/$fname")
                sizes+=("${entry%% *}")
            fi
        done
    done

    if [[ ${#stacks[@]} -eq 0 ]]; then
        log_error "No stack backups found"
        exit 1
    fi

    echo "Available stacks:"
    for stack in "${stacks[@]}"; do
        # The size find printed (digits only), never `du -h f | cut -f1`, which reprinted
        # the rest of a file name that holds a newline on root's terminal (R2-01).
        local size="${sizes[$((i-1))]}"
        [[ "$size" =~ ^[0-9]+$ ]] && size=$(numfmt --to=iec "$size")
        printf '  %b%s)%b %s (%s)\n' "$GREEN" "$i" "$NC" "$(printable "$stack")" "$size"
        ((i++))
    done

    echo ""
    local selection; selection=$(prompt_input "Select stack number" "1")

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#stacks[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi

    selected_stack="${stacks[$((selection-1))]}"
    require_plain_name "stack" "$selected_stack"
    selected_backup_file="${stack_files[$((selection-1))]}"
    printf '\n%b✓%b Selected stack: %b%s%b\n' "$GREEN" "$NC" "$BOLD" "$(printable "$selected_stack")" "$NC"
}

# What was selected, for log lines.
selected_label() {
    if [[ "$restore_source" == restic ]]; then
        echo "restic snapshot ${selected_restic_id:0:8} of $selected_stack"
    else
        echo "$selected_backup_file"
    fi
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
    # awk tags its output: P = a preview line (first 20), X = a member restoring it as
    # root would be worth a second look (setuid/setgid, device, pipe, socket — audit p3a
    # F-03), N = "<count> <bytes>" at EOF. Names come escaped from tar -tv, one per line.
    local out list_rc=0
    # --numeric-owner: tar -tv prints owner/group names raw, and a PAX name can hold line
    # breaks that replaced the preview with forged lines (round 4, R4-01). Numeric ids
    # remove that channel; the awk field positions are unchanged.
    out=$(archive_read --numeric-owner -tv | awk '
        NR <= 20 { print "P\t" $0 }
        substr($1, 1, 1) ~ /[bcps]/ || substr($1, 4, 1) ~ /[sS]/ || substr($1, 7, 1) ~ /[sS]/ { print "X\t" $0 }
        $3 ~ /^[0-9]+$/ { bytes += $3 }
        END { printf "N\t%d %.0f\n", NR, bytes }') || list_rc=$?
    local line summary="0 0"
    local -a special=()
    while IFS= read -r line; do
        case "${line%%$'\t'*}" in
            # printable: tar -tv escapes member names and link targets but prints owner
            # and group names raw, so an ESC there reached root's terminal and could blank
            # the warning below (round 3, F-03).
            P) printf '%s\n' "$(printable "${line#*$'\t'}")" ;;
            X) special+=("${line#*$'\t'}") ;;
            N) summary="${line#*$'\t'}" ;;
        esac
    done <<< "$out"
    local total_files="${summary% *}"
    if [[ $list_rc -ne 0 ]]; then
        log_warning "Could not list $(selected_label) (tar exit $list_rc) — the archive may be corrupt or truncated"
        archive_extract_bytes=""
    else
        archive_extract_bytes="${summary#* }"
    fi

    if [[ $total_files -gt 20 ]]; then
        echo -e "${YELLOW}... and $((total_files - 20)) more files${NC}"
    fi
    if [[ ${#special[@]} -gt 0 ]]; then
        echo ""
        log_warning "${#special[@]} member(s) are setuid/setgid or device/pipe/socket entries. Restored as root, they keep the owner and mode recorded in the archive:"
        local entry
        for entry in "${special[@]:0:10}"; do
            printf '  %s\n' "$(printable "$entry")"
        done
        if [[ ${#special[@]} -gt 10 ]]; then
            echo "  ... and $(( ${#special[@]} - 10 )) more"
        fi
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
    
    # A symlinked appdata dir: the restore replaces the link with a real dir on
    # APPDATA_PATH's filesystem, and the link's target is left as it was (audit p3a F-06).
    if [[ -L "$appdata_dir" ]]; then
        log_warning "Appdata $appdata_dir is a symlink (-> $(readlink -- "$appdata_dir")): the restore replaces the link with a real directory and leaves the target untouched"
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
    # A dir that doesn't exist yet (RESTORE_SAFETY_DIR before its first use) will be
    # created on its nearest existing ancestor's filesystem, so measure that one.
    local dir="$1"
    while [[ ! -d "$dir" && "$dir" == */* && -n "${dir%/*}" ]]; do
        dir="${dir%/*}"
    done
    [[ -d "$dir" ]] || dir=/
    df -PB1 -- "$dir" 2>/dev/null | awk 'NR == 2 { print $4, $6 }'
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
        need_extract=0
        if [[ "$restore_source" == tar ]]; then
            need_extract=$(as_owner_of "$(share_owner_path)" stat -c %s -- "$selected_backup_file" 2>/dev/null) || need_extract=0
        fi
    fi
    # Member sizes are as the archive declares them. 19+ digits would wrap bash's 64-bit
    # arithmetic and make the comparison below pass (audit p3a F-05).
    if [[ ${#need_extract} -gt 18 ]]; then
        log_error "The archive declares an implausible total size ($need_extract bytes) — nothing was changed"
        return 1
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
    # restore whichever is there, not only docker-compose.yml. And when the archive has
    # one, remove the stack dir's other compose names first: compose prefers
    # compose.yaml > compose.yml > docker-compose.yaml > docker-compose.yml, so a
    # leftover higher-priority file would shadow the restored one.
    local -a compose_names=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)
    local name other restored_compose=false
    # Only regular files, never symlinks: this runs as root on an archive read from a
    # share, and `-f`/`cp` follow links, so a member `compose.yaml -> /etc/shadow` would
    # copy that file's content into the stack dir. --remove-destination likewise keeps cp
    # from writing through a symlink already sitting at the destination.
    for name in "${compose_names[@]}"; do
        if [[ -f "$temp_restore/$name" && ! -L "$temp_restore/$name" ]]; then
            for other in "${compose_names[@]}"; do
                [[ "$other" == "$name" ]] || rm -f -- "${stack_dir:?}/$other" || return 1
            done
            break
        fi
    done
    for name in "${compose_names[@]}" .env; do
        if [[ -L "$temp_restore/$name" ]]; then
            log_warning "Not restoring $name: it is a symlink in the archive"
        elif [[ -f "$temp_restore/$name" ]]; then
            cp -p --remove-destination "$temp_restore/$name" "$stack_dir/$name" || return 1
            [[ "$name" != .env ]] && restored_compose=true
        fi
    done
    if [[ "$restored_compose" != true ]]; then
        log_warning "The backup holds no compose file; kept the stack dir's existing one"
    fi

    log "Restoring appdata..."
    if [[ -L "$temp_restore/$selected_stack" || ! -d "$temp_restore/$selected_stack" ]]; then
        # Never delete the live appdata when there is nothing (or only a symlink) to put
        # in its place.
        log_warning "The backup holds no $selected_stack/ appdata directory; existing appdata left as is"
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
    if ! archive_read -x -C "$temp_restore"; then
        log_error "Could not extract $(selected_label) — nothing was changed"
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
        if [[ -z "${RESTORE_SAFETY_DIR:-}" ]]; then
            log_warning "That copy is under TMPDIR (${TMPDIR:-/tmp}), which is cleaned up (Debian: after 10 days, or at reboot on tmpfs). Move it if you need to keep it; set RESTORE_SAFETY_DIR for a lasting location."
        fi
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
    select_source
    if [[ "$restore_source" == restic ]]; then
        select_restic_snapshot
    else
        select_hostname
        select_timestamp
        select_stack
    fi
    preview_backup
    check_conflicts
    perform_restore
    
    print_section "Restore Complete!"
    
    log_success "Stack '$selected_stack' has been restored from $(selected_label)"
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
