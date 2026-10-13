#!/usr/bin/env bats
# cleanup-old-backups.sh used to delete every run dir older than RETENTION_DAYS and
# keep no minimum, so 30 days without a successful backup meant the next cleanup
# deleted every backup. Since 0.5.0, the KEEP_MIN (default 7) newest run dirs per
# parent that hold a completed archive are always kept.

SCRIPT="$BATS_TEST_DIRNAME/../cleanup-old-backups.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    export BACKUP_BASE="$TEST_DIR/backups"
    export LOG_FILE="$TEST_DIR/cleanup.log"
    export RETENTION_DAYS=30
    export SEARCH_DEPTH=2
    unset KEEP_MIN
    mkdir -p "$BACKUP_BASE"
}

teardown() {
    rm -rf "${TEST_DIR:?}"
}

# _run_dir <path> <age-days> [with-archive: 1|0]
_run_dir() {
    local path="$1" age="$2" with_archive="${3:-1}"
    mkdir -p "$path"
    if [[ "$with_archive" == 1 ]]; then echo data > "$path/stack.tar"; fi
    touch -d "${age} days ago" "$path"
}

@test "40 run dirs all past retention: the 7 newest are kept" {
    for age in $(seq 31 70); do
        _run_dir "$BACKUP_BASE/host1/run-$age" "$age"
    done
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 33"* ]]
    [[ "$output" == *"Kept 7 past retention by KEEP_MIN (7)"* ]]
    for age in $(seq 31 37); do [ -d "$BACKUP_BASE/host1/run-$age" ]; done
    for age in $(seq 38 70); do [ ! -d "$BACKUP_BASE/host1/run-$age" ]; done
}

@test "old empty or failed-run dirs do not use up a KEEP_MIN slot" {
    for age in $(seq 33 42); do
        _run_dir "$BACKUP_BASE/host1/run-$age" "$age"
    done
    # Newer than every archive dir, but with no completed archive: must not be kept.
    _run_dir "$BACKUP_BASE/host1/empty-a" 31 0
    _run_dir "$BACKUP_BASE/host1/empty-b" 32 0
    mkdir -p "$BACKUP_BASE/host1/failed"
    echo x > "$BACKUP_BASE/host1/failed/stack.incomplete"
    touch -d "31 days ago" "$BACKUP_BASE/host1/failed"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Kept 7 past retention by KEEP_MIN (7)"* ]]
    for age in $(seq 33 39); do [ -d "$BACKUP_BASE/host1/run-$age" ]; done
    for age in $(seq 40 42); do [ ! -d "$BACKUP_BASE/host1/run-$age" ]; done
    [ ! -d "$BACKUP_BASE/host1/empty-a" ]
    [ ! -d "$BACKUP_BASE/host1/empty-b" ]
    [ ! -d "$BACKUP_BASE/host1/failed" ]
}

@test "compressed archives (*.tar.*) count as completed" {
    for age in $(seq 31 35); do
        mkdir -p "$BACKUP_BASE/host1/run-$age"
        echo data > "$BACKUP_BASE/host1/run-$age/stack.tar.zst"
        touch -d "$age days ago" "$BACKUP_BASE/host1/run-$age"
    done
    export KEEP_MIN=2
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -d "$BACKUP_BASE/host1/run-31" ]
    [ -d "$BACKUP_BASE/host1/run-32" ]
    [ ! -d "$BACKUP_BASE/host1/run-33" ]
}

@test "recent run dirs count toward KEEP_MIN, so old ones are not kept needlessly" {
    for age in 1 2 3 4 5 6 7; do _run_dir "$BACKUP_BASE/host1/new-$age" "$age"; done
    _run_dir "$BACKUP_BASE/host1/old" 40
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 1"* ]]
    [ ! -d "$BACKUP_BASE/host1/old" ]
}

@test "KEEP_MIN applies per host (per parent dir)" {
    for age in $(seq 31 40); do
        _run_dir "$BACKUP_BASE/host1/run-$age" "$age"
        _run_dir "$BACKUP_BASE/host2/run-$age" "$age"
    done
    export KEEP_MIN=2
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Kept 4 past retention by KEEP_MIN (2)"* ]]
    for h in host1 host2; do
        [ -d "$BACKUP_BASE/$h/run-31" ]
        [ -d "$BACKUP_BASE/$h/run-32" ]
        [ ! -d "$BACKUP_BASE/$h/run-33" ]
    done
}

@test "SEARCH_DEPTH=1: KEEP_MIN groups under BACKUP_BASE itself" {
    export SEARCH_DEPTH=1 KEEP_MIN=3
    for age in $(seq 31 36); do _run_dir "$BACKUP_BASE/run-$age" "$age"; done
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    for age in 31 32 33; do [ -d "$BACKUP_BASE/run-$age" ]; done
    for age in 34 35 36; do [ ! -d "$BACKUP_BASE/run-$age" ]; done
}

@test "KEEP_MIN=0 disables the floor (pre-0.5.0 behaviour)" {
    export KEEP_MIN=0
    for age in $(seq 31 35); do _run_dir "$BACKUP_BASE/host1/run-$age" "$age"; done
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 5"* ]]
}

@test "a non-numeric KEEP_MIN is rejected before anything is deleted" {
    export KEEP_MIN=abc
    _run_dir "$BACKUP_BASE/host1/run-40" 40
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"KEEP_MIN must be a non-negative integer"* ]]
    [ -d "$BACKUP_BASE/host1/run-40" ]
}

@test "paths containing spaces are handled" {
    for age in $(seq 31 39); do _run_dir "$BACKUP_BASE/host one/run $age" "$age"; done
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -d "$BACKUP_BASE/host one/run 31" ]
    [ -d "$BACKUP_BASE/host one/run 37" ]
    [ ! -d "$BACKUP_BASE/host one/run 38" ]
}
