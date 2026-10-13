#!/usr/bin/env bats
# A stack with appdata but no running containers used to return 0 from backup_stack()
# without archiving anything, so the run reported it as "Successfully backed up".
# Since 0.5.0:
#   BACKUP_STOPPED_STACKS=true  (default) — archived as-is, nothing stopped or started,
#                                           counted as backed up and listed "(stopped)".
#   BACKUP_STOPPED_STACKS=false — skipped with reason not-running, never counted as
#                                 backed up.
# An empty or missing appdata dir is skipped with a reason, too.

load helpers/stub-env

setup() {
    stub_env_setup
    : > "$STATE_FILE"   # nothing running
}

teardown() {
    stub_env_teardown
}

@test "BACKUP_STOPPED_STACKS=true: stopped stack is archived without stop/start" {
    export BACKUP_STOPPED_STACKS=true
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully backed up: 1"* ]]
    [[ "$output" == *"Backed up while stopped: $STACK (stopped)"* ]]

    archive="$(find "$BACKUP_DEST" -name "$STACK.tar")"
    [ -n "$archive" ]
    tar -tf "$archive" | grep -q "$STACK/data.txt"

    run grep -E '^compose (stop|start|up|down)' "$DOCKER_LOG"
    [ "$status" -ne 0 ]
}

@test "BACKUP_STOPPED_STACKS defaults to true" {
    unset BACKUP_STOPPED_STACKS
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully backed up: 1"* ]]
}

@test "BACKUP_STOPPED_STACKS=false: skipped with reason not-running, not counted as backed up" {
    export BACKUP_STOPPED_STACKS=false
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully backed up: 0"* ]]
    [[ "$output" == *"Skipped stacks: $STACK (not-running)"* ]]
    [ -z "$(find "$BACKUP_DEST" -name '*.tar*')" ]
    # The run's timestamp dir is removed when nothing was archived into it.
    [ -z "$(find "$BACKUP_DEST" -mindepth 2 -type d)" ]
}

@test "missing appdata dir is skipped with reason appdata-missing" {
    mv "$APPDATA_PATH/$STACK" "$TEST_DIR/moved-away"
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully backed up: 0"* ]]
    [[ "$output" == *"Skipped stacks: $STACK (appdata-missing)"* ]]
}

@test "empty appdata dir is skipped with reason appdata-empty (run and --dry-run)" {
    # appdata_has_content() only inspects the dir when ELEVATION_CMD=none, and that
    # mode requires root. A user namespace gives EUID 0 without real privilege.
    if ! unshare -r true 2>/dev/null; then
        skip "unprivileged user namespaces unavailable (unshare -r)"
    fi
    export ELEVATION_CMD=none
    mv "$APPDATA_PATH/$STACK/data.txt" "$TEST_DIR/"

    run unshare -r bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully backed up: 0"* ]]
    [[ "$output" == *"Skipped stacks: $STACK (appdata-empty)"* ]]

    run unshare -r bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"$STACK (appdata-empty)"* ]]
}

@test "--dry-run lists a stopped stack as skipped (not-running) when BACKUP_STOPPED_STACKS=false" {
    export BACKUP_STOPPED_STACKS=false
    run_backup --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would skip:"* ]]
    [[ "$output" == *"$STACK (not-running)"* ]]
}

@test "--dry-run lists a stopped stack as backed up when BACKUP_STOPPED_STACKS=true" {
    export BACKUP_STOPPED_STACKS=true
    run_backup --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"$STACK ("*"stopped"* ]]
    [[ "$output" != *"$STACK (not-running)"* ]]
}
