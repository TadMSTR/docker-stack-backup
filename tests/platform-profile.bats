#!/usr/bin/env bats
# Platform profiles (0.7.0): PLATFORM=auto|debian|truenas sets defaults for ELEVATION_CMD
# and SNAPSHOT_BACKEND; anything set in config.sh or the environment wins.

load helpers/stub-env
load helpers/status

LIB_SNIPPET='source "$1"; shift; eval "$1"; apply_platform_defaults
             printf "%s|%s|%s|%s\n" "$RESOLVED_PLATFORM" "${ELEVATION_CMD:-}" "$SNAPSHOT_BACKEND" "$SNAPSHOT_BACKEND_SOURCE"'

# profile <shell assignments> — prints platform|elevation|snapshot_backend|source
profile() {
    bash -c "$LIB_SNIPPET" _ "$BATS_TEST_DIRNAME/../lib.sh" "unset ELEVATION_HELPER_PATH PLATFORM; $1"
}

setup() {
    stub_env_setup
    status_setup
}

teardown() {
    stub_env_teardown
}

@test "detect: Debian, Ubuntu and Proxmox use the debian profile; unknown OS is generic" {
    [ "$(profile 'OS_TYPE=debian; unset ELEVATION_CMD SNAPSHOT_BACKEND')" = "debian||auto|profile" ]
    [ "$(profile 'OS_TYPE=ubuntu; unset ELEVATION_CMD SNAPSHOT_BACKEND')" = "debian||auto|profile" ]
    [ "$(profile 'OS_TYPE=proxmox; unset ELEVATION_CMD SNAPSHOT_BACKEND')" = "debian||auto|profile" ]
    [ "$(profile 'OS_TYPE=unknown; unset ELEVATION_CMD SNAPSHOT_BACKEND')" = "generic||none|profile" ]
}

@test "detect: TrueNAS SCALE by OS_TYPE, or by its middleware client although os-release says debian" {
    [ "$(profile 'OS_TYPE=truenas; unset ELEVATION_CMD SNAPSHOT_BACKEND')" = "truenas|none|zfs|profile" ]
    printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/midclt"; chmod +x "$BIN_DIR/midclt"
    [ "$(profile 'OS_TYPE=debian; unset ELEVATION_CMD SNAPSHOT_BACKEND')" = "truenas|none|zfs|profile" ]
}

@test "debian: ELEVATION_CMD=sudo only when not root and a helper path is set" {
    [[ $EUID -ne 0 ]] || skip "runs unprivileged"
    [ "$(profile 'PLATFORM=debian; unset ELEVATION_CMD SNAPSHOT_BACKEND; ELEVATION_HELPER_PATH=/x')" = "debian|sudo|auto|profile" ]
    # No helper path: unchanged, so the run still stops at the privilege check as before.
    [ "$(profile 'PLATFORM=debian; unset ELEVATION_CMD SNAPSHOT_BACKEND ELEVATION_HELPER_PATH')" = "debian||auto|profile" ]
}

@test "explicit config always wins over the profile" {
    [ "$(profile 'PLATFORM=truenas; ELEVATION_CMD=sudo; SNAPSHOT_BACKEND=none')" = "truenas|sudo|none|config" ]
    [ "$(profile 'PLATFORM=debian; ELEVATION_CMD=none; SNAPSHOT_BACKEND=btrfs')" = "debian|none|btrfs|config" ]
}

@test "an invalid PLATFORM stops the run (invalid-config)" {
    export PLATFORM=freebsd
    run_backup
    [ "$status" -eq 1 ]
    [[ "$output" == *"PLATFORM must be auto, debian or truenas (got: 'freebsd')"* ]]
}

@test "the run logs the resolved platform and writes it to status.json" {
    export PLATFORM=debian
    run_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Platform: debian (PLATFORM=debian)"* ]]
    [ "$(js "$STATUS" 'd["platform"]')" = '"debian"' ]
}

@test "a 0.6.0 config run as root on Debian keeps ELEVATION_CMD=none (no sudo appears)" {
    unshare -r true 2>/dev/null || skip "unshare -r not available"
    unset ELEVATION_CMD ELEVATION_HELPER_PATH
    run unshare -r bash -c "$LIB_SNIPPET" _ "$BATS_TEST_DIRNAME/../lib.sh" 'PLATFORM=debian; unset SNAPSHOT_BACKEND'
    [ "$output" = "debian||auto|profile" ]
}
