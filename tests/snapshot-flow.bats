#!/usr/bin/env bats
# Snapshot-assisted backup (0.7.0), end to end: docker-stack-backup.sh with the REAL
# snapshot helper and the REAL tar helper (constants pointed at the test), btrfs/zfs
# shimmed (helpers/snapshot), docker stubbed (helpers/stub-env). sudo is a logging stub,
# and docker, btrfs and sudo all write to one log, so the order of operations can be
# asserted: check -> stop -> snapshot -> start -> archive from the snapshot -> delete.

load helpers/stub-env
load helpers/status
load helpers/snapshot

setup() {
    stub_env_setup
    status_setup
    snap_setup btrfs
    export TMPDIR=/tmp
    # One ordered log for everything.
    export SNAP_LOG="$DOCKER_LOG"

    # The stack's appdata moves under the fake subvolume.
    export APPDATA_PATH="$SNAP_APPDATA"
    rm -rf "${SNAP_APPDATA:?}/st"
    mkdir -p "$APPDATA_PATH/$STACK"
    echo "appdata-content" > "$APPDATA_PATH/$STACK/data.txt"
    sed -i "s|- .*:/data|- $APPDATA_PATH/$STACK:/data|" "$DOCKHAND_BASE/$STACK/docker-compose.yml"
    cat > "$STUB_CONFIG_DIR/$STACK.json" <<JSON
{"name": "$STACK", "services": {
  "app": {"image": "busybox", "volumes": [
    {"type": "bind", "source": "$APPDATA_PATH/$STACK", "target": "/data", "bind": {}}]},
  "worker": {"image": "busybox"}}}
JSON

    TAR_HELPER="$SNAP_T/docker-backup-tar-create.sh"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA_PATH\"|" \
        -e "s|^SNAPSHOT_HELPER=.*|SNAPSHOT_HELPER=\"$SNAP_HELPER\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-tar-create.sh" > "$TAR_HELPER"
    chmod +x "$TAR_HELPER"

    # sudo: log, optionally signal the backup script while it archives from the
    # snapshot, optionally fail that archive; then run the command.
    cat > "$BIN_DIR/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo ${1##*/} ${*:2}" >> "$DOCKER_LOG"
if [[ "$*" == *--from-snapshot* ]]; then
    if [[ -n "${STUB_SIGNAL_ON_ARCHIVE:-}" ]]; then
        p=$PPID target=""
        while [[ "$p" -gt 1 ]]; do
            arg1=$(tr '\0' '\n' < "/proc/$p/cmdline" | sed -n 2p)
            if [[ "$arg1" =~ docker-stack-backup\.sh$ ]]; then target=$p; elif [[ -n "$target" ]]; then break; fi
            p=$(awk '{print $4}' "/proc/$p/stat")
        done
        for sig in $STUB_SIGNAL_ON_ARCHIVE; do kill -"$sig" "$target"; sleep 0.2; done
    fi
    [[ "${STUB_ARCHIVE_FAIL:-0}" == 1 ]] && exit 1
fi
exec "$@"
STUB
    chmod +x "$BIN_DIR/sudo"

    export PATH="$SNAP_SHIM:$PATH"
    export ELEVATION_CMD=sudo ELEVATION_HELPER_PATH="$TAR_HELPER"
    export SNAPSHOT_BACKEND=btrfs SNAPSHOT_HELPER_PATH="$SNAP_HELPER"
    export PROM_TEXTFILE_DIR="$TEST_DIR/prom"
    mkdir -p "$PROM_TEXTFILE_DIR"
    PROM="$PROM_TEXTFILE_DIR/docker_stack_backup.prom"
}

teardown() {
    stub_env_teardown
}

# The interesting lines of the ordered log, shortened.
flow() {
    grep -E '^(compose (stop|start)|sudo |btrfs subvolume)' "$DOCKER_LOG" \
        | sed -E -e "s|$TEST_DIR|T|g" -e 's/ (none|\/tmp\/[^ ]+) T\/snap\/vol\/appdata / /'
}

snapshots_left() {
    find "$SNAP_VOL/.dsb-snapshots" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l
}

@test "order: check, stop, snapshot, start, then archive from the snapshot, then delete" {
    run_backup
    [ "$status" -eq 0 ]
    run flow
    printf '%s\n' "${lines[@]}" >&3
    local ts; ts=$(js "$STATUS" 'd["run_id"]' | tr -d '"')
    [ "${lines[0]}" = "sudo docker-backup-snapshot.sh info" ]
    [ "${lines[1]}" = "sudo docker-backup-snapshot.sh sweep" ]
    [ "${lines[2]}" = "sudo docker-backup-snapshot.sh check $STACK" ]
    [ "${lines[3]}" = "compose stop" ]
    [ "${lines[4]}" = "sudo docker-backup-snapshot.sh create $STACK $ts" ]
    [[ "${lines[5]}" == "btrfs subvolume snapshot -r T/snap/vol T/snap/vol/.dsb-snapshots/dsb-$STACK-$ts" ]]
    [ "${lines[6]}" = "compose start app worker" ]
    [[ "${lines[7]}" == "sudo docker-backup-tar-create.sh "*"$STACK --from-snapshot $ts" ]]
    [ "${lines[8]}" = "sudo docker-backup-snapshot.sh delete $STACK $ts" ]
    [[ "${lines[9]}" == "btrfs subvolume delete "* ]]
    [ "${#lines[@]}" -eq 10 ]
    [ "$(snapshots_left)" -eq 0 ]
}

@test "status and .prom: snapshot used, downtime excludes the archive, backend at run level" {
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["snapshot_backend"]')" = '"btrfs"' ]
    [ "$(js "$STATUS" 'd["snapshot_note"]')" = null ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["used"]')" = true ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["fallback_reason"]')" = null ]
    [ "$(js "$STATUS" 'type(d["stacks"][0]["snapshot"]["snapshot_s"]) is int')" = true ]
    [ "$(js "$STATUS" 'd["stacks"][0]["mode"]')" = '"running"' ]
    [ "$(js "$STATUS" 'type(d["stacks"][0]["downtime_s"]) is int')" = true ]
    run_id=$(js "$STATUS" 'd["run_id"]' | tr -d '"')
    [ "$(tar -xOf "$HOST_DIR/$run_id/$STACK.tar" "$STACK/data.txt")" = appdata-content ]
    grep -qx "dsb_stack_snapshot_used{host=\"$HOST\",stack=\"$STACK\"} 1" "$PROM"
    grep -qx "dsb_snapshot_fallbacks{host=\"$HOST\"} 0" "$PROM"
}

@test "snapshot create fails: archived while stopped (stopped once), fallback create-failed" {
    export STUB_SNAP_CREATE_RC=1
    run_backup
    [ "$status" -eq 0 ]
    [ "$(grep -c '^compose stop' "$DOCKER_LOG")" -eq 1 ]
    [ "$(grep -c '^compose start' "$DOCKER_LOG")" -eq 1 ]
    ! grep -q -- '--from-snapshot' "$DOCKER_LOG"
    # The archive came before the start: the old order.
    run flow
    local i archive_at start_at
    for i in "${!lines[@]}"; do
        [[ "${lines[$i]}" == "sudo docker-backup-tar-create.sh"* ]] && archive_at=$i
        [[ "${lines[$i]}" == "compose start"* ]] && start_at=$i
    done
    [ "$archive_at" -lt "$start_at" ]
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"backed_up"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["used"]')" = false ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["fallback_reason"]')" = '"create-failed"' ]
    grep -qx "dsb_snapshot_fallbacks{host=\"$HOST\"} 1" "$PROM"
    grep -qx "dsb_stack_snapshot_used{host=\"$HOST\",stack=\"$STACK\"} 0" "$PROM"
}

@test "a mountpoint under the stack's appdata: no snapshot is taken, the stack is stopped once" {
    mkdir -p "$APPDATA_PATH/$STACK/db"
    echo "$APPDATA_PATH/$STACK/db ext4" > "$SNAP_T/mounts"
    run_backup
    [ "$status" -eq 0 ]
    ! grep -q "create $STACK" "$DOCKER_LOG"
    ! grep -q '^btrfs subvolume snapshot' "$DOCKER_LOG"
    [ "$(grep -c '^compose stop' "$DOCKER_LOG")" -eq 1 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["fallback_reason"]')" = '"mountpoint"' ]
    [[ "$output" == *"No snapshot for $STACK (mountpoint)"* ]]
}

@test "a mount that appears between check and create: fallback mountpoint, stopped once, no snapshot (F-03)" {
    # The mount shows up on the first `compose stop`, i.e. after `check` ran.
    mkdir -p "$APPDATA_PATH/$STACK/late"
    local real_docker="$BIN_DIR/docker"
    mv "$real_docker" "$BIN_DIR/docker.real"
    cat > "$real_docker" <<STUB
#!/usr/bin/env bash
[[ "\$1 \$2" == "compose stop" ]] && echo "$APPDATA_PATH/$STACK/late ext4" > "$SNAP_T/mounts"
exec "$BIN_DIR/docker.real" "\$@"
STUB
    chmod +x "$real_docker"
    run_backup
    [ "$status" -eq 0 ]
    grep -q "check $STACK" "$DOCKER_LOG"
    ! grep -q '^btrfs subvolume snapshot' "$DOCKER_LOG"
    [ "$(grep -c '^compose stop' "$DOCKER_LOG")" -eq 1 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["fallback_reason"]')" = '"mountpoint"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"backed_up"' ]
}

@test "R2-02: create left a snapshot behind (exit 4) and the retry fails: counted, not silent" {
    export STUB_INODE2=1 STUB_SNAP_DELETE_RC=1
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["fallback_reason"]')" = '"nested-subvolume"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["delete_failed"]')" = true ]
    [ "$(js "$STATUS" 'd["snapshot_cleanup"]["failed"]')" = 1 ]
    [ "$(grep -c '^compose stop' "$DOCKER_LOG")" -eq 1 ]
}

@test "the boundary check failing is 'cannot tell': fallback check-failed, never a snapshot" {
    # A stack dir that is a symlink makes `check` fail (exit 1).
    mv "$APPDATA_PATH/$STACK" "$APPDATA_PATH/real"
    ln -s real "$APPDATA_PATH/$STACK"
    run_backup
    ! grep -q '^btrfs subvolume snapshot' "$DOCKER_LOG"
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["fallback_reason"]')" = '"check-failed"' ]
}

@test "snapshot delete fails: logged, the stack still counts as backed up, next run's sweep removes it" {
    export STUB_SNAP_DELETE_RC=1
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not delete snapshot dsb-$STACK-"*"the next run's sweep removes it"* ]]
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"backed_up"' ]
    [ "$(snapshots_left)" -eq 1 ]
    # Not only a log line (baseline OV-01): status, .prom and the summary say so.
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["delete_failed"]')" = true ]
    [ "$(js "$STATUS" 'd["snapshot_cleanup"]')" = '{"failed": 1, "swept": 0}' ]
    grep -qx "dsb_snapshot_cleanup_failures{host=\"$HOST\"} 1" "$PROM"
    [[ "$output" == *"Snapshot cleanup failed: 1"* ]]
    local left; left=$(basename "$(find "$SNAP_VOL/.dsb-snapshots" -mindepth 1 -maxdepth 1)")
    unset STUB_SNAP_DELETE_RC
    sleep 1   # a new run timestamp
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed leftover snapshot: $left"* ]]
    [ "$(snapshots_left)" -eq 0 ]
    [ "$(js "$STATUS" 'd["snapshot_cleanup"]')" = '{"failed": 0, "swept": 1}' ]
    grep -qx "dsb_snapshot_leftovers_swept{host=\"$HOST\"} 1" "$PROM"
    grep -qx "dsb_snapshot_cleanup_failures{host=\"$HOST\"} 0" "$PROM"
}

@test "a failed sweep counts as a cleanup failure, and the run goes on" {
    export STUB_SNAP_DELETE_RC=1
    run_backup                     # leaves one snapshot behind
    sleep 1
    run_backup                     # its sweep fails on it, and its own delete fails
    [ "$status" -eq 0 ]
    [[ "$output" == *"Snapshot sweep did not finish"* ]]
    [ "$(js "$STATUS" 'd["snapshot_cleanup"]["failed"]')" = 2 ]
    [ "$(js "$STATUS" 'd["outcome"]')" = '"success"' ]
}

@test "an unsupported ELEVATION_CMD never reaches the snapshot helper" {
    export ELEVATION_CMD=pkexec
    run_backup
    ! grep -q 'docker-backup-snapshot' "$DOCKER_LOG"
}

@test "two signals during the archive: exit at once, and the snapshot is still deleted" {
    # The first signal is deferred at `stop`, the second arrives during the archive
    # (two signals at one point coalesce, as the same signal is not queued twice).
    export STUB_SIGNAL_ON_STOP=INT STUB_SIGNAL_ON_ARCHIVE=TERM
    run_backup
    [ "$status" -eq 143 ]
    [[ "$output" == *"Second signal: exiting during $STACK"* ]]
    grep -q "^sudo docker-backup-snapshot.sh delete $STACK " "$DOCKER_LOG"
    [ "$(snapshots_left)" -eq 0 ]
    [ "$(js "$STATUS" 'd["abort_reason"]')" = '"interrupted"' ]
    # The services were already running again: the snapshot flow started them first.
    [ "$(cat "$STATE_FILE")" = "$(printf 'app\nworker')" ]
}

@test "two signals and a delete that fails: the abort record counts it (CR-03)" {
    # The first signal is deferred at `stop`; the second exits during `compose start`,
    # while the snapshot exists. The exit handler is what deletes it, so the abort record
    # must be written after that delete.
    export STUB_SIGNAL_ON_STOP=INT STUB_SIGNAL_ON_START=TERM STUB_SNAP_DELETE_RC=1
    run_backup
    [ "$status" -eq 143 ]
    [[ "$output" == *"Second signal: exiting during $STACK"* ]]
    [ "$(js "$STATUS" 'd["abort_reason"]')" = '"interrupted"' ]
    [ "$(js "$STATUS" 'd["snapshot_cleanup"]["failed"]')" = 1 ]
    grep -qx "dsb_snapshot_cleanup_failures{host=\"$HOST\"} 1" "$PROM"
}

@test "one signal during the archive: the stack finishes (archive, delete), then the run stops" {
    export STUB_SIGNAL_ON_ARCHIVE="TERM"
    run_backup
    [ "$status" -eq 143 ]
    [ "$(snapshots_left)" -eq 0 ]
    [ "$(js "$STATUS" 'd["abort_reason"]')" = '"interrupted"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"backed_up"' ]
}

@test "the archive from the snapshot fails: failed archive-failed, not started twice, snapshot deleted" {
    export STUB_ARCHIVE_FAIL=1
    run_backup
    [ "$status" -eq 1 ]
    [ "$(grep -c '^compose start' "$DOCKER_LOG")" -eq 1 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"archive-failed"' ]
    [ "$(snapshots_left)" -eq 0 ]
}

@test "the restart after the snapshot fails: the archive is still made; failed restart-failed" {
    export STUB_START_RC=1 STUB_UP_RC=1
    run_backup
    [ "$status" -eq 1 ]
    run_id=$(js "$STATUS" 'd["run_id"]' | tr -d '"')
    [ -f "$HOST_DIR/$run_id/$STACK.tar" ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"restart-failed"' ]
    [ "$(snapshots_left)" -eq 0 ]
}

@test "a stopped stack is archived live: no check, no snapshot" {
    : > "$STATE_FILE"
    run_backup
    [ "$status" -eq 0 ]
    ! grep -q "check $STACK" "$DOCKER_LOG"
    ! grep -q '^btrfs subvolume snapshot' "$DOCKER_LOG"
    [ "$(js "$STATUS" 'd["stacks"][0]["mode"]')" = '"stopped"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["used"]')" = false ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["fallback_reason"]')" = null ]
}

# ---------------------------------------------------------------------------
# Resolution: explicit vs auto vs profile, and the 0.6.0 default
# ---------------------------------------------------------------------------

@test "explicit SNAPSHOT_BACKEND=btrfs with no helper fails the preflight" {
    unset SNAPSHOT_HELPER_PATH
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"SNAPSHOT_BACKEND=btrfs: SNAPSHOT_HELPER_PATH is not set"* ]]
    [[ "$output" == *"Pre-flight checks failed"* ]]
}

@test "explicit SNAPSHOT_BACKEND=zfs on a btrfs appdata fails the preflight" {
    export SNAPSHOT_BACKEND=zfs
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"SNAPSHOT_BACKEND=zfs: $APPDATA_PATH is on btrfs, not zfs"* ]]
}

@test "the helper set up for another appdata root fails an explicit backend" {
    mkdir -p "$SNAP_VOL/other"
    sed -i "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$SNAP_VOL/other\"|" "$SNAP_HELPER"
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"ALLOWED_APPDATA_PATH ($SNAP_VOL/other) is not APPDATA_PATH"* ]]
}

@test "SNAPSHOT_BACKEND=auto with no helper: none, with the reason in the log and status.json" {
    export SNAPSHOT_BACKEND=auto
    unset SNAPSHOT_HELPER_PATH
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["snapshot_backend"]')" = '"none"' ]
    [ "$(js "$STATUS" 'd["snapshot_note"]')" = '"btrfs: SNAPSHOT_HELPER_PATH is not set"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]')" = null ]
    [[ "$output" == *"Snapshots not used (btrfs: SNAPSHOT_HELPER_PATH is not set)"* ]]
    ! grep -q 'docker-backup-snapshot' "$DOCKER_LOG"
}

@test "SNAPSHOT_BACKEND=auto on a filesystem with no snapshots: none" {
    export SNAPSHOT_BACKEND=auto STUB_FS=ext2/ext3
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["snapshot_backend"]')" = '"none"' ]
    [[ "$(js "$STATUS" 'd["snapshot_note"]')" == *"not btrfs or zfs"* ]]
}

@test "a 0.6.0 config (no SNAPSHOT_*, no PLATFORM) never calls a snapshot helper" {
    unset SNAPSHOT_BACKEND SNAPSHOT_HELPER_PATH
    run_backup
    [ "$status" -eq 0 ]
    ! grep -q 'docker-backup-snapshot' "$DOCKER_LOG"
    [ "$(js "$STATUS" 'd["snapshot_backend"]')" = '"none"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]')" = null ]
    ! grep -q '^dsb_snapshot_fallbacks' "$PROM"
}

@test "a backend from the debian profile behaves like auto: no helper means none, not a failure" {
    unset SNAPSHOT_BACKEND SNAPSHOT_HELPER_PATH
    export PLATFORM=debian
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["platform"]')" = '"debian"' ]
    [ "$(js "$STATUS" 'd["snapshot_backend"]')" = '"none"' ]
    [ "$(js "$STATUS" 'd["snapshot_note"]')" = '"btrfs: SNAPSHOT_HELPER_PATH is not set"' ]
}

@test "the debian profile with a helper configured takes snapshots" {
    unset SNAPSHOT_BACKEND
    export PLATFORM=debian
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["snapshot_backend"]')" = '"btrfs"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["used"]')" = true ]
}

@test "dry run: prints the resolved backend and each stack's snapshot plan, takes no snapshot" {
    run_backup --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Snapshot backend: btrfs"* ]]
    [[ "$output" == *"snapshot: btrfs (stopped only while the snapshot is taken)"* ]]
    ! grep -qE '^btrfs subvolume (snapshot|delete)' "$DOCKER_LOG"
    ! grep -q '^compose stop' "$DOCKER_LOG"
}
