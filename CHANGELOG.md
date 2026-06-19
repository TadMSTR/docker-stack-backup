# Changelog

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
