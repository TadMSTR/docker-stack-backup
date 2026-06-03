# Changelog

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
