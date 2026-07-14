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
#       <appdata_path> <stack_name> [exclude_pattern...] > <output_file>
#######################################

set -euo pipefail

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

usage() {
    echo "Usage: $0 <compression:none|gzip|bzip2|xz|zstd> <temp_dir> <appdata_path> <stack_name> [exclude_pattern...]" >&2
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

# Stack name: single path component, no leading dash (would be parsed as a tar flag)
[[ "$stack_name" =~ ^[A-Za-z0-9._-]+$ && "$stack_name" != -* ]] || { echo "docker-backup-tar-create: invalid stack_name: $stack_name" >&2; exit 2; }
[[ -d "$appdata_path/$stack_name" ]] || { echo "docker-backup-tar-create: stack appdata dir not found: $appdata_path/$stack_name" >&2; exit 2; }

exclude_args=()
for pattern in "$@"; do
    [[ "$pattern" =~ ^[A-Za-z0-9._/*-]+$ && "$pattern" != -* ]] || { echo "docker-backup-tar-create: invalid exclude pattern: $pattern" >&2; exit 2; }
    exclude_args+=(--exclude="$pattern")
done

compression_flag=()
case "$compression" in
    none)  ;;
    gzip)  compression_flag=(-z) ;;
    bzip2) compression_flag=(-j) ;;
    xz)    compression_flag=(-J) ;;
    zstd)  compression_flag=(--zstd) ;;
esac

exec /usr/bin/tar -c "${compression_flag[@]}" "${exclude_args[@]}" -C "$temp_dir" . -C "$appdata_path" "$stack_name"
