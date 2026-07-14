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

# Stack manager base path — the directory containing one subdirectory per stack.
# Despite the name, this doesn't require actually using Dockhand — it just needs to be
# "the directory with one subdirectory per compose stack."
DOCKHAND_BASE="/opt/dockhand/stacks"

# Whether stacks live under $DOCKHAND_BASE/<hostname>/ (true, default — a shared stacks
# root serving a fleet, each host nested under its own hostname) or directly under
# $DOCKHAND_BASE with no per-host subdirectory (false — a flat single-host layout, e.g.
# DOCKHAND_BASE="/home/user/docker" with compose files at /home/user/docker/<stack>/).
DOCKHAND_APPEND_HOSTNAME=true

# Appdata bind-mount root
APPDATA_PATH="/mnt/datastor/appdata"

# Backup destination (local path, NFS, SMB mount)
BACKUP_DEST="/mnt/backup/docker-backups"

# Compression: none | gzip | bzip2 | xz | zstd
COMPRESSION_METHOD="none"
COMPRESSION_LEVEL=6
USE_PARALLEL=false
PARALLEL_THREADS=0      # 0 = auto-detect cores

# Privileged archive creation (optional)
# When appdata is root-owned and the backup runs unprivileged — or writes to an NFS
# export with root_squash — route tar through a root-owned, argument-validating helper
# instead of running tar directly. Do NOT use a bare `sudo tar` grant: crafted exclude
# patterns can smuggle tar flags (e.g. --checkpoint-action=exec). See ELEVATION.md.
ELEVATION_CMD="none"              # none | sudo | doas
ELEVATION_HELPER_PATH=""          # root-owned validating helper; required if ELEVATION_CMD != none
                                  # e.g. /usr/local/sbin/docker-backup-tar-create.sh

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
NTFY_URGENT_ONLY=false  # true: ntfy fires on failure only (ignores NOTIFY_ON_SUCCESS);
                        # other channels still follow the global toggles above

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

# Post-restart hooks (optional)
# Function names (define the functions below in this file) or command names, run after
# each stack's containers restart successfully. Each is invoked as:
#   <hook> <stack_name> <stack_path>
# A failing hook logs a warning but does not fail the backup. See HOOKS.md for a worked
# example (e.g. a chown fixup for a service that resets ownership on restart).
POST_RESTART_HOOKS=()
