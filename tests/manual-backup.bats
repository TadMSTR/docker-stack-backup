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

@test "summary survives appdata the user can't fully read, and labels the size an estimate (#1092)" {
    [[ $EUID -eq 0 ]] && skip "root reads everything; needs an unprivileged user"
    mkdir -p "$APPDATA_PATH/$STACK/private"
    echo secret > "$APPDATA_PATH/$STACK/private/key"
    chmod 000 "$APPDATA_PATH/$STACK/private"
    run bash -c "printf '1\nn\n' | bash '$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh'"
    chmod 700 "$APPDATA_PATH/$STACK/private"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Appdata: "*"(estimate — unreadable paths excluded)"* ]]
    [[ "$output" == *"Proceed with backup?"* ]]
    [[ "$output" == *"Backup cancelled."* ]]
}

@test "a stack whose compose ps fails shows 'state unknown', never 'stopped' (#1090 R2-01)" {
    export STUB_PS_RC=1
    run bash -c "printf '1\nn\n' | bash '$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$STACK"*"state unknown"* ]]
    [[ "$output" == *"Status: "*"state unknown"* ]]
    [[ "$output" != *"All containers stopped"* ]]
    ! grep -q "$STACK.*(appdata: .*stopped" <<< "$output" || false
    [[ "$output" == *"Backup cancelled."* ]]
}

@test "dry run: a stack whose compose ps fails shows 'state unknown — would fail'" {
    export STUB_PS_RC=1
    run bash -c "printf '1\ny\n' | bash '$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh' --dry-run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$STACK"*"state unknown — would fail"* ]]
    [[ "$output" != *"$STACK ("*", stopped)"* ]]
    # Counted as a would-fail, not as backed up (CR-01).
    [[ "$output" == *"Would backup: "*"0"* ]]
    [[ "$output" == *"Would fail: "*"1"* ]]
    [[ "$output" == *"0 stacks would be backed up, 1 would fail"* ]]
}
