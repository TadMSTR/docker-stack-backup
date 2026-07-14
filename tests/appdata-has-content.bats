#!/usr/bin/env bats
# Tests for appdata_has_content() in lib.sh (DSBAK-6 follow-up, H-1).
# Requires: bats (apt install bats)
# Run:      bats tests/appdata-has-content.bats
#
# A directory chmod'd to 000 by its own (non-root) owner denies that owner read/execute
# access just like a root-owned dir denies an unprivileged caller — this reproduces the
# "permission denied looks identical to empty" mechanism H-1 is about without needing an
# actual root-owned fixture.

setup() {
    TEST_DIR="$(mktemp -d)"
    export LOG_FILE="$TEST_DIR/test.log"
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib.sh"

    if [[ $EUID -eq 0 ]]; then
        skip "these tests require an unprivileged test runner (EUID != 0) — chmod 000 has no effect on root"
    fi
}

teardown() {
    # restore perms in case a test left them locked down, so cleanup can descend
    chmod -R u+rwx "$TEST_DIR" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

@test "ELEVATION_CMD=none: truly empty dir is reported empty (skip)" {
    unset ELEVATION_CMD
    local dir="$TEST_DIR/empty"; mkdir -p "$dir"
    run appdata_has_content "$dir"
    [ "$status" -eq 1 ]
}

@test "ELEVATION_CMD=none: populated dir is reported has-content" {
    unset ELEVATION_CMD
    local dir="$TEST_DIR/populated"; mkdir -p "$dir"; touch "$dir/file"
    run appdata_has_content "$dir"
    [ "$status" -eq 0 ]
}

@test "ELEVATION_CMD=none: unreadable-but-populated dir is misreported empty (documents the H-1 mechanism)" {
    unset ELEVATION_CMD
    local dir="$TEST_DIR/unreadable"; mkdir -p "$dir"; touch "$dir/secret-file"
    chmod 000 "$dir"
    run appdata_has_content "$dir"
    chmod 755 "$dir"
    [ "$status" -eq 1 ]
}

@test "ELEVATION_CMD=sudo: unreadable-but-populated dir is NOT treated as empty (H-1 fix)" {
    ELEVATION_CMD=sudo
    local dir="$TEST_DIR/unreadable-elevated"; mkdir -p "$dir"; touch "$dir/secret-file"
    chmod 000 "$dir"
    run appdata_has_content "$dir"
    chmod 755 "$dir"
    [ "$status" -eq 0 ]
}

@test "ELEVATION_CMD=doas: unreadable-but-populated dir is NOT treated as empty (H-1 fix)" {
    ELEVATION_CMD=doas
    local dir="$TEST_DIR/unreadable-elevated-doas"; mkdir -p "$dir"; touch "$dir/secret-file"
    chmod 000 "$dir"
    run appdata_has_content "$dir"
    chmod 755 "$dir"
    [ "$status" -eq 0 ]
}

@test "ELEVATION_CMD=sudo: truly empty dir still proceeds (attempt), not skipped" {
    ELEVATION_CMD=sudo
    local dir="$TEST_DIR/empty-elevated"; mkdir -p "$dir"
    run appdata_has_content "$dir"
    [ "$status" -eq 0 ]
}
