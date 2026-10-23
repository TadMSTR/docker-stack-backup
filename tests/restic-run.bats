#!/usr/bin/env bats
# BACKENDS x TAR_SCHEDULE x run kind x snapshot used/fallback/stopped, end to end
# (plan p5b, Verification 6): docker-stack-backup.sh with the REAL snapshot and tar
# helpers (btrfs shimmed, as in snapshot-flow.bats) and a STUB restic helper that logs
# its verbs. One ordered log (docker, btrfs, sudo) shows one stop per stack and where each
# backend ran. The real restic helper end to end is in restic-e2e.bats.

load helpers/stub-env
load helpers/status
load helpers/snapshot

setup() {
    stub_env_setup
    status_setup
    snap_setup btrfs
    export TMPDIR=/tmp
    export SNAP_LOG="$DOCKER_LOG"
    export APPDATA_PATH="$SNAP_APPDATA"
    rm -rf "${SNAP_APPDATA:?}/st"
    mkdir -p "$APPDATA_PATH/$STACK"
    echo "appdata-content" > "$APPDATA_PATH/$STACK/data.txt"
    sed -i "s|- .*:/data|- $APPDATA_PATH/$STACK:/data|" "$DOCKHAND_BASE/$STACK/docker-compose.yml"
    stack_config ""

    TAR_HELPER="$SNAP_T/docker-backup-tar-create.sh"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA_PATH\"|" \
        -e "s|^SNAPSHOT_HELPER=.*|SNAPSHOT_HELPER=\"$SNAP_HELPER\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-tar-create.sh" > "$TAR_HELPER"
    chmod +x "$TAR_HELPER"

    cat > "$BIN_DIR/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo ${1##*/} ${*:2}" >> "$DOCKER_LOG"
exec "$@"
STUB
    chmod +x "$BIN_DIR/sudo"

    # The stub restic helper. STUB_RESTIC_<VERB>_RC makes a verb fail with that code.
    RESTIC_STUB="$TEST_DIR/docker-backup-restic.sh"
    cat > "$RESTIC_STUB" <<'STUB'
#!/usr/bin/env bash
verb="$1"; shift
rc_var="STUB_RESTIC_${verb^^}_RC"
rc="${!rc_var:-0}"
case "$verb" in
    info)
        printf 'host=h\nappdata=%s\nrepo=/r\nrun_as=x\nfloor_daily=7\nfloor_weekly=4\nfloor_monthly=0\n' "$APPDATA_PATH" ;;
    repo)
        [[ $rc -eq 0 ]] && echo "id=$(printf 'ab%.0s' {1..32})" ;;
    backup)
        [[ $rc -eq 0 ]] && printf '{"message_type":"summary","files_new":1,"files_changed":2,"files_unmodified":3,"data_added":42,"snapshot_id":"%s"}\n' "$(printf 'cd%.0s' {1..32})" ;;
    forget)
        [[ $rc -eq 0 ]] && echo '[{"keep":[{"id":"a"},{"id":"b"}],"remove":[{"id":"c"}]}]' ;;
    snapshots)
        echo "${STUB_RESTIC_SNAPSHOTS:-[]}" ;;
    stats)
        echo '{"total_size":1000,"total_uncompressed_size":2000,"snapshots_count":3}' ;;
esac
exit "$rc"
STUB
    chmod +x "$RESTIC_STUB"

    export PATH="$SNAP_SHIM:$PATH"
    export ELEVATION_CMD=sudo ELEVATION_HELPER_PATH="$TAR_HELPER"
    export SNAPSHOT_BACKEND=btrfs SNAPSHOT_HELPER_PATH="$SNAP_HELPER"
    export RESTIC_HELPER_PATH="$RESTIC_STUB"
    export PROM_TEXTFILE_DIR="$TEST_DIR/prom"
    mkdir -p "$PROM_TEXTFILE_DIR"
    PROM="$PROM_TEXTFILE_DIR/docker_stack_backup.prom"
    export FULL_RUN_DAY=$(( $(date +%u) % 7 + 1 ))   # not today: daily unless --full
}

teardown() {
    stub_env_teardown
}

# stack_config <x-backup json or ""> — the stub `docker compose config` for $STACK.
stack_config() {
    local extra=""
    [[ -n "$1" ]] && extra=", \"x-backup\": $1"
    cat > "$STUB_CONFIG_DIR/$STACK.json" <<JSON
{"name": "$STACK", "services": {
  "app": {"image": "busybox", "volumes": [
    {"type": "bind", "source": "$APPDATA_PATH/$STACK", "target": "/data", "bind": {}}]},
  "worker": {"image": "busybox"}}$extra}
JSON
}

# The ordered operations, shortened: stop/start, snapshot create, tar, restic backup.
ops() {
    grep -E '^(compose (stop|start)|sudo docker-backup-(snapshot|tar-create|restic)\.sh)' "$DOCKER_LOG" \
        | sed -E -e 's/^sudo docker-backup-snapshot\.sh (create).*/snapshot/' \
                 -e '/^sudo docker-backup-snapshot\.sh/d' \
                 -e 's/^sudo docker-backup-tar-create\.sh.*--from-snapshot.*/tar-snap/' \
                 -e 's/^sudo docker-backup-tar-create\.sh.*/tar-live/' \
                 -e 's/^sudo docker-backup-restic\.sh backup.*--from-snapshot.*/restic-snap/' \
                 -e 's/^sudo docker-backup-restic\.sh backup.*/restic-live/' \
                 -e '/^sudo docker-backup-restic\.sh/d' \
                 -e 's/^compose (stop|start).*/\1/' \
        | paste -sd' '
}

run_id() { js "$STATUS" 'd["run_id"]' | tr -d '"'; }

@test "default config (BACKENDS unset): tar only, no restic call, status records the tar backend" {
    unset RESTIC_HELPER_PATH
    run_backup
    [ "$status" -eq 0 ]
    ! grep -q 'docker-backup-restic' "$DOCKER_LOG" || false
    [ "$(js "$STATUS" 'd["backends"]')" = '["tar"]' ]
    [ "$(js "$STATUS" 'd["tar_ran"]')" = 'true' ]
    [ "$(js "$STATUS" 'd["restic"]')" = 'null' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["tar"]["result"]')" = '"ok"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["tar"]["archive"] == d["stacks"][0]["archive"]')" = 'true' ]
    grep -q '^dsb_backend_enabled{backend="tar",host=' "$PROM"
    ! grep -q 'backend="restic"' "$PROM" || false
}

# combo <BACKENDS> <TAR_SCHEDULE> <daily|full> — one run; sets OPS, TAR_FILE (or "").
combo() {
    : > "$DOCKER_LOG"
    rm -rf "${HOST_DIR:?}"/2* "$HOST_DIR/status.json"
    export BACKENDS="$1" TAR_SCHEDULE="$2"
    local args=()
    [[ "$3" == full ]] && args=(--full)
    run_backup "${args[@]+"${args[@]}"}"
    [ "$status" -eq 0 ] || { echo "rc=$status $output" >&2; return 1; }
    OPS=$(ops)
    TAR_FILE=$(find "$HOST_DIR" -name "$STACK.tar" 2>/dev/null)
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"backed_up"' ]
    [ "$(js "$STATUS" 'd["run_kind"]')" = "\"$3\"" ]
}

# expect <ops> <tar:yes|no> <backends json>
expect() {
    echo "  BACKENDS='$BACKENDS' TAR_SCHEDULE=$TAR_SCHEDULE: $OPS" >&3
    [ "$OPS" = "$1" ] || { echo "ops: '$OPS' != '$1'" >&2; return 1; }
    if [[ "$2" == yes ]]; then [ -n "$TAR_FILE" ]; else [ -z "$TAR_FILE" ] && [ ! -d "$HOST_DIR/$(run_id)" ]; fi
    [ "$(js "$STATUS" 'sorted(d["stacks"][0]["backends"])')" = "$3" ]
}

@test "snapshot used: one stop; tar (when scheduled) and restic both read the snapshot after the start" {
    combo tar daily daily;          expect "stop snapshot start tar-snap" yes '["tar"]'
    combo tar daily full;           expect "stop snapshot start tar-snap" yes '["tar"]'
    combo restic daily daily;       expect "stop snapshot start restic-snap" no '["restic"]'
    combo restic daily full;        expect "stop snapshot start restic-snap" no '["restic"]'
    combo "tar restic" daily daily; expect "stop snapshot start tar-snap restic-snap" yes '["restic", "tar"]'
    combo "tar restic" daily full;  expect "stop snapshot start tar-snap restic-snap" yes '["restic", "tar"]'
    combo "tar restic" full daily;  expect "stop snapshot start restic-snap" no '["restic"]'
    combo "tar restic" full full;   expect "stop snapshot start tar-snap restic-snap" yes '["restic", "tar"]'
}

@test "snapshot fallback (a mount under the appdata): one stop; both backends read the live dir before the start" {
    echo "$APPDATA_PATH/$STACK/sub ext4" > "$SNAP_T/mounts"
    combo tar daily daily;          expect "stop tar-live start" yes '["tar"]'
    combo restic daily full;        expect "stop restic-live start" no '["restic"]'
    combo "tar restic" daily daily; expect "stop tar-live restic-live start" yes '["restic", "tar"]'
    combo "tar restic" full daily;  expect "stop restic-live start" no '["restic"]'
    combo "tar restic" full full;   expect "stop tar-live restic-live start" yes '["restic", "tar"]'
    [ "$(js "$STATUS" 'd["stacks"][0]["snapshot"]["fallback_reason"]')" = '"mountpoint"' ]
}

@test "stopped stack: no stop, no start; both backends read the live dir" {
    : > "$STATE_FILE"
    combo tar daily daily;          expect "tar-live" yes '["tar"]'
    combo restic daily daily;       expect "restic-live" no '["restic"]'
    combo "tar restic" daily full;  expect "tar-live restic-live" yes '["restic", "tar"]'
    combo "tar restic" full daily;  expect "restic-live" no '["restic"]'
    [ "$(js "$STATUS" 'd["stacks"][0]["mode"]')" = '"stopped"' ]
}

@test "restic backup fails, tar succeeds: the stack fails as restic-backup-failed; the archive and tar result stand" {
    export BACKENDS="tar restic" STUB_RESTIC_BACKUP_RC=1
    run_backup
    [ "$status" -eq 1 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"failed"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"restic-backup-failed"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["tar"]["result"]')" = '"ok"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["result"]')" = '"failed"' ]
    [ -n "$(find "$HOST_DIR" -name "$STACK.tar")" ]
    # The services were started again (the snapshot path starts them before the backends).
    [ "$(sort "$STATE_FILE" | paste -sd,)" = "app,worker" ]
    grep -q 'dsb_stack_backend_ok{backend="restic",host=.*} 0' "$PROM"
    grep -q 'dsb_stack_backend_ok{backend="tar",host=.*} 1' "$PROM"
    # No forget for a stack whose restic backup failed.
    ! grep -q 'docker-backup-restic.sh forget' "$DOCKER_LOG" || false
}

@test "restic backup fails on the fallback path: the services are started again exactly once" {
    echo "$APPDATA_PATH/$STACK/sub ext4" > "$SNAP_T/mounts"
    export BACKENDS="tar restic" STUB_RESTIC_BACKUP_RC=3
    run_backup
    [ "$status" -eq 1 ]
    [ "$(ops)" = "stop tar-live restic-live start" ]
    [ "$(sort "$STATE_FILE" | paste -sd,)" = "app,worker" ]
}

@test "tar fails, restic succeeds: archive-failed, the restic result is still recorded" {
    export BACKENDS="tar restic"
    cat > "$TEST_DIR/failing-tar.sh" <<'STUB'
#!/usr/bin/env bash
printf 'partial'
exit 1
STUB
    chmod +x "$TEST_DIR/failing-tar.sh"
    export ELEVATION_HELPER_PATH="$TEST_DIR/failing-tar.sh"
    run_backup
    [ "$status" -eq 1 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"archive-failed"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["result"]')" = '"ok"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["files_unmodified"]')" = '3' ]
}

@test "wrong password: run-level restic-password-wrong, every stack's restic fails, tar still runs" {
    add_stack second
    export BACKENDS="tar restic" STUB_RESTIC_REPO_RC=12
    run_backup
    [ "$status" -eq 1 ]
    [ "$(js "$STATUS" 'd["restic"]["problem"]')" = '"restic-password-wrong"' ]
    [ "$(js "$STATUS" '[s["reason"] for s in d["stacks"]]')" = '["restic-password-wrong", "restic-password-wrong"]' ]
    [ "$(js "$STATUS" '[s["backends"]["tar"]["result"] for s in d["stacks"]]')" = '["ok", "ok"]' ]
    ! grep -q 'docker-backup-restic.sh backup' "$DOCKER_LOG" || false
    grep -q '^dsb_restic_repo_available{host=.*} 0' "$PROM"
    [[ "$output" == *"repository unusable (restic-password-wrong)"* ]]
}

@test "missing repository on a restic-only (daily) run: no stack is stopped at all" {
    export BACKENDS="tar restic" TAR_SCHEDULE=full STUB_RESTIC_REPO_RC=10
    run_backup
    [ "$status" -eq 1 ]
    [ "$(ops)" = "" ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"restic-repo-missing"' ]
    [ "$(js "$STATUS" 'd["counts"]["failed"]')" = '1' ]
}

@test "a locked repository during one stack's backup fails that stack as restic-repo-locked" {
    export BACKENDS=restic STUB_RESTIC_BACKUP_RC=11
    run_backup
    [ "$status" -eq 1 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["reason"]')" = '"restic-repo-locked"' ]
}

@test "forget: x-backup.retention key by key over RESTIC_KEEP_*, kept/removed counted" {
    export BACKENDS=restic
    stack_config '{"retention": {"daily": 10, "monthly": 0}}'
    run_backup
    [ "$status" -eq 0 ]
    grep -q "docker-backup-restic.sh forget $STACK 10 4 0$" "$DOCKER_LOG"
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["forget"]')" = '{"result": "ok", "retention": {"daily": 10, "weekly": 4, "monthly": 0}, "kept": 2, "removed": 1}' ]
    [ "$(js "$STATUS" 'd["restic"]["forget"]["result"]')" = '"ok"' ]
    [ "$(js "$STATUS" 'd["restic"]["forget"]["last_success"] > 0')" = 'true' ]
}

@test "forget: a stack retention below the helper's floors is refused, not raised; the run fails" {
    export BACKENDS=restic
    stack_config '{"retention": {"daily": 3}}'
    run_backup
    [ "$status" -eq 1 ]
    ! grep -q 'docker-backup-restic.sh forget' "$DOCKER_LOG" || false
    [ "$(js "$STATUS" 'd["stacks"][0]["result"]')" = '"backed_up"' ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["forget"]["result"]')" = '"refused"' ]
    [ "$(js "$STATUS" 'd["restic"]["forget"]["result"]')" = '"failed"' ]
    grep -q '^dsb_restic_task_failed{host=.*,task="forget"} 1' "$PROM"
    [[ "$output" == *"below the helper's floors"* ]]
}

@test "forget failure is counted: status, .prom, run exit 1" {
    export BACKENDS=restic STUB_RESTIC_FORGET_RC=1
    run_backup
    [ "$status" -eq 1 ]
    [ "$(js "$STATUS" 'd["restic"]["forget"]')" = '{"result": "failed", "last_success": null, "stacks": 1, "failed": 1}' ]
    grep -q '^dsb_restic_task_last_success_timestamp_seconds{host=.*,task="forget"} 0' "$PROM"
}

@test "prune and check run on the full run only (defaults); check reads a rotating n/12 subset" {
    export BACKENDS=restic
    run_backup
    [ "$status" -eq 0 ]
    ! grep -q 'docker-backup-restic.sh \(prune\|check\)' "$DOCKER_LOG" || false
    [ "$(js "$STATUS" 'd["restic"]["prune"]')" = '{"result": null, "last_success": null}' ]
    : > "$DOCKER_LOG"
    run_backup --full
    [ "$status" -eq 0 ]
    grep -q 'docker-backup-restic.sh prune' "$DOCKER_LOG"
    local subset; subset=$(sed -n 's/.*docker-backup-restic.sh check //p' "$DOCKER_LOG")
    [[ "$subset" =~ ^([1-9]|1[0-2])/12$ ]]
    [ "$subset" = "$(( $(date +%s) / 604800 % 12 + 1 ))/12" ]
    [ "$(js "$STATUS" 'd["restic"]["check"]["subset"]')" = "\"$subset\"" ]
    local pruned; pruned=$(js "$STATUS" 'd["restic"]["prune"]["last_success"]')
    [ "$pruned" -gt 0 ]
    # A daily run carries the last prune/check success forward.
    : > "$DOCKER_LOG"
    run_backup
    [ "$(js "$STATUS" 'd["restic"]["prune"]["last_success"]')" = "$pruned" ]
    [ "$(js "$STATUS" 'd["restic"]["prune"]["result"]')" = 'null' ]
    grep -q "^dsb_restic_task_last_success_timestamp_seconds{host=.*,task=\"prune\"} $pruned" "$PROM"
}

@test "a failed check fails the run and is counted; RESTIC_CHECK_ON=daily, explicit subset" {
    export BACKENDS=restic RESTIC_CHECK_ON=daily RESTIC_CHECK_SUBSET=5% STUB_RESTIC_CHECK_RC=1
    run_backup
    [ "$status" -eq 1 ]
    grep -q 'docker-backup-restic.sh check 5%$' "$DOCKER_LOG"
    [ "$(js "$STATUS" 'd["restic"]["check"]["result"]')" = '"failed"' ]
    grep -q '^dsb_restic_task_failed{host=.*,task="check"} 1' "$PROM"
    [[ "$output" == *"check failed (subset 5%)"* ]]
}

@test "orphan stacks: snapshots of a stack with no stack dir are reported, never forgotten" {
    export BACKENDS=restic
    export STUB_RESTIC_SNAPSHOTS='[{"tags":["dsb","stack:gone"]},{"tags":["dsb","stack:'"$STACK"'"]},{"tags":["dsb","stack:bad name"]}]'
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["restic"]["orphan_stacks"]')" = '["gone"]' ]
    ! grep -q 'docker-backup-restic.sh forget gone' "$DOCKER_LOG" || false
    grep -q '^dsb_restic_orphan_stacks{host=.*} 1' "$PROM"
    grep -q '^dsb_restic_repo_bytes{host=.*} 1000' "$PROM"
}

@test "per-backend last success is carried forward: a weekly tar's time survives the daily runs" {
    export BACKENDS="tar restic" TAR_SCHEDULE=full
    run_backup --full
    [ "$status" -eq 0 ]
    local tar_last; tar_last=$(js "$STATUS" 'd["backend_last_success"]["tar"]')
    [ "$tar_last" -gt 0 ]
    sleep 1
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["tar_ran"]')" = 'false' ]
    [ "$(js "$STATUS" 'd["backend_last_success"]["tar"]')" = "$tar_last" ]
    [ "$(js "$STATUS" 'd["backend_last_success"]["restic"] > '"$tar_last")" = 'true' ]
    grep -q "^dsb_backend_ran{backend=\"tar\",host=.*} 0" "$PROM"
    grep -q "^dsb_backend_last_success_timestamp_seconds{backend=\"tar\",host=.*} $tar_last" "$PROM"
}

@test "config validation: bad BACKENDS, TAR_SCHEDULE=full without restic, restic without a helper, keep below floors" {
    export BACKENDS=zip
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"BACKENDS must be"* ]]
    export BACKENDS=tar TAR_SCHEDULE=full
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"TAR_SCHEDULE=full needs restic"* ]]
    export BACKENDS="restic restic" TAR_SCHEDULE=daily
    run_backup
    [ "$status" -eq 1 ]
    export BACKENDS=restic RESTIC_HELPER_PATH=""
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"RESTIC_HELPER_PATH is not set"* ]]
    export RESTIC_HELPER_PATH="$RESTIC_STUB" RESTIC_KEEP_DAILY=6
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"below the restic helper's floors"* ]]
    ! grep -q 'compose stop' "$DOCKER_LOG" || false
    export RESTIC_KEEP_DAILY=7
    # Shape and range, as the helper checks them (CR-02): refused at config time.
    local sub
    for sub in "1/2;id" 0/4 5/4 150% 100.5% 1/0; do
        export RESTIC_CHECK_SUBSET="$sub"
        run_backup
        [ "$status" -eq 1 ] || { echo "accepted: $sub" >&2; false; }
        [[ "$output" == *"RESTIC_CHECK_SUBSET must be"* ]]
    done
    for sub in 1/12 12/12 100% 2.5%; do
        export RESTIC_CHECK_SUBSET="$sub"
        run_backup
        [[ "$output" != *"RESTIC_CHECK_SUBSET must be"* ]] || { echo "refused: $sub" >&2; false; }
    done
    # A global exclude pattern the helpers would refuse (here: one string with a space).
    export RESTIC_CHECK_SUBSET=auto EXCLUDE_PATTERNS="a b"
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not allowed with restic"* ]]
    # With tar only the new check does not apply: the pattern behaves as on 0.7.0 (the
    # elevated tar helper refuses it per stack, as before).
    export BACKENDS=tar
    run_backup
    [[ "$output" != *"is not allowed with restic"* ]]
    [[ "$output" != *"invalid-config"* ]]
}

@test "dry run shows the backends and does not call restic backup" {
    export BACKENDS="tar restic" TAR_SCHEDULE=full
    run_backup --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Backends: tar restic (tar: full; this run: tar false, restic true)"* ]]
    [[ "$output" == *"backends: restic"* ]]
    ! grep -q 'docker-backup-restic.sh \(backup\|forget\|prune\|check\)' "$DOCKER_LOG" || false
}

@test "#1089: archives are 0600 and new run/host dirs 0700" {
    run_backup
    [ "$status" -eq 0 ]
    local archive; archive=$(find "$HOST_DIR" -name "$STACK.tar")
    [ "$(stat -c %a "$archive")" = 600 ]
    [ "$(stat -c %a "$(dirname "$archive")")" = 700 ]
    [ "$(stat -c %a "$HOST_DIR")" = 700 ]
    # status.json stays world-readable (names and sizes only).
    [ "$(stat -c %a "$STATUS")" = 644 ]
    # The compose file keeps its own mode in the archive (cp -p), not one masked by 077.
    chmod 0644 "$DOCKHAND_BASE/$STACK/docker-compose.yml"
    rm -rf "${HOST_DIR:?}"/2*
    run_backup
    archive=$(find "$HOST_DIR" -name "$STACK.tar")
    tar -tvf "$archive" | grep -q '^-rw-r--r-- .* \./docker-compose.yml$'
}
