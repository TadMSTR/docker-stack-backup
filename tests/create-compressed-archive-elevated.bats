#!/usr/bin/env bats
# Tests for create_compressed_archive_elevated() in lib.sh (DSBAK-10 / #23).
# Requires: bats (apt install bats)
# Run:      bats tests/create-compressed-archive-elevated.bats
#
# The blocker: the elevation precondition used `[[ ! -x "$ELEVATION_HELPER_PATH" ]]`,
# which tests the execute bit AS THE UNPRIVILEGED CALLER. The helper is installed
# root:root 0750 by design (SECURITY.md/ELEVATION.md), so the caller has no execute
# bit on it — the check always failed and aborted every stack's backup before
# ELEVATION_CMD (sudo/doas) was ever invoked. A file mode 0600 owned by the
# (non-root) test runner reproduces that condition: the caller cannot execute it,
# exactly as with a root-owned 0750 helper, without needing an actual root fixture.
#
# ELEVATION_CMD is pinned to "sudo" (the function only accepts sudo|doas), so we
# shadow `sudo` on PATH with a stub that records its invocation instead of running
# the real helper. Reaching the stub proves the precondition was passed.

setup() {
    TEST_DIR="$(mktemp -d)"
    export LOG_FILE="$TEST_DIR/test.log"
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib.sh"

    if [[ $EUID -eq 0 ]]; then
        skip "these tests require an unprivileged test runner (EUID != 0) — root can execute a 0600 file, which defeats the -x repro"
    fi

    # A helper the caller cannot execute (mode 0600), standing in for the real
    # root:root 0750 install. `[[ -x ]]` is false for the caller; `[[ -f ]]` is true.
    HELPER="$TEST_DIR/docker-backup-tar-create.sh"
    printf '#!/usr/bin/env bash\n' > "$HELPER"
    chmod 0600 "$HELPER"

    # Stub `sudo` on PATH: record that we were reached, echo to stdout (which the
    # function redirects into the output file), and exit 0 — no real elevation.
    STUB_DIR="$TEST_DIR/bin"
    mkdir -p "$STUB_DIR"
    ELEVATION_MARKER="$TEST_DIR/sudo-was-called"
    cat > "$STUB_DIR/sudo" <<STUB
#!/usr/bin/env bash
echo "reached-elevation" > "$ELEVATION_MARKER"
echo "archive-bytes"
exit 0
STUB
    chmod 0755 "$STUB_DIR/sudo"
    PATH="$STUB_DIR:$PATH"

    export ELEVATION_CMD=sudo
    export ELEVATION_HELPER_PATH="$HELPER"
    export COMPRESSION_METHOD=none
    EXCLUDE_PATTERNS=()

    APPDATA_DIR="$TEST_DIR/appdata"; mkdir -p "$APPDATA_DIR/mystack"
    TMP_DIR="$TEST_DIR/tmp"; mkdir -p "$TMP_DIR"
    OUT_FILE="$TEST_DIR/mystack.tar"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "DSBAK-10: helper not caller-executable (0600) proceeds to the elevation call, not abort" {
    run create_compressed_archive_elevated "$OUT_FILE" \
        -C "$TMP_DIR" . -C "$APPDATA_DIR" mystack
    [ "$status" -eq 0 ]
    # The stub was actually reached — the precondition did not abort first.
    [ -f "$ELEVATION_MARKER" ]
    [[ "$(cat "$ELEVATION_MARKER")" == "reached-elevation" ]]
    # And the elevation call's stdout landed in the output file.
    [[ "$(cat "$OUT_FILE")" == "archive-bytes" ]]
}

@test "DSBAK-10: caller CAN execute the helper — still proceeds (regression is not perms-gated)" {
    chmod 0700 "$HELPER"
    run create_compressed_archive_elevated "$OUT_FILE" \
        -C "$TMP_DIR" . -C "$APPDATA_DIR" mystack
    [ "$status" -eq 0 ]
    [ -f "$ELEVATION_MARKER" ]
}

@test "helper path does not exist: still fails closed with a clear error" {
    export ELEVATION_HELPER_PATH="$TEST_DIR/does-not-exist.sh"
    run create_compressed_archive_elevated "$OUT_FILE" \
        -C "$TMP_DIR" . -C "$APPDATA_DIR" mystack
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
    [ ! -f "$ELEVATION_MARKER" ]
}

@test "ELEVATION_HELPER_PATH unset: fails closed before any elevation" {
    unset ELEVATION_HELPER_PATH
    run create_compressed_archive_elevated "$OUT_FILE" \
        -C "$TMP_DIR" . -C "$APPDATA_DIR" mystack
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not set"* ]]
    [ ! -f "$ELEVATION_MARKER" ]
}

@test "non-standard tar layout: fails closed rather than mis-invoking the privileged helper" {
    run create_compressed_archive_elevated "$OUT_FILE" \
        -C "$TMP_DIR" mystack
    [ "$status" -eq 1 ]
    [[ "$output" == *"standard layout"* ]]
    [ ! -f "$ELEVATION_MARKER" ]
}
