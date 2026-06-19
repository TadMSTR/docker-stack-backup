#!/bin/bash
# shellcheck disable=SC2034  # all vars used by sourcing scripts

#######################################
# docker-stack-backup — example configuration
#
# Copy this file to config.sh and edit to suit your environment.
# config.sh is git-ignored — credentials stay off disk.
#
#   cp config.example.sh config.sh
#   $EDITOR config.sh
#######################################

# Stack manager base path (hostname appended automatically)
DOCKHAND_BASE="/opt/dockhand/stacks"

# Appdata bind-mount root
APPDATA_PATH="/mnt/datastor/appdata"

# Backup destination (local path, NFS, SMB mount)
BACKUP_DEST="/mnt/backup/docker-backups"

# Compression: none | gzip | bzip2 | xz | zstd
COMPRESSION_METHOD="none"
COMPRESSION_LEVEL=6
USE_PARALLEL=false
PARALLEL_THREADS=0      # 0 = auto-detect cores

# Retention (cleanup-old-backups.sh)
RETENTION_DAYS=30
SEARCH_DEPTH=2

# Notification toggles
NOTIFY_ON_SUCCESS=true
NOTIFY_ON_FAILURE=true

# Ntfy (https://ntfy.sh)
NTFY_ENABLED=false
NTFY_URL="https://ntfy.sh"
NTFY_TOPIC="docker-backups"
NTFY_PRIORITY="default"
NTFY_TOKEN=""           # Leave empty for public topics

# Pushover (https://pushover.net)
PUSHOVER_ENABLED=false
PUSHOVER_USER_KEY=""
PUSHOVER_API_TOKEN=""
PUSHOVER_PRIORITY=0     # -2=lowest … 2=emergency

# Email
EMAIL_ENABLED=false
EMAIL_TO=""
EMAIL_FROM="docker-backup@$(hostname)"
EMAIL_SUBJECT_PREFIX="[Docker Backup]"
EMAIL_METHOD="sendmail"    # sendmail | smtp
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASSWORD=""
SMTP_USE_TLS=true
SMTP_INSECURE=false        # true for self-signed certs (e.g. Proton Mail Bridge)

# Matrix
# Prerequisites: a Matrix account + access token
# Get token: Element → Settings → Help & About → scroll to Access Token
# Room ID format: !roomid:server.com (from Room Settings → Advanced)
MATRIX_ENABLED=false
MATRIX_HOMESERVER="https://matrix.example.com"
MATRIX_ACCESS_TOKEN=""
MATRIX_ROOM_ID="!roomid:example.com"
