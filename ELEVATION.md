# Privileged Archive Creation (Elevation)

By default `docker-stack-backup` runs `tar` directly as whoever invokes the script.
That is fine when the invoking user can already read every stack's appdata and write to
the backup destination.

Two common setups need something more careful:

1. **Root-owned appdata read by an unprivileged backup user.** Appdata lives under a
   root-owned tree (e.g. `/opt/appdata`, mode `0750`) and you do not want to run the
   whole backup as root.
2. **NFS destination with `root_squash`.** If `tar` runs as root and opens the output
   file itself (`tar -cf …`), the NFS server squashes root to `nobody` and the write
   is denied. (This project's `tar` invocations always write via a stdout redirect from
   the *caller's* shell, so the output file is opened in the caller's context — see the
   note at the bottom.)

The elevation feature lets you keep the bulk of the backup running unprivileged and
elevate **only** the `tar` read of root-owned appdata, through a root-owned helper whose
arguments are validated.

## Why not just `sudo tar`?

A `NOPASSWD: /usr/bin/tar` sudoers grant is a well-known local root primitive. GNU
`tar` can run arbitrary commands as part of an otherwise-innocent create:

```
tar -c --checkpoint=1 --checkpoint-action=exec='sh -c "id > /tmp/pwned"' …
```

Because exclude patterns and paths flow from configuration/among callers into the `tar`
command line, prefixing the existing `tar` calls with `sudo` would hand that primitive
to anyone who can influence those inputs. **Do not do this.**

Instead, elevation routes through a small root-owned helper
(`docker-backup-tar-create.sh`) that:

- never accepts raw `tar` flags — it takes a fixed, positional argument list and builds
  the `tar` command itself;
- validates every argument (compression method, temp dir shape, appdata root, stack
  name, and each exclude pattern) against strict regexes and rejects anything with a
  leading `-` or unexpected characters;
- pins the appdata root to a value only root can change (`ALLOWED_APPDATA_PATH` inside
  the helper), so a caller cannot point it at `/root`, `/etc`, etc.;
- writes the archive to **stdout** (no `-f`), so the privileged process never opens the
  output file.

## Running unprivileged

`docker-stack-backup.sh` and `docker-stack-backup-manual.sh` only require root when
`ELEVATION_CMD` is `none` (the default). Set `ELEVATION_CMD`/`ELEVATION_HELPER_PATH` and
the script itself can run as an unprivileged user (e.g. via cron as a service account) —
it elevates only the one operation the helper covers: reading root-owned appdata during
archive creation.

Their `LOG_FILE` default follows the same rule: `/var/log/docker-backup*.log` when
`ELEVATION_CMD=none` (unchanged, matches a root-run install), or `${HOME}/logs/docker-
backup*.log` when elevation is configured (writable by the unprivileged user). Set
`LOG_FILE` explicitly in `config.sh` to override either default.

**This does not extend to `docker-stack-restore.sh`.** Restore writes directly into
appdata (`tar -x`, `cp -a`, `rm -rf` in `perform_restore()`) and no validated helper
exists for that direction — only archive *creation* (the read side) has one. Restore
therefore still requires root unconditionally, regardless of `ELEVATION_CMD`. Running it
unprivileged would let it start (stopping the target stack, taking a safety backup) and
then fail mid-restore with permission-denied once it reaches root-owned appdata — a worse
failure mode than rejecting upfront. A privileged-write helper for restore is a possible
future addition but does not exist today.

## Configuration

In `config.sh`:

```bash
ELEVATION_CMD="sudo"                                        # none | sudo | doas
ELEVATION_HELPER_PATH="/usr/local/sbin/docker-backup-tar-create.sh"
```

When `ELEVATION_CMD` is `none` (default), behavior is unchanged — `tar` runs directly.
When it is `sudo` or `doas`, `create_compressed_archive()` calls:

```
<ELEVATION_CMD> <ELEVATION_HELPER_PATH> <compression> <temp_dir> <appdata_path> <stack_name> [excludes…] > <output_file>
```

and fails closed (logs an error, aborts that stack's archive) if the helper path is
unset/not executable, `ELEVATION_CMD` is not `sudo`/`doas`, or the archive layout is not
the expected `-C <temp_dir> . -C <appdata_path> <stack_name>`.

## Install the helper

1. **Copy the helper to a root-owned path and lock it down.** Copy (do not symlink — a
   symlink lets a compromised unprivileged file alter root's execution path):

   ```bash
   sudo cp docker-backup-tar-create.sh /usr/local/sbin/docker-backup-tar-create.sh
   sudo chown root:root /usr/local/sbin/docker-backup-tar-create.sh
   sudo chmod 0750 /usr/local/sbin/docker-backup-tar-create.sh
   ```

2. **Set the allowed appdata root.** Edit the copy and set `ALLOWED_APPDATA_PATH` to
   match your `config.sh` `APPDATA_PATH`. This value is the trust boundary: because the
   file is root-owned, only root can widen it.

   ```bash
   sudo sed -i 's|^ALLOWED_APPDATA_PATH=.*|ALLOWED_APPDATA_PATH="/opt/appdata"|' \
       /usr/local/sbin/docker-backup-tar-create.sh
   ```

3. **Grant the backup user permission to run only this helper.**

   sudo (`/etc/sudoers.d/docker-backup`, mode `0440`, validate with `visudo -c`):

   ```
   backupuser ALL=(root) NOPASSWD: /usr/local/sbin/docker-backup-tar-create.sh
   ```

   or doas (`/etc/doas.conf`):

   ```
   permit nopass backupuser as root cmd /usr/local/sbin/docker-backup-tar-create.sh
   ```

   Scope the grant to this **exact path** — never a bare `tar` grant. Do not add the
   helper's arguments to an `env_keep` list; the helper's safety relies on
   `ALLOWED_APPDATA_PATH` coming from the root-owned file, not from the caller's
   environment.

4. **Verify the scope after install and after any change:**

   ```bash
   sudo -n -l -U backupuser        # should show only the helper path
   ```

## A note on `root_squash` and the stdout redirect

Every `tar` invocation in `lib.sh` (elevated or not) writes the archive to stdout, and
the calling script redirects that into the output file. The redirect is performed by the
backup script's own shell — not by `tar`, and not by `sudo`/`doas`. On an NFS export
with `root_squash`, that means the output file is opened as the (unprivileged) backup
user, so the write succeeds even though the appdata read was elevated. This is a plain
bug fix over `tar -cf <file>` and has no downside on local disks.
