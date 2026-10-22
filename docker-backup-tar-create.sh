#!/bin/bash

#######################################
# docker-backup-tar-create — restricted elevation helper for docker-stack-backup
#
# Companion to the ELEVATION_CMD / ELEVATION_HELPER_PATH config options. Install this
# as a root-owned, 0750 file (e.g. /usr/local/sbin/docker-backup-tar-create.sh) and
# grant the backup user permission to run ONLY this exact path via sudo/doas. See
# ELEVATION.md and SECURITY.md for the full install + hardening procedure.
#
# Why a helper instead of `sudo tar`? A bare `NOPASSWD: /usr/bin/tar` grant is a
# GTFOBins root-shell primitive: tar's --checkpoint-action=exec (and -x/--to-command,
# etc.) turn "tar as root" into "arbitrary code as root". This wrapper never accepts
# raw tar flags from its caller — it validates each argument against a fixed shape and
# builds the tar invocation itself, so no combination of inputs can smuggle a flag the
# wrapper did not choose to pass.
#
# It always runs tar in create mode (-c) against exactly two -C sources, writing the
# archive to STDOUT (no -f) so the caller's own (unprivileged) shell opens the output
# file — this is what keeps writes to an NFS root_squash export working.
#
# Usage:
#   docker-backup-tar-create <compression:none|gzip|bzip2|xz|zstd> <temp_dir> \
#       <appdata_path> <stack_name> [--from-snapshot <ts>] [exclude_pattern...] \
#       [-- <stack_name>/<declared_path>...] > <output_file>
#
# exclude_pattern: the global EXCLUDE_PATTERNS, unanchored globs (unchanged since 0.4).
# After `--`: x-backup declared paths (0.7.0), each anchored at the stack's own dir and
# matched literally: `<stack>/a/b` leaves out that member and everything under it, and
# nothing else. They are passed to tar after the globs, behind --anchored --no-wildcards,
# which are positional and so cannot change how the globs match.
# --from-snapshot <ts>: read the stack's appdata from the read-only snapshot
# dsb-<stack_name>-<ts> instead of the live dir. The path comes from the snapshot
# helper's `source` verb (SNAPSHOT_HELPER below): never from the caller.
#######################################

set -euo pipefail
# Character classes below must mean ASCII: in a UTF-8 locale bash's [A-Za-z] follows the
# locale's collation and matches letters such as 'é' (sudo keeps LANG/LC_* by default).
export LC_ALL=C
# Fixed search path for the compressor tar runs (-z/-j/-J/--zstd): a root run with
# ELEVATION_CMD=none, or doas, would otherwise inherit the caller's PATH.
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

#######################################
# Trust boundary — the allowed appdata bind-mount root.
#
# This helper is root-owned and only root can edit it, so this value (NOT the caller's
# argument) decides what root will read. Set it to match config.sh's APPDATA_PATH when
# you install the helper. The caller must pass this exact path; anything else is
# rejected. Never widen this to accept arbitrary caller input — that would let an
# unprivileged caller tar any root-readable directory.
#######################################
ALLOWED_APPDATA_PATH="/opt/appdata"

# The installed snapshot helper (docker-backup-snapshot.sh), root-owned like this file.
# Used by --from-snapshot only.
SNAPSHOT_HELPER="/usr/local/sbin/docker-backup-snapshot.sh"

usage() {
    echo "Usage: $0 <compression:none|gzip|bzip2|xz|zstd> <temp_dir> <appdata_path> <stack_name> [--from-snapshot <ts>] [exclude_pattern...] [-- <stack_name>/<path>...]" >&2
    exit 2
}

[[ $# -ge 4 ]] || usage

compression="$1"; temp_dir="$2"; appdata_path="$3"; stack_name="$4"; shift 4

case "$compression" in
    none|gzip|bzip2|xz|zstd) ;;
    *) echo "docker-backup-tar-create: invalid compression: $compression" >&2; exit 2 ;;
esac

# mktemp -d output: a single path component directly under /tmp
[[ "$temp_dir" =~ ^/tmp/[^/]+$ ]] || { echo "docker-backup-tar-create: invalid temp_dir: $temp_dir" >&2; exit 2; }
[[ -d "$temp_dir" ]] || { echo "docker-backup-tar-create: temp_dir does not exist: $temp_dir" >&2; exit 2; }

# The temp dir must be the caller's own private dir (what `mktemp -d` makes), not just
# any /tmp/<name>: a symlink there, or a root-owned dir already in /tmp (PrivateTmp
# dirs), made root archive any directory it pointed at into the caller's stdout (audit
# p5a F-01). Who the caller is: sudo sets SUDO_UID and doas sets DOAS_USER, and neither
# can be set by the caller through them; otherwise it is whoever runs this.
invoker_uid="$EUID"
invoker_gid=$(id -g)
if [[ -n "${SUDO_UID:-}" ]]; then
    invoker_uid="$SUDO_UID"
    invoker_gid="${SUDO_GID:-}"
elif [[ -n "${DOAS_USER:-}" ]]; then
    invoker_uid=$(id -u -- "$DOAS_USER" 2>/dev/null) || invoker_uid=""
    invoker_gid=$(id -g -- "$DOAS_USER" 2>/dev/null) || invoker_gid=""
fi
[[ "$invoker_uid" =~ ^[0-9]+$ && "$invoker_gid" =~ ^[0-9]+$ ]] || { echo "docker-backup-tar-create: cannot tell the invoking user" >&2; exit 2; }
[[ ! -L "$temp_dir" ]] || { echo "docker-backup-tar-create: temp_dir is a symlink: $temp_dir" >&2; exit 2; }
# The caller owns the /tmp entry and can swap it at any moment (audit p5a R2-01, R3-01).
# After `cd -P`, the KERNEL cwd must be the directory now at the validated path: an
# lstat of the path (stat without -L; a symlink there never matches) against `.`. (bash's
# builtin `pwd -P` re-resolves the path string, never getcwd, so a swap-back passed it.)
# These checks are defence in depth: root does not read the caller's files at all, see
# "Staging" below.
cd -P -- "$temp_dir" || { echo "docker-backup-tar-create: cannot enter temp_dir: $temp_dir" >&2; exit 2; }
cwd_id=$(stat -c '%d:%i' -- .) || cwd_id=""
path_id=$(stat -c '%d:%i' -- "$temp_dir") || path_id=""
[[ -n "$cwd_id" && "$cwd_id" == "$path_id" ]] || { echo "docker-backup-tar-create: temp_dir was replaced while it was being entered: $temp_dir" >&2; exit 2; }
read -r td_uid td_mode < <(stat -c '%u %a' -- .) || { echo "docker-backup-tar-create: cannot stat temp_dir" >&2; exit 2; }
[[ "$td_uid" == "$invoker_uid" ]] || { echo "docker-backup-tar-create: temp_dir is not owned by the invoking user (uid $invoker_uid): $temp_dir" >&2; exit 2; }
(( (8#$td_mode & 8#077) == 0 )) || { echo "docker-backup-tar-create: temp_dir must be mode 0700: $temp_dir" >&2; exit 2; }

# Appdata root must match the root-configured allowlist above (not arbitrary caller input)
[[ "$appdata_path" == "$ALLOWED_APPDATA_PATH" ]] || { echo "docker-backup-tar-create: invalid appdata_path: $appdata_path (allowed: $ALLOWED_APPDATA_PATH)" >&2; exit 2; }

# Stack name: single path component, no leading dash (would be parsed as a tar flag).
# The character class permits '.' and '-' individually, so also reject the '.' and '..'
# tokens explicitly: '..' would escape ALLOWED_APPDATA_PATH (tar -C <root> .. archives the
# parent), and '.' would archive the whole appdata root instead of one stack.
[[ "$stack_name" =~ ^[A-Za-z0-9._-]+$ && "$stack_name" != -* ]] || { echo "docker-backup-tar-create: invalid stack_name: $stack_name" >&2; exit 2; }
[[ "$stack_name" != "." && "$stack_name" != ".." ]] || { echo "docker-backup-tar-create: invalid stack_name (. and .. are not allowed): $stack_name" >&2; exit 2; }
[[ -d "$appdata_path/$stack_name" ]] || { echo "docker-backup-tar-create: stack appdata dir not found: $appdata_path/$stack_name" >&2; exit 2; }

snapshot_ts=""
if [[ "${1:-}" == --from-snapshot ]]; then
    [[ $# -ge 2 && "$2" =~ ^[0-9]{8}_[0-9]{6}$ ]] || { echo "docker-backup-tar-create: invalid --from-snapshot timestamp" >&2; exit 2; }
    snapshot_ts="$2"
    shift 2
fi

exclude_args=()
while [[ $# -gt 0 && "$1" != -- ]]; do
    pattern="$1"; shift
    [[ "$pattern" =~ ^[A-Za-z0-9._/*-]+$ && "$pattern" != -* ]] || { echo "docker-backup-tar-create: invalid exclude pattern: $pattern" >&2; exit 2; }
    exclude_args+=(--exclude="$pattern")
done

# Declared paths: <stack_name>/<path>, the same rule as lib.sh valid_declared_path and
# dsb_status.py xb_path_error (tests/xbackup-path-rule.bats checks all three agree).
if [[ "${1:-}" == -- ]]; then
    shift
    [[ $# -gt 0 ]] || { echo "docker-backup-tar-create: '--' with no declared path" >&2; exit 2; }
    exclude_args+=(--anchored --no-wildcards)
    for declared in "$@"; do
        rel="${declared#"$stack_name"/}"
        ok=true
        [[ "$declared" == "$stack_name/"* && "$rel" =~ ^[A-Za-z0-9._/-]+$ && ${#rel} -le 255 ]] || ok=false
        [[ "$rel" != /* && "$rel" != */ && "$rel" != *//* ]] || ok=false
        if [[ "$ok" == true ]]; then
            IFS=/ read -r -a comps <<< "$rel"
            for c in "${comps[@]}"; do
                [[ "$c" =~ ^[A-Za-z0-9._-]+$ && "$c" != -* && "$c" != . && "$c" != .. ]] || ok=false
            done
        fi
        [[ "$ok" == true ]] || { echo "docker-backup-tar-create: invalid declared path: $declared" >&2; exit 2; }
        exclude_args+=(--exclude="$declared")
    done
fi

source_root="$appdata_path"
if [[ -n "$snapshot_ts" ]]; then
    # Root runs this file: it must be a regular file owned by root (whoever runs this),
    # writable by nobody else (audit p5a F-04).
    [[ -f "$SNAPSHOT_HELPER" && ! -L "$SNAPSHOT_HELPER" ]] \
        || { echo "docker-backup-tar-create: SNAPSHOT_HELPER is not a regular file: $SNAPSHOT_HELPER" >&2; exit 1; }
    read -r sh_uid sh_mode < <(stat -c '%u %a' -- "$SNAPSHOT_HELPER") \
        || { echo "docker-backup-tar-create: cannot stat SNAPSHOT_HELPER" >&2; exit 1; }
    [[ "$sh_uid" == "$EUID" ]] && (( (8#$sh_mode & 8#022) == 0 )) \
        || { echo "docker-backup-tar-create: SNAPSHOT_HELPER must be owned by uid $EUID and not group/other-writable" >&2; exit 1; }
    # The two helpers must agree on the appdata root, and the source must lie inside
    # exactly this snapshot (its dir for btrfs, .zfs/snapshot/<name> for ZFS).
    helper_info=$("$SNAPSHOT_HELPER" info) \
        || { echo "docker-backup-tar-create: the snapshot helper's info failed" >&2; exit 1; }
    sh_appdata="" snap_root=""
    while IFS='=' read -r key val; do
        case "$key" in
            appdata)      sh_appdata="$val" ;;
            snapshot_dir) snap_root="$val/dsb-$stack_name-$snapshot_ts" ;;
            mountpoint)   snap_root="${val%/}/.zfs/snapshot/dsb-$stack_name-$snapshot_ts" ;;
        esac
    done <<< "$helper_info"
    [[ "$sh_appdata" == "$ALLOWED_APPDATA_PATH" && -n "$snap_root" ]] \
        || { echo "docker-backup-tar-create: the snapshot helper's appdata root is not ALLOWED_APPDATA_PATH" >&2; exit 1; }
    source_root=$("$SNAPSHOT_HELPER" source "$stack_name" "$snapshot_ts") \
        || { echo "docker-backup-tar-create: the snapshot helper could not resolve the snapshot" >&2; exit 1; }
    [[ "$source_root" == "$snap_root" || "$source_root" == "$snap_root"/* ]] \
        || { echo "docker-backup-tar-create: snapshot source is outside the snapshot" >&2; exit 1; }
    [[ "$source_root" != *[[:cntrl:]]* && "$source_root" != */../* && "$source_root" != */.. \
        && -d "$source_root/$stack_name" && ! -L "$source_root/$stack_name" ]] \
        || { echo "docker-backup-tar-create: snapshot source is not a directory" >&2; exit 1; }
fi

#######################################
# Staging: root never reads the caller's temp dir. Its files (the stack's compose file
# and .env, the only things the backup puts there) are read AS THE INVOKING USER, through
# setpriv, and written into a private root-owned staging dir that tar then archives. So
# whatever the caller does to its own dir (swap it, rename another dir to it, plant a
# link to a file it cannot read), root only ever archives bytes the caller could read
# anyway (audit p5a R3-01, option B). Ownership and modes of the staged files are set
# back to the caller's, so the archive's root members look as they did before.
#######################################
STAGE_NAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml .env)
STAGE_MAX_BYTES=$((16 * 1024 * 1024))
drop_privs=false
if [[ $EUID -eq 0 && "$invoker_uid" != 0 ]]; then
    drop_privs=true
fi
as_invoker() {
    if [[ "$drop_privs" == true ]]; then
        setpriv --reuid="$invoker_uid" --regid="$invoker_gid" --clear-groups --no-new-privs -- "$@"
    else
        "$@"
    fi
}
umask 077
stage=$(mktemp -d /tmp/dsb-stage.XXXXXXXXXX) || { echo "docker-backup-tar-create: cannot create a staging dir" >&2; exit 1; }
trap 'rm -rf -- "$stage"' EXIT
for name in "${STAGE_NAMES[@]}"; do
    # Relative to the checked cwd. `stat` without -L: a symlink is reported as one.
    info=$(as_invoker stat -c '%F|%a' -- "./$name" 2>/dev/null) || continue   # absent
    kind="${info%%|*}" mode="${info##*|}"
    [[ "$kind" == "regular file" || "$kind" == "regular empty file" ]] \
        || { echo "docker-backup-tar-create: $name in temp_dir is not a regular file" >&2; exit 2; }
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { echo "docker-backup-tar-create: cannot read the mode of $name" >&2; exit 2; }
    as_invoker head -c "$((STAGE_MAX_BYTES + 1))" -- "./$name" > "$stage/$name" \
        || { echo "docker-backup-tar-create: cannot read $name as the invoking user" >&2; exit 1; }
    (( $(stat -c %s -- "$stage/$name") <= STAGE_MAX_BYTES )) \
        || { echo "docker-backup-tar-create: $name is larger than $STAGE_MAX_BYTES bytes" >&2; exit 2; }
    chmod "$mode" -- "$stage/$name"
    chown "$invoker_uid:$invoker_gid" -- "$stage/$name" 2>/dev/null || [[ $EUID -ne 0 ]] \
        || { echo "docker-backup-tar-create: cannot set the owner of the staged $name" >&2; exit 1; }
done
chmod 0700 -- "$stage"
chown "$invoker_uid:$invoker_gid" -- "$stage" 2>/dev/null || true

compression_flag=()
case "$compression" in
    none)  ;;
    gzip)  compression_flag=(-z) ;;
    bzip2) compression_flag=(-j) ;;
    xz)    compression_flag=(-J) ;;
    zstd)  compression_flag=(--zstd) ;;
esac

# Not `exec`: the EXIT trap removes the staging dir after tar.
rc=0
/usr/bin/tar -c "${compression_flag[@]}" "${exclude_args[@]}" -C "$stage" . -C "$source_root" "$stack_name" || rc=$?
exit "$rc"
