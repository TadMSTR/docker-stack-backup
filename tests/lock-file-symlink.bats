#!/usr/bin/env bats
# #1186: the lock file is opened without following a symlink and without truncating.
# A root run (the manual script, say) used to open LOCK_FILE with `exec 200>file`, so a
# symlink planted in the backup user's own ~/run made root truncate its target.

load helpers/stub-env
load helpers/status

setup() {
    stub_env_setup
    status_setup
    mkdir -p "$TEST_DIR/run"
    VICTIM="$TEST_DIR/victim"
    echo "precious" > "$VICTIM"
}

teardown() {
    stub_env_teardown
}

@test "a symlinked LOCK_FILE is refused, and its target is untouched" {
    ln -s "$VICTIM" "$LOCK_FILE"
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"Lock file is a symlink, refusing to open it"* ]]
    [ "$(cat "$VICTIM")" = precious ]
    [ -L "$LOCK_FILE" ]
}

@test "the same for the manual script" {
    ln -s "$VICTIM" "$LOCK_FILE"
    run bash "$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh" <<< $'1\ny\n'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Lock file is a symlink"* ]]
    [ "$(cat "$VICTIM")" = precious ]
}

@test "a dangling symlink is refused too (it would create the target)" {
    ln -s "$TEST_DIR/created-by-root" "$LOCK_FILE"
    run_backup
    [ "$status" -eq 1 ]
    [ ! -e "$TEST_DIR/created-by-root" ]
}

@test "a LOCK_FILE that is not a regular file (a FIFO) is refused" {
    mkfifo "$LOCK_FILE"
    run timeout 20 bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Lock file is not a regular file"* ]]
}

@test "a regular lock file works and holds the PID while the run is going" {
    echo "stale-content-longer-than-a-pid" > "$LOCK_FILE"
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Lock acquired (PID: "* ]]
    # Released (removed) at the end, as before.
    [ ! -e "$LOCK_FILE" ]
}

@test "a lock file swapped between the check and the open is refused (inode check)" {
    # stat reports another inode for the path than for the opened fd: what a swap looks
    # like from inside. The stub changes only `stat -c %d:%i -- <LOCK_FILE>`.
    cat > "$BIN_DIR/stat" <<STUB
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3 \$4" == "-c %d:%i -- $LOCK_FILE" ]]; then echo "1:1"; exit 0; fi
exec /usr/bin/stat "\$@"
STUB
    chmod +x "$BIN_DIR/stat"
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"Lock file was replaced while it was being opened"* ]]
}

@test "the PID is written through the checked fd: the file holds exactly the PID" {
    # Read the lock file while the run holds it, from a post-restart hook.
    cat > "$TEST_DIR/cfg-hook.sh" <<HOOK
peek_lock() { cat "$LOCK_FILE" > "$TEST_DIR/lock-content"; }
HOOK
    echo "stale-content-longer-than-a-pid" > "$LOCK_FILE"
    run bash -c "source '$TEST_DIR/cfg-hook.sh'; export -f peek_lock; POST_RESTART_HOOKS=peek_lock bash '$BATS_TEST_DIRNAME/../docker-stack-backup.sh'"
    [ "$status" -eq 0 ]
    [[ "$(cat "$TEST_DIR/lock-content")" =~ ^[0-9]+$ ]]
}
