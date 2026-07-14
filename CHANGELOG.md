# Changelog

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
