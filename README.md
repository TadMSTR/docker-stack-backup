# Docker Stack Backup & Restore

A comprehensive backup and restore solution for Docker Compose stacks managed by Dockhand. Designed for home lab and production environments with support for automated backups, manual selective backups, and interactive restoration.

## Features

- ✅ **Automated Backups** - Schedule regular backups via cron
- 🎯 **Manual Selection** - Interactive mode to select specific stacks
- 🔄 **Smart Restore** - Interactive wizard with conflict detection
- 📱 **Notifications** - Ntfy, Pushover, and Email support
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

Edit the configuration section in each script:

```bash
# Main paths
DOCKHAND_BASE="/path/to/dockhand"
APPDATA_PATH="/mnt/datastor/appdata"
BACKUP_DEST="/mnt/backup/docker-backups"
```

### 3. Install the Scripts

```bash
# Make scripts executable
chmod +x *.sh

# Copy to system bin directory
sudo cp docker-stack-backup.sh /usr/local/bin/
sudo cp docker-stack-backup-manual.sh /usr/local/bin/
sudo cp docker-stack-restore.sh /usr/local/bin/
sudo cp backup-verify.sh /usr/local/bin/
sudo cp cleanup-old-backups.sh /usr/local/bin/
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
- **[Notification Setup](NOTIFICATIONS.md)** - Configure Ntfy, Pushover, or Email alerts
- **[GitHub Setup](GITHUB_SETUP.md)** - SSH keys and repository management

## Requirements

- Docker and Docker Compose
- Bash 4.0+
- Root access for backup operations
- Dockhand for stack management
- `curl` for notifications (optional)
- `sendmail` or SMTP access for email (optional)

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
# Remove backups older than 30 days
cleanup-old-backups.sh

# Or schedule weekly cleanup
0 3 * * 0 /usr/local/bin/cleanup-old-backups.sh
```

## Configuration

### Notification Setup

Configure notifications in `docker-stack-backup.sh`:

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
```

See [NOTIFICATIONS.md](NOTIFICATIONS.md) for detailed setup.

## Security Considerations

- Scripts require root access (needed for Docker operations)
- Store sensitive credentials in environment variables or encrypted config files
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

### Version 1.0.0 (Initial Release)
- Automated backup script with cron support
- Interactive manual backup mode
- Interactive restore wizard
- Notification support (Ntfy, Pushover, Email)
- Backup verification tools
- Automatic cleanup script
- Comprehensive documentation

---

**Author:** TadMSTR  
**Repository:** https://github.com/TadMSTR/docker-stack-backup  
**Last Updated:** 2026-02-08

