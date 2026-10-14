#!/usr/bin/env bats
# A backup run must stop and start the stack's existing containers, never recreate
# them (#564/#565/#488). `docker compose down` removed the containers, and the `up -d`
# that followed recreated them from whatever compose file and image were on disk —
# deploying pending changes at 02:00, possibly pulling images, and discarding the
# containers' writable layers. Since 0.5.0: `stop` → archive → `start`, with
# `up -d --no-recreate --pull never` only as a fallback when `start` fails.
#
# Runs against a stub docker (tests/helpers/stub-env.bash); no daemon needed.

load helpers/stub-env

setup() {
    stub_env_setup
}

teardown() {
    stub_env_teardown
}

@test "backup stops with 'compose stop' and restarts with 'compose start <previously running services>'" {
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully backed up: 1"* ]]

    grep -qx "compose stop" "$DOCKER_LOG"
    grep -qx "compose start app worker" "$DOCKER_LOG"
}

@test "backup never calls 'compose down', nor 'compose up' without --no-recreate" {
    run_backup
    [ "$status" -eq 0 ]

    run grep -E '^compose down' "$DOCKER_LOG"
    [ "$status" -ne 0 ]
    run grep -E '^compose up' "$DOCKER_LOG"
    [ "$status" -ne 0 ]
}

@test "only the services that were running are started" {
    printf 'app\n' > "$STATE_FILE"
    run_backup
    [ "$status" -eq 0 ]
    grep -qx "compose start app" "$DOCKER_LOG"
}

@test "when start fails, falls back to 'up -d --no-recreate --pull never --no-build --no-deps' and warns" {
    export STUB_START_RC=1
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"falling back to the deploy path"* ]]
    # --no-build: a build would fetch its base image and apply the working-tree
    # Dockerfile; --no-deps: start only what was running (audit F-02).
    grep -qx "compose up -d --no-recreate --pull never --no-build --no-deps app worker" "$DOCKER_LOG"

    # That is the only `up`, and it carries both guards.
    [ "$(grep -cE '^compose up' "$DOCKER_LOG")" -eq 1 ]
}

@test "the manual-restart hint names 'compose start', not 'compose up'" {
    # start and the fallback up both fail -> retries exhausted.
    cat > "$BIN_DIR/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
[[ "$1" == info ]] && exit 0
case "$2" in
    ps)    cat "$STATE_FILE" ;;
    stop)  : > "$STATE_FILE" ;;
    start) exit 1 ;;
    up)    exit 1 ;;
esac
exit 0
STUB
    run_backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"To restart manually: cd "*"&& docker compose start app"* ]]
    [[ "$output" == *"Failed: 1"* ]]
}

@test "MAX_RESTART_ATTEMPTS and RESTART_RETRY_DELAY are overridable from the environment" {
    export MAX_RESTART_ATTEMPTS=7 RESTART_RETRY_DELAY=11
    source "$BATS_TEST_DIRNAME/../lib.sh"
    [ "$MAX_RESTART_ATTEMPTS" -eq 7 ]
    [ "$RESTART_RETRY_DELAY" -eq 11 ]
}

@test "the run header logs the version" {
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Version: docker-stack-backup 0.5.2"* ]]
}
