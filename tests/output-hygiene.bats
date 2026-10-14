#!/usr/bin/env bats
# Output hygiene (#1093, review finding 8):
#   - dry-run lines were printed with plain `echo`, so the terminal showed a literal
#     "\033[0;32m" instead of a colour;
#   - log_error/log_success/log_warning tee'd the coloured line into LOG_FILE, so every
#     log reader got raw escape codes;
#   - scripts tracked 0644 failed under `sudo ./script` ("command not found").

load helpers/stub-env

setup() {
    stub_env_setup
    export LOG_FILE="$TEST_DIR/backup.log"
}

teardown() {
    stub_env_teardown
}

@test "dry run prints no literal \\033 sequences" {
    run_backup --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would backup"* ]]
    [[ "$output" != *'\033'* ]]
}

@test "manual dry run prints no literal \\033 sequences" {
    run bash -c "printf '1\ny\n' | bash '$BATS_TEST_DIRNAME/../docker-stack-backup-manual.sh' --dry-run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN COMPLETE"* ]]
    [[ "$output" != *'\033'* ]]
}

@test "a real run writes plain [SUCCESS]/[ERROR] lines to LOG_FILE, no escape codes" {
    run_backup
    [ "$status" -eq 0 ]
    export STUB_PS_RC=1   # second run: the stack fails, which logs errors
    run_backup
    [ "$status" -ne 0 ]
    grep -q '^\[SUCCESS\] ' "$LOG_FILE"
    grep -q '^\[ERROR\] ' "$LOG_FILE"
    ! grep -q $'\033' "$LOG_FILE"
    # log()'s timestamp format is unchanged: cron log readers parse it.
    grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] ' "$LOG_FILE"
}

@test "with no LOG_FILE, log_* still print the coloured line" {
    run bash -c 'unset LOG_FILE; source "$1"; log_warning hello 2>/dev/null' _ "$BATS_TEST_DIRNAME/../lib.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[1;33m[WARNING]\033[0m hello'* ]]
}

@test "every tracked *.sh with a shebang is mode 100755 in the git index" {
    command -v git >/dev/null && git -C "$BATS_TEST_DIRNAME/.." rev-parse --git-dir >/dev/null 2>&1 \
        || skip "not a git checkout"
    local bad=() mode f
    while read -r mode _ _ f; do
        [[ "$(head -c 2 "$BATS_TEST_DIRNAME/../$f")" == '#!' ]] || continue
        [[ "$mode" == 100755 ]] || bad+=("$f ($mode)")
    done < <(git -C "$BATS_TEST_DIRNAME/.." ls-files -s -- '*.sh')
    if [[ ${#bad[@]} -gt 0 ]]; then
        printf 'not executable in the index: %s\n' "${bad[@]}" >&3
        return 1
    fi
}
