#!/usr/bin/env bats
# docker-stack-backup-manual.sh: same stop/start contract as the automated script, and
# it must get past the summary step. Before 0.5.0 its `((n++))` counters returned 1 when
# n was 0, and `set -e` aborted the script at the first stack with appdata.

load helpers/stub-env

setup() {
    stub_env_setup
}

teardown() {
    stub_env_teardown
}

_run_manual() {
    # Select stack 1, confirm.
    run bash -c "printf '1\ny\n' | bash '$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh'"
}

@test "manual backup completes, using stop/start and never down/up" {
    _run_manual
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully backed up: "*"1"* ]]
    grep -qx "compose stop" "$DOCKER_LOG"
    grep -qx "compose start app worker" "$DOCKER_LOG"
    run grep -E '^compose (down|up)' "$DOCKER_LOG"
    [ "$status" -ne 0 ]
    [ -n "$(find "$BACKUP_DEST" -name "$STACK.tar")" ]
}

@test "manual backup skips a stopped stack with reason not-running when BACKUP_STOPPED_STACKS=false" {
    : > "$STATE_FILE"
    export BACKUP_STOPPED_STACKS=false
    _run_manual
    [ "$status" -eq 0 ]
    [[ "$output" == *"$STACK (not-running)"* ]]
    [ -z "$(find "$BACKUP_DEST" -name '*.tar*')" ]
}
