#!/usr/bin/env bats
# Snapshot-assisted backup on a REAL btrfs filesystem, unprivileged. Skips unless the
# repo checkout is on btrfs (GitHub runners are ext4; forge's /home is btrfs @home).
#
# A scratch subvolume is made in the gitignored .scratch/ dir of the checkout, never
# elsewhere. As a normal user, `btrfs subvolume create` and `snapshot -r` work, but
# deleting a read-only snapshot needs root; so `btrfs subvolume delete` alone is wrapped
# here as `property set ro false` + `rm -rf` (what root's delete amounts to for the
# test). Everything else is the real btrfs, the real stat/find/findmnt, the real helpers.
#
# What it proves (plan p5a, Verification 5-6):
#   - nested-subvolume detection on a real nested subvolume
#   - an archive made from the snapshot is the same archive as one of the same quiesced
#     data made live: identical `tar -tv` listings (names, modes, owners, sizes, mtimes)
#     and identical content hashes
#   - the restore wizard's Steps 1-6 restore that archive

TS=20261022_020001

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    [[ "$(stat -f -c %T "$REPO")" == btrfs ]] || skip "the checkout is not on btrfs"
    command -v btrfs >/dev/null || skip "btrfs-progs not installed"
    SCR="$REPO/.scratch/bats-real-$$"
    mkdir -p "$SCR"
    VOL="$SCR/vol"
    btrfs subvolume create "$VOL" >/dev/null || skip "cannot create a btrfs subvolume here"
    APPDATA="$VOL/appdata"
    mkdir -p "$APPDATA/web/conf" "$APPDATA/web/db/pages"
    echo "listen 80" > "$APPDATA/web/conf/site.conf"
    head -c 65536 /dev/urandom > "$APPDATA/web/db/pages/p1"
    printf 'secret\n' > "$APPDATA/web/db/key"
    chmod 0600 "$APPDATA/web/db/key"
    chmod 0700 "$APPDATA/web/db"
    ln -s conf/site.conf "$APPDATA/web/current"
    ln "$APPDATA/web/db/pages/p1" "$APPDATA/web/db/pages/p1-hardlink"
    touch -d '2026-01-02 03:04:05' "$APPDATA/web/conf/site.conf"

    SHIM="$SCR/shim"
    mkdir -p "$SHIM"
    local real_btrfs; real_btrfs=$(command -v btrfs)
    cat > "$SHIM/btrfs" <<STUB
#!/usr/bin/env bash
if [[ "\$1 \$2" == "subvolume delete" ]]; then
    "$real_btrfs" property set "\$3" ro false && rm -rf -- "\$3"
    exit
fi
exec "$real_btrfs" "\$@"
STUB
    chmod +x "$SHIM/btrfs"

    SNAP_HELPER="$SCR/docker-backup-snapshot.sh"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA\"|" \
        -e "s|^SNAPSHOT_BACKEND=.*|SNAPSHOT_BACKEND=\"btrfs\"|" \
        -e "s|^PATH=.*|PATH=\"$SHIM:/usr/sbin:/usr/bin:/sbin:/bin\"|" \
        "$REPO/docker-backup-snapshot.sh" > "$SNAP_HELPER"
    TAR_HELPER="$SCR/docker-backup-tar-create.sh"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA\"|" \
        -e "s|^SNAPSHOT_HELPER=.*|SNAPSHOT_HELPER=\"$SNAP_HELPER\"|" \
        "$REPO/docker-backup-tar-create.sh" > "$TAR_HELPER"
    chmod 0755 "$SNAP_HELPER" "$TAR_HELPER"
    TEMP_SRC="$(mktemp -d -p /tmp)"
    echo "services: {web: {image: nginx}}" > "$TEMP_SRC/compose.yaml"
    echo "WEB_PORT=80" > "$TEMP_SRC/.env"
}

teardown() {
    [[ -n "${SCR:-}" && -d "$SCR" ]] || return 0
    # Read-only snapshots and nested subvolumes cannot be removed by rm alone.
    local sub
    while IFS= read -r sub; do
        btrfs property set "$sub" ro false 2>/dev/null || true
    done < <(find "$SCR" -xdev -depth -type d -inum 256 2>/dev/null; find "$SCR" -depth -type d -inum 256 2>/dev/null)
    rm -rf -- "$SCR" "${TEMP_SRC:-/nonexistent}"
}

@test "real btrfs: the helper finds the subvolume and the stack has no boundary" {
    run "$SNAP_HELPER" info
    [ "$status" -eq 0 ]
    [[ "$output" == *"subvolume=$VOL"* ]]
    [[ "$output" == *"snapshot_dir=$VOL/.dsb-snapshots"* ]]
    run "$SNAP_HELPER" check web
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
}

@test "real btrfs: a nested subvolume under the stack forces the fallback" {
    mkdir -p "$APPDATA/web2"
    btrfs subvolume create "$APPDATA/web2/cache" >/dev/null
    echo inside > "$APPDATA/web2/cache/f"
    run "$SNAP_HELPER" check web2
    [ "$output" = "fallback nested-subvolume" ]
    # The trap it avoids, shown with btrfs directly: in a snapshot the nested subvolume
    # is an empty directory (inode 2).
    btrfs subvolume snapshot -r "$VOL" "$SCR/raw-snap" >/dev/null
    [ -d "$SCR/raw-snap/appdata/web2/cache" ]
    [ -z "$(ls -A "$SCR/raw-snap/appdata/web2/cache")" ]
    [ "$(stat -c %i "$SCR/raw-snap/appdata/web2/cache")" = 2 ]
    # And the helper will not take one: create re-checks after the stop.
    run "$SNAP_HELPER" create web2 "$TS"
    [ "$status" -eq 3 ]
    [ "$output" = "fallback nested-subvolume" ]
    # The stack dir itself being a subvolume counts too.
    btrfs subvolume create "$APPDATA/web3" >/dev/null
    run "$SNAP_HELPER" check web3
    [ "$output" = "fallback nested-subvolume" ]
}

@test "real btrfs: a nested subvolume made after check is caught in the snapshot itself (inode 2), and the snapshot removed" {
    run "$SNAP_HELPER" check web
    [ "$output" = ok ]
    btrfs subvolume create "$APPDATA/web/late" >/dev/null
    echo inside > "$APPDATA/web/late/f"
    # Hide the late subvolume from create's own pre-snapshot scan, so the post-snapshot
    # inode-2 scan is what has to catch it: a race we cannot time in a test.
    sed -i 's/^        reason=$(boundary "$stack") || exit 1$/        reason=""/' "$SNAP_HELPER"
    grep -c '^        reason=""$' "$SNAP_HELPER"
    run "$SNAP_HELPER" create web "$TS"
    [ "$status" -eq 3 ]
    [ "$output" = "fallback nested-subvolume" ]
    [ ! -e "$VOL/.dsb-snapshots/dsb-web-$TS" ]
}

@test "real btrfs: the snapshot-made archive equals the live one (listing and content hashes)" {
    "$SNAP_HELPER" create web "$TS"
    bash "$TAR_HELPER" none "$TEMP_SRC" "$APPDATA" web --from-snapshot "$TS" > "$SCR/snap.tar"
    bash "$TAR_HELPER" none "$TEMP_SRC" "$APPDATA" web > "$SCR/live.tar"
    diff <(tar -tvf "$SCR/snap.tar" | sort -k6) <(tar -tvf "$SCR/live.tar" | sort -k6)
    mkdir "$SCR/x-snap" "$SCR/x-live"
    tar -xf "$SCR/snap.tar" -C "$SCR/x-snap"
    tar -xf "$SCR/live.tar" -C "$SCR/x-live"
    diff <(cd "$SCR/x-snap" && find . -type f -exec sha256sum {} + | sort -k2) \
         <(cd "$SCR/x-live" && find . -type f -exec sha256sum {} + | sort -k2)
    [ "$(tar -tf "$SCR/snap.tar" | grep -c '^web/')" -ge 8 ]
    run "$SNAP_HELPER" delete web "$TS"
    [ "$status" -eq 0 ]
    [ ! -e "$VOL/.dsb-snapshots/dsb-web-$TS" ]
}

@test "real btrfs: the archive is from the snapshot, not the live dir that changed after it" {
    "$SNAP_HELPER" create web "$TS"
    echo "listen 8080" > "$APPDATA/web/conf/site.conf"
    bash "$TAR_HELPER" none "$TEMP_SRC" "$APPDATA" web --from-snapshot "$TS" > "$SCR/snap.tar"
    [ "$(tar -xOf "$SCR/snap.tar" web/conf/site.conf)" = "listen 80" ]
    "$SNAP_HELPER" delete web "$TS"
}

@test "real btrfs: declared excludes apply to the snapshot archive the same way" {
    "$SNAP_HELPER" create web "$TS"
    bash "$TAR_HELPER" none "$TEMP_SRC" "$APPDATA" web --from-snapshot "$TS" -- web/db/pages > "$SCR/snap.tar"
    bash "$TAR_HELPER" none "$TEMP_SRC" "$APPDATA" web -- web/db/pages > "$SCR/live.tar"
    diff <(tar -tf "$SCR/snap.tar" | sort) <(tar -tf "$SCR/live.tar" | sort)
    ! tar -tf "$SCR/snap.tar" | grep -q '^web/db/pages'
    tar -tf "$SCR/snap.tar" | grep -qx 'web/db/key'
    "$SNAP_HELPER" delete web "$TS"
}

@test "real btrfs: sweep removes leftover dsb snapshots and leaves the rest" {
    "$SNAP_HELPER" create web "$TS"
    "$SNAP_HELPER" create web 20261021_020001
    btrfs subvolume snapshot -r "$VOL" "$VOL/.dsb-snapshots/manual-keep" >/dev/null
    run "$SNAP_HELPER" sweep
    [ "$status" -eq 0 ]
    [ "$(sort <<< "$output")" = "$(printf 'dsb-web-20261021_020001\ndsb-web-%s' "$TS")" ]
    [ -d "$VOL/.dsb-snapshots/manual-keep" ]
}

@test "real btrfs: the restore wizard (Steps 1-6) restores a snapshot-made archive" {
    "$SNAP_HELPER" create web "$TS"
    local base="$SCR/share"
    mkdir -p "$base/testhost/20261013_020000"
    bash "$TAR_HELPER" none "$TEMP_SRC" "$APPDATA" web --from-snapshot "$TS" \
        > "$base/testhost/20261013_020000/web.tar"
    "$SNAP_HELPER" delete web "$TS"
    tar -tf "$base/testhost/20261013_020000/web.tar" | sort > "$SCR/archived.list"

    # A restore target: a different appdata root and stack dir, with old content.
    local target="$SCR/target"
    mkdir -p "$target/docker/testhost/web" "$target/appdata/web" "$SCR/tmp" "$SCR/safety" "$SCR/bin"
    echo old > "$target/docker/testhost/web/compose.yaml"
    echo old > "$target/appdata/web/old.txt"
    cat > "$SCR/bin/docker" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == compose && "$2" == ps && "$*" == *status=running* ]] && echo web
exit 0
STUB
    chmod +x "$SCR/bin/docker"
    run env PATH="$SCR/bin:$PATH" BACKUP_BASE="$base" LOG_FILE="$SCR/restore.log" \
        DOCKHAND_BASE="$target/docker" APPDATA_PATH="$target/appdata" DOCKHAND_APPEND_HOSTNAME=true \
        TMPDIR="$SCR/tmp" RESTORE_SAFETY_DIR="$SCR/safety" \
        bash -c 'source "$1"
                 select_hostname; select_timestamp; select_stack; preview_backup
                 check_conflicts; perform_restore; print_section "Restore Complete!"
                 echo REACHED_END' _ "$REPO/docker-stack-restore.sh" <<< $'1\n1\n1\ny\n2\ny'
    [ "$status" -eq 0 ]
    [[ "$output" == *REACHED_END* ]]
    [ "$(cat "$target/appdata/web/conf/site.conf")" = "listen 80" ]
    [ ! -e "$target/appdata/web/old.txt" ]
    cmp "$APPDATA/web/db/pages/p1" "$target/appdata/web/db/pages/p1"
    [ "$(cat "$target/docker/testhost/web/compose.yaml")" = "services: {web: {image: nginx}}" ]
    [ "$(cat "$target/docker/testhost/web/.env")" = "WEB_PORT=80" ]
    [ "$(stat -c %a "$target/appdata/web/db/key")" = 600 ]
}
