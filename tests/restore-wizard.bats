#!/usr/bin/env bats
# docker-stack-restore.sh: the wizard must get from Step 1 to the "Proceed with restore?"
# confirmation. Before 0.5.1 it never did on any host:
#   - Step 2 filled its timestamps array inside `for … done | sort -r`, a subshell, so the
#     array stayed unset and `set -u` aborted ("timestamps: unbound variable") (#1094).
#   - Step 4 piped `tar -tf` into `head -20`; on an archive whose listing outgrows the
#     pipe buffer tar dies of SIGPIPE and pipefail + set -e killed the preview.
# Every test answers "n" at the confirmation, so nothing past Step 4 runs.

setup() {
    TEST_DIR="$(mktemp -d)"
    export BACKUP_BASE="$TEST_DIR/backups"
    export LOG_FILE="$TEST_DIR/restore.log"
    export DOCKHAND_BASE="$TEST_DIR/docker" APPDATA_PATH="$TEST_DIR/appdata"
    HOST_DIR="$BACKUP_BASE/testhost"
    SCRIPT="$BATS_TEST_DIRNAME/../docker-stack-restore.sh"

    # Created out of order, so a plain glob would list them oldest-first.
    mkdir -p "$HOST_DIR"/{20261012_020000,20261011_020000,20261013_020000}
    local src="$TEST_DIR/src"

    # alpha: enough long paths that `tar -tf` writes well past 64 KiB.
    mkdir -p "$src/alpha/data"
    (cd "$src/alpha/data" && printf 'file_%05d_padding_padding_padding_padding\n' $(seq 1 3000) | xargs touch)
    # Step 3 lists *.tar.* before *.tar, so alpha (.tar.gz) is 1) and beta (.tar) is 2).
    tar -czf "$HOST_DIR/20261013_020000/alpha.tar.gz" -C "$src" alpha
    mkdir -p "$src/beta" && echo b > "$src/beta/b.txt"
    tar -cf "$HOST_DIR/20261013_020000/beta.tar" -C "$src" beta
    # A failed archive's temp name: must not be offered as a stack (or counted).
    : > "$HOST_DIR/20261013_020000/gamma.incomplete"

    tar -cf "$HOST_DIR/20261012_020000/beta.tar" -C "$src" beta
    tar -cf "$HOST_DIR/20261011_020000/beta.tar" -C "$src" beta
}

teardown() {
    rm -rf "${TEST_DIR:?}"
}

# Sources the script (main does not run when sourced) and drives Steps 1-4 with $1 as
# stdin. Sourcing skips main's root check, so this runs on any unprivileged runner.
_drive_steps() {
    run bash -c 'source "$1"; select_hostname; select_timestamp; select_stack; preview_backup' \
        _ "$SCRIPT" <<< "$1"
}

@test "wizard reaches the confirmation prompt: Steps 1-4, cancel at Step 4" {
    _drive_steps $'1\n1\n1\nn'
    [ "$status" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]]
    [[ "$output" == *"Selected host: "*"testhost"* ]]
    [[ "$output" == *"Selected backup: "*"20261013_020000"* ]]
    [[ "$output" == *"Selected stack: "*"alpha"* ]]
    [[ "$output" == *"Step 4: Preview Backup Contents"* ]]
    [[ "$output" == *"more files"* ]]
    [[ "$output" == *"Proceed with restore?"* ]]
    [[ "$output" == *"Restore cancelled."* ]]
}

@test "Step 2 lists backups newest-first, and the number selects in that order" {
    _drive_steps $'1\n2\n1\nn'
    [ "$status" -eq 0 ]
    local listing
    listing=$(printf '%s\n' "$output" | grep 'October')
    [ "$(printf '%s\n' "$listing" | sed -n 1p | grep -c 'October 13, 2026 at 02:00:00 (2 stacks)')" -eq 1 ]
    [ "$(printf '%s\n' "$listing" | sed -n 2p | grep -c 'October 12, 2026')" -eq 1 ]
    [ "$(printf '%s\n' "$listing" | sed -n 3p | grep -c 'October 11, 2026')" -eq 1 ]
    [[ "$output" == *"Selected backup: "*"20261012_020000"* ]]
    [[ "$output" == *"Restore cancelled."* ]]
}

@test "Step 3 lists .tar.gz and .tar stacks and skips .incomplete files" {
    _drive_steps $'1\n1\n2\nn'
    [ "$status" -eq 0 ]
    [[ "$output" == *"1)"*"alpha ("* ]]
    [[ "$output" == *"2)"*"beta ("* ]]
    [[ "$output" != *"gamma"* ]]
    [[ "$output" == *"Selected stack: "*"beta"* ]]
    [[ "$output" == *"beta/b.txt"* ]]
}

@test "sourcing the script does not run the wizard" {
    run bash -c 'source "$1" </dev/null; echo sourced-ok' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced-ok"* ]]
    [[ "$output" != *"Restore Wizard"* ]]
}

@test "executed as root, main runs Steps 1-4 to the confirmation" {
    # main refuses non-root. A user namespace gives EUID 0 without real privilege.
    if ! unshare -r true 2>/dev/null; then
        skip "unprivileged user namespaces unavailable (unshare -r)"
    fi
    run unshare -r bash "$SCRIPT" <<< $'1\n1\n1\nn'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restore Wizard"* ]]
    [[ "$output" == *"Selected backup: "*"20261013_020000"* ]]
    [[ "$output" == *"Restore cancelled."* ]]
}

@test "Step 1 with no host dirs prints its own error instead of an unbound variable" {
    rm -rf "${BACKUP_BASE:?}"/*
    _drive_steps $'1'
    [ "$status" -eq 1 ]
    [[ "$output" == *"No backup hosts found in $BACKUP_BASE"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

@test "Step 4 warns when the archive cannot be listed (corrupt), but not on SIGPIPE" {
    printf 'not-a-tar-archive' > "$HOST_DIR/20261013_020000/beta.tar"
    _drive_steps $'1\n1\n2\nn'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not list"*"beta.tar (tar exit 2)"* ]]
    [[ "$output" == *"Restore cancelled."* ]]

    # alpha's listing is cut short by head (tar gets SIGPIPE): no warning.
    _drive_steps $'1\n1\n1\nn'
    [ "$status" -eq 0 ]
    [[ "$output" != *"Could not list"* ]]
}
