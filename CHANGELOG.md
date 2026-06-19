# Changelog

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
