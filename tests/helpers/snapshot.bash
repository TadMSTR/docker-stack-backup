# Shims for the snapshot helper tests: the REAL docker-backup-snapshot.sh runs
# unprivileged against fake btrfs/zfs/findmnt/stat on PATH, so these tests run anywhere
# (CI included). Real btrfs is in snapshot-btrfs-real.bats.
#
# snap_setup <btrfs|zfs> creates, under $SNAP_T:
#   vol/            the fake subvolume (btrfs) or dataset mountpoint (zfs)
#   vol/appdata/st  a stack's appdata, with a file
# and $SNAP_HELPER, a copy of the real helper with its constants pointed there and its
# PATH line starting with the shim dir. Every shimmed btrfs/zfs call is appended to
# $SNAP_LOG ("btrfs <args>" / "zfs <args>").
#
# Knobs: STUB_SNAP_CREATE_RC (btrfs snapshot / zfs snapshot fail), STUB_SNAP_DELETE_RC,
# STUB_SNAPDIR (zfs snapdir, default hidden), $SNAP_T/mounts (extra findmnt -rn lines,
# "TARGET FSTYPE").

snap_setup() {
    local backend="$1"
    SNAP_T="${TEST_DIR:?}/snap"
    SNAP_SHIM="$SNAP_T/shim"
    SNAP_LOG="$SNAP_T/calls.log"
    SNAP_VOL="$SNAP_T/vol"
    SNAP_APPDATA="$SNAP_VOL/appdata"
    mkdir -p "$SNAP_SHIM" "$SNAP_APPDATA/st"
    echo payload > "$SNAP_APPDATA/st/file"
    : > "$SNAP_LOG"
    : > "$SNAP_T/mounts"
    printf '%s\n' "$SNAP_VOL" > "$SNAP_T/subvols"
    export SNAP_T SNAP_LOG SNAP_VOL SNAP_APPDATA
    export STUB_FS="$backend" STUB_DATASET="pool/apps" STUB_MNT="$SNAP_VOL"

    cat > "$SNAP_SHIM/stat" <<'STUB'
#!/usr/bin/env bash
# Fake fs type and subvolume inodes; everything else is the real stat.
last="${!#}"
if [[ "$1" == -f && "$2" == -c && "$3" == %T ]]; then echo "$STUB_FS"; exit 0; fi
if [[ "$1" == -c && "$2" == %i ]]; then
    if grep -qxF -- "$last" "$SNAP_T/subvols"; then echo 256; else echo 1000; fi
    exit 0
fi
exec /usr/bin/stat "$@"
STUB
    cat > "$SNAP_SHIM/btrfs" <<'STUB'
#!/usr/bin/env bash
echo "btrfs $*" >> "$SNAP_LOG"
case "$1 $2" in
    "subvolume snapshot")
        [[ "${STUB_SNAP_CREATE_RC:-0}" -ne 0 ]] && exit "$STUB_SNAP_CREATE_RC"
        src="$4" dst="$5"
        mkdir "$dst" && cp -a "$src/appdata" "$dst/" && echo "$dst" >> "$SNAP_T/subvols" ;;
    "subvolume delete")
        [[ "${STUB_SNAP_DELETE_RC:-0}" -ne 0 ]] && exit "$STUB_SNAP_DELETE_RC"
        rm -rf -- "$3"
        grep -vxF -- "$3" "$SNAP_T/subvols" > "$SNAP_T/subvols.new" || true
        mv "$SNAP_T/subvols.new" "$SNAP_T/subvols" ;;
esac
exit 0
STUB
    cat > "$SNAP_SHIM/zfs" <<'STUB'
#!/usr/bin/env bash
echo "zfs $*" >> "$SNAP_LOG"
snapdir="$STUB_MNT/.zfs/snapshot"
case "$1" in
    get) echo "${STUB_SNAPDIR:-hidden}" ;;
    snapshot)
        [[ "${STUB_SNAP_CREATE_RC:-0}" -ne 0 ]] && exit "$STUB_SNAP_CREATE_RC"
        name="${2#*@}"; mkdir -p "$snapdir/$name" && cp -a "$STUB_MNT/appdata" "$snapdir/$name/" ;;
    list)
        if [[ "$*" == *"-d 1"* ]]; then
            for d in "$snapdir"/*; do [[ -e "$d" ]] && echo "$STUB_DATASET@${d##*/}"; done
            [[ -f "$SNAP_T/extra-zfs" ]] && cat "$SNAP_T/extra-zfs"
        else
            last="${!#}"
            [[ -d "$snapdir/${last#*@}" ]] || exit 1
            echo "$last"
        fi ;;
    destroy)
        [[ "${STUB_SNAP_DELETE_RC:-0}" -ne 0 ]] && exit "$STUB_SNAP_DELETE_RC"
        name="${!#}"; name="${name#*@}"; rm -rf -- "${snapdir:?}/$name" ;;
esac
exit 0
STUB
    cat > "$SNAP_SHIM/findmnt" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"-o SOURCE --target"*) echo "$STUB_DATASET" ;;
    *"-o TARGET --target"*) echo "$STUB_MNT" ;;
    "-rn -o TARGET,FSTYPE") echo "/ ext4"; cat "$SNAP_T/mounts" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$SNAP_SHIM"/*

    SNAP_HELPER="$SNAP_T/docker-backup-snapshot.sh"
    snap_helper_with "$backend" ""
}

# snap_helper_with <backend> <snapshot_dir> — (re)writes $SNAP_HELPER's constants.
snap_helper_with() {
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$SNAP_APPDATA\"|" \
        -e "s|^SNAPSHOT_BACKEND=.*|SNAPSHOT_BACKEND=\"$1\"|" \
        -e "s|^SNAPSHOT_DIR=.*|SNAPSHOT_DIR=\"$2\"|" \
        -e "s|^PATH=.*|PATH=\"$SNAP_SHIM:/usr/sbin:/usr/bin:/sbin:/bin\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-snapshot.sh" > "$SNAP_HELPER"
    # A fixed mode, whatever the caller's umask: the tar helper refuses a group-writable
    # snapshot helper (F-04), and a 0002 umask would make this one so.
    chmod 0755 "$SNAP_HELPER"
}

# The calls that changed something (create/delete/destroy/snapshot), one per line.
snap_mutations() {
    grep -E '^(btrfs subvolume (snapshot|delete)|zfs (snapshot|destroy))' "$SNAP_LOG" || true
}
