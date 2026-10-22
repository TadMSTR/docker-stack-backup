#!/usr/bin/env bats
# docker-backup-snapshot.sh, the root snapshot helper (0.7.0). Its trust boundary: the
# caller passes a verb, a stack name and a run timestamp, never a path; root-set
# constants decide every path. The negative probes at the end are each run first against
# a NAIVE helper (the obvious implementation that takes names or paths from its caller)
# to show the probe really fires, then against the real helper, which must refuse it
# without running btrfs/zfs at all. (Lesson from the p3a audit: a probe that has never
# been seen to fire proves nothing.)

load helpers/snapshot

TS=20261022_020001

setup() {
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "${TEST_DIR:?}"
}

# ---------------------------------------------------------------------------
# btrfs verbs
# ---------------------------------------------------------------------------

@test "btrfs info: backend, appdata, the subvolume and the default snapshot dir" {
    snap_setup btrfs
    run "$SNAP_HELPER" info
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'backend=btrfs\nappdata=%s\nsubvolume=%s\nsnapshot_dir=%s' \
        "$SNAP_APPDATA" "$SNAP_VOL" "$SNAP_VOL/.dsb-snapshots")" ]
}

@test "btrfs create, source, delete: one snapshot, read from the right place, removed" {
    snap_setup btrfs
    run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$SNAP_VOL/.dsb-snapshots")" = 700 ]
    grep -qx "btrfs subvolume snapshot -r $SNAP_VOL $SNAP_VOL/.dsb-snapshots/dsb-st-$TS" "$SNAP_LOG"
    run "$SNAP_HELPER" source st "$TS"
    [ "$status" -eq 0 ]
    [ "$output" = "$SNAP_VOL/.dsb-snapshots/dsb-st-$TS/appdata" ]
    [ "$(cat "$output/st/file")" = payload ]
    run "$SNAP_HELPER" delete st "$TS"
    [ "$status" -eq 0 ]
    grep -qx "btrfs subvolume delete $SNAP_VOL/.dsb-snapshots/dsb-st-$TS" "$SNAP_LOG"
    [ ! -e "$SNAP_VOL/.dsb-snapshots/dsb-st-$TS" ]
}

@test "create refuses a stack with no appdata dir (no snapshots minted for arbitrary names)" {
    snap_setup btrfs
    run "$SNAP_HELPER" create nosuchstack "$TS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no appdata dir for stack nosuchstack"* ]]
    ln -s st "$SNAP_APPDATA/linked"
    run "$SNAP_HELPER" create linked "$TS"
    [ "$status" -eq 1 ]
    [ -z "$(snap_mutations)" ]
}

@test "btrfs create refuses to reuse an existing name; delete of a missing snapshot fails" {
    snap_setup btrfs
    "$SNAP_HELPER" create st "$TS"
    run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 1 ]
    run "$SNAP_HELPER" delete st 20990101_000000
    [ "$status" -eq 1 ]
}

@test "btrfs check: ok; a mountpoint under the stack falls back" {
    snap_setup btrfs
    run "$SNAP_HELPER" check st
    [ "$output" = ok ]
    mkdir -p "$SNAP_APPDATA/st/db"
    echo "$SNAP_APPDATA/st/db ext4" > "$SNAP_T/mounts"
    run "$SNAP_HELPER" check st
    [ "$status" -eq 0 ]
    [ "$output" = "fallback mountpoint" ]
    # The stack dir itself mounted counts too; another stack's mount does not.
    echo "$SNAP_APPDATA/st xfs" > "$SNAP_T/mounts"
    run "$SNAP_HELPER" check st
    [ "$output" = "fallback mountpoint" ]
    mkdir -p "$SNAP_APPDATA/st2"
    echo "$SNAP_APPDATA/st2 ext4" > "$SNAP_T/mounts"
    run "$SNAP_HELPER" check st
    [ "$output" = ok ]
}

@test "btrfs check: a stack dir that cannot be walked is 'cannot tell' (exit 1), not ok" {
    [[ $EUID -ne 0 ]] || skip "root reads a 0000 dir"
    snap_setup btrfs
    mkdir -p "$SNAP_APPDATA/st/locked/inner"
    chmod 000 "$SNAP_APPDATA/st/locked"
    run "$SNAP_HELPER" check st
    chmod 755 "$SNAP_APPDATA/st/locked"
    [ "$status" -eq 1 ]
    ! grep -qx ok <<< "$output"
    ! grep -q '^fallback' <<< "$output"
}

@test "btrfs sweep: removes only dsb-<stack>-<ts> subvolumes, prints each" {
    snap_setup btrfs
    "$SNAP_HELPER" create st "$TS"
    "$SNAP_HELPER" create st2 20261021_020001 2>/dev/null || { mkdir -p "$SNAP_APPDATA/st2"; "$SNAP_HELPER" create st2 20261021_020001; }
    local sd="$SNAP_VOL/.dsb-snapshots"
    mkdir "$sd/manual-keep" "$sd/dsb-st-notats" "$sd/dsb-plain-dir-20261022_020001"
    echo "$sd/manual-keep" >> "$SNAP_T/subvols"
    echo "$sd/dsb-st-notats" >> "$SNAP_T/subvols"
    run "$SNAP_HELPER" sweep
    [ "$status" -eq 0 ]
    [ "$(sort <<< "$output")" = "$(printf 'dsb-st-%s\ndsb-st2-20261021_020001' "$TS")" ]
    [ -d "$sd/manual-keep" ]
    [ -d "$sd/dsb-st-notats" ]
    [ -d "$sd/dsb-plain-dir-20261022_020001" ]   # not a subvolume: left alone
}

@test "btrfs sweep with no snapshot dir yet does nothing" {
    snap_setup btrfs
    run "$SNAP_HELPER" sweep
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(snap_mutations)" ]
}

@test "btrfs snapshot dir: refused when under the appdata root, a symlink, or group-writable" {
    snap_setup btrfs
    snap_helper_with btrfs "$SNAP_APPDATA/.snaps"
    run "$SNAP_HELPER" info
    [ "$status" -eq 2 ]
    [[ "$output" == *"must not be under ALLOWED_APPDATA_PATH"* ]]

    mkdir -p "$SNAP_T/elsewhere"
    ln -s "$SNAP_T/elsewhere" "$SNAP_VOL/linked"
    snap_helper_with btrfs "$SNAP_VOL/linked"
    run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a directory"* ]]

    mkdir -m 0770 "$SNAP_VOL/shared"
    chmod 0770 "$SNAP_VOL/shared"
    snap_helper_with btrfs "$SNAP_VOL/shared"
    run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be mode 0700"* ]]

    # Readable by others is refused too: it exposes a frozen copy of the subvolume.
    mkdir "$SNAP_VOL/readable"
    chmod 0755 "$SNAP_VOL/readable"
    snap_helper_with btrfs "$SNAP_VOL/readable"
    run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be mode 0700"* ]]
    # delete, source and sweep check the dir as well, not only create.
    run "$SNAP_HELPER" sweep
    [ "$status" -eq 1 ]
    run "$SNAP_HELPER" delete st "$TS"
    [ "$status" -eq 1 ]
    [ -z "$(snap_mutations)" ]
}

@test "constants: a backend that does not match the appdata filesystem is refused" {
    snap_setup btrfs
    snap_helper_with zfs ""
    run "$SNAP_HELPER" info
    [ "$status" -eq 2 ]
    [[ "$output" == *"is on btrfs, but SNAPSHOT_BACKEND is zfs"* ]]
}

# ---------------------------------------------------------------------------
# zfs verbs
# ---------------------------------------------------------------------------

@test "zfs info, create, source, delete" {
    snap_setup zfs
    run "$SNAP_HELPER" info
    [ "$output" = "$(printf 'backend=zfs\nappdata=%s\ndataset=pool/apps\nmountpoint=%s' "$SNAP_APPDATA" "$SNAP_VOL")" ]
    run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 0 ]
    grep -qx "zfs snapshot pool/apps@dsb-st-$TS" "$SNAP_LOG"
    run "$SNAP_HELPER" source st "$TS"
    [ "$output" = "$SNAP_VOL/.zfs/snapshot/dsb-st-$TS/appdata" ]
    run "$SNAP_HELPER" delete st "$TS"
    [ "$status" -eq 0 ]
    grep -qx "zfs destroy pool/apps@dsb-st-$TS" "$SNAP_LOG"
}

@test "zfs check: snapdir=disabled falls back; a child dataset under the stack falls back" {
    snap_setup zfs
    run "$SNAP_HELPER" check st
    [ "$output" = ok ]
    STUB_SNAPDIR=disabled run "$SNAP_HELPER" check st
    [ "$output" = "fallback snapdir-disabled" ]
    mkdir -p "$SNAP_APPDATA/st/db"
    echo "$SNAP_APPDATA/st/db zfs" > "$SNAP_T/mounts"
    run "$SNAP_HELPER" check st
    [ "$output" = "fallback nested-dataset" ]
}

@test "zfs sweep: destroys only <dataset>@dsb-<stack>-<ts>, never another dataset's" {
    snap_setup zfs
    "$SNAP_HELPER" create st "$TS"
    mkdir -p "$SNAP_VOL/.zfs/snapshot/manual-keep" "$SNAP_VOL/.zfs/snapshot/dsb-st-notats"
    printf '%s\n' "pool/apps/child@dsb-st-$TS" "pool/other@dsb-st-$TS" > "$SNAP_T/extra-zfs"
    run "$SNAP_HELPER" sweep
    [ "$status" -eq 0 ]
    [ "$output" = "dsb-st-$TS" ]
    [ "$(snap_mutations | grep -c destroy)" = 1 ]
    grep -qx "zfs destroy pool/apps@dsb-st-$TS" "$SNAP_LOG"
}

@test "zfs: every destroy is one <dataset>@dsb-… name, never -r, never without @" {
    snap_setup zfs
    "$SNAP_HELPER" create st "$TS"
    "$SNAP_HELPER" delete st "$TS"
    "$SNAP_HELPER" create st "$TS"
    "$SNAP_HELPER" sweep
    run grep '^zfs destroy' "$SNAP_LOG"
    [ "${#lines[@]}" -eq 2 ]
    local l
    for l in "${lines[@]}"; do
        [[ "$l" =~ ^zfs\ destroy\ pool/apps@dsb-st-[0-9]{8}_[0-9]{6}$ ]]
    done
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "bad verbs and argument counts are refused (exit 2) before anything runs" {
    snap_setup btrfs
    local args
    for args in "" "frobnicate" "info extra" "check" "check st extra" "create st" \
        "create st $TS extra" "delete" "sweep extra" "source st"; do
        # shellcheck disable=SC2086
        run "$SNAP_HELPER" $args
        echo "case: $args -> $status" >&2
        [ "$status" -eq 2 ]
    done
    [ -z "$(snap_mutations)" ]
}

# ---------------------------------------------------------------------------
# Negative probes: naive helper first (the probe fires), then the real one (refused)
# ---------------------------------------------------------------------------

# The obvious helper: it trusts what it is given.
naive_helper() {
    local naive="$SNAP_T/naive.sh"
    cat > "$naive" <<NAIVE
#!/usr/bin/env bash
PATH="$SNAP_SHIM:\$PATH"
SNAPSHOT_DIR="$SNAP_VOL/.dsb-snapshots"
case "\$1" in
    create)  btrfs subvolume snapshot -r "\$2" "\$SNAPSHOT_DIR/dsb-\$3-\$4" ;;
    delete)  btrfs subvolume delete "\$SNAPSHOT_DIR/dsb-\$2-\$3" ;;
    zdelete) zfs destroy \$2 ;;
    sweep)   for s in "\$SNAPSHOT_DIR"/*; do btrfs subvolume delete "\$s"; done ;;
    zsweep)  zfs list -H -t snapshot -o name -d 1 pool/apps | while read -r n; do zfs destroy "\$n"; done ;;
esac
NAIVE
    chmod +x "$naive"
    echo "$naive"
}

@test "probe: path injection through the stack name" {
    snap_setup btrfs
    mkdir -p -m 0700 "$SNAP_VOL/.dsb-snapshots"
    "$(naive_helper)" delete "x/../../../victim" "$TS"
    grep -q "btrfs subvolume delete $SNAP_VOL/.dsb-snapshots/dsb-x/../../../victim" "$SNAP_LOG"   # fires
    : > "$SNAP_LOG"
    local s
    for s in "x/../../../victim" ".." "." "-r" "a b" $'a\nb' "a/b" "" "st;id"; do
        run "$SNAP_HELPER" delete "$s" "$TS"
        [ "$status" -eq 2 ]
        run "$SNAP_HELPER" create "$s" "$TS"
        [ "$status" -eq 2 ]
        run "$SNAP_HELPER" check "$s"
        [ "$status" -eq 2 ]
    done
    [ -z "$(snap_mutations)" ]
}

@test "probe: path injection through the timestamp" {
    snap_setup btrfs
    mkdir -p -m 0700 "$SNAP_VOL/.dsb-snapshots"
    "$(naive_helper)" delete st "$TS/../../../../victim"
    grep -q "/../../../../victim" "$SNAP_LOG"   # fires
    : > "$SNAP_LOG"
    local t
    for t in "$TS/../../x" "20261022_02000" "20261022-020001" "2026102_0200011" " $TS" "$TS " "-r"; do
        run "$SNAP_HELPER" delete st "$t"
        [ "$status" -eq 2 ]
        run "$SNAP_HELPER" create st "$t"
        [ "$status" -eq 2 ]
    done
    [ -z "$(snap_mutations)" ]
}

@test "probe: zfs destroy without '@', or with -r" {
    snap_setup zfs
    "$(naive_helper)" zdelete "pool/apps"
    grep -qx "zfs destroy pool/apps" "$SNAP_LOG"            # fires: the whole dataset
    "$(naive_helper)" zdelete "-r pool/apps@x"
    grep -qx "zfs destroy -r pool/apps@x" "$SNAP_LOG"       # fires: recursive
    : > "$SNAP_LOG"
    run "$SNAP_HELPER" delete "pool/apps" "$TS"
    [ "$status" -eq 2 ]
    run "$SNAP_HELPER" delete "-r" "$TS"
    [ "$status" -eq 2 ]
    run "$SNAP_HELPER" delete st "$TS" -r
    [ "$status" -eq 2 ]
    [ -z "$(snap_mutations)" ]
}

@test "probe: sweep touching a snapshot that is not dsb-<stack>-<ts>" {
    snap_setup btrfs
    local sd="$SNAP_VOL/.dsb-snapshots"
    mkdir -p -m 0700 "$sd"
    mkdir "$sd/manual-keep"
    echo "$sd/manual-keep" >> "$SNAP_T/subvols"
    "$(naive_helper)" sweep
    grep -qx "btrfs subvolume delete $sd/manual-keep" "$SNAP_LOG"   # fires
    mkdir -p "$sd/manual-keep"
    : > "$SNAP_LOG"
    run "$SNAP_HELPER" sweep
    [ "$status" -eq 0 ]
    [ -d "$sd/manual-keep" ]
    [ -z "$(snap_mutations)" ]

    snap_setup zfs
    mkdir -p "$SNAP_VOL/.zfs/snapshot/manual-keep"
    "$(naive_helper)" zsweep
    grep -qx "zfs destroy pool/apps@manual-keep" "$SNAP_LOG"         # fires
    mkdir -p "$SNAP_VOL/.zfs/snapshot/manual-keep"
    : > "$SNAP_LOG"
    run "$SNAP_HELPER" sweep
    [ -z "$(snap_mutations)" ]
}

@test "probe: a snapshot source outside the root constants" {
    snap_setup btrfs
    mkdir -p -m 0700 "$SNAP_VOL/.dsb-snapshots"
    "$(naive_helper)" create /etc st "$TS"
    grep -qx "btrfs subvolume snapshot -r /etc $SNAP_VOL/.dsb-snapshots/dsb-st-$TS" "$SNAP_LOG"   # fires
    : > "$SNAP_LOG"
    # The real helper has no source argument at all: an extra one is refused, and a path
    # in the stack slot is not a stack name.
    run "$SNAP_HELPER" create /etc st "$TS"
    [ "$status" -eq 2 ]
    run "$SNAP_HELPER" create /etc "$TS"
    [ "$status" -eq 2 ]
    [ -z "$(snap_mutations)" ]
    # Whatever it is asked, the snapshot it takes is of the subvolume holding the
    # constant appdata root.
    "$SNAP_HELPER" create st 20261022_020002
    grep -qx "btrfs subvolume snapshot -r $SNAP_VOL $SNAP_VOL/.dsb-snapshots/dsb-st-20261022_020002" "$SNAP_LOG"
}

# ---------------------------------------------------------------------------
# The tar helper's --from-snapshot mode
# ---------------------------------------------------------------------------

tar_helper_setup() {
    TEMP_SRC="$(mktemp -d -p /tmp)"
    echo cfg > "$TEMP_SRC/compose.yaml"
    TAR_HELPER="$SNAP_T/tar-create.sh"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$SNAP_APPDATA\"|" \
        -e "s|^SNAPSHOT_HELPER=.*|SNAPSHOT_HELPER=\"${1:-$SNAP_HELPER}\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-tar-create.sh" > "$TAR_HELPER"
    chmod +x "$TAR_HELPER"
}

@test "tar helper --from-snapshot: archives the snapshot's copy, same member names as live" {
    snap_setup btrfs
    tar_helper_setup
    "$SNAP_HELPER" create st "$TS"
    echo changed-after-snapshot > "$SNAP_APPDATA/st/file"
    bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st --from-snapshot "$TS" > "$SNAP_T/snap.tar"
    bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st > "$SNAP_T/live.tar"
    diff <(tar -tf "$SNAP_T/snap.tar" | sort) <(tar -tf "$SNAP_T/live.tar" | sort)
    [ "$(tar -xOf "$SNAP_T/snap.tar" st/file)" = payload ]
    [ "$(tar -xOf "$SNAP_T/live.tar" st/file)" = changed-after-snapshot ]
    rm -rf "${TEMP_SRC:?}"
}

@test "probe: the tar helper takes no snapshot path from its caller" {
    snap_setup btrfs
    # Naive: a --from-snapshot that takes a directory.
    local naive="$SNAP_T/naive-tar.sh"
    printf '#!/usr/bin/env bash\n[[ "$1" == --from-snapshot ]] && exec tar -c -C "$2" "$3"\n' > "$naive"
    run bash -c "bash '$naive' --from-snapshot / etc/hostname | tar -t"
    [[ "$output" == *etc/hostname* ]]                                  # fires
    tar_helper_setup
    local bad
    for bad in / /etc "../$TS" "$TS/.." "" "x"; do
        run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st --from-snapshot "$bad"
        [ "$status" -eq 2 ]
        [[ "$output" == *"invalid --from-snapshot timestamp"* ]]
    done
    rm -rf "${TEMP_SRC:?}"
}

@test "the tar helper refuses a snapshot source that is not a directory holding the stack" {
    snap_setup btrfs
    local liar="$SNAP_T/liar.sh"
    printf '#!/usr/bin/env bash\necho "%s"\n' "relative/path" > "$liar"
    chmod 0755 "$liar"
    tar_helper_setup "$liar"
    run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st --from-snapshot "$TS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"appdata root is not ALLOWED_APPDATA_PATH"* ]]
    # A helper that agrees on appdata but points `source` outside the snapshot.
    "$SNAP_HELPER" create st "$TS"
    cat > "$liar" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == info ]]; then exec "$SNAP_HELPER" info; fi
echo "$SNAP_APPDATA/.."
STUB
    tar_helper_setup "$liar"
    run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st --from-snapshot "$TS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"snapshot source is outside the snapshot"* ]]
    "$SNAP_HELPER" delete st "$TS"
    # The snapshot helper failing (no such snapshot) fails the archive too.
    tar_helper_setup "$SNAP_HELPER"
    run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st --from-snapshot "$TS"
    [ "$status" -eq 1 ]
    rm -rf "${TEMP_SRC:?}"
}

@test "probe: tar flags smuggled in as declared paths" {
    snap_setup btrfs
    tar_helper_setup
    local mark="$SNAP_T/PWNED"
    # Naive: declared paths appended to tar's arguments as they are.
    local naive="$SNAP_T/naive-decl.sh"
    printf '#!/usr/bin/env bash\nexec tar -c -C "$1" st "${@:2}"\n' > "$naive"
    bash "$naive" "$SNAP_APPDATA" --checkpoint=1 "--checkpoint-action=exec=touch $mark" > /dev/null
    [ -e "$mark" ]                                                     # fires
    rm -f "$mark"
    run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st -- --checkpoint=1 "--checkpoint-action=exec=touch $mark"
    [ "$status" -eq 2 ]
    run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st -- "st/--checkpoint=1"
    [ "$status" -eq 2 ]
    run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st -- "st/../../etc"
    [ "$status" -eq 2 ]
    [ ! -e "$mark" ]
    rm -rf "${TEMP_SRC:?}"
}

@test "the tar helper refuses a snapshot helper that others can write (F-04)" {
    snap_setup btrfs
    tar_helper_setup
    "$SNAP_HELPER" create st "$TS"
    chmod 0775 "$SNAP_HELPER"
    run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st --from-snapshot "$TS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not group/other-writable"* ]]
    chmod 0755 "$SNAP_HELPER"
    ln -s "$SNAP_HELPER" "$SNAP_T/linked-helper"
    tar_helper_setup "$SNAP_T/linked-helper"
    run bash "$TAR_HELPER" none "$TEMP_SRC" "$SNAP_APPDATA" st --from-snapshot "$TS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a regular file"* ]]
    rm -rf "${TEMP_SRC:?}"
}

@test "F-02: a mount between the subvolume and the appdata root makes the helper refuse to run" {
    snap_setup btrfs
    # findmnt --target says the appdata root is its own mount (a bind mount), below the
    # subvolume the inode walk found.
    export STUB_MNT="$SNAP_APPDATA"
    run "$SNAP_HELPER" info
    [ "$status" -eq 2 ]
    [[ "$output" == *"is mounted between the subvolume"* ]]
    run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 2 ]
    [ -z "$(snap_mutations)" ]
}

@test "CR-02: when the appdata root is itself the subvolume, the default snapshot dir sits next to it" {
    snap_setup btrfs
    printf '%s\n' "$SNAP_APPDATA" > "$SNAP_T/subvols"
    export STUB_MNT="$SNAP_APPDATA"
    run "$SNAP_HELPER" info
    [ "$status" -eq 0 ]
    [[ "$output" == *"subvolume=$SNAP_APPDATA"* ]]
    [[ "$output" == *"snapshot_dir=$SNAP_VOL/.dsb-snapshots"* ]]
}

@test "create re-checks the boundary after the stop: a mount that appeared since check -> exit 3, no snapshot (F-03)" {
    snap_setup btrfs
    run "$SNAP_HELPER" check st
    [ "$output" = ok ]
    mkdir -p "$SNAP_APPDATA/st/late"
    echo "$SNAP_APPDATA/st/late ext4" > "$SNAP_T/mounts"
    run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 3 ]
    [ "$output" = "fallback mountpoint" ]
    [ -z "$(snap_mutations)" ]
}

@test "R2-02: nested subvolume found in the snapshot and its delete fails -> exit 4, fallback printed" {
    snap_setup btrfs
    STUB_INODE2=1 STUB_SNAP_DELETE_RC=1 run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 4 ]
    [[ "$output" == *"fallback nested-subvolume"* ]]
    [[ "$output" == *"could not delete it"* ]]
    # And with a working delete: exit 3, nothing left.
    "$SNAP_HELPER" delete st "$TS"
    STUB_INODE2=1 run "$SNAP_HELPER" create st "$TS"
    [ "$status" -eq 3 ]
    [ "$output" = "fallback nested-subvolume" ]
    [ ! -e "$SNAP_VOL/.dsb-snapshots/dsb-st-$TS" ]
}

@test "R2-04: a snapshot dir on another filesystem than the subvolume is refused at info" {
    snap_setup btrfs
    printf '%s\n' "$SNAP_APPDATA" > "$SNAP_T/subvols"
    export STUB_MNT="$SNAP_APPDATA"
    # Appdata is a mounted subvolume; its parent (where the default goes) is another fs.
    export STUB_OTHER_FS="$SNAP_VOL"
    run "$SNAP_HELPER" info
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not on the btrfs filesystem of $SNAP_APPDATA"* ]]
    [[ "$output" == *"set SNAPSHOT_DIR in this helper"* ]]
}
