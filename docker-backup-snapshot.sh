#!/bin/bash

#######################################
# docker-backup-snapshot — restricted snapshot helper for docker-stack-backup
#
# Companion to SNAPSHOT_BACKEND / SNAPSHOT_HELPER_PATH. Install it like
# docker-backup-tar-create.sh: root-owned, 0750, at a fixed path (e.g.
# /usr/local/sbin/docker-backup-snapshot.sh), and grant the backup user this exact path
# only. See ELEVATION.md and SECURITY.md.
#
# Why a helper? Creating and deleting btrfs subvolumes or ZFS snapshots needs root, and a
# loose `sudo btrfs` or `sudo zfs` grant is a root primitive (delete any subvolume,
# destroy any dataset). This helper takes NO path from its caller. The constants below,
# which only root can edit, decide every path; the caller passes a verb, a stack name and
# a run timestamp, each checked against a fixed shape.
#
# Verbs:
#   info                    print backend=, appdata=, snapshot_dir= / dataset= (one per line)
#   check  <stack>          print "ok", or "fallback <reason>" if a snapshot would hide data
#                           under the stack's appdata (nested subvolume, child dataset,
#                           any mountpoint) or could not be read (snapdir=disabled)
#   create <stack> <ts>     take the read-only snapshot dsb-<stack>-<ts>; exit 3 and print
#                           "fallback <reason>" if a boundary appeared since `check`
#   source <stack> <ts>     print the directory that holds <stack> inside that snapshot
#   delete <stack> <ts>     delete exactly that snapshot
#   sweep                   delete every leftover dsb-<stack>-<ts> snapshot, printing each
#                           name; anything else is left alone
# <stack>: one path component of [A-Za-z0-9._-], not '.', '..' or starting with '-'.
# <ts>:    YYYYMMDD_HHMMSS (the run timestamp).
# Exit: 0 done, 1 the operation failed, 2 refused (bad arguments or constants);
#       create only: 3 fallback (nothing left behind), 4 a snapshot it took is left behind.
#
# The tar helper's --from-snapshot mode asks this helper's `source` verb for the path, so
# the snapshot path rule lives here only.
#######################################

set -euo pipefail
umask 077
# ASCII character classes whatever the caller's locale (see docker-backup-tar-create.sh).
export LC_ALL=C

#######################################
# Trust boundary — root-set constants. Only root can edit this file.
#######################################
# The appdata root. Must equal config.sh's APPDATA_PATH (the backup checks it via `info`)
# and the tar helper's ALLOWED_APPDATA_PATH.
ALLOWED_APPDATA_PATH="/opt/appdata"
# btrfs or zfs: the filesystem ALLOWED_APPDATA_PATH lives on.
SNAPSHOT_BACKEND="btrfs"
# btrfs only. Empty: <the subvolume holding ALLOWED_APPDATA_PATH>/.dsb-snapshots. It must
# be on the same btrfs filesystem and must not be under ALLOWED_APPDATA_PATH. Created
# 0700 if missing.
SNAPSHOT_DIR=""
# Fixed search path: a root run with ELEVATION_CMD=none inherits the caller's PATH.
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

STACK_RE='^[A-Za-z0-9._-]+$'
TS_RE='^[0-9]{8}_[0-9]{6}$'
SNAP_RE='^dsb-[A-Za-z0-9._-]+-[0-9]{8}_[0-9]{6}$'
DATASET_RE='^[A-Za-z0-9][A-Za-z0-9_.:/-]*$'

refuse() { echo "docker-backup-snapshot: $*" >&2; exit 2; }
fail()   { echo "docker-backup-snapshot: $*" >&2; exit 1; }

valid_stack() { [[ "$1" =~ $STACK_RE && "$1" != -* && "$1" != . && "$1" != .. ]]; }
valid_ts()    { [[ "$1" =~ $TS_RE ]]; }

# A clean absolute path: no '.', '..' or empty component, no trailing '/'.
clean_abs() {
    local p="$1"
    [[ "$p" == /* && "$p" != */ && "$p" != *//* && "$p" != */./* && "$p" != */../* \
        && "$p" != */. && "$p" != */.. && "$p" != *[[:cntrl:]]* ]]
}

#######################################
# Constants check and path resolution
#######################################
clean_abs "$ALLOWED_APPDATA_PATH" || refuse "ALLOWED_APPDATA_PATH must be a clean absolute path"
[[ -d "$ALLOWED_APPDATA_PATH" && ! -L "$ALLOWED_APPDATA_PATH" ]] \
    || refuse "ALLOWED_APPDATA_PATH is not a directory: $ALLOWED_APPDATA_PATH"
case "$SNAPSHOT_BACKEND" in
    btrfs|zfs) ;;
    *) refuse "SNAPSHOT_BACKEND must be btrfs or zfs" ;;
esac
FS_TYPE=$(stat -f -c %T -- "$ALLOWED_APPDATA_PATH") || refuse "cannot stat the appdata filesystem"
[[ "$FS_TYPE" == "$SNAPSHOT_BACKEND" ]] \
    || refuse "ALLOWED_APPDATA_PATH is on $FS_TYPE, but SNAPSHOT_BACKEND is $SNAPSHOT_BACKEND"

# Path of $1 below $2 ("" when equal). Both are clean absolute paths, $1 under $2.
rel_below() {
    local p="$1" root="$2"
    if [[ "$p" == "$root" ]]; then
        echo ""
    elif [[ "$root" == / ]]; then
        echo "${p#/}"
    else
        echo "${p#"$root"/}"
    fi
}

if [[ "$SNAPSHOT_BACKEND" == btrfs ]]; then
    # The subvolume that holds the appdata root: the nearest directory at or above it
    # whose inode is 256 (a btrfs subvolume root; ordinary inodes start at 257).
    SUBVOL="$ALLOWED_APPDATA_PATH"
    while [[ "$(stat -c %i -- "$SUBVOL")" != 256 ]]; do
        [[ "$SUBVOL" != / ]] || refuse "no btrfs subvolume root found above $ALLOWED_APPDATA_PATH"
        SUBVOL=$(dirname -- "$SUBVOL")
    done
    [[ "$(stat -f -c %T -- "$SUBVOL")" == btrfs ]] || refuse "$SUBVOL is not on btrfs"
    # The walk goes by inode only, so it climbs past a mount whose root is not inode 256
    # (a bind mount, or a subvol= mount of a plain directory). A snapshot of the subvolume
    # above it shows the directory UNDER that mount, not the mounted data: stale data,
    # archived as a success, or nothing (audit p5a F-02 / CR-01). So the mount holding the
    # appdata root must be the subvolume itself or above it.
    APPMNT=$(findmnt -n -o TARGET --target "$ALLOWED_APPDATA_PATH") || refuse "cannot find the mount of $ALLOWED_APPDATA_PATH"
    if [[ "$APPMNT" != "$SUBVOL" && "$APPMNT" != / && "$SUBVOL" != "$APPMNT"/* ]]; then
        refuse "$APPMNT is mounted between the subvolume $SUBVOL and ALLOWED_APPDATA_PATH: a snapshot of $SUBVOL would not show it"
    fi
    REL=$(rel_below "$ALLOWED_APPDATA_PATH" "$SUBVOL")
    if [[ -z "$SNAPSHOT_DIR" ]]; then
        # Next to the subvolume when the appdata root IS the subvolume, since inside it
        # would be under the appdata root (CR-02); else at the top of the subvolume.
        parent=$(dirname -- "$SUBVOL")
        if [[ "$SUBVOL" == "$ALLOWED_APPDATA_PATH" && "$parent" == / ]]; then
            SNAPSHOT_DIR="/.dsb-snapshots"
        elif [[ "$SUBVOL" == "$ALLOWED_APPDATA_PATH" ]]; then
            SNAPSHOT_DIR="$parent/.dsb-snapshots"
        elif [[ "$SUBVOL" == / ]]; then
            SNAPSHOT_DIR="/.dsb-snapshots"
        else
            SNAPSHOT_DIR="$SUBVOL/.dsb-snapshots"
        fi
    fi
    clean_abs "$SNAPSHOT_DIR" || refuse "SNAPSHOT_DIR must be a clean absolute path"
    if [[ "$SNAPSHOT_DIR" == "$ALLOWED_APPDATA_PATH" || "$SNAPSHOT_DIR" == "$ALLOWED_APPDATA_PATH"/* ]]; then
        refuse "SNAPSHOT_DIR ($SNAPSHOT_DIR) must not be under ALLOWED_APPDATA_PATH; set SNAPSHOT_DIR in this helper"
    fi
    # A snapshot can only be made on the same btrfs filesystem. Next to a MOUNTED appdata
    # subvolume, the default lands on the parent mount, usually another filesystem: say so
    # here, at `info`, not as a create failure after every stop (audit p5a R2-04).
    snapdir_probe="$SNAPSHOT_DIR"
    while [[ ! -e "$snapdir_probe" && "$snapdir_probe" != / ]]; do snapdir_probe=$(dirname -- "$snapdir_probe"); done
    fs_subvol=$(findmnt -n -o UUID --target "$SUBVOL" 2>/dev/null) || fs_subvol=""
    fs_snapdir=$(findmnt -n -o UUID --target "$snapdir_probe" 2>/dev/null) || fs_snapdir=""
    if [[ -z "$fs_subvol" || "$fs_subvol" != "$fs_snapdir" ]]; then
        refuse "SNAPSHOT_DIR ($SNAPSHOT_DIR) is not on the btrfs filesystem of $SUBVOL; set SNAPSHOT_DIR in this helper to a directory on that filesystem"
    fi
else
    DATASET=$(findmnt -n -o SOURCE --target "$ALLOWED_APPDATA_PATH") || refuse "cannot find the dataset of $ALLOWED_APPDATA_PATH"
    MNT=$(findmnt -n -o TARGET --target "$ALLOWED_APPDATA_PATH") || refuse "cannot find the mountpoint of $ALLOWED_APPDATA_PATH"
    [[ "$DATASET" =~ $DATASET_RE && "$DATASET" != *@* ]] || refuse "unsupported dataset name for $ALLOWED_APPDATA_PATH"
    clean_abs "$MNT" || [[ "$MNT" == / ]] || refuse "unsupported mountpoint for $ALLOWED_APPDATA_PATH"
    REL=$(rel_below "$ALLOWED_APPDATA_PATH" "$MNT")
fi

snap_name() { printf 'dsb-%s-%s' "$1" "$2"; }

# The snapshot dir must be a real directory owned by whoever runs this (root), with no
# group or other access at all: a planted symlink or a writable dir would let another
# user steer what `delete`/`sweep` act on, and a traversable one would expose a frozen
# copy of the whole subvolume (files since tightened or deleted, old setuid binaries).
check_snapshot_dir() {
    [[ -d "$SNAPSHOT_DIR" && ! -L "$SNAPSHOT_DIR" ]] || fail "$SNAPSHOT_DIR is not a directory"
    local owner mode
    owner=$(stat -c %u -- "$SNAPSHOT_DIR")
    mode=$(stat -c %a -- "$SNAPSHOT_DIR")
    [[ "$owner" == "$EUID" ]] || fail "$SNAPSHOT_DIR is not owned by uid $EUID"
    (( (8#$mode & 8#077) == 0 )) || fail "$SNAPSHOT_DIR must be mode 0700 (no group or other access)"
    [[ "$(stat -f -c %T -- "$SNAPSHOT_DIR")" == btrfs ]] || fail "$SNAPSHOT_DIR is not on btrfs"
}

prepare_snapshot_dir() {
    if [[ ! -e "$SNAPSHOT_DIR" && ! -L "$SNAPSHOT_DIR" ]]; then
        mkdir -m 0700 -- "$SNAPSHOT_DIR" || fail "cannot create $SNAPSHOT_DIR"
    fi
    check_snapshot_dir
}

# btrfs: path of one of our snapshots, checked to be a real subvolume.
btrfs_snapshot_ok() {
    local snap="$1"
    [[ -d "$snap" && ! -L "$snap" && "$(stat -c %i -- "$snap")" == 256 ]]
}

# boundary <stack> — prints the reason a snapshot would hide data under the stack's
# appdata (nested-dataset, mountpoint, nested-subvolume), or nothing. Exits 1 when it
# cannot tell. Used by `check` before the stop and again by `create` after it.
boundary() {
    local dir="$ALLOWED_APPDATA_PATH/$1" mounts target fstype nested
    [[ -d "$dir" && ! -L "$dir" ]] || fail "not a directory: $dir"
    # Any mountpoint at or under the stack's appdata: a snapshot of the parent
    # filesystem shows it as an empty directory. -r prints targets with special
    # characters escaped; $dir itself has none, so a prefix test is exact.
    mounts=$(findmnt -rn -o TARGET,FSTYPE) || fail "findmnt failed"
    while read -r target fstype; do
        if [[ "$target" == "$dir" || "$target" == "$dir"/* ]]; then
            if [[ "$fstype" == zfs ]]; then echo nested-dataset; else echo mountpoint; fi
            return 0
        fi
    done <<< "$mounts"
    if [[ "$SNAPSHOT_BACKEND" == btrfs ]]; then
        # A nested subvolume (inode 256), the stack dir itself included. Any find error
        # other than a file vanishing mid-walk is "cannot tell": fall back.
        nested=$(find "$dir" -ignore_readdir_race -xdev -type d -inum 256 -print -quit) \
            || fail "cannot walk $dir"
        [[ -z "$nested" ]] || echo nested-subvolume
    fi
    return 0
}

#######################################
# Verbs
#######################################
verb="${1:-}"
[[ -n "$verb" ]] || refuse "usage: $0 info|check|create|source|delete|sweep ..."
shift

expect_args() {
    [[ $1 -eq $2 ]] || refuse "$verb: expected $2 argument(s)"
}

case "$verb" in
    info)
        expect_args $# 0
        echo "backend=$SNAPSHOT_BACKEND"
        echo "appdata=$ALLOWED_APPDATA_PATH"
        if [[ "$SNAPSHOT_BACKEND" == btrfs ]]; then
            echo "subvolume=$SUBVOL"
            echo "snapshot_dir=$SNAPSHOT_DIR"
        else
            echo "dataset=$DATASET"
            echo "mountpoint=$MNT"
        fi
        ;;

    check)
        expect_args $# 1
        stack="$1"
        valid_stack "$stack" || refuse "invalid stack name"
        reason=$(boundary "$stack") || exit 1
        if [[ -n "$reason" ]]; then
            echo "fallback $reason"
            exit 0
        fi
        if [[ "$SNAPSHOT_BACKEND" != btrfs ]]; then
            snapdir=$(zfs get -H -o value snapdir "$DATASET") || fail "cannot read snapdir of the dataset"
            if [[ "$snapdir" == disabled ]]; then
                echo "fallback snapdir-disabled"
                exit 0
            fi
        fi
        echo ok
        ;;

    create)
        expect_args $# 2
        stack="$1"; ts="$2"
        valid_stack "$stack" || refuse "invalid stack name"
        valid_ts "$ts" || refuse "invalid timestamp"
        name=$(snap_name "$stack" "$ts")
        # Only for a stack that exists: the grant must not mint whole-subvolume snapshots
        # for arbitrary names (each pins disk until the next sweep).
        [[ -d "$ALLOWED_APPDATA_PATH/$stack" && ! -L "$ALLOWED_APPDATA_PATH/$stack" ]] \
            || fail "no appdata dir for stack $stack"
        # `check` ran before the stop; a mount or subvolume made since then would be hidden
        # too (audit p5a F-03). Exit 3 + "fallback <reason>": the caller archives the old way.
        reason=$(boundary "$stack") || exit 1
        if [[ -n "$reason" ]]; then
            echo "fallback $reason"
            exit 3
        fi
        if [[ "$SNAPSHOT_BACKEND" == btrfs ]]; then
            prepare_snapshot_dir
            [[ ! -e "$SNAPSHOT_DIR/$name" && ! -L "$SNAPSHOT_DIR/$name" ]] || fail "$name already exists"
            btrfs subvolume snapshot -r "$SUBVOL" "$SNAPSHOT_DIR/$name" >/dev/null || fail "btrfs snapshot failed"
            # And what the snapshot itself holds, which no race can change: btrfs shows a
            # nested subvolume inside a snapshot as an empty directory with inode 2.
            # Exit 4 if a snapshot it took here could not be deleted again: the caller
            # must count that leftover (audit p5a R2-02), not read it as "no snapshot".
            inner="$SNAPSHOT_DIR/$name${REL:+/$REL}/$stack"
            if ! hidden=$(find "$inner" -type d -inum 2 -print -quit); then
                btrfs subvolume delete "$SNAPSHOT_DIR/$name" >/dev/null \
                    || { echo "docker-backup-snapshot: cannot walk the snapshot of $stack, and could not delete $name" >&2; exit 4; }
                fail "cannot walk the snapshot of $stack"
            fi
            if [[ -n "$hidden" ]]; then
                if ! btrfs subvolume delete "$SNAPSHOT_DIR/$name" >/dev/null; then
                    echo "docker-backup-snapshot: found a nested subvolume in $name, and could not delete it" >&2
                    echo "fallback nested-subvolume"
                    exit 4
                fi
                echo "fallback nested-subvolume"
                exit 3
            fi
        else
            zfs snapshot "$DATASET@$name" || fail "zfs snapshot failed"
        fi
        ;;

    source)
        expect_args $# 2
        stack="$1"; ts="$2"
        valid_stack "$stack" || refuse "invalid stack name"
        valid_ts "$ts" || refuse "invalid timestamp"
        name=$(snap_name "$stack" "$ts")
        if [[ "$SNAPSHOT_BACKEND" == btrfs ]]; then
            check_snapshot_dir
            btrfs_snapshot_ok "$SNAPSHOT_DIR/$name" || fail "no such snapshot: $name"
            root="$SNAPSHOT_DIR/$name"
        else
            if [[ "$MNT" == / ]]; then root="/.zfs/snapshot/$name"; else root="$MNT/.zfs/snapshot/$name"; fi
        fi
        src="$root${REL:+/$REL}"
        [[ -d "$src/$stack" && ! -L "$src/$stack" ]] || fail "$stack is not a directory in snapshot $name"
        printf '%s\n' "$src"
        ;;

    delete)
        expect_args $# 2
        stack="$1"; ts="$2"
        valid_stack "$stack" || refuse "invalid stack name"
        valid_ts "$ts" || refuse "invalid timestamp"
        name=$(snap_name "$stack" "$ts")
        if [[ "$SNAPSHOT_BACKEND" == btrfs ]]; then
            check_snapshot_dir
            btrfs_snapshot_ok "$SNAPSHOT_DIR/$name" || fail "no such snapshot: $name"
            btrfs subvolume delete "$SNAPSHOT_DIR/$name" >/dev/null || fail "btrfs subvolume delete failed"
        else
            # Never -r, never a name without '@': exactly one snapshot of one dataset.
            zfs list -H -t snapshot -o name "$DATASET@$name" >/dev/null 2>&1 || fail "no such snapshot: $name"
            zfs destroy "$DATASET@$name" || fail "zfs destroy failed"
        fi
        ;;

    sweep)
        expect_args $# 0
        rc=0
        if [[ "$SNAPSHOT_BACKEND" == btrfs ]]; then
            [[ -e "$SNAPSHOT_DIR" || -L "$SNAPSHOT_DIR" ]] || exit 0
            check_snapshot_dir
            shopt -s nullglob
            for snap in "$SNAPSHOT_DIR"/dsb-*; do
                name="${snap##*/}"
                [[ "$name" =~ $SNAP_RE ]] || continue
                btrfs_snapshot_ok "$snap" || continue
                if btrfs subvolume delete "$snap" >/dev/null; then
                    echo "$name"
                else
                    echo "docker-backup-snapshot: could not delete $name" >&2
                    rc=1
                fi
            done
        else
            names=$(zfs list -H -t snapshot -o name -d 1 "$DATASET") || fail "zfs list failed"
            while IFS= read -r full; do
                [[ "$full" == "$DATASET@"* ]] || continue
                name="${full#"$DATASET@"}"
                [[ "$name" =~ $SNAP_RE ]] || continue
                if zfs destroy "$DATASET@$name"; then
                    echo "$name"
                else
                    echo "docker-backup-snapshot: could not destroy $name" >&2
                    rc=1
                fi
            done <<< "$names"
        fi
        exit "$rc"
        ;;

    *)
        refuse "unknown verb"
        ;;
esac
