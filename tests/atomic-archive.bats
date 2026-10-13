#!/usr/bin/env bats
# A failed tar used to leave a partial archive at the final <stack>.tar[.ext] path,
# which backup-verify.sh and docker-stack-restore.sh then enumerate (*.tar / *.tar.*)
# as a backup. Since 0.5.0 the archive is written to <stack>.incomplete and renamed
# only on success; on failure the partial file is deleted.

load helpers/stub-env

setup() {
    stub_env_setup
}

teardown() {
    stub_env_teardown
}

_no_archive_files() {
    [ -z "$(find "$BACKUP_DEST" \( -name '*.tar' -o -name '*.tar.*' -o -name '*.incomplete' \))" ]
}

@test "create_archive_atomic: a failing archive leaves no *.tar, *.tar.* or .incomplete file" {
    source "$BATS_TEST_DIRNAME/../lib.sh"
    create_compressed_archive() { printf 'partial' > "$1"; return 1; }
    local dir="$BACKUP_DEST/host/20260101_000000"
    mkdir -p "$dir"

    run create_archive_atomic "$dir/s.tar" -C /tmp . -C /tmp s
    [ "$status" -ne 0 ]
    _no_archive_files
}

@test "create_archive_atomic: writes to <stack>.incomplete, then renames to the final name" {
    source "$BATS_TEST_DIRNAME/../lib.sh"
    export COMPRESSION_METHOD=gzip
    create_compressed_archive() { echo "$1" > "$TEST_DIR/written-to"; printf 'data' > "$1"; }
    local dir="$BACKUP_DEST/host/20260101_000000"
    mkdir -p "$dir"

    create_archive_atomic "$dir/s.tar.gz" -C /tmp . -C /tmp s

    [ "$(cat "$TEST_DIR/written-to")" = "$dir/s.incomplete" ]
    [ -f "$dir/s.tar.gz" ]
    [ ! -e "$dir/s.incomplete" ]
}

@test "the temporary name matches neither *.tar nor *.tar.* (the verify/restore globs)" {
    source "$BATS_TEST_DIRNAME/../lib.sh"
    local name
    create_compressed_archive() { basename "$1" > "$TEST_DIR/name"; return 1; }
    for COMPRESSION_METHOD in none gzip bzip2 xz zstd; do
        create_archive_atomic "$BACKUP_DEST/s$(get_compression_extension)" -C /tmp . -C /tmp s || true
        name="$(cat "$TEST_DIR/name")"
        [ "$name" = "s.incomplete" ]
        [[ "$name" != *.tar && "$name" != *.tar.* ]]
    done
}

@test "full run: a failing helper leaves no archive, counts the stack as failed, and restarts it" {
    export STUB_HELPER_FAIL=1
    run_backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed: 1"* ]]
    [[ "$output" == *"Failed stacks: $STACK"* ]]
    _no_archive_files
    grep -qx "compose start app worker" "$DOCKER_LOG"
}
