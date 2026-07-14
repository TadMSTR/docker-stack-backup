#!/usr/bin/env bats
# Tests for docker-backup-tar-create.sh — the restricted elevation helper.
# Requires: bats (apt install bats)
# Run:      bats tests/tar-create-helper.bats
#
# The shipped helper bakes ALLOWED_APPDATA_PATH in as a root-owned constant. To exercise
# the validation logic and happy path without needing /opt/appdata (or root), each test
# runs a copy of the helper whose ALLOWED_APPDATA_PATH line is rewritten to a temp dir.
# The validation logic under test is unchanged.

setup() {
    TEST_DIR="$(mktemp -d)"
    APPDATA="$TEST_DIR/appdata"
    mkdir -p "$APPDATA/mystack"
    echo "payload" > "$APPDATA/mystack/file.txt"

    # temp_dir arg must be a single path component under /tmp (helper's regex)
    TEMP_SRC="$(mktemp -d -p /tmp)"
    echo "services: {}" > "$TEMP_SRC/compose.yaml"

    HELPER="$TEST_DIR/helper.sh"
    sed "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-tar-create.sh" > "$HELPER"
    chmod +x "$HELPER"
}

teardown() {
    rm -rf "$TEST_DIR" "$TEMP_SRC"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "valid invocation writes a readable archive to stdout" {
    bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack > "$TEST_DIR/out.tar"
    run tar -tf "$TEST_DIR/out.tar"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mystack/file.txt"* ]]
    [[ "$output" == *"compose.yaml"* ]]
}

@test "valid exclude pattern is accepted" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack "*.log"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Argument validation — the security boundary
# ---------------------------------------------------------------------------

@test "rejects a crafted --checkpoint exclude pattern (GTFOBins primitive)" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack "--checkpoint=1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid exclude pattern"* ]]
}

@test "rejects a --checkpoint-action=exec exclude pattern" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack "--checkpoint-action=exec=sh shell.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid exclude pattern"* ]]
}

@test "rejects an appdata_path outside the allowlist" {
    run bash "$HELPER" none "$TEMP_SRC" /etc mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid appdata_path"* ]]
}

@test "rejects an invalid compression method" {
    run bash "$HELPER" zip "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid compression"* ]]
}

@test "rejects a temp_dir outside /tmp" {
    run bash "$HELPER" none /etc "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid temp_dir"* ]]
}

@test "rejects a temp_dir with nested path components" {
    run bash "$HELPER" none "/tmp/a/b" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid temp_dir"* ]]
}

@test "rejects a stack_name containing a slash (path traversal)" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" "../../etc"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid stack_name"* ]]
}

@test "rejects the bare '..' token (would archive the parent of the appdata root)" {
    # Regression for H-1: '..' passes the char-class regex and -d "<root>/.." is always
    # true, so without an explicit reject it archives one level above ALLOWED_APPDATA_PATH.
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" ".."
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid stack_name"* ]]
}

@test "rejects the bare '.' token (would archive the entire appdata root)" {
    # Regression for L-1: '.' archives every stack instead of one.
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" "."
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid stack_name"* ]]
}

@test "rejects a leading-dash stack_name" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" "-C/etc"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid stack_name"* ]]
}

@test "rejects a nonexistent stack appdata dir" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" nosuchstack
    [ "$status" -eq 2 ]
    [[ "$output" == *"stack appdata dir not found"* ]]
}

@test "exits 2 with usage when given too few arguments" {
    run bash "$HELPER" none "$TEMP_SRC"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}
