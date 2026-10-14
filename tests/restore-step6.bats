#!/usr/bin/env bats
# docker-stack-restore.sh Steps 5-6: conflict check, then stop + safety copy + replace +
# start. Until 0.5.2 nothing had ever driven these steps, on a host or in a test:
#   - perform_restore's RETURN trap was never disarmed, so it fired again on main's next
#     function return (print_section "Restore Complete!") with $temp_restore out of scope:
#     "temp_restore: unbound variable", exit 1 after a successful restore (#1098).
# Steps 1-4 are answered "1, 1, 1, y"; Step 5 then sees a conflict (stack dir + appdata
# exist) and takes option 2, "Backup existing data first".

setup() {
    TEST_DIR="$(mktemp -d)"
    export BACKUP_BASE="$TEST_DIR/backups"
    export LOG_FILE="$TEST_DIR/restore.log"
    export DOCKHAND_BASE="$TEST_DIR/docker" APPDATA_PATH="$TEST_DIR/appdata"
    export DOCKHAND_APPEND_HOSTNAME=true
    export TMPDIR="$TEST_DIR/tmp" RESTORE_SAFETY_DIR="$TEST_DIR/safety"
    mkdir -p "$TMPDIR"
    SCRIPT="$BATS_TEST_DIRNAME/../docker-stack-restore.sh"
    STACK_DIR="$DOCKHAND_BASE/testhost/web"

    # Live state: what the restore replaces.
    mkdir -p "$STACK_DIR" "$APPDATA_PATH/web"
    echo old-compose > "$STACK_DIR/compose.yaml"
    echo old-data > "$APPDATA_PATH/web/data.txt"
    echo old-only > "$APPDATA_PATH/web/oldonly.txt"

    # The archive, in the layout the backup writes: compose file + .env at the root
    # (from its temp dir), then <stack>/ from APPDATA_PATH.
    local src="$TEST_DIR/src"
    mkdir -p "$src/cfg" "$src/appdata/web" "$BACKUP_BASE/testhost/20261013_020000"
    echo new-compose > "$src/cfg/compose.yaml"
    echo NEW_ENV=1 > "$src/cfg/.env"
    echo new-data > "$src/appdata/web/data.txt"
    echo new-only > "$src/appdata/web/newonly.txt"
    # Owned by 0:0, so the `unshare -r` run (only uid 0 mapped) can extract as root
    # without "Cannot change ownership"; a real root extract restores real owners.
    tar -cf "$BACKUP_BASE/testhost/20261013_020000/web.tar" --owner=0 --group=0 --numeric-owner \
        -C "$src/cfg" . -C "$src/appdata" web

    # docker stub: records each call with the appdata content at that moment, so the
    # test can tell whether `down` ran before the replace and `up -d` after it.
    export DOCKER_LOG="$TEST_DIR/docker.log"
    : > "$DOCKER_LOG"
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
data=$(cat "$APPDATA_PATH/web/data.txt" 2>/dev/null || echo none)
echo "$* data=$data" >> "$DOCKER_LOG"
[[ "$1" == compose ]] || exit 0
case "$2" in
    ps) [[ "$*" == *status=running* ]] && echo app ;;
    up) exit "${STUB_UP_RC:-0}" ;;
esac
exit 0
STUB
    chmod +x "$TEST_DIR/bin/docker"
    export PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
    rm -rf "${TEST_DIR:?}"
}

# Sources the script and runs Steps 1-6 plus main's closing print_section inside a
# function, as main does — the undisarmed trap fired when that function returned — with
# $1 as stdin. Runs unprivileged (main's root check is skipped by sourcing), so this
# also runs on CI, where the `unshare -r` test below skips.
_drive_restore() {
    run bash -c 'source "$1"
                 wizard() {
                     select_hostname; select_timestamp; select_stack; preview_backup
                     check_conflicts; perform_restore; print_section "Restore Complete!"
                 }
                 wizard
                 echo REACHED_END' _ "$SCRIPT" <<< "$1"
}

_assert_restored() {
    [ "$(cat "$APPDATA_PATH/web/data.txt")" = new-data ]
    [ -f "$APPDATA_PATH/web/newonly.txt" ]
    [ ! -e "$APPDATA_PATH/web/oldonly.txt" ]
    [ "$(cat "$STACK_DIR/compose.yaml")" = new-compose ]
    [ "$(cat "$STACK_DIR/.env")" = NEW_ENV=1 ]
}

_assert_safety_copy() {
    local copy
    copy=$(find "$RESTORE_SAFETY_DIR" -mindepth 1 -maxdepth 1 -name 'docker-restore-backup-web-*')
    [ -n "$copy" ]
    [ "$(cat "$copy/appdata/data.txt")" = old-data ]
    [ -f "$copy/appdata/oldonly.txt" ]
    [ "$(cat "$copy/stack/compose.yaml")" = old-compose ]
    [[ "$output" == *"Pre-restore copy"*"$copy"* ]] || [[ "$(cat "$LOG_FILE")" == *"$copy"* ]]
}

_assert_order() {
    # down saw the old data, up -d saw the new.
    local down_line up_line
    down_line=$(grep -n '^compose down data=old-data$' "$DOCKER_LOG" | cut -d: -f1)
    up_line=$(grep -n '^compose up -d data=new-data$' "$DOCKER_LOG" | cut -d: -f1)
    [ -n "$down_line" ] && [ -n "$up_line" ] && [ "$down_line" -lt "$up_line" ]
}

@test "Steps 5-6 complete: backup-first restore replaces config + appdata and returns 0" {
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]]
    [[ "$output" == *"REACHED_END"* ]]
    [[ "$output" == *"Stack has running containers!"* ]]
    [[ "$output" == *"Stack started successfully"* ]]
    _assert_restored
    _assert_order
    # The temp extract is gone: TMPDIR holds nothing.
    [ -z "$(ls -A "$TMPDIR")" ]
    local copy
    copy=$(find "$RESTORE_SAFETY_DIR" -mindepth 1 -maxdepth 1 -name 'docker-restore-backup-web-*')
    [ "$(cat "$copy/appdata/data.txt")" = old-data ]
    [ -f "$copy/appdata/oldonly.txt" ]
    [ "$(cat "$copy/stack/compose.yaml")" = old-compose ]
    [ "$(stat -c %a "$copy")" = 700 ]
}

@test "executed as root, main runs all six steps, logs success and exits 0" {
    if ! unshare -r true 2>/dev/null; then
        skip "unprivileged user namespaces unavailable (unshare -r)"
    fi
    run unshare -r bash "$SCRIPT" <<< $'1\n1\n1\ny\n2\ny'
    [ "$status" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]]
    grep -q 'Restore completed successfully' "$LOG_FILE"
    _assert_restored
    _assert_order
    _assert_safety_copy
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "compose up -d fails: reports the manual command and exits non-zero" {
    export STUB_UP_RC=1
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -ne 0 ]
    [[ "$output" != *"REACHED_END"* ]]
    [[ "$output" == *"Failed to start stack"* ]]
    [[ "$output" == *"cd $STACK_DIR && docker compose up -d"* ]]
    # Files are restored; only the start failed. The temp extract is still cleaned up.
    _assert_restored
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "not enough free space: fails before stopping anything, names TMPDIR" {
    # df stub: 10 bytes free everywhere (the archive members sum to more).
    cat > "$TEST_DIR/bin/df" <<'STUB'
#!/usr/bin/env bash
echo "Filesystem 1-blocks Used Available Capacity Mounted on"
echo "stubfs 1000 990 10 99% /stub"
STUB
    chmod +x "$TEST_DIR/bin/df"
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not enough space on /stub"* ]]
    [[ "$output" == *"TMPDIR"* ]]
    [[ "$output" == *"RESTORE_SAFETY_DIR"* ]]
    ! grep -q 'compose down' "$DOCKER_LOG"
    [ "$(cat "$APPDATA_PATH/web/data.txt")" = old-data ]
}

@test "corrupt archive: extract fails before the stack is stopped" {
    # Step 4 warns and the operator proceeds anyway; Step 6's extract must then fail
    # before anything is stopped or removed.
    printf 'not-a-tar-archive' > "$BACKUP_BASE/testhost/20261013_020000/web.tar"
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not extract"*"nothing was changed"* ]]
    ! grep -q 'compose down' "$DOCKER_LOG"
    [ "$(cat "$APPDATA_PATH/web/data.txt")" = old-data ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "an archive with no appdata dir leaves the live appdata in place" {
    local src="$TEST_DIR/src2"
    mkdir -p "$src"
    echo new-compose > "$src/compose.yaml"
    tar -cf "$BACKUP_BASE/testhost/20261013_020000/web.tar" -C "$src" .
    _drive_restore $'1\n1\n1\ny\n1\ny\ny'
    [ "$status" -eq 0 ]
    [[ "$output" == *"no web/ appdata directory"* ]]
    [ "$(cat "$APPDATA_PATH/web/data.txt")" = old-data ]
    [ "$(cat "$STACK_DIR/compose.yaml")" = new-compose ]
}

@test "the log file gets plain [WARNING]/[SUCCESS] lines, no colour codes" {
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -eq 0 ]
    grep -q '^\[WARNING\] Stack directory already exists' "$LOG_FILE"
    grep -q '^\[SUCCESS\] Files restored successfully' "$LOG_FILE"
    ! grep -q $'\033' "$LOG_FILE"
}

@test "safety dir that doesn't exist yet: space is checked on its future filesystem" {
    # df stub: anything under safetyfs is a small, separate filesystem; the rest is big.
    # Like the real df, it fails on a path that doesn't exist.
    mkdir -p "$TEST_DIR/safetyfs"
    export RESTORE_SAFETY_DIR="$TEST_DIR/safetyfs/not/yet/created"
    cat > "$TEST_DIR/bin/df" <<'STUB'
#!/usr/bin/env bash
[[ -e "${*: -1}" ]] || { echo "df: ${*: -1}: No such file or directory" >&2; exit 1; }
echo "Filesystem 1-blocks Used Available Capacity Mounted on"
case "${*: -1}" in
    */safetyfs|*/safetyfs/*) echo "small 1000 990 10 99% /safetyfs" ;;
    *) echo "big 1000000000 0 1000000000 0% /big" ;;
esac
STUB
    chmod +x "$TEST_DIR/bin/df"
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not enough space on /safetyfs"* ]]
    ! grep -q 'compose down' "$DOCKER_LOG"
    [ "$(cat "$APPDATA_PATH/web/data.txt")" = old-data ]
}

@test "a restored compose file is not shadowed by a leftover higher-priority name" {
    # Archive has docker-compose.yml; the live stack has compose.yaml, which compose
    # would otherwise pick first.
    local src="$TEST_DIR/src3"
    mkdir -p "$src/cfg" "$src/appdata/web"
    echo new-compose > "$src/cfg/docker-compose.yml"
    echo new-data > "$src/appdata/web/data.txt"
    tar -cf "$BACKUP_BASE/testhost/20261013_020000/web.tar" --owner=0 --group=0 --numeric-owner \
        -C "$src/cfg" . -C "$src/appdata" web
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -eq 0 ]
    [ "$(cat "$STACK_DIR/docker-compose.yml")" = new-compose ]
    [ ! -e "$STACK_DIR/compose.yaml" ]
    # The old file survives in the safety copy.
    [ "$(cat "$RESTORE_SAFETY_DIR"/docker-restore-backup-web-*/stack/compose.yaml)" = old-compose ]
}

@test "symlinks in the archive are not followed, and not written through at the destination" {
    # Archive: compose.yaml -> a file outside (as root this could be /etc/shadow), and
    # web -> a dir outside. Live stack dir: .env is a symlink to another outside file.
    echo top-secret > "$TEST_DIR/secret"
    mkdir -p "$TEST_DIR/outside-dir" && echo outside > "$TEST_DIR/outside-dir/x"
    echo victim > "$TEST_DIR/victim"
    ln -s "$TEST_DIR/victim" "$STACK_DIR/.env"
    local src="$TEST_DIR/src4"
    mkdir -p "$src"
    ln -s "$TEST_DIR/secret" "$src/compose.yaml"
    echo NEW_ENV=1 > "$src/.env"
    ln -s "$TEST_DIR/outside-dir" "$src/web"
    tar -cf "$BACKUP_BASE/testhost/20261013_020000/web.tar" --owner=0 --group=0 --numeric-owner -C "$src" .
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Not restoring compose.yaml: it is a symlink in the archive"* ]]
    # The secret was not copied in, and the old compose file was left alone.
    [ "$(cat "$STACK_DIR/compose.yaml")" = old-compose ]
    ! grep -rq top-secret "$STACK_DIR" "$APPDATA_PATH"
    # .env replaced the destination symlink instead of writing through it.
    [ ! -L "$STACK_DIR/.env" ]
    [ "$(cat "$STACK_DIR/.env")" = NEW_ENV=1 ]
    [ "$(cat "$TEST_DIR/victim")" = victim ]
    # The appdata symlink member did not replace the live appdata.
    [ ! -L "$APPDATA_PATH/web" ]
    [ "$(cat "$APPDATA_PATH/web/data.txt")" = old-data ]
}
