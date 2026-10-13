#!/usr/bin/env bats
# The free-space preflight used a fixed 5 GB; one forge run writes ~80 GB. Since 0.5.0
# it requires max(MIN_FREE_GB, 1.2 x this host's most recent previous run dir).

setup() {
    TEST_DIR="$(mktemp -d)"
    export LOG_FILE="$TEST_DIR/test.log"
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib.sh"
    BACKUP_DEST="$TEST_DIR/backups"
    HOSTNAME="h"
    TIMESTAMP="20260301_020000"
    mkdir -p "$BACKUP_DEST/$HOSTNAME"
}

teardown() {
    rm -rf "${TEST_DIR:?}"
}

@test "no previous run: MIN_FREE_GB applies" {
    MIN_FREE_GB=5
    [ "$(required_free_bytes)" -eq $((5 * 1024 * 1024 * 1024)) ]
}

@test "MIN_FREE_GB defaults to 5" {
    unset MIN_FREE_GB
    [ "$(required_free_bytes)" -eq $((5 * 1024 * 1024 * 1024)) ]
}

@test "previous run larger than the floor: 1.2 x its size" {
    MIN_FREE_GB=0
    mkdir -p "$BACKUP_DEST/h/20260228_020000"
    head -c 10000000 /dev/zero > "$BACKUP_DEST/h/20260228_020000/s.tar"
    local prev; prev=$(du -sb "$BACKUP_DEST/h/20260228_020000" | cut -f1)
    [ "$(required_free_bytes)" -eq $((prev * 12 / 10)) ]
}

@test "uses the most recent previous run, not an older larger one" {
    MIN_FREE_GB=0
    mkdir -p "$BACKUP_DEST/h/20260101_020000" "$BACKUP_DEST/h/20260228_020000"
    head -c 20000000 /dev/zero > "$BACKUP_DEST/h/20260101_020000/s.tar"
    head -c 1000000 /dev/zero > "$BACKUP_DEST/h/20260228_020000/s.tar"
    local prev; prev=$(du -sb "$BACKUP_DEST/h/20260228_020000" | cut -f1)
    [ "$(required_free_bytes)" -eq $((prev * 12 / 10)) ]
}

@test "ignores the current run's own dir and non-run dirs" {
    MIN_FREE_GB=0
    mkdir -p "$BACKUP_DEST/h/$TIMESTAMP" "$BACKUP_DEST/h/zz-not-a-run"
    head -c 5000000 /dev/zero > "$BACKUP_DEST/h/$TIMESTAMP/s.tar"
    head -c 5000000 /dev/zero > "$BACKUP_DEST/h/zz-not-a-run/s.tar"
    [ "$(required_free_bytes)" -eq 0 ]
}

@test "the floor wins when the previous run is small" {
    MIN_FREE_GB=1
    mkdir -p "$BACKUP_DEST/h/20260228_020000"
    echo small > "$BACKUP_DEST/h/20260228_020000/s.tar"
    [ "$(required_free_bytes)" -eq $((1024 * 1024 * 1024)) ]
}
