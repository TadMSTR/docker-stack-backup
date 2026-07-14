# Docker Stack Backup & Restore

[![CI](https://github.com/TadMSTR/docker-stack-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/TadMSTR/docker-stack-backup/actions/workflows/ci.yml)

A comprehensive backup and restore solution for Docker Compose stacks managed by Dockhand. Designed for home lab and production environments with support for automated backups, manual selective backups, and interactive restoration.

## Features

- ✅ **Automated Backups** - Schedule regular backups via cron
- 🎯 **Manual Selection** - Interactive mode to select specific stacks
- 🔄 **Smart Restore** - Interactive wizard with conflict detection
- 📱 **Notifications** - Ntfy, Pushover, Email, and Matrix support
- 🛡️ **Safe Operations** - Preserves container run states
- 📊 **Detailed Logging** - Comprehensive audit trail
- 🔍 **Backup Verification** - Tools to verify backup integrity
- 🧹 **Automatic Cleanup** - Configurable retention policies

## Overview

This toolkit provides three main scripts:

1. **docker-stack-backup.sh** - Automated backup of all stacks with appdata
2. **docker-stack-backup-manual.sh** - Interactive selection of stacks to backup
3. **docker-stack-restore.sh** - Interactive restoration wizard

Plus utility scripts for verification and cleanup.

## Quick Start

### 1. Clone the Repository

```bash
git clone git@github.com:TadMSTR/docker-stack-backup.git
cd docker-stack-backup
```

### 2. Configure the Scripts

Copy `config.example.sh` to `config.sh` and edit it:

```bash
cp config.example.sh config.sh
$EDITOR config.sh
```

`config.sh` is git-ignored — your credentials and local paths stay off the repo. At minimum configure the main paths:

```bash
DOCKHAND_BASE="/path/to/dockhand"
APPDATA_PATH="/mnt/datastor/appdata"
BACKUP_DEST="/mnt/backup/docker-backups"
```

`DOCKHAND_BASE` defaults to `$DOCKHAND_BASE/<hostname>` layout (a shared stacks root
serving a fleet). For a flat single-host setup — stacks directly under one directory,
e.g. `DOCKHAND_BASE="/home/user/docker"` with compose files at
`/home/user/docker/<stack>/` — set `DOCKHAND_APPEND_HOSTNAME=false`.

### 3. Install the Scripts

```bash
# Make scripts executable
chmod +x *.sh

# Copy to system bin directory. lib.sh is sourced by every script and
# MUST be installed alongside them, or the scripts will fail to start.
sudo cp docker-stack-backup.sh docker-stack-backup-manual.sh docker-stack-restore.sh \
        backup-verify.sh cleanup-old-backups.sh lib.sh /usr/local/bin/

# If you created a config.sh in step 2, copy it to the same directory:
sudo cp config.sh /usr/local/bin/ && sudo chmod 600 /usr/local/bin/config.sh
```

### 4. Test Run

```bash
# Test automated backup (as root)
sudo docker-stack-backup.sh

# Or try manual mode
sudo docker-stack-backup-manual.sh
```

## Documentation

- **[Installation & Usage Guide](USAGE.md)** - Detailed setup and usage instructions
- **[Notification Setup](NOTIFICATIONS.md)** - Configure Ntfy, Pushover, Email, or Matrix alerts
- **[Privileged Archive Creation](ELEVATION.md)** - Back up root-owned appdata unprivileged, or write to an NFS `root_squash` export, via a validated elevation helper
- **[Post-Restart Hooks](HOOKS.md)** - Run custom fixups after each stack's containers restart

## Requirements

- Docker and Docker Compose
- Bash 4.0+
- Root access for backup operations
- Dockhand for stack management
- `curl` for notifications (optional)
- `sendmail` or SMTP access for email (optional)
- `python3` for safe notification encoding — Matrix JSON bodies and room IDs, Pushover form data (optional; reduced-safety shell fallbacks used if absent)
- `bats` for running tests: `apt install bats` (optional)

## Architecture

### Backup Structure

```
/mnt/backup/docker-backups/
├── hostname1/
│   ├── 20241203_020000/
│   │   ├── stack1.tar.gz
│   │   ├── stack2.tar.gz
│   │   └── stack3.tar.gz
│   └── 20241204_020000/
│       └── ...
└── hostname2/
    └── ...
```

Each backup tarball contains:
- `docker-compose.yml`
- `.env` file (if exists)
- Complete appdata directory

### How It Works

1. **Discovery** - Scans Dockhand stacks for those with appdata bind mounts
2. **State Capture** - Records which containers are running
3. **Graceful Stop** - Stops running containers in the stack
4. **Backup** - Creates tar.gz of compose files + appdata
5. **Restore State** - Restarts only previously running containers
6. **Notification** - Sends status to configured services

## Usage Examples

### Automated Daily Backups

Add to root's crontab:

```bash
# Daily backup at 2 AM
0 2 * * * /usr/local/bin/docker-stack-backup.sh
```

### Manual Backup Before Changes

```bash
# Run interactive selection
sudo docker-stack-backup-manual.sh

# Select stacks: 1 3 5-7
# Review summary
# Confirm backup
```

### Restore a Stack

```bash
# Run interactive restore wizard
sudo docker-stack-restore.sh

# Follow prompts:
# 1. Select host
# 2. Select backup date
# 3. Select stack
# 4. Preview contents
# 5. Handle conflicts
# 6. Restore
```

### Verify Backups

```bash
# List all backups
backup-verify.sh --list

# Verify integrity
backup-verify.sh --verify

# Show statistics
backup-verify.sh --stats
```

### Clean Old Backups

```bash
# Remove backups older than 30 days (default)
cleanup-old-backups.sh

# Pass BACKUP_BASE as a CLI argument
cleanup-old-backups.sh /mnt/nas/backups/docker

# Override via env vars
BACKUP_BASE=/mnt/nas/backups/docker RETENTION_DAYS=60 cleanup-old-backups.sh

# Depth-1 layout (BACKUP_BASE/YYYY-MM-DD/ instead of BACKUP_BASE/stack/YYYY-MM-DD/)
SEARCH_DEPTH=1 cleanup-old-backups.sh

# Schedule weekly cleanup via cron
0 3 * * 0 BACKUP_BASE=/mnt/nas/backups/docker /usr/local/bin/cleanup-old-backups.sh
```

## Configuration

### Notification Setup

Configure notifications in `config.sh` (copy from `config.example.sh`):

```bash
# Enable/disable notifications
NOTIFY_ON_SUCCESS=true
NOTIFY_ON_FAILURE=true

# Ntfy
NTFY_ENABLED=true
NTFY_TOPIC="my-docker-backups"

# Pushover
PUSHOVER_ENABLED=false
PUSHOVER_USER_KEY="your-key"

# Email (Proton Mail Bridge example)
EMAIL_ENABLED=true
EMAIL_TO="you@protonmail.com"
SMTP_SERVER="127.0.0.1"
SMTP_PORT="1025"
SMTP_INSECURE=true

# Matrix
MATRIX_ENABLED=false
MATRIX_HOMESERVER="https://matrix.example.com"
MATRIX_ACCESS_TOKEN="syt_yourtoken"
MATRIX_ROOM_ID="!roomid:matrix.example.com"
```

To make one channel quieter than the rest (e.g. Matrix for everything, ntfy for failures
only), set `NTFY_URGENT_ONLY=true` — see [NOTIFICATIONS.md](NOTIFICATIONS.md) for details.

See [NOTIFICATIONS.md](NOTIFICATIONS.md) for detailed setup.

### Elevation and Hooks

- **Root-owned appdata / NFS `root_squash`:** to run the backup unprivileged and elevate
  only the archive read (via a validated helper rather than a raw `sudo tar`), set
  `ELEVATION_CMD` and `ELEVATION_HELPER_PATH`. See [ELEVATION.md](ELEVATION.md).
- **Post-restart fixups:** register functions/commands in `POST_RESTART_HOOKS` to run
  after each stack's containers restart. See [HOOKS.md](HOOKS.md).

## Production / Cron Deployment

For cron or unattended root execution, deploy to a **root-owned directory** so that a user-context compromise cannot inject code into `lib.sh` or `config.sh` before they are sourced as root:

```bash
sudo cp -r . /opt/docker-stack-backup
sudo chown -R root:root /opt/docker-stack-backup
sudo chmod 750 /opt/docker-stack-backup
# Place your config.sh there (root-readable only)
sudo cp config.sh /opt/docker-stack-backup/config.sh
sudo chmod 600 /opt/docker-stack-backup/config.sh
```

Then reference the installed path in your crontab:

```bash
0 2 * * * /opt/docker-stack-backup/docker-stack-backup.sh
```

Running the scripts directly from a user-owned checkout (`~/repos/...`) as root will display a warning to stderr. This is safe for interactive use and testing; it is not recommended for production.

## Security Considerations

- Scripts require root access (needed for Docker operations)
- Store sensitive credentials in `config.sh` (git-ignored, see `config.example.sh`)
- For production/cron use, deploy to a root-owned directory (see above)
- Use SSH keys for GitHub access (not HTTPS tokens in scripts)
- Consider encrypting backups if storing off-site
- Review backup contents before restoring
- Use private topics/channels for notifications
- For Proton Mail Bridge, credentials stay local (end-to-end encryption maintained)

## Troubleshooting

### Backups Not Created

```bash
# Check logs
tail -100 /var/log/docker-backup.log

# Verify paths
ls -la /mnt/datastor/appdata
ls -la /path/to/dockhand/$(hostname)

# Test permissions
touch /mnt/backup/docker-backups/test && rm /mnt/backup/docker-backups/test
```

### Containers Don't Restart

```bash
# Check stack status
cd /path/to/dockhand/$(hostname)/stack-name
docker compose ps

# View logs
docker compose logs

# Manual restart
docker compose up -d
```

### Notifications Not Sent

```bash
# Check configuration
grep -i "ENABLED" /usr/local/bin/docker-stack-backup.sh

# Test services manually
# Ntfy
curl -d "Test" https://ntfy.sh/your-topic

# Pushover
curl -s --form-string "token=TOKEN" --form-string "user=USER" \
  --form-string "message=Test" https://api.pushover.net/1/messages.json

# Email
echo "Test" | sendmail you@example.com
```

## Testing

```bash
apt install bats
bats tests/cleanup-old-backups.bats
```

## Contributing

This is a personal project, but suggestions and improvements are welcome! Feel free to:

1. Open an issue for bugs or feature requests
2. Fork the repository for your own modifications
3. Submit pull requests for improvements

## License

MIT License - See [LICENSE](LICENSE) file for details

## Acknowledgments

- Built for Docker Compose stacks managed by [Dockhand](https://github.com/dockhand/dockhand)
- Notification support via [Ntfy](https://ntfy.sh) and [Pushover](https://pushover.net)
- Inspired by the need for reliable home lab backups

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

**Author:** TadMSTR  
**Repository:** https://github.com/TadMSTR/docker-stack-backup  
**Last Updated:** 2026-07-14

