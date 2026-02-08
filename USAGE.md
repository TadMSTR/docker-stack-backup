# Usage Guide

Detailed instructions for configuring and using the Docker Stack Backup & Restore toolkit.

## Table of Contents

1. [Initial Setup](#initial-setup)
2. [Configuration](#configuration)
3. [Running Backups](#running-backups)
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

# Install to system
sudo cp *.sh /usr/local/bin/

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

**docker-stack-restore.sh:**
```bash
BACKUP_BASE="/mnt/backup/docker-backups"
DOCKHAND_BASE="/path/to/dockhand"
APPDATA_PATH="/mnt/datastor/appdata"
```

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

---

## Restoring from Backup

### Interactive Restore

```bash
# Run the restore wizard
sudo docker-stack-restore.sh
```

**Wizard flow:**

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
```
Creating safety backup in /tmp/docker-restore-backup-...
Stopping existing stack
Restoring files...
✓ Files restored successfully

Start the stack now? [y/N]: y
✓ Stack started successfully
```

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
