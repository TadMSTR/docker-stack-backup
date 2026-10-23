#!/usr/bin/env bats
# restic change detection across fresh btrfs snapshots, on a REAL btrfs filesystem (plan
# p5b, Verification 3). Skips unless the checkout is on btrfs, user namespaces work and a
# restic binary is found (helpers/restic.bash).
#
# Each backup reads a NEW read-only snapshot (a different absolute path every time). The
# restic helper binds the stack's dir from it onto the fixed RESTIC_STAGE_DIR, so restic
# sees the same paths every night and picks the previous snapshot as the parent; btrfs
# snapshots keep inode numbers and ctimes, so restic's change detection (mtime, ctime,
# size, inode) holds. The stack's compose file and .env are copied into a fresh tmpfs for
# every backup (new inodes), so those two always count as changed: tiny files, re-read.

TS1=20261023_020001
TS2=20261024_020001
TS3=20261025_020001
TS4=20261026_020001

load helpers/restic

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    [[ "$(stat -f -c %T "$REPO")" == btrfs ]] || skip "the checkout is not on btrfs"
    command -v btrfs >/dev/null || skip "btrfs-progs not installed"
    TEST_DIR="$(mktemp -d)"
    SCR="$REPO/.scratch/bats-restic-real-$$"
    mkdir -p "$SCR"
    VOL="$SCR/vol"
    btrfs subvolume create "$VOL" >/dev/null || skip "cannot create a btrfs subvolume here"
    RH_APPDATA="$VOL/appdata" RH_STACK=web
    mkdir -p "$RH_APPDATA/web/db/pages" "$RH_APPDATA/web/conf"
    local i
    for i in 1 2 3 4 5 6 7 8; do head -c 50000 /dev/urandom > "$RH_APPDATA/web/db/pages/p$i"; done
    echo "listen 80" > "$RH_APPDATA/web/conf/site.conf"
    printf 'secret\n' > "$RH_APPDATA/web/db/key"
    chmod 0600 "$RH_APPDATA/web/db/key"
    APPDATA_FILES=10

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
    RH_SNAP_HELPER="$SCR/docker-backup-snapshot.sh"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$RH_APPDATA\"|" \
        -e "s|^SNAPSHOT_BACKEND=.*|SNAPSHOT_BACKEND=\"btrfs\"|" \
        -e "s|^PATH=.*|PATH=\"$SHIM:/usr/sbin:/usr/bin:/sbin:/bin\"|" \
        "$REPO/docker-backup-snapshot.sh" > "$RH_SNAP_HELPER"
    chmod 0755 "$RH_SNAP_HELPER"
    rh_setup_ns
}

teardown() {
    rh_teardown
    [[ -n "${SCR:-}" && -d "$SCR" ]] || return 0
    local sub
    while IFS= read -r sub; do
        btrfs property set "$sub" ro false 2>/dev/null || true
    done < <(find "$SCR" -depth -type d -inum 256 2>/dev/null)
    rm -rf -- "$SCR" "${TEST_DIR:?}"
}

# snap_backup <ts> — snapshot (as the test user, like the backup's helper call), restic
# from it, snapshot deleted; prints the summary's counts as "new changed unmodified added".
snap_backup() {
    "$RH_SNAP_HELPER" create web "$1" >&2
    local out rc=0
    out=$(rh_ns backup "$RH_TMP" web "$1" daily --from-snapshot) || rc=$?
    "$RH_SNAP_HELPER" delete web "$1" >&2
    [[ $rc -eq 0 ]] || return "$rc"
    counts "$out"
}

live_backup() {
    local out
    out=$(rh_ns backup "$RH_TMP" web "$1" daily) || return
    counts "$out"
}

counts() {
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["files_new"], d["files_changed"], d["files_unmodified"], d["data_added"])' "$1"
}

@test "real btrfs: change detection holds across fresh snapshots, and through a live-dir run between them" {
    local r1 r2 r3 r4 new changed unmod added
    r1=$(snap_backup "$TS1")
    echo "run 1 (snapshot): $r1" >&3
    read -r new changed unmod added <<< "$r1"
    [ "$new" -eq $((APPDATA_FILES + 2)) ]

    r2=$(snap_backup "$TS2")
    echo "run 2 (new snapshot, nothing changed): $r2" >&3
    read -r new changed unmod added <<< "$r2"
    [ "$new" -eq 0 ]
    [ "$unmod" -eq "$APPDATA_FILES" ]
    [ "$changed" -eq 2 ]                    # compose.yaml + .env, staged afresh
    [ "$added" -lt 20000 ]                  # metadata only; the 400 KB of pages is not re-read

    # A live-dir run (the stopped-stack / fallback case) between two snapshot runs.
    r3=$(live_backup "$TS3")
    echo "run 3 (live dir): $r3" >&3
    read -r new changed unmod added <<< "$r3"
    [ "$unmod" -eq "$APPDATA_FILES" ]
    [ "$changed" -eq 2 ]

    head -c 50000 /dev/urandom > "$RH_APPDATA/web/db/pages/p3"
    r4=$(snap_backup "$TS4")
    echo "run 4 (new snapshot, one file rewritten): $r4" >&3
    read -r new changed unmod added <<< "$r4"
    [ "$unmod" -eq $((APPDATA_FILES - 1)) ]
    [ "$changed" -eq 3 ]                    # p3 + compose.yaml + .env
    [ "$added" -ge 50000 ]

    # Every snapshot recorded the same paths (the fixed stage dir), which is what makes
    # each one the next one's parent.
    run rh_restic snapshots --json
    python3 - "$output" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
assert len(s) == 4, len(s)
assert len({tuple(sorted(x["paths"])) for x in s}) == 1, [x["paths"] for x in s]
assert all(x.get("parent") for x in s[1:]), "runs 2-4 must have a parent"
PY
}
