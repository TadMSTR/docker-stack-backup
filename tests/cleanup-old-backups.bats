#!/usr/bin/env bats
# Tests for cleanup-old-backups.sh
# Requires: bats (apt install bats)
# Run:      bats tests/cleanup-old-backups.bats

SCRIPT="$BATS_TEST_DIRNAME/../cleanup-old-backups.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    export BACKUP_BASE="$TEST_DIR/backups"
    export LOG_FILE="$TEST_DIR/cleanup.log"
    export RETENTION_DAYS=30
    export SEARCH_DEPTH=2
    mkdir -p "$BACKUP_BASE"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Create a directory at $1, optionally aged $2 days (default: current mtime)
_make_dir() {
    local path="$1" age="${2:-0}"
    mkdir -p "$path"
    if [[ "$age" -gt 0 ]]; then touch -d "${age} days ago" "$path"; fi
}

# ---------------------------------------------------------------------------
# Basic error handling
# ---------------------------------------------------------------------------

@test "exits non-zero when BACKUP_BASE does not exist" {
    export BACKUP_BASE="$TEST_DIR/nonexistent"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Backup directory not found"* ]]
}

@test "exits zero when BACKUP_BASE is empty" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 0"* ]]
}

# ---------------------------------------------------------------------------
# Depth-2 layout: BACKUP_BASE/stack/YYYY-MM-DD-HHMMSS/
# ---------------------------------------------------------------------------

@test "removes old dir at depth 2" {
    _make_dir "$BACKUP_BASE/stack1/2024-01-01-120000" 35
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 1"* ]]
    [ ! -d "$BACKUP_BASE/stack1/2024-01-01-120000" ]
}

@test "preserves recent dir at depth 2" {
    _make_dir "$BACKUP_BASE/stack1/2026-06-19-120000"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 0"* ]]
    [ -d "$BACKUP_BASE/stack1/2026-06-19-120000" ]
}

@test "removes old dir but preserves recent sibling" {
    _make_dir "$BACKUP_BASE/stack1/2024-01-01-120000" 35
    _make_dir "$BACKUP_BASE/stack1/2026-06-19-120000"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 1"* ]]
    [ ! -d "$BACKUP_BASE/stack1/2024-01-01-120000" ]
    [ -d "$BACKUP_BASE/stack1/2026-06-19-120000" ]
}

# ---------------------------------------------------------------------------
# Arithmetic regression — the (( n++ )) / set -e bug
# All 5 dirs must be removed and counted; the bug caused exit after the first.
# ---------------------------------------------------------------------------

@test "counts multiple removals correctly (arithmetic regression)" {
    for i in 1 2 3 4 5; do
        _make_dir "$BACKUP_BASE/stack${i}/2024-01-0${i}-120000" 35
    done
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 5"* ]]
}

# ---------------------------------------------------------------------------
# SEARCH_DEPTH
# ---------------------------------------------------------------------------

@test "SEARCH_DEPTH=1 removes depth-1 old dir" {
    export SEARCH_DEPTH=1
    _make_dir "$BACKUP_BASE/2024-01-01-120000" 35
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 1"* ]]
    [ ! -d "$BACKUP_BASE/2024-01-01-120000" ]
}

@test "SEARCH_DEPTH=1 ignores depth-2 dirs" {
    export SEARCH_DEPTH=1
    _make_dir "$BACKUP_BASE/stack1/2024-01-01-120000" 35
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 0"* ]]
    [ -d "$BACKUP_BASE/stack1/2024-01-01-120000" ]
}

@test "SEARCH_DEPTH=2 (default) ignores depth-1 dirs" {
    _make_dir "$BACKUP_BASE/2024-01-01-120000" 35
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 0"* ]]
    [ -d "$BACKUP_BASE/2024-01-01-120000" ]
}

# ---------------------------------------------------------------------------
# Configuration via env vars and CLI
# ---------------------------------------------------------------------------

@test "BACKUP_BASE accepted as CLI arg" {
    local alt_base="$TEST_DIR/alt-backups"
    mkdir -p "$alt_base"
    _make_dir "$alt_base/stack1/2024-01-01-120000" 35
    unset BACKUP_BASE
    run bash "$SCRIPT" "$alt_base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 1"* ]]
}

@test "CLI arg for BACKUP_BASE takes precedence over env var" {
    local alt_base="$TEST_DIR/alt-backups"
    mkdir -p "$alt_base"
    _make_dir "$alt_base/stack1/2024-01-01-120000" 35
    export BACKUP_BASE="$TEST_DIR/wrong"
    mkdir -p "$TEST_DIR/wrong"
    run bash "$SCRIPT" "$alt_base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 1"* ]]
}

@test "RETENTION_DAYS controls the age threshold" {
    export RETENTION_DAYS=60
    _make_dir "$BACKUP_BASE/stack1/2024-01-01-120000" 35
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Directories removed: 0"* ]]
    [ -d "$BACKUP_BASE/stack1/2024-01-01-120000" ]
}

# ---------------------------------------------------------------------------
# Log file
# ---------------------------------------------------------------------------

@test "log file is created at LOG_FILE path" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$LOG_FILE" ]
}

@test "log file contains no ANSI escape codes when not a tty" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -P '\x1b' "$LOG_FILE"
    [ "$status" -ne 0 ]
}
