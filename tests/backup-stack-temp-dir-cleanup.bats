#!/usr/bin/env bats
# Regression: the temp_dir cleanup trap in backup_stack() must not leak.
#
# backup_stack() creates a temp dir and installs `trap 'rm -rf "$temp_dir"' RETURN`
# to clean it up when the function returns. Bash RETURN traps are GLOBAL, so an
# un-disarmed trap stays armed after backup_stack() returns and re-fires on every
# subsequent function return — notably main()'s — where the function-local $temp_dir
# is out of scope. Under the script's `set -u`, that aborts with
# "temp_dir: unbound variable" and the script exits NONZERO even though the backup
# completed (Failed: 0, archive valid). This was latent until the elevation blocker
# (#23) was fixed, because no real run had ever reached a successful backup_stack()
# return before. The fix disarms the trap as part of its own action
# (`trap 'rm -rf "$temp_dir"; trap - RETURN' RETURN`) so it fires exactly once.
#
# To exercise the bug we must reach a SUCCESSFUL backup_stack() return, which needs:
#   - a running stack (so there are containers to stop/restart), and
#   - a working elevated archive step.
# We start a tiny busybox stack for real and stub the elevation boundary: a
# transparent `sudo` on PATH plus a stub helper that just tars the standard layout.
# No real root/sudo is required.
#
# Requires: bats, docker + docker compose (present on GitHub Actions ubuntu-latest).

setup() {
    TEST_DIR="$(mktemp -d)"
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    DOCKHAND_BASE="$TEST_DIR/docker"
    APPDATA_PATH="$TEST_DIR/appdata"
    BACKUP_DEST="$TEST_DIR/backups"
    mkdir -p "$DOCKHAND_BASE" "$APPDATA_PATH" "$BACKUP_DEST"

    # A real, startable stack with real appdata content to archive. The name is made
    # unique per run so the derived docker compose project name can't collide with a
    # leftover container from an interrupted earlier run.
    STACK="temptrap-$$"
    mkdir -p "$DOCKHAND_BASE/$STACK" "$APPDATA_PATH/$STACK"
    echo "real-appdata-content" > "$APPDATA_PATH/$STACK/data.txt"
    # The bind mount into APPDATA_PATH is what makes stack_has_appdata() recognise
    # this as a backup-eligible stack (it greps the compose for APPDATA_PATH).
    cat > "$DOCKHAND_BASE/$STACK/docker-compose.yml" <<EOF
services:
  app:
    image: busybox
    command: sleep 3600
    volumes:
      - $APPDATA_PATH/$STACK:/data
EOF

    # Transparent sudo + a stub elevation helper that mimics the real helper's
    # interface: <compression> <temp_dir> <appdata_path> <stack_name> [excludes...]
    # and writes the standard-layout tar to stdout. This lets an unprivileged test
    # traverse the elevated code path (the only path that passes
    # require_privileged_or_elevated() as non-root) without real sudo.
    BIN_DIR="$TEST_DIR/bin"
    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$BIN_DIR/sudo"

    HELPER="$TEST_DIR/tar-create-stub.sh"
    cat > "$HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# args: <compression> <temp_dir> <appdata_path> <stack_name> [excludes...]
temp_dir="$2"; appdata_path="$3"; stack_name="$4"
exec tar -cf - -C "$temp_dir" . -C "$appdata_path" "$stack_name"
EOF
    chmod +x "$HELPER"

    export PATH="$BIN_DIR:$PATH"
    export DOCKHAND_BASE DOCKHAND_APPEND_HOSTNAME=false APPDATA_PATH BACKUP_DEST
    export COMPRESSION_METHOD=none
    export ELEVATION_CMD=sudo ELEVATION_HELPER_PATH="$HELPER"
    export NOTIFY_ON_SUCCESS=false NOTIFY_ON_FAILURE=false
}

teardown() {
    # Best-effort: bring the test stack down if it is still up.
    (cd "$DOCKHAND_BASE/$STACK" 2>/dev/null && docker compose down >/dev/null 2>&1) || true
    rm -rf "$TEST_DIR"
}

@test "successful backup_stack() returns exit 0 (temp_dir RETURN trap does not leak under set -u)" {
    # Start the stack for real so backup_stack() has running containers to
    # stop/restart and reaches the temp_dir trap + a successful return.
    (cd "$DOCKHAND_BASE/$STACK" && docker compose up -d)

    run bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" != *"temp_dir: unbound variable"* ]]
    [[ "$output" == *"Failed: 0"* ]]
    [[ "$output" == *"Successfully backed up: 1"* ]]

    # And the archive actually contains the real appdata content.
    archive="$(find "$BACKUP_DEST" -name "$STACK.tar" | head -n1)"
    [ -n "$archive" ]
    tar -tf "$archive" | grep -q "$STACK/data.txt"
}
