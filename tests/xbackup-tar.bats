#!/usr/bin/env bats
# x-backup declared paths reach tar as anchored, literal excludes, after the global
# EXCLUDE_PATTERNS (unanchored globs, unchanged since 0.4). Real tar on a fixture tree;
# the member lists are compared. The same checks run through the direct path
# (ELEVATION_CMD=none) and through the real root helper (ELEVATION_CMD=sudo, sudo stubbed),
# which builds its own tar command line.

load helpers/stub-env
load helpers/status
load helpers/xbackup

setup() {
    stub_env_setup
    status_setup
    xb_tree
    # The real tar helper, its appdata root pointed at the test's (as tar-create-helper.bats).
    REAL_HELPER="$TEST_DIR/docker-backup-tar-create.sh"
    sed "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA_PATH\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-tar-create.sh" > "$REAL_HELPER"
    chmod +x "$REAL_HELPER"
    # The helper wants its temp dir directly under /tmp (mktemp -d's default).
    export TMPDIR=/tmp
    export FULL_RUN_DAY=$(( $(date +%u) % 7 + 1 ))   # not today: daily runs
}

teardown() {
    stub_env_teardown
}

# archive_of <mode: direct|helper> [backup args] — runs a backup, prints the archive path.
backup_archive() {
    local mode="$1"; shift
    if [[ "$mode" == direct ]]; then
        export ELEVATION_CMD=none
        # The direct path needs root, or the run stops at the privilege check.
        run unshare -r bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh" "$@"
    else
        export ELEVATION_CMD=sudo ELEVATION_HELPER_PATH="$REAL_HELPER"
        run_backup "$@"
    fi
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    local run_id; run_id=$(js "$STATUS" 'd["run_id"]' | tr -d '"')
    ARCHIVE="$HOST_DIR/$run_id/$STACK.tar"
    [ -f "$ARCHIVE" ]
}

need_userns() {
    unshare -r true 2>/dev/null || skip "unshare -r not available (user namespaces disabled)"
}

@test "declared a/b excludes <stack>/a/b and everything under it, and nothing else (helper)" {
    xb_config '{"exclude": [{"path": "a/b", "reason": "test"}]}'
    backup_archive helper
    run members "$ARCHIVE"
    [[ "$output" != *"$STACK/a/b/"* ]]
    [[ "$output" == *"$STACK/a/bc/f"* ]]      # a sibling with the same prefix is kept
    [[ "$output" == *"$STACK/x/a/b/f"* ]]     # the same name deeper down is kept
    [[ "$output" == *"$STACK/models/blobs/sha"* ]]
}

@test "the same, through the direct path (tar run by the script itself)" {
    need_userns
    xb_config '{"exclude": [{"path": "a/b", "reason": "test"}]}'
    backup_archive direct
    run members "$ARCHIVE"
    [[ "$output" != *"$STACK/a/b/"* ]]
    [[ "$output" == *"$STACK/a/bc/f"* ]]
    [[ "$output" == *"$STACK/x/a/b/f"* ]]
}

@test "direct path and root helper produce the same member list (declared + global excludes)" {
    need_userns
    xb_config '{"exclude": [{"path": "models/blobs", "reason": "r"}], "weekly": [{"path": "idx", "reason": "r"}]}'
    export EXCLUDE_PATTERNS='clamav'
    backup_archive direct
    members "$ARCHIVE" > "$TEST_DIR/direct.list"
    rm -rf "${HOST_DIR:?}"/2*
    backup_archive helper
    members "$ARCHIVE" > "$TEST_DIR/helper.list"
    diff "$TEST_DIR/direct.list" "$TEST_DIR/helper.list"
    ! grep -q "models/blobs/" "$TEST_DIR/helper.list" || false
    ! grep -q "/idx/" "$TEST_DIR/helper.list" || false
    ! grep -q "clamav/" "$TEST_DIR/helper.list" || false
}

@test "global EXCLUDE_PATTERNS match as on 0.6.0 (unanchored), with or without declared paths" {
    # Without declarations: the 0.6.0 reference.
    # 'b' unanchored matches every member named b at any depth: a/b, x/a/b.
    cat > "$TEST_DIR/cfg.sh" <<'CFG'
EXCLUDE_PATTERNS=("b" "clamav")
CFG
    lib_tar() {   # lib_tar <out> — create_compressed_archive, direct, with EXCLUDE_PATTERNS from cfg.sh
        bash -c 'source "$1"; source "$2"; LOG_FILE=/dev/null ELEVATION_CMD=none
                 DECLARED_EXCLUDES=(); [[ -n "$4" ]] && DECLARED_EXCLUDES=("$4")
                 mkdir -p "$3.tmp"; create_compressed_archive "$3" -C "$3.tmp" . -C "$5" "$6"' \
            _ "$BATS_TEST_DIRNAME/../lib.sh" "$TEST_DIR/cfg.sh" "$1" "${2:-}" "$APPDATA_PATH" "$STACK"
    }
    lib_tar "$TEST_DIR/ref.tar"
    lib_tar "$TEST_DIR/decl.tar" models/blobs
    members "$TEST_DIR/ref.tar" > "$TEST_DIR/ref.list"
    members "$TEST_DIR/decl.tar" > "$TEST_DIR/decl.list"
    # The globals still match at any depth (unanchored): a/b and x/a/b are gone in both.
    ! grep -q "/a/b/" "$TEST_DIR/ref.list" || false
    ! grep -q "/x/a/b/" "$TEST_DIR/decl.list" || false
    ! grep -q "clamav" "$TEST_DIR/decl.list" || false
    # The declared path removed exactly models/blobs and nothing else.
    diff <(grep -v "^$STACK/models/blobs/" "$TEST_DIR/ref.list") "$TEST_DIR/decl.list"
    grep -q "^$STACK/models/blobs/" "$TEST_DIR/ref.list"
}

@test "the order matters: declared first would make the global globs anchored (why globals go first)" {
    # The naive order, run directly against tar: --anchored leaks into the globals that
    # follow, and the unanchored glob 'clamav' stops matching cache/clamav.
    local d="$TEST_DIR/naive.tar"
    tar -c --anchored --no-wildcards --exclude="$STACK/a/b" --exclude=clamav \
        -C "$APPDATA_PATH" "$STACK" > "$d"
    members "$d" | grep -q "cache/clamav/db"      # the probe fires on the naive order
    # The order the code uses: the glob still matches.
    tar -c --exclude=clamav --anchored --no-wildcards --exclude="$STACK/a/b" \
        -C "$APPDATA_PATH" "$STACK" > "$d"
    ! members "$d" | grep -q "clamav" || false
    ! members "$d" | grep -q "^$STACK/a/b/" || false
}

@test "daily run defers the weekly tier; a full run (--full) backs it up" {
    xb_config '{"exclude": [{"path": "models/blobs", "reason": "r"}], "weekly": [{"path": "idx", "reason": "r"}]}'
    backup_archive helper
    run members "$ARCHIVE"
    [[ "$output" != *"$STACK/idx/"* ]]
    [[ "$output" != *"$STACK/models/blobs/"* ]]
    [ "$(js "$STATUS" 'd["run_kind"]')" = '"daily"' ]
    rm -rf "${HOST_DIR:?}"/2*
    backup_archive helper --full
    run members "$ARCHIVE"
    [[ "$output" == *"$STACK/idx/i"* ]]
    [[ "$output" != *"$STACK/models/blobs/"* ]]
    [ "$(js "$STATUS" 'd["run_kind"]')" = '"full"' ]
}

@test "FULL_RUN_DAY = today makes the run full" {
    xb_config '{"weekly": [{"path": "idx", "reason": "r"}]}'
    export FULL_RUN_DAY=$(date +%u)
    backup_archive helper
    [ "$(js "$STATUS" 'd["run_kind"]')" = '"full"' ]
    members "$ARCHIVE" | grep -q "$STACK/idx/i"
}

@test "FULL_RUN_DAY with a leading zero (07) is the same day: compared as a number (baseline IV-60)" {
    xb_config '{"weekly": [{"path": "idx", "reason": "r"}]}'
    export FULL_RUN_DAY="0$(date +%u)"
    backup_archive helper
    [ "$(js "$STATUS" 'd["run_kind"]')" = '"full"' ]
    members "$ARCHIVE" | grep -q "$STACK/idx/i"
    # And --coverage-report, which runs before any validation, agrees.
    run_backup --coverage-report
    [[ "$output" == *'"run_kind": "full"'* ]]
}

@test "an invalid FULL_RUN_DAY stops the run (invalid-config)" {
    export FULL_RUN_DAY=8
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"FULL_RUN_DAY must be between 1 and 7"* ]]
}

@test "with no declaration the helper gets exactly 0.6.0's arguments (an old helper keeps working)" {
    xb_config
    local logging="$TEST_DIR/logging-helper.sh"
    cat > "$logging" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_DIR/helper-args"
exec tar -cf - -C "\$2" . -C "\$3" "\$4"
STUB
    chmod +x "$logging"
    export ELEVATION_CMD=sudo ELEVATION_HELPER_PATH="$logging"
    run_backup
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_DIR/helper-args")" = "$(printf 'none\n%s\n%s\n%s' "$(sed -n 2p "$TEST_DIR/helper-args")" "$APPDATA_PATH" "$STACK")" ]
}

@test "manual script: exclude tier left out, weekly tier kept (a manual backup is a full one)" {
    xb_config '{"exclude": [{"path": "models/blobs", "reason": "r"}], "weekly": [{"path": "idx", "reason": "r"}]}'
    export ELEVATION_CMD=sudo ELEVATION_HELPER_PATH="$REAL_HELPER"
    run bash "$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh" <<< $'1\ny\n'
    [ "$status" -eq 0 ]
    local archive; archive=$(find "$BACKUP_DEST" -name "$STACK.tar")
    [ -n "$archive" ]
    run members "$archive"
    [[ "$output" != *"$STACK/models/blobs/"* ]]
    [[ "$output" == *"$STACK/idx/i"* ]]
}
