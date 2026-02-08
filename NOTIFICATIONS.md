# Notification Setup Guide

The backup script supports three notification methods: Ntfy, Pushover, and Email. You can enable one, multiple, or all of them.

## Quick Setup

Edit the notification section in `docker-stack-backup.sh`:

```bash
# Notification Configuration
NOTIFY_ON_SUCCESS=true   # Send notification when backup succeeds
NOTIFY_ON_FAILURE=true   # Send notification when backup fails
```

Then configure the service(s) you want to use:

---

## Ntfy Setup

[Ntfy](https://ntfy.sh) is a simple pub-sub notification service. You can use the free hosted service or self-host.

### Using ntfy.sh (hosted, free)

```bash
NTFY_ENABLED=true
NTFY_URL="https://ntfy.sh"
NTFY_TOPIC="my-docker-backups-xyz123"  # Choose a unique topic name
NTFY_PRIORITY="default"  # min, low, default, high, urgent
NTFY_TOKEN=""  # Leave empty for public topics
```

**Important:** Choose a unique topic name (like `docker-backups-myserver-xyz123`) since ntfy.sh topics are public by default. Anyone who knows your topic name can subscribe to it.

### Using your own Ntfy server (recommended for privacy)

```bash
NTFY_ENABLED=true
NTFY_URL="https://ntfy.yourdomain.com"
NTFY_TOPIC="docker-backups"
NTFY_PRIORITY="default"
NTFY_TOKEN="tk_yourtokenhere"  # Optional: for authenticated topics
```

To self-host Ntfy:
```bash
# Docker Compose example
services:
  ntfy:
    image: binwiederhier/ntfy
    command: serve
    ports:
      - "80:80"
    volumes:
      - /var/cache/ntfy:/var/cache/ntfy
```

### Subscribe to notifications

**On your phone:**
1. Install the Ntfy app (iOS/Android)
2. Subscribe to your topic
3. Done!

**On your desktop:**
```bash
# Using the web interface
https://ntfy.sh/my-docker-backups-xyz123

# Or command line
ntfy subscribe my-docker-backups-xyz123
```

---

## Pushover Setup

[Pushover](https://pushover.net) is a paid notification service ($5 one-time per platform).

### Steps

1. **Sign up at https://pushover.net**
   - Install the Pushover app on your device

2. **Get your User Key:**
   - Login to pushover.net
   - Your User Key is shown on the main page

3. **Create an Application:**
   - Click "Create an Application/API Token"
   - Name it "Docker Backup"
   - Copy the API Token

4. **Configure the script:**
```bash
PUSHOVER_ENABLED=true
PUSHOVER_USER_KEY="uxxxxxxxxxxxxxxxxxxxxxxxx"  # Your User Key
PUSHOVER_API_TOKEN="axxxxxxxxxxxxxxxxxxxxxxxx"  # Your API Token
PUSHOVER_PRIORITY=0  # -2=lowest, -1=low, 0=normal, 1=high, 2=emergency
```

**Priority levels:**
- `-2` (lowest): No notification/alert
- `-1` (low): No sound or vibration
- `0` (normal): Default sound and vibration
- `1` (high): Bypasses quiet hours
- `2` (emergency): Requires acknowledgment

---

## Email Setup

Two methods available: sendmail (simple) or SMTP (more reliable).

### Method 1: Using sendmail (simplest)

**Install sendmail:**
```bash
# Debian/Ubuntu
apt-get install sendmail

# Configure
sendmailconfig  # Follow prompts
```

**Configure script:**
```bash
EMAIL_ENABLED=true
EMAIL_TO="you@example.com"
EMAIL_FROM="docker-backup@$HOSTNAME"
EMAIL_SUBJECT_PREFIX="[Docker Backup]"
EMAIL_METHOD="sendmail"
```

### Method 2: Using SMTP (recommended)

More reliable, works with Gmail, Office 365, etc.

**For Gmail:**
1. Enable 2FA on your Google account
2. Generate an App Password: https://myaccount.google.com/apppasswords
3. Use these settings:

```bash
EMAIL_ENABLED=true
EMAIL_TO="you@gmail.com"
EMAIL_FROM="docker-backup@$HOSTNAME"
EMAIL_SUBJECT_PREFIX="[Docker Backup]"
EMAIL_METHOD="smtp"

SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="your-email@gmail.com"
SMTP_PASSWORD="your-app-password-here"  # 16-char app password
SMTP_USE_TLS=true
```

**For Office 365:**
```bash
SMTP_SERVER="smtp.office365.com"
SMTP_PORT="587"
SMTP_USER="your-email@outlook.com"
SMTP_PASSWORD="your-password"
SMTP_USE_TLS=true
```

**For Proton Mail Bridge (recommended for privacy):**

Proton Mail Bridge runs locally (often in a container) and provides an SMTP interface to your Proton account with end-to-end encryption.

```bash
EMAIL_ENABLED=true
EMAIL_TO="you@protonmail.com"
EMAIL_FROM="docker-backup@$HOSTNAME"
EMAIL_SUBJECT_PREFIX="[Docker Backup]"
EMAIL_METHOD="smtp"

SMTP_SERVER="127.0.0.1"  # or your container IP/hostname
SMTP_PORT="1025"  # Proton Bridge default SMTP port
SMTP_USER="your-email@protonmail.com"
SMTP_PASSWORD="your-bridge-password"  # From Proton Bridge, not your Proton password
SMTP_USE_TLS=true
SMTP_INSECURE=true  # Required for self-signed certificate
```

**Notes for Proton Mail Bridge:**
- The Bridge generates its own password - get it from the Bridge interface
- Uses a self-signed certificate, so `SMTP_INSECURE=true` is required
- If Bridge is in a container, use the container name or IP for `SMTP_SERVER`
- Port 1025 is SMTP, port 1143 is IMAP (we only need SMTP)

**If your Bridge container is on the same Docker network:**
```bash
SMTP_SERVER="protonmail-bridge"  # Your container name
```

**For generic SMTP:**
```bash
SMTP_SERVER="mail.yourdomain.com"
SMTP_PORT="587"  # or 465 for SSL, 25 for unencrypted
SMTP_USER="username"
SMTP_PASSWORD="password"
SMTP_USE_TLS=true  # false for port 25
```

---

## Testing Notifications

After configuring, test each service:

### Test Ntfy
```bash
curl -H "Title: Test" -d "This is a test notification" https://ntfy.sh/your-topic
```

### Test Pushover
```bash
curl -s \
  --form-string "token=YOUR_API_TOKEN" \
  --form-string "user=YOUR_USER_KEY" \
  --form-string "message=Test notification" \
  https://api.pushover.net/1/messages.json
```

### Test Email (sendmail)
```bash
echo -e "Subject: Test\n\nThis is a test" | sendmail you@example.com
```

### Test Email (SMTP with curl)
```bash
# Create test email
cat > /tmp/test-email.txt << 'EOF'
From: docker-backup@hostname
To: you@example.com
Subject: Test Email

This is a test email.
EOF

# Send it (Gmail example)
curl --url "smtp://smtp.gmail.com:587" \
  --mail-from "docker-backup@hostname" \
  --mail-rcpt "you@example.com" \
  --user "your-email@gmail.com:your-app-password" \
  --upload-file /tmp/test-email.txt

# Send it (Proton Mail Bridge example)
curl --url "smtp://127.0.0.1:1025" \
  --mail-from "docker-backup@hostname" \
  --mail-rcpt "you@protonmail.com" \
  --user "you@protonmail.com:bridge-password" \
  --insecure \
  --upload-file /tmp/test-email.txt
```

---

## Notification Content

Notifications include:
- ✓ Number of stacks successfully backed up
- ⊘ Number skipped (no appdata)
- ✗ Number failed
- Hostname
- Timestamp
- Log file location (on failure)

**Success example:**
```
Docker Backup Complete - debian-docker

✓ Successfully backed up: 5
⊘ Skipped (no appdata): 2
✗ Failed: 0
━━━━━━━━━━━━━━━━━━━━
Total stacks: 7
Host: debian-docker
Time: 2024-12-03 02:00:15
```

**Failure example:**
```
Docker Backup FAILED - debian-docker

✓ Successfully backed up: 4
⊘ Skipped (no appdata): 2
✗ FAILED: 1
━━━━━━━━━━━━━━━━━━━━
Total stacks: 7
Host: debian-docker
Time: 2024-12-03 02:00:15

Check logs: /var/log/docker-backup.log
```

---

## Troubleshooting

### Ntfy not working
- Check your topic name has no spaces
- Verify NTFY_URL is reachable: `curl https://ntfy.sh`
- For self-hosted, ensure your server is accessible
- Check firewall rules if using custom server

### Pushover not working
- Verify User Key and API Token are correct
- Check pushover.net service status
- Ensure curl is installed: `which curl`
- Test with the curl command above

### Email not working (sendmail)
- Check sendmail is installed: `which sendmail`
- Test sendmail directly: `echo "test" | sendmail you@example.com`
- Check mail logs: `tail -f /var/log/mail.log`
- Verify hostname resolution: `hostname -f`

### Email not working (SMTP)
- Verify credentials are correct
- For Gmail, ensure you're using an App Password, not your main password
- For Proton Bridge, use the Bridge-generated password, not your Proton account password
- For Proton Bridge, ensure `SMTP_INSECURE=true` is set (required for self-signed cert)
- Check SMTP server and port are correct
- Test connection: `telnet smtp.gmail.com 587` or `telnet 127.0.0.1 1025` (for Bridge)
- For containerized Proton Bridge, verify the container is running and accessible
- Ensure curl is installed: `which curl`

### No notifications sent
- Check `NOTIFY_ON_SUCCESS` and `NOTIFY_ON_FAILURE` are set to `true`
- Verify at least one notification service is enabled
- Check the log file for notification errors: `grep -i "notification" /var/log/docker-backup.log`

---

## Recommendations

**For home use:**
- Ntfy (self-hosted) - Free, private, easy to set up
- Or Pushover - Reliable, one-time $5 payment

**For production:**
- Email (SMTP) - Professional, creates audit trail
- Plus Pushover or Ntfy for instant alerts

**Best practice:**
- Enable notifications for failures only (`NOTIFY_ON_SUCCESS=false`)
- Use high priority for failures so you're woken up if needed
- Test notifications before relying on them
