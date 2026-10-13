# Safety Features & Error Handling

The backup scripts include comprehensive safety checks and error handling to prevent common failure scenarios.

## 1. File Locking (Prevents Concurrent Runs)

### What It Does
- Prevents multiple backup jobs from running simultaneously
- Uses system-level file locks (`flock`)
- Automatically releases lock on exit/crash

### Lock Files
- Automated backup: `/var/run/docker-stack-backup.lock`
- Manual backup: `/var/run/docker-stack-backup-manual.lock`

### Behavior
```
First instance:  Acquires lock → Runs backup
Second instance: Detects lock → Exits with error message
```

### Manual Override
If a backup crashes and leaves a stale lock:

```bash
# Check if backup is actually running
ps aux | grep docker-stack-backup

# If not running, remove lock file
sudo rm /var/run/docker-stack-backup.lock
```

### Why This Matters
**Prevents:**
- Corrupted backups from simultaneous writes
- Multiple stacks stopped at once
- Race conditions on shared resources
- Backup destination conflicts

---

## 2. Pre-Flight Checks

### What Gets Checked

#### ✓ Docker Daemon Status
- Verifies Docker service is running
- Tests Docker API responsiveness
- Prevents operations if Docker is down

**Failure Example:**
```
[ERROR] Docker daemon is not running
[ERROR] Start with: systemctl start docker
```

#### ✓ Required Paths Exist
- Dockhand directory: `/path/to/dockhand/hostname/`
- Appdata directory: `/mnt/datastor/appdata/`

**Failure Example:**
```
[ERROR] Dockhand directory not found: /opt/dockhand/debian-docker
```

#### ✓ Backup Destination Accessible
- Directory exists or can be created
- Write permissions verified
- Mount point check (if applicable)

**Failure Example:**
```
[ERROR] Cannot write to /mnt/backup/docker-backups
[ERROR] Check permissions and mount status
```

#### ✓ Sufficient Disk Space
- Requires the larger of `MIN_FREE_GB` (default 5) and 1.2 × the size of this host's most recent previous run
- Checks actual available space
- Prevents mid-backup disk full errors

**Failure Example:**
```
[ERROR] Insufficient disk space on /mnt/backup/docker-backups
[ERROR] Available: 2GB, Required: 5GB
```

### Pre-Flight Output

**Automated Backup:**
```
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
```

**Manual Backup:**
```
Running pre-flight checks...

✓ Docker daemon running
✓ Dockhand directory found
✓ Appdata directory found
✓ Backup destination writable
✓ Disk space: 250GB available

✓ All checks passed
```

### Customizing Disk Space Requirements

Set the floor in `config.sh` (or the environment). The estimate from the previous run
still applies when it is larger:

```bash
MIN_FREE_GB=10   # Require at least 10GB instead of 5GB
```

---

## 3. Improved Restart Error Handling

### Stop/start, never recreate
The backup stops a stack with `docker compose stop` and brings it back with
`docker compose start <previously running services>`. The containers are never removed, so:

- no image is pulled
- no pending compose-file or image change is applied (backups do not deploy)
- each container's writable layer is kept

If `start` fails (for example a container was removed by hand while the stack was
stopped), the attempt falls back to `docker compose up -d --no-recreate --pull never`.
That creates only the missing containers, from local images, and never touches the
existing ones. The fallback is logged as a warning naming the deploy path.

### Retry Logic
When containers fail to start after backup:

1. **Attempt 1**: Try to start containers
2. **Wait 5 seconds** (configurable)
3. **Attempt 2**: Retry
4. **Wait 5 seconds**
5. **Attempt 3**: Final attempt
6. **Verify**: Check containers actually started

### Configuration
Set in `config.sh` or the environment:
```bash
MAX_RESTART_ATTEMPTS=3      # Number of retry attempts
RESTART_RETRY_DELAY=5       # Seconds between retries
```

### What Gets Verified
- Containers start successfully (not just command succeeds)
- Every previously running service is running again (a dependency compose starts on its own is not counted)
- Status checked 2 seconds after start

### Failure Handling

#### Automated Backup
If restart fails after all retries:

1. **Logs detailed error:**
```
[ERROR] Failed to restart stack after 3 attempts
[ERROR] Stack: plex
[ERROR] Containers that should be running: plex
[ERROR] Manual intervention required!
[ERROR] To restart manually: cd /path/to/stack && docker compose start plex
```

2. **Sends CRITICAL notification** (regardless of normal notification settings):
```
CRITICAL: Stack Failed to Restart - debian-docker

⚠️  IMMEDIATE ACTION REQUIRED ⚠️

Stack: plex
Host: debian-docker
Containers: plex

Manual restart command:
cd /opt/dockhand/debian-docker/plex && docker compose start plex

Check logs:
/var/log/docker-backup.log
```

**Notification Priority:**
- Ntfy: `urgent` priority (with warning emoji)
- Pushover: Priority `1` (high)
- Email: Subject line marked `[CRITICAL]`

#### Manual Backup
Interactive feedback during retries:

```
  └─ Starting containers (attempt 1/3)...
     ⚠️ Container failed to start
  └─ Waiting 5s before retry...
  └─ Starting containers (attempt 2/3)...
     ✓ All containers started
```

### Common Causes of Restart Failures

**Port Conflicts:**
- Another service claimed the port while stack was down
- Solution: Stop conflicting service, restart stack

**Dependency Issues:**
- Dependent stack/service not available
- Solution: Start dependencies first

**Resource Exhaustion:**
- Out of memory/CPU
- Solution: Free resources, restart stack

**Configuration Errors:**
- Compose file or env file issues
- Solution: Check Docker logs, fix config

### Manual Recovery

If restart fails, manually restart the stack:

```bash
# Navigate to stack directory
cd /opt/dockhand/debian-docker/plex

# Check what's wrong
docker compose logs

# Try starting again (same containers)
docker compose start

# Or specific services
docker compose start plex

# Only if the containers are gone: create them from local images
docker compose up -d --no-recreate --pull never
```

---

## Error Handling Summary

### Before Backup
| Check | Action on Failure |
|-------|------------------|
| Another backup running | Exit immediately |
| Docker not running | Exit with error |
| Paths missing | Exit with error |
| No disk space | Exit with error |
| Cannot write to destination | Exit with error |

### During Backup
| Issue | Action |
|-------|--------|
| Stack has no appdata | Skip (`no-appdata-reference`), log warning |
| Appdata directory missing | Skip (`appdata-missing`), log warning |
| Appdata directory empty | Skip (`appdata-empty`), log warning |
| No running containers | Archive as-is, no stop/start (`BACKUP_STOPPED_STACKS=true`); or skip (`not-running`) |
| Failed to stop stack | Count as failed, start what was running, log error |
| Failed to create backup | Count as failed, delete the partial `.incomplete` file, restart stack, log error |

Skipped stacks are listed by name with their reason in the run summary and in the
notification; they are never counted as backed up.

### Atomic archives
Each archive is written as `<stack>.incomplete` and renamed to `<stack>.tar[.ext]` only
after it completes. `backup-verify.sh` and `docker-stack-restore.sh` look for `*.tar` /
`*.tar.*`, so a failed or interrupted archive is never mistaken for a backup. A run dir
that ends up with no archives is removed.

### Retention keeps a minimum
`cleanup-old-backups.sh` never deletes the newest `KEEP_MIN` (default 7) run dirs per
host, whatever their age. Only dirs holding a completed archive count toward that
minimum, so a run of failed nights cannot push the last good backups out.

### After Backup
| Issue | Action |
|-------|--------|
| Restart fails (attempt 1) | Wait, retry |
| Restart fails (attempt 2) | Wait, retry |
| Restart fails (attempt 3) | Log critical error, send urgent notification |

---

## Best Practices

### Monitoring
1. **Review logs regularly:**
   ```bash
   tail -100 /var/log/docker-backup.log
   ```

2. **Check for failed restarts:**
   ```bash
   grep "Failed to restart" /var/log/docker-backup.log
   ```

3. **Verify disk space trends:**
   ```bash
   df -h /mnt/backup/docker-backups
   ```

### Maintenance
1. **Test notifications** - Ensure critical alerts actually reach you
2. **Check lock files** - Remove stale locks if needed
3. **Monitor disk usage** - Clean old backups before space runs out
4. **Test restarts** - Verify stacks can actually restart

### Planning
1. **Schedule backups during low-usage hours** - Minimize impact of downtime
2. **Stagger backups** - Don't backup all hosts at 2 AM
3. **Increase disk space threshold** - For large backup volumes
4. **Document manual recovery** - So you know what to do at 3 AM

---

## Troubleshooting

### Lock File Won't Release
```bash
# Check if process is actually running
ps aux | grep docker-stack-backup

# If not, manually remove lock
sudo rm /var/run/docker-stack-backup.lock
```

### Pre-Flight Checks Keep Failing
```bash
# Check Docker
sudo systemctl status docker
sudo docker info

# Check paths
ls -la /opt/dockhand/$(hostname)
ls -la /mnt/datastor/appdata

# Check disk space
df -h /mnt/backup/docker-backups

# Check write permissions
sudo touch /mnt/backup/docker-backups/test
sudo rm /mnt/backup/docker-backups/test
```

### Stack Won't Restart Even Manually
```bash
# Check Docker logs
cd /path/to/stack
docker compose logs

# Check for port conflicts
sudo netstat -tlnp | grep <port>

# Check resource usage
docker stats

# Try starting with verbose output
docker compose up -d --verbose
```

### Notifications Not Sent for Critical Failures
```bash
# Check notification settings
grep "ENABLED" /usr/local/bin/docker-stack-backup.sh

# Test notification manually
curl -d "Test" https://ntfy.sh/your-topic

# Check logs for notification errors
grep -i "notification" /var/log/docker-backup.log
```

---

## Configuration Examples

### Conservative (Maximum Safety)
```bash
# Require lots of free space
check_disk_space "$BACKUP_DEST" 50  # 50GB minimum

# More restart attempts
MAX_RESTART_ATTEMPTS=5
RESTART_RETRY_DELAY=10  # Wait longer between attempts
```

### Aggressive (Faster Recovery)
```bash
# Less free space required
check_disk_space "$BACKUP_DEST" 2  # 2GB minimum

# Fewer attempts, faster retries
MAX_RESTART_ATTEMPTS=2
RESTART_RETRY_DELAY=2
```

### Production (Balanced)
```bash
# Default settings are good
MAX_RESTART_ATTEMPTS=3
RESTART_RETRY_DELAY=5
check_disk_space "$BACKUP_DEST" 5
```

---

## Summary

**Three layers of protection:**

1. **Pre-Flight Checks** - Verify environment before starting
2. **File Locking** - Prevent concurrent operations
3. **Retry Logic** - Recover from transient failures

**Result:** Robust, reliable backups with minimal chance of leaving systems in a broken state.
