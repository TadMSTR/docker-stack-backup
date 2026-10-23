#!/usr/bin/env bats
# The Prometheus textfile (0.6.0): node_exporter textfile format, gauges only, written
# only when PROM_TEXTFILE_DIR is set. promtool is used when installed; otherwise every
# line must pass a strict check (_strict below), which runs either way.

load helpers/stub-env
load helpers/status

setup() {
    stub_env_setup
    status_setup
    export PROM_TEXTFILE_DIR="$TEST_DIR/textfile"
    mkdir -p "$PROM_TEXTFILE_DIR"
    PROM="$PROM_TEXTFILE_DIR/docker_stack_backup.prom"
}

teardown() {
    stub_env_teardown
}

# Strict line test: every line is a HELP, a TYPE gauge, or a sample with only
# [A-Za-z0-9._-] label values and an integer value. HELP and TYPE appear once per
# metric, in that order, directly before its samples. No duplicate series.
_strict() {
    python3 -I - "$1" <<'EOF'
import re, sys
data = open(sys.argv[1], "rb").read()
assert data.endswith(b"\n"), "no trailing newline"
text = data.decode("ascii")
NAME = r"[a-zA-Z_:][a-zA-Z0-9_:]*"
help_re = re.compile(r"# HELP (%s) \S.*" % NAME)
type_re = re.compile(r"# TYPE (%s) gauge" % NAME)
sample_re = re.compile(r'(%s)\{((?:[a-zA-Z_][a-zA-Z0-9_]*="[A-Za-z0-9._-]*")(?:,[a-zA-Z_][a-zA-Z0-9_]*="[A-Za-z0-9._-]*")*)\} (-?[0-9]+)' % NAME)
seen_help, seen_type, series = set(), set(), set()
current = None
expect_type = None
for n, line in enumerate(text.split("\n")[:-1], 1):
    m = help_re.fullmatch(line)
    if m:
        name = m.group(1)
        assert name not in seen_help, "HELP twice: %s" % name
        seen_help.add(name); expect_type = name; current = None
        continue
    m = type_re.fullmatch(line)
    if m:
        name = m.group(1)
        assert name == expect_type, "TYPE without HELP: line %d" % n
        assert name not in seen_type, "TYPE twice: %s" % name
        seen_type.add(name); current = name; expect_type = None
        continue
    m = sample_re.fullmatch(line)
    assert m, "bad line %d: %r" % (n, line)
    assert m.group(1) == current, "sample outside its metric block: line %d" % n
    labels = tuple(sorted(m.group(2).split(",")))
    key = (m.group(1), labels)
    assert key not in series, "duplicate series line %d" % n
    series.add(key)
    assert 'host="' in m.group(2), "no host label: line %d" % n
print(len(series))
EOF
}

_promtool() {
    if command -v promtool >/dev/null; then
        promtool check metrics < "$1"
    fi
}

@test "a real run writes the .prom; it passes the strict line test (and promtool if present)" {
    run_backup
    [ "$status" -eq 0 ]
    [ -f "$PROM" ]
    _strict "$PROM"
    _promtool "$PROM"
    grep -qx "dsb_build_info{host=\"$HOST\",version=\"$(sed -n 's/^DSB_VERSION="\(.*\)"$/\1/p' "$BATS_TEST_DIRNAME/../lib.sh")\"} 1" "$PROM"
    grep -qx "dsb_last_run_outcome{host=\"$HOST\",outcome=\"success\"} 1" "$PROM"
    grep -qx "dsb_last_run_outcome{host=\"$HOST\",outcome=\"failed\"} 0" "$PROM"
    grep -qx "dsb_stacks{host=\"$HOST\",result=\"backed_up\"} 1" "$PROM"
    grep -qx "dsb_stack_result{host=\"$HOST\",reason=\"none\",result=\"backed_up\",stack=\"$STACK\"} 1" "$PROM"
    grep -qE "^dsb_stack_archive_bytes\{host=\"$HOST\",stack=\"$STACK\"\} [1-9][0-9]*$" "$PROM"
    grep -qE "^dsb_last_success_timestamp_seconds\{host=\"$HOST\"\} [1-9][0-9]{9}$" "$PROM"
    grep -qE "^dsb_stack_last_success_timestamp_seconds\{host=\"$HOST\",stack=\"$STACK\"\} [1-9][0-9]{9}$" "$PROM"
    grep -qx "dsb_coverage_items{class=\"archived\",host=\"$HOST\",stack=\"$STACK\"} 1" "$PROM"
    grep -qx "dsb_coverage_uncovered{host=\"$HOST\",stack=\"$STACK\"} 0" "$PROM"
    grep -qx "dsb_coverage_unknown{host=\"$HOST\",stack=\"$STACK\"} 0" "$PROM"
    for m in dsb_unowned_appdata_dirs dsb_unowned_appdata_unexempt dsb_unowned_appdata_unknown dsb_exemptions_stale; do
        grep -qE "^$m\{host=\"$HOST\"\} [0-9]+$" "$PROM"
    done
    [ "$(stat -c %a "$PROM")" = 644 ]
    # The temp file was renamed away.
    [ "$(ls "$PROM_TEXTFILE_DIR")" = docker_stack_backup.prom ]
}

@test "the .prom temp name does not end in .prom (collectors read every *.prom), same dir" {
    # Run finalize with os.replace recorded, to see the temp name actually used.
    run python3 -I - "$BATS_TEST_DIRNAME/.." "$PROM_TEXTFILE_DIR" <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import dsb_status
seen = []
real = os.replace
os.replace = lambda a, b: (seen.append((a, b)), real(a, b))
prom_dir = sys.argv[2]
sys.argv = ["dsb_status.py", "finalize", "--records", "/nonexistent", "--stack-base", "/nonexistent",
            "--appdata", "/nonexistent", "--host", "h", "--run-id", "r", "--version", "0",
            "--started", "1", "--prom-dir", prom_dir]
dsb_status.main()
(tmp, final), = seen
assert os.path.dirname(tmp) == os.path.dirname(final), (tmp, final)
assert final.endswith("/docker_stack_backup.prom"), final
assert not tmp.endswith(".prom"), tmp
print(os.path.basename(tmp))
PY
    [ "$status" -eq 0 ]
    [[ "${lines[-1]}" == docker_stack_backup.prom.[0-9]* ]]
}

@test "a .prom write failure exits non-zero and leaves no temp file" {
    mkdir "$PROM"      # a directory where the file goes: the rename fails
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot write $PROM"* ]]
    [ "$(ls "$PROM_TEXTFILE_DIR")" = docker_stack_backup.prom ]
}

@test "the strict line test fires on bad input (it can fail)" {
    printf '# HELP a x\n# TYPE a gauge\na{host="h"} 1\na{host="h"} 2\n' > "$TEST_DIR/dup.prom"
    run _strict "$TEST_DIR/dup.prom"
    [ "$status" -ne 0 ]
    printf '# HELP a x\n# TYPE a gauge\na{host="h",p="/opt/x"} 1\n' > "$TEST_DIR/path.prom"
    run _strict "$TEST_DIR/path.prom"
    [ "$status" -ne 0 ]
    printf '# HELP a x\n# TYPE a counter\na{host="h"} 1\n' > "$TEST_DIR/counter.prom"
    run _strict "$TEST_DIR/counter.prom"
    [ "$status" -ne 0 ]
}

@test "no paths or volume names in labels: uncovered items are counted, not named" {
    mkdir -p "$TEST_DIR/rw"
    cat > "$STUB_CONFIG_DIR/$STACK.json" <<JSON
{"services": {"app": {"volumes": [
  {"type": "bind", "source": "$TEST_DIR/rw", "target": "/x"},
  {"type": "volume", "source": "secretvol", "target": "/v"}]}}}
JSON
    run_backup
    [ "$status" -eq 0 ]
    _strict "$PROM"
    ! grep -q "$TEST_DIR" "$PROM" || false
    ! grep -q secretvol "$PROM" || false
    grep -qx "dsb_coverage_uncovered{host=\"$HOST\",stack=\"$STACK\"} 2" "$PROM"
}

@test "stack names that would need escaping become stack=\"_invalid\", merged, never duplicated" {
    for name in 'we ird' 'qu"ote'; do
        add_stack "$name"
    done
    run_backup
    _strict "$PROM"
    grep -q 'stack="_invalid"' "$PROM"
    grep -qx "dsb_stack_result{host=\"$HOST\",reason=\"none\",result=\"backed_up\",stack=\"_invalid\"} 2" "$PROM"
    [[ "$output" == *'not valid metric label values; reported as stack="_invalid"'* ]]
    # status.json keeps the real names.
    [ "$(js "$STATUS" 'sorted(s["name"] for s in d["stacks"])')" = '["qu\"ote", "stubstack", "we ird"]' ]
}

@test "an aborted run writes the .prom too: outcome aborted, last success carried" {
    run_backup
    [ "$status" -eq 0 ]
    last=$(grep "^dsb_last_success_timestamp_seconds" "$PROM" | awk '{print $2}')
    export MIN_FREE_GB=bad
    run_backup
    [ "$status" -eq 1 ]
    _strict "$PROM"
    grep -qx "dsb_last_run_outcome{host=\"$HOST\",outcome=\"aborted\"} 1" "$PROM"
    grep -qx "dsb_last_success_timestamp_seconds{host=\"$HOST\"} $last" "$PROM"
    grep -q "^dsb_stack_last_success_timestamp_seconds{host=\"$HOST\",stack=\"$STACK\"}" "$PROM"
}

@test "never succeeded: last success is 0, so a staleness alert fires" {
    export STUB_PS_RC=1
    run_backup
    grep -qx "dsb_last_success_timestamp_seconds{host=\"$HOST\"} 0" "$PROM"
    grep -qx "dsb_last_run_outcome{host=\"$HOST\",outcome=\"failed\"} 1" "$PROM"
}

@test "PROM_TEXTFILE_DIR unset: no .prom anywhere; dry run never writes one" {
    unset PROM_TEXTFILE_DIR
    run_backup
    [ "$status" -eq 0 ]
    [ -z "$(find "$TEST_DIR" -name '*.prom*')" ]
    export PROM_TEXTFILE_DIR="$TEST_DIR/textfile"
    run_backup --dry-run
    [ ! -e "$PROM" ]
}

@test "the .prom is written even with STATUS_ENABLED=false" {
    export STATUS_ENABLED=false
    run_backup
    [ "$status" -eq 0 ]
    [ -f "$PROM" ]
    [ ! -e "$STATUS" ]
}
