#!/usr/bin/env bats
# Tests for require_privileged_or_elevated() in lib.sh (DSBAK-6).
# Requires: bats (apt install bats)
# Run:      bats tests/require-privileged-or-elevated.bats
#
# These tests assume bats itself runs unprivileged (EUID != 0), which is the normal
# case in CI and local dev. They exercise the "not root" branches of the check; the
# "already root" passthrough is unchanged legacy behavior and not re-tested here.

setup() {
    TEST_DIR="$(mktemp -d)"
    export LOG_FILE="$TEST_DIR/test.log"
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib.sh"

    if [[ $EUID -eq 0 ]]; then
        skip "these tests require an unprivileged test runner (EUID != 0)"
    fi
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "unprivileged + ELEVATION_CMD unset (default none) fails closed" {
    unset ELEVATION_CMD
    run require_privileged_or_elevated
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}

@test "unprivileged + ELEVATION_CMD=none fails closed" {
    ELEVATION_CMD=none
    run require_privileged_or_elevated
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}

@test "unprivileged + ELEVATION_CMD=sudo passes the check" {
    ELEVATION_CMD=sudo
    run require_privileged_or_elevated
    [ "$status" -eq 0 ]
}

@test "unprivileged + ELEVATION_CMD=doas passes the check" {
    ELEVATION_CMD=doas
    run require_privileged_or_elevated
    [ "$status" -eq 0 ]
}
