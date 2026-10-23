#!/usr/bin/env bats
# docker-backup-restic.sh, the root helper. Every negative probe is first run against a
# NAIVE helper (the obvious few lines of `sudo restic …`) and shown to fire; then the real
# helper is shown to refuse it (plan p5b, Design §2 and Verification 4).
#
# Unprivileged tests (rh_setup_user) run wherever a restic binary is found. The backup verb
# needs a private mount namespace, so its tests run under `unshare -r -m` (rh_setup_ns) and
# skip where user namespaces are disabled (GitHub runners). Two probes need two real uids
# and are left to p5c as real root: a different-uid process reading /proc/<restic pid>/fd/N
# or environ, and ptrace of restic (RESTIC.md "Verify as root").

load helpers/restic

setup() {
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    rh_teardown
    rm -rf -- "${TEST_DIR:?}"
}

# A stand-in restic that records what it was given: argv, environment, stdin, caps.
fake_restic() {
    cat > "$RH_BIN" <<STUB
#!/usr/bin/env bash
tr '\0' '\n' < /proc/\$\$/cmdline > "$RH_D/fake.argv"
tr '\0' '\n' < /proc/\$\$/environ > "$RH_D/fake.env"
grep -E '^(Cap(Eff|Prm|Inh|Bnd|Amb)|NoNewPrivs|Uid):' /proc/\$\$/status > "$RH_D/fake.status"
cat > "$RH_D/fake.stdin"
echo '{"message_type":"summary","snapshot_id":"00"}'
STUB
    chmod 0755 "$RH_BIN"
}

#######################################
# Constants and the caller
#######################################
@test "info prints the root-set constants and calls no restic" {
    rh_setup_user
    run bash "$RH" info
    [ "$status" -eq 0 ]
    [[ "$output" == *"host=testhost"* ]]
    [[ "$output" == *"floor_daily=7"* && "$output" == *"floor_weekly=4"* && "$output" == *"floor_monthly=0"* ]]
}

@test "refuses: RESTIC_HOST unset, RESTIC_RUN_AS root, a caller that is neither root nor RESTIC_RUN_AS" {
    rh_setup_user
    rh_write "$(id -un)" -e 's|^RESTIC_HOST=.*|RESTIC_HOST=""|'
    run bash "$RH" info
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESTIC_HOST is not set"* ]]
    rh_write root
    run bash "$RH" info
    [ "$status" -eq 2 ]
    [[ "$output" == *"must not be root"* ]]
    rh_write nobody
    run bash "$RH" snapshots
    [ "$status" -eq 2 ]
    [[ "$output" == *"run as root"* ]]
}

@test "refuses a password file readable by group/other, or a symlink; a group-writable restic" {
    rh_setup_user
    chmod 0440 "$RH_PW"
    run bash "$RH" snapshots
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESTIC_PASSWORD_FILE must not be readable"* ]]
    chmod 0400 "$RH_PW"
    ln -s "$RH_PW" "$RH_D/pwlink"
    rh_write "$(id -un)" -e "s|^RESTIC_PASSWORD_FILE=.*|RESTIC_PASSWORD_FILE=\"$RH_D/pwlink\"|"
    run bash "$RH" snapshots
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a regular file"* ]]
    rh_write "$(id -un)"
    chmod 0775 "$RH_BIN"
    run bash "$RH" snapshots
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESTIC_BIN must be owned"* ]]
}

@test "repo prints the repository id; wrong password exits 12, a missing repository 10" {
    rh_setup_user
    run bash "$RH" repo
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^id=[0-9a-f]{64}$ ]]
    chmod 0600 "$RH_PW"; printf 'wrong\n' > "$RH_PW"; chmod 0400 "$RH_PW"
    run bash "$RH" repo
    [ "$status" -eq 12 ]
    printf 'correct horse\n' > "$RH_D/pw2"; chmod 0400 "$RH_D/pw2"
    rh_write "$(id -un)" -e "s|^RESTIC_REPO=.*|RESTIC_REPO=\"$RH_D/no-repo\"|" \
        -e "s|^RESTIC_PASSWORD_FILE=.*|RESTIC_PASSWORD_FILE=\"$RH_D/pw2\"|"
    run bash "$RH" repo
    [ "$status" -eq 10 ]
}

#######################################
# The password and the environment
#######################################
@test "probe: the password never reaches restic's argv or environment, only its stdin (naive: RESTIC_PASSWORD fires)" {
    rh_setup_user
    fake_restic
    # Naive: the usual `RESTIC_PASSWORD=$(cat file) restic …`.
    RESTIC_PASSWORD="$(cat "$RH_PW")" "$RH_BIN" snapshots < /dev/null >/dev/null
    grep -q 'correct horse' "$RH_D/fake.env"          # fires: in /proc/<pid>/environ
    # Real helper.
    run bash "$RH" snapshots
    [ "$status" -eq 0 ]
    ! grep -q 'correct horse' "$RH_D/fake.env" || false
    ! grep -q 'correct horse' "$RH_D/fake.argv" || false
    ! grep -q -- '--password' "$RH_D/fake.argv" || false
    [ "$(cat "$RH_D/fake.stdin")" = "correct horse" ]
}

@test "probe: the caller's RESTIC_* environment does not reach restic (naive: RESTIC_REPOSITORY is honoured)" {
    rh_setup_user
    fake_restic
    export RESTIC_REPOSITORY=/tmp/elsewhere RESTIC_PASSWORD_COMMAND="cat /etc/shadow" GODEBUG=x
    "$RH_BIN" snapshots < /dev/null >/dev/null      # naive: inherits the environment
    grep -q '^RESTIC_REPOSITORY=/tmp/elsewhere' "$RH_D/fake.env"
    run bash "$RH" snapshots
    [ "$status" -eq 0 ]
    ! grep -q '^RESTIC_REPOSITORY=\|^RESTIC_PASSWORD_COMMAND=\|^GODEBUG=' "$RH_D/fake.env" || false
    grep -qx -- "--repo" "$RH_D/fake.argv"
    grep -qx -- "$RH_REPO" "$RH_D/fake.argv"
}

#######################################
# forget: floors, tag filter, grouping
#######################################
# day_back <n> — 2026-10-20 02:00:00 UTC minus n days (the test's restic runs with TZ=UTC).
day_back() {
    date -u -d "@$(( $(date -u -d '2026-10-20 02:00:00' +%s) - $1 * 86400 ))" '+%Y-%m-%d %H:%M:%S'
}

seed_days() {   # seed_days <stack> <host> <n> — one snapshot a day, n days back from 2026-10-20
    local i
    for ((i = 0; i < $3; i++)); do
        rh_seed "$1" "$2" "$(day_back "$i")"
    done
}

@test "probe: forget below the floors (naive: --keep-daily 1 erases the history); the real helper refuses" {
    rh_setup_user
    seed_days web "$RH_HOST" 10
    cp -a "$RH_REPO" "$RH_D/repo-copy"
    # Naive, on a copy of the repo: whatever counts the caller passes.
    env -i PATH=/usr/bin:/bin HOME=/nonexistent "$RH_BIN" --repo "$RH_D/repo-copy" --password-file "$RH_PW" \
        --no-cache forget -q --host "$RH_HOST" --tag dsb,stack:web --keep-daily 1 >/dev/null
    [ "$(env -i PATH=/usr/bin:/bin HOME=/nonexistent "$RH_BIN" --repo "$RH_D/repo-copy" --password-file "$RH_PW" --no-cache snapshots --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq 1 ]
    local bad
    for bad in "1 0 0" "6 4 0" "7 3 0" "0 0 0" "7 4 -1" "7 4 1001" "x 4 0" "07a 4 0"; do
        # shellcheck disable=SC2086
        run bash "$RH" forget web $bad
        [ "$status" -eq 2 ]
    done
    [ "$(rh_times web | wc -l)" -eq 10 ]
}

@test "probe: forget without a tag filter (naive) removes other stacks' snapshots; the real one touches only its stack and host" {
    rh_setup_user
    seed_days web "$RH_HOST" 10
    seed_days db "$RH_HOST" 10
    seed_days web otherhost 10
    cp -a "$RH_REPO" "$RH_D/repo-copy"
    # Naive: forget with the policy, no tag and no host filter.
    env -i PATH=/usr/bin:/bin HOME=/nonexistent "$RH_BIN" --repo "$RH_D/repo-copy" --password-file "$RH_PW" \
        --no-cache forget -q --group-by host --keep-daily 7 >/dev/null
    [ "$(env -i PATH=/usr/bin:/bin HOME=/nonexistent "$RH_BIN" --repo "$RH_D/repo-copy" --password-file "$RH_PW" --no-cache snapshots --json --tag stack:db | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -lt 10 ]
    run bash "$RH" forget web 7 4 0
    [ "$status" -eq 0 ]
    # 10-11 .. 10-20 seeded: 7 days (10-14 .. 10-20) + the newest of each ISO week with
    # data (10-20, 10-18, 10-11) = 8.
    rh_times web >&3
    [ "$(rh_times web | wc -l)" -eq 8 ]
    [ "$(rh_times db | wc -l)" -eq 10 ]
    [ "$(rh_times web otherhost | wc -l)" -eq 10 ]
}

@test "probe: grouping by host,tags with per-run tags forgets nothing (naive); the helper groups by host" {
    rh_setup_user
    local i
    for ((i = 0; i < 10; i++)); do
        (cd "$RH_D" && mkdir -p seed/web && echo "$i" > seed/web/s && cd seed && rh_restic backup -q --host "$RH_HOST" \
            --time "$(day_back "$i")" \
            --tag dsb --tag stack:web --tag kind:daily --tag "run:2026101${i}_020000" web >/dev/null)
    done
    cp -a "$RH_REPO" "$RH_D/repo-copy"
    env -i PATH=/usr/bin:/bin HOME=/nonexistent "$RH_BIN" --repo "$RH_D/repo-copy" --password-file "$RH_PW" \
        --no-cache forget -q --host "$RH_HOST" --tag dsb,stack:web --group-by host,tags --keep-daily 7 >/dev/null
    [ "$(env -i PATH=/usr/bin:/bin HOME=/nonexistent "$RH_BIN" --repo "$RH_D/repo-copy" --password-file "$RH_PW" --no-cache snapshots --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq 10 ]
    run bash "$RH" forget web 7 4 0
    [ "$status" -eq 0 ]
    # 10-11 .. 10-20 seeded: 7 days (10-14 .. 10-20) + the newest of each ISO week with
    # data (10-20, 10-18, 10-11) = 8.
    rh_times web >&3
    [ "$(rh_times web | wc -l)" -eq 8 ]
}

@test "forget with per-stack retention on backdated snapshots keeps exactly the expected set" {
    rh_setup_user
    # 120 days of daily snapshots (2026-06-23 .. 2026-10-20).
    seed_days web "$RH_HOST" 120
    seed_days signoz "$RH_HOST" 120
    run bash "$RH" forget web 7 4 6
    [ "$status" -eq 0 ]
    run bash "$RH" forget signoz 7 4 0
    [ "$status" -eq 0 ]
    # signoz 7d/4w: 10-14 .. 10-20, plus the newest snapshot of each of the last 4 ISO
    # weeks (10-20, 10-18, 10-11, 10-04); each rule counts on its own, so 9 in all.
    run rh_times signoz
    echo "$output" >&3
    [ "${#lines[@]}" -eq 9 ]
    [ "${lines[0]}" = "2026-10-04T02:00:00" ]
    [ "${lines[1]}" = "2026-10-11T02:00:00" ]
    [ "${lines[2]}" = "2026-10-14T02:00:00" ]
    [ "${lines[8]}" = "2026-10-20T02:00:00" ]
    # web 7d/4w/6m: the same 9 plus the newest of each month with data (June to
    # September; October's is 10-20, already kept), plus the oldest snapshot (06-23):
    # with fewer months than --keep-monthly asks for, restic (0.17+) keeps the oldest too.
    run rh_times web
    echo "$output" >&3
    [ "${#lines[@]}" -eq 14 ]
    [ "${lines[0]}" = "2026-06-23T02:00:00" ]
    [ "${lines[1]}" = "2026-06-30T02:00:00" ]
    [ "${lines[2]}" = "2026-07-31T02:00:00" ]
    [ "${lines[3]}" = "2026-08-31T02:00:00" ]
    [ "${lines[4]}" = "2026-09-30T02:00:00" ]
    [ "${lines[5]}" = "2026-10-04T02:00:00" ]
}

#######################################
# dump, check, snapshots
#######################################
@test "probe: dump of another stack's or another host's snapshot (naive dumps it); the real helper refuses" {
    rh_setup_user
    seed_days db "$RH_HOST" 1
    seed_days web otherhost 1
    seed_days web "$RH_HOST" 1
    local db_id other_id web_id
    db_id=$(rh_restic snapshots --json --tag stack:db | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
    other_id=$(rh_restic snapshots --json --host otherhost | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
    web_id=$(rh_restic snapshots --json --host "$RH_HOST" --tag stack:web | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
    rh_restic dump --archive tar "$db_id" / | tar -tf - | grep -q '^db/stamp'      # naive: fires
    run bash "$RH" dump web "$db_id"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no snapshot"* ]]
    run bash "$RH" dump web "$other_id"
    [ "$status" -eq 2 ]
    run bash "$RH" dump web "${web_id:0:8}"
    [ "$status" -eq 0 ]
    bash "$RH" dump web "${web_id:0:8}" | tar -tf - | grep -q '^web/stamp'
    local bad
    for bad in "${web_id:0:7}" "${web_id^^}" "latest" "--help" "$web_id/../x" "${web_id}0"; do
        run bash "$RH" dump web "$bad"
        [ "$status" -eq 2 ]
    done
}

@test "check takes n/N or x% only" {
    rh_setup_user
    seed_days web "$RH_HOST" 1
    run bash "$RH" check 1/4
    [ "$status" -eq 0 ]
    run bash "$RH" check 2.5%
    [ "$status" -eq 0 ]
    local bad
    for bad in 0/4 5/4 1/257 101% 100.5% 150% 0% 0.0% 0.00% "1/4 --x" "--read-data" "1/4;id" "" 1/0; do
        run bash "$RH" check "$bad"
        [ "$status" -eq 2 ]
    done
}

@test "snapshots lists this host's dsb snapshots only; stats is JSON" {
    rh_setup_user
    seed_days web "$RH_HOST" 2
    seed_days web otherhost 1
    run bash "$RH" snapshots web
    [ "$status" -eq 0 ]
    [ "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$output")" -eq 2 ]
    run bash "$RH" snapshots "../x"
    [ "$status" -eq 2 ]
    run bash "$RH" stats
    [ "$status" -eq 0 ]
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["snapshots_count"] == 2' "$output"
}

@test "unknown verbs and wrong argument counts are refused" {
    rh_setup_user
    run bash "$RH" restore
    [ "$status" -eq 2 ]
    run bash "$RH" forget web 7 4
    [ "$status" -eq 2 ]
    run bash "$RH" snapshots a b
    [ "$status" -eq 2 ]
    run bash "$RH"
    [ "$status" -eq 2 ]
}

#######################################
# backup (private mount namespace; local only)
#######################################
@test "backup needs root, after checking its arguments" {
    rh_setup_user
    run bash "$RH" backup "$RH_TMP" web 20261023_020001 daily
    [ "$status" -eq 2 ]
    [[ "$output" == *"backup needs root"* ]]
    run bash "$RH" backup "$RH_TMP" web 20261023_020001 weekly
    [[ "$output" == *"invalid run kind"* ]]
}

@test "backup: one snapshot with compose, .env and the stack, tagged, as RESTIC_HOST; summary on stdout" {
    rh_setup_ns
    run rh_ns backup "$RH_TMP" web 20261023_020001 daily
    [ "$status" -eq 0 ]
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["message_type"] == "summary" and len(d["snapshot_id"]) == 64' "$output"
    run rh_restic snapshots --json
    python3 - "$output" "$RH_STAGE" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
assert len(s) == 1, s
s = s[0]
assert s["hostname"] == "testhost", s
assert sorted(s["tags"]) == ["dsb", "kind:daily", "run:20261023_020001", "stack:web"], s["tags"]
assert sorted(s["paths"]) == sorted(sys.argv[2] + "/" + n for n in (".env", "compose.yaml", "web")), s["paths"]
PY
    run rh_restic ls latest
    [[ "$output" == *"/compose.yaml"* && "$output" == *"/.env"* && "$output" == *"/web/data/one"* ]]
    # The mounts ended with the namespace: the stage dir is empty again.
    [ -z "$(ls -A "$RH_STAGE")" ]
}

@test "backup: restic runs with CAP_DAC_READ_SEARCH only, no new privileges; it reads a 0000 file" {
    rh_setup_ns
    printf 'locked\n' > "$RH_APPDATA/web/data/zero"
    chmod 0000 "$RH_APPDATA/web/data/zero"
    run rh_ns backup "$RH_TMP" web 20261023_020001 daily
    [ "$status" -eq 0 ]
    [ "$(rh_restic dump latest /web/data/zero)" = "locked" ]
    fake_restic
    run rh_ns backup "$RH_TMP" web 20261023_020002 daily
    [ "$status" -eq 0 ]
    grep -q '^CapEff:[[:space:]]*0000000000000004$' "$RH_D/fake.status"
    grep -q '^CapBnd:[[:space:]]*0000000000000004$' "$RH_D/fake.status"
    grep -q '^CapAmb:[[:space:]]*0000000000000004$' "$RH_D/fake.status"
    grep -q '^NoNewPrivs:[[:space:]]*1$' "$RH_D/fake.status"
    [ "$(cat "$RH_D/fake.stdin")" = "correct horse" ]
    chmod 0600 "$RH_APPDATA/web/data/zero"
}

@test "probe: a declared path escaping /<stack>/, or another stack's, is refused (naive: --exclude passes through)" {
    rh_setup_user
    local bad
    for bad in "web/../x" "other/x" "web/" "web//a" "web/-a" "web/a b" "web/*" "/web/a" "web/a/.."; do
        run bash "$RH" backup "$RH_TMP" web 20261023_020001 daily -- "$bad"
        [ "$status" -eq 2 ]
        [[ "$output" == *"invalid declared path"* ]]
    done
    for bad in "--password-command=id" "-x" "a b" "a;b" '$(id)'; do
        run bash "$RH" backup "$RH_TMP" web 20261023_020001 daily "$bad"
        [ "$status" -eq 2 ]
        [[ "$output" == *"invalid exclude pattern"* ]]
    done
}

@test "backup refuses a temp dir that is not the caller's private dir, and a stack name that escapes" {
    rh_setup_ns
    chmod 0755 "$RH_TMP"
    run rh_ns backup "$RH_TMP" web 20261023_020001 daily
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be mode 0700"* ]]
    chmod 0700 "$RH_TMP"
    ln -s "$RH_TMP" "$RH_D/tmplink"
    run rh_ns backup "$RH_D/tmplink" web 20261023_020001 daily
    [ "$status" -eq 2 ]
    local bad
    for bad in .. . -web "web/x" "" "wéb"; do
        run rh_ns backup "$RH_TMP" "$bad" 20261023_020001 daily
        [ "$status" -eq 2 ]
    done
    run rh_ns backup "$RH_TMP" web 2026102_020001 daily
    [ "$status" -eq 2 ]
    rm -f "$RH_TMP/compose.yaml"
    run rh_ns backup "$RH_TMP" web 20261023_020001 daily
    [ "$status" -eq 2 ]
    [[ "$output" == *"no compose file"* ]]
}

@test "backup without --from-snapshot never asks the snapshot helper; with it, a missing snapshot fails" {
    rh_setup_ns
    RH_SNAP_HELPER="$RH_D/snap.sh"
    printf '#!/usr/bin/env bash\necho called >> %q\nexit 1\n' "$RH_D/snap.calls" > "$RH_SNAP_HELPER"
    chmod 0755 "$RH_SNAP_HELPER"
    rh_write root -e 's|^\[\[ "\$run_uid" != 0 \]\] .*|: # test copy: RESTIC_RUN_AS is the namespace root|'
    run rh_ns backup "$RH_TMP" web 20261023_020001 daily
    [ "$status" -eq 0 ]
    [ ! -e "$RH_D/snap.calls" ]
    run rh_ns backup "$RH_TMP" web 20261023_020001 daily --from-snapshot
    [ "$status" -eq 1 ]
    [ -e "$RH_D/snap.calls" ]
}

@test "F-01: a stack dir swapped for a symlink between the check and the bind is refused, nothing backed up" {
    rh_setup_ns
    mkdir -p "$RH_D/secret"
    echo "not the stack" > "$RH_D/secret/elsewhere"
    # The race, made deterministic: a mount shim that, just before the stack's bind, swaps
    # the (already checked) stack dir for a symlink to another directory.
    cat > "$RH_SHIM/mount" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == --rbind ]]; then
    mv -- "$RH_APPDATA/web" "$RH_APPDATA/web.real" && ln -s "$RH_D/secret" "$RH_APPDATA/web"
fi
exec /usr/bin/mount "\$@"
STUB
    chmod +x "$RH_SHIM/mount"
    run rh_ns backup "$RH_TMP" web 20261023_020001 daily
    echo "rc=$status $output" >&3
    rm -f "$RH_APPDATA/web"; mv "$RH_APPDATA/web.real" "$RH_APPDATA/web"
    [ "$status" -ne 0 ]
    [[ "$output" == *"replaced"* ]]
    [ "$(rh_restic snapshots --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq 0 ]
}

@test "F-01: a stack dir that is itself a symlink is refused at the check" {
    rh_setup_ns
    mv "$RH_APPDATA/web" "$RH_D/web-real"
    ln -s "$RH_D/web-real" "$RH_APPDATA/web"
    run rh_ns backup "$RH_TMP" web 20261023_020001 daily
    [ "$status" -eq 2 ]
    rm -f "$RH_APPDATA/web"; mv "$RH_D/web-real" "$RH_APPDATA/web"
}

@test "F-01: a stack dir reached through a symlinked parent is refused (the pre-F-01 helper backed it up)" {
    rh_setup_ns
    ln -s "$RH_APPDATA" "$RH_D/applink"
    local link_expr="s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$RH_D/applink\"|"
    # Probe first: the helper as it was before the F-01 fix (b574766) accepts the path.
    if git -C "$BATS_TEST_DIRNAME/.." cat-file -e b574766 2>/dev/null; then
        git -C "$BATS_TEST_DIRNAME/.." show b574766:docker-backup-restic.sh > "$RH_D/old-helper.sh"
        cp "$RH" "$RH.keep"
        sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$RH_D/applink\"|" \
            -e "s|^RESTIC_BIN=.*|RESTIC_BIN=\"$RH_BIN\"|" -e "s|^RESTIC_REPO=.*|RESTIC_REPO=\"$RH_REPO\"|" \
            -e "s|^RESTIC_PASSWORD_FILE=.*|RESTIC_PASSWORD_FILE=\"$RH_PW\"|" -e "s|^RESTIC_RUN_AS=.*|RESTIC_RUN_AS=\"root\"|" \
            -e "s|^RESTIC_HOST=.*|RESTIC_HOST=\"$RH_HOST\"|" -e "s|^RESTIC_CACHE_DIR=.*|RESTIC_CACHE_DIR=\"$RH_CACHE\"|" \
            -e "s|^RESTIC_STAGE_DIR=.*|RESTIC_STAGE_DIR=\"$RH_STAGE\"|" \
            -e "s|^PATH=.*|PATH=\"$RH_D/shim:/usr/sbin:/usr/bin:/sbin:/bin\"|" \
            -e 's|^\[\[ "\$run_uid" != 0 \]\] .*|: # test copy|' "$RH_D/old-helper.sh" > "$RH"
        run rh_ns backup "$RH_TMP" web 20261023_020001 daily
        [ "$status" -eq 0 ]                                     # fires
        cp "$RH.keep" "$RH"
    fi
    rh_write root -e 's|^\[\[ "\$run_uid" != 0 \]\] .*|: # test copy: RESTIC_RUN_AS is the namespace root|' -e "$link_expr"
    run rh_ns backup "$RH_TMP" web 20261023_020002 daily
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a plain directory at its canonical path"* ]]
}
