#!/usr/bin/env bats
# Restore-verification age (plan p5b, Design §5): tests/host/restore-drill.sh records a
# passing drill in BACKUP_DEST/<host>/restore-verified.json (dsb_status.py
# restore-verified); the next run carries it into status.json `restore_verified` and the
# .prom gauge dsb_restore_verified_timestamp_seconds{backend}. The file is on the share, so
# it is read like the previous status.json: untrusted. The drill itself runs as root on a
# host (p5c); here, its syntax and its --check mode.

load helpers/stub-env
load helpers/status

setup() {
    stub_env_setup
    status_setup
    export PROM_TEXTFILE_DIR="$TEST_DIR/prom"
    mkdir -p "$PROM_TEXTFILE_DIR" "$HOST_DIR"
    PROM="$PROM_TEXTFILE_DIR/docker_stack_backup.prom"
    RV="$HOST_DIR/restore-verified.json"
}

teardown() {
    stub_env_teardown
}

record() {   # record <backend> <ref>
    python3 -I "$BATS_TEST_DIRNAME/../dsb_status.py" restore-verified --file "$RV" \
        --backend "$1" --host "$HOST" --version 0.8.0 --ref "$2"
}

@test "the drill script parses, and --check reports without root and exits 0" {
    bash -n "$BATS_TEST_DIRNAME/host/restore-drill.sh"
    run bash "$BATS_TEST_DIRNAME/host/restore-drill.sh" --check --restic-run-as nosuchuser-dsb
    [ "$status" -eq 0 ]
    [[ "$output" == *"no such user: nosuchuser-dsb"* ]]
    [[ "$output" == *"--check:"* ]]
    run bash "$BATS_TEST_DIRNAME/host/restore-drill.sh" --backend tar --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"backends=tar "* ]]
    run bash "$BATS_TEST_DIRNAME/host/restore-drill.sh" --backend zip
    [ "$status" -eq 2 ]
}

@test "the drill refuses to run for real without root" {
    [[ $EUID -ne 0 ]] || skip "running as root"
    run bash "$BATS_TEST_DIRNAME/host/restore-drill.sh" --backend tar
    [ "$status" -ne 0 ]
    [[ "$output" == *"run as root"* || "$output" == *"not ready"* ]]
}

@test "restore-verified: per-backend entries merge; the next run carries them into status.json and the .prom" {
    record tar "drill: stubstack.tar"
    sleep 1
    record restic "drill snapshot abcd1234"
    [ "$(js "$RV" 'sorted(d["backends"])')" = '["restic", "tar"]' ]
    [ "$(stat -c %a "$RV")" = 644 ]
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'd["restore_verified"]["tar"]["ref"]')" = '"drill: stubstack.tar"' ]
    [ "$(js "$STATUS" 'd["restore_verified"]["restic"]["version"]')" = '"0.8.0"' ]
    local t; t=$(js "$RV" 'd["backends"]["restic"]["time"]')
    grep -q "^dsb_restore_verified_timestamp_seconds{backend=\"restic\",host=.*} $t$" "$PROM"
    grep -q '^dsb_restore_verified_timestamp_seconds{backend="tar",' "$PROM"
}

@test "restore-verified is untrusted share input: a symlink, another host's, garbage values are ignored" {
    run_backup
    [ "$(js "$STATUS" 'd["restore_verified"]')" = 'null' ]
    ! grep -q dsb_restore_verified "$PROM"
    # A symlink to a valid file.
    record tar x
    mv "$RV" "$TEST_DIR/real.json"
    ln -s "$TEST_DIR/real.json" "$RV"
    run_backup
    [ "$(js "$STATUS" 'd["restore_verified"]')" = 'null' ]
    rm -f "$RV"
    # Another host's; out-of-range and non-integer times; control bytes; extra keys.
    python3 - "$RV" "$HOST" <<'PY'
import json, sys
path, host = sys.argv[1], sys.argv[2]
json.dump({"schema": 1, "tool": "docker-stack-backup", "host": "elsewhere",
           "backends": {"tar": {"time": 1800000000, "version": "x", "ref": "y"}}}, open(path, "w"))
PY
    run_backup
    [ "$(js "$STATUS" 'd["restore_verified"]')" = 'null' ]
    python3 - "$RV" "$HOST" <<'PY'
import json, sys, time
path, host = sys.argv[1], sys.argv[2]
json.dump({"schema": 1, "tool": "docker-stack-backup", "host": host,
           "backends": {"tar": {"time": True, "version": "x"},
                        "restic": {"time": int(time.time()) - 100, "version": "v\u001b[2J" * 50,
                                   "ref": "r\nforged line"},
                        "zip": {"time": 1800000000}}}, open(path, "w"))
PY
    run_backup
    [ "$status" -eq 0 ]
    [ "$(js "$STATUS" 'sorted(d["restore_verified"])')" = '["restic"]' ]
    [ "$(js "$STATUS" 'd["restore_verified"]["restic"]["ref"]')" = '"r?forged line"' ]
    [ "$(js "$STATUS" 'len(d["restore_verified"]["restic"]["version"]) <= 32 and "\x1b" not in d["restore_verified"]["restic"]["version"]')" = 'true' ]
    # A future time beyond the slack is refused too.
    python3 - "$RV" "$HOST" <<'PY'
import json, sys, time
path, host = sys.argv[1], sys.argv[2]
json.dump({"schema": 1, "tool": "docker-stack-backup", "host": host,
           "backends": {"tar": {"time": int(time.time()) + 10 * 86400}}}, open(path, "w"))
PY
    run_backup
    [ "$(js "$STATUS" 'd["restore_verified"]')" = 'null' ]
}
