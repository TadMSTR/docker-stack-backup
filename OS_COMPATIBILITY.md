# OS Compatibility Guide

The Docker Stack Backup scripts support multiple Linux distributions and automatically detect the running OS.

## Supported Operating Systems

### ✅ Fully Tested
- **Debian 11+** (Bullseye and newer)
- **Ubuntu 20.04+** (Focal and newer)
- **TrueNAS Scale** (Based on Debian)
- **Proxmox VE** (Based on Debian)

### ✅ Should Work
- **Other Debian-based distributions**
- **Linux Mint**
- **Pop!_OS**
- Any distribution with:
  - Docker and Docker Compose
  - Bash 4.0+
  - Standard GNU utilities (tar, find, etc.)

## OS Detection

The scripts automatically detect the operating system on startup using `/etc/os-release`.

### Detection Logic

```bash
# Priority order:
1. Check /etc/os-release ID field
2. Check for TrueNAS-specific files (/etc/version)
3. Fall back to /etc/debian_version for Debian-based systems
4. Default to "unknown"
```

### OS Types Recognized

| Distribution | Detected As | OS_TYPE |
|--------------|-------------|---------|
| Debian | Debian GNU/Linux | `debian` |
| Ubuntu | Ubuntu | `ubuntu` |
| TrueNAS Scale | TrueNAS | `truenas` |
| Proxmox VE | Proxmox VE | `proxmox` |
| Other Debian-based | (varies) | `debian` (fallback) |

### Viewing OS Detection

When scripts run, they log the detected OS:

```
=========================================
Starting Docker stack backup
Hostname: debian-docker
OS: Debian GNU/Linux (debian)
=========================================
```

## OS-Specific Considerations

### Debian
- **Package manager:** `apt-get`
- **Python:** May need `python3-pip`
- **Default shell:** bash

**Installation:**
```bash
# Install dependencies
apt-get update
apt-get install docker.io docker-compose curl

# Optional: Parallel compression tools
apt-get install pigz pbzip2 pxz zstd

# Optional: Email support
apt-get install sendmail
```

### Ubuntu
- **Package manager:** `apt` or `apt-get`
- **Python:** Usually pre-installed
- **Snap-based Docker:** May need adjustment if using Snap Docker

**Installation:**
```bash
# Install dependencies
apt update
apt install docker.io docker-compose curl

# Optional: Parallel compression tools
apt install pigz pbzip2 pxz zstd

# Optional: Email support
apt install sendmail
```

**Note:** If using Snap-based Docker:
```bash
# Snap Docker may have different paths
snap install docker
```

### TrueNAS Scale
- **Package manager:** `apt-get` (read-only system)
- **Docker:** Built-in, but limited CLI access
- **Python:** Built-in

**Considerations:**
- System partition is read-only
- Scripts should be installed on data pool: `/mnt/pool/scripts/`
- Logs should go to data pool
- Built-in Docker management via web UI
- Direct Docker CLI access available

**Installation:**
```bash
# Scripts location
mkdir -p /mnt/datastor/scripts
cp *.sh /mnt/datastor/scripts/
chmod +x /mnt/datastor/scripts/*.sh

# Logs location
mkdir -p /mnt/datastor/logs
# Update LOG_FILE paths in scripts to /mnt/datastor/logs/
```

**Cron on TrueNAS:**
```bash
# Use TrueNAS web UI: System Settings → Advanced → Cron Jobs
# Or edit directly (persists across reboots)
# Command: /mnt/datastor/scripts/docker-stack-backup.sh
```

### Proxmox VE
- **Package manager:** `apt-get`
- **Docker:** Not installed by default
- **LXC containers:** Alternative to Docker (not covered by these scripts)

**Installation:**
```bash
# Install Docker on Proxmox host
apt update
apt install docker.io docker-compose curl

# Optional tools
apt install pigz pbzip2 pxz zstd
```

**Considerations:**
- Proxmox uses LXC containers by default (different from Docker)
- These scripts only work with Docker containers
- Can run scripts in Proxmox host or in a VM/LXC container

## Package Dependencies

### Required
- `bash` (4.0+)
- `docker` (Docker Engine)
- `docker-compose` or `docker compose` (v2)
- `tar`
- `find`
- `grep`
- `sed`

### Optional (for compression)
- `gzip` (usually pre-installed)
- `pigz` (parallel gzip)
- `bzip2` (usually pre-installed)
- `pbzip2` (parallel bzip2)
- `xz-utils` (for xz compression)
- `pxz` (parallel xz)
- `zstd` (modern compression)

### Optional (for notifications)
- `curl` (for Ntfy and Pushover)
- `sendmail` or SMTP access (for email)

### Installation by OS

**Debian/Ubuntu:**
```bash
apt-get install curl pigz pbzip2 pxz zstd sendmail
```

**TrueNAS Scale:**
```bash
# Most tools pre-installed
# Additional tools:
apt-get install pigz pbzip2 pxz zstd
```

**Proxmox:**
```bash
apt-get install curl pigz pbzip2 pxz zstd sendmail
```

## Compatibility Notes

### Docker Compose Version
Scripts support both:
- `docker-compose` (v1, standalone)
- `docker compose` (v2, plugin)

Auto-detection is handled by Docker itself.

### Filesystem Compatibility
Scripts work with any Linux filesystem:
- **ext4** - Standard choice
- **ZFS** - TrueNAS, optimized for compression
- **btrfs** - Alternative with snapshots
- **XFS** - High-performance

### Network Filesystems
Backup destinations can be:
- **Local:** `/mnt/local/path`
- **NFS:** `/mnt/nfs-mount`
- **SMB/CIFS:** `/mnt/smb-mount`
- **Any mounted filesystem**

## Testing OS Detection

Check what your system detects as:

```bash
# View OS info
cat /etc/os-release

# Test detection (if script is available)
bash -c 'source docker-stack-backup.sh; detect_os; echo "Detected: $OS_TYPE ($OS_NAME)"'
```

## Troubleshooting

### "Unknown OS" Detected

If scripts detect `OS_TYPE=unknown`:

1. Check `/etc/os-release` exists:
```bash
ls -la /etc/os-release
cat /etc/os-release
```

2. Scripts will still work, but OS-specific optimizations disabled

3. Manually set if needed (not recommended):
```bash
export OS_TYPE="debian"
export OS_NAME="Debian GNU/Linux"
```

### Docker Not Found

```bash
# Check Docker installation
docker --version
docker compose version

# Debian/Ubuntu: Install Docker
apt-get install docker.io docker-compose

# Check Docker service
systemctl status docker
systemctl start docker
```

### Permission Issues

```bash
# Scripts must run as root
sudo ./docker-stack-backup.sh

# Or switch to root
sudo -i
./docker-stack-backup.sh
```

### TrueNAS Specific Issues

**Scripts don't persist after reboot:**
- Don't install in `/usr/local/bin` (system partition)
- Use data pool location: `/mnt/datastor/scripts/`

**Cron jobs don't work:**
- Use TrueNAS web UI for cron configuration
- System Settings → Advanced → Cron Jobs

**Docker commands fail:**
- Ensure using TrueNAS Docker, not manually installed
- Check Apps service is running

### Proxmox Specific Issues

**No Docker:**
- Proxmox doesn't include Docker by default
- Install manually or use VM/container

**LXC vs Docker:**
- These scripts only work with Docker
- For LXC containers, use Proxmox backup tools

## Distribution-Specific Paths

### Default Paths by OS

**Debian/Ubuntu:**
```bash
DOCKHAND_BASE="/opt/dockhand"
APPDATA_PATH="/opt/docker-appdata"
BACKUP_DEST="/var/backups/docker"
```

**TrueNAS Scale:**
```bash
DOCKHAND_BASE="/mnt/datastor/dockhand"
APPDATA_PATH="/mnt/datastor/appdata"
BACKUP_DEST="/mnt/datastor/backups/docker-backups"
```

**Proxmox:**
```bash
DOCKHAND_BASE="/opt/dockhand"
APPDATA_PATH="/opt/docker-appdata"
BACKUP_DEST="/var/backups/docker"
```

Adjust these paths based on your setup.

## Future OS Support

To add support for additional distributions:

1. Identify the OS ID in `/etc/os-release`
2. Add case in `detect_os()` function
3. Test all scripts
4. Document any OS-specific requirements

## Getting Help

If you encounter issues on a specific OS:

1. Check the OS is detected correctly
2. Verify all dependencies installed
3. Check Docker and Docker Compose work
4. Review logs for OS-specific errors
5. Open an issue on GitHub with:
   - OS name and version
   - Output of `cat /etc/os-release`
   - Error messages from logs

---

**Summary:** Scripts automatically detect and adapt to Debian, Ubuntu, TrueNAS Scale, and Proxmox VE. Most Debian-based distributions should work out of the box.
