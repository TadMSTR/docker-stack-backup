#!/usr/bin/env bats
# PING_URL (0.6.0): Healthchecks-style liveness ping — /start before the loop, the bare
# URL on success, /fail on partial/failed/aborted. The URL may carry a secret ping key:
# it goes to curl through -K on a file descriptor (never argv, so `ps` never shows it)
# and it is never logged. A ping error never fails the run.

load helpers/stub-env
load helpers/status

setup() {
    stub_env_setup
    status_setup
    curl_stub
    export PING_URL="https://hc.example/ping/SECRET-KEY-123"
    LOG="$HOME/logs/docker-backup.log"
}

teardown() {
    stub_env_teardown
}

_pings() { grep '^CONFIG: url' "$CURL_LOG" | sed 's/^CONFIG: //'; }

@test "success: /start, then the bare URL" {
    run_backup
    [ "$status" -eq 0 ]
    [ "$(_pings)" = $'url = "https://hc.example/ping/SECRET-KEY-123/start"\nurl = "https://hc.example/ping/SECRET-KEY-123"' ]
}

@test "a failed stack: /start, then /fail" {
    export STUB_PS_RC=1
    run_backup
    [ "$status" -eq 1 ]
    [ "$(_pings | tail -1)" = 'url = "https://hc.example/ping/SECRET-KEY-123/fail"' ]
}

@test "an aborted run pings /fail" {
    export MIN_FREE_GB=x
    run_backup
    [ "$status" -eq 1 ]
    [ "$(_pings)" = 'url = "https://hc.example/ping/SECRET-KEY-123/fail"' ]
}

@test "the URL is never on curl's argv and never in the log or output" {
    run_backup
    [ "$status" -eq 0 ]
    ! grep '^ARGV:' "$CURL_LOG" | grep -q SECRET-KEY || false
    grep '^ARGV:' "$CURL_LOG" | grep -q -- '-K'
    ! grep -q SECRET-KEY "$LOG" || false
    [[ "$output" != *SECRET-KEY* ]]
}

@test "a ping failure is a warning, never a failed run" {
    export STUB_CURL_RC=7
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Liveness ping failed (start)"* ]]
    [[ "$output" == *"Liveness ping failed (success)"* ]]
}

@test "quotes and backslashes in the URL cannot inject curl config" {
    export PING_URL='https://hc.example/p"
output = "/tmp/x'
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"PING_URL is not an http(s) URL; liveness ping skipped"* ]]
    export PING_URL='https://hc.example/a"b\c'
    run_backup
    [ "$(_pings | tail -1)" = 'url = "https://hc.example/a\"b\\c"' ]
}

@test "dry run never pings; PING_URL unset never calls curl" {
    run_backup --dry-run
    [ ! -s "$CURL_LOG" ]
    unset PING_URL
    run_backup
    [ ! -s "$CURL_LOG" ]
}

@test "a status write failure pings /fail, not success: the record the alerts read is stale" {
    : > "$TEST_DIR/not-a-dir"
    export STATUS_FILE="$TEST_DIR/not-a-dir/status.json"
    run_backup
    [ "$status" -eq 1 ]
    [ "$(_pings | tail -1)" = 'url = "https://hc.example/ping/SECRET-KEY-123/fail"' ]
}
