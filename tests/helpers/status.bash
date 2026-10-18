# Helpers for the status contract tests (status.json, .prom, coverage). Load after
# helpers/stub-env. No jq: python3 is already a hard requirement.

# js <file> <python expression over `d`> — prints the expression's value as JSON.
js() {
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2])))' "$1" "$2"
}

# Sets HOST, HOST_DIR, STATUS for the .bats files that load this helper.
# shellcheck disable=SC2034
status_setup() {
    HOST="$(hostname)"
    HOST_DIR="$BACKUP_DEST/$HOST"
    STATUS="$HOST_DIR/status.json"
    export LOCK_FILE="$TEST_DIR/run/dsb.lock"
    export COVERAGE_EXEMPTIONS_FILE="$TEST_DIR/coverage-exemptions.conf"
    unset STATUS_ENABLED STATUS_FILE PROM_TEXTFILE_DIR COVERAGE_IGNORE_PATHS PING_URL
}

# add_stack <name> [running-services...] — a second stack with its own appdata and
# compose config (stub). Running state is shared with the main stack via STATE_FILE.
add_stack() {
    local name="$1"
    mkdir -p "$DOCKHAND_BASE/$name" "$APPDATA_PATH/$name"
    echo "x" > "$APPDATA_PATH/$name/data.txt"
    cat > "$DOCKHAND_BASE/$name/compose.yaml" <<YAML
services:
  app:
    volumes:
      - $APPDATA_PATH/$name:/data
YAML
    cat > "$STUB_CONFIG_DIR/$name.json" <<JSON
{"services": {"app": {"volumes": [{"type": "bind", "source": "$APPDATA_PATH/$name", "target": "/data"}]}}}
JSON
}

# A curl stub that records its argv and any -K config it was given.
curl_stub() {
    export CURL_LOG="$TEST_DIR/curl.log"
    : > "$CURL_LOG"
    cat > "$BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf 'ARGV:' >> "$CURL_LOG"; printf ' %q' "$@" >> "$CURL_LOG"; echo >> "$CURL_LOG"
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -K ]]; then sed 's/^/CONFIG: /' "$2" >> "$CURL_LOG"; shift; fi
    shift
done
exit "${STUB_CURL_RC:-0}"
STUB
    chmod +x "$BIN_DIR/curl"
}
