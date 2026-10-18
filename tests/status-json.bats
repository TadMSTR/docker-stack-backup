#!/usr/bin/env bats
# status.json (0.6.0): every real run writes a machine-readable record next to the run
# dirs, aborts included; a dry run and the manual script never do. See STATUS.md.

load helpers/stub-env
load helpers/status

setup() {
    stub_env_setup
    status_setup
}

teardown() {
    stub_env_teardown
}

@test "a real run writes status.json next to the run dirs, and a copy in the run dir" {
    run_backup
    [ "$status" -eq 0 ]
    [ -f "$STATUS" ]
    run_id=$(js "$STATUS" 'd["run_id"]' | tr -d '"')
    [ -f "$HOST_DIR/$run_id/status.json" ]
    cmp "$STATUS" "$HOST_DIR/$run_id/status.json"
    [ "$(js "$STATUS" 'd["schema"]')" = 1 ]
    [ "$(js "$STATUS" 'd["tool"]')" = '"docker-stack-backup"' ]
    [ "$(js "$STATUS" 'd["host"]')" = "\"$HOST\"" ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"success"' ]
    [ "$(js "$STATUS" 'd["abort_reason"]')" = null ]
    [ "$(js "$STATUS" 'd["counts"]')" = '{"found": 1, "backed_up": 1, "skipped": 0, "failed": 0}' ]
    [ "$(js "$STATUS" 'd["last_success"] == d["finished"]')" = true ]
    [ "$(js "$STATUS" 'd["duration_s"] == d["finished"] - d["started"]')" = true ]
    [[ "$output" == *"Status written: $STATUS"* ]]
    # No temp files left behind.
    [ -z "$(find "$HOST_DIR" -name '*.tmp.*')" ]
}

@test "per-stack record: result, mode, archive, actual bytes, downtime, last_success, coverage" {
    run_backup
    [ "$status" -eq 0 ]
    run_id=$(js "$STATUS" 'd["run_id"]' | tr -d '"')
    archive="$HOST_DIR/$run_id/$STACK.tar"
    [ "$(js "$STATUS" 'd["stacks"][0]["name"]')" = "\"$STACK\"" ]
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"backed_up"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = null ]
    [ "$(js "$STATUS" 'd["stacks"][0]["mode"]')" = '"running"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["archive"]')" = "\"$run_id/$STACK.tar\"" ]
    [ "$(js "$STATUS" 'd["stacks"][0]["bytes"]')" = "$(stat -c %s "$archive")" ]
    [ "$(js "$STATUS" 'd["bytes_total"]')" = "$(stat -c %s "$archive")" ]
    [ "$(js "$STATUS" 'type(d["stacks"][0]["downtime_s"]) is int and d["stacks"][0]["downtime_s"] >= 0')" = true ]
    [ "$(js "$STATUS" 'd["stacks"][0]["started"] <= d["stacks"][0]["finished"]')" = true ]
    [ "$(js "$STATUS" 'd["stacks"][0]["last_success"] == d["stacks"][0]["finished"]')" = true ]
    [ "$(js "$STATUS" 'd["stack_last_success"]["'"$STACK"'"] == d["stacks"][0]["finished"]')" = true ]
    [ "$(js "$STATUS" 'd["stacks"][0]["coverage"]["status"]')" = '"ok"' ]
    [ "$(js "$STATUS" '[i["class"] for i in d["stacks"][0]["coverage"]["items"]]')" = '["archived"]' ]
}

@test "status.json is 0644 even under umask 077" {
    run bash -c "umask 077; bash '$BATS_TEST_DIRNAME/../docker-stack-backup.sh'"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$STATUS")" = 644 ]
}

@test "a stopped stack: mode stopped, downtime 0" {
    : > "$STATE_FILE"
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["mode"]')" = '"stopped"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["downtime_s"]')" = 0 ]
}

@test "a skipped stack carries its reason; no run dir copy when the run dir was removed" {
    export BACKUP_STOPPED_STACKS=false
    : > "$STATE_FILE"
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"skipped"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"not-running"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["archive"]')" = null ]
    [ "$(js "$STATUS" 'd["stacks"][0]["downtime_s"]')" = null ]
    # The rmdir-if-empty still removes the run dir: status.json is not written into it.
    [ -z "$(find "$HOST_DIR" -mindepth 1 -type d)" ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"success"' ]
}

@test "skipped stacks are still classified (coverage is static)" {
    sed -i "s|$APPDATA_PATH|/elsewhere|" "$DOCKHAND_BASE/$STACK/docker-compose.yml"
    cat > "$STUB_CONFIG_DIR/$STACK.json" <<JSON
{"services": {"app": {"volumes": [{"type": "volume", "source": "pgdata", "target": "/var/lib/postgresql/data"}]}}}
JSON
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"no-appdata-reference"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["coverage"]["status"]')" = '"uncovered"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["coverage"]["items"][0]["class"]')" = '"named-volume"' ]
}

@test "stop-failed: recorded as the reason; the log and notification text keep 0.5.3's wording" {
    export STUB_STOP_RC=1
    run_backup
    [ "$status" -ne 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"failed"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"stop-failed"' ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"failed"' ]
    [[ "$output" == *"Failed stacks: $STACK"$'\n'* || "$output" == *"Failed stacks: $STACK" ]]
    [[ "$output" != *"(stop-failed)"* ]]
}

@test "archive-failed: recorded as the reason, no archive" {
    export STUB_HELPER_FAIL=1
    run_backup
    [ "$status" -ne 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"archive-failed"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["archive"]')" = null ]
    [[ "$output" != *"(archive-failed)"* ]]
}

@test "restart-failed: recorded as the reason, with the archive that was written; no downtime" {
    export STUB_START_RC=1 STUB_UP_RC=1
    run_backup
    [ "$status" -ne 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"restart-failed"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["archive"] is not None')" = true ]
    [ "$(js "$STATUS" 'd["stacks"][0]["downtime_s"]')" = null ]
    [[ "$output" != *"(restart-failed)"* ]]
}

@test "compose-ps-failed keeps its reason in status.json" {
    export STUB_PS_RC=1
    run_backup
    [ "$status" -ne 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"compose-ps-failed"' ]
}

@test "outcome partial: one stack failed, one backed up" {
    add_stack second
    printf 'app\n' > "$STATE_FILE"
    # compose ps fails for the second stack only.
    sed -i 's|^    ps)$|    ps)\n        [[ "$(basename "$PWD")" == second ]] \&\& exit 1|' "$BIN_DIR/docker"
    run_backup
    [ "$status" -ne 0 ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"partial"' ]
    [ "$(js "$STATUS" 'd["counts"]["failed"]')" = 1 ]
    [ "$(js "$STATUS" 'd["counts"]["backed_up"]')" = 1 ]
    [ "$(js "$STATUS" 'd["last_success"]')" = null ]
}

@test "a run with no stacks at all: success with zero counts" {
    rm -rf "${DOCKHAND_BASE:?}/$STACK"
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"success"' ]
    [ "$(js "$STATUS" 'd["counts"]["found"]')" = 0 ]
}

@test "STATUS_ENABLED=false writes nothing" {
    export STATUS_ENABLED=false
    run_backup
    [ "$status" -eq 0 ]
    [ ! -e "$STATUS" ]
    [ -z "$(find "$BACKUP_DEST" -name 'status.json*')" ]
}

@test "STATUS_FILE overrides the location" {
    export STATUS_FILE="$TEST_DIR/elsewhere/st.json"
    run_backup
    [ "$status" -eq 0 ]
    [ -f "$STATUS_FILE" ]
    [ ! -e "$STATUS" ]
}

@test "a status write failure exits non-zero, after the notifications went out" {
    curl_stub
    export NOTIFY_ON_SUCCESS=true NTFY_ENABLED=true NTFY_URL=http://ntfy.invalid
    : > "$TEST_DIR/not-a-dir"
    export STATUS_FILE="$TEST_DIR/not-a-dir/status.json"
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"Successfully backed up: 1"* ]]
    [[ "$output" == *"Could not write the run status"* ]]
    grep -q 'ntfy.invalid' "$CURL_LOG"
}

@test "dry run and the manual script leave an existing status.json byte-identical" {
    run_backup
    [ "$status" -eq 0 ]
    cp -p "$STATUS" "$TEST_DIR/before.json"
    run_backup --dry-run
    [ "$status" -eq 0 ]
    cmp "$STATUS" "$TEST_DIR/before.json"
    run bash -c "printf '1\ny\n' | bash '$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh'"
    cmp "$STATUS" "$TEST_DIR/before.json"
    [ "$(find "$HOST_DIR" -name status.json | wc -l)" -eq 2 ]
}

@test "--coverage-report prints JSON only and writes nothing" {
    run bash -c "bash '$BATS_TEST_DIRNAME/../docker-stack-backup.sh' --coverage-report 2>/dev/null"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["stacks"][0]["name"]=="stubstack"'
    [ ! -e "$STATUS" ]
    [ ! -e "$HOME/logs/docker-backup.log" ] || ! grep -q . "$HOME/logs/docker-backup.log"
    run grep -E '^compose (stop|start|up)' "$DOCKER_LOG"
    [ "$status" -ne 0 ]
}

#######################################
# Abort paths: one EXIT handler writes the status, then releases the lock
#######################################

_assert_aborted() {
    [ "$(js "$STATUS" 'd["outcome"]')" = '"aborted"' ]
    [ "$(js "$STATUS" 'd["abort_reason"]')" = "\"$1\"" ]
    [ "$(js "$STATUS" 'd["stacks"]')" = '[]' ]
    [[ "$output" == *"Lock released"* ]]
}

@test "abort: not privileged" {
    export ELEVATION_CMD=none
    if [[ $EUID -eq 0 ]]; then skip "runs as root"; fi
    mkdir -p "$HOST_DIR"
    run_backup
    [ "$status" -eq 1 ]
    _assert_aborted not-privileged
}

@test "abort: invalid numeric config" {
    export MIN_FREE_GB=5G
    mkdir -p "$HOST_DIR"
    run_backup
    [ "$status" -eq 1 ]
    _assert_aborted invalid-config
}

@test "lock held by another run: its lock file, status.json and ping are left alone (CR-02, #1158)" {
    mkdir -p "$HOST_DIR" "$(dirname "$LOCK_FILE")"
    echo '{"the running run": "wrote this"}' > "$STATUS"
    cp "$STATUS" "$TEST_DIR/before.json"
    curl_stub
    export PING_URL="https://hc.example/ping/k"
    exec 9>"$LOCK_FILE"
    flock 9
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"Another backup is already running"* ]]
    [[ "$output" == *"Another run holds the lock: its status.json, .prom and ping are left alone"* ]]
    [[ "$output" != *"Lock released"* ]]
    # The holder's lock file still exists (it used to be deleted), so a third run is
    # still refused.
    [ -e "$LOCK_FILE" ]
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"Another backup is already running"* ]]
    exec 9>&-
    cmp "$STATUS" "$TEST_DIR/before.json"
    ! grep -q '^CONFIG: url' "$CURL_LOG"
}

@test "an abort before the lock does not touch status while another run holds the lock" {
    mkdir -p "$HOST_DIR" "$(dirname "$LOCK_FILE")"
    echo '{"the running run": "wrote this"}' > "$STATUS"
    cp "$STATUS" "$TEST_DIR/before.json"
    export MIN_FREE_GB=5G
    exec 9>"$LOCK_FILE"
    flock 9
    run_backup
    exec 9>&-
    [ "$status" -eq 1 ]
    cmp "$STATUS" "$TEST_DIR/before.json"
    [ -e "$LOCK_FILE" ]
}

@test "release_lock only acts for the lock holder" {
    run bash -c 'LOG_FILE=/dev/null; source "$1"; LOCK_FILE="$2"; LOCK_FD=200; : > "$LOCK_FILE"; release_lock; [ -e "$LOCK_FILE" ]' \
        _ "$BATS_TEST_DIRNAME/../lib.sh" "$TEST_DIR/some.lock"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Lock released"* ]]
}

@test "abort: preflight failed; the lock is released (lock file removed)" {
    mkdir -p "$HOST_DIR"
    rm -rf "${APPDATA_PATH:?}"
    run_backup
    [ "$status" -eq 1 ]
    _assert_aborted preflight-failed
    [ ! -e "$LOCK_FILE" ]
}

@test "abort keeps the previous last_success and every stack's carried history" {
    run_backup
    [ "$status" -eq 0 ]
    prev=$(js "$STATUS" 'd["last_success"]')
    prev_stack=$(js "$STATUS" 'd["stack_last_success"]')
    export MIN_FREE_GB=5G
    run_backup
    [ "$status" -eq 1 ]
    [ "$(js "$STATUS" 'd["last_success"]')" = "$prev" ]
    [ "$(js "$STATUS" 'd["stack_last_success"]')" = "$prev_stack" ]
}

@test "TERM while a stack is stopped: that stack is started again, the loop stops, status says interrupted (CR-01)" {
    add_stack second   # "second" sorts before "stubstack": it is the stack in flight
    export STUB_SIGNAL_ON_STOP=TERM
    run_backup
    [ "$status" -eq 143 ]
    [[ "$output" == *"Signal received: finishing the current stack"* ]]
    [[ "$output" == *"Stopping after second on a signal"* ]]
    # second was stopped, archived and started again; stubstack was never touched.
    grep -q '^compose stop' "$DOCKER_LOG"
    grep -q '^compose start' "$DOCKER_LOG"
    [ "$(grep -c '^compose stop' "$DOCKER_LOG")" -eq 1 ]
    [ -s "$STATE_FILE" ]
    [ -n "$(find "$BACKUP_DEST" -name 'second.tar')" ]
    [ -z "$(find "$BACKUP_DEST" -name "$STACK.tar")" ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"aborted"' ]
    [ "$(js "$STATUS" 'd["abort_reason"]')" = '"interrupted"' ]
    [ "$(js "$STATUS" '[(s["name"], s["result"]) for s in d["stacks"]]')" = '[["second", "backed_up"]]' ]
    [[ "$output" == *"Lock released"* ]]
    [ ! -e "$LOCK_FILE" ]
}

@test "TERM from a post-restart hook: same handler (interrupted, lock released)" {
    cat > "$TEST_DIR/killer" <<'EOF'
#!/usr/bin/env bash
kill -TERM "$PPID"
EOF
    chmod +x "$TEST_DIR/killer"
    cat > "$HOME/hooks.sh" <<EOF
POST_RESTART_HOOKS=("$TEST_DIR/killer")
EOF
    cp "$BATS_TEST_DIRNAME/../docker-stack-backup.sh" "$BATS_TEST_DIRNAME/../lib.sh" \
       "$BATS_TEST_DIRNAME/../dsb_status.py" "$TEST_DIR/"
    cp "$HOME/hooks.sh" "$TEST_DIR/config.sh"
    run bash "$TEST_DIR/docker-stack-backup.sh"
    [ "$status" -eq 143 ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"aborted"' ]
    [ "$(js "$STATUS" 'd["abort_reason"]')" = '"interrupted"' ]
    # The hook ran inside the stack, so the stack finished and was recorded.
    [ "$(js "$STATUS" '[s["result"] for s in d["stacks"]]')" = '["backed_up"]' ]
    [[ "$output" == *"Lock released"* ]]
    [[ "$output" != *"Backup Summary"* ]]
    [ ! -e "$LOCK_FILE" ]
}

@test "only one EXIT trap is installed, and it is the status-writing handler" {
    run bash -c "grep -nE '^[[:space:]]*trap [^-].* EXIT' '$BATS_TEST_DIRNAME/../docker-stack-backup.sh'"
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == *"trap on_exit EXIT"* ]]
}
