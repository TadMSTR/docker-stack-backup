# Helpers for the x-backup tier tests. Load after helpers/stub-env (and helpers/status
# where status.json is read).

# xb_config <json> — the stub `docker compose config` output for $STACK, with <json> as
# its top-level x-backup value. With no argument, no x-backup key at all.
xb_config() {
    local xb="${1:-}"
    local extra=""
    [[ -n "$xb" ]] && extra=", \"x-backup\": $xb"
    cat > "$STUB_CONFIG_DIR/$STACK.json" <<JSON
{"name": "$STACK", "services": {
  "app": {"image": "busybox", "volumes": [
    {"type": "bind", "source": "$APPDATA_PATH/$STACK", "target": "/data", "bind": {}}]},
  "worker": {"image": "busybox"}}$extra}
JSON
}

# xb_read [run_kind] — runs `dsb_status.py xbackup` for $STACK. Sets XB_OUT (the record
# file) and XB_PATHS (the excluded paths, one per line; NULs turned into newlines).
xb_read() {
    XB_OUT="$TEST_DIR/xb.json"
    rm -f "$XB_OUT"
    run bash -c 'cd "$1" && python3 -I "$2" xbackup --stack-path "$3" --appdata-dir "$4" --run-kind "$5" --out "$6" 2>"$7" | tr "\0" "\n"' \
        _ "$TEST_DIR" "$BATS_TEST_DIRNAME/../dsb_status.py" "$DOCKHAND_BASE/$STACK" \
        "$APPDATA_PATH/$STACK" "${1:-daily}" "$XB_OUT" "$TEST_DIR/xb.err"
    # shellcheck disable=SC2034,SC2154  # $output is set by bats' run; XB_PATHS is read by the tests
    XB_PATHS="$output"
}

# xb <python expression over `d`> — a field of the last xb_read's record, as JSON.
xb() {
    js "$XB_OUT" "$1"
}

# A fixture tree under the stack's appdata for the tar tests.
xb_tree() {
    local a="$APPDATA_PATH/$STACK"
    mkdir -p "$a/a/b/deep" "$a/a/bc" "$a/x/a/b" "$a/models/blobs" "$a/models/manifests" \
        "$a/cache/clamav" "$a/idx"
    local f
    for f in a/b/f a/b/deep/g a/bc/f x/a/b/f models/blobs/sha models/manifests/m \
        cache/clamav/db idx/i; do
        echo "$f" > "$a/$f"
    done
}

# members <archive> — sorted member list.
members() {
    tar -tf "$1" | sort
}
