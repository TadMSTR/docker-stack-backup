#!/usr/bin/env bats
# backup-verify.sh on a share shaped like forge's:
#   - `--stats` took oldest/newest with `find … | sort | head -1` under pipefail. Once the
#     listing outgrows the 64 KiB pipe buffer, head exits, sort dies of SIGPIPE and the
#     script exits 141 (#1099; forge's ~930 archives, 96 KB of listing).
#   - it read BACKUP_BASE only, while the backup writes BACKUP_DEST (#1091).

setup() {
    TEST_DIR="$(mktemp -d)"
    SRC="$BATS_TEST_DIRNAME/.."
    # A copy of the scripts, so a config.sh can be dropped next to them.
    mkdir -p "$TEST_DIR/scripts"
    cp "$SRC/backup-verify.sh" "$SRC/lib.sh" "$SRC/docker-stack-restore.sh" "$TEST_DIR/scripts/"
    SHARE="$TEST_DIR/share-with-a-path-long-enough-to-look-like-a-real-nfs-mount"
    HOST_DIR="$SHARE/testhost"
    unset BACKUP_BASE BACKUP_DEST
}

teardown() {
    rm -rf "${TEST_DIR:?}"
}

# 40 run dirs x 50 empty archives = 2000 entries; the old `%T+ %p` listing is ~240 KB.
_make_big_share() {
    local d s
    for d in $(seq -w 1 40); do
        mkdir -p "$HOST_DIR/202609${d}_020000"
        for s in $(seq -w 1 50); do
            : > "$HOST_DIR/202609${d}_020000/stack_with_a_longish_name_${s}.tar"
        done
        touch -d "2026-09-01 +$((10#$d - 1)) days" "$HOST_DIR/202609${d}_020000"/*.tar
    done
}

@test "--stats on a listing larger than the pipe buffer exits 0 with oldest/newest (#1099)" {
    _make_big_share
    BACKUP_BASE="$SHARE" run bash "$TEST_DIR/scripts/backup-verify.sh" --stats
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total backups: 2000"* ]]
    [[ "$output" == *"Backup sets: 40"* ]]
    [[ "$output" == *"Oldest: 2026-09-01"* ]]
    [[ "$output" == *"Newest: 2026-10-10"* ]]
}

@test "--stats on a host with no archives prints counts and no dates" {
    mkdir -p "$HOST_DIR/20261013_020000"
    BACKUP_BASE="$SHARE" run bash "$TEST_DIR/scripts/backup-verify.sh" --stats
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total backups: 0"* ]]
    [[ "$output" != *"Oldest:"* ]]
}

@test "a config.sh that sets only BACKUP_DEST: --list finds the host dir (#1091)" {
    mkdir -p "$HOST_DIR/20261013_020000"
    : > "$HOST_DIR/20261013_020000/web.tar"
    echo "BACKUP_DEST=\"$SHARE\"" > "$TEST_DIR/scripts/config.sh"
    run bash "$TEST_DIR/scripts/backup-verify.sh" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Host: testhost"* ]]
    [[ "$output" == *"- web ("* ]]
}

@test "a config.sh that sets only BACKUP_DEST: restore Step 1 finds the host dir (#1091)" {
    mkdir -p "$HOST_DIR/20261013_020000"
    echo "BACKUP_DEST=\"$SHARE\"" > "$TEST_DIR/scripts/config.sh"
    run bash -c 'LOG_FILE=/dev/null; source "$1"; echo "base=$BACKUP_BASE"; select_hostname' \
        _ "$TEST_DIR/scripts/docker-stack-restore.sh" <<< $'1'
    [ "$status" -eq 0 ]
    [[ "$output" == *"base=$SHARE"* ]]
    [[ "$output" == *"Selected host: "*"testhost"* ]]
}

@test "BACKUP_BASE still overrides BACKUP_DEST for the read-side tools" {
    mkdir -p "$HOST_DIR/20261013_020000" "$TEST_DIR/other/otherhost/20261013_020000"
    echo "BACKUP_DEST=\"$SHARE\"" > "$TEST_DIR/scripts/config.sh"
    BACKUP_BASE="$TEST_DIR/other" run bash "$TEST_DIR/scripts/backup-verify.sh" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Host: otherhost"* ]]
    [[ "$output" != *"testhost"* ]]
}
