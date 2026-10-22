#!/usr/bin/env bats
# Tests for docker-backup-tar-create.sh — the restricted elevation helper.
# Requires: bats (apt install bats)
# Run:      bats tests/tar-create-helper.bats
#
# The shipped helper bakes ALLOWED_APPDATA_PATH in as a root-owned constant. To exercise
# the validation logic and happy path without needing /opt/appdata (or root), each test
# runs a copy of the helper whose ALLOWED_APPDATA_PATH line is rewritten to a temp dir.
# The validation logic under test is unchanged.

setup() {
    TEST_DIR="$(mktemp -d)"
    APPDATA="$TEST_DIR/appdata"
    mkdir -p "$APPDATA/mystack"
    echo "payload" > "$APPDATA/mystack/file.txt"

    # temp_dir arg must be a single path component under /tmp (helper's regex)
    TEMP_SRC="$(mktemp -d -p /tmp)"
    echo "services: {}" > "$TEMP_SRC/compose.yaml"

    HELPER="$TEST_DIR/helper.sh"
    sed "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA\"|" \
        "$BATS_TEST_DIRNAME/../docker-backup-tar-create.sh" > "$HELPER"
    chmod +x "$HELPER"
}

teardown() {
    rm -rf "$TEST_DIR" "$TEMP_SRC"
    rm -f -- "${PROBE_LINK:-/nonexistent}"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "valid invocation writes a readable archive to stdout" {
    bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack > "$TEST_DIR/out.tar"
    run tar -tf "$TEST_DIR/out.tar"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mystack/file.txt"* ]]
    [[ "$output" == *"compose.yaml"* ]]
}

@test "valid exclude pattern is accepted" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack "*.log"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Argument validation — the security boundary
# ---------------------------------------------------------------------------

@test "rejects a crafted --checkpoint exclude pattern (GTFOBins primitive)" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack "--checkpoint=1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid exclude pattern"* ]]
}

@test "rejects a --checkpoint-action=exec exclude pattern" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack "--checkpoint-action=exec=sh shell.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid exclude pattern"* ]]
}

@test "rejects an appdata_path outside the allowlist" {
    run bash "$HELPER" none "$TEMP_SRC" /etc mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid appdata_path"* ]]
}

@test "rejects an invalid compression method" {
    run bash "$HELPER" zip "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid compression"* ]]
}

@test "rejects a temp_dir outside /tmp" {
    run bash "$HELPER" none /etc "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid temp_dir"* ]]
}

@test "rejects a temp_dir with nested path components" {
    run bash "$HELPER" none "/tmp/a/b" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid temp_dir"* ]]
}

@test "rejects a stack_name containing a slash (path traversal)" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" "../../etc"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid stack_name"* ]]
}

@test "rejects the bare '..' token (would archive the parent of the appdata root)" {
    # Regression for H-1: '..' passes the char-class regex and -d "<root>/.." is always
    # true, so without an explicit reject it archives one level above ALLOWED_APPDATA_PATH.
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" ".."
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid stack_name"* ]]
}

@test "rejects the bare '.' token (would archive the entire appdata root)" {
    # Regression for L-1: '.' archives every stack instead of one.
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" "."
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid stack_name"* ]]
}

@test "rejects a leading-dash stack_name" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" "-C/etc"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid stack_name"* ]]
}

@test "rejects a nonexistent stack appdata dir" {
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" nosuchstack
    [ "$status" -eq 2 ]
    [[ "$output" == *"stack appdata dir not found"* ]]
}

@test "exits 2 with usage when given too few arguments" {
    run bash "$HELPER" none "$TEMP_SRC"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}

# ---------------------------------------------------------------------------
# temp_dir must be the caller's own private dir (audit p5a F-01, High). Each probe is
# first run against the 0.6.0 helper from main, to show it fires, then refused.
# ---------------------------------------------------------------------------

# Sets OLD_HELPER. Not in a $( ): `skip` in a command substitution does not skip the
# test. CI's shallow checkout has no 74ea297, so these probes skip there.
old_helper() {
    OLD_HELPER="$TEST_DIR/old-helper.sh"
    git -C "$BATS_TEST_DIRNAME/.." show 74ea297:docker-backup-tar-create.sh 2>/dev/null \
        | sed "s|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH=\"$APPDATA\"|" > "$OLD_HELPER"
    [[ -s "$OLD_HELPER" ]] || skip "no 74ea297 (0.6.0) in this checkout (shallow clone)"
}

@test "probe: a /tmp symlink to another directory is archived by the 0.6.0 helper, refused now" {
    local secret="$TEST_DIR/secret"
    mkdir -p "$secret" && echo topsecret > "$secret/shadow-like"
    local link; link="/tmp/dsb-f01-probe-$$"
    PROBE_LINK="$link"
    ln -s "$secret" "$link"
    run bash "$HELPER" none "$link" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"temp_dir is a symlink"* ]]
    # Last, so the refusal above is checked even where the 0.6.0 helper is unavailable.
    old_helper
    bash "$OLD_HELPER" none "$link" "$APPDATA" mystack > "$TEST_DIR/old.tar"
    rm -f "$link"
    tar -tf "$TEST_DIR/old.tar" | grep -qx './shadow-like'          # fires on 0.6.0
}

@test "probe: a temp_dir owned by someone else (e.g. a root-owned dir in /tmp) is refused" {
    # The invoking user as sudo reports it: SUDO_UID. A dir we own, claimed by another
    # uid, stands in for a root-owned /tmp dir (PrivateTmp) on an unprivileged runner.
    SUDO_UID=$((EUID + 1)) SUDO_GID=$((EUID + 1)) run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"not owned by the invoking user"* ]]
    old_helper
    SUDO_UID=$((EUID + 1)) SUDO_GID=$((EUID + 1)) bash "$OLD_HELPER" none "$TEMP_SRC" "$APPDATA" mystack > /dev/null   # 0.6.0: accepted
}

@test "a temp_dir with group or other access is refused (mktemp -d gives 0700)" {
    chmod 0755 "$TEMP_SRC"
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be mode 0700"* ]]
    chmod 0700 "$TEMP_SRC"
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 0 ]
}

@test "SUDO_UID that is not a number is refused" {
    SUDO_UID="0;x" run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot tell the invoking user"* ]]
}

@test "R2-01/R3-01: a symlink swapped in after the -L test is refused after cd -P (kernel cwd check)" {
    # The race is made deterministic: a copy of the helper without its `! -L` test, given
    # a symlink. Only the cwd-vs-lstat inode check stands between it and the target.
    local secret="$TEST_DIR/secret"
    mkdir -m 0700 "$secret" && echo topsecret > "$secret/shadow-like"
    local link="/tmp/dsb-r201-probe-$$"
    PROBE_LINK="$link"
    ln -s "$secret" "$link"
    local nolink="$TEST_DIR/helper-no-L.sh"
    grep -v 'temp_dir is a symlink' "$HELPER" > "$nolink"
    ! grep -q 'temp_dir is a symlink' "$nolink"
    run bash "$nolink" none "$link" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"temp_dir was replaced while it was being entered"* ]]
    [[ "$output" != *shadow-like* ]]
    # A swap-back defeats a check of bash's own path string (builtin `pwd -P`, R3-01): the
    # inode check reads the kernel's cwd instead. Shown with the check removed as well:
    # then the staging (below) is all that is left, and it archives none of the target.
    grep -v 'was replaced while it was being entered' "$nolink" > "$TEST_DIR/helper-naive.sh"
    bash "$TEST_DIR/helper-naive.sh" none "$link" "$APPDATA" mystack > "$TEST_DIR/naive.tar"
    ! tar -tf "$TEST_DIR/naive.tar" | grep -q 'shadow-like'
}

# ---------------------------------------------------------------------------
# Staging (audit p5a R3-01, option B): root archives only the allowlisted regular
# files of the temp dir, read as the invoking user, from its own staging dir.
# ---------------------------------------------------------------------------

@test "staging: only compose files and .env are archived, as regular files with their modes" {
    echo "A=1" > "$TEMP_SRC/.env"; chmod 0600 "$TEMP_SRC/.env"
    mkdir "$TEMP_SRC/sub" && echo nested > "$TEMP_SRC/sub/f"
    echo other > "$TEMP_SRC/notes.txt"
    bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack > "$TEST_DIR/out.tar"
    run bash -c "tar -tf '$TEST_DIR/out.tar' | grep -v '^mystack' | LC_ALL=C sort"
    [ "$output" = "$(printf './\n./.env\n./compose.yaml')" ]
    tar -tvf "$TEST_DIR/out.tar" ./.env | grep -q '^-rw-------'
    [ "$(tar -xOf "$TEST_DIR/out.tar" ./.env)" = "A=1" ]
    [ "$(tar -xOf "$TEST_DIR/out.tar" ./compose.yaml)" = "services: {}" ]
    # The staging dir is removed afterwards.
    [ -z "$(find /tmp -maxdepth 1 -name 'dsb-stage.*' -user "$(id -u)" -newer "$TEMP_SRC/.env" 2>/dev/null)" ]
}

@test "staging: an allowlisted name that is a symlink (or a directory) is refused" {
    ln -s /etc/hostname "$TEMP_SRC/.env"
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *".env in temp_dir is not a regular file"* ]]
    rm "$TEMP_SRC/.env" && mkdir "$TEMP_SRC/.env"
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 2 ]
}

@test "staging: a file over 16 MiB is refused (a link to /dev/zero cannot fill root's /tmp)" {
    truncate -s $((16 * 1024 * 1024 + 1)) "$TEMP_SRC/.env"
    run bash "$HELPER" none "$TEMP_SRC" "$APPDATA" mystack
    [ "$status" -eq 2 ]
    [[ "$output" == *"larger than"* ]]
}

@test "staging: as root, every read of the caller's files goes through setpriv as the caller" {
    # No real root here: a copy forced onto the privilege-drop path, with a setpriv shim
    # that logs its options and runs the command (as us). The real drop is checked at deploy.
    local shim="$TEST_DIR/shim"; mkdir -p "$shim"
    cat > "$shim/setpriv" <<STUB
#!/usr/bin/env bash
args=(); while [[ \$# -gt 0 && "\$1" != -- ]]; do args+=("\$1"); shift; done; shift
printf '%s\n' "\${args[*]} :: \$1" >> "$TEST_DIR/setpriv.log"
exec "\$@"
STUB
    chmod +x "$shim/setpriv"
    sed -e 's/^drop_privs=false$/drop_privs=true/' \
        -e "s|^PATH=.*|PATH=\"$shim:/usr/sbin:/usr/bin:/sbin:/bin\"|" "$HELPER" > "$TEST_DIR/helper-drop.sh"
    grep -q '^drop_privs=true$' "$TEST_DIR/helper-drop.sh"
    echo "A=1" > "$TEMP_SRC/.env"
    SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" bash "$TEST_DIR/helper-drop.sh" none "$TEMP_SRC" "$APPDATA" mystack > "$TEST_DIR/out.tar"
    run cat "$TEST_DIR/setpriv.log"
    # A stat for each of the 5 allowlisted names, a read (head) for the 2 present; all
    # with the caller's ids, none as root.
    [ "${#lines[@]}" -eq 7 ]
    [ "$(grep -c ':: stat$' "$TEST_DIR/setpriv.log")" -eq 5 ]
    [ "$(grep -c ':: head$' "$TEST_DIR/setpriv.log")" -eq 2 ]
    local l
    for l in "${lines[@]}"; do
        [[ "$l" == "--reuid=$(id -u) --regid=$(id -g) --clear-groups --no-new-privs :: "* ]]
    done
    [[ "$output" == *":: stat"* && "$output" == *":: head"* ]]
    [ "$(tar -xOf "$TEST_DIR/out.tar" ./.env)" = "A=1" ]
}
