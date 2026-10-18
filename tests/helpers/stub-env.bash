# Shared stub environment for tests that run docker-stack-backup.sh end to end
# without a Docker daemon. Call stub_env_setup from setup(), stub_env_teardown from
# teardown().
#
# Provides on PATH:
#   docker     — records every invocation in $DOCKER_LOG; `compose ps --services
#                --filter status=running` prints $STATE_FILE; `compose stop` empties
#                it; `compose start <svcs>` / `compose up ... <svcs>` write <svcs> to it.
#                STUB_START_RC makes `compose start` fail with that code (STUB_STOP_RC
#                and STUB_UP_RC do the same for `stop` and `up`). STUB_SIGNAL_ON_STOP=TERM
#                sends that signal to the running docker-stack-backup.sh on the first
#                `compose stop` (an operator's Ctrl-C or a timeout wrapper); STUB_PS_RC
#                makes `compose ps` fail (as a YAML error or unset ${VAR:?} does).
#                Plain `docker ps` (the label cross-check) prints $STUB_LIVE; with a
#                `volume=` filter it prints $STUB_LIVE_VOLUME instead. `compose config`
#                prints $STUB_CONFIG_DIR/<stack dir name>.json (exit 1 with a message
#                if absent, or exit $STUB_CONFIG_RC with STUB_CONFIG_RC set).
#   systemctl  — always reports docker active.
#   sudo       — transparent (exec "$@"), so ELEVATION_CMD=sudo runs unprivileged.
# And $HELPER, a stand-in elevation helper that tars the standard layout to stdout.
# STUB_HELPER_FAIL=1 makes it write a partial archive and exit 1.

stub_env_setup() {
    TEST_DIR="$(mktemp -d)"
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    DOCKHAND_BASE="$TEST_DIR/docker"
    APPDATA_PATH="$TEST_DIR/appdata"
    BACKUP_DEST="$TEST_DIR/backups"
    mkdir -p "$DOCKHAND_BASE" "$APPDATA_PATH" "$BACKUP_DEST"

    STACK="stubstack"
    mkdir -p "$DOCKHAND_BASE/$STACK" "$APPDATA_PATH/$STACK"
    echo "appdata-content" > "$APPDATA_PATH/$STACK/data.txt"
    cat > "$DOCKHAND_BASE/$STACK/docker-compose.yml" <<YAML
services:
  app:
    image: busybox
    volumes:
      - $APPDATA_PATH/$STACK:/data
  worker:
    image: busybox
YAML

    export STUB_CONFIG_DIR="$TEST_DIR/compose-config"
    mkdir -p "$STUB_CONFIG_DIR"
    cat > "$STUB_CONFIG_DIR/$STACK.json" <<JSON
{"name": "$STACK", "services": {
  "app": {"image": "busybox", "volumes": [
    {"type": "bind", "source": "$APPDATA_PATH/$STACK", "target": "/data", "bind": {}}]},
  "worker": {"image": "busybox"}}}
JSON

    export DOCKER_LOG="$TEST_DIR/docker.log"
    export STATE_FILE="$TEST_DIR/running"
    : > "$DOCKER_LOG"
    printf 'app\nworker\n' > "$STATE_FILE"

    BIN_DIR="$TEST_DIR/bin"
    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
[[ "$1" == info ]] && exit 0
if [[ "$1" == ps ]]; then
    if [[ "$*" == *"--filter volume="* ]]; then
        [[ -n "${STUB_LIVE_VOLUME:-}" ]] && echo "$STUB_LIVE_VOLUME"
    else
        [[ -n "${STUB_LIVE:-}" ]] && echo "$STUB_LIVE"
    fi
    exit 0
fi
[[ "$1" == compose ]] || exit 0
shift
case "$1" in
    ps)
        [[ "${STUB_PS_RC:-0}" -ne 0 ]] && { echo "stub: invalid compose project" >&2; exit "$STUB_PS_RC"; }
        cat "$STATE_FILE" ;;
    config)
        [[ "${STUB_CONFIG_RC:-0}" -ne 0 ]] && { echo "stub: services.app.image must be a string" >&2; exit "$STUB_CONFIG_RC"; }
        f="${STUB_CONFIG_DIR:-/nonexistent}/$(basename "$PWD").json"
        [[ -f "$f" ]] || { echo "stub: no config for $(basename "$PWD")" >&2; exit 1; }
        cat "$f" ;;
    stop)
        if [[ -n "${STUB_SIGNAL_ON_STOP:-}" && ! -e "$DOCKER_LOG.signalled" ]]; then
            : > "$DOCKER_LOG.signalled"
            p=$PPID
            while [[ "$p" -gt 1 ]]; do
                if tr '\0' ' ' < "/proc/$p/cmdline" | grep -q 'docker-stack-backup\.sh'; then
                    kill -"$STUB_SIGNAL_ON_STOP" "$p"; break
                fi
                p=$(awk '{print $4}' "/proc/$p/stat")
            done
        fi
        [[ "${STUB_STOP_RC:-0}" -ne 0 ]] && exit "$STUB_STOP_RC"
        : > "$STATE_FILE" ;;
    start)
        shift
        [[ "${STUB_START_RC:-0}" -ne 0 ]] && exit "$STUB_START_RC"
        printf '%s\n' "$@" > "$STATE_FILE" ;;
    up)
        shift
        [[ "${STUB_UP_RC:-0}" -ne 0 ]] && exit "$STUB_UP_RC"
        svcs=()
        for a in "$@"; do
            case "$a" in -d|--no-recreate|--pull|never|--no-build|--no-deps) ;; *) svcs+=("$a") ;; esac
        done
        printf '%s\n' "${svcs[@]}" > "$STATE_FILE" ;;
esac
exit 0
STUB
    cat > "$BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat > "$BIN_DIR/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "$BIN_DIR"/*

    HELPER="$TEST_DIR/tar-create-stub.sh"
    cat > "$HELPER" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# args: <compression> <temp_dir> <appdata_path> <stack_name> [excludes...]
if [[ "${STUB_HELPER_FAIL:-0}" == 1 ]]; then
    printf 'partial-archive-bytes'
    exit 1
fi
exec tar -cf - -C "$2" . -C "$3" "$4"
STUB
    chmod +x "$HELPER"

    export PATH="$BIN_DIR:$PATH"
    export DOCKHAND_BASE DOCKHAND_APPEND_HOSTNAME=false APPDATA_PATH BACKUP_DEST
    export COMPRESSION_METHOD=none
    export ELEVATION_CMD=sudo ELEVATION_HELPER_PATH="$HELPER"
    export NOTIFY_ON_SUCCESS=false NOTIFY_ON_FAILURE=false
    export MAX_RESTART_ATTEMPTS=1 RESTART_RETRY_DELAY=0
}

stub_env_teardown() {
    rm -rf "${TEST_DIR:?}"
}

run_backup() {
    run bash "$BATS_TEST_DIRNAME/../docker-stack-backup.sh" "$@"
}
