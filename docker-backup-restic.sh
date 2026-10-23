#!/bin/bash

#######################################
# docker-backup-restic — restricted restic helper for docker-stack-backup
#
# Companion to BACKENDS=restic / RESTIC_HELPER_PATH. Install it like the other two
# helpers: root-owned, 0750, at a fixed path (e.g. /usr/local/sbin/docker-backup-restic.sh),
# and grant the backup user this exact path only. See RESTIC.md and ELEVATION.md.
#
# Why a helper? A loose `sudo restic` grant is a root primitive: `restic backup /etc/shadow`,
# `restore --target /`, `forget --keep-last 1` on every host's history, a repository and
# password of the caller's choosing. This helper takes NO path, repository, password or
# restic flag from its caller. The constants below, which only root can edit, decide all
# of them; the caller passes a verb, a stack name, a run timestamp, a run kind, retention
# counts and the stack's declared x-backup paths, each checked against a fixed shape.
#
# restic itself never runs as root and never as the caller: every call drops to
# RESTIC_RUN_AS with CAP_DAC_READ_SEARCH as its only capability (read any file, write
# nothing it does not own), so the repository belongs to that user and works on a
# root-squashed NFS export. The repository password is read by root from
# RESTIC_PASSWORD_FILE and handed to restic on its standard input, an inherited fd: it is
# never in argv, the environment, a path restic opens, or a log line.
#
# Verbs:
#   info                      print host=, appdata=, repo=, run_as=, floor_daily=,
#                             floor_weekly=, floor_monthly= (no restic call)
#   repo                      print id=<repository id>; restic's exit code on failure
#   init                      initialise RESTIC_REPO (restic refuses an existing one)
#   backup <temp_dir> <stack> <ts> <daily|full> [--from-snapshot] [glob...]
#          [-- <stack>/<path>...]
#                             one snapshot of the stack's appdata plus the compose file and
#                             .env in <temp_dir>, tagged dsb, stack:<stack>, kind:<kind>,
#                             run:<ts>; prints restic's JSON summary line
#   forget <stack> <daily> <weekly> <monthly>
#                             apply retention to that stack's snapshots on this host only;
#                             counts below the floors are refused
#   prune                     restic prune (takes the exclusive repository lock)
#   check <n/N | x%>          restic check --read-data-subset
#   snapshots [<stack>]       JSON list of this host's dsb snapshots (of one stack)
#   dump <stack> <id>         the snapshot as a tar stream on stdout; the id must be one of
#                             this host's snapshots of that stack
#   stats                     restic stats --mode raw-data --json
# <stack>: one path component of [A-Za-z0-9._-], not '.', '..' or starting with '-'.
# <ts>:    YYYYMMDD_HHMMSS (the run timestamp).
# Exit: 0 done, 2 refused (bad arguments or constants), 1 a helper step failed, else
# restic's own exit code (3 = some source data unreadable, 10 = no repository, 11 = lock
# failed, 12 = wrong password; see RESTIC.md).
#######################################

set -euo pipefail
umask 077
# ASCII character classes whatever the caller's locale (see docker-backup-tar-create.sh).
export LC_ALL=C
# Fixed search path: a root run with ELEVATION_CMD=none inherits the caller's PATH.
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

#######################################
# Trust boundary — root-set constants. Only root can edit this file.
#######################################
# The appdata root. Must equal config.sh's APPDATA_PATH and the other helpers'.
ALLOWED_APPDATA_PATH="/opt/appdata"
# The installed snapshot helper (docker-backup-snapshot.sh). Used by backup --from-snapshot.
SNAPSHOT_HELPER="/usr/local/sbin/docker-backup-snapshot.sh"
# restic 0.17.1 or later (RESTIC.md). Root-owned, not group/other-writable.
RESTIC_BIN="/usr/bin/restic"
# The repository: a local or NFS path, owned by RESTIC_RUN_AS. Not Backrest's.
RESTIC_REPO="/mnt/backup/restic"
# Root-owned, mode 0400 or 0600. Read by root, passed on restic's stdin.
RESTIC_PASSWORD_FILE="/etc/docker-backup-restic/password"
# The dedicated system user restic runs as. Never root, never the backup user.
RESTIC_RUN_AS="dsb-restic"
# The host name recorded in every snapshot, and the only one forget/dump/snapshots act
# on. Fixed here, so a host cloned from another cannot write into, or forget, its groups.
RESTIC_HOST=""
# restic's cache, owned by RESTIC_RUN_AS, 0700. Created if missing.
RESTIC_CACHE_DIR="/var/cache/docker-backup-restic"
# A fixed, empty, root-owned 0700 directory. backup mounts a private tmpfs on it in its
# own mount namespace and binds the stack's appdata into that, so every snapshot of a
# stack records the same paths (restic's parent snapshot, hence its change detection,
# is chosen by host and paths). Created if missing.
RESTIC_STAGE_DIR="/run/docker-backup-restic"
# Retention floors. forget refuses fewer than these: any process that can run this
# helper could otherwise erase a stack's history through it.
FLOOR_DAILY=7
FLOOR_WEEKLY=4
FLOOR_MONTHLY=0

STACK_RE='^[A-Za-z0-9._-]+$'
TS_RE='^[0-9]{8}_[0-9]{6}$'
ID_RE='^[0-9a-f]{8,64}$'

refuse() { echo "docker-backup-restic: $*" >&2; exit 2; }
fail()   { echo "docker-backup-restic: $*" >&2; exit 1; }

valid_stack() { [[ "$1" =~ $STACK_RE && "$1" != -* && "$1" != . && "$1" != .. ]]; }

# A clean absolute path of plain characters: no '.', '..' or empty component, no
# trailing '/', nothing a restic exclude pattern would read as a wildcard.
clean_abs() {
    local p="$1"
    [[ "$p" =~ ^/[A-Za-z0-9._/-]*$ && "$p" != */ && "$p" != *//* && "$p" != */./* \
        && "$p" != */../* && "$p" != */. && "$p" != */.. ]]
}

# root_file <path> <what> — a regular file (not a symlink) owned by whoever runs this,
# not group/other-writable. Root runs or reads it.
root_file() {
    local f="$1" what="$2" uid mode
    [[ -f "$f" && ! -L "$f" ]] || refuse "$what is not a regular file: $f"
    read -r uid mode < <(stat -c '%u %a' -- "$f") || refuse "cannot stat $what"
    [[ "$uid" == "$EUID" ]] && (( (8#$mode & 8#022) == 0 )) \
        || refuse "$what must be owned by uid $EUID and not group/other-writable: $f"
}

#######################################
# Constants check
#######################################
clean_abs "$ALLOWED_APPDATA_PATH" || refuse "ALLOWED_APPDATA_PATH must be a clean absolute path"
clean_abs "$RESTIC_REPO" || refuse "RESTIC_REPO must be a clean absolute path"
clean_abs "$RESTIC_CACHE_DIR" || refuse "RESTIC_CACHE_DIR must be a clean absolute path"
clean_abs "$RESTIC_STAGE_DIR" && [[ "$RESTIC_STAGE_DIR" != / ]] \
    || refuse "RESTIC_STAGE_DIR must be a clean absolute path"
[[ "$RESTIC_HOST" =~ $STACK_RE && "$RESTIC_HOST" != -* ]] \
    || refuse "RESTIC_HOST is not set (one name of [A-Za-z0-9._-]); set it in this helper"
[[ "$RESTIC_RUN_AS" =~ ^[a-z_][a-z0-9_-]*$ ]] || refuse "invalid RESTIC_RUN_AS"
for floor in "$FLOOR_DAILY" "$FLOOR_WEEKLY" "$FLOOR_MONTHLY"; do
    [[ "$floor" =~ ^[0-9]{1,4}$ ]] || refuse "the floors must be integers"
done
(( 10#$FLOOR_DAILY + 10#$FLOOR_WEEKLY + 10#$FLOOR_MONTHLY > 0 )) || refuse "at least one floor must be above 0"
run_uid=$(id -u -- "$RESTIC_RUN_AS" 2>/dev/null) || refuse "no such user: RESTIC_RUN_AS=$RESTIC_RUN_AS"
run_gid=$(id -g -- "$RESTIC_RUN_AS" 2>/dev/null) || refuse "no primary group for $RESTIC_RUN_AS"
[[ "$run_uid" =~ ^[0-9]+$ && "$run_gid" =~ ^[0-9]+$ ]] || refuse "cannot resolve RESTIC_RUN_AS"
# restic must not run as root: that is the point of RESTIC_RUN_AS.
[[ "$run_uid" != 0 ]] || refuse "RESTIC_RUN_AS must not be root"
if [[ $EUID -ne 0 && "$EUID" != "$run_uid" ]]; then
    # Unprivileged, this helper can only be RESTIC_RUN_AS itself (no drop is possible).
    refuse "run as root (through the sudo/doas grant), or as $RESTIC_RUN_AS"
fi

#######################################
# Running restic
#######################################
# restic gets a fixed environment: nothing of the caller's (RESTIC_PASSWORD_COMMAND,
# RESTIC_REPOSITORY, a proxy, GODEBUG) reaches it, whatever sudo/doas keep.
RESTIC_ENV=(PATH=/usr/bin:/bin HOME=/nonexistent LC_ALL=C TMPDIR=/tmp
    RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR")

# drop <cmd...> — as RESTIC_RUN_AS with CAP_DAC_READ_SEARCH only (ambient, so it survives
# the exec of restic), no supplementary groups, no new privileges. Unprivileged (already
# RESTIC_RUN_AS): as is.
DROP=()
if [[ $EUID -eq 0 ]]; then
    DROP=(setpriv --reuid="$run_uid" --regid="$run_gid" --clear-groups
        "--inh-caps=-all,+dac_read_search" "--ambient-caps=-all,+dac_read_search"
        "--bounding-set=-all,+dac_read_search" --no-new-privs --)
fi
drop() {
    "${DROP[@]+"${DROP[@]}"}" "$@"
}

check_runtime() {
    root_file "$RESTIC_BIN" RESTIC_BIN
    root_file "$RESTIC_PASSWORD_FILE" RESTIC_PASSWORD_FILE
    local mode; mode=$(stat -c %a -- "$RESTIC_PASSWORD_FILE")
    (( (8#$mode & 8#077) == 0 )) || refuse "RESTIC_PASSWORD_FILE must not be readable by group or other (0400/0600)"
    # The cache: RESTIC_RUN_AS's own 0700 dir. Made here when missing.
    if [[ ! -e "$RESTIC_CACHE_DIR" && ! -L "$RESTIC_CACHE_DIR" ]]; then
        mkdir -m 0700 -- "$RESTIC_CACHE_DIR" || fail "cannot create $RESTIC_CACHE_DIR"
        if [[ $EUID -eq 0 ]]; then
            chown "$run_uid:$run_gid" -- "$RESTIC_CACHE_DIR" || fail "cannot chown $RESTIC_CACHE_DIR"
        fi
    fi
    [[ -d "$RESTIC_CACHE_DIR" && ! -L "$RESTIC_CACHE_DIR" ]] || refuse "RESTIC_CACHE_DIR is not a directory"
    [[ "$(stat -c %u -- "$RESTIC_CACHE_DIR")" == "$run_uid" ]] \
        || refuse "RESTIC_CACHE_DIR must be owned by $RESTIC_RUN_AS"
}

# restic <args...> — restic as RESTIC_RUN_AS against RESTIC_REPO, the password on stdin.
# The redirect is opened by this (root) shell before the drop, so restic reads the
# password from fd 0 and never opens RESTIC_PASSWORD_FILE itself.
restic() {
    drop env -i "${RESTIC_ENV[@]}" "$RESTIC_BIN" --repo "$RESTIC_REPO" "$@" \
        < "$RESTIC_PASSWORD_FILE"
}

#######################################
# Verbs
#######################################
verb="${1:-}"
[[ -n "$verb" ]] || refuse "usage: $0 info|repo|init|backup|forget|prune|check|snapshots|dump|stats ..."
shift

expect_args() {
    [[ $1 -eq $2 ]] || refuse "$verb: expected $2 argument(s)"
}

# The stack's snapshot ids on this host, one per line (full ids).
stack_snapshot_ids() {
    restic snapshots --json --host "$RESTIC_HOST" --tag "dsb,stack:$1" \
        | grep -o '"id":"[0-9a-f]\{64\}"' | cut -d'"' -f4
}

case "$verb" in
    info)
        expect_args $# 0
        echo "host=$RESTIC_HOST"
        echo "appdata=$ALLOWED_APPDATA_PATH"
        echo "repo=$RESTIC_REPO"
        echo "run_as=$RESTIC_RUN_AS"
        echo "floor_daily=$((10#$FLOOR_DAILY))"
        echo "floor_weekly=$((10#$FLOOR_WEEKLY))"
        echo "floor_monthly=$((10#$FLOOR_MONTHLY))"
        ;;

    repo)
        expect_args $# 0
        check_runtime
        rc=0
        out=$(restic cat config --json) || rc=$?
        [[ $rc -eq 0 ]] || exit "$rc"
        id=$(grep -o '"id": *"[0-9a-f]\{64\}"' <<< "$out" | grep -o '[0-9a-f]\{64\}') \
            || fail "cannot read the repository id"
        echo "id=$id"
        ;;

    init)
        expect_args $# 0
        check_runtime
        restic init
        ;;

    backup)
        [[ $# -ge 4 ]] || refuse "backup: expected <temp_dir> <stack> <ts> <kind> ..."
        temp_dir="$1"; stack="$2"; ts="$3"; kind="$4"; shift 4
        valid_stack "$stack" || refuse "invalid stack name"
        [[ "$ts" =~ $TS_RE ]] || refuse "invalid timestamp"
        [[ "$kind" == daily || "$kind" == full ]] || refuse "invalid run kind"
        from_snapshot=false
        if [[ "${1:-}" == --from-snapshot ]]; then
            from_snapshot=true
            shift
        fi
        # The global EXCLUDE_PATTERNS (unanchored globs), as the tar helper takes them.
        exclude_args=()
        while [[ $# -gt 0 && "$1" != -- ]]; do
            pattern="$1"; shift
            [[ "$pattern" =~ ^[A-Za-z0-9._/*-]+$ && "$pattern" != -* ]] || refuse "invalid exclude pattern: $pattern"
            exclude_args+=(--exclude "$pattern")
        done
        # Declared paths: <stack>/<path>, the same rule as lib.sh valid_declared_path,
        # dsb_status.py xb_path_error and the tar helper (tests/xbackup-path-rule.bats).
        # Anchored at the stack's own dir under RESTIC_STAGE_DIR: restic matches a pattern
        # that starts with '/' against the absolute path, and these hold no wildcard.
        if [[ "${1:-}" == -- ]]; then
            shift
            [[ $# -gt 0 ]] || refuse "'--' with no declared path"
            for declared in "$@"; do
                rel="${declared#"$stack"/}"
                ok=true
                [[ "$declared" == "$stack/"* && "$rel" =~ ^[A-Za-z0-9._/-]+$ && ${#rel} -le 255 ]] || ok=false
                [[ "$rel" != /* && "$rel" != */ && "$rel" != *//* ]] || ok=false
                if [[ "$ok" == true ]]; then
                    IFS=/ read -r -a comps <<< "$rel"
                    for c in "${comps[@]}"; do
                        [[ "$c" =~ ^[A-Za-z0-9._-]+$ && "$c" != -* && "$c" != . && "$c" != .. ]] || ok=false
                    done
                fi
                [[ "$ok" == true ]] || refuse "invalid declared path: $declared"
                exclude_args+=(--exclude "$RESTIC_STAGE_DIR/$stack/$rel")
            done
        fi
        # After the argument checks, so they can be tested unprivileged.
        [[ $EUID -eq 0 ]] || refuse "backup needs root (a private mount namespace)"

        # Who the caller is (as the tar helper): sudo sets SUDO_UID, doas DOAS_USER.
        invoker_uid="$EUID"
        invoker_gid=$(id -g)
        if [[ -n "${SUDO_UID:-}" ]]; then
            invoker_uid="$SUDO_UID"
            invoker_gid="${SUDO_GID:-}"
        elif [[ -n "${DOAS_USER:-}" ]]; then
            invoker_uid=$(id -u -- "$DOAS_USER" 2>/dev/null) || invoker_uid=""
            invoker_gid=$(id -g -- "$DOAS_USER" 2>/dev/null) || invoker_gid=""
        fi
        [[ "$invoker_uid" =~ ^[0-9]+$ && "$invoker_gid" =~ ^[0-9]+$ ]] || refuse "cannot tell the invoking user"

        # The temp dir: the caller's own private dir directly under /tmp, entered and
        # checked by inode, as in docker-backup-tar-create.sh (audit p5a F-01, R2-01).
        [[ "$temp_dir" =~ ^/tmp/[^/]+$ ]] || refuse "invalid temp_dir: $temp_dir"
        [[ -d "$temp_dir" && ! -L "$temp_dir" ]] || refuse "temp_dir is not a directory: $temp_dir"
        cd -P -- "$temp_dir" || refuse "cannot enter temp_dir: $temp_dir"
        cwd_id=$(stat -c '%d:%i' -- .) || cwd_id=""
        path_id=$(stat -c '%d:%i' -- "$temp_dir") || path_id=""
        [[ -n "$cwd_id" && "$cwd_id" == "$path_id" ]] || refuse "temp_dir was replaced while it was being entered"
        read -r td_uid td_mode < <(stat -c '%u %a' -- .) || refuse "cannot stat temp_dir"
        [[ "$td_uid" == "$invoker_uid" ]] || refuse "temp_dir is not owned by the invoking user (uid $invoker_uid)"
        (( (8#$td_mode & 8#077) == 0 )) || refuse "temp_dir must be mode 0700"

        [[ -d "$ALLOWED_APPDATA_PATH/$stack" && ! -L "$ALLOWED_APPDATA_PATH/$stack" ]] \
            || refuse "stack appdata dir not found: $ALLOWED_APPDATA_PATH/$stack"
        check_runtime

        # The source: the live appdata root, or the snapshot the snapshot helper names.
        # The path is never the caller's.
        source_root="$ALLOWED_APPDATA_PATH"
        if [[ "$from_snapshot" == true ]]; then
            root_file "$SNAPSHOT_HELPER" SNAPSHOT_HELPER
            helper_info=$("$SNAPSHOT_HELPER" info) || fail "the snapshot helper's info failed"
            sh_appdata="" snap_root=""
            while IFS='=' read -r key val; do
                case "$key" in
                    appdata)      sh_appdata="$val" ;;
                    snapshot_dir) snap_root="$val/dsb-$stack-$ts" ;;
                    mountpoint)   snap_root="${val%/}/.zfs/snapshot/dsb-$stack-$ts" ;;
                esac
            done <<< "$helper_info"
            [[ "$sh_appdata" == "$ALLOWED_APPDATA_PATH" && -n "$snap_root" ]] \
                || fail "the snapshot helper's appdata root is not ALLOWED_APPDATA_PATH"
            source_root=$("$SNAPSHOT_HELPER" source "$stack" "$ts") \
                || fail "the snapshot helper could not resolve the snapshot"
            [[ "$source_root" == "$snap_root" || "$source_root" == "$snap_root"/* ]] \
                || fail "snapshot source is outside the snapshot"
            [[ "$source_root" != *[[:cntrl:]]* && "$source_root" != */../* && "$source_root" != */.. \
                && -d "$source_root/$stack" && ! -L "$source_root/$stack" ]] \
                || fail "snapshot source is not a directory"
        fi

        # The stage dir: a fixed mount point, root's, empty of meaning outside the namespace.
        if [[ ! -e "$RESTIC_STAGE_DIR" && ! -L "$RESTIC_STAGE_DIR" ]]; then
            mkdir -m 0700 -- "$RESTIC_STAGE_DIR" || fail "cannot create $RESTIC_STAGE_DIR"
        fi
        [[ -d "$RESTIC_STAGE_DIR" && ! -L "$RESTIC_STAGE_DIR" ]] || refuse "RESTIC_STAGE_DIR is not a directory"
        read -r sd_uid sd_mode < <(stat -c '%u %a' -- "$RESTIC_STAGE_DIR") || fail "cannot stat RESTIC_STAGE_DIR"
        [[ "$sd_uid" == "$EUID" ]] && (( (8#$sd_mode & 8#077) == 0 )) \
            || refuse "RESTIC_STAGE_DIR must be owned by uid $EUID, mode 0700"

        # The compose file and .env, read AS THE INVOKING USER into a private root-owned
        # dir (docker-backup-tar-create.sh "Staging": root never reads the caller's dir).
        STAGE_NAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml .env)
        STAGE_MAX_BYTES=$((16 * 1024 * 1024))
        drop_privs=false
        [[ "$invoker_uid" != 0 ]] && drop_privs=true
        as_invoker() {
            if [[ "$drop_privs" == true ]]; then
                setpriv --reuid="$invoker_uid" --regid="$invoker_gid" --clear-groups --no-new-privs -- "$@"
            else
                "$@"
            fi
        }
        if [[ "$drop_privs" == true ]]; then
            as_invoker true || fail "cannot run as the invoking user (setpriv)"
        fi
        stage=$(mktemp -d /tmp/dsb-restic-stage.XXXXXXXXXX) || fail "cannot create a staging dir"
        trap 'rm -rf -- "$stage"' EXIT
        names=()
        for name in "${STAGE_NAMES[@]}"; do
            as_invoker test -e "./$name" -o -L "./$name" || continue
            info=$(as_invoker stat -c '%F|%a' -- "./$name") || fail "cannot stat $name as the invoking user"
            fkind="${info%%|*}" mode="${info##*|}"
            [[ "$fkind" == "regular file" || "$fkind" == "regular empty file" ]] \
                || refuse "$name in temp_dir is not a regular file"
            [[ "$mode" =~ ^[0-7]{3,4}$ ]] || refuse "cannot read the mode of $name"
            as_invoker head -c "$((STAGE_MAX_BYTES + 1))" -- "./$name" > "$stage/$name" \
                || fail "cannot read $name as the invoking user"
            (( $(stat -c %s -- "$stage/$name") <= STAGE_MAX_BYTES )) || refuse "$name is larger than $STAGE_MAX_BYTES bytes"
            chmod "$mode" -- "$stage/$name"
            chown "$invoker_uid:$invoker_gid" -- "$stage/$name" || fail "cannot set the owner of the staged $name"
            names+=("$name")
        done
        [[ ${#names[@]} -gt 0 && "${names[0]}" != .env ]] || refuse "no compose file in temp_dir"
        names+=("$stack")
        cd /

        # In a private mount namespace: a tmpfs on RESTIC_STAGE_DIR holding the staged
        # files, the stack's appdata bound read-only below it, restic run from there with
        # relative paths. The mounts end with the namespace, whatever happens to restic.
        # This script text is a constant; only checked values are passed to it.
        ns_script='set -euo pipefail
dir=$1 stage=$2 src=$3 stack=$4; shift 4
mount -t tmpfs -o mode=0700,size=64m,nosuid,nodev,noexec dsb-restic "$dir"
for n in compose.yaml compose.yml docker-compose.yaml docker-compose.yml .env; do
    if [[ -f "$stage/$n" ]]; then cp -p -- "$stage/$n" "$dir/$n"; fi
done
mkdir -m 0700 -- "$dir/$stack"
mount --rbind -- "$src/$stack" "$dir/$stack"
mount -o remount,bind,ro,nosuid,nodev -- "$dir/$stack"
cd -- "$dir"
exec "$@"'
        rc=0
        unshare --mount --propagation private -- bash -c "$ns_script" _ \
            "$RESTIC_STAGE_DIR" "$stage" "$source_root" "$stack" \
            "${DROP[@]}" env -i "${RESTIC_ENV[@]}" "$RESTIC_BIN" --repo "$RESTIC_REPO" \
            backup --json --quiet --host "$RESTIC_HOST" --group-by host,paths \
            --tag dsb --tag "stack:$stack" --tag "kind:$kind" --tag "run:$ts" \
            "${exclude_args[@]+"${exclude_args[@]}"}" -- "${names[@]}" \
            < "$RESTIC_PASSWORD_FILE" || rc=$?
        exit "$rc"
        ;;

    forget)
        expect_args $# 4
        stack="$1"
        valid_stack "$stack" || refuse "invalid stack name"
        keep=()
        n=0
        for v in "$2" "$3" "$4"; do
            [[ "$v" =~ ^[0-9]{1,4}$ ]] && (( 10#$v <= 1000 )) || refuse "retention counts must be integers 0-1000"
        done
        d=$((10#$2)) w=$((10#$3)) m=$((10#$4))
        (( d >= 10#$FLOOR_DAILY && w >= 10#$FLOOR_WEEKLY && m >= 10#$FLOOR_MONTHLY )) \
            || refuse "retention $d/$w/$m is below the floors $((10#$FLOOR_DAILY))/$((10#$FLOOR_WEEKLY))/$((10#$FLOOR_MONTHLY)) (daily/weekly/monthly)"
        (( d > 0 )) && keep+=(--keep-daily "$d") && n=$((n + 1))
        (( w > 0 )) && keep+=(--keep-weekly "$w") && n=$((n + 1))
        (( m > 0 )) && keep+=(--keep-monthly "$m") && n=$((n + 1))
        [[ $n -gt 0 ]] || refuse "no retention policy"
        check_runtime
        # Always this host and this stack's tag: never a forget across stacks or hosts.
        # Grouped by host only: the run:/kind: tags differ per snapshot, and grouping by
        # tags would make every snapshot its own group, so nothing would ever be removed.
        restic forget --json --host "$RESTIC_HOST" --tag "dsb,stack:$stack" --group-by host "${keep[@]}"
        ;;

    prune)
        expect_args $# 0
        check_runtime
        restic prune
        ;;

    check)
        expect_args $# 1
        subset="$1"
        if [[ "$subset" =~ ^([0-9]{1,4})/([0-9]{1,4})$ ]]; then
            (( 10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= 10#${BASH_REMATCH[2]} )) \
                || refuse "invalid subset: n/N needs 1 <= n <= N"
            subset="$((10#${BASH_REMATCH[1]}))/$((10#${BASH_REMATCH[2]}))"
        elif [[ "$subset" =~ ^([0-9]{1,3})(\.[0-9]{1,2})?%$ ]]; then
            (( 10#${BASH_REMATCH[1]} <= 100 )) || refuse "invalid subset: at most 100%"
        else
            refuse "invalid subset (n/N or x%)"
        fi
        check_runtime
        restic check --read-data-subset="$subset"
        ;;

    snapshots)
        [[ $# -le 1 ]] || refuse "snapshots: expected at most 1 argument"
        tags="dsb"
        if [[ $# -eq 1 ]]; then
            valid_stack "$1" || refuse "invalid stack name"
            tags="dsb,stack:$1"
        fi
        check_runtime
        restic snapshots --json --host "$RESTIC_HOST" --tag "$tags"
        ;;

    dump)
        expect_args $# 2
        stack="$1" id="$2"
        valid_stack "$stack" || refuse "invalid stack name"
        [[ "$id" =~ $ID_RE ]] || refuse "invalid snapshot id"
        check_runtime
        # The id must name exactly one of this host's snapshots of this stack: never
        # another stack's, another host's, or an ambiguous prefix.
        ids=$(stack_snapshot_ids "$stack") || fail "cannot list the snapshots of $stack"
        full=$(grep "^$id" <<< "$ids" || true)
        [[ -n "$full" && "$full" != *$'\n'* ]] || refuse "no snapshot $id of stack $stack on host $RESTIC_HOST"
        restic dump --archive tar "$full" /
        ;;

    stats)
        expect_args $# 0
        check_runtime
        restic stats --json --mode raw-data --host "$RESTIC_HOST" --tag dsb
        ;;

    *)
        refuse "unknown verb"
        ;;
esac
