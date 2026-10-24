#!/usr/bin/env bats
# tests/host/restore-drill.sh, the parts no CI run of the drill itself can reach (#1218).
#
# 1. The drill's backup step must run in an environment the production restic helper
#    accepts. 0.8.0 exported TMPDIR=/tmp/dsb-drill/tmp for the whole drill, so the
#    backup's per-stack temp dir was /tmp/dsb-drill/tmp/tmp.X and the helper refused it
#    (^/tmp/[^/]+$, exit 2). Here the REAL helper runs a backup under the BACKUP_ENV the
#    drill itself reports in --check, and the 0.8.0 environment is shown to be refused.
#    Local only (user namespaces and restic; see helpers/restic.bash), like restic-e2e.
# 2. ptrace-probe.py must not leave its target stopped. 0.8.0 used PTRACE_ATTACH and the
#    drill hung at teardown on its own stopped probe target.

load helpers/stub-env
load helpers/status
load helpers/restic

DRILL="$BATS_TEST_DIRNAME/host/restore-drill.sh"
PROBE="$BATS_TEST_DIRNAME/host/ptrace-probe.py"

setup() {
    stub_env_setup
    status_setup
}

teardown() {
    [[ -n "${SLEEPER:-}" ]] && { kill -KILL "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; }
    [[ -n "${RH:-}" ]] && rh_teardown
    stub_env_teardown
}

# drill_env <backup|restore> — the env prefix the drill reports in --check, as words.
drill_env() {
    bash "$DRILL" --check | sed -n "s/^  $1 env: //p"
}

# ns_backup_in <env words...> — one tar+restic backup through the real helper, as
# namespace root, under the given env prefix (no word may contain a space).
ns_backup_in() {
    RH_APPDATA="$APPDATA_PATH" RH_STACK="$STACK"
    rh_setup_ns
    export ELEVATION_CMD=none RESTIC_HELPER_PATH="$RH" BACKENDS="tar restic"
    export LOG_FILE="$TEST_DIR/backup.log"   # the helper's stderr goes here
    export FULL_RUN_DAY=$(( $(date +%u) % 7 + 1 ))
    unset ELEVATION_HELPER_PATH
    run "$@" unshare -r -m bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh"
}

proc_state() { awk '{print $3}' "/proc/$1/stat"; }

@test "--check reports the backup env (TMPDIR unset, as cron) and the restore env" {
    [ "$(drill_env backup)" = "env -u TMPDIR" ]
    [ "$(drill_env restore)" = "env TMPDIR=/tmp/dsb-drill/tmp" ]
    # Both steps of the drill use them (a bare invocation would inherit whatever is set).
    [ "$(grep -c '"${BACKUP_ENV\[@\]}" bash $S/docker-stack-backup.sh' "$DRILL")" -eq 2 ]
    ! grep -nE '^[^#]*bash \$S/docker-stack-(backup|restore)\.sh' "$DRILL" | grep -vF '_ENV[@]}"'
    ! grep -nE '^[[:space:]]*export TMPDIR' "$DRILL"
}

@test "the drill's backup env: the real restic helper accepts the backup temp dir" {
    local -a env_words
    read -ra env_words <<< "$(drill_env backup)"
    [ "${#env_words[@]}" -gt 0 ]
    export TMPDIR="$TEST_DIR/inherited-tmp"   # what the drill's caller may have set
    mkdir -p "$TMPDIR"
    ns_backup_in "${env_words[@]}"
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["result"]')" = '"ok"' ]
}

@test "probe: the 0.8.0 drill env (TMPDIR under a dir in /tmp) is refused by the helper" {
    mkdir -p "$TEST_DIR/tmp"
    ns_backup_in env TMPDIR="$TEST_DIR/tmp"
    [ "$status" -ne 0 ]
    [ "$(js "$STATUS" 'd["stacks"][0]["backends"]["restic"]["result"]')" != '"ok"' ]
    grep -qF "invalid temp_dir: $TEST_DIR/tmp/" "$LOG_FILE" || { cat "$LOG_FILE" >&2; false; }
}

@test "ptrace-probe.py: may-trace exits 0 and leaves the target running" {
    sleep 30 >/dev/null 2>&1 &
    SLEEPER=$!
    sleep 0.2
    run python3 -I "$PROBE" "$SLEEPER"
    [ "$status" -eq 0 ] || skip "ptrace of a sibling not permitted here (yama ptrace_scope)"
    sleep 0.3
    [[ "$(proc_state "$SLEEPER")" != [Tt] ]]
}

@test "ptrace-probe.py: a process it may not trace exits 1" {
    [[ $EUID -ne 0 ]] || skip "running as root"
    run python3 -I "$PROBE" 1
    [ "$status" -eq 1 ]
}

@test "probe: PTRACE_ATTACH (0.8.0's probe) leaves the target stopped, so the state check can fail" {
    sleep 30 >/dev/null 2>&1 &
    SLEEPER=$!
    sleep 0.2
    run python3 -I -c 'import ctypes,sys; l=ctypes.CDLL(None,use_errno=True); sys.exit(0 if l.ptrace(16,int(sys.argv[1]),0,0)==0 else 1)' "$SLEEPER"
    [ "$status" -eq 0 ] || skip "ptrace of a sibling not permitted here (yama ptrace_scope)"
    sleep 0.3
    [[ "$(proc_state "$SLEEPER")" == [Tt] ]]
}
