#!/usr/bin/env bats
# Audit F-01 (docker-stack-backup-2026-10-p1-correctness): `docker compose ps` failing
# (YAML error, unset ${VAR:?} in cron's environment) printed nothing, the failure was
# swallowed, and the empty list sent a RUNNING stack down the stopped-stack branch: its
# live appdata was archived without stopping it and reported as a successful
# "(stopped)" backup. An undeterminable running state must fail the stack instead.

load helpers/stub-env

setup() {
    stub_env_setup
}

teardown() {
    stub_env_teardown
}

@test "compose ps failure: stack is failed (compose-ps-failed), not archived, not stopped" {
    export STUB_PS_RC=1
    run_backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"Successfully backed up: 0"* ]]
    [[ "$output" == *"Failed: 1"* ]]
    [[ "$output" == *"Failed stacks: $STACK (compose-ps-failed)"* ]]
    [[ "$output" != *"(stopped)"* ]]
    [ -z "$(find "$BACKUP_DEST" \( -name '*.tar*' -o -name '*.incomplete' \))" ]
    run grep -E '^compose (stop|start|up|down)' "$DOCKER_LOG"
    [ "$status" -ne 0 ]
}

@test "compose says nothing runs but docker sees the stack's containers: failed (running-state-mismatch)" {
    : > "$STATE_FILE"
    export STUB_LIVE="0123456789ab"
    run_backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed stacks: $STACK (running-state-mismatch)"* ]]
    [ -z "$(find "$BACKUP_DEST" -name '*.tar*')" ]
}

@test "the cross-check queries docker ps by the stack dir's compose working_dir label" {
    : > "$STATE_FILE"
    run_backup
    [ "$status" -eq 0 ]
    grep -qF "ps -q --filter label=com.docker.compose.project.working_dir=$DOCKHAND_BASE/$STACK --filter status=running" "$DOCKER_LOG"
}

@test "genuinely stopped (compose and docker agree): still archived as-is" {
    : > "$STATE_FILE"
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Backed up while stopped: $STACK (stopped)"* ]]
}

@test "--dry-run lists a compose-ps failure under 'Would fail', not as stopped" {
    export STUB_PS_RC=1
    run_backup --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would fail:"* ]]
    [[ "$output" == *"$STACK (compose-ps-failed)"* ]]
    [[ "$output" != *"archived without stop/start"* ]]
}

@test "manual script: compose ps failure fails the stack and archives nothing" {
    export STUB_PS_RC=1
    run bash -c "printf '1\ny\n' | bash '$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot determine running state of $STACK"* ]]
    [ -z "$(find "$BACKUP_DEST" -name '*.tar*')" ]
}
