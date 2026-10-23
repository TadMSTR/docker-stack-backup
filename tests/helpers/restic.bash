# Helpers for the restic tests. Load after helpers/stub-env where a backup runs.
#
# restic itself: $DSB_TEST_RESTIC, else `restic` on PATH, else .scratch/restic in the
# checkout (a copy, never the system's or Backrest's binary). Tests that need it call
# need_restic, which skips when there is none.
#
# Two ways to run the REAL docker-backup-restic.sh, constants rewritten by sed:
#   rh_setup_user  — unprivileged, as the current user with RESTIC_RUN_AS = that user.
#                    No privilege drop is possible or attempted. Every verb but backup.
#   rh_setup_ns    — under `unshare -r -m` (user + mount namespace, uid 0 = you). Needs
#                    user namespaces (skipped on GitHub runners). For backup. Only uid 0 is
#                    mapped there, so two changes are made, both to the copy under test:
#                    the "RESTIC_RUN_AS must not be root" refusal is removed (RESTIC_RUN_AS
#                    = root), and a setpriv shim turns --clear-groups (setgroups is denied
#                    in such a namespace) into --keep-groups. The capability set is real:
#                    restic runs with CAP_DAC_READ_SEARCH only. The uid drop to a dedicated
#                    user is verified as real root in p5c (RESTIC.md "Verify as root").
# Both create $RH (the helper copy), $RH_REPO (initialised), $RH_PW (0400 password file),
# $RH_HOST, $RH_APPDATA (with stack $RH_STACK), $RH_TMP (a 0700 temp dir under /tmp with
# compose.yaml and .env), and rh_restic <args> (restic on that repo, as the test user).
# Set RH_APPDATA before the setup call to use an existing appdata root (stack $RH_STACK
# is then created in it only if missing).

rh_restic_bin() {
    local repo; repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    if [[ -n "${DSB_TEST_RESTIC:-}" ]]; then
        echo "$DSB_TEST_RESTIC"
    elif command -v restic >/dev/null 2>&1; then
        command -v restic
    elif [[ -x "$repo/.scratch/restic" ]]; then
        echo "$repo/.scratch/restic"
    else
        return 1
    fi
}

need_restic() {
    RESTIC_TEST_BIN=$(rh_restic_bin) || skip "no restic binary (set DSB_TEST_RESTIC)"
    RESTIC_TEST_BIN="$(cd "$(dirname "$RESTIC_TEST_BIN")" && pwd)/$(basename "$RESTIC_TEST_BIN")"
    export RESTIC_TEST_BIN
}

need_userns() {
    unshare -r -m true 2>/dev/null || skip "unshare -r -m not available (user namespaces disabled)"
}

# rh_common <dir> — the parts both modes share.
rh_common() {
    RH_D="$1"
    mkdir -p "$RH_D"
    RH_HOST="testhost"
    RH_STACK="${RH_STACK:-web}"
    # RH_APPDATA preset (e.g. to the stub env's APPDATA_PATH) is kept.
    RH_APPDATA="${RH_APPDATA:-$RH_D/appdata}"
    RH_REPO="$RH_D/repo"
    RH_PW="$RH_D/password"
    RH_CACHE="$RH_D/cache"
    RH_STAGE="$RH_D/stage"
    RH_SHIM="$RH_D/shim"
    RH_BIN="$RH_D/restic"
    mkdir -p "$RH_SHIM"
    if [[ ! -d "$RH_APPDATA/$RH_STACK" ]]; then
        mkdir -p "$RH_APPDATA/$RH_STACK/data"
        echo "one" > "$RH_APPDATA/$RH_STACK/data/one"
    fi
    printf 'correct horse\n' > "$RH_PW"
    chmod 0400 "$RH_PW"
    # A copy owned by the test user, 0755 (the helper refuses a group-writable binary).
    cp "$RESTIC_TEST_BIN" "$RH_BIN"
    chmod 0755 "$RH_BIN"
    RH_TMP="$(mktemp -d -p /tmp)"
    echo "services: {web: {image: nginx}}" > "$RH_TMP/compose.yaml"
    echo "WEB_PORT=80" > "$RH_TMP/.env"
    chmod 0644 "$RH_TMP/compose.yaml"
    chmod 0600 "$RH_TMP/.env"
    export RH_D RH_HOST RH_STACK RH_APPDATA RH_REPO RH_PW RH_CACHE RH_STAGE RH_BIN RH_TMP
    rh_restic init -q >/dev/null
}

# rh_write <run_as> [extra sed expressions...] — (re)writes $RH from the real helper.
rh_write() {
    local run_as="$1"; shift
    RH="$RH_D/docker-backup-restic.sh"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$RH_APPDATA\"|" \
        -e "s|^SNAPSHOT_HELPER=.*|SNAPSHOT_HELPER=\"${RH_SNAP_HELPER:-/nonexistent}\"|" \
        -e "s|^RESTIC_BIN=.*|RESTIC_BIN=\"$RH_BIN\"|" \
        -e "s|^RESTIC_REPO=.*|RESTIC_REPO=\"$RH_REPO\"|" \
        -e "s|^RESTIC_PASSWORD_FILE=.*|RESTIC_PASSWORD_FILE=\"$RH_PW\"|" \
        -e "s|^RESTIC_RUN_AS=.*|RESTIC_RUN_AS=\"$run_as\"|" \
        -e "s|^RESTIC_HOST=.*|RESTIC_HOST=\"$RH_HOST\"|" \
        -e "s|^RESTIC_CACHE_DIR=.*|RESTIC_CACHE_DIR=\"$RH_CACHE\"|" \
        -e "s|^RESTIC_STAGE_DIR=.*|RESTIC_STAGE_DIR=\"$RH_STAGE\"|" \
        -e "s|^PATH=.*|PATH=\"$RH_SHIM:/usr/sbin:/usr/bin:/sbin:/bin\"|" \
        "$@" "$BATS_TEST_DIRNAME/../docker-backup-restic.sh" > "$RH"
    chmod 0755 "$RH"
    export RH
}

rh_setup_user() {
    need_restic
    rh_common "${TEST_DIR:?}/rh"
    mkdir -p "$RH_CACHE"
    chmod 0700 "$RH_CACHE"
    rh_write "$(id -un)"
}

rh_setup_ns() {
    need_restic
    need_userns
    rh_common "${TEST_DIR:?}/rh"
    mkdir -p "$RH_CACHE" "$RH_STAGE"
    chmod 0700 "$RH_CACHE" "$RH_STAGE"
    cat > "$RH_SHIM/setpriv" <<'STUB'
#!/usr/bin/env bash
# Inside `unshare -r` setgroups(2) is denied: keep the (single, mapped) group instead.
args=()
for a in "$@"; do
    [[ "$a" == --clear-groups ]] && a=--keep-groups
    args+=("$a")
done
exec /usr/bin/setpriv "${args[@]}"
STUB
    chmod +x "$RH_SHIM/setpriv"
    rh_write root -e 's|^\[\[ "\$run_uid" != 0 \]\] .*|: # test copy: RESTIC_RUN_AS is the namespace root|'
    grep -q '^: # test copy' "$RH"
}

# rh_ns <args...> — the helper as (namespace) root.
rh_ns() {
    unshare -r -m bash "$RH" "$@"
}

# rh_restic <args...> — restic on the test repo, as the test user.
rh_restic() {
    env -i PATH=/usr/bin:/bin HOME=/nonexistent TZ=UTC RESTIC_CACHE_DIR="$RH_D/cache-test" \
        "$RH_BIN" --repo "$RH_REPO" --password-file "$RH_PW" "$@"
}

# rh_seed <stack> <host> <time> — one snapshot, as the backup would tag it, made directly.
rh_seed() {
    local stack="$1" host="$2" t="$3" src="$RH_D/seed/$1"
    mkdir -p "$src"
    echo "$t" > "$src/stamp"
    (cd "$RH_D/seed" && rh_restic backup -q --host "$host" --time "$t" \
        --tag dsb --tag "stack:$stack" --tag kind:daily --tag "run:x" "$stack" >/dev/null)
}

# rh_times <stack> [host] — the stack's snapshot times on the host, sorted, one per line.
rh_times() {
    rh_restic snapshots --json --host "${2:-$RH_HOST}" --tag "dsb,stack:$1" \
        | python3 -c 'import json,sys; [print(s["time"][:19]) for s in sorted(json.load(sys.stdin), key=lambda s: s["time"])]'
}

rh_teardown() {
    rm -rf -- "${RH_TMP:-/nonexistent-rh}"
}
