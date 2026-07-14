#!/usr/bin/env bats
# Tests for dockhand_stack_base() in lib.sh (DSBAK-7).
# Requires: bats (apt install bats)
# Run:      bats tests/dockhand-stack-base.bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export LOG_FILE="$TEST_DIR/test.log"
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib.sh"
    DOCKHAND_BASE="/opt/dockhand/stacks"
    HOSTNAME="myhost"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "default (unset) appends \$HOSTNAME" {
    unset DOCKHAND_APPEND_HOSTNAME
    result="$(dockhand_stack_base)"
    [ "$result" = "/opt/dockhand/stacks/myhost" ]
}

@test "DOCKHAND_APPEND_HOSTNAME=true appends \$HOSTNAME (explicit, matches default)" {
    DOCKHAND_APPEND_HOSTNAME=true
    result="$(dockhand_stack_base)"
    [ "$result" = "/opt/dockhand/stacks/myhost" ]
}

@test "DOCKHAND_APPEND_HOSTNAME=false returns DOCKHAND_BASE directly (flat layout)" {
    DOCKHAND_APPEND_HOSTNAME=false
    result="$(dockhand_stack_base)"
    [ "$result" = "/opt/dockhand/stacks" ]
}

@test "explicit hostname arg overrides \$HOSTNAME when appending" {
    DOCKHAND_APPEND_HOSTNAME=true
    result="$(dockhand_stack_base otherhost)"
    [ "$result" = "/opt/dockhand/stacks/otherhost" ]
}

@test "explicit hostname arg is ignored (no nesting) when DOCKHAND_APPEND_HOSTNAME=false" {
    DOCKHAND_APPEND_HOSTNAME=false
    result="$(dockhand_stack_base otherhost)"
    [ "$result" = "/opt/dockhand/stacks" ]
}
