#!/usr/bin/env bats
# #1089: restore and verify, run as root, read the backup share AS ITS OWNER, so 0600
# archives in 0700 run dirs stay readable on an NFS export with root squash (plan p5b,
# Verification 7).
#
# A real squashed export needs a second uid, which an unprivileged `unshare -r` cannot map
# (p5c verifies it as real root: RESTIC.md "Verify as root"). Here, as namespace root:
#   - a `stat` shim says the share belongs to uid 4242 (a non-root owner)
#   - a `setpriv` shim logs the uid it was asked for and runs the command marked "as owner"
#   - cat/find/du/tar/stat shims log every call that names a share path WITHOUT that mark
# so the test sees every direct root read of the share. The probe fires first: v0.7.0's
# restore and verify (from git) read the share directly.

setup() {
    unshare -r true 2>/dev/null || skip "unshare -r not available (user namespaces disabled)"
    TEST_DIR="$(mktemp -d)"
    export BACKUP_BASE="$TEST_DIR/backups"
    export LOG_FILE="$TEST_DIR/restore.log"
    export DOCKHAND_BASE="$TEST_DIR/docker" APPDATA_PATH="$TEST_DIR/appdata"
    export DOCKHAND_APPEND_HOSTNAME=true
    export TMPDIR="$TEST_DIR/tmp" RESTORE_SAFETY_DIR="$TEST_DIR/safety"
    mkdir -p "$TMPDIR" "$DOCKHAND_BASE/testhost/web" "$APPDATA_PATH/web"
    echo old > "$APPDATA_PATH/web/data.txt"
    echo old-compose > "$DOCKHAND_BASE/testhost/web/compose.yaml"

    # The share as 0.8.0 writes it: 0700 dirs, 0600 archives.
    local src="$TEST_DIR/src" run="$BACKUP_BASE/testhost/20261023_020001"
    mkdir -p "$src/cfg" "$src/appdata/web" "$run"
    echo new-compose > "$src/cfg/compose.yaml"
    echo new > "$src/appdata/web/data.txt"
    tar -czf "$run/web.tar.gz" --owner=0 --group=0 --numeric-owner -C "$src/cfg" . -C "$src/appdata" web
    chmod 0700 "$BACKUP_BASE/testhost" "$run"
    chmod 0600 "$run/web.tar.gz"

    SHIM="$TEST_DIR/shim"
    mkdir -p "$SHIM"
    export SHARE_LOG="$TEST_DIR/share.log"
    : > "$SHARE_LOG"
    cat > "$SHIM/setpriv" <<'STUB'
#!/usr/bin/env bash
uid=""
while [[ $# -gt 0 && "$1" != -- ]]; do
    [[ "$1" == --reuid=* ]] && uid="${1#--reuid=}"
    shift
done
shift
echo "setpriv uid=$uid $*" >> "$SHARE_LOG"
DSB_AS_OWNER=1 exec "$@"
STUB
    local c
    for c in cat find du tar stat; do
        cat > "$SHIM/$c" <<STUB
#!/usr/bin/env bash
real=\$(PATH=/usr/bin:/bin command -v $c)
if [[ "\${DSB_AS_OWNER:-}" != 1 && "\$*" == *"\$BACKUP_BASE"* ]]; then
    echo "direct $c \$*" >> "\$SHARE_LOG"
fi
# The share belongs to uid 4242: what stat -c '%u:%g' reports for it.
if [[ "$c" == stat && "\$*" == *"%u:%g -- \$BACKUP_BASE"* ]]; then echo 4242:4242; exit 0; fi
exec "\$real" "\$@"
STUB
    done
    # docker: nothing runs; the conflict check and the restore just need answers.
    cat > "$SHIM/docker" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$SHIM"/*
    export PATH="$SHIM:$PATH"
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() {
    # setup may have skipped before TEST_DIR was set: a failing teardown makes bats drop
    # the tests from its count instead of reporting them skipped.
    [[ -n "${TEST_DIR:-}" ]] || return 0
    rm -rf -- "$TEST_DIR"
}

# restore_steps <script dir> — Steps 1-6 as namespace root, answers 1,1,1,y,1,y,n.
restore_steps() {
    run unshare -r bash -c 'source "$1/docker-stack-restore.sh"
        select_hostname; select_timestamp; select_stack; preview_backup
        check_conflicts; perform_restore' _ "$1" <<< $'1\n1\n1\ny\n1\ny\nn\n'
}

# Direct root accesses to the share, except the one by design: `stat -c %u:%g` of
# BACKUP_BASE or the host dir, which only learns whose uid to read as. A stat needs search
# permission on the parent only, which a squashed root still has on the share (775).
direct_reads() {
    grep '^direct ' "$SHARE_LOG" | grep -v "^direct stat -c %u:%g -- $BACKUP_BASE\(/[^/]*\)\?\$" || true
}

# plain_line <exact line> — $output, colour codes removed, has that exact line (CR-11/13:
# a wildcard match let the digit in a later ESC[0;31m stand in for the count).
plain_line() {
    sed 's/\x1b\[[0-9;]*m//g' <<< "$output" | grep -qx -- "$1"
}

@test "probe: v0.7.0's restore reads the share directly as root" {
    git -C "$REPO" cat-file -e v0.7.0 2>/dev/null || skip "v0.7.0 not in this checkout"
    local old="$TEST_DIR/v070"
    mkdir -p "$old"
    git -C "$REPO" show v0.7.0:docker-stack-restore.sh > "$old/docker-stack-restore.sh"
    git -C "$REPO" show v0.7.0:lib.sh > "$old/lib.sh"
    restore_steps "$old"
    echo "$output" >&3
    [ -n "$(direct_reads)" ]                       # fires: tar -tvf / find as root
    direct_reads | grep -q '^direct tar .*web.tar.gz'
}

@test "restore: every read of the share runs as the share's owner; the restore completes" {
    restore_steps "$REPO"
    echo "$output" >&3
    [ "$status" -eq 0 ]
    [ "$(cat "$APPDATA_PATH/web/data.txt")" = new ]
    [ "$(cat "$DOCKHAND_BASE/testhost/web/compose.yaml")" = new-compose ]
    [ -z "$(direct_reads)" ] || { direct_reads >&2; false; }
    grep -q '^setpriv uid=4242 cat -- .*web.tar.gz' "$SHARE_LOG"
    grep -q '^setpriv uid=4242 find .*/backups/testhost ' "$SHARE_LOG"
    # The extract itself ran as root (tar -x reads stdin): restored owners are kept.
    ! grep -q '^setpriv .* tar ' "$SHARE_LOG" || false
}

@test "probe then fix: verify --list/--verify/--stats read the share as its owner (v0.7.0 read it as root)" {
    if git -C "$REPO" cat-file -e v0.7.0 2>/dev/null; then
        local old="$TEST_DIR/v070"
        mkdir -p "$old"
        git -C "$REPO" show v0.7.0:backup-verify.sh > "$old/backup-verify.sh"
        git -C "$REPO" show v0.7.0:lib.sh > "$old/lib.sh"
        run unshare -r bash "$old/backup-verify.sh" --verify
        [ -n "$(direct_reads)" ]                   # fires
        : > "$SHARE_LOG"
    fi
    local mode
    for mode in --list --verify --stats; do
        run unshare -r bash "$REPO/backup-verify.sh" "$mode"
        echo "$output" >&3
        [ "$status" -eq 0 ]
    done
    [ -z "$(direct_reads)" ] || { direct_reads >&2; false; }
    grep -q '^setpriv uid=4242 tar -tf .*web.tar.gz' "$SHARE_LOG"
    run unshare -r bash "$REPO/backup-verify.sh" --verify
    plain_line "Valid: 1"
}

@test "as_owner_of runs as is for a non-root caller, and for a root-owned path" {
    run bash -c 'source "$1/lib.sh"; as_owner_of "$2" echo plain' _ "$REPO" "$BACKUP_BASE"
    [ "$output" = plain ]
    ! grep -q '^setpriv' "$SHARE_LOG" || false
    run unshare -r bash -c 'source "$1/lib.sh"; as_owner_of "$2" echo rootowned' _ "$REPO" "$TEST_DIR/src"
    [ "$output" = rootowned ]
    ! grep -q '^setpriv' "$SHARE_LOG" || false
}
