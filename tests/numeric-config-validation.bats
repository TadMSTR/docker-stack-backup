#!/usr/bin/env bats
# Audit F-03 / CodeRabbit CR-02 and CR-01 (docker-stack-backup-2026-10-p1-correctness):
# numeric settings that reach bash arithmetic must be validated and normalised, or a
# typo silently disables the check they configure.
#   MIN_FREE_GB=5G or an overflowing value made the free-space preflight pass.
#   KEEP_MIN=08 passed `^[0-9]+$`, then failed `-gt` as invalid octal: the floor was
#   disabled and every expired run dir deleted. KEEP_MIN=010 kept 8, not 10.

load helpers/stub-env

setup() {
    stub_env_setup
}

teardown() {
    stub_env_teardown
}

# --- backup scripts --------------------------------------------------------

@test "MIN_FREE_GB=5G is rejected before anything runs" {
    export MIN_FREE_GB=5G
    run_backup --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIN_FREE_GB must be a non-negative integer"* ]]
    [[ "$output" != *"Disk space:"* ]]
}

@test "an overflowing MIN_FREE_GB is rejected" {
    export MIN_FREE_GB=99999999999999999999
    run_backup --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIN_FREE_GB must be"* ]]
}

@test "MIN_FREE_GB above the bound is rejected" {
    export MIN_FREE_GB=99999999
    run_backup --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIN_FREE_GB must be between 0 and 1048576"* ]]
}

@test "MIN_FREE_GB=08 is read as 8 (decimal), not rejected as octal" {
    export MIN_FREE_GB=08
    run_backup --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"(required: 8GB)"* ]]
}

@test "MAX_RESTART_ATTEMPTS=0 and a non-numeric RESTART_RETRY_DELAY are rejected" {
    export MAX_RESTART_ATTEMPTS=0 RESTART_RETRY_DELAY=5s
    run_backup --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"MAX_RESTART_ATTEMPTS must be between 1 and 100"* ]]
    [[ "$output" == *"RESTART_RETRY_DELAY must be a non-negative integer"* ]]
}

@test "the manual script validates the same settings" {
    export MIN_FREE_GB=5G
    run bash -c "printf '1\ny\n' | bash '$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIN_FREE_GB must be a non-negative integer"* ]]
}

@test "validate_uint normalises leading zeros in place" {
    source "$BATS_TEST_DIRNAME/../lib.sh"
    export LOG_FILE="$TEST_DIR/t.log"
    FOO=010
    validate_uint FOO 0 100
    [ "$FOO" = "10" ]
}

# --- cleanup-old-backups.sh ------------------------------------------------

_cleanup() {
    run env BACKUP_BASE="$TEST_DIR/cb" LOG_FILE="$TEST_DIR/cleanup.log" RETENTION_DAYS=30 \
        bash "$BATS_TEST_DIRNAME/../cleanup-old-backups.sh"
}

_run_dirs() {
    local age
    for age in $(seq 31 "$1"); do
        mkdir -p "$TEST_DIR/cb/host1/run-$age"
        echo data > "$TEST_DIR/cb/host1/run-$age/stack.tar"
        touch -d "$age days ago" "$TEST_DIR/cb/host1/run-$age"
    done
}

@test "cleanup: KEEP_MIN=08 keeps 8 (was: floor disabled, everything deleted)" {
    _run_dirs 42
    export KEEP_MIN=08
    _cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Kept 8 past retention by KEEP_MIN (8)"* ]]
    [ "$(find "$TEST_DIR/cb/host1" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 8 ]
}

@test "cleanup: KEEP_MIN=010 keeps 10, not 8" {
    _run_dirs 42
    export KEEP_MIN=010
    _cleanup
    [ "$status" -eq 0 ]
    [ "$(find "$TEST_DIR/cb/host1" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 10 ]
}

@test "cleanup: invalid SEARCH_DEPTH or RETENTION_DAYS is rejected before anything is deleted" {
    _run_dirs 35
    export SEARCH_DEPTH=0
    _cleanup
    [ "$status" -ne 0 ]
    [[ "$output" == *"SEARCH_DEPTH must be between 1 and 10"* ]]
    [ -d "$TEST_DIR/cb/host1/run-35" ]

    export SEARCH_DEPTH=2 RETENTION_DAYS=abc
    run env BACKUP_BASE="$TEST_DIR/cb" LOG_FILE="$TEST_DIR/cleanup.log" \
        bash "$BATS_TEST_DIRNAME/../cleanup-old-backups.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"RETENTION_DAYS must be a non-negative integer"* ]]
    [ -d "$TEST_DIR/cb/host1/run-35" ]
}
