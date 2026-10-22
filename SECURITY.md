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
  from this helper's `source` verb.

**Accepted:** the snapshot is of the whole subvolume or dataset that holds the appdata
root (on forge, `@opt`), not of one stack's directory. It is read-only, lives in a
root-only directory, and is deleted after the stack's archive. While it exists, it
holds root-readable copies of everything in that subvolume, which root can read anyway.

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
