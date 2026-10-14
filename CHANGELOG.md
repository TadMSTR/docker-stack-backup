# Changelog

## [0.5.3] — 2026-10-14

The fixes from the v0.5.2 security audit (audit p3a, 1 Medium, 2 Low, 3 Info). Restore
also stops following symlinks in an archive.

### Security

- **Cleanup no longer runs a share directory's name as code** (re-check round 3, F-01,
  **High**; present since the first commit). `cleanup-old-backups.sh` sized each expired
  run dir with `du -sb | cut -f1`. A dir whose name holds a newline made that return
  `<bytes>` plus the rest of the name, which `$(( ))` then evaluated. An array subscript
  like `BASH_VERSINFO[$(cmd)0]` ran `cmd` as the cleanup user: from cron, nightly, with
  no operator involved. The size is now the text before the first whitespace and must be
  all digits. Dirs whose names hold control bytes are skipped and logged with `%q`.
- **The restore preview lists numeric owners** (`tar --numeric-owner -tvf`; round 4,
  R4-01, Low). PAX owner/group names can hold line breaks, and one member's owner name
  could replace the 20-line preview with forged lines.
- **Cleanup checks the whole path below the base for control bytes**, not only the last
  component (round 4, R4-02, Info).
- **Cleanup's log is printable** (round 3, F-02, Low). Cleanup has its own `log*`
  functions (it runs standalone). They now print messages as data, with control bytes
  replaced, and no longer use `echo -e`.
- **Step 4 makes owner and group names printable** (round 3, F-03, Low). `tar -tv` prints
  them raw, so escape codes in them could reach root's terminal and blank the
  setuid/special-member warning.
- **`printable` also replaces UTF-8-encoded C1 controls** such as U+009B CSI, which
  `[[:cntrl:]]` misses under the C locale (round 3, F-04, Info). Lone 0x80-0x9f bytes
  are left alone: UTF-8 terminals ignore them, and stripping them would corrupt valid
  characters.
- **Step 3 only offers the suffixes the backup writes** (`.tar`, `.tar.gz`, `.tar.bz2`,
  `.tar.xz`, `.tar.zst`) (round 3, F-05, Info).
- **The dry run no longer evaluates a planted file as code** (audit F-01, Medium; predates
  0.5.x). `docker-stack-backup.sh --dry-run` passed each stack's size through
  `/tmp/stack_size_$$` and added what it read back inside `$(( ))`. Bash arithmetic runs
  command substitutions in array subscripts. With `fs.protected_regular` (Debian's
  default), another user's file planted at that name survives root's write. So
  `BASH_VERSINFO[$(cmd)]` ran as whoever ran the dry run, root included under sudo. The
  size now goes through a variable, and it must be digits before any arithmetic.
- **Archive and host names can no longer forge log lines** (F-02, Low). `log_*` and the
  wizard's list lines used `echo -e`, so a literal `\n` or `\033` in a name on the share
  became a new line or an escape sequence in `/var/log/docker-restore.log` and on root's
  terminal. Escapes are now interpreted only in the colour codes, and messages are
  printed as data.
- **Raw control bytes in share names are neutralised too** (re-check round 2, R2-01, Low).
  `printf %s` stops escape interpretation but passes a real LF or ESC through as is. A new
  `printable` lib helper replaces control bytes with `?` in every `log`/`log_*` message and
  in the restore and verify list lines. Refused names are shown only via `printf %q`, so
  the refusal itself can no longer write a forged line. Step 3's size column uses
  `du_size`; `du -h f | cut -f1` reprinted the rest of a name holding a newline. The run
  dir chosen at Step 2 must match `YYYYMMDD_HHMMSS`.
- **The name checks are ASCII-only in every locale** (R2-02, Info). They are pinned to
  `LC_ALL=C`; under `en_US.UTF-8` the ranges also matched `é`, `ß` and fullwidth letters.
- **Step 4 flags members worth a second look** (F-03, Low): setuid/setgid files and
  device, pipe or socket entries are counted and listed (up to 10) before "Proceed with
  restore?". USAGE.md now says the backup share is a root trust boundary.
- **Host and stack names from the share must be plain** (F-04, Info):
  `[A-Za-z0-9._-]+`, not `.`, `..` or a leading `-`, the same rule the tar-create helper
  applies. The globs already skipped dotfiles, but `shopt -s dotglob` in config.sh would
  have lifted that.
- **The space check refuses archives declaring 19+ digits of size** (F-05, Info). Such a
  size wrapped bash's 64-bit arithmetic and passed the check.
- **Symlinked appdata is flagged at Step 5, and the default safety copy is called
  temporary** (F-06, Info). Under the default `TMPDIR`, the wizard says the copy will be
  cleaned up and points to `RESTORE_SAFETY_DIR`.

- **Restore no longer follows symlinks in an archive's config files or appdata dir.** It
  runs as root. v0.5.1 checked `docker-compose.yml` with `[[ -f ]]` and copied it with a
  plain `cp`, which follows links; v0.5.2 did the same for all four compose names and
  `.env`. A member `compose.yaml -> /etc/shadow` was copied into the stack dir as root.
  Symlinked members are now refused with a warning. Config files are copied with
  `--remove-destination`, so a symlink already at the destination is replaced instead of
  written through. A `<stack>` member that is a symlink no longer replaces the live
  appdata. Found by the pre-audit security baseline (FW-21 class). Test:
  `restore-step6.bats` "symlinks in the archive are not followed…" fails on v0.5.2.

### Tests

- One test per audit finding (F-01 to F-06, R2-01, R2-02). Round-1 tests fail on `9ea9118`;
  the four round-2 tests (real LF/ESC in a stack name, a host dir and a timestamp dir; a
  non-ASCII name under `en_US.UTF-8`) fail on `a62f2b4`. The five round-3 tests fail on
  `5d88cdc`; on the cleanup test the injected command runs. The two round-4 tests fail on
  `2202f48`. All pass here.
- Known and accepted (round 4, R4-03): bytes that are not valid UTF-8 (lone 0x80-0x9f,
  0xff) reach the cleanup log raw. Stripping them would corrupt valid UTF-8, so log
  readers should treat the log as bytes. The
  F-01 test `exec`s the dry run so its PID is known, plants a read-only
  `/tmp/stack_size_<pid>`, and asserts that the injected command never runs.

## [0.5.2] — 2026-10-14

The tools around the backup now work on a real share: restore, verify and the manual
script. The restore wizard's last two steps are tested for the first time.

### Fixed

- **A successful restore no longer exits 1** (#1098). `perform_restore` set
  `trap 'rm -rf "$temp_restore"' RETURN` and never disarmed it. After the restore had
  finished and logged "Restore completed successfully", the trap fired again when `main`
  returned. `$temp_restore` was out of scope by then, so `set -u` aborted with
  `temp_restore: unbound variable` and exit 1. The trap now disarms itself, as
  `backup_stack`'s has done since PR #11.
- **`backup-verify.sh --stats` works on large shares** (#1099). It took oldest/newest
  with `find … | sort | head -1` under `pipefail`. Once the listing outgrew the 64 KiB
  pipe buffer, `sort` died of SIGPIPE and the script exited 141. That happens on every
  forge run: about 930 archives, 96 KB of listing. One `find | awk` pass now gives the
  count, oldest and newest.
- **Restore and verify read `BACKUP_DEST`** (#1091). They read only `BACKUP_BASE`,
  defaulting to `/mnt/backup/docker-backups`, so with a config that set `BACKUP_DEST` (as
  `config.example.sh` does) they looked somewhere the backup never wrote. `BACKUP_BASE`
  still overrides. `cleanup-old-backups.sh` falls back to `BACKUP_DEST` from the
  environment after `$1` and `BACKUP_BASE`.
- **Restore puts back the compose file the stack actually uses.** The backup archives
  whichever of `compose.yaml`, `compose.yml`, `docker-compose.yaml` or
  `docker-compose.yml` it finds. Restore copied back only `docker-compose.yml`, so a stack
  using any other name came back with its old compose file, or with none if the stack dir
  was gone. When the archive has a compose file, any other compose name in the stack dir
  is removed first, so a leftover `compose.yaml` cannot shadow a restored
  `docker-compose.yml`. The safety copy keeps the old file.
- **The manual script handles appdata it can't fully read** (#1092). `du -sb | cut` under
  `pipefail` exited 1 at the summary step for any root-owned appdata. This broke the
  unprivileged elevated path it exists for. The size is now an estimate, labelled
  "(estimate — unreadable paths excluded)". A new lib helper, `du_size`, never aborts
  its caller. Restore, verify and the main script's dry run use it too.
- **The manual script shows "state unknown", never "stopped", when it can't tell**
  (#1090 R2-01). Its stack list, summary and dry run now use `get_running_services()`.
  A stack whose compose file fails to parse used to show as "stopped", even though the
  backup fails such a stack. Its dry run now counts these stacks as "Would fail", leaving
  them out of "Would backup" and the size estimate.
- **No literal `\033[…m` in dry runs** (#1093). Dry-run lines used `echo` without `-e`.
- **No colour codes in `LOG_FILE`.** `log_error`, `log_success` and `log_warning` tee'd the
  coloured line into the log. The terminal still gets colour; the log gets
  `[ERROR] …`, `[SUCCESS] …` and `[WARNING] …`. `log()`'s timestamp format is unchanged.
- **Restore Step 4 reads the archive once** (#1095). A single `tar -tvf | awk` pass prints
  the first 20 entries and also counts entries and sums member sizes. A `tar` failure
  still warns that the archive may be corrupt.
- Every script with a shebang is tracked 100755: `docker-stack-backup.sh`,
  `docker-stack-backup-manual.sh`, `cleanup-old-backups.sh`, `lib.sh`,
  `config.example.sh` (#1093).

### Changed — restore Step 6

- **Space check before anything is written.** The extract (under `TMPDIR`) and, with
  option 2, the safety copy (under `RESTORE_SAFETY_DIR`) must both fit. The two sizes
  are summed when they share a filesystem. A `RESTORE_SAFETY_DIR` that doesn't exist yet
  is measured on its nearest existing parent. The extract size is the member-size sum
  from Step 4. If they don't fit, the wizard stops and names both variables.
- **The archive is extracted before the stack is stopped.** A corrupt archive now costs
  no downtime and changes nothing. The safety copy is taken after `compose down`, so it is
  a consistent copy of stopped data. `down`/`up` semantics are unchanged.
- **The safety copy goes in a fresh 0700 `mktemp -d` dir** under
  `${RESTORE_SAFETY_DIR:-${TMPDIR:-/tmp}}`, named `docker-restore-backup-<stack>-<ts>.XXXXXX`.
  It replaces a predictable path in `/tmp`. The path is printed when the restore ends.
- An archive with no `<stack>/` appdata dir no longer deletes the live appdata.
- If `compose up -d` fails, the wizard prints the manual start command and exits
  non-zero. If a step fails after `down`, it says where things stand and where the
  safety copy is.

### Tests

- `tests/restore-step6.bats` drives Steps 5-6 to completion against a stub `docker`.
  It checks: rc 0, appdata and compose/.env replaced, the safety copy holds the old data
  (0700), `down` ran before the replace and `up -d` after it, the temp extract is gone, and
  the log holds plain lines. Further cases: `up -d` fails; not enough space; a corrupt
  archive (nothing stopped); an archive without appdata. The steps run inside a function,
  as `main` does, so #1098 fails the CI-run test too. One test runs `main` end to end under
  `unshare -r`; GitHub runners skip it.
- `tests/backup-verify.bats`: `--stats` over 2000 archives (about 240 KB of listing), and
  `BACKUP_DEST`-only configs for verify and restore.
- `tests/output-hygiene.bats`: no `\033` in either dry run, a plain `LOG_FILE`, and every
  shebang script 100755 in the index.
- `tests/manual-backup.bats`: an unreadable appdata subdir; "state unknown".
- `tests/restore-wizard.bats`: Step 4 calls `tar -t` once.

## [0.5.1] — 2026-10-13

The restore wizard reaches its confirmation prompt. It never had before, on any host.

### Fixed

- **Step 2 no longer aborts with `timestamps: unbound variable`** (#1094). `select_timestamp`
  filled its array inside `for … done | sort -r`. The pipe ran the loop in a subshell, so
  the array was never set in the wizard itself, and `set -u` stopped it. The bug dates from
  the first commit. It is now `mapfile` from a process substitution, still newest-first.
- **Step 4 no longer dies previewing a real archive.** `tar -tf | head -20` under
  `pipefail`: once `head` had its 20 lines, `tar` died of SIGPIPE (or exited 2 on EPIPE
  where SIGPIPE is ignored) and `set -e` ended the wizard. This happened on any archive
  whose listing outgrew the pipe buffer, which means every real one. It went unnoticed
  only because Step 2 always failed first. The preview now uses `sed -n '1,20p'`, which
  reads to the end. A `tar` error is then a real one, and it logs a warning that the
  archive may be corrupt or truncated before you are asked to proceed.
- **An empty backup dir now gets its own error.** With no host dirs (Step 1) or no
  archives (Step 3), the wizard printed `unbound variable` instead of "No backup hosts
  found" / "No stack backups found". The arrays are now initialised empty.
- `docker-stack-restore.sh` and `backup-verify.sh` are tracked as executable (100755), so
  `sudo ./docker-stack-restore.sh` works without `bash` in front (#1093, part 1).

### Tests

- `tests/restore-wizard.bats` drives Steps 1-4 through piped input to the "Proceed with
  restore?" prompt and answers `n`. It covers newest-first ordering, `.tar.gz` and `.tar`
  stacks, and `.incomplete` files being skipped. The fixture archive's listing is larger
  than the pipe buffer. The script now runs `main` only when executed, so the tests can
  source it and call the steps without root. One more test runs `main` end to end as
  root in a user namespace (`unshare -r`); it skips where user namespaces are unavailable.

## [0.5.0] — 2026-10-13

A backup run now changes nothing except producing archives.

### Behaviour change — read before upgrading

- **Backups no longer deploy.** The backup used to stop a stack with
  `docker compose down` and bring it back with `docker compose up -d <services>`.
  `down` removes the containers, so `up` recreated them from whatever compose file and
  image were on disk at 02:00. Every pending compose edit or pulled image was deployed
  unattended, an image could be pulled (rate limits), and each container's writable layer
  was thrown away. It now uses `docker compose stop` and `docker compose start
  <previously running services>`: the same containers come back, unchanged. **Compose and
  image changes are no longer applied by the backup; deploy them deliberately with
  `docker compose up -d`.** If `start` fails, for example because a container was removed
  while the stack was stopped, the attempt falls back to
  `docker compose up -d --no-recreate --pull never --no-build --no-deps`. That creates
  only the missing containers of the services that were running, from images already
  present locally: no pull, no build, no dependency start. It is logged as a warning
  naming the deploy path. The
  interactive `docker-stack-backup-manual.sh` changes the same way.
  `docker-stack-restore.sh` keeps `down`/`up`, because a restore is meant to recreate.
- **Stopped stacks are archived.** A stack with appdata but no running containers was
  reported as "Successfully backed up" without archiving anything. With the new
  `BACKUP_STOPPED_STACKS=true` (the default) it is archived as it is, with nothing
  stopped or started, and listed as `(stopped)`. With `false` it is skipped with reason
  `not-running` and never counted as backed up.

### Fixed

- **Run counts match what was archived.** An empty appdata dir was also counted as
  backed up. It is now skipped with reason `appdata-empty`. Each skipped stack carries a
  reason (`no-appdata-reference`, `appdata-missing`, `appdata-empty`, `not-running`),
  and the run summary and notification list skipped, stopped and failed stacks by name.
  The existing count lines keep their wording (`Skipped (no appdata): N` in the log) so
  log readers still match; the names follow them.
- **No partial archives under the final name.** A failed `tar` left a truncated
  `<stack>.tar[.ext]` that `backup-verify.sh` and `docker-stack-restore.sh` treated as a
  backup. Archives are now written as `<stack>.incomplete` and renamed only on success;
  the partial file is deleted on failure. This applies to the elevated helper path too, and
  the helper's arguments are unchanged. A run dir left with no archives is removed.
- **Cleanup can no longer delete every backup.** `cleanup-old-backups.sh` deleted every
  run dir older than `RETENTION_DAYS`, so 30 days without a good backup meant the next
  cleanup removed them all. New `KEEP_MIN` (env, default 7): the newest `KEEP_MIN` run dirs
  per host that hold a completed archive are always kept. Empty or failed-run dirs don't
  use a slot. `KEEP_MIN=0` restores the old behaviour. The CLI is unchanged (`$1` = base path).
- **Free-space preflight sized to the real run.** It required a fixed 5 GB. It now requires
  the larger of `MIN_FREE_GB` (new, default 5) and 1.2 × this host's most recent previous run.
- **A stack whose running state can't be determined is failed, never archived as
  "stopped".** If `docker compose ps` fails (a compose syntax error, or a `${VAR:?}` that
  is unset in cron's environment), the stack is counted as failed with reason
  `compose-ps-failed`. Before an "archive as-is" of a stopped stack, a label-based
  `docker ps` cross-check must also agree that nothing is running
  (`running-state-mismatch` otherwise). Without this, the new stopped-stack path would
  have archived a live database and reported it as a clean backup. Found in the v0.5.0
  security audit (F-01). `--dry-run` lists these under "Would fail".
- **Numeric settings are validated and read as decimal.** `MIN_FREE_GB`,
  `MAX_RESTART_ATTEMPTS`, `RESTART_RETRY_DELAY` and `PARALLEL_THREADS` (backup scripts),
  and `KEEP_MIN`, `RETENTION_DAYS` and `SEARCH_DEPTH` (cleanup), must be plain integers in
  a bounded range, or the run exits before doing anything. Leading zeros are read as
  decimal. Before this, `MIN_FREE_GB=5G` made the free-space check pass, and
  `KEEP_MIN=08` passed the format check, then failed as invalid octal and disabled the
  retention floor. Found in the v0.5.0 security audit (F-03) and CodeRabbit (CR-01, CR-02).
- **Restart verification counts only the expected services.** A dependency that compose
  started on its own no longer skews the "N of M started" check.
- **A failed `docker compose stop` restarts what was running** instead of leaving a
  half-stopped stack.
- **`--dry-run` crashed when no stack was skipped** (`skip_list: unbound variable` under
  `set -u`). The skip list now shows each stack's reason.
- **`docker-stack-backup-manual.sh` aborted on the first stack under `set -e`.** Its
  `((n++))` counters return 1 when `n` is 0. It also counted skipped stacks as successes and
  kept a non-disarming `RETURN` trap; both are fixed to match the automated script.

### Added

- `DSB_VERSION` in `lib.sh` (`0.5.0`), logged in every run header and included in
  notifications.
- `MAX_RESTART_ATTEMPTS` and `RESTART_RETRY_DELAY` can now be set from the environment as
  well as from `config.sh`.
- `config.example.sh` documents `BACKUP_STOPPED_STACKS`, `MIN_FREE_GB`,
  `MAX_RESTART_ATTEMPTS`, `RESTART_RETRY_DELAY` and `KEEP_MIN`, and notes that the cleanup
  script reads its settings from the environment.

### Tests

- `tests/restart-uses-start.bats`: `stop`/`start`, never `down`, and never `up` without
  `--no-recreate`. Also covers the fallback, the manual-restart hint, env overrides and the
  version line.
- `tests/stopped-stack-counted.bats`: `BACKUP_STOPPED_STACKS` true/false and the
  `appdata-missing`/`appdata-empty` reasons, in both real runs and `--dry-run`.
- `tests/atomic-archive.bats`: a failed archive leaves no `*.tar`, `*.tar.*` or
  `.incomplete` file, and the temporary name never matches the verify/restore globs.
- `tests/cleanup-keep-min.bats`: 40 expired run dirs keep the newest 7. Empty or failed
  dirs take no slot. Also covers per-host grouping, depth 1, `KEEP_MIN=0` and validation.
- `tests/free-space-estimate.bats`: the `MIN_FREE_GB` floor against the 1.2× estimate.
- `tests/manual-backup.bats`: the manual script completes (the `set -e` regression) and uses
  `stop`/`start`.
- `tests/running-state-unknown.bats`: a `compose ps` failure or a compose/docker
  disagreement fails the stack and archives nothing, in real runs, `--dry-run` and the
  manual script.
- `tests/numeric-config-validation.bats`: invalid, overflowing and out-of-range values
  are rejected; leading zeros are read as decimal (`KEEP_MIN=08` keeps 8, `010` keeps 10).

### Known issue (deferred)

- Archives take the process umask, so they are world-readable (0664) on the backup
  destination although they hold full appdata. This predates 0.5.0. A `umask 077` fix
  waits on a restore/verify read path that still works when an NFS destination squashes
  root (a root restore reaches the share as `nobody`).
- `tests/helpers/stub-env.bash`: a stub `docker`/`systemctl`/`sudo` and helper, so a full
  run is tested without a daemon.

## [0.4.4] — 2026-07-26

### Fixed

- **Elevated backups aborted before `sudo` ever ran — total backup coverage loss under
  `ELEVATION_CMD` (DSBAK-10 / #23).** `create_compressed_archive_elevated()` in `lib.sh`
  gated the elevated path on `[[ ! -x "$ELEVATION_HELPER_PATH" ]]`. That tests the execute
  bit **from the unprivileged caller's perspective**, but the helper is installed
  `root:root 0750` exactly as `SECURITY.md`/`ELEVATION.md` require — so the caller has no
  execute bit on it *by design*, which is the entire reason `ELEVATION_CMD` (sudo/doas)
  exists. The check therefore failed for every stack and returned 1 before elevation was
  ever attempted, aborting the backup of every stack. This is a logic contradiction with
  the elevation threat model: it demanded the caller hold a permission the design
  deliberately withholds. Replaced with an existence-and-regular-file test
  (`[[ ! -f ... ]]`); whether *root* can execute the helper is what matters, and
  `ELEVATION_CMD` surfaces any genuine exec failure with a clear error. Same
  wrong-perspective class as DSBAK-6 (`EUID`).
- **Interactive selection prompts corrupted every choice (DSBAK-11 / #22).**
  `prompt_input()` in `docker-stack-backup-manual.sh` (and the identical function in
  `docker-stack-restore.sh`) wrote its prompt to **stdout**, but is called as
  `selection=$(prompt_input ...)` — so `$(...)` captured the prompt text (plus ANSI
  codes) concatenated with the user's input, and the caller's word-split never matched a
  valid index ("No valid stacks selected" regardless of input). Prompts now go to stderr;
  only the `read` result reaches stdout.
- **`docker-stack-restore.sh` preview could abort under `set -e`/`pipefail` (DSBAK-9 /
  #24).** Two unguarded pipelines — `find ... | wc -l` (`select_timestamp()`) and
  `tar -tf ... | wc -l` (`preview_backup()`) — would kill the whole script if `find`/`tar`
  errored (e.g. an unreadable timestamp dir or a truncated archive). Guarded with
  `|| var=0`, matching the DSBAK-8 idiom.

### Tests

- `tests/create-compressed-archive-elevated.bats` — regression for DSBAK-10: with
  `ELEVATION_CMD=sudo` and a helper the caller cannot execute (mode `0600`, standing in
  for `root:root 0750`), asserts the elevated path reaches the elevation call (via a
  `sudo` PATH stub) instead of aborting at the precondition; plus fail-closed coverage for
  a missing helper, an unset `ELEVATION_HELPER_PATH`, and a non-standard tar layout.

## [0.4.3] — 2026-07-14

### Fixed

- **`set -e` silently aborted the entire backup on the first non-stack directory in
  `DOCKHAND_BASE`.** Five call sites in `docker-stack-backup.sh`
  (`simulate_backup_stack()`, `backup_stack()`, and three sites in `main()`'s dry-run
  and real-run loops) did `local compose_file; compose_file=$(find_compose_file
  "$stack_path")` with no guard. `find_compose_file()` legitimately returns 1 for any
  directory with no compose file — normal, expected behavior for filtering out
  non-stack entries (e.g. an `_archive/` folder alongside real stacks) — but under
  `set -euo pipefail`, that nonzero exit killed the *entire script* on the bare
  assignment, before the very next line's `[[ -z "$compose_file" ]]` check ever ran.
  Every real cron run would silently process only the alphabetically-first stack(s)
  and stop — worse, because the abort happens mid-loop, `main()`'s final
  `send_notifications()` call is never reached either, so **no success or failure
  alert fires at all**. `docker-stack-backup-manual.sh` already guarded all six of its
  equivalent sites correctly (`|| true`); this fix was simply never ported to the
  automated script. Found by sysadmin via `bash -x` trace against forge's real
  `~/docker/` layout (37 entries; script silently stopped after 1).
- **Same class, found while auditing per this fix's own recommendation:** three
  `docker compose ps ... | wc -l` pipelines (`lib.sh`'s `restart_stack_with_retry()`,
  and two sites in `docker-stack-backup-manual.sh`) were unguarded — under `pipefail`,
  a `docker compose ps` failure (not just `wc -l`) aborts the pipeline, which the same
  `set -e` hazard would kill the script on. Now guarded with `|| <var>=0`, matching the
  idiom already used at the one site in `docker-stack-backup.sh` that had it right.
- **`LOCK_FILE` also defaulted to a root-only path** (`/var/run/...`), unconditionally
  — even overriding a `config.sh` value, since the assignment had no `${LOCK_FILE:-}`
  guard at all. This made `acquire_lock()` fail for any `ELEVATION_CMD`-configured
  unprivileged run (found while writing this fix's own regression test). Default now
  tests actual `/var/run` writability and falls back to `${HOME}/run/...`, matching the
  `LOG_FILE` convention from DSBAK-6 — and a `config.sh` override now actually takes
  effect, which it previously didn't.

### Tests

- `tests/set-e-non-stack-entries.bats` — end-to-end fixture (real Docker/Compose, no
  image pull needed) with a non-stack directory alongside a real stack, covering both
  `--dry-run` and real-run modes. Confirmed to fail without this fix (reproduces the
  exact regression) and pass with it.

## [0.4.2] — 2026-07-14

### Added

- **`DOCKHAND_APPEND_HOSTNAME`** — stack discovery (`docker-stack-backup.sh`,
  `docker-stack-backup-manual.sh`) and restore's target-directory computation
  (`docker-stack-restore.sh`) always appended the machine hostname as a subdirectory
  under `DOCKHAND_BASE` (`$DOCKHAND_BASE/$HOSTNAME`), matching a shared/centralized
  stacks root serving a fleet. This breaks any flat single-host layout where stacks
  live directly under one directory with no per-host nesting. New
  `DOCKHAND_APPEND_HOSTNAME` (default `true`, unchanged behavior); set `false` for a
  flat layout (e.g. `DOCKHAND_BASE="/home/user/docker"` with compose files at
  `/home/user/docker/<stack>/`). New shared `dockhand_stack_base()` in `lib.sh`
  centralizes the four call sites across all three scripts. Found by sysadmin during
  the forge cutover (DSBAK-7) — forge's own layout is exactly this flat case, and
  `DOCKHAND_BASE` doesn't actually require running Dockhand at all, just a directory
  with one subdirectory per stack; the variable name is a holdover from the project's
  original use case.

## [0.4.1] — 2026-07-14

### Fixed

- **`ELEVATION_CMD` was unusable as documented.** `docker-stack-backup.sh` and
  `docker-stack-backup-manual.sh` unconditionally required `EUID==0` in `main()` —
  even when `ELEVATION_CMD` was configured, and even in `--dry-run` mode — which
  contradicted `ELEVATION.md`'s design ("keep the bulk of the backup running
  unprivileged and elevate only the tar read"). As shipped in 0.4.0, the script
  refused to start at all unless already root, regardless of `ELEVATION_CMD`. New
  shared `require_privileged_or_elevated()` in `lib.sh` only requires root when
  `ELEVATION_CMD` is `none` (the default — unchanged behavior). Found by sysadmin
  during the forge cutover to v0.4.0 (DSBAK-6).
- **Appdata-emptiness check silently skipped exactly the layout `ELEVATION_CMD` exists
  to handle.** `docker-stack-backup.sh`'s `ls -A "$appdata_dir" 2>/dev/null` can't tell
  "genuinely empty" from "unreadable by the unprivileged caller" — for any appdata
  directory that actually needs elevation (i.e. isn't already readable unprivileged),
  this check silently skipped the stack, logging a benign-looking "is empty... skipping"
  before `create_compressed_archive()` was ever reached. A nightly cron run could report
  full success while backing up nothing. New `appdata_has_content()` in `lib.sh` skips
  this test entirely under `ELEVATION_CMD` and lets the elevated archive-creation call
  (which runs through the validated helper, as root) be authoritative instead. `--dry-run`
  size estimates for such stacks still under-report (dry-run never elevates), a known,
  lower-severity limitation. Found in pre-merge security audit of the `EUID` fix above.
- **`LOG_FILE` default also required root**, independent of the `EUID` check above —
  `docker-stack-backup.sh`/`docker-stack-backup-manual.sh` defaulted to
  `/var/log/docker-backup*.log`, which an unprivileged `ELEVATION_CMD` user can't write.
  Under `set -euo pipefail`, `log()`'s `tee -a` failure there aborted the script before
  ever reaching the `EUID` check, silently reintroducing the same "elevation doesn't
  actually work unprivileged" problem this release otherwise fixes. **Revised in the
  same release**, per audit: the initial fix branched the default on `ELEVATION_CMD`,
  which left the plain "forgot `sudo`" case (`ELEVATION_CMD=none`, unprivileged) still
  hitting the same raw `tee` failure instead of `require_privileged_or_elevated()`'s
  clear error message. Default now tests actual writability of `/var/log` directly, and
  falls back to `${HOME}/logs/docker-backup*.log` regardless of `ELEVATION_CMD` when it
  isn't writable — same convention `cleanup-old-backups.sh` already used for its own
  non-root default. An explicit `LOG_FILE` override always wins.

### Changed

- **`docker-stack-restore.sh` deliberately keeps its unconditional root requirement.**
  Restore writes directly into appdata (`tar -x`/`cp -a`/`rm -rf`) and has no
  elevation-aware helper for that direction — only archive *creation* (the read side)
  has one. Relaxing restore's check without a matching privileged-write helper would
  let it start (stopping the stack, taking a safety backup) and then fail mid-restore
  with permission-denied — worse than rejecting upfront. See `ELEVATION.md`.

## [0.4.0] — 2026-07-14

### Security

- **Elevation helper `stack_name` validation** — reject the bare `.` and `..` tokens in
  `docker-backup-tar-create.sh`. The character-class regex admitted `..`, which (since
  `-d "<root>/.."` is always true) let a caller holding the sudoers/doas grant invoke the
  helper directly with `stack_name=..` and archive the parent of `ALLOWED_APPDATA_PATH` —
  a one-level read above the allowlist the helper exists to enforce. `.` similarly widened
  the archive to the whole appdata root. Added explicit rejection and regression tests for
  the bare `..`/`.` tokens (the prior test only covered slash-containing values). Found in
  pre-merge security audit (H-1/L-1).

### Added

- **Elevation helper (`ELEVATION_CMD`, `ELEVATION_HELPER_PATH`)** — optionally route
  archive creation through a root-owned, argument-validating helper
  (`docker-backup-tar-create.sh`, now shipped in the repo) instead of running `tar`
  directly. Lets the backup run unprivileged while elevating only the read of
  root-owned appdata. The helper never accepts raw `tar` flags — it validates a fixed
  positional argument list and builds the `tar` invocation itself, closing the
  `sudo tar` → `--checkpoint-action=exec` GTFOBins local-root hole. The allowed appdata
  root is pinned by `ALLOWED_APPDATA_PATH` inside the root-owned helper, not by caller
  input. `create_compressed_archive()` fails closed if the helper is missing, the
  command is not `sudo`/`doas`, or the archive layout is unexpected. See `ELEVATION.md`
  and `SECURITY.md`. Defaults to `none` (unchanged behavior).
- **Per-channel notification severity (`NTFY_URGENT_ONLY`)** — when `true`, ntfy fires on
  failure only, even if `NOTIFY_ON_SUCCESS=true`; other channels still follow the global
  toggles. Supports "one loud channel (e.g. Matrix), one urgent-only channel". Default
  `false`. See `NOTIFICATIONS.md`.
- **Post-restart hooks (`POST_RESTART_HOOKS`)** — an array of function/command names run
  after each stack's containers restart successfully, invoked as
  `<hook> <stack_name> <stack_path>`. A failing hook logs a warning and does not abort
  the backup. See `HOOKS.md`.
- **`docker-backup-tar-create.sh`** — the shipped elevation helper (install root-owned
  `0750`; see `ELEVATION.md`).
- **`tests/post-restart-hooks.bats`, `tests/tar-create-helper.bats`** — cover hook
  invocation/failure semantics and the helper's argument validation (crafted
  `--checkpoint` excludes, path traversal, appdata allowlist, temp-dir shape). CI now
  runs the whole `tests/` directory.

### Fixed

- **NFS `root_squash` archive writes** — `create_compressed_archive()` now writes every
  archive via a stdout redirect from the caller's shell (`tar -c … > "$file"`) instead
  of `tar -cf "$file"`. Under NFS `root_squash`, a root `tar` opening the output file is
  squashed to `nobody` and denied; letting the caller's (unprivileged) shell open the
  file avoids this. No behavioral change on local disks. Affected all three tar sites
  (parallel "none", `--zstd`, and the default sequential path).

---

## [0.3.1] — 2026-06-19

### Security

- **`send_matrix()`**: Fixed invalid JSON payload generation. The `sed`-only body escaping
  left raw newlines in the `formatted_body` field, causing Matrix homeservers to reject all
  notifications. Now uses `python3 json.dumps` for both fields; `sed`/`tr` fallback strips
  newlines with `tr '\n' ' '` on hosts without Python. (Audit finding L-2)
- **`acquire_lock()`**: Added numeric guard before `eval "exec ${LOCK_FD}>..."`. LOCK_FD is
  now validated against `^[0-9]+$` before use; non-numeric values default to 200, preventing
  shell metacharacter injection when running as root. (Audit finding I-1)
- **Notification secrets off `ps` argv**: Bearer tokens (Ntfy, Matrix) and SMTP credentials
  are now passed via `curl -K <(printf ...)` process substitution instead of `-H` / `--user`
  CLI flags. Pushover POST body built via `python3 urllib.parse.urlencode` piped to
  `--data-binary @-`; fallback retains `--form-string` with `SECURITY[control]` annotation.
  (Audit finding L-1)
- **Root ownership warning**: All four entry-point scripts now emit a stderr warning when
  `EUID==0` but `$SCRIPT_DIR` is not root-owned, with guidance to deploy to
  `/opt/docker-stack-backup`. README updated with Production/Cron Deployment section.
  (Audit finding M-1)
- **`.gitignore`**: Added `.env`, `*.env`, `core.*`, `*.core` to prevent accidental credential
  commits. (Audit pre-audit baseline SC-02)
- Accepted risks documented inline (`SECURITY[accepted]`): `--insecure` curl flag for Proton
  Bridge (opt-in, default false); unquoted `$running_containers` for intentional word-splitting
  to pass per-service restart args. Full audit record: docker-stack-backup-2026-06.

---

## [0.3.0] — 2026-06-19

### Added

- **Matrix notification support** — `MATRIX_ENABLED`, `MATRIX_HOMESERVER`, `MATRIX_ACCESS_TOKEN`,
  `MATRIX_ROOM_ID` env vars; sends formatted backup summaries to a Matrix room via the
  client/v3 REST API. `python3` used for URL encoding with a sed-based fallback.
- **`lib.sh`** — shared library sourced by all scripts; contains color vars, logging helpers,
  locking (`acquire_lock` / `release_lock`), compression helpers, notification functions
  (`send_ntfy`, `send_pushover`, `send_email`, `send_matrix`, `send_notifications`),
  restart logic, and `find_compose_file`.
- **`config.example.sh`** — documents all user-configurable variables with defaults; copy to
  `config.sh` to configure without editing scripts directly. `config.sh` is git-ignored.
- **`.gitignore`** — excludes `config.sh` to prevent credentials from being committed.
- **`find_compose_file()`** in `lib.sh` — returns the first compose file found in a stack
  directory, checking `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`.

### Changed

- All four scripts (`docker-stack-backup.sh`, `docker-stack-restore.sh`,
  `docker-stack-backup-manual.sh`, `backup-verify.sh`) now source `lib.sh` and optionally
  source `config.sh`; duplicate code removed.
- `docker-stack-backup-manual.sh`: all hardcoded `$stack_path/docker-compose.yml` references
  replaced with `find_compose_file()` — stacks using `compose.yml` or `compose.yaml` now work.
- SC2155 (`local var=$(cmd)`) fixed across all scripts — declarations and assignments split
  to preserve exit code capture.
- `.shellcheckrc`: removed global `disable=SC2155` suppression (now fixed at source).

---

## [0.2.1] — 2026-06-19

### Fixed

- `backup-verify.sh`: `((n++))` counter arithmetic caused the script to exit prematurely
  under `set -euo pipefail` when the counter value was 0. Replaced with `n=$((n+1))`.
- `backup-verify.sh`, `docker-stack-restore.sh`: hardcoded `.tar.gz` extension in glob
  patterns and `tar -tzf`/`-xzf` flags broke verification and restore of archives created
  with bzip2, xz, or zstd compression. Now uses `find \( -name "*.tar.*" -o -name "*.tar" \)`,
  `*.tar.* *.tar` loop globs, and `tar -tf`/`-xf` (GNU tar auto-detects format).
- `backup-verify.sh`: `basename "$file" .tar.gz` failed to strip extensions other than `.tar.gz`.
  Fixed with chained `${name%.tar.*}` / `${name%.tar}` parameter expansion.
- `docker-stack-restore.sh`: `select_stack()` used a single `stacks` array indexed by loop
  variable `i`, losing the path-to-file mapping. Refactored to use parallel `stacks`/`stack_files`
  arrays for correct file selection.
- `docker-stack-backup.sh`: removed stray debug `echo` statement that emitted
  `DEBUG: simulate_backup_stack returned success` to stderr on every successful dry-run.

---

## [0.2.0] — 2026-06-19

### Fixed

- `cleanup-old-backups.sh`: `((n++))` arithmetic under `set -euo pipefail` caused the script
  to exit after removing only the first backup directory. Replaced with `n=$((n + 1))`.
- `docker-stack-backup.sh`, `docker-stack-backup-manual.sh`, `docker-stack-restore.sh`:
  SC2064 — `trap "rm -rf '$var'" RETURN` expanded `$var` at trap-set time rather than when
  the trap fires. Fixed to use single-quoted form.

### Changed

- `cleanup-old-backups.sh`: `detect_os()` simplified — drops unused `OS_NAME`, `OS_VERSION`,
  and `proxmox` case; TrueNAS/SCALE detection retained.
- `cleanup-old-backups.sh`: `LOG_FILE` default changed from `/var/log/` (requires root) to
  `${HOME}/logs/` — writable by the cron user without root; log directory created automatically.
- `docker-stack-backup.sh`: removed unused `BLUE` color variable.
- `backup-verify.sh`: removed unused `YELLOW` and `OS_VERSION` variables.

### Added

- `cleanup-old-backups.sh`: accepts `BACKUP_BASE` as optional `$1` CLI argument (CLI → env var
  → default), eliminating the need for per-host patched copies.
- `cleanup-old-backups.sh`: `SEARCH_DEPTH` env var (default 2) controls `find -mindepth/-maxdepth`;
  depth-1 layouts (`BACKUP_BASE/YYYY-MM-DD/`) work without editing the script.
- `cleanup-old-backups.sh`: startup log now includes OS type, backup base, and search depth.
- `tests/cleanup-old-backups.bats`: 14 bats tests covering error handling, retention logic,
  depth variants, env var and CLI arg precedence, and ANSI-free log output.
- `.github/workflows/ci.yml`: ShellCheck (warning severity) + bats CI on every push and PR.
- `.shellcheckrc`: suppress SC2155 globally pending a dedicated cleanup pass (~80 instances
  across the four larger scripts).

---

## [0.1.0] — 2026-02-08

### Added

- Initial release of `docker-stack-backup` — Bash scripts for backing up Docker Compose stacks
  with appdata bind mounts
- `docker-stack-backup.sh` — Main backup script with OS detection (Debian, Ubuntu, TrueNAS),
  stack discovery, bind mount enumeration, and compressed archive creation
- `docker-stack-restore.sh` — Restore a backup archive to a target stack path
- `docker-stack-backup-manual.sh` — Manual single-stack backup for ad hoc use
- `backup-verify.sh` — Integrity verification for existing backup archives
- `cleanup-old-backups.sh` — Prune backup archives older than the configured retention window
- Multi-OS support: Debian, Ubuntu, TrueNAS/SCALE
- `set -euo pipefail` throughout; dry-run mode; optional notification hooks
- Reference docs: `USAGE.md`, `SAFETY_FEATURES.md`, `DRY_RUN.md`, `COMPRESSION.md`,
  `NOTIFICATIONS.md`, `OS_COMPATIBILITY.md`, `HOMELAB_SETUP.md`
