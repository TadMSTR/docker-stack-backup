# Dry-Run Mode

Both backup scripts support dry-run mode, which simulates the backup without actually making any changes. This is useful for testing, planning, and verification.

## Usage

### Automated Backup
```bash
# See what would be backed up
sudo docker-stack-backup.sh --dry-run

# Also works with short flag
sudo docker-stack-backup.sh -n
```

### Manual Backup
```bash
# Interactive selection with dry-run
sudo docker-stack-backup-manual.sh --dry-run
```

---

## What Dry-Run Does

### ✓ Actions Performed
- **Runs all pre-flight checks** - Verifies Docker, paths, disk space
- **Lists stacks** - Shows which would be backed up
- **Calculates sizes** - Estimates total backup size
- **Shows container states** - Which are running/stopped
- **Checks available space** - Verifies sufficient disk space
- **Logs simulation** - Records dry-run in log file

### ✗ Actions NOT Performed
- **No locking** - Doesn't prevent other backups from running
- **No container stopping** - Containers keep running
- **No backups created** - No tar files written
- **No notifications sent** - Won't trigger alerts
- **No state changes** - System remains untouched

---

## Output Examples

### Automated Backup Dry-Run

```bash
sudo docker-stack-backup.sh --dry-run
```

**Output:**
```
=========================================
DRY RUN MODE - No changes will be made
=========================================

=========================================
Running pre-flight checks...
=========================================
✓ Docker daemon is running
✓ Dockhand directory exists: /opt/dockhand/debian-docker
✓ Appdata directory exists: /mnt/datastor/appdata
✓ /mnt/backup/docker-backups is accessible (local filesystem)
✓ Disk space: 250GB available on /mnt/backup/docker-backups
=========================================
✓ All pre-flight checks passed
=========================================

Stacks that would be backed up:

  ✓ plex (45G appdata, 3 running)
  ✓ sonarr (2.1G appdata, 1 running)
  ✓ radarr (1.8G appdata, 1 running)
  ○ jellyfin (15G appdata, stopped)

Would skip (no appdata):

  ○ nginx
  ○ whoami
  ○ traefik

=========================================
Summary:
  Total stacks found: 7
  Would backup: 4
  Would skip: 3

  Estimated backup size: 62.1GB
  Compression method: none
  Backup extension: .tar

  Space available: 250GB
  ✓ Sufficient space available
=========================================

DRY RUN COMPLETE - No actions taken
```

### Manual Backup Dry-Run

```bash
sudo docker-stack-backup-manual.sh --dry-run
```

**Interactive Session:**
```
═══════════════════════════════════════════════════════
  Docker Stack Manual Backup - DRY RUN
  No changes will be made
  Host: debian-docker | OS: Debian GNU/Linux
═══════════════════════════════════════════════════════

Running pre-flight checks...

✓ Docker daemon running
✓ Dockhand directory found
✓ Appdata directory found
✓ Backup destination writable
✓ Disk space: 250GB available

✓ All checks passed

▶ Step 1: Select Stacks to Backup

  1) plex (appdata: 45G, 3 running)
  2) sonarr (appdata: 2.1G, 1 running)
  3) nginx (no appdata, stopped)
  4) radarr (appdata: 1.8G, 1 running)
  5) jellyfin (appdata: 15G, stopped)

Select stacks to backup: 1 2 4

✓ Selected 3 stack(s):
  - plex
  - sonarr
  - radarr

▶ Step 2: Backup Summary

plex
  └─ Appdata: 45G
  └─ Status: 3 container(s) running (will be stopped during backup)

sonarr
  └─ Appdata: 2.1G
  └─ Status: 1 container(s) running (will be stopped during backup)

radarr
  └─ Appdata: 1.8G
  └─ Status: 1 container(s) running (will be stopped during backup)

═══════════════════════════════════════════════════════
Total estimated backup size: 48.9GB
Stacks with appdata: 3
Running stacks (will be stopped): 3
Backup destination: /mnt/backup/docker-backups/debian-docker/20241203_140530
═══════════════════════════════════════════════════════

Proceed with backup? [y/N]: y

▶ Dry Run Results

Selected stacks:

  ✓ plex (45G, 3 running)
  ✓ sonarr (2.1G, 1 running)
  ✓ radarr (1.8G, 1 running)

═══════════════════════════════════════════════════════
Total stacks: 3
Estimated backup size: 48.9GB
Compression: none
═══════════════════════════════════════════════════════

DRY RUN COMPLETE - No actions taken
```

---

## Use Cases

### 1. Testing New Configuration
Before changing backup settings:

```bash
# Edit compression settings
sudo nano /usr/local/bin/docker-stack-backup.sh

# Test the changes
sudo docker-stack-backup.sh --dry-run

# If looks good, run for real
sudo docker-stack-backup.sh
```

### 2. Planning Storage Requirements
Estimate how much space you'll need:

```bash
# Check backup size before allocating storage
sudo docker-stack-backup.sh --dry-run | grep "Estimated backup size"
```

### 3. Verifying After Changes
After adding new stacks or modifying appdata:

```bash
# See what will be backed up now
sudo docker-stack-backup.sh --dry-run

# Compare to last backup
ls -lh /mnt/backup/docker-backups/$(hostname)/latest/
```

### 4. Training/Documentation
Show what the backup does without risk:

```bash
# Safe demonstration
sudo docker-stack-backup.sh --dry-run > backup-simulation.txt
```

### 5. Troubleshooting Pre-Flight Failures
Diagnose issues without attempting backup:

```bash
# Will run checks and show what's wrong
sudo docker-stack-backup.sh --dry-run
```

### 6. Validating Exclude Patterns
Test exclusion patterns before running real backup:

```bash
# Edit exclude patterns
sudo nano /usr/local/bin/docker-stack-backup.sh

# EXCLUDE_PATTERNS=(
#     "*/cache/*"
#     "*/tmp/*"
# )

# See what would be backed up
sudo docker-stack-backup.sh --dry-run
```

---

## Differences from Normal Mode

| Feature | Normal Mode | Dry-Run Mode |
|---------|-------------|--------------|
| Pre-flight checks | ✓ Yes | ✓ Yes |
| File locking | ✓ Yes | ✗ No |
| Stop containers | ✓ Yes | ✗ No |
| Create backups | ✓ Yes | ✗ No |
| Restart containers | ✓ Yes | ✗ No |
| Send notifications | ✓ Yes | ✗ No |
| Write to log | ✓ Yes | ✓ Yes (marked as dry-run) |
| Exit codes | 0=success, 1=error | 0=would succeed |

---

## Log File Entries

Dry-run operations are logged:

**Example log:**
```
[2024-12-03 14:05:30] =========================================
[2024-12-03 14:05:30] DRY RUN: Docker stack backup simulation
[2024-12-03 14:05:30] Hostname: debian-docker
[2024-12-03 14:05:30] OS: Debian GNU/Linux (debian)
[2024-12-03 14:05:30] =========================================
[2024-12-03 14:05:31] ✓ Docker daemon is running
[2024-12-03 14:05:31] ✓ Dockhand directory exists
...
[2024-12-03 14:05:35] Dry run complete
[2024-12-03 14:05:35] Would backup: 4 stacks
[2024-12-03 14:05:35] Estimated size: 62.1GB
[2024-12-03 14:05:35] =========================================
```

---

## Exit Codes

Dry-run mode uses standard exit codes:

- **0** - Success, backup would complete
- **1** - Error, backup would fail

**Example:**
```bash
sudo docker-stack-backup.sh --dry-run
echo $?  # Returns 0 if all checks pass, 1 if any check fails
```

---

## Scripting with Dry-Run

### Check if Backup Would Succeed
```bash
#!/bin/bash

if docker-stack-backup.sh --dry-run; then
    echo "Backup would succeed"
    # Schedule actual backup
    docker-stack-backup.sh
else
    echo "Backup would fail - fix issues first"
    exit 1
fi
```

### Get Estimated Size
```bash
#!/bin/bash

OUTPUT=$(docker-stack-backup.sh --dry-run)
SIZE=$(echo "$OUTPUT" | grep "Estimated backup size" | awk '{print $4}')

echo "Next backup will be approximately: $SIZE"
```

### Verify Before Cron Job
```bash
#!/bin/bash

# Run dry-run before actual backup
if ! /usr/local/bin/docker-stack-backup.sh --dry-run >> /var/log/backup-preflight.log 2>&1; then
    echo "Pre-flight dry-run failed, skipping backup"
    # Send alert
    curl -d "Backup pre-flight failed on $(hostname)" https://ntfy.sh/my-alerts
    exit 1
fi

# Proceed with actual backup
/usr/local/bin/docker-stack-backup.sh
```

---

## Limitations

### What Dry-Run Cannot Detect

1. **Mid-backup failures** - Won't catch errors during tar creation
2. **Restart issues** - Won't detect if containers would fail to restart
3. **Performance problems** - Won't measure actual backup speed
4. **Network issues** - Won't catch NFS mount problems during write
5. **Concurrent conflicts** - Doesn't acquire lock

### When to Still Be Careful

Even with dry-run, you should still:
- **Test on non-production first** - Verify logic before using in prod
- **Review exclude patterns** - Dry-run estimates size but doesn't show excluded files
- **Monitor actual runs** - First real backup might behave differently
- **Check compression** - Size estimates don't account for compression ratios

---

## Best Practices

### Before First Use
```bash
# 1. Dry-run to verify configuration
sudo docker-stack-backup.sh --dry-run

# 2. Review what will be backed up
# 3. Check estimated sizes
# 4. Verify available space

# 5. Run actual backup
sudo docker-stack-backup.sh
```

### Before Configuration Changes
```bash
# 1. Note current settings
grep "COMPRESSION_METHOD\|EXCLUDE_PATTERNS" /usr/local/bin/docker-stack-backup.sh

# 2. Make changes

# 3. Dry-run to verify
sudo docker-stack-backup.sh --dry-run

# 4. If good, run backup
sudo docker-stack-backup.sh
```

### Regular Verification
```bash
# Monthly: Verify backup configuration still makes sense
sudo docker-stack-backup.sh --dry-run > /tmp/backup-plan.txt
# Review /tmp/backup-plan.txt
```

---

## Help Output

```bash
sudo docker-stack-backup.sh --help
```

**Output:**
```
Usage: docker-stack-backup.sh [OPTIONS]

Options:
  --dry-run, -n    Simulate backup without making changes
  --help, -h       Show this help message

Examples:
  docker-stack-backup.sh                Run backup normally
  docker-stack-backup.sh --dry-run      Show what would be backed up
```

---

## Summary

Dry-run mode is a powerful tool for:
- ✓ **Planning** - See what will happen before it happens
- ✓ **Testing** - Verify configuration without risk
- ✓ **Debugging** - Diagnose issues safely
- ✓ **Documentation** - Show backup behavior
- ✓ **Validation** - Check pre-flight conditions

**Remember:** Dry-run is a simulation. Always test actual backups in a controlled environment first!
