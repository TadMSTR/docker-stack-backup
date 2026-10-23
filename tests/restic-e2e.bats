#!/usr/bin/env bats
# The REAL restic helper end to end, under `unshare -r -m` (local only: needs user
# namespaces and a restic binary; see helpers/restic.bash). docker-stack-backup.sh runs as
# namespace root with ELEVATION_CMD=none, so tar is made by lib.sh and restic by the
# helper, from the same source, in one run.
#
# Plan p5b, Verification:
#   1. tar and restic include and exclude exactly the same files, for every declared-path
#      case of xbackup-tar.bats and the global EXCLUDE_PATTERNS; a naive (unanchored)
#      restic exclude is shown to break that first
#   2. `restic dump` gives the tar archive's member list (names, types, modes, owners), and
#      the restore wizard restores a stack from it through Steps 4-6

load helpers/stub-env
load helpers/status
load helpers/xbackup
load helpers/restic

setup() {
    stub_env_setup
    status_setup
    export TMPDIR=/tmp
    export FULL_RUN_DAY=$(( $(date +%u) % 7 + 1 ))   # not today: daily unless --full
    RH_APPDATA="$APPDATA_PATH" RH_STACK="$STACK"
    rh_setup_ns
    export ELEVATION_CMD=none RESTIC_HELPER_PATH="$RH" BACKENDS="tar restic"
    unset ELEVATION_HELPER_PATH
}

teardown() {
    rh_teardown
    stub_env_teardown
}

# ns_backup [args] — the backup as namespace root; sets ARCHIVE.
ns_backup() {
    rm -rf "${HOST_DIR:?}"/2*
    run unshare -r -m bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh" "$@"
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    ARCHIVE=$(find "$HOST_DIR" -name "$STACK.tar")
    [ -n "$ARCHIVE" ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["result"]')" = '"ok"' ]
}

# Member paths, normalised: no leading ./ or /, no trailing /, no root entry.
tar_paths() {
    tar -tf "$1" | sed -e 's|^\./||' -e 's|/$||' | grep -v '^\.\?$' | sort
}
restic_paths() {
    rh_restic ls latest --host "$RH_HOST" | tail -n +2 | sed 's|^/||' | sort
}

# parity — the two lists must be equal; prints the difference otherwise.
parity() {
    tar_paths "$ARCHIVE" > "$TEST_DIR/tar.list"
    restic_paths > "$TEST_DIR/restic.list"
    diff "$TEST_DIR/tar.list" "$TEST_DIR/restic.list"
}

@test "V1 probe: a naive restic helper (declared paths unanchored) excludes x/a/b too, where tar keeps it" {
    xb_tree
    xb_config '{"exclude": [{"path": "a/b", "reason": "test"}]}'
    # Naive: --exclude <path> as given, the obvious translation of tar's --exclude.
    sed -i 's|exclude_args+=(--exclude "\$RESTIC_STAGE_DIR/\$stack/\$rel")|exclude_args+=(--exclude "$rel")|' "$RH"
    grep -q 'exclude_args+=(--exclude "$rel")' "$RH"
    ns_backup
    ! parity
    grep -q "^$STACK/x/a/b/f$" "$TEST_DIR/tar.list"
    ! grep -q "^$STACK/x/a/b/f$" "$TEST_DIR/restic.list"
}

@test "V1: tar and restic leave out exactly the same files, for every declared-path and global-pattern case" {
    xb_tree
    echo log > "$APPDATA_PATH/$STACK/x/run.log"
    local cases=(
        '{"exclude": [{"path": "a/b", "reason": "r"}]}|'
        '{"exclude": [{"path": "models/blobs", "reason": "r"}], "weekly": [{"path": "idx", "reason": "r"}]}|'
        '{"exclude": [{"path": "models/blobs", "reason": "r"}], "weekly": [{"path": "idx", "reason": "r"}]}|--full'
        '{"exclude": [{"path": "models/blobs", "reason": "r"}]}|b'
        '|clamav'
        '{"exclude": [{"path": "cache", "reason": "r"}, {"path": "a/bc/f", "reason": "r"}]}|*.log'
        '|cache/clamav'
        '|'
    )
    local c xb rest
    for c in "${cases[@]}"; do
        xb="${c%%|*}" rest="${c#*|}"
        xb_config "$xb"
        if [[ "$rest" == --full ]]; then
            unset EXCLUDE_PATTERNS
            ns_backup --full
        else
            # An empty string would be one empty pattern, which both helpers refuse.
            if [[ -n "$rest" ]]; then export EXCLUDE_PATTERNS="$rest"; else unset EXCLUDE_PATTERNS; fi
            ns_backup
        fi
        echo "case: x-backup=${xb:-none} ${rest:+($rest)}: $(wc -l < <(tar_paths "$ARCHIVE")) members" >&3
        parity
    done
}

# tv <stream on stdin> — `tar -tv` lines without the date and time (the staged compose
# file and .env are copied at different moments for the two backends), normalised.
tv() {
    tar --numeric-owner -tvf - | awk '{ $4 = ""; $5 = ""; print }' \
        | sed -E -e 's| \./| |' -e 's|/$||' -e 's|/ ->| ->|' | grep -vE ' \.?$' | sort -k4
}

@test "V2: restic dump has the tar archive's member layout (names, types, modes, owners, sizes)" {
    local a="$APPDATA_PATH/$STACK"
    mkdir -p "$a/db/pages" "$a/conf"
    printf 'secret\n' > "$a/db/key"; chmod 0600 "$a/db/key"; chmod 0700 "$a/db"
    head -c 70000 /dev/urandom > "$a/db/pages/p1"
    echo "listen 80" > "$a/conf/site.conf"
    ln -s conf/site.conf "$a/current"
    echo "PW=x" > "$DOCKHAND_BASE/$STACK/.env"; chmod 0600 "$DOCKHAND_BASE/$STACK/.env"
    ns_backup
    tv < "$ARCHIVE" > "$TEST_DIR/tar.tv"
    local id; id=$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["snapshot_id"]' | tr -d '"')
    unshare -r -m bash "$RH" dump "$STACK" "$id" | tv > "$TEST_DIR/dump.tv"
    cat "$TEST_DIR/dump.tv" >&3
    diff "$TEST_DIR/tar.tv" "$TEST_DIR/dump.tv"
    grep -q '^-rw------- 0/0 5 *\.env$' "$TEST_DIR/dump.tv"
    grep -q "^lrwxrwxrwx 0/0 0 *$STACK/current -> conf/site.conf$" "$TEST_DIR/dump.tv"
    grep -q "^drwx------ 0/0 0 *$STACK/db$" "$TEST_DIR/dump.tv"
}

@test "V2: the restore wizard restores a stack from a restic snapshot (Steps 0-6, the same Step 4-6 code)" {
    local a="$APPDATA_PATH/$STACK"
    mkdir -p "$a/db"
    printf 'state A\n' > "$a/db/page"; chmod 0600 "$a/db/page"
    ln -s db/page "$a/link"
    ns_backup
    local manifest_a; manifest_a=$(cd "$a" && find . -printf '%P %m %y %l %s\n' | sort)
    # State B: what the restore replaces.
    printf 'state B, longer\n' > "$a/db/page"
    echo added > "$a/added"
    echo "services: {changed: {}}" > "$DOCKHAND_BASE/$STACK/docker-compose.yml"
    : > "$DOCKER_LOG"
    export LOG_FILE="$TEST_DIR/restore.log"
    # Source 2 (restic), stack 1, snapshot 1, Proceed y, overwrite (1) + sure y, start n.
    run unshare -r -m bash -c 'source "$1"
        select_source; select_restic_snapshot; preview_backup; check_conflicts; perform_restore
        echo REACHED_END' _ "$BATS_TEST_DIRNAME/../docker-stack-restore.sh" <<< $'2\n1\n1\ny\n1\ny\nn\n'
    echo "$output" >&3
    [ "$status" -eq 0 ]
    [[ "$output" == *REACHED_END* ]]
    [[ "$output" == *"restic snapshots of this host"* ]]
    [ "$(cd "$a" && find . -printf '%P %m %y %l %s\n' | sort)" = "$manifest_a" ]
    [ "$(cat "$DOCKHAND_BASE/$STACK/docker-compose.yml")" = "$(cat "$TEST_DIR/../$(basename "$TEST_DIR")/docker/$STACK/docker-compose.yml")" ]
    grep -q "$APPDATA_PATH/$STACK:/data" "$DOCKHAND_BASE/$STACK/docker-compose.yml"
    # Extract before down: the stub saw `compose down` only after the extract succeeded.
    grep -q 'compose down' "$DOCKER_LOG"
}

@test "V2 negative: a dump that fails (unknown snapshot) changes nothing and stops nothing" {
    ns_backup
    : > "$DOCKER_LOG"
    export LOG_FILE="$TEST_DIR/restore.log"
    run unshare -r -m bash -c 'source "$1"
        restore_source=restic selected_stack="$2" selected_hostname="$(hostname)"
        selected_restic_id=$(printf "ab%.0s" {1..32})
        restore_mode=overwrite
        perform_restore' _ "$BATS_TEST_DIRNAME/../docker-stack-restore.sh" "$STACK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing was changed"* ]]
    ! grep -q 'compose down' "$DOCKER_LOG"
    [ "$(cat "$APPDATA_PATH/$STACK/data.txt")" = appdata-content ]
}
