#!/usr/bin/env bats
# Tests for DSBAK-8: docker-stack-backup.sh must not abort under `set -e` when
# DOCKHAND_BASE contains a non-stack entry (a directory with no compose file) —
# e.g. forge's real ~/docker/_archive/. Regression: bare `compose_file=$(find_compose_file
# ...)` assignments (find_compose_file legitimately returns 1 for "no compose file",
# not an error) tripped `set -e` and killed the whole script before the very next line's
# `[[ -z "$compose_file" ]]` check ever ran — so every stack alphabetically after the
# first non-stack entry was silently never processed.
#
# The compose project here is never started (`docker compose up` is never called), so
# these tests need no image pull — `docker compose ps` against an unstarted project
# returns empty with exit 0, which is all backup_stack()/simulate_backup_stack() need to
# reach and correctly skip/report the stack (proving the LOOP reached it, which is the
# actual regression under test).
#
# Requires: bats, docker + docker compose (present on GitHub Actions ubuntu-latest and
# this dev environment)

setup() {
    TEST_DIR="$(mktemp -d)"
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    DOCKHAND_BASE="$TEST_DIR/docker"
    APPDATA_PATH="$TEST_DIR/appdata"
    BACKUP_DEST="$TEST_DIR/backups"
    mkdir -p "$DOCKHAND_BASE" "$APPDATA_PATH" "$BACKUP_DEST"

    # Non-stack entry — no compose file at all, matching forge's real _archive/ case.
    mkdir -p "$DOCKHAND_BASE/_archive"
    touch "$DOCKHAND_BASE/_archive/readme.txt"

    # A real stack, alphabetically AFTER the non-stack entry, so a premature abort on
    # _archive would prevent this stack from ever being reached — reproduces the exact
    # ordering forge hit (its first non-stack entry sorted before later real stacks).
    mkdir -p "$DOCKHAND_BASE/zzz-realstack" "$APPDATA_PATH/zzz-realstack"
    touch "$APPDATA_PATH/zzz-realstack/data.txt"
    cat > "$DOCKHAND_BASE/zzz-realstack/docker-compose.yml" <<EOF
services:
  app:
    image: busybox
    command: sleep 3600
EOF

    export DOCKHAND_BASE DOCKHAND_APPEND_HOSTNAME=false APPDATA_PATH BACKUP_DEST
    # ELEVATION_CMD=sudo only to pass require_privileged_or_elevated() while running
    # these tests unprivileged (see DSBAK-6) — no real elevation is ever exercised,
    # since neither test reaches create_compressed_archive() (the compose project is
    # never started, so backup_stack() exits at "no running containers" first).
    export ELEVATION_CMD=sudo COMPRESSION_METHOD=none
    export NOTIFY_ON_SUCCESS=false NOTIFY_ON_FAILURE=false
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "--dry-run processes the real stack past a non-stack entry (does not abort early)" {
    run bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"zzz-realstack"* ]]
    [[ "$output" == *"DRY RUN COMPLETE"* ]]
}

@test "real run reaches and processes the real stack past a non-stack entry (does not abort early)" {
    run bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh"
    [ "$status" -eq 0 ]
    # The compose project is never started, so backup_stack() correctly skips it
    # ("no running containers") — the point under test is that the loop REACHED it
    # at all, past the _archive non-stack entry, rather than aborting on _archive.
    [[ "$output" == *"Processing stack: zzz-realstack"* ]]
    [[ "$output" == *"Backup Summary"* ]]
}
