#!/usr/bin/env bats
# The declared-path rule exists in three places: dsb_status.py (xb_path_error, the
# reader), lib.sh (valid_declared_path, before tar or the helper) and the root tar helper
# (it trusts no caller). A root-owned helper cannot source the unprivileged lib, so the
# rule is duplicated on purpose; this test is what keeps the three copies equal.

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

@test "python, lib.sh and the root helper accept and refuse exactly the same paths" {
    local p py lib hp long
    long=$(printf 'a%.0s' {1..255})
    for p in "${PATHS[@]}" "$long" "${long}b" "$long/x"; do
        python_ok "$p" && py=ok || py=refused
        lib_ok "$p" && lib=ok || lib=refused
        helper_ok "$p" && hp=ok || hp=refused
        printf 'path=%q python=%s lib=%s helper=%s\n' "$p" "$py" "$lib" "$hp" >&3
        [ "$py" = "$lib" ]
        [ "$py" = "$hp" ]
    done
}

@test "a sample of the rule's verdicts (so equal-but-wrong copies would still fail)" {
    lib_ok models/blobs
    lib_ok .hidden
    ! lib_ok ..
    ! lib_ok a/../b
    ! lib_ok /a
    ! lib_ok -a
    ! lib_ok 'a*'
    ! lib_ok ''
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
