#!/bin/bash
# shellcheck disable=SC2034  # rrc, cid2, cid3, … are read inside the check() eval strings
#######################################
# restore-drill.sh — a host acceptance test of backup AND restore, for both backends.
#
# Run as root on the host that runs docker-stack-backup (it starts a container):
#   sudo bash tests/host/restore-drill.sh [--backend tar|restic|both] [--probes]
#        [--restic-run-as USER] [--restic-bin PATH] [--probe-user USER]
#        [--record-dest DIR]
#   bash tests/host/restore-drill.sh --check     # prerequisites and plan only, no root
#
# Vendored from the p3b drill (2026-10-14) and extended in 0.8.0 to restic. Everything it
# makes is under /tmp/dsb-drill and compose project dsb-drill, and it tears both down:
#   - the scripts of THIS checkout, copied to /tmp/dsb-drill/scripts with a generated
#     scratch config.sh (DOCKHAND_BASE/APPDATA_PATH/BACKUP_DEST/LOG_FILE/LOCK_FILE/
#     RESTORE_SAFETY_DIR under /tmp/dsb-drill, ELEVATION_CMD=none, notifications off)
#   - for restic, a scratch copy of docker-backup-restic.sh, root-owned 0750, whose
#     constants point at a scratch repository and password under /tmp/dsb-drill. The real
#     restic binary and the real RESTIC_RUN_AS user are used; the production repository,
#     password and share are never touched.
# Prerequisites: docker with image alpine:3 present (pull_policy never), python3,
# util-linux setpriv/unshare; for restic: the restic binary (0.17.1+) and the RESTIC_RUN_AS
# system user (RESTIC.md "Install").
#
# Per backend: a throwaway stack with seeded state A (a root 0600 file, a uid-999 0700 tree,
# a symlink) is backed up by docker-stack-backup.sh, mutated to state B, and restored
# through all wizard steps with "back up existing data first". PASS needs: rc 0, the
# appdata manifest and sha256 equal to state A, the safety copy equal to state B, the
# container running. A negative case per backend must change nothing and stop nothing.
#
# --probes (restic): the checks no unprivileged test can make, run against a live restic
# process: it runs as RESTIC_RUN_AS with CapEff = CAP_DAC_READ_SEARCH only, and a process
# of --probe-user (default: SUDO_USER) can read neither its /proc/<pid>/environ nor fd 0
# (the password) nor ptrace it. Each probe is first shown to work against a process of the
# probe user itself.
#
# --record-dest DIR: on a PASS, write DIR/restore-verified.json (per backend: time,
# version, what was restored), as the owner of DIR; the next backup run carries it into
# status.json and dsb_restore_verified_timestamp_seconds. DIR is the production
# BACKUP_DEST/<hostname>, e.g. /mnt/backup/docker-backups/myhost.
#######################################
set -uo pipefail
umask 022

D=/tmp/dsb-drill
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S=$D/scripts
A=$D/appdata/dsb-drill
OUT=$D/out
BACKEND=both
PROBES=false
CHECK_ONLY=false
RUN_AS=dsb-restic
RESTIC_BIN=/usr/bin/restic
PROBE_USER="${SUDO_USER:-}"
RECORD_DEST=""

usage() { sed -n '6,10p' "$0" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)       [[ $# -ge 2 ]] || usage; BACKEND="$2"; shift 2 ;;
        --probes)        PROBES=true; shift ;;
        --check)         CHECK_ONLY=true; shift ;;
        --restic-run-as) [[ $# -ge 2 ]] || usage; RUN_AS="$2"; shift 2 ;;
        --restic-bin)    [[ $# -ge 2 ]] || usage; RESTIC_BIN="$2"; shift 2 ;;
        --probe-user)    [[ $# -ge 2 ]] || usage; PROBE_USER="$2"; shift 2 ;;
        --record-dest)   [[ $# -ge 2 ]] || usage; RECORD_DEST="$2"; shift 2 ;;
        *) usage ;;
    esac
done
case "$BACKEND" in
    tar)    BACKENDS=(tar) ;;
    restic) BACKENDS=(restic) ;;
    both)   BACKENDS=(tar restic) ;;
    *)      usage ;;
esac

#######################################
# Prerequisites (also all of --check)
#######################################
problems=()
need() { command -v "$1" >/dev/null 2>&1 || problems+=("missing command: $1"); }
need docker; need python3; need setpriv; need unshare; need sha256sum
for f in docker-stack-backup.sh docker-stack-restore.sh lib.sh dsb_status.py docker-backup-restic.sh; do
    [[ -f "$REPO/$f" ]] || problems+=("missing $REPO/$f")
done
if [[ " ${BACKENDS[*]} " == *" restic "* ]]; then
    [[ -x "$RESTIC_BIN" ]] || problems+=("restic binary not found: $RESTIC_BIN (--restic-bin)")
    id -u -- "$RUN_AS" >/dev/null 2>&1 || problems+=("no such user: $RUN_AS (--restic-run-as; RESTIC.md \"Install\")")
fi
if [[ "$PROBES" == true ]]; then
    [[ -n "$PROBE_USER" ]] && id -u -- "$PROBE_USER" >/dev/null 2>&1 \
        || problems+=("--probes needs --probe-user (or SUDO_USER): a non-root user to probe from")
fi
if [[ -n "$RECORD_DEST" && ! -d "$RECORD_DEST" ]]; then
    problems+=("--record-dest is not a directory: $RECORD_DEST")
fi

echo "restore-drill: backends=${BACKENDS[*]} probes=$PROBES record=${RECORD_DEST:-no}"
echo "  scripts from: $REPO ($(sed -n 's/^DSB_VERSION="\(.*\)"/\1/p' "$REPO/lib.sh"))"
echo "  scratch: $D (removed at the end); compose project: dsb-drill"
if [[ "$CHECK_ONLY" == true ]]; then
    if [[ ${#problems[@]} -gt 0 ]]; then
        printf '  not ready: %s\n' "${problems[@]}"
        echo "--check: the drill would not run on this host (as above)."
    else
        echo "--check: prerequisites met."
    fi
    # --check reports; the syntax of every step below is checked by bash -n in CI.
    exit 0
fi
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }
if [[ ${#problems[@]} -gt 0 ]]; then
    printf 'not ready: %s\n' "${problems[@]}"
    exit 1
fi
docker image inspect alpine:3 >/dev/null 2>&1 || { echo "image alpine:3 is not present (the drill never pulls)"; exit 1; }
[[ -z "$(docker ps -aq --filter label=com.docker.compose.project=dsb-drill)" ]] || { echo "project dsb-drill already exists"; exit 1; }

# /tmp is shared: create the scratch root in one step that fails if anything (a dir, a
# file, a planted symlink) is already there, then check it is root's own directory. A
# `[[ ! -e ]]` test followed by `mkdir -p` left a window in which another user could plant
# a symlink there, and root would then write (and source) the scratch config.sh through it.
mkdir -m 0700 -- "$D" 2>/dev/null || { echo "$D already exists (or cannot be created) — not running"; exit 1; }
# From here on the drill owns $D and project dsb-drill: tear both down however it ends, so
# a failed run does not leave them for the next one to refuse (CR-07).
TEARDOWN_DONE=false
RESULTS="${DRILL_RESULTS:-/root/dsb-restore-drill-$(date +%Y%m%d_%H%M%S)}"
teardown() {
    [[ "$TEARDOWN_DONE" == false ]] || return 0
    TEARDOWN_DONE=true
    echo "=== teardown ==="
    cp "$D/backup.log" "$OUT/backup.log" 2>/dev/null
    docker compose -p dsb-drill down 2>&1
    local left; left=$(docker ps -aq --filter label=com.docker.compose.project=dsb-drill)
    echo "dsb-drill containers left: ${left:-none}"
    if [[ -d "$OUT" ]]; then
        mkdir -p "$RESULTS" && cp -a "$OUT"/. "$RESULTS"/
        [[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER:" "$RESULTS"
    fi
    rm -rf -- /tmp/dsb-drill
    if [[ -e $D ]]; then echo "WARN: $D still present"; else echo "$D removed"; fi
}
on_exit() {
    local rc=$?
    set +e
    teardown
    exit "$rc"
}
trap on_exit EXIT
[[ -d "$D" && ! -L "$D" && "$(stat -c %u -- "$D")" == 0 ]] || { echo "$D is not root's own directory — not running"; exit 1; }
chmod 0755 -- "$D"   # RESTIC_RUN_AS must traverse it to reach the scratch repository
mkdir -p "$OUT" "$D/tmp" "$D/run" "$D/stacks/dsb-drill" "$A" "$D/backups" "$D/safety" "$S"
export TMPDIR=$D/tmp
unset BACKUP_BASE
exec > >(tee "$OUT/drill-transcript.txt") 2>&1
# Setup steps must not fail quietly (CR-04): errexit until the checks start (step 3),
# where check() expects commands to fail and records them instead.
set -e

PASS=0; FAIL=0
declare -A OK_BACKEND=()
check() { if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
manifest() { find "$1" -printf '%P %U:%G %m %s %y %l\n' | sort; }
sums() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
cid() { docker ps -q --no-trunc --filter label=com.docker.compose.project=dsb-drill --filter status=running; }
js() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

#######################################
# Scripts, scratch config, scratch restic helper
#######################################
cp "$REPO"/{docker-stack-backup.sh,docker-stack-restore.sh,lib.sh,dsb_status.py,backup-verify.sh} "$S/"
chmod 0755 "$S"/*.sh
cat > "$S/config.sh" <<EOF
DOCKHAND_BASE=$D/stacks
DOCKHAND_APPEND_HOSTNAME=false
APPDATA_PATH=$D/appdata
BACKUP_DEST=$D/backups
LOG_FILE=$D/backup.log
LOCK_FILE=$D/run/dsb.lock
RESTORE_SAFETY_DIR=$D/safety
COVERAGE_EXEMPTIONS_FILE=/dev/null
ELEVATION_CMD=none
SNAPSHOT_BACKEND=none
NOTIFY_ON_SUCCESS=false
NOTIFY_ON_FAILURE=false
BACKENDS="${BACKENDS[*]}"
EOF
if [[ " ${BACKENDS[*]} " == *" restic "* ]]; then
    H=$D/helpers
    mkdir -p "$H"
    head -c 32 /dev/urandom | base64 > "$H/password"
    chmod 0400 "$H/password"
    mkdir -m 0700 "$D/restic-repo"
    chown "$(id -u -- "$RUN_AS"):$(id -g -- "$RUN_AS")" "$D/restic-repo"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$D/appdata\"|" \
        -e "s|^RESTIC_BIN=.*|RESTIC_BIN=\"$RESTIC_BIN\"|" \
        -e "s|^RESTIC_REPO=.*|RESTIC_REPO=\"$D/restic-repo\"|" \
        -e "s|^RESTIC_PASSWORD_FILE=.*|RESTIC_PASSWORD_FILE=\"$H/password\"|" \
        -e "s|^RESTIC_RUN_AS=.*|RESTIC_RUN_AS=\"$RUN_AS\"|" \
        -e "s|^RESTIC_HOST=.*|RESTIC_HOST=\"dsb-drill\"|" \
        -e "s|^RESTIC_CACHE_DIR=.*|RESTIC_CACHE_DIR=\"$D/restic-cache\"|" \
        -e "s|^RESTIC_STAGE_DIR=.*|RESTIC_STAGE_DIR=\"$D/restic-stage\"|" \
        "$REPO/docker-backup-restic.sh" > "$H/docker-backup-restic.sh"
    chmod 0750 "$H/docker-backup-restic.sh"
    echo "RESTIC_HELPER_PATH=$H/docker-backup-restic.sh" >> "$S/config.sh"
    bash "$H/docker-backup-restic.sh" init > "$OUT/restic-init.txt" 2>&1 \
        || { echo "restic init failed:"; cat "$OUT/restic-init.txt"; exit 1; }
fi

#######################################
# 1-3. Stack, state A, one backup run (every selected backend)
#######################################
echo "=== 1. throwaway stack (compose.yaml, alpine:3, no pull) ==="
cat > $D/stacks/dsb-drill/compose.yaml <<EOF
services:
  app:
    image: alpine:3
    pull_policy: never
    init: true
    command: ["sleep", "infinity"]
    volumes:
      - $A:/data
EOF
(cd $D/stacks/dsb-drill && docker compose up -d) || { echo "compose up failed"; exit 1; }

echo "=== 2. seed state A ==="
seed_a() {
    rm -rf -- "${A:?}"/* "$A"/.[!.]* 2>/dev/null
    mkdir -p "$A/db/nested/deeper"
    printf 'root secret A\n' > "$A/secret.conf"; chmod 600 "$A/secret.conf"
    printf 'db page A\n' > "$A/db/page.dat"
    printf 'nested A\n' > "$A/db/nested/deeper/file.txt"
    chown -R 999:999 "$A/db"; chmod 700 "$A/db"
    printf 'to be deleted A\n' > "$A/delete-me.txt"
    ln -s db/nested/deeper/file.txt "$A/link-to-nested"
    if [[ "$PROBES" == true ]]; then
        # Large enough that restic is still running while the probes look at it.
        head -c $((300 * 1024 * 1024)) /dev/urandom > "$A/big.bin"
    fi
    touch -d '2026-01-02 03:04:05' "$A/secret.conf"
}
seed_a
manifest "$A" > "$OUT/state-A.txt"; sums "$A" > "$OUT/state-A.sha256"
cat "$OUT/state-A.txt"
CID0=$(cid); echo "container before backup: $CID0"

# The --probes checks, run while restic runs (a backup in the background).
probe_restic() {
    local pid="" i
    for _ in $(seq 1 200); do
        pid=$(pgrep -u "$RUN_AS" -x restic | head -1) && [[ -n "$pid" ]] && break
        sleep 0.05
    done
    if [[ -z "$pid" ]]; then
        echo "FAIL  probes: restic was never seen running (make big.bin larger)"; FAIL=$((FAIL+1)); return
    fi
    grep -E '^(Uid|CapEff|CapBnd|CapAmb|NoNewPrivs):' "/proc/$pid/status" > "$OUT/restic-proc-status.txt"
    cat "$OUT/restic-proc-status.txt"
    local uid; uid=$(id -u -- "$RUN_AS")
    check "probes: restic runs as $RUN_AS (uid $uid)" "awk '/^Uid:/ {exit !(\$2 == $uid && \$3 == $uid)}' $OUT/restic-proc-status.txt"
    check "probes: CapEff = CAP_DAC_READ_SEARCH only" "grep -q '^CapEff:[[:space:]]*0000000000000004$' $OUT/restic-proc-status.txt"
    check "probes: bounding set = CAP_DAC_READ_SEARCH only" "grep -q '^CapBnd:[[:space:]]*0000000000000004$' $OUT/restic-proc-status.txt"
    # Each probe first against a process of the probe user itself: it must work there.
    setpriv --reuid="$PROBE_USER" --regid="$(id -g -- "$PROBE_USER")" --init-groups -- sleep 30 &
    local own=$!
    sleep 0.2
    local as_probe=(setpriv --reuid="$PROBE_USER" --regid="$(id -g -- "$PROBE_USER")" --init-groups --)
    check "probes fire: $PROBE_USER reads its own process's environ" "${as_probe[*]} cat /proc/$own/environ >/dev/null"
    check "probes fire: $PROBE_USER ptraces its own process" "${as_probe[*]} python3 -I -c 'import ctypes,sys; l=ctypes.CDLL(None,use_errno=True); sys.exit(0 if l.ptrace(16,$own,0,0)==0 else 1)'"
    kill "$own" 2>/dev/null
    check "probes: $PROBE_USER cannot read restic's /proc/$pid/environ" "! ${as_probe[*]} cat /proc/$pid/environ >/dev/null 2>&1"
    check "probes: $PROBE_USER cannot read restic's fd 0 (the password)" "! ${as_probe[*]} cat /proc/$pid/fd/0 >/dev/null 2>&1"
    check "probes: $PROBE_USER cannot ptrace restic" "! ${as_probe[*]} python3 -I -c 'import ctypes,sys; l=ctypes.CDLL(None,use_errno=True); sys.exit(0 if l.ptrace(16,$pid,0,0)==0 else 1)'"
    # -f: the pattern is read from the file, so the password is never in grep's own argv.
    check "probes: the password is not in restic's argv or environ" "! grep -qFf $H/password /proc/$pid/cmdline /proc/$pid/environ"
}

set +e
echo "=== 3. backup (${BACKENDS[*]}) ==="
if [[ "$PROBES" == true && " ${BACKENDS[*]} " == *" restic "* ]]; then
    bash $S/docker-stack-backup.sh > "$OUT/backup-run.txt" 2>&1 &
    bpid=$!
    probe_restic
    wait "$bpid"; brc=$?
else
    bash $S/docker-stack-backup.sh > "$OUT/backup-run.txt" 2>&1; brc=$?
fi
echo "backup rc=$brc"
tail -25 "$OUT/backup-run.txt"
STATUS_FILE=$(find $D/backups -maxdepth 2 -name status.json | head -1)
check "backup rc 0" '[[ $brc -eq 0 ]]'
check "status.json: stack backed up" '[[ -n "$STATUS_FILE" && "$(js "$STATUS_FILE" "d[\"stacks\"][0][\"result\"]")" == backed_up ]]'
CID1=$(cid); echo "container after backup: $CID1"
check "backup kept the container (same ID, running)" '[[ -n "$CID0" && "$CID0" == "$CID1" ]]'
ARCH=$(find $D/backups -name 'dsb-drill.tar*' -type f | head -1)
SNAP_ID=""
[[ -n "$STATUS_FILE" ]] && SNAP_ID=$(js "$STATUS_FILE" '(d["stacks"][0].get("backends") or {}).get("restic", {}).get("snapshot_id") or ""')
for b in "${BACKENDS[@]}"; do
    check "status.json: $b ok" '[[ "$(js "$STATUS_FILE" "d[\"stacks\"][0][\"backends\"][\"$b\"][\"result\"]")" == ok ]]'
done
[[ " ${BACKENDS[*]} " == *" tar "* ]] && check "tar: archive is 0600 (#1089)" '[[ "$(stat -c %a "$ARCH")" == 600 ]]'

#######################################
# 4-6. Per backend: state B, restore, checks, negative case
#######################################
restore_drill() {   # restore_drill <tar|restic>
    local b="$1" input
    echo "=== 4. [$b] mutate to state B ==="
    printf 'db page B (changed)\n' > "$A/db/page.dat"
    rm -f "$A/delete-me.txt"
    printf 'added in B\n' > "$A/added-B.txt"
    manifest "$A" > "$OUT/$b-state-B.txt"; sums "$A" > "$OUT/$b-state-B.sha256"
    rm -rf -- "${D:?}/safety"/*

    echo "=== 5. [$b] restore wizard, all steps, option 2 (back up existing data first), start y ==="
    # With a restic helper configured, Step 0 asks for the source first.
    if [[ " ${BACKENDS[*]} " == *" restic "* ]]; then
        if [[ "$b" == tar ]]; then input=$'1\n1\n1\n1\ny\n2\ny\n'; else input=$'2\n1\n1\ny\n2\ny\n'; fi
    else
        input=$'1\n1\n1\ny\n2\ny\n'
    fi
    printf '%s' "$input" | bash $S/docker-stack-restore.sh > "$OUT/$b-restore-transcript.txt" 2>&1
    local rrc=$?
    cat "$OUT/$b-restore-transcript.txt"
    manifest "$A" > "$OUT/$b-state-restored.txt"; sums "$A" > "$OUT/$b-state-restored.sha256"
    local safe; safe=$(find $D/safety -mindepth 1 -maxdepth 1 -type d -name 'docker-restore-backup-dsb-drill-*' | head -1)
    [[ -n "$safe" ]] && manifest "$safe/appdata" > "$OUT/$b-state-safety.txt" && sums "$safe/appdata" > "$OUT/$b-state-safety.sha256"
    local cid2; cid2=$(cid)
    local before=$FAIL
    check "[$b] restore rc 0" '[[ $rrc -eq 0 ]]'
    check "[$b] restored manifest == state A (owners, modes, types, sizes, symlink)" 'diff "$OUT/state-A.txt" "$OUT/$b-state-restored.txt"'
    check "[$b] restored sha256 == state A" 'diff "$OUT/state-A.sha256" "$OUT/$b-state-restored.sha256"'
    check "[$b] safety copy == state B" '[[ -n "$safe" ]] && diff "$OUT/$b-state-B.txt" "$OUT/$b-state-safety.txt" && diff "$OUT/$b-state-B.sha256" "$OUT/$b-state-safety.sha256"'
    check "[$b] container running after restore" '[[ -n "$cid2" ]]'
    check "[$b] compose.yaml restored" '[[ -f $D/stacks/dsb-drill/compose.yaml ]]'
    check "[$b] no temp extract dir left in TMPDIR" '[[ -z "$(ls -A $TMPDIR)" ]]'

    echo "=== 6. [$b] negative: nothing changed, nothing stopped ==="
    local cid3; cid3=$(cid)
    manifest "$A" > "$OUT/$b-before-negative.txt"
    local nrc=0
    if [[ "$b" == tar ]]; then
        local bad; bad=$D/backups/$(basename "$(dirname "$(dirname "$ARCH")")")/20991231_235959
        mkdir -p "$bad"; head -c 4096 "$ARCH" > "$bad/$(basename "$ARCH")"
        if [[ " ${BACKENDS[*]} " == *" restic "* ]]; then input=$'1\n1\n1\n1\ny\n2\ny\n'; else input=$'1\n1\n1\ny\n2\ny\n'; fi
        printf '%s' "$input" | bash $S/docker-stack-restore.sh > "$OUT/$b-negative.txt" 2>&1 || nrc=$?
        rm -rf -- "$bad"
    else
        # An id that is not one of this stack's snapshots: the helper refuses the dump.
        bash -c 'source "$1/docker-stack-restore.sh"; restore_source=restic selected_stack=dsb-drill
            selected_hostname="$(hostname)" selected_restic_id="$2" restore_mode=backup_first
            perform_restore' _ "$S" "$(printf 'ab%.0s' {1..32})" > "$OUT/$b-negative.txt" 2>&1 || nrc=$?
    fi
    cat "$OUT/$b-negative.txt"
    manifest "$A" > "$OUT/$b-after-negative.txt"
    check "[$b] negative: rc non-zero ($nrc)" '[[ $nrc -ne 0 ]]'
    check "[$b] negative: 'nothing was changed'" 'grep -q "nothing was changed" "$OUT/$b-negative.txt"'
    check "[$b] negative: same container, still running" '[[ -n "$cid3" && "$cid3" == "$(cid)" ]]'
    check "[$b] negative: appdata unchanged" 'diff "$OUT/$b-before-negative.txt" "$OUT/$b-after-negative.txt"'
    [[ $FAIL -eq $before ]] && OK_BACKEND[$b]=1
}

# A passing restore leaves state A in place, so the next backend starts from it again.
for b in "${BACKENDS[@]}"; do
    restore_drill "$b"
done

#######################################
# 7. Record (only the backends that passed), results, teardown
#######################################
if [[ -n "$RECORD_DEST" ]]; then
    owner=$(stat -c '%u:%g' -- "$RECORD_DEST")
    as_owner=()
    [[ "${owner%%:*}" != 0 ]] && as_owner=(setpriv --reuid="${owner%%:*}" --regid="${owner##*:}" --clear-groups --no-new-privs --)
    version=$(sed -n 's/^DSB_VERSION="\(.*\)"/\1/p' "$S/lib.sh")
    for b in "${BACKENDS[@]}"; do
        if [[ -z "${OK_BACKEND[$b]:-}" ]]; then
            echo "not recording $b: its checks failed"
            continue
        fi
        ref="$(basename "${ARCH:-}")"
        [[ "$b" == restic ]] && ref="drill snapshot ${SNAP_ID:0:8}"
        if "${as_owner[@]+"${as_owner[@]}"}" python3 -I "$S/dsb_status.py" restore-verified \
            --file "$RECORD_DEST/restore-verified.json" --backend "$b" --host "$(hostname)" \
            --version "$version" --ref "drill: $ref"; then
            echo "recorded: $b in $RECORD_DEST/restore-verified.json"
        else
            echo "FAIL  could not record $b in $RECORD_DEST/restore-verified.json"; FAIL=$((FAIL+1))
        fi
    done
fi

echo "=== 7. results: $PASS pass, $FAIL fail ==="
teardown
echo "DONE: $PASS pass, $FAIL fail — results in $RESULTS"
exit $(( FAIL > 0 ))
