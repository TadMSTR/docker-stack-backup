#!/usr/bin/env bats
# A run dir the reader cannot list is a failure, never an empty dir (security-patterns
# SH-15). 0.8.0 reads the share as its owner with find's stderr discarded, so restore and
# verify check readability first. Runs unprivileged: a 000 run dir is unreadable to its
# owner. Shown to fire on 0.7.0 first, whose verify silently skipped such a dir.

setup() {
    [[ $EUID -ne 0 ]] || skip "root can read a 000 dir"
    TEST_DIR="$(mktemp -d)"
    export BACKUP_BASE="$TEST_DIR/backups" LOG_FILE="$TEST_DIR/log"
    local src="$TEST_DIR/src"
    mkdir -p "$src/web" "$BACKUP_BASE/h/20261023_020001" "$BACKUP_BASE/h/20261024_020001"
    echo x > "$src/web/f"
    tar -cf "$BACKUP_BASE/h/20261023_020001/web.tar" -C "$src" web
    tar -cf "$BACKUP_BASE/h/20261024_020001/web.tar" -C "$src" web
    chmod 000 "$BACKUP_BASE/h/20261024_020001"
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() {
    [[ -n "${TEST_DIR:-}" ]] || return 0   # setup skipped (root)
    chmod 0700 "$BACKUP_BASE/h/20261024_020001" 2>/dev/null || true
    rm -rf -- "$TEST_DIR"
}

# plain_line <exact line> — $output, colour codes removed, has that exact line (CR-11/13:
# a wildcard match let the digit in a later ESC[0;31m stand in for the count).
plain_line() {
    sed 's/\x1b\[[0-9;]*m//g' <<< "$output" | grep -qx -- "$1"
}

@test "probe: v0.7.0's verify reports an unreadable run dir as nothing at all" {
    git -C "$REPO" cat-file -e v0.7.0 2>/dev/null || skip "v0.7.0 not in this checkout"
    local old="$TEST_DIR/v070"
    mkdir -p "$old"
    git -C "$REPO" show v0.7.0:backup-verify.sh > "$old/backup-verify.sh"
    git -C "$REPO" show v0.7.0:lib.sh > "$old/lib.sh"
    run bash "$old/backup-verify.sh" --verify
    plain_line "Invalid: 0"                                # fires: the unreadable set is invisible
    plain_line "Total backups checked: 1"
    [[ "$output" != *"20261024_020001"* ]]
}

@test "verify counts an unreadable run dir as invalid and names it" {
    run bash "$REPO/backup-verify.sh" --verify
    echo "$output" >&3
    [[ "$output" == *"cannot read h/20261024_020001 as its owner"* ]]
    plain_line "Valid: 1"
    plain_line "Invalid: 1"
}

@test "restore Step 3 refuses an unreadable run dir instead of saying it holds no stacks" {
    run bash -c 'source "$1/docker-stack-restore.sh"; selected_hostname=h selected_timestamp=20261024_020001; select_stack' _ "$REPO" <<< $'1\n'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot read"*"20261024_020001 as its owner"* ]]
    [[ "$output" != *"No stack backups found"* ]]
}
