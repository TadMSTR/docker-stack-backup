#!/usr/bin/env bats
# status.json sits on the share at two levels: a regular file next to the run dirs, and
# a copy inside a run dir. Restore, verify and cleanup must behave exactly as without
# them: they enumerate directories (restore Step 2, verify --list/--stats, cleanup) and
# *.tar* files (restore Step 3, verify), and a status.json is neither.

setup() {
    TEST_DIR="$(mktemp -d)"
    export BACKUP_BASE="$TEST_DIR/backups"
    export LOG_FILE="$TEST_DIR/t.log"
    export DOCKHAND_BASE="$TEST_DIR/docker" APPDATA_PATH="$TEST_DIR/appdata"
    HOST_DIR="$BACKUP_BASE/testhost"
    SRC="$BATS_TEST_DIRNAME/.."
    mkdir -p "$TEST_DIR/src/beta" && echo b > "$TEST_DIR/src/beta/b.txt"
    for ts in 20261011_020000 20261012_020000 20261013_020000; do
        mkdir -p "$HOST_DIR/$ts"
        tar -cf "$HOST_DIR/$ts/beta.tar" -C "$TEST_DIR/src" beta
    done
}

teardown() {
    rm -rf "${TEST_DIR:?}"
}

_with_status() {
    echo '{"schema": 1}' > "$HOST_DIR/status.json"
    echo '{"schema": 1}' > "$HOST_DIR/20261013_020000/status.json"
}

_restore_steps_1_3() {
    run bash -c 'source "$1"; select_hostname; select_timestamp; select_stack; echo "STACK=$selected_stack"' \
        _ "$SRC/docker-stack-restore.sh" <<< $'1\n1\n1'
}

@test "restore Steps 1-3: identical with status.json present at both levels" {
    _restore_steps_1_3
    [ "$status" -eq 0 ]
    without="$output"
    _with_status
    _restore_steps_1_3
    [ "$status" -eq 0 ]
    [ "$output" = "$without" ]
    [[ "$output" != *status.json* ]]
    [[ "$output" == *"STACK=beta"* ]]
}

@test "verify --list and --stats: identical with status.json present" {
    run bash "$SRC/backup-verify.sh" --list
    [ "$status" -eq 0 ]
    list_without="$output"
    run bash "$SRC/backup-verify.sh" --stats
    [ "$status" -eq 0 ]
    stats_without="$output"
    _with_status
    run bash "$SRC/backup-verify.sh" --list
    [ "$status" -eq 0 ]
    [ "$output" = "$list_without" ] || [ "$(sed 's/[0-9.]*[KMG]\?$//' <<< "$output")" = "$(sed 's/[0-9.]*[KMG]\?$//' <<< "$list_without")" ]
    [[ "$output" != *status.json* ]]
    run bash "$SRC/backup-verify.sh" --stats
    [ "$status" -eq 0 ]
    [[ "$output" == *"Backup sets: 3"* ]]
    [[ "$output" == *"Total backups: 3"* ]]
}

@test "cleanup with KEEP_MIN: status.json is neither a run nor deleted; KEEP_MIN counts the same" {
    _with_status
    touch -d "40 days ago" "$HOST_DIR"/2026101[123]_020000
    run env RETENTION_DAYS=30 SEARCH_DEPTH=2 KEEP_MIN=2 bash "$SRC/cleanup-old-backups.sh" "$BACKUP_BASE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 1"* ]]
    [[ "$output" == *"Kept 2 past retention by KEEP_MIN (2)"* ]]
    [ -f "$HOST_DIR/status.json" ]
    [ -f "$HOST_DIR/20261013_020000/status.json" ]
    [ ! -d "$HOST_DIR/20261011_020000" ]
}
