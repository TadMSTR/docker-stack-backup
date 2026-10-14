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

@test "an archive filename with a literal \\n cannot forge a log line (audit p3a F-02)" {
    local src="$TEST_DIR/src5" name='web\n[2026-10-14 03:00:00] FORGED Restore completed successfully'
    mkdir -p "$src"
    echo forged-compose > "$src/compose.yaml"
    # Alone in the newest run dir, so it is backup 1, stack 1. Step 3 refuses the name
    # (F-04) and logs it in the error; that line must stay one line (F-02).
    mkdir -p "$BACKUP_BASE/testhost/20261014_020000"
    tar -cf "$BACKUP_BASE/testhost/20261014_020000/$name.tar" -C "$src" .
    _drive_restore $'1\n1\n1\ny\nn'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing stack name"* ]]
    grep -qF "[ERROR] Refusing stack name $(printf '%q' "$name")" "$LOG_FILE"
    ! grep -q '^\[2026-10-14 03:00:00\] FORGED' "$LOG_FILE"
    ! grep -q '^\[2026-10-14 03:00:00\] FORGED' <<< "$output"
}

@test "log_* print the message as data: a literal \\n in a message stays one line (F-02)" {
    run bash -c 'source "$1"; LOG_FILE="$2"; log_warning "a\\nb \\033[31m"' \
        _ "$BATS_TEST_DIRNAME/../lib.sh" "$LOG_FILE"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$LOG_FILE")" -eq 1 ]
    grep -qxF '[WARNING] a\nb \033[31m' "$LOG_FILE"
}

@test "Step 3 refuses a stack name outside [A-Za-z0-9._-] (audit p3a F-04)" {
    mkdir -p "$BACKUP_BASE/testhost/20261014_020000"
    : > "$BACKUP_BASE/testhost/20261014_020000/we b.tar"
    _drive_restore $'1\n1\n1'
    [ "$status" -eq 1 ]
    [[ "$output" == *'Refusing stack name we\ b'* ]]
    ! grep -q 'compose down' "$DOCKER_LOG"
}

@test "Step 4 flags setuid and device/pipe members before Proceed (audit p3a F-03)" {
    local src="$TEST_DIR/src6"
    mkdir -p "$src/web"
    echo x > "$src/web/tool" && chmod 4755 "$src/web/tool"
    mkfifo "$src/web/fifo"
    echo y > "$src/web/plain"
    tar -cf "$BACKUP_BASE/testhost/20261013_020000/web.tar" -C "$src" web
    _drive_restore $'1\n1\n1\nn'
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 member(s) are setuid/setgid or device/pipe/socket entries"* ]]
    [[ "$output" == *"web/tool"* ]]
    [[ "$output" == *"web/fifo"* ]]
    [[ "$output" == *"Restore cancelled."* ]]
}

@test "space check refuses an archive declaring 19+ digits of size (audit p3a F-05)" {
    run bash -c 'source "$1"; selected_backup_file=/dev/null; restore_mode=clean
                 archive_extract_bytes=9223372036854775808
                 check_restore_space /nonexistent/stack /nonexistent/appdata /tmp' _ "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"implausible total size"* ]]
}

@test "symlinked appdata is flagged at Step 5; default safety copy is called temporary (F-06)" {
    mv "$APPDATA_PATH/web" "$TEST_DIR/real-web"
    ln -s "$TEST_DIR/real-web" "$APPDATA_PATH/web"
    unset RESTORE_SAFETY_DIR
    _drive_restore $'1\n1\n1\ny\n2\ny'
    [ "$status" -eq 0 ]
    [[ "$output" == *"is a symlink (-> $TEST_DIR/real-web)"* ]]
    [[ "$output" == *"which is cleaned up"* ]]
    # The target is untouched; the link became a real dir holding the restored data.
    [ "$(cat "$TEST_DIR/real-web/data.txt")" = old-data ]
    [ ! -L "$APPDATA_PATH/web" ]
    [ "$(cat "$APPDATA_PATH/web/data.txt")" = new-data ]
}

# Raw control bytes (a real LF or ESC, not a backslash sequence) in names on the share:
# printf %s passed them through, so the refusal message and the list lines could still
# forge a root log line or drive the terminal (audit p3a round 2, R2-01).
_assert_no_raw_control() {
    ! grep -q $'\033' "$LOG_FILE"
    ! grep -q '^\[2026-10-14 03:00:00\] FORGED' "$LOG_FILE"
    ! grep -q '^\[2026-10-14 03:00:00\] FORGED' <<< "$output"
    # The only ESC bytes on the terminal are our own colour codes.
    ! grep -q $'\033\\[2J\\|\033\\]0;' <<< "$output"
}

@test "a stack archive name with a real LF and ESC: refused, no forged line, no raw ESC (R2-01)" {
    local name=$'web\n[2026-10-14 03:00:00] FORGED Restore completed successfully\033[2J'
    mkdir -p "$BACKUP_BASE/testhost/20261014_020000"
    : > "$BACKUP_BASE/testhost/20261014_020000/$name.tar"
    _drive_restore $'1\n1\n1'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing stack name"* ]]
    _assert_no_raw_control
}

@test "a host dir with a real LF and ESC: refused, no forged line, no raw ESC (R2-01)" {
    rm -rf "${BACKUP_BASE:?}"/*
    mkdir -p "$BACKUP_BASE/"$'forge\033[2J\n[2026-10-14 03:00:00] FORGED'"/20261013_020000"
    _drive_restore $'1'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing host name"* ]]
    _assert_no_raw_control
}

@test "a timestamp dir that isn't YYYYMMDD_HHMMSS is refused before it reaches a path or the log (R2-01)" {
    rm -rf "${BACKUP_BASE:?}/testhost"/*
    mkdir -p "$BACKUP_BASE/testhost/"$'20261014_020000\033]0;pwned\a\033[1A'
    _drive_restore $'1\n1\n1'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing backup dir"*"expected YYYYMMDD_HHMMSS"* ]]
    [[ "$output" != *"Selected backup"* ]]
    _assert_no_raw_control
}

@test "name check is ASCII-only in a UTF-8 locale (R2-02)" {
    locale -a 2>/dev/null | grep -qi '^\(en_US\|C\)\.utf-\?8$' || skip "no UTF-8 locale installed"
    local loc; loc=$(locale -a | grep -i '^en_US\.utf-\?8$' | head -1); loc=${loc:-C.UTF-8}
    mkdir -p "$BACKUP_BASE/testhost/20261014_020000"
    : > "$BACKUP_BASE/testhost/20261014_020000/café.tar"
    LC_ALL="$loc" _drive_restore $'1\n1\n1'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing stack name"* ]]
}

@test "Step 4 makes archive owner/group names printable (round 3 F-03)" {
    # GNU tar -tv escapes member names but prints owner names raw.
    local src="$TEST_DIR/src7"
    mkdir -p "$src/web"
    echo x > "$src/web/tool" && chmod 4755 "$src/web/tool"
    tar -cf "$BACKUP_BASE/testhost/20261013_020000/web.tar" -C "$src" \
        --owner=$'ev\033]0;PWN\a\033[2Jil:0' --group=$'g\033[1A:0' web
    _drive_restore $'1\n1\n1\nn'
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 member(s) are setuid/setgid"* ]]
    ! grep -q $'\033\\]0;\\|\033\\[2J\\|\033\\[1A' <<< "$output"
}

@test "printable replaces UTF-8 C1 controls in a C locale, keeps — and é (round 3 F-04)" {
    run env LC_ALL=C bash -c 'source "$1"; printable "a$(printf "\xc2\x9b")b — é"' _ "$BATS_TEST_DIRNAME/../lib.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "a?b — é" ]
}

@test "Step 3 only offers the archive suffixes the backup writes (round 3 F-05)" {
    : > "$BACKUP_BASE/testhost/20261013_020000/odd.tar.weird"
    _drive_restore $'1\n1\n1\nn'
    [ "$status" -eq 0 ]
    [[ "$output" != *"odd"* ]]
    [[ "$output" == *"Selected stack: "*"web"* ]]
}

@test "Step 4 lists numeric owners: a multi-line PAX owner name can't forge the preview (round 4 R4-01)" {
    # Python tarfile: GNU tar's --owner can't take the ':' these fake lines need.
    python3 -I - "$BACKUP_BASE/testhost/20261013_020000/web.tar" <<'PY'
import io, sys, tarfile
fake = "root" + "".join(f"\n-rw-r--r-- root/root 1 2026-10-13 02:00 ./config/fake{i:02d}.yml" for i in range(22))
with tarfile.open(sys.argv[1], "w", format=tarfile.PAX_FORMAT) as t:
    for name, data, uname in (("web/config/real.yml", b"real\n", fake), ("web/b", b"b\n", "root")):
        ti = tarfile.TarInfo(name); ti.size = len(data); ti.uname = uname; ti.gname = "root"
        t.addfile(ti, io.BytesIO(data))
PY
    _drive_restore $'1\n1\n1\nn'
    [ "$status" -eq 0 ]
    [[ "$output" != *"fake00.yml"* ]]
    [[ "$output" == *"web/config/real.yml"* ]]
    [[ "$output" != *"more files"* ]]
}
