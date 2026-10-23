# Usage Guide

Detailed instructions for configuring and using the Docker Stack Backup & Restore toolkit.

## Table of Contents

1. [Initial Setup](#initial-setup)
2. [Configuration](#configuration)
3. [Running Backups](#running-backups)
   - [Backup tiers (`x-backup`)](#backup-tiers-x-backup)
   - [Snapshots](#snapshots)
   - [Backends: tar and restic](#backends-tar-and-restic)
4. [Restoring from Backup](#restoring-from-backup)
5. [Verification & Maintenance](#verification--maintenance)
6. [Automation](#automation)

---

## Initial Setup

### Prerequisites

```bash
# Verify Docker is installed and running
docker --version
docker compose version

# Check that Dockhand is managing your stacks
ls -la /path/to/dockhand/$(hostname)

# Ensure appdata directory exists
ls -la /mnt/datastor/appdata
```

### Installation

```bash
# Clone the repository
cd ~
git clone git@github.com:TadMSTR/docker-stack-backup.git
cd docker-stack-backup

# Make scripts executable
chmod +x *.sh

# Install to system (dsb_status.py writes the run status; keep it next to the scripts)
sudo cp *.sh dsb_status.py /usr/local/bin/

# Create log directory (if it doesn't exist)
sudo touch /var/log/docker-backup.log
sudo touch /var/log/docker-backup-manual.log
sudo touch /var/log/docker-restore.log
```

---

## Configuration

### Core Settings

Edit each script and update these paths:

**docker-stack-backup.sh:**
```bash
DOCKHAND_BASE="/path/to/dockhand"
APPDATA_PATH="/mnt/datastor/appdata"
BACKUP_DEST="/mnt/backup/docker-backups"
```

**docker-stack-backup-manual.sh:**
```bash
# Same settings as above
DOCKHAND_BASE="/path/to/dockhand"
APPDATA_PATH="/mnt/datastor/appdata"
BACKUP_DEST="/mnt/backup/docker-backups"
```

**docker-stack-restore.sh** and **backup-verify.sh** read the same `BACKUP_DEST` the backup
writes. Set `BACKUP_BASE` only to read a different share:
```bash
BACKUP_DEST="/mnt/backup/docker-backups"   # or BACKUP_BASE=… to override for these tools
DOCKHAND_BASE="/path/to/dockhand"
APPDATA_PATH="/mnt/datastor/appdata"
```

Restore stages the extracted archive under `TMPDIR` (default `/tmp`). With option 2 in
Step 5, it also writes a pre-restore copy of the old stack dir and appdata under
`RESTORE_SAFETY_DIR` (default `TMPDIR`). Before Step 6 changes anything, it checks that
both fit and stops with a message naming these variables if they don't. On a host with a
small `/tmp`, run it as `sudo TMPDIR=/srv/scratch ./docker-stack-restore.sh`. Under the
default `TMPDIR` the safety copy is **temporary**. Debian removes `/tmp` files after 10 days,
and a tmpfs `/tmp` is emptied at reboot. Set `RESTORE_SAFETY_DIR` in `config.sh` to keep it.

> **The backup share is a root trust boundary.** Restore runs as root and puts back what the
> archive holds: owners, modes, setuid bits and device nodes. The archived `compose.yaml` and
> `.env` are what `docker compose up -d` runs. Anyone who can write the share can therefore
> act as root on the host you restore to. Keep the share writable only by the backup user,
> and keep that user as trusted as root. Step 4 lists any setuid/setgid, device, pipe or
> socket members before you confirm. Symlinked `compose`/`.env`/appdata members are refused,
> and names outside `[A-Za-z0-9._-]` are rejected.

### Backup Destination Setup

#### Option 1: Local Backup (TrueNAS)

If running on TrueNAS and backing up locally:

```bash
BACKUP_DEST="/mnt/pool/backup/docker-backups"
```

#### Option 2: Remote Backup via NFS (Debian → TrueNAS)

```bash
# On Debian, mount TrueNAS share
sudo mkdir -p /mnt/backup

# Add to /etc/fstab
echo "truenas-ip:/mnt/pool/backup /mnt/backup nfs defaults 0 0" | sudo tee -a /etc/fstab

# Mount it
sudo mount /mnt/backup

# Set in script
BACKUP_DEST="/mnt/backup/docker-backups"
```

#### Option 3: Remote Backup via SMB/CIFS

```bash
# Install CIFS utils
sudo apt-get install cifs-utils

# Create credentials file
sudo cat > /root/.smbcredentials << EOF
username=your_username
password=your_password
EOF

sudo chmod 600 /root/.smbcredentials

# Add to /etc/fstab
echo "//truenas-ip/backup /mnt/backup cifs credentials=/root/.smbcredentials,uid=0,gid=0 0 0" | sudo tee -a /etc/fstab

# Mount it
sudo mount /mnt/backup
```

### Notification Setup

See [NOTIFICATIONS.md](NOTIFICATIONS.md) for detailed configuration of:
- Ntfy
- Pushover
- Email (including Proton Mail Bridge)

---

## Running Backups

### Automated Backup (All Stacks)

```bash
# Run manually
sudo docker-stack-backup.sh

# Check the log
tail -f /var/log/docker-backup.log
```

This will:
1. Scan all Dockhand stacks
2. Backup only those with appdata bind mounts
3. Preserve container run states
4. Send notifications (if configured)
5. Write the run status: `status.json` next to the run dirs (and a copy inside this run's
   dir), plus `docker_stack_backup.prom` if `PROM_TEXTFILE_DIR` is set. See
   [STATUS.md](STATUS.md)

### Stack results and reasons

Every stack ends as `backed_up`, `skipped` or `failed`, and `status.json` records why.
These values are a contract from 0.6.0 on: alerts and dashboards match on them.

| Result | Reason | Meaning |
|---|---|---|
| skipped | `no-appdata-reference` | the compose file never names `APPDATA_PATH` |
| skipped | `appdata-missing` | `APPDATA_PATH/<stack>` does not exist |
| skipped | `appdata-empty` | `APPDATA_PATH/<stack>` is empty (checked only without ELEVATION_CMD) |
| skipped | `not-running` | nothing runs and `BACKUP_STOPPED_STACKS=false` |
| failed | `compose-ps-failed` | `docker compose ps` failed, so the running state is unknown |
| failed | `running-state-mismatch` | compose sees nothing running, docker does |
| failed | `stop-failed` | `docker compose stop` failed (what was running is started again) |
| failed | `archive-failed` | the archive could not be written (what was running is started again) |
| failed | `restart-failed` | archived, but the stack did not come back up (CRITICAL notification) |
| failed | `interrupted` | a second INT/TERM arrived while this stack was being backed up; its services may be stopped |
| failed | `restic-backup-failed` | the stack's restic backup failed (0.8.0; restic exit 3 = some files could not be read) |
| failed | `restic-repo-locked` | the restic repository was locked during the stack's backup (0.8.0) |
| failed | `restic-repo-missing`, `restic-password-wrong`, `restic-repo-error`, `restic-helper-refused`, `restic-helper-failed` | restic could not be used at all this run (0.8.0); every stack's restic backup fails with the same reason, which is also `restic.problem` |

With more than one backend, a stack is `backed_up` only if every backend scheduled for it
this run succeeded; `stacks[].backends` in status.json has each backend's own result.

`no-compose-file` exists in the code but is never recorded: a dir without a compose file
is not counted as a stack. The log and notification text keep their 0.5.x wording, so the
last three failures appear there as a bare `Failed stacks: <name>`; `status.json` carries
the reason.

To see what each stack holds that the archive does **not** take (named volumes, writable
host paths, appdata dirs no stack owns), without stopping or writing anything:

```bash
docker-stack-backup.sh --coverage-report | python3 -m json.tool | less
```

### Manual Backup (Selected Stacks)

```bash
# Run interactive mode
sudo docker-stack-backup-manual.sh
```

**Example session:**
```
▶ Step 1: Select Stacks to Backup

  1) plex (appdata: 45G, 3 running)
  2) sonarr (appdata: 2.1G, 1 running)
  3) nginx (no appdata, stopped)
  4) radarr (appdata: 1.8G, 1 running)

Select stacks to backup: 1 2 4

✓ Selected 3 stack(s):
  - plex
  - sonarr
  - radarr

▶ Step 2: Backup Summary
[Shows details and asks for confirmation]

▶ Step 3: Performing Backup
[Backs up each stack with progress]
```

**Selection tips:**
- Individual: `1 3 5`
- Ranges: `1-3 5-7`
- All with appdata: `all`

### Backup tiers (`x-backup`)

*0.7.0.* By default every stack that binds `APPDATA_PATH` is backed up **daily, in
full**. A stack can narrow that in its own compose file, with a top-level `x-backup:`
block. Compose ignores `x-` keys, so the stack itself is unaffected.

```yaml
x-backup:
  exclude:                 # never backed up
    - path: ollama/models/blobs
      reason: "re-download with ollama pull; manifests are kept"
  weekly:                  # backed up on the full run only
    - path: search/index
      reason: "rebuilt by reindex; a week's loss is acceptable"
  retention:               # reserved for the restic backend (0.8.0); validated, not used yet
    daily: 7
    weekly: 4
    monthly: 6
```

- **`path`** is relative to `$APPDATA_PATH/<stack>` and is a **literal** path, not a
  pattern. Each `/`-separated part may use only `A-Z a-z 0-9 . _ -`. Paths that are
  empty, contain `.`, `..` or a part starting with `-`, start with `/`, or exceed 255
  bytes are refused. A path leaves out that file or directory **and everything under
  it**, and nothing else: `models/blobs` does not touch `models/blobs2` or
  `other/models/blobs`.
- **`reason`** is required (≤ 200 characters, no control characters). It is reported in
  `status.json` and printed by the dry run. Compose interpolates `${VAR}` in it, so write
  `$$` for a literal `$`.
- At most 64 entries per list. A path may be in one list only. Unknown keys are errors.
- **Run kind.** A run is `full` on `FULL_RUN_DAY` (1 = Monday … 7 = Sunday, default 7)
  or with `--full`, and `daily` otherwise. A daily run leaves out both lists (the
  weekly list is reported as *deferred*). A full run leaves out only `exclude`. The
  manual script always backs up as a full run.

**A declaration can only narrow a backup, and an invalid one narrows nothing.** If the
block has any error, the whole block is ignored: the stack is backed up in full, the
errors go to the log, and the stack's `x_backup.status` is `config-error`, which makes the
run's `coverage.status` `config-error` (STATUS.md) and sets
`dsb_stack_xbackup_config_error`. A declared path that does not exist is reported as
*stale*, but is not an error.

The block is read through `docker compose config --format json`, the same reader the
coverage classifier uses. It is never parsed as YAML here and never sourced. The global
`EXCLUDE_PATTERNS` keep their meaning: unanchored globs that match at any depth in every
stack. The two kinds do not interfere (`tests/xbackup-tar.bats`).

Check a declaration before the nightly picks it up:

```bash
./docker-stack-backup.sh --dry-run          # per stack: the tiers, with their reasons
./docker-stack-backup.sh --coverage-report  # per stack: "x_backup": {...}
```

**Example: ollama.** `models/blobs` holds every model's layers (forge: 18 GB) and
`models/manifests` says which ones to pull. The path is relative to the stack's appdata
dir: forge mounts `/opt/appdata/ollama/ollama:/root/.ollama`, so there it is
`ollama/models/blobs`. Check it with `--dry-run`: a path that does not exist is listed
as *stale* (and excludes nothing). Library models come back with
`ollama pull <name>`, so `exclude: models/blobs` is safe for them, **but a custom model
(one built with `ollama create` from a Modelfile) has its layers only in `blobs`.** Put
its Modelfile in git first (`ollama show --modelfile <name> > <name>.Modelfile`). A
restore then needs `ollama pull` for each library model and `ollama create` for each
custom one.

### Snapshots

*0.7.0.* Without snapshots, a running stack is stopped for as long as its archive takes to
write (forge: up to about 3 minutes for the largest). With a snapshot backend it is
stopped only while a read-only snapshot is taken, then started, and the archive is read
from the snapshot:

```
stop → snapshot → start → archive from the snapshot → delete the snapshot
```

`downtime_s` in status.json then covers only stop → started. The archive is
**identical in layout**: the same `<stack>/…` member names, the compose file and `.env`
at the root, so restore, verify and cleanup are unchanged.

| Setting | Values | Default |
|---|---|---|
| `SNAPSHOT_BACKEND` | `none`, `auto`, `btrfs`, `zfs` | `none` (the Debian profile picks `auto`, TrueNAS `zfs`; see `PLATFORM`) |
| `SNAPSHOT_HELPER_PATH` | path of the installed `docker-backup-snapshot.sh` | empty |

Snapshots need the root-owned snapshot helper (ELEVATION.md, "The snapshot helper"),
which holds the snapshot settings itself (appdata root, backend, snapshot dir). The script
checks that the helper's appdata root equals `APPDATA_PATH` before it uses it.

- An **explicit** `btrfs` or `zfs` in config.sh that cannot work (wrong filesystem, no
  helper, a helper set up for another root) **fails the preflight**.
- `auto`, or a backend that came from the platform profile, falls back to `none` instead.
  The reason is logged and written to `status.json` as `snapshot_note`. So upgrading to
  0.7.0 without installing the helper changes nothing.

**A snapshot that hides data is worse than downtime.** A btrfs snapshot shows a nested
subvolume as an empty directory, and a ZFS snapshot leaves out child datasets. Before it
stops a stack, the run asks the helper to check the stack's appdata. That covers the
stack dir itself and everything under it. A nested btrfs subvolume, a ZFS child dataset
or any other mountpoint makes that stack fall back to the old stop-archive-start
(`fallback_reason`). So does a directory the check cannot read, ZFS `snapdir=disabled`
(the snapshot cannot be read), or a failed snapshot. The stack is never stopped twice.

Other behaviour:

- A stopped stack is archived live, with no snapshot: there is nothing to quiesce.
- The snapshot is deleted after its archive, whether the archive worked or not, and on
  any exit or signal.
- Each run first sweeps leftover `dsb-<stack>-<timestamp>` snapshots from runs that died,
  and logs each one. Nothing else in the snapshot dir or dataset is touched. The sweep
  covers every `dsb-*` snapshot the helper manages, while the run lock is per
  `LOCK_FILE`. So use **one** schedule (one config) per helper: two configs sharing a
  helper with different `LOCK_FILE`s would sweep each other's in-flight snapshots.
- A delete that fails, or a sweep that fails, is counted in `snapshot_cleanup.failed`
  (status.json), in `dsb_snapshot_cleanup_failures`, and in the notification text.
- If the stack fails to start again after the snapshot, the archive is still made (the
  snapshot holds the quiesced data), and the stack is reported `failed` / `restart-failed`
  as before.

The manual script does not use snapshots: it is run by hand, for a few stacks, and keeps
the plain stop-archive-start.

### Backends: tar and restic

*0.8.0.* `BACKENDS` selects what each stack is written to: `tar` (the default: an archive
per stack in a run dir), `restic` (one snapshot per stack in a restic repository), or
`"tar restic"`. RESTIC.md has the restic side: install, retention, prune and check,
security.

- **One stop per stack, whatever the number of backends.** Both read the same source: the
  snapshot (after the stack is started again) or, for a stopped stack or a snapshot
  fallback, the live dir while the stack is still stopped.
- **The same excludes.** `x-backup` paths and `EXCLUDE_PATTERNS` leave out exactly the same
  files from both (`tests/restic-e2e.bats`).
- **`TAR_SCHEDULE`**: `daily` (every run, the default) or `full`, which writes the tar set
  only on the full run (`FULL_RUN_DAY`, or `--full`): a weekly tar beside daily restic.
  `full` needs both backends, or daily runs would back up nothing.
- **Weekly tar retention.** `cleanup-old-backups.sh` needs no change, but its settings
  do: `RETENTION_DAYS=27 KEEP_MIN=4` keeps exactly the four newest weekly sets on every
  night of the week. `RETENTION_DAYS=29` keeps five on the full-run day, because the set
  from 28 days ago is not "more than 29 days" old (`tests/cleanup-weekly.bats`).
- The dry run prints the backends and, per stack, which ones would run.
- The manual script writes tar only.

Archives are written **0600** in **0700** run dirs (#1089). Restore and verify read the
share as its owner, which also works when root is squashed on an NFS export (RESTIC.md
"Upgrading to 0.8.0" has the one-time `chmod` of older archives).

---

## Restoring from Backup

### Interactive Restore

```bash
# Run the restore wizard
sudo docker-stack-restore.sh
```

**Wizard flow:**

**Step 0: Select Backup Source** (0.8.0, only when `RESTIC_HELPER_PATH` is set): `1)` tar
archives on the share, or `2)` restic snapshots of this host. For restic, Step 2 lists the
stacks with snapshots and Step 3 the stack's snapshots, newest first, with the run kind.
Steps 4-6 are the same for both sources: the wizard reads one tar stream, from the archive
or from the restic helper's `dump`, which has the archive's member layout (RESTIC.md
"Restore").

**Step 1: Select Host**
```
Available hosts:
  1) debian-docker
  2) truenas-docker

Select host number [1]: 1
```

**Step 2: Select Backup Date**
```
Available backups (newest first):
  1) December 03, 2024 at 02:00:15 (7 stacks)
  2) December 02, 2024 at 02:00:12 (7 stacks)

Select backup number [1]: 1
```

**Step 3: Select Stack**
```
Available stacks:
  1) plex (45G)
  2) sonarr (2.1G)
  3) radarr (1.8G)

Select stack number [1]: 1
```

**Step 4: Preview Contents**
```
Contents of backup:
─────────────────────────────────────────────
docker-compose.yml
.env
plex/...
─────────────────────────────────────────────

Proceed with restore? [y/N]: y
```

**Step 5: Handle Conflicts**

If stack already exists:
```
⚠ Conflicts detected!

Choose how to proceed:
  1) Stop containers and overwrite everything (destructive)
  2) Backup existing data first, then restore
  3) Cancel restore

Select option [3]: 2
```

**Step 6: Restore**

The archive is extracted while the stack is still running, so a corrupt archive or a full
disk causes no downtime. Then the stack is stopped, the safety copy is taken (option 2),
and the files are replaced:
```
Extracting backup...
Stopping existing stack
Creating safety backup in /tmp/docker-restore-backup-plex-20261014_101500.Ab12Cd
✓ Safety backup created
Restoring stack configuration...
Restoring appdata...
✓ Files restored successfully

Start the stack now? [y/N]: y
✓ Stack started successfully
...
Pre-restore copy of the old data: /tmp/docker-restore-backup-plex-20261014_101500.Ab12Cd
```
If `docker compose up -d` fails, the wizard prints the command to start the stack by hand
and exits non-zero. The restored files stay in place.

---

## Verification & Maintenance

### Verify Backup Integrity

```bash
# List all backups
backup-verify.sh --list

# Verify all backup files
backup-verify.sh --verify

# Show statistics
backup-verify.sh --stats

# Filter by hostname
backup-verify.sh --list -h debian-docker
```

### Clean Old Backups

```bash
# Remove backups older than 30 days (default)
sudo cleanup-old-backups.sh

# View what would be deleted first
find /mnt/backup/docker-backups -type d -mtime +30

# Adjust retention in the script
# Edit RETENTION_DAYS in cleanup-old-backups.sh

# Weekly tar sets (TAR_SCHEDULE=full): exactly the 4 newest
RETENTION_DAYS=27 KEEP_MIN=4 cleanup-old-backups.sh
```

---

## Automation

### Daily Automated Backups

```bash
# Edit root's crontab
sudo crontab -e

# Add daily backup at 2 AM
0 2 * * * /usr/local/bin/docker-stack-backup.sh

# Or with output logging
0 2 * * * /usr/local/bin/docker-stack-backup.sh >> /var/log/docker-backup-cron.log 2>&1
```

### Weekly Cleanup

```bash
# Add to root's crontab
# Weekly cleanup on Sunday at 3 AM
0 3 * * 0 /usr/local/bin/cleanup-old-backups.sh
```

### Backup Verification (Monthly)

```bash
# Add to root's crontab
# Monthly verification on 1st at 4 AM
0 4 1 * * /usr/local/bin/backup-verify.sh --verify >> /var/log/backup-verify.log 2>&1
```

### Complete Cron Setup Example

```bash
sudo crontab -e
```

Add these lines:
```cron
# Docker Stack Backups
0 2 * * * /usr/local/bin/docker-stack-backup.sh
0 3 * * 0 /usr/local/bin/cleanup-old-backups.sh
0 4 1 * * /usr/local/bin/backup-verify.sh --verify >> /var/log/backup-verify.log 2>&1
```

---

## Tips & Best Practices

### Performance

- Large appdata directories (50GB+) can take several minutes to backup
- Consider backing up large stacks during low-usage hours
- NFS is faster than SMB for large transfers
- Use local backups when possible, then sync to remote

### Safety

- Always test restore on non-production stacks first
- Keep at least 7 days of backups before deleting
- Verify backups monthly
- Test notification delivery
- Document your stack configurations

### Organization

- Use descriptive stack names in Dockhand
- Keep related containers in the same stack
- Document dependencies between stacks
- Maintain a recovery runbook

### Monitoring

- Set up failure notifications (high priority)
- Monitor backup sizes for unexpected changes
- Check logs weekly: `tail -100 /var/log/docker-backup.log`
- Verify backup destinations have adequate space

---

## Troubleshooting

### Common Issues

**Problem: "No stacks found"**
```bash
# Verify Dockhand path
ls -la /path/to/dockhand/$(hostname)

# Check hostname matches directory name
hostname
```

**Problem: "Permission denied"**
```bash
# Ensure running as root
sudo -i

# Check file permissions
ls -la /usr/local/bin/docker-stack-backup.sh
```

**Problem: "Stack won't restart"**
```bash
# Check Docker status
systemctl status docker

# View stack logs
cd /path/to/dockhand/$(hostname)/stack-name
docker compose logs

# Check for port conflicts
docker compose ps
```

**Problem: "Backup destination not writable"**
```bash
# Check mount
df -h /mnt/backup
mount | grep backup

# Test write access
touch /mnt/backup/test && rm /mnt/backup/test
```

### Getting Help

1. Check the logs: `/var/log/docker-backup.log`
2. Run scripts with bash debug: `bash -x /usr/local/bin/docker-stack-backup.sh`
3. Verify all paths in configuration
4. Test individual components (Docker, mounts, notifications)
5. Open an issue on GitHub with log excerpts

---

## Next Steps

1. ✅ Complete initial setup
2. ✅ Configure backup destination
3. ✅ Test manual backup
4. ✅ Set up notifications
5. ✅ Schedule automated backups
6. ✅ Test restore procedure
7. ✅ Configure cleanup automation
8. ✅ Document your specific setup

For notification setup, see [NOTIFICATIONS.md](NOTIFICATIONS.md)
