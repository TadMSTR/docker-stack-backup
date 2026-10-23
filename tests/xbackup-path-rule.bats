#!/usr/bin/env bats
# The declared-path rule exists in four places: dsb_status.py (xb_path_error, the
# reader), lib.sh (valid_declared_path, before tar or the helpers), the root tar helper
# and the root restic helper (they trust no caller). A root-owned helper cannot source
# the unprivileged lib, so the rule is duplicated on purpose; this test is what keeps the
# four copies equal.

setup() {
    # A locale where bash's [A-Za-z] is NOT ASCII ('é' matches it there): each copy must
    # pin LC_ALL=C itself. Without that, lib.sh and the helper accepted 'é' (found here).
    if locale -a 2>/dev/null | grep -qix 'en_US.utf8'; then
        export LC_ALL=en_US.UTF-8
    fi
    TEST_DIR="$(mktemp -d)"
    APPDATA="$TEST_DIR/appdata"
    mkdir -p "$APPDATA/st"
    TEMP_SRC="$(mktemp -d -p /tmp)"
    echo "services: {}" > "$TEMP_SRC/compose.yaml"
    HELPER="$TEST_DIR/helper.sh"
    sed "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-tar-create.sh" > "$HELPER"
    # The restic helper, unprivileged and as RESTIC_RUN_AS: it checks every argument and
    # then refuses with "backup needs root", so no restic binary is needed here.
    RHELPER="$TEST_DIR/restic-helper.sh"
    sed -e "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA\"|" \
        -e "s|^RESTIC_HOST=.*|RESTIC_HOST=\"h\"|" \
        -e "s|^RESTIC_RUN_AS=.*|RESTIC_RUN_AS=\"$(id -un)\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-restic.sh" > "$RHELPER"
}

teardown() {
    rm -rf "${TEST_DIR:?}" "${TEMP_SRC:?}"
}

PATHS=(
    a a/b models/blobs 'a.b' 'a_b' 'a-b' '.hidden' 'a/.hidden' 'a..b' '...' 'a/b/c/d/e'
    '' . .. a/.. ../a a/../b ./a a/. / /a a/ a//b -a a/-b '*' 'a*' 'a?' '[a]' 'a b'
    $'a\nb' $'a\tb' 'a\b' 'é' '~' '$x' 'a:b' 'a@b' 'a=b'
)

python_ok() {
    python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import dsb_status as d; sys.exit(0 if d.xb_path_error(sys.argv[2]) is None else 1)' \
        "$BATS_TEST_DIRNAME/.." "$1"
}

lib_ok() {
    bash -c 'source "$1"; valid_declared_path "$2"' _ "$BATS_TEST_DIRNAME/../lib.sh" "$1"
}

helper_ok() {
    bash "$HELPER" none "$TEMP_SRC" "$APPDATA" st -- "st/$1" > /dev/null 2>&1
}

restic_ok() {
    local out
    out=$(bash "$RHELPER" backup "$TEMP_SRC" st 20261023_020001 daily -- "st/$1" 2>&1) && return 1
    [[ "$out" == *"backup needs root"* ]]
}

@test "python, lib.sh and both root helpers accept and refuse exactly the same paths" {
    # The restic helper copy runs as RESTIC_RUN_AS = the caller, which it refuses for root
    # (CR-14): as root every path would read as refused.
    [[ $EUID -ne 0 ]] || skip "the restic helper copy cannot run as root"
    local p py lib hp rp long
    long=$(printf 'a%.0s' {1..255})
    for p in "${PATHS[@]}" "$long" "${long}b" "$long/x"; do
        python_ok "$p" && py=ok || py=refused
        lib_ok "$p" && lib=ok || lib=refused
        helper_ok "$p" && hp=ok || hp=refused
        restic_ok "$p" && rp=ok || rp=refused
        printf 'path=%q python=%s lib=%s helper=%s restic=%s\n' "$p" "$py" "$lib" "$hp" "$rp" >&3
        [ "$py" = "$lib" ]
        [ "$py" = "$hp" ]
        [ "$py" = "$rp" ]
    done
}

@test "a sample of the rule's verdicts (so equal-but-wrong copies would still fail)" {
    lib_ok models/blobs
    lib_ok .hidden
    ! lib_ok .. || false
    ! lib_ok a/../b || false
    ! lib_ok /a || false
    ! lib_ok -a || false
    ! lib_ok 'a*' || false
    ! lib_ok '' || false
}

@test "the helper refuses a declared path for another stack, and '--' with nothing after it" {
    mkdir -p "$APPDATA/other"
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" st -- "other/x"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid declared path"* ]]
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" st --
    [ "$status" -eq 2 ]
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" st -- "st"
    [ "$status" -eq 2 ]
}
