#!/usr/bin/env bats
# Tests for run_post_restart_hooks() in lib.sh
# Requires: bats (apt install bats)
# Run:      bats tests/post-restart-hooks.bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export LOG_FILE="$TEST_DIR/test.log"
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Hook invocation contract
# ---------------------------------------------------------------------------

@test "hook is called with stack_name and stack_path as positional args" {
    local marker="$TEST_DIR/marker"
    myhook() { printf '%s|%s' "$1" "$2" > "$marker"; }
    POST_RESTART_HOOKS=(myhook)

    run_post_restart_hooks "mystack" "/srv/stacks/mystack"

    [ -f "$marker" ]
    [ "$(cat "$marker")" = "mystack|/srv/stacks/mystack" ]
}

@test "multiple hooks all run in order" {
    local order="$TEST_DIR/order"
    first()  { echo "first"  >> "$order"; }
    second() { echo "second" >> "$order"; }
    POST_RESTART_HOOKS=(first second)

    run_post_restart_hooks "s" "/p"

    [ "$(cat "$order")" = "$(printf 'first\nsecond')" ]
}

# ---------------------------------------------------------------------------
# Failure is non-fatal
# ---------------------------------------------------------------------------

@test "a failing hook logs a warning but does not abort" {
    failhook() { return 3; }
    POST_RESTART_HOOKS=(failhook)

    run run_post_restart_hooks "s" "/p"

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"exit 3"* ]]
}

@test "a failing hook does not prevent later hooks from running" {
    local m1="$TEST_DIR/m1" m2="$TEST_DIR/m2"
    good1() { : > "$m1"; }
    bad()   { return 1; }
    good2() { : > "$m2"; }
    POST_RESTART_HOOKS=(good1 bad good2)

    run run_post_restart_hooks "s" "/p"

    [ "$status" -eq 0 ]
    [ -f "$m1" ]
    [ -f "$m2" ]
}

@test "a missing hook command is non-fatal (exit 127 logged, run continues)" {
    local m1="$TEST_DIR/m1"
    good1() { : > "$m1"; }
    POST_RESTART_HOOKS=(this_command_does_not_exist_12345 good1)

    run run_post_restart_hooks "s" "/p"

    [ "$status" -eq 0 ]
    [ -f "$m1" ]
    [[ "$output" == *"WARNING"* ]]
}

# ---------------------------------------------------------------------------
# Empty / no-op cases
# ---------------------------------------------------------------------------

@test "no hooks configured is a no-op" {
    POST_RESTART_HOOKS=()
    run run_post_restart_hooks "s" "/p"
    [ "$status" -eq 0 ]
}

@test "empty-string hook entries are skipped" {
    POST_RESTART_HOOKS=("")
    run run_post_restart_hooks "s" "/p"
    [ "$status" -eq 0 ]
}
