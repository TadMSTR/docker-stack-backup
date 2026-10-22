#!/usr/bin/env bats
# x-backup (0.7.0): the per-stack tier block is read from `docker compose config --format
# json` (never parsed as YAML here) and validated by dsb_status.py. A declaration may
# only narrow a backup, and an invalid one narrows nothing: every error below must print
# no path to exclude, so the stack is backed up in full.

load helpers/stub-env
load helpers/status
load helpers/xbackup

setup() {
    stub_env_setup
    status_setup
    mkdir -p "$APPDATA_PATH/$STACK/models/blobs" "$APPDATA_PATH/$STACK/idx"
}

teardown() {
    stub_env_teardown
}

# The block is rejected: config-error, errors listed, nothing excluded.
assert_rejected() {
    [ "$status" -eq 0 ]
    [ -z "$XB_PATHS" ]
    [ "$(xb 'd["status"]')" = '"config-error"' ]
    [ "$(xb 'len(d["errors"]) > 0')" = true ]
    [ "$(xb 'd["excluded"]')" = '[]' ]
}

@test "no x-backup block: status none, nothing excluded" {
    xb_config
    xb_read
    [ "$status" -eq 0 ]
    [ -z "$XB_PATHS" ]
    [ "$(xb 'd["status"]')" = '"none"' ]
    [ "$(xb 'd["run_kind"]')" = '"daily"' ]
}

@test "valid block, daily run: exclude tier excluded, weekly tier deferred, retention kept" {
    xb_config '{"exclude": [{"path": "models/blobs", "reason": "re-pull"}],
                "weekly": [{"path": "idx", "reason": "rebuilt by reindex"}],
                "retention": {"daily": 7, "weekly": 4, "monthly": 6}}'
    xb_read daily
    [ "$status" -eq 0 ]
    [ "$XB_PATHS" = "$(printf 'models/blobs\nidx')" ]
    [ "$(xb 'd["status"]')" = '"ok"' ]
    [ "$(xb '[(e["path"], e["tier"], e["action"], e["exists"]) for e in d["excluded"]]')" = \
      '[["models/blobs", "exclude", "excluded", true], ["idx", "weekly", "deferred", true]]' ]
    [ "$(xb 'd["excluded"][0]["reason"]')" = '"re-pull"' ]
    [ "$(xb 'd["retention"]')" = '{"daily": 7, "weekly": 4, "monthly": 6}' ]
    [ "$(xb 'd["stale"]')" = '[]' ]
}

@test "full run: the weekly tier is backed up, only the exclude tier is left out" {
    xb_config '{"exclude": [{"path": "models/blobs", "reason": "re-pull"}],
                "weekly": [{"path": "idx", "reason": "rebuilt"}]}'
    xb_read full
    [ "$XB_PATHS" = "models/blobs" ]
    [ "$(xb 'd["run_kind"]')" = '"full"' ]
    [ "$(xb '[e["path"] for e in d["excluded"]]')" = '["models/blobs"]' ]
}

@test "a declared path that does not exist is stale: reported, still excluded, not an error" {
    xb_config '{"exclude": [{"path": "gone/away", "reason": "old"}]}'
    xb_read
    [ "$XB_PATHS" = "gone/away" ]
    [ "$(xb 'd["status"]')" = '"ok"' ]
    [ "$(xb 'd["stale"]')" = '["gone/away"]' ]
    [ "$(xb 'd["excluded"][0]["exists"]')" = false ]
}

@test "compose config fails: status unknown, nothing excluded" {
    rm -f "$STUB_CONFIG_DIR/$STACK.json"
    xb_read
    [ "$status" -eq 0 ]
    [ -z "$XB_PATHS" ]
    [ "$(xb 'd["status"]')" = '"unknown"' ]
}

@test "empty lists are valid and exclude nothing" {
    xb_config '{"exclude": [], "weekly": []}'
    xb_read
    [ -z "$XB_PATHS" ]
    [ "$(xb 'd["status"]')" = '"ok"' ]
}

@test "invalid shapes: block, lists, entries and types" {
    local bad
    for bad in '"a string"' '[]' 'null' \
        '{"exclude": null}' '{"exclude": "models/blobs"}' '{"exclude": {"path": "a", "reason": "r"}}' \
        '{"exclude": ["models/blobs"]}' '{"exclude": [{"path": "a"}]}' '{"exclude": [{"reason": "r"}]}' \
        '{"exclude": [{"path": 5, "reason": "r"}]}' '{"exclude": [{"path": "a", "reason": 5}]}' \
        '{"exclude": [{"path": ["a"], "reason": "r"}]}' '{"exclude": [{"path": "a", "reason": ""}]}' \
        '{"exclude": [{"path": "a", "reason": "   "}]}' \
        '{"retention": 7}' '{"retention": {"daily": "7"}}' '{"retention": {"daily": true}}' \
        '{"retention": {"daily": -1}}' '{"retention": {"daily": 1001}}' '{"retention": {"daily": 1.5}}'; do
        xb_config "$bad"
        xb_read
        echo "case: $bad" >&2
        assert_rejected
    done
}

@test "unknown keys at any level are an error" {
    local bad
    for bad in '{"exclud": []}' '{"exclude": [{"path": "a", "reason": "r", "tier": "x"}]}' \
        '{"retention": {"yearly": 1}}'; do
        xb_config "$bad"
        xb_read
        echo "case: $bad" >&2
        assert_rejected
    done
}

@test "traversal, absolute, option-like, glob and control-character paths are refused" {
    local p
    for p in '..' '.' 'a/../b' 'a/./b' '../etc' '/abs' '/etc/passwd' '-x' 'a/-x' \
        '*' 'models/*' 'a?b' '[ab]' 'a b' 'a//b' 'a/' '' 'a\\b' 'a\u0000b' 'a\nb' 'a\u001bb' \
        'café' '~/x' '$HOME'; do
        xb_config "{\"exclude\": [{\"path\": \"$p\", \"reason\": \"r\"}]}"
        xb_read
        echo "case: $p" >&2
        assert_rejected
    done
}

@test "length and count limits: 255-byte paths, 200-char reasons, 64 entries" {
    local long; long=$(printf 'a%.0s' {1..255})
    xb_config "{\"exclude\": [{\"path\": \"$long\", \"reason\": \"r\"}]}"
    xb_read
    [ "$(xb 'd["status"]')" = '"ok"' ]
    xb_config "{\"exclude\": [{\"path\": \"${long}b\", \"reason\": \"r\"}]}"
    xb_read
    assert_rejected

    local reason; reason=$(printf 'r%.0s' {1..200})
    xb_config "{\"exclude\": [{\"path\": \"a\", \"reason\": \"$reason\"}]}"
    xb_read
    [ "$(xb 'd["status"]')" = '"ok"' ]
    xb_config "{\"exclude\": [{\"path\": \"a\", \"reason\": \"${reason}r\"}]}"
    xb_read
    assert_rejected

    local entries="" i
    for i in $(seq 1 64); do entries+="${entries:+,}{\"path\": \"p$i\", \"reason\": \"r\"}"; done
    xb_config "{\"exclude\": [$entries]}"
    xb_read
    [ "$(xb 'd["status"]')" = '"ok"' ]
    xb_config "{\"exclude\": [$entries, {\"path\": \"p65\", \"reason\": \"r\"}]}"
    xb_read
    assert_rejected
}

@test "a control character in a reason is refused; the value never reaches the error text" {
    xb_config '{"exclude": [{"path": "a", "reason": "line1\nFORGED [SUCCESS]"}]}'
    xb_read
    assert_rejected
    [[ "$(cat "$XB_OUT")" != *FORGED* ]]
}

@test "the same path in both tiers is an error (ambiguous)" {
    xb_config '{"exclude": [{"path": "idx", "reason": "r"}], "weekly": [{"path": "idx", "reason": "r"}]}'
    xb_read
    assert_rejected
}

@test "one bad entry voids the whole block: the valid entries are not applied either" {
    xb_config '{"exclude": [{"path": "models/blobs", "reason": "ok"}, {"path": "../x", "reason": "bad"}]}'
    xb_read
    assert_rejected
}

# ---------------------------------------------------------------------------
# End to end: the backup run
# ---------------------------------------------------------------------------

@test "an invalid block: the stack is backed up in full and coverage says config-error" {
    xb_config '{"exclude": [{"path": "../../etc", "reason": "nope"}]}'
    echo blob > "$APPDATA_PATH/$STACK/models/blobs/b"
    export PROM_TEXTFILE_DIR="$TEST_DIR/prom"; mkdir -p "$PROM_TEXTFILE_DIR"
    run_backup
    [ "$status" -eq 0 ]
    run_id=$(js "$STATUS" 'd["run_id"]' | tr -d '"')
    tar -tf "$HOST_DIR/$run_id/$STACK.tar" | grep -qx "$STACK/models/blobs/b"
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"backed_up"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["x_backup"]["status"]')" = '"config-error"' ]
    [ "$(js "$STATUS" 'd["coverage"]["status"]')" = '"config-error"' ]
    [ "$(js "$STATUS" 'd["coverage"]["xbackup_config_errors"]')" = 1 ]
    grep -qx "dsb_stack_xbackup_config_error{host=\"$HOST\",stack=\"$STACK\"} 1" "$PROM_TEXTFILE_DIR/docker_stack_backup.prom"
    [[ "$output" == *"x-backup: 1 stack(s) with an invalid x-backup block, backed up in full"* ]]
}

@test "a valid block: status.json carries the record, the .prom carries the counts" {
    xb_config '{"exclude": [{"path": "models/blobs", "reason": "re-pull"}, {"path": "gone", "reason": "old"}],
                "weekly": [{"path": "idx", "reason": "rebuilt"}]}'
    export PROM_TEXTFILE_DIR="$TEST_DIR/prom"; mkdir -p "$PROM_TEXTFILE_DIR"
    export FULL_RUN_DAY=$(( $(date +%u) % 7 + 1 ))   # not today: a daily run
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["run_kind"]')" = '"daily"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["x_backup"]["status"]')" = '"ok"' ]
    [ "$(js "$STATUS" '[e["action"] for e in d["stacks"][0]["x_backup"]["excluded"]]')" = '["excluded", "excluded", "deferred"]' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["x_backup"]["stale"]')" = '["gone"]' ]
    [ "$(js "$STATUS" 'd["coverage"]["status"]')" = '"ok"' ]
    prom="$PROM_TEXTFILE_DIR/docker_stack_backup.prom"
    grep -qx "dsb_stack_xbackup_paths{host=\"$HOST\",stack=\"$STACK\",state=\"excluded\"} 2" "$prom"
    grep -qx "dsb_stack_xbackup_paths{host=\"$HOST\",stack=\"$STACK\",state=\"deferred\"} 1" "$prom"
    grep -qx "dsb_stack_xbackup_paths{host=\"$HOST\",stack=\"$STACK\",state=\"stale\"} 1" "$prom"
    grep -qx "dsb_stack_xbackup_config_error{host=\"$HOST\",stack=\"$STACK\"} 0" "$prom"
    grep -qx "dsb_last_run_kind{host=\"$HOST\",kind=\"daily\"} 1" "$prom"
    grep -qx "dsb_last_run_kind{host=\"$HOST\",kind=\"full\"} 0" "$prom"
}

@test "--coverage-report shows each stack's x_backup, and a bad block makes the summary config-error" {
    xb_config
    run_backup --coverage-report
    [ "$status" -eq 0 ]
    echo "$output" > "$TEST_DIR/report.json"
    [ "$(js "$TEST_DIR/report.json" 'd["stacks"][0]["x_backup"]["status"]')" = '"none"' ]
    [ "$(js "$TEST_DIR/report.json" 'd["summary"]["status"]')" = '"ok"' ]
    xb_config '{"weekly": "idx"}'
    run_backup --coverage-report
    echo "$output" > "$TEST_DIR/report.json"
    [ "$(js "$TEST_DIR/report.json" 'd["stacks"][0]["x_backup"]["status"]')" = '"config-error"' ]
    [ "$(js "$TEST_DIR/report.json" 'd["summary"]["status"]')" = '"config-error"' ]
}

@test "the dry run prints the run kind, the tiers with their reasons, and the snapshot backend" {
    xb_config '{"exclude": [{"path": "models/blobs", "reason": "re-download with ollama pull"}]}'
    run_backup --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"x-backup: ok ("*" run)"* ]]
    [[ "$output" == *"excluded: models/blobs — re-download with ollama pull"* ]]
    [[ "$output" == *"Run kind: "* ]]
    [[ "$output" == *"Snapshot backend: none"* ]]
}
