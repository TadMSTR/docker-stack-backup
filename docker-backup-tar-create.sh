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
    source_root=$("$SNAPSHOT_HELPER" source "$stack_name" "$snapshot_ts") \
        || { echo "docker-backup-tar-create: the snapshot helper could not resolve the snapshot" >&2; exit 1; }
    [[ "$source_root" == /* && "$source_root" != *[[:cntrl:]]* && -d "$source_root/$stack_name" && ! -L "$source_root/$stack_name" ]] \
        || { echo "docker-backup-tar-create: snapshot source is not a directory" >&2; exit 1; }
fi

compression_flag=()
case "$compression" in
    none)  ;;
    gzip)  compression_flag=(-z) ;;
    bzip2) compression_flag=(-j) ;;
    xz)    compression_flag=(-J) ;;
    zstd)  compression_flag=(--zstd) ;;
esac

exec /usr/bin/tar -c "${compression_flag[@]}" "${exclude_args[@]}" -C "$temp_dir" . -C "$source_root" "$stack_name"
