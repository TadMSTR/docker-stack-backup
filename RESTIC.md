# restic backend

Since 0.8.0, docker-stack-backup can write each stack to a [restic](https://restic.net)
repository as well as, or instead of, a tar archive. The orchestration does not change:
the same stack selection, the same stop → snapshot → start (USAGE.md "Snapshots"), the same
`x-backup` tiers and `EXCLUDE_PATTERNS`, the same status contract. restic adds
deduplicated, encrypted daily history with per-stack retention; the tar set can then move
to weekly (`TAR_SCHEDULE=full`) as the copy that depends on neither the restic repository
nor its password.

- [Requirements](#requirements)
- [How a backup works](#how-a-backup-works)
- [Install](#install)
- [Configuration](#configuration)
- [Retention, prune and check](#retention-prune-and-check)
- [Failures](#failures)
- [Restore](#restore)
- [Security](#security)
- [Verify as root](#verify-as-root)
- [Upgrading to 0.8.0](#upgrading-to-080)

## Requirements

- **restic 0.17.1 or later.** The helper tells "no repository" (exit 10, 0.17.0+), "locked"
  (11, 0.17.0+) and "wrong password" (12, 0.17.1+) apart, and the backup reports each as its
  own reason. It also uses `backup --json` summaries, `dump --archive tar`, `forget
  --group-by`, `check --read-data-subset`, `stats --mode raw-data`. Tested with 0.18.0
  (Debian trixie's package) and 0.18.1.
- util-linux `setpriv` and `unshare` (both already used by the other helpers).
- A **dedicated system user** for restic (`RESTIC_RUN_AS`, e.g. `dsb-restic`). Not root, and
  not the user the backup runs as.
- python3, as for status.json.

## How a backup works

Every restic call goes through the root-owned helper `docker-backup-restic.sh`, the third
helper next to the tar and snapshot helpers. Its constants, which only root can edit,
decide the repository, the password file, the user restic runs as, the binary, the host
name recorded in snapshots and the retention floors. The backup script passes verbs, a
stack name, the run timestamp, the run kind, retention counts and the stack's declared
paths; the helper checks each against a fixed shape.

For each stack, after the stop and (when snapshots are on) the snapshot and the start:

1. tar, when scheduled this run, archives the stack as before.
2. The helper makes **one restic snapshot of the stack** from the same source: the
   snapshot, through the snapshot helper's `source` verb (it never computes the path), or
   the live appdata while the stack is still stopped (stopped stacks and snapshot
   fallbacks). The stack is stopped once, whatever the number of backends.
3. After the stack is back up, `forget` applies that stack's retention.

Inside the helper, the backup runs in a **private mount namespace**: a tmpfs is mounted on
the fixed directory `RESTIC_STAGE_DIR`, the stack's compose file and `.env` are copied into
it (read as the invoking user, as the tar helper does), the stack's appdata is bound
read-only below it (the top bind; submounts below it keep their own flags), and restic is
run from there with relative paths. The mounts end with the namespace. The stack dir must
be a plain directory at its canonical path, and the helper checks that the bound directory
is the same inode it checked, so a stack dir replaced by a symlink in between is refused.

**Why the fixed directory.** restic chooses the parent snapshot, against which it detects
unchanged files, by host and paths, and it records absolute paths. A snapshot is mounted at
a different path every night (`/opt/.dsb-snapshots/dsb-<stack>-<ts>/…`), so backing it up
directly would find no parent and re-read every file, every night. Seen
through `RESTIC_STAGE_DIR`, every snapshot of a stack records the same paths, and btrfs and
ZFS snapshots keep inode numbers and ctimes, so restic's change detection (mtime, ctime,
size, inode) holds. `tests/restic-btrfs-real.bats` proves it on real btrfs: after the first
run, every appdata file is `unmodified` across fresh snapshots and across a live-dir run
between them, and exactly the rewritten file is `changed`. The stack's compose file and
`.env` are copied afresh each time, so those two always count as changed (two small files).

**Snapshot layout** (answers the plan's first question). The snapshot root holds
`compose.yaml` (whichever compose file name the stack uses), `.env` when present, and
`<stack>/` with the appdata. That is the tar archive's layout: `restic dump --archive tar`
produces the same members with the same names, types, modes, owners and sizes, without the
archive's leading `./` and its root `./` entry, which the restore ignores
(`tests/restic-e2e.bats`). So the restore wizard feeds the dump into its existing Step 4-6
code and every check from the 0.5.3 audit applies unchanged; no path is rewritten. One
difference: **a second hard link comes out of `dump` as a separate regular file** with the
same content (tar records it as a link). A restore from restic therefore breaks hard links
inside appdata, and such files take their space twice.

**Tags.** Each snapshot is tagged `dsb`, `stack:<stack>`, `kind:<daily|full>` and
`run:<run timestamp>`, with host `RESTIC_HOST`. `backup` passes `--group-by host,paths`
(restic's default, stated): the paths are what is stable. `forget` uses `--host
RESTIC_HOST --tag dsb,stack:<stack> --group-by host`, never `host,tags`: the `run:` and
`kind:` tags differ per snapshot, so grouping by tags would make every snapshot its own
group and nothing would ever be removed (`tests/restic-helper.bats` shows it).

**Excludes.** tar and restic leave out exactly the same files. Declared `x-backup` paths
go to restic anchored at the stack's dir under `RESTIC_STAGE_DIR` (they hold no wildcard);
the global `EXCLUDE_PATTERNS` go to both unanchored, where both tools match them at any
depth. `tests/restic-e2e.bats` compares tar's member list with restic's for every case in
`xbackup-tar.bats`, and shows that the naive translation (`--exclude <path>` as given)
breaks it. One theoretical difference in the globals: tar's `*` also matches `/`, restic's
does not, so a pattern like `a*b` would match `ax/yb` in tar only. A pattern matching a
directory excludes its whole subtree in both, so this needs a `*` between two parts of one
name. With restic enabled, an `EXCLUDE_PATTERNS` entry outside `A-Z a-z 0-9 . _ / * -` is a
config error.

## Install

Done once per host. Nothing here is done by the scripts.

1. Install restic (`apt install restic` on Debian 13: 0.18.0). Do not share another tool's
   bundled binary (Backrest's, for example).
2. Create the user: `useradd --system --no-create-home --shell /usr/sbin/nologin dsb-restic`.
3. Create the repository directory, **owned by that user's uid number**, mode 0700. On an
   NFS share (`sec=sys`), ownership is by number and root may be squashed, so create it
   on the NFS server or as a user the server maps correctly. It must not be inside another
   tool's repository.
4. Create the password: `head -c 32 /dev/urandom | base64 > /etc/docker-backup-restic/password`,
   root-owned, 0400 (the directory 0700). Keep a copy outside the host (a password manager):
   without it the repository cannot be read.
5. Install `docker-backup-restic.sh` root-owned, 0750, e.g. at
   `/usr/local/sbin/docker-backup-restic.sh`, and set its constants:

   ```bash
   ALLOWED_APPDATA_PATH="/opt/appdata"          # = config.sh APPDATA_PATH = the other helpers'
   SNAPSHOT_HELPER="/usr/local/sbin/docker-backup-snapshot.sh"
   RESTIC_BIN="/usr/bin/restic"
   RESTIC_REPO="/mnt/backup/restic"
   RESTIC_PASSWORD_FILE="/etc/docker-backup-restic/password"
   RESTIC_RUN_AS="dsb-restic"
   RESTIC_HOST="myhost"
   RESTIC_CACHE_DIR="/var/cache/docker-backup-restic"   # created, owned by RESTIC_RUN_AS
   RESTIC_STAGE_DIR="/run/docker-backup-restic"         # created, root 0700
   FLOOR_DAILY=7 FLOOR_WEEKLY=4 FLOOR_MONTHLY=0
   ```

6. Grant the backup user this helper through the same sudoers line as the other two
   (ELEVATION.md, "Install the helper").
7. Initialise: `sudo /usr/local/sbin/docker-backup-restic.sh init`.
8. Set `BACKENDS` and `RESTIC_HELPER_PATH` in config.sh (below), then `--dry-run`.

## Configuration

config.sh keys (all optional; the defaults keep 0.7.0's behaviour):

| Key | Default | Meaning |
|---|---|---|
| `BACKENDS` | `tar` | `tar`, `restic` or `"tar restic"` |
| `TAR_SCHEDULE` | `daily` | `daily`, or `full` = only on the full run (weekly). `full` needs both backends |
| `RESTIC_HELPER_PATH` | (empty) | the installed helper; required with restic |
| `RESTIC_KEEP_DAILY` / `_WEEKLY` / `_MONTHLY` | 7 / 4 / 6 | host default retention |
| `RESTIC_PRUNE_ON` | `full` | `full`, `daily` or `never` |
| `RESTIC_CHECK_ON` | `full` | `full`, `daily` or `never` |
| `RESTIC_CHECK_SUBSET` | `auto` | `auto`, `n/N` or `x%` |

The repository, password, user, binary and host name are **helper constants, never
config.sh keys**: config.sh is writable by the backup user, and may be tracked in git.

The two cadences:

- **Trial (both backends daily):** `BACKENDS="tar restic"`, `TAR_SCHEDULE=daily`.
- **Weekly tar:** `TAR_SCHEDULE=full`, and for `cleanup-old-backups.sh`
  `RETENTION_DAYS=27 KEEP_MIN=4`, which keeps exactly four weekly sets on every night of
  the week. 29 days keeps five on the full-run day (`tests/cleanup-weekly.bats`).

## Retention, prune and check

**Per stack**, in the stack's compose file, key by key over `RESTIC_KEEP_*`:

```yaml
x-backup:
  retention: {daily: 7, weekly: 4, monthly: 0}   # signoz, observability: 7d/4w
```

A missing key takes the host default, so a stack that wants no monthlies says
`monthly: 0`. Counts below the helper's floors (7 daily, 4 weekly) are **refused, never
raised**: that stack's forget does not run, the result is `refused`, the run fails. A
`RESTIC_KEEP_*` below the floors stops the run as `invalid-config`. The floors are a
security control: the helper's grant can be driven by any process of the backup user, and
without them `forget --keep-daily 1` would erase a stack's history. **They protect what they
name, and nothing more:** with the default monthly floor of 0, the grant can still remove a
stack's monthly snapshots (`forget <stack> 7 4 0`, then `prune`), so history older than about
four weeks is not protected by them. Set `FLOOR_MONTHLY` in the helper to protect monthlies
too; every stack then keeps at least that many.

`forget` runs after each stack's successful restic backup, scoped to this host and that
stack's tag. A stack whose compose dir is gone keeps its snapshots (nothing forgets an
absent tag); it is reported in `restic.orphan_stacks` and `dsb_restic_orphan_stacks`.
Remove those by hand, deliberately.

`prune` and `check` run after every stack, on the full run by default. Each of forget,
prune and check is **counted**: status.json `restic.<task>` has the result and a
last-success time carried forward across runs, and the .prom has
`dsb_restic_task_last_success_timestamp_seconds{task}` and `dsb_restic_task_failed{task}`.
"Configured" is not evidence that retention runs; the age of the last success is, and
STATUS.md has the alert.

**`RESTIC_CHECK_SUBSET=auto`** (answers the plan's second question) reads `n/12` of the
pack files on each check, with `n` advancing by one per check period (a week with the
default `RESTIC_CHECK_ON=full`, counted from the Unix epoch, so it does not depend on the
run day). restic's `n/N` subsets are disjoint and together cover every pack, so twelve
consecutive checks read the whole repository: once a quarter. For a 180-400 GB repository
that is 15-35 GB read per full run, a fraction of a weekly full tar set, and a damaged
pack is found within twelve weeks. A smaller `N` finds damage sooner
at a higher weekly cost; `x%` picks packs at random, so it gives no bound on when a pack
is first read.

## Failures

| Situation | Effect |
|---|---|
| Repository missing, wrong password, locked at start, helper refuses or fails | `restic.problem` = `restic-repo-missing`, `restic-password-wrong`, `restic-repo-locked`, `restic-helper-refused`, `restic-helper-failed` or `restic-repo-error`. Every stack's restic backup fails with that reason; tar still runs where scheduled. A stack with no tar this run is not stopped at all. |
| One stack's restic backup fails | That stack fails: `restic-backup-failed` (restic exit 3 = some files unreadable) or `restic-repo-locked`. Its tar result stands. |
| A stack's forget is refused or fails; prune or check fails | Counted (above); the run's notification is a failure and the run exits 1. The stacks stay `backed_up`. |

The run outcome (`success`/`partial`/`failed`) still counts stacks. `backend_last_success`
in status.json and `dsb_backend_last_success_timestamp_seconds{backend}` give each backend
its own last good run, so a weekly tar is not reported stale on the six days it does not
run.

## Restore

The restore wizard asks for the source when `RESTIC_HELPER_PATH` is set (Step 0): tar
archives, or restic snapshots of this host. For restic it lists the stacks and their
snapshots (newest first, with the run kind), then streams the helper's `dump` into the
same Steps 4-6: preview with the setuid/device warnings, extract before `down`, the safety
copy, the replace. A dump that fails changes nothing and stops nothing. The helper dumps
only this host's snapshots of the selected stack.

## Security

- restic runs as `RESTIC_RUN_AS` with **only `CAP_DAC_READ_SEARCH`**: in its effective,
  inheritable, ambient and bounding sets, no supplementary groups, `no_new_privs`. It can
  read any file (it is the backup reader), and write only what that user owns: the
  repository and the cache. It works on a root-squashed share because it is not root.
- **The password** is read by root from `RESTIC_PASSWORD_FILE` and given to restic on
  **stdin** (an inherited fd that restic reads without opening a path). It is never in
  argv, the environment, a file restic opens, or a log line. The plan suggested
  `--password-file /dev/fd/N`; restic would re-open that path, which works only because of
  `CAP_DAC_READ_SEARCH`, so stdin is used instead.
- restic gets a fixed environment (`env -i`): nothing of the caller's (`RESTIC_*`,
  proxies, `GODEBUG`) reaches it.
- Every caller value is checked against a fixed shape; declared paths by the same rule as
  the other three copies (`tests/xbackup-path-rule.bats`). forget and dump are scoped to
  `RESTIC_HOST` and the stack's tag; dump checks the id against that stack's own
  snapshots.
- The backup user cannot read the repository (it is `RESTIC_RUN_AS`'s, 0700) or the
  password (root's, 0400).

Accepted, documented: a process that can run the helper can trigger backups, prunes and
checks (load) and read its own stacks back through `dump`, which it could read anyway;
whoever controls the restic binary or `RESTIC_RUN_AS` reads every file on the host.

## Verify as root

Some properties need two real uids and real root, which no unprivileged test has (answers
the plan's third question). Run the vendored drill on the host after install, as root:

```bash
sudo bash tests/host/restore-drill.sh --backend both --probes --probe-user ted \
    --restic-run-as dsb-restic --record-dest /mnt/backup/docker-backups/$(hostname)
```

Its `--probes` checks, against a live restic process (each probe first shown to work against
a process of the probe user itself): restic runs as `RESTIC_RUN_AS` with
`CapEff`/`CapBnd` = `0000000000000004`; the probe user can read neither
`/proc/<restic pid>/environ` nor `/proc/<restic pid>/fd/0` (the password) and cannot
ptrace it; the password is in neither restic's cmdline nor environ. It then drills a tar
and a restic restore of a scratch stack through every wizard step, plus a negative case
for each, and records the passing backends in `restore-verified.json`. It uses a scratch
repository and password, never the production ones. The backup runs with `TMPDIR` unset,
as from cron, so it goes through the helpers' production temp dir rule (`^/tmp/[^/]+$`);
only the restore steps extract under `/tmp/dsb-drill/tmp` (0.8.1, #1218).

Also as root, on the real share: `sudo bash backup-verify.sh --verify` and the restore
wizard's Steps 1-4 on a real run dir after the chmod below (#1089: they read the share as
its owner). Check `ls -ld` of the repository directory (owned by `RESTIC_RUN_AS`, 0700).

## Upgrading to 0.8.0

- #1089: the backup and manual scripts now write archives 0600 and new run dirs 0700, and
  restore and verify read the share as its owner. Archives written before 0.8.0 stay 0664.
  After 0.8.0's restore and verify are installed, tighten them once, as the share owner:

  ```bash
  B=/mnt/backup/docker-backups/$(hostname)    # BACKUP_DEST/<hostname>
  find "$B" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*_[0-9]*' -exec chmod 0700 {} +
  find "$B" -mindepth 2 -maxdepth 2 -type f \( -name '*.tar' -o -name '*.tar.*' \) -exec chmod 0600 {} +
  ```

- Nothing changes until `BACKENDS` includes restic: the default is tar, daily, as before.
