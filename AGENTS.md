# docker-stack-backup

Bash scripts for backing up Docker Compose stacks that use appdata bind mounts. Multi-OS (Debian, Ubuntu, TrueNAS). No code compilation required.

## What it does

Detects Docker Compose stacks, stops them (or uses snapshot), archives their bind-mount appdata, and optionally restores from a backup archive.

## Structure

```
docker-stack-backup.sh         Main backup script — detects OS, finds stacks,
                               backs up bind mounts
docker-stack-restore.sh        Restore a backup archive to a stack
docker-stack-backup-manual.sh  Manual backup for a single named stack
backup-verify.sh               Integrity verification for existing backup archives
cleanup-old-backups.sh         Prune backups older than the configured retention window
```

Reference docs: `USAGE.md`, `SAFETY_FEATURES.md`, `DRY_RUN.md`, `COMPRESSION.md`, `NOTIFICATIONS.md`, `OS_COMPATIBILITY.md`, `HOMELAB_SETUP.md`.

## When editing scripts

- Test with `--dry-run` before committing.
- `set -euo pipefail` is used throughout — do not remove it.
- OS detection is via `/etc/os-release` — add new distros to the `case` block in `detect_os()`.
- Notification integration is optional and configured via env vars — see `NOTIFICATIONS.md`.
- Do not hardcode paths; use variables that can be overridden via env vars.

## Git workflow

Changes can be committed directly to `main`.
