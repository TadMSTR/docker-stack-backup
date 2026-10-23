#!/usr/bin/env bats
# Weekly tar sets (TAR_SCHEDULE=full) with the unchanged cleanup-old-backups.sh (plan p5b,
# Design §7). Tar run dirs only exist on runs that wrote tar, so with a weekly cadence
# the share holds one set a week. Cleanup runs every night (03:30, about 1.5 h after the
# 02:00 run) and deletes run dirs whose age in whole days (find -mtime) exceeds
# RETENTION_DAYS, keeping the KEEP_MIN newest.
#
# Finding: RETENTION_DAYS=29 (the plan's figure) keeps FIVE weekly sets on the full-run
# day: the set from 28 days ago is 28 whole days old, which is not more than 29. With
# RETENTION_DAYS=27 and KEEP_MIN=4, every night of the week keeps exactly 4. No code
# change is needed; the setting is documented in USAGE.md "Weekly tar".

SCRIPT="$BATS_TEST_DIRNAME/../cleanup-old-backups.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    export BACKUP_BASE="$TEST_DIR/backups"
    export LOG_FILE="$TEST_DIR/cleanup.log"
    export SEARCH_DEPTH=2
    H="$BACKUP_BASE/host1"
    mkdir -p "$H"
}

teardown() {
    rm -rf "${TEST_DIR:?}"
}

# run_dir <name> <age in hours> — a run dir with one archive, its mtime that long ago.
run_dir() {
    mkdir -p "$H/$1"
    echo data > "$H/$1/stack.tar"
    touch -d "@$(( $(date +%s) - $2 * 3600 ))" "$H/$1"
}

# fixture <days since the last weekly run> — the cleanup's view at 03:30: 6 weekly sets
# (02:00 on each full-run day) plus 7 daily sets from the trial before the cut.
fixture() {
    local since="$1" w d
    for w in 0 1 2 3 4 5; do
        run_dir "weekly-$w" $(( (since + 7 * w) * 24 + 1 ))
    done
    for d in 0 1 2 3 4 5 6; do
        run_dir "trial-$d" $(( (since + 7 * 5 + 1 + d) * 24 + 1 ))
    done
}

kept() {
    find "$H" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | paste -sd' '
}

@test "weekly: RETENTION_DAYS=27, KEEP_MIN=4 keeps exactly the 4 newest sets on every night of the week" {
    local since
    for since in 0 1 2 3 4 5 6; do
        rm -rf "${H:?}"/*
        fixture "$since"
        RETENTION_DAYS=27 KEEP_MIN=4 run bash "$SCRIPT"
        [ "$status" -eq 0 ]
        echo "  $since day(s) after the full run: kept $(kept)" >&3
        [ "$(kept)" = "weekly-0 weekly-1 weekly-2 weekly-3" ]
    done
}

@test "weekly: the plan's RETENTION_DAYS=29 keeps 5 sets on the full-run day (why 27)" {
    fixture 0
    RETENTION_DAYS=29 KEEP_MIN=4 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(kept)" = "weekly-0 weekly-1 weekly-2 weekly-3 weekly-4" ]
}

@test "weekly: when backups stop, KEEP_MIN=4 still keeps the last 4 sets" {
    fixture 40
    RETENTION_DAYS=27 KEEP_MIN=4 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(kept)" = "weekly-0 weekly-1 weekly-2 weekly-3" ]
    [[ "$output" == *"Kept 4 past retention by KEEP_MIN (4)"* ]]
}

@test "the 7-night trial (tar daily): every daily set is kept, under the trial's settings and under the weekly ones" {
    local d settings
    for settings in "30 7" "27 4"; do
        rm -rf "${H:?}"/*
        for d in 0 1 2 3 4 5 6; do run_dir "daily-$d" $(( d * 24 + 1 )); done
        # Older daily sets from before the trial, every day back 40 days.
        for d in $(seq 7 40); do run_dir "old-$d" $(( d * 24 + 1 )); done
        read -r r k <<< "$settings"
        RETENTION_DAYS=$r KEEP_MIN=$k run bash "$SCRIPT"
        [ "$status" -eq 0 ]
        for d in 0 1 2 3 4 5 6; do [ -d "$H/daily-$d" ]; done
        echo "  RETENTION_DAYS=$r KEEP_MIN=$k: $(find "$H" -mindepth 1 -maxdepth 1 -type d | wc -l) sets kept" >&3
    done
}
