# Security Policy

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

To report a vulnerability, use one of these channels:

- **GitHub private disclosure:** Use the [Security tab](https://github.com/TadMSTR/docker-stack-backup/security/advisories/new) to submit a private advisory.
- **Email:** Send a description to `security.i9v75@8alias.com` with the subject line `[docker-stack-backup] Security Report`.

Include as much detail as possible: the affected component, steps to reproduce, and potential impact.

## Scope

**In scope:**

- Path traversal in backup source or destination path arguments
- Sensitive data exposure in backup archives (secrets, tokens, environment files)
- Command injection via stack name or backup path inputs
- Privilege escalation or argument injection via the elevation helper
  (`docker-backup-tar-create.sh`) — e.g. smuggling `tar` flags through exclude patterns,
  or reading appdata roots outside the configured allowlist
- The same via the snapshot helper (`docker-backup-snapshot.sh`): steering a snapshot
  create, delete, destroy or sweep at anything other than the `dsb-<stack>-<ts>`
  snapshots of the configured appdata root
- An `x-backup` declaration that leaves out more than the declared path, or that is
  applied although it is invalid
- Dependency vulnerabilities with a plausible exploitation path in docker-stack-backup's usage

**Out of scope:**

- Vulnerabilities in the host system, underlying services, or MCP transport layer
- Issues that require attacker control of configuration environment variables
  (operator-controlled trust boundaries, not input attack surfaces)
- Theoretical weaknesses without a realistic attack path against the MCP tool surface

## Privileged Elevation Helper

`docker-backup-tar-create.sh` is an optional, root-owned helper used by the
`ELEVATION_CMD` / `ELEVATION_HELPER_PATH` feature (see [ELEVATION.md](ELEVATION.md)).
Its security model:

- It replaces a bare `sudo tar` grant, which is a GTFOBins local-root primitive
  (`--checkpoint-action=exec`). The helper never accepts raw `tar` flags — it validates
  a fixed positional argument list and builds the `tar` invocation itself.
- The allowed appdata root is pinned by `ALLOWED_APPDATA_PATH` **inside the root-owned
  helper**, not taken from caller-supplied input, so an unprivileged caller cannot cause
  root to read arbitrary directories.
- It must be installed `root:root`, mode `0750`, and granted via a sudoers/doas rule
  scoped to that exact path. The grant must not `env_keep` the helper's inputs.

Reports of a way to (a) make the helper run `tar` with attacker-influenced flags, (b)
read an appdata root outside `ALLOWED_APPDATA_PATH`, or (c) otherwise gain root through
the helper are in scope and welcome.

Since 0.7.0 the tar helper also accepts x-backup declared paths (after `--`). Each must
be `<stack_name>/<path>`, with every part of `<path>` in `[A-Za-z0-9._-]`, none `.`,
`..` or starting with `-`. They go to tar as anchored, literal `--exclude=` values
**after** the global patterns. They can only leave data out of the archive. The same
rule is in `lib.sh` and `dsb_status.py`; `tests/xbackup-path-rule.bats` keeps the three
copies equal. The helpers pin `LC_ALL=C`, because in a UTF-8 locale bash's `[A-Za-z]`
matches non-ASCII letters, and sudo keeps `LANG`/`LC_*` by default.

## Snapshot Helper

`docker-backup-snapshot.sh` (0.7.0, optional) creates and deletes snapshots as root for
snapshot-assisted backup. Its trust boundary:

- **No caller-supplied path, ever.** The root-owned constants (`ALLOWED_APPDATA_PATH`,
  `SNAPSHOT_BACKEND`, `SNAPSHOT_DIR`) decide every path. The caller passes a verb, a stack
  name and a run timestamp, each checked against a fixed shape. The snapshot name is
  always `dsb-<stack>-<YYYYMMDD_HHMMSS>`.
- **ZFS:** `zfs destroy` is only ever given `<dataset>@dsb-<stack>-<ts>`, one snapshot of
  the one dataset holding the appdata root. Never `-r`, never a name without `@`.
- **btrfs:** `delete` and `sweep` act only on entries of `SNAPSHOT_DIR` named
  `dsb-<stack>-<ts>` that are real subvolumes (inode 256, not symlinks). `SNAPSHOT_DIR`
  must be a root-owned directory with no group or other write, and not under the appdata
  root.
- `sweep` touches nothing that does not match the snapshot name shape.
- `PATH` and `LC_ALL` are fixed inside the helper, because a root run with
  `ELEVATION_CMD=none` inherits the caller's environment.
- The tar helper's `--from-snapshot` takes a timestamp, not a path, and gets the path
  from this helper's `source` verb. Before calling it, the tar helper checks it is a
  root-owned regular file that nobody else can write, that both helpers name the same
  appdata root (`info`), and that the `source` path lies inside that exact snapshot.
- `create` repeats the boundary check after the stack is stopped, and on btrfs also scans
  the new snapshot for the empty inode-2 placeholder a nested subvolume leaves. That closes
  the nested-subvolume case whatever its timing. A **mount** (FUSE needs no root), or a
  ZFS child dataset, made in the moment between that re-check and the snapshot is still
  not detected. Only the owner of the stack dir can make one, and it can only hide that
  mount's own contents from the backup.
- The helper refuses to run if a mount lies between the snapshotted subvolume and the
  appdata root (the snapshot would hold the directory under it).

The tar helper's `temp_dir` (since 0.7.0). **Root never reads the caller's temp dir.**
The only files the backup puts there (the stack's compose file, by one of its four
names, and `.env`) are read **as the invoking user** (`setpriv --reuid/--regid
--clear-groups --no-new-privs`, from `SUDO_UID`/`SUDO_GID` or `DOAS_USER`). Each must be
a regular file of at most 16 MiB. They are copied into a private staging dir that stays
root-owned and 0700 for the whole archive, and that is what tar archives. The staged
files get the caller's owners and modes back; the stage dir, the archive's `./`
member, is root's. It is never given to the caller: in sticky `/tmp` the owner of an
entry can rename it, which would let it swap a symlink in under `tar -C` (audit
2026-10-22, R4-01). Anything else in the temp dir is ignored. If the drop to the caller
cannot be made, or an allowlisted name that is present cannot be stat'ed, the archive
fails, and a temp dir with no compose file is refused (R4-02). A name the caller's own
dir hides from the caller itself (it removes its own search permission mid-run) reads as
absent; that only drops the caller's own file from its own backup. So whatever the caller does to its own `/tmp/<name>` (swap it
for a symlink, rename another of its directories there, plant a link to a file it cannot
read), root archives only bytes the caller could read itself.

In front of that, as defence in depth, the dir must be a real directory under `/tmp`
(not a symlink), owned by the invoking user, mode 0700. After `cd -P` the kernel's cwd
must be the directory at that path (an inode compare, not bash's `pwd -P`). Before 0.7.0
any `/tmp/<name>` was accepted and archived as root, so a symlink there, or a root-owned
dir in `/tmp`, let the grant read any directory as root (audit 2026-10-22: F-01, then
R2-01 and R3-01 on the races in the first two fixes).

**Accepted:** whoever holds the sudo grant can `create` snapshots for any existing stack
with any well-formed timestamp, each pinning disk until the next sweep (or their own
`sweep`). That is a local disk-space denial of service by the backup user, not a read
or write escalation: `source` output is used only by the root tar helper, which archives
just `<stack>`.

**Accepted:** anyone who can edit a stack's compose file can declare `x-backup.exclude`
paths and so leave a subtree of that stack's appdata out of the backup. A declaration
can only narrow the stack's own backup, and every one needs a reason. For the nightly
run, each one is visible in status.json (`x_backup.excluded`) and the .prom
(`dsb_stack_xbackup_paths`). The manual script writes no status.json: it prints the
excluded paths and writes them to its `LOG_FILE`. The compose files are as trusted as the
stack's own configuration.

**Accepted:** the snapshot is of the whole subvolume or dataset that holds the appdata
root, not of one stack's directory. It is read-only and is deleted after the stack's
archive (or by the next run's sweep).
- **btrfs:** it lives in the 0700 root-only `SNAPSHOT_DIR`. While it exists, it holds
  copies of everything in that subvolume, which only root can reach.
- **ZFS:** it is reachable at `<mountpoint>/.zfs/snapshot/<name>` (with `snapdir=hidden`
  too) by any local user, subject to the file modes **as they were when it was taken**.
  For as long as it exists, a file deleted or tightened since then is still readable
  there at its old mode. The window is the archive's duration, longer only if a delete
  fails. The TrueNAS target is a single-admin, root-run host.

`tests/snapshot-helper.bats` runs each negative probe first against a naive helper, to
show the probe fires, and then against the real helper, which must refuse it without
running btrfs or zfs.

## Response Expectations

| Stage | Timeline |
|-------|----------|
| Acknowledgement | Within 3 business days |
| Initial assessment | Within 7 business days |
| Fix or remediation plan | Within 30 days for critical/high; 60 days for medium/low |

This is a personal project maintained by one developer. Response times are best-effort.
If you haven't heard back within 3 business days, a follow-up email is welcome.

## Disclosure

Coordinated disclosure is preferred. Please allow time for a fix to be released before
public disclosure. The CHANGELOG documents remediated findings at an appropriate level
of detail after each release.
