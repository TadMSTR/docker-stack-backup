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
lib.sh                         Shared functions, sourced by every script; DSB_VERSION
docker-backup-tar-create.sh    Root helper: tar of one stack (ELEVATION.md)
docker-backup-snapshot.sh      Root helper: btrfs/ZFS snapshots (ELEVATION.md)
docker-backup-restic.sh        Root helper: restic, as a dedicated uid (RESTIC.md)
tests/host/restore-drill.sh    Host acceptance drill, run as root (both backends)
dsb_status.py                  Run status helper (python3 -I, stdlib only): status.json,
                               .prom, coverage classifier, exemptions. See STATUS.md
```

Reference docs: `RESTIC.md` (the restic backend), `STATUS.md` (the status contract: its schema, reasons, classes and
metrics are an interface; additive changes keep `schema: 1`), `USAGE.md`, `SAFETY_FEATURES.md`, `DRY_RUN.md`, `COMPRESSION.md`, `NOTIFICATIONS.md`, `OS_COMPATIBILITY.md`, `HOMELAB_SETUP.md`.

## When editing scripts

- Test with `--dry-run` before committing.
- `set -euo pipefail` is used throughout — do not remove it.
- OS detection is via `/etc/os-release` — add new distros to the `case` block in `detect_os()`.
- Notification integration is optional and configured via env vars — see `NOTIFICATIONS.md`.
- Do not hardcode paths; use variables that can be overridden via env vars.

## Git workflow

Work on a branch and open a pull request; do not commit to `main` directly. CI
(ShellCheck at severity warning, plus `bats tests/`) must be green before merge. Releases
are cut by pushing a `vX.Y.Z` tag after merge (the Release workflow publishes it), and
`DSB_VERSION` in `lib.sh` must match the tag.
