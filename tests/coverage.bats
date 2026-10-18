#!/usr/bin/env bats
# Coverage classifier (0.6.0): what state each stack has that the archive does not
# take. It reports; it never selects (stack_has_appdata is unchanged). Every mount comes
# from `docker compose config --format json` (stubbed here), never from the YAML text.

load helpers/stub-env
load helpers/status

setup() {
    stub_env_setup
    status_setup
    ST="$DOCKHAND_BASE/$STACK"
    mkdir -p "$APPDATA_PATH/other" "$APPDATA_PATH/orphan" "$TEST_DIR/host-ro" "$TEST_DIR/host-rw"
    echo o > "$APPDATA_PATH/orphan/f"
    : > "$APPDATA_PATH/README.md"                    # a regular file: never "unowned"
    ln -s "$TEST_DIR/host-rw" "$APPDATA_PATH/a-link"  # a symlink: not followed, not listed
    cat > "$STUB_CONFIG_DIR/$STACK.json" <<JSON
{"services": {
  "app": {"volumes": [
    {"type": "bind", "source": "$APPDATA_PATH/$STACK", "target": "/data"},
    {"type": "bind", "source": "$APPDATA_PATH/$STACK/sub/../db", "target": "/db"},
    {"type": "bind", "source": "$APPDATA_PATH/other/logs", "target": "/logs", "read_only": true},
    {"type": "bind", "source": "$ST/config.yml", "target": "/etc/app.yml", "read_only": true},
    {"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock"},
    {"type": "bind", "source": "/etc/localtime", "target": "/etc/localtime", "read_only": true},
    {"type": "bind", "source": "$TEST_DIR/host-ro", "target": "/in", "read_only": true},
    {"type": "bind", "source": "$TEST_DIR/host-rw", "target": "/out"},
    {"type": "volume", "source": "pgdata", "target": "/var/lib/postgresql/data", "volume": {}},
    {"type": "volume", "target": "/anon"},
    {"type": "tmpfs", "target": "/run/tmp"}
  ]},
  "worker": {"image": "busybox"}},
 "volumes": {"pgdata": {"name": "stubstack_pgdata"}}}
JSON
}

teardown() {
    stub_env_teardown
}

_report() {
    run bash -c "bash '$BATS_TEST_DIRNAME/../docker-stack-backup.sh' --coverage-report 2>'$TEST_DIR/report.err' >'$TEST_DIR/report.json'"
    [ "$status" -eq 0 ]
    R="$TEST_DIR/report.json"
}

_classes() { js "$R" '[i["class"] for i in d["stacks"][0]["coverage"]["items"]]'; }

@test "every mount gets a class (report mode)" {
    _report
    [ "$(_classes)" = '["archived", "archived", "other-stack-appdata", "stack-dir", "system", "system", "input-ro", "uncovered", "named-volume", "named-volume", "tmpfs"]' ]
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["status"]')" = '"uncovered"' ]
    # Paths are normalised without touching the filesystem.
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["items"][1]["source"]')" = "\"$APPDATA_PATH/$STACK/db\"" ]
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["items"][2]["other_stack"]')" = '"other"' ]
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["items"][8]["volume_name"]')" = '"stubstack_pgdata"' ]
}

@test "alerting: uncovered and named volumes; other-stack-appdata only if <other> is not a stack" {
    _report
    [ "$(js "$R" '[i["class"] for i in d["stacks"][0]["coverage"]["items"] if i["alerting"]]')" = '["other-stack-appdata", "uncovered", "named-volume", "named-volume"]' ]
    [ "$(js "$R" 'd["summary"]["uncovered_items"]')" = 4 ]
}

@test "unowned appdata: dirs that match no stack, with size; files and symlinks are skipped" {
    _report
    [ "$(js "$R" '[u["dir"] for u in d["unowned_appdata"]]')" = '["orphan", "other"]' ]
    [ "$(js "$R" 'd["unowned_appdata"][0]["bytes"] > 0')" = true ]
    [ "$(js "$R" 'd["unowned_appdata"][0]["estimate"]')" = false ]
}

@test "the compose file's own text is never read: a mount only the config JSON knows is classified" {
    # The stub compose file mentions no host-rw path; only `compose config` does.
    ! grep -q host-rw "$ST/docker-compose.yml"
    _report
    [ "$(js "$R" '"'"$TEST_DIR/host-rw"'" in [i["source"] for i in d["stacks"][0]["coverage"]["items"]]')" = true ]
}

@test "compose config failure: coverage unknown with stderr's first line, counted as alerting" {
    export STUB_CONFIG_RC=15
    _report
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["status"]')" = '"unknown"' ]
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["error"]')" = '"stub: services.app.image must be a string"' ]
    [ "$(js "$R" 'd["summary"]["status"]')" = '"unknown"' ]
    [ "$(js "$R" 'd["summary"]["stacks_unknown"]')" = 1 ]
}

@test "compose config printing non-JSON is unknown, never 'nothing uncovered'" {
    echo 'services: {}' > "$STUB_CONFIG_DIR/$STACK.json"
    _report
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["status"]')" = '"unknown"' ]
}

@test "COVERAGE_IGNORE_PATHS adds system prefixes" {
    export COVERAGE_IGNORE_PATHS="/nonexistent:$TEST_DIR/host-rw"
    _report
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["items"][7]["class"]')" = '"system"' ]
}

@test "real run: other-stack-appdata is alerting only when <other> was not backed up this run" {
    add_stack other
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" '[i for s in d["stacks"] if s["name"] == "'"$STACK"'" for i in s["coverage"]["items"] if i["class"] == "other-stack-appdata"][0]["other_backed_up"]')" = true ]
    [ "$(js "$STATUS" '[i for s in d["stacks"] if s["name"] == "'"$STACK"'" for i in s["coverage"]["items"] if i["class"] == "other-stack-appdata"][0]["alerting"]')" = false ]

    export BACKUP_STOPPED_STACKS=false
    printf 'app\nworker\n' > "$STATE_FILE"
    sed -i 's|^    ps)$|    ps)\n        [[ "$(basename "$PWD")" == other ]] \&\& exit 0|' "$BIN_DIR/docker"
    run_backup
    [ "$(js "$STATUS" '[s["result"] for s in d["stacks"] if s["name"] == "other"]')" = '["skipped"]' ]
    [ "$(js "$STATUS" '[i for s in d["stacks"] if s["name"] == "'"$STACK"'" for i in s["coverage"]["items"] if i["class"] == "other-stack-appdata"][0]["alerting"]')" = true ]
}

#######################################
# Exemptions: data, never sourced or evaluated
#######################################

@test "exemptions: stack, mount (path and volume), appdata; each item keeps its class" {
    cat > "$COVERAGE_EXEMPTIONS_FILE" <<EOF
# comment

mount|$STACK:$TEST_DIR/host-rw|scratch output, regenerated on start
mount|$STACK:volume:pgdata|dumped nightly by pg-dump stack
mount|$STACK:$APPDATA_PATH/other/logs|read-only log tail
appdata|orphan|owned by the PM2 service orphan; Backrest plan forge-agent
EOF
    _report
    [ "$(js "$R" '[(i["class"], i["exempt"]) for i in d["stacks"][0]["coverage"]["items"] if i["exempt"]]')" = '[["other-stack-appdata", "read-only log tail"], ["uncovered", "scratch output, regenerated on start"], ["named-volume", "dumped nightly by pg-dump stack"]]' ]
    # The anonymous volume is still uncovered.
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["status"]')" = '"uncovered"' ]
    [ "$(js "$R" '[u["exempt"] for u in d["unowned_appdata"]]')" = '["owned by the PM2 service orphan; Backrest plan forge-agent", null]' ]
    [ "$(js "$R" 'd["exemptions"]["status"]')" = '"ok"' ]
    [ "$(js "$R" 'd["exemptions"]["stale"]')" = '[]' ]
}

@test "a stack exemption covers every alerting item in the stack" {
    echo "stack|$STACK|disposable scratch databases" > "$COVERAGE_EXEMPTIONS_FILE"
    _report
    [ "$(js "$R" 'd["stacks"][0]["coverage"]["status"]')" = '"ok"' ]
    [ "$(js "$R" 'all(i["exempt"] for i in d["stacks"][0]["coverage"]["items"] if i["alerting"])')" = true ]
}

@test "a stale exemption (matches nothing) is listed and logged" {
    printf 'stack|gone-stack|was here once\nappdata|no-such-dir|old\n' > "$COVERAGE_EXEMPTIONS_FILE"
    _report
    [ "$(js "$R" '[s["subject"] for s in d["exemptions"]["stale"]]')" = '["gone-stack", "no-such-dir"]' ]
    grep -q 'matched nothing (stale): line 1 stack|gone-stack' "$TEST_DIR/report.err"
}

@test "malformed lines: rejected and reported; valid lines still apply; status config-error" {
    printf '%s\n' \
        'stack||a reason' \
        "stack|$STACK|" \
        'bogus|x|y' \
        'just text' \
        "mount|$STACK|no colon" \
        "mount|$STACK:relative/path|relative" \
        "appdata|orphan|ok"$'\x1b'"[31m" \
        "appdata|orphan|valid line" > "$COVERAGE_EXEMPTIONS_FILE"
    _report
    [ "$(js "$R" 'd["exemptions"]["status"]')" = '"config-error"' ]
    [ "$(js "$R" '[(e["line"], e["error"]) for e in d["exemptions"]["errors"]]')" = '[[1, "empty subject"], [2, "empty reason"], [3, "unknown kind"], [4, "expected <kind>|<subject>|<reason>"], [5, "mount subject must be <stack>:<path> or <stack>:volume:<name>"], [6, "mount target must be an absolute path or volume:<name>"], [7, "control character"]]' ]
    [ "$(js "$R" 'd["unowned_appdata"][0]["exempt"]')" = '"valid line"' ]
    [ "$(js "$R" 'd["summary"]["status"]')" = '"config-error"' ]
    # Diagnostics are printable: no raw ESC reaches the log.
    ! grep -q $'\x1b' "$TEST_DIR/report.err"
}

@test 'a command substitution in a reason is inert data' {
    echo "appdata|orphan|\$(touch $TEST_DIR/PWNED) \`touch $TEST_DIR/PWNED2\`" > "$COVERAGE_EXEMPTIONS_FILE"
    _report
    [ ! -e "$TEST_DIR/PWNED" ]
    [ ! -e "$TEST_DIR/PWNED2" ]
    [ "$(js "$R" 'd["unowned_appdata"][0]["exempt"]')" = "\"\$(touch $TEST_DIR/PWNED) \`touch $TEST_DIR/PWNED2\`\"" ]
}

@test "a malformed exemptions file does not stop the backup" {
    printf 'garbage\n\xff\xfe\n' > "$COVERAGE_EXEMPTIONS_FILE"
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully backed up: 1"* ]]
    [ "$(js "$STATUS" 'd["exemptions"]["status"]')" = '"config-error"' ]
    [ "$(js "$STATUS" 'd["coverage"]["status"]')" = '"config-error"' ]
    [[ "$output" == *"status: coverage exemptions"*"line 1: expected <kind>|<subject>|<reason>"* ]]
    [[ "$output" == *"line 2: not valid UTF-8"* ]]
}

@test "a missing exemptions file: status missing, no error" {
    _report
    [ "$(js "$R" 'd["exemptions"]["status"]')" = '"missing"' ]
}

@test "selection is unchanged: a stack whose compose file never names APPDATA_PATH is skipped" {
    sed -i "s|$APPDATA_PATH|/elsewhere|" "$ST/docker-compose.yml"
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped stacks: $STACK (no-appdata-reference)"* ]]
}
