# Shared stub environment for tests that run docker-stack-backup.sh end to end
# without a Docker daemon. Call stub_env_setup from setup(), stub_env_teardown from
# teardown().
#
# Provides on PATH:
#   docker     — records every invocation in $DOCKER_LOG; `compose ps --services
#                --filter status=running` prints $STATE_FILE; `compose stop` empties
#                it; `compose start <svcs>` / `compose up ... <svcs>` write <svcs> to it.
#                STUB_START_RC makes `compose start` fail with that code; STUB_PS_RC
#                makes `compose ps` fail (as a YAML error or unset ${VAR:?} does).
#                Plain `docker ps` (the label cross-check) prints $STUB_LIVE.
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
    [[ -n "${STUB_LIVE:-}" ]] && echo "$STUB_LIVE"
    exit 0
fi
[[ "$1" == compose ]] || exit 0
shift
case "$1" in
    ps)
        [[ "${STUB_PS_RC:-0}" -ne 0 ]] && { echo "stub: invalid compose project" >&2; exit "$STUB_PS_RC"; }
        cat "$STATE_FILE" ;;
    stop)  : > "$STATE_FILE" ;;
    start)
        shift
        [[ "${STUB_START_RC:-0}" -ne 0 ]] && exit "$STUB_START_RC"
        printf '%s\n' "$@" > "$STATE_FILE" ;;
    up)
        shift
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
