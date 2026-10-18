#!/usr/bin/env bats
# last_success is carried forward from the previous status.json when this run did not
# succeed. That file lives on the backup share, a root trust boundary (USAGE.md): every
# value in it is attacker input. dsb_status.py reads it, and only an integer in
# [2020-01-01, now + 1 day] survives; anything else means "no previous success".
#
# Each probe is first shown to FIRE on a deliberately naive reader (a negative probe
# that cannot fire proves nothing; programme lesson from audit p3a), then shown to be
# rejected by the real one with nothing executed.

load helpers/stub-env
load helpers/status

setup() {
    stub_env_setup
    status_setup
    mkdir -p "$HOST_DIR"
    PWNED="$TEST_DIR/PWNED"
    GOOD=1760000000   # 2025-10-09, in range
}

teardown() {
    stub_env_teardown
}

# _prev <python expression for last_success> [extra python statements on d] — writes
# the previous status.json with the probe in last_success and in the stack's history.
_prev() {
    python3 -I - "$STATUS" "$HOST" "$STACK" "$1" "$PWNED" "${2:-}" <<'EOF'
import json, sys
path, host, stack, expr, pwned, extra = sys.argv[1:7]
v = eval(expr, {"PWNED": pwned})
d = {"schema": 1, "tool": "docker-stack-backup", "host": host, "last_success": v,
     "stack_last_success": {stack: v}, "stacks": []}
if extra:
    exec(extra)
raw = d if isinstance(d, (bytes, bytearray)) else json.dumps(d).encode()
open(path, "wb").write(raw)
EOF
}

# Naive readers: what a first draft without guards would do.
_naive_py() {   # prints the accepted value, or nothing
    python3 -I -c '
import json, sys
d = json.loads(open(sys.argv[1], "rb").read().decode("latin-1"))
v = d.get("last_success")
if v is not None: print(repr(v))' "$STATUS"
}
_naive_shell_arith() {   # `(( ))` on the value, as cleanup's du | cut once did
    local v; v=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["last_success"])' "$STATUS")
    (( v > 0 )) 2>/dev/null || true
}
_naive_shell_eval() {
    local v; v=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["last_success"])' "$STATUS")
    eval "prev=\"$v\"" 2>/dev/null || true
}

# The real reader, through a run in which the stack fails (so nothing is fresh and
# every last_success must come from the previous file or be null).
_real() {
    export STUB_PS_RC=1
    run_backup
    [ "$status" -eq 1 ]
}

_assert_rejected() {
    [ "$(js "$STATUS" 'd["last_success"]')" = null ]
    [ "$(js "$STATUS" 'd["stack_last_success"]')" = '{}' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["last_success"]')" = null ]
    [ ! -e "$PWNED" ]
}

@test "control: a valid previous last_success is carried forward (host and stack)" {
    _prev "$GOOD"
    _real
    [ "$(js "$STATUS" 'd["last_success"]')" = "$GOOD" ]
    [ "$(js "$STATUS" 'd["stack_last_success"]["'"$STACK"'"]')" = "$GOOD" ]
    [ "$(js "$STATUS" 'd["stacks"][0]["last_success"]')" = "$GOOD" ]
}

@test 'probe: command substitution string fires on a naive eval reader; real reader rejects it, nothing runs' {
    _prev '"$(touch " + PWNED + ")"'
    _naive_shell_eval
    [ -e "$PWNED" ]; rm -f "$PWNED"
    _real
    _assert_rejected
}

@test 'probe: arithmetic array-subscript string fires on a naive (( )) reader; real reader rejects it, nothing runs' {
    _prev '"x[$(touch " + PWNED + ")0]"'
    _naive_shell_arith
    [ -e "$PWNED" ]; rm -f "$PWNED"
    _real
    _assert_rejected
}

@test "probe 1e99: accepted by a naive reader; rejected" {
    _prev '1e99'
    [ -n "$(_naive_py)" ]
    _real
    _assert_rejected
}

@test "probe -1: accepted by a naive reader; rejected" {
    _prev '-1'
    [ "$(_naive_py)" = "-1" ]
    _real
    _assert_rejected
}

@test "probe: a numeric string; accepted by a naive reader; rejected" {
    _prev "'$GOOD'"
    [ -n "$(_naive_py)" ]
    _real
    _assert_rejected
}

@test "probe: true (bool is an int subclass in python); accepted by a naive reader; rejected" {
    _prev 'True'
    [ "$(_naive_py)" = True ]
    _real
    _assert_rejected
}

@test "probe: a nested object; accepted by a naive reader; rejected" {
    _prev '{"$gt": 0, "v": [1, 2]}'
    [ -n "$(_naive_py)" ]
    _real
    _assert_rejected
}

@test "probe: a far-future time (now + 2 days); accepted by a naive reader; rejected" {
    future=$(( $(date +%s) + 2 * 86400 ))
    _prev "$future"
    [ "$(_naive_py)" = "$future" ]
    _real
    _assert_rejected
}

@test "probe: a 10 MB file with a valid value inside; accepted by a naive reader; rejected" {
    _prev "$GOOD" 'd["pad"] = "A" * (10 * 1024 * 1024)'
    [ "$(stat -c %s "$STATUS")" -gt 10000000 ]
    [ "$(_naive_py)" = "$GOOD" ]
    _real
    _assert_rejected
    [[ "$output" == *"previous status file ignored: larger than"* ]]
}

@test "probe: invalid UTF-8 around a valid value; accepted by a naive reader; rejected" {
    _prev "$GOOD" 'd = json.dumps(d).encode().replace(b"\"stacks\"", b"\"st\xff\xfeacks\"")'
    [ "$(_naive_py)" = "$GOOD" ]
    _real
    _assert_rejected
    [[ "$output" == *"previous status file ignored: not valid UTF-8 JSON"* ]]
}

@test "probe: deeply nested JSON (RecursionError); rejected, run unaffected" {
    _prev "$GOOD" 'd = (b"[" * 200000) + (b"]" * 200000)'
    _real
    _assert_rejected
}

@test "probe: a symlink in place of status.json is not followed" {
    echo '{"schema": 1, "tool": "docker-stack-backup", "host": "'"$HOST"'", "last_success": '"$GOOD"'}' > "$TEST_DIR/elsewhere.json"
    ln -s "$TEST_DIR/elsewhere.json" "$STATUS"
    _real
    [ "$(js "$STATUS" 'd["last_success"]')" = null ]
    # The new status replaced the link; the link target is untouched.
    [ ! -L "$STATUS" ]
    grep -q "$GOOD" "$TEST_DIR/elsewhere.json"
}

@test "probe: a FIFO in place of status.json does not hang the run" {
    mkfifo "$STATUS"
    export STUB_PS_RC=1
    run timeout 60 bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh"
    [ "$status" -eq 1 ]
    [ -f "$STATUS" ]
    [ "$(js "$STATUS" 'd["last_success"]')" = null ]
}

@test "the type check runs BEFORE open: a non-regular file is never opened (audit F-02)" {
    # A device node cannot be made unprivileged; a FIFO takes the same path. The reader
    # must refuse it from lstat alone, without calling os.open on it.
    mkfifo "$TEST_DIR/fifo"
    run python3 -I - "$BATS_TEST_DIRNAME/.." "$TEST_DIR/fifo" <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import dsb_status
opened = []
real = os.open
os.open = lambda p, *a, **k: (opened.append(p), real(p, *a, **k))[1]
print(dsb_status.load_previous(sys.argv[2], "h", 2000000000))
assert opened == [], opened
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"(None, {})"* ]]
    [[ "$output" == *"not a regular file"* ]]
}

@test "probe: a file written for another host is not carried" {
    _prev "$GOOD" 'd["host"] = "someone-else"'
    _real
    _assert_rejected
}

@test "an unparsable previous file is never an error that stops the run" {
    printf 'not json at all' > "$STATUS"
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"success"' ]
    [ "$(js "$STATUS" 'type(d["last_success"]) is int')" = true ]
}
