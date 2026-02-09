# Homelab Setup & Configuration

This document provides an overview of the homelab infrastructure where the Docker Stack Backup scripts are deployed.

## Network Topology

### Public Network (192.168.1.0/24) - 1Gbit
- **Unraid:** 192.168.1.6
  - Proton Mail Bridge running on port 1025 (accessible from all hosts)
  - SMTP server for notifications
- **TrueNAS Scale (atlas):** 192.168.1.9
  - Primary storage server
  - ZFS with LZ4 compression
  - Backup destination for all hosts
- **Debian (loki):** 192.168.1.10
  - Test/development host
  - Single 250GB SSD
  - 4x 1Gbit NICs available

### Private Network (10.10.1.0/24) - 10Gbit
Direct link between storage hosts for high-speed data transfers:
- **Unraid:** 10.10.1.6
- **TrueNAS Scale (atlas):** 10.10.1.9
- **Debian (loki):** *Not currently connected (only has 1Gbit NICs)*

**Note:** The private 10Gbit network is used for fast backups and large data transfers between Unraid and TrueNAS.

## Host Details

### Unraid (192.168.1.6 / 10.10.1.6)
- **Purpose:** Primary application server
- **OS:** Unraid
- **Services:**
  - Proton Mail Bridge (port 1025, self-signed cert)
  - Various Docker containers
- **Networks:** Both public (1Gbit) and private (10Gbit)

### TrueNAS Scale "atlas" (192.168.1.9 / 10.10.1.9)
- **Purpose:** Storage server and backup destination
- **OS:** TrueNAS Scale (Debian-based)
- **Filesystem:** ZFS with LZ4 compression enabled
- **Docker Management:** Dockhand
- **Paths:**
  - Dockhand stacks: `/mnt/datastor/dockhand/atlas/`
  - Appdata: `/mnt/datastor/appdata/`
  - Backup storage: `/mnt/datastor/backups/docker-backups/`
- **Networks:** Both public (1Gbit) and private (10Gbit)
- **Note:** ZFS with LZ4 compression is already enabled, so backup scripts use no compression by default

### Debian "loki" (192.168.1.10)
- **Purpose:** Test/development host
- **OS:** Debian GNU/Linux
- **Hardware:** 
  - Single 250GB SSD (OS and local appdata)
  - 4x 1Gbit NICs (potential for private network addition)
- **Docker Management:** Dockhand
- **Paths:**
  - Dockhand stacks: `/opt/dockhand/stacks/loki/`
  - Appdata: `/mnt/datastor/appdata/` (local on SSD)
  - Backups: Will mount NFS from TrueNAS
- **Networks:** Public only (1Gbit)
- **Status:** Successfully tested backup scripts ✅

### Proxmox (Potential Future Host)
- **Status:** Under consideration
- **Would follow:** Similar Dockhand structure as other hosts

## Docker Stack Management

### Dockhand Structure
All hosts use Dockhand for Docker Compose stack management:

```
/opt/dockhand/stacks/{hostname}/     # Debian/Proxmox structure
/mnt/datastor/dockhand/{hostname}/   # TrueNAS structure
└── stack-name/
    ├── compose.yaml              # Docker Compose v2 format
    └── .env                      # Optional environment file
```

### Compose File Naming
- **Primary:** `compose.yaml` (Docker Compose v2 default)
- **Also supported:** `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`
- Scripts check for all variants automatically

### Appdata Organization
Appdata follows a **one folder per stack** pattern:

```
/mnt/datastor/appdata/
├── stack-name/              # Stack folder
│   ├── container1/          # Container-specific data
│   ├── container2/
│   └── container3/
```

**Example from loki (tested):**
```
/mnt/datastor/appdata/
├── adguard/                 # 185MB - backed up ✅
├── dashboards/              # 300KB - backed up ✅
│   ├── heimdall/
│   └── homepage/
├── monitors/                # No persistent data - skipped
└── system/                  # No persistent data - skipped
```

## Backup Strategy

### Current Setup
- **TrueNAS (atlas):** Central backup destination for all hosts
- **Filesystem:** ZFS with LZ4 compression (transparent, automatic)
- **Compression in scripts:** Disabled by default (ZFS already compresses)
- **Backup location:** `/mnt/datastor/backups/docker-backups/`

### Backup Structure
```
/mnt/datastor/backups/docker-backups/
├── atlas/                   # TrueNAS local backups
│   └── YYYYMMDD_HHMMSS/
│       ├── stack1.tar
│       └── stack2.tar
├── loki/                    # Debian backups (via NFS)
│   └── YYYYMMDD_HHMMSS/
│       ├── stack1.tar
│       └── stack2.tar
└── unraid/                  # Unraid backups (planned)
    └── YYYYMMDD_HHMMSS/
```

### NFS Configuration (Planned)

**For Debian (loki) → TrueNAS (atlas):**
```bash
# On TrueNAS: Create NFS share
Path: /mnt/datastor/backups/docker-backups
Allowed: 192.168.1.10 (or 10.10.1.x if added to private network)

# On Debian: Mount point
/mnt/truenas-backups

# In /etc/fstab:
192.168.1.9:/mnt/datastor/backups/docker-backups /mnt/truenas-backups nfs defaults,_netdev 0 0

# Or via private network (if loki added to 10.10.1.0/24):
10.10.1.9:/mnt/datastor/backups/docker-backups /mnt/truenas-backups nfs defaults,_netdev 0 0
```

## Notification Configuration

### Proton Mail Bridge (SMTP)
Available on Unraid for all hosts to use:

```bash
# SMTP Configuration
SMTP_SERVER="192.168.1.6"          # Unraid public IP
SMTP_PORT="1025"
SMTP_USER="your-email@protonmail.com"
SMTP_PASSWORD="bridge-password"    # From Proton Bridge
SMTP_USE_TLS=true
SMTP_INSECURE=true                 # Required for self-signed cert
```

**Note:** Proton Bridge uses a self-signed certificate, so `SMTP_INSECURE=true` is required.

### Other Notification Options
Scripts also support:
- **Ntfy:** Self-hosted or ntfy.sh
- **Pushover:** $5 one-time purchase

## Deployment Status

### ✅ Tested & Working
- **Debian (loki):** Backup script fully tested
  - Successfully backs up 2 stacks (adguard, dashboards)
  - Properly skips 2 stacks without appdata (monitors, system)
  - All containers restart successfully
  - Pre-flight checks working
  - File locking working
  - Return code handling working

### 📋 Planned
- **TrueNAS (atlas):** Deploy backup scripts
- **Unraid:** Deploy backup scripts (if needed)
- **NFS Setup:** Configure cross-host backups
- **Notifications:** Configure email via Proton Bridge
- **Scheduling:** Set up cron jobs for automated backups

### 🔮 Future Considerations
- Add Debian (loki) to private 10Gbit network (limited to 1Gbit)
- Proxmox host deployment
- Offsite backup strategy
- Backup encryption for offsite storage

## Script Configuration Per Host

### Debian (loki) - Current Config
```bash
DOCKHAND_BASE="/opt/dockhand/stacks"
APPDATA_PATH="/mnt/datastor/appdata"
BACKUP_DEST="/mnt/truenas-backups"  # NFS mount to TrueNAS
COMPRESSION_METHOD="none"           # Let ZFS handle compression
```

### TrueNAS (atlas) - Planned Config
```bash
DOCKHAND_BASE="/mnt/datastor/dockhand"
APPDATA_PATH="/mnt/datastor/appdata"
BACKUP_DEST="/mnt/datastor/backups/docker-backups"  # Local
COMPRESSION_METHOD="none"           # ZFS LZ4 already enabled
```

### Unraid - Planned Config
```bash
DOCKHAND_BASE="/path/to/dockhand"  # TBD
APPDATA_PATH="/mnt/user/appdata"   # Typical Unraid path
BACKUP_DEST="/mnt/user/backups"    # Or NFS to TrueNAS
COMPRESSION_METHOD="gzip"          # Unraid doesn't use ZFS
COMPRESSION_LEVEL=3                # Fast compression for network transfer
USE_PARALLEL=true                  # Multi-core compression
```

## Key Design Decisions

### Why No Compression by Default?
TrueNAS uses ZFS with LZ4 compression enabled at the filesystem level. Double compression (gzip + LZ4) provides minimal additional space savings (~5%) while being 4x slower. Let ZFS handle it efficiently.

### Why One Folder Per Stack?
- Logical grouping - all related containers together
- Easy to backup/restore entire stack
- Clear ownership and organization
- Prevents naming conflicts
- Simplifies migration

### Why Separate Dockhand and Appdata?
- Configuration (Dockhand) vs data (appdata)
- Can set different ZFS properties if needed
- Easier to understand folder structure
- Traditional separation of concerns

## Testing Notes

### Successful Test Run (loki - 2026-02-03)
```
Total stacks found: 4
Successfully backed up: 2 (adguard 185M, dashboards 190K)
Skipped (no appdata): 2 (monitors, system)
Failed: 0
Time: ~23 seconds for full backup cycle
```

**Issues discovered and fixed during testing:**
1. ✅ Compose file naming - Added support for `compose.yaml`
2. ✅ Color variables missing - Added BLUE, CYAN, BOLD
3. ✅ Dockhand path structure - Updated to `/opt/dockhand/stacks/{hostname}`
4. ✅ Arithmetic operations - Changed `((var++))` to `var=$((var + 1))`
5. ✅ Counting bug - Fixed skip vs backup counting
6. ✅ Return code handling - Properly handle return code 2 for skipped stacks

## Security Considerations

### Network Isolation
- Private 10Gbit network for bulk data transfers
- Public network for management and notifications
- No external exposure

### SMTP Security
- Proton Mail Bridge requires authentication
- Self-signed cert (trusted within homelab)
- Traffic stays on local network

### Backup Security
- Backups stored on trusted ZFS filesystem
- No encryption (data stays in homelab)
- Consider encryption for future offsite backups

## Performance Characteristics

### Backup Speed (Observed on loki)
- 185MB backup: ~1 second (tar creation)
- Container stop: ~1-8 seconds depending on container
- Container start: ~4-5 seconds
- Total for 2 stacks: ~23 seconds

### Expected Performance on 10Gbit
- NFS over 10Gbit: Near-local performance
- Large backups (100GB+): Minutes vs hours
- ZFS dedup/compression: Real-time, no overhead

### Network Bandwidth
- 1Gbit (loki): ~125MB/s theoretical max
- 10Gbit (Unraid/TrueNAS): ~1.25GB/s theoretical max
- Actual: ~70-80% of theoretical (protocol overhead)

## Future Enhancements

### Under Consideration
- [ ] Add loki to private 10Gbit network
- [ ] Proxmox host integration
- [ ] Offsite backup automation
- [ ] Backup encryption for offsite
- [ ] Prometheus metrics export
- [ ] Grafana dashboard for backup monitoring
- [ ] Automated restore testing
- [ ] Backup verification checksums

### GitHub Repository
- **Name:** docker-stack-backup
- **Owner:** TadMSTR
- **URL:** https://github.com/TadMSTR/docker-stack-backup
- **Status:** Active - Debian host tested successfully ✅
- **Visibility:** Public

## Contact & Documentation

All scripts and documentation are in the project repository:
- README.md - Overview and quick start
- USAGE.md - Detailed usage and configuration
- NOTIFICATIONS.md - Notification setup (Ntfy, Pushover, Proton Bridge)
- COMPRESSION.md - Compression options and guidance
- SAFETY_FEATURES.md - Pre-flight checks, locking, error handling
- OS_COMPATIBILITY.md - Supported operating systems
- DRY_RUN.md - Dry-run mode usage
- GITHUB_SETUP.md - Repository setup instructions

---

**Last Updated:** 2026-02-03
**Status:** Active Development - Debian host tested successfully ✅
