# Run Status & Coverage

From 0.6.0, every real run of `docker-stack-backup.sh` writes a machine-readable record
of what it did: `status.json` and, optionally, a Prometheus textfile. Each run also
classifies every stack's mounts, so the record says which state the archive does **not**
take. Alerts, dashboards and the restore drill all read this one contract.

- [Files and when they are written](#files-and-when-they-are-written)
- [status.json](#statusjson)
- [Coverage classes](#coverage-classes)
- [Exemptions](#exemptions)
- [Carry-forward and the untrusted share](#carry-forward-and-the-untrusted-share)
- [Prometheus textfile](#prometheus-textfile)
- [Example alerts](#example-alerts)
- [Liveness ping](#liveness-ping)
- [Configuration](#configuration)

## Files and when they are written

| File | Written |
|---|---|
| `$BACKUP_DEST/$HOSTNAME/status.json` | end of every real run, and on every abort path, by the run that holds the lock |
| `$BACKUP_DEST/$HOSTNAME/<run>/status.json` | same content, only if the run dir exists (something was archived); history for trends |
| `$PROM_TEXTFILE_DIR/docker_stack_backup.prom` | same points as `status.json`, aborts included, if `PROM_TEXTFILE_DIR` is set |

**A dry run, `--coverage-report` and `docker-stack-backup-manual.sh` write none of them**,
so a test run or a one-stack manual backup never replaces the nightly's record. **Nor does
a run that finds the lock held**: the status files and the ping belong to the lock
holder, so a second invocation during the nightly logs that and leaves them alone (an
abort before the lock step takes the lock just to write its record, if it is free).
This relies on every run resolving the **same `LOCK_FILE`**. The default depends on
whether the user can write `/var/run`, so if the script may be run by more than one user,
set `LOCK_FILE` explicitly in `config.sh`.

`status.json` is a **regular file**, never a directory. `docker-stack-restore.sh`,
`backup-verify.sh` and `cleanup-old-backups.sh` enumerate directories under the host dir
(and `*.tar*` files inside a run dir), so they ignore it. A directory there would be shown
as a run, counted by `--stats` and `KEEP_MIN`, and deleted by retention.

Every write goes to a temp file in the same directory (`status.json.tmp.<pid>`,
`docker_stack_backup.prom.<pid>`; the latter deliberately does not end in `.prom`, since
collectors read every `*.prom`) and is then renamed into place. Files are mode 0644 under
any umask: they hold names, sizes and paths, no secrets. If a requested file cannot be
written, the run logs an error and exits non-zero, after the notifications have gone out.

The encoding is done by `dsb_status.py` (run as `python3 -I`, standard library only),
which must be installed next to `docker-stack-backup.sh`. No JSON is ever assembled in
bash. If python3 is missing, the run logs that and exits non-zero; set
`STATUS_ENABLED=false` (and leave `PROM_TEXTFILE_DIR` empty) to run without it.

## status.json

`schema: 1`. Additive changes (new fields, new enum values) keep `1`; anything that
removes or changes the meaning of a field bumps it.

```json
{
 "schema": 1,
 "tool": "docker-stack-backup",
 "version": "0.8.0",
 "host": "forge",
 "run_id": "20261019_020001",
 "started": 1760839201,
 "finished": 1760839987,
 "duration_s": 786,
 "outcome": "success",
 "abort_reason": null,
 "run_kind": "daily",
 "platform": "debian",
 "snapshot_backend": "btrfs",
 "snapshot_note": null,
 "backends": ["tar", "restic"],
 "tar_schedule": "full",
 "tar_ran": false,
 "backend_last_success": {"tar": 1760234401, "restic": 1760839987},
 "restic": {"ran": true, "repo_id": "6b0c…64 hex…", "problem": null,
            "forget": {"result": "ok", "last_success": 1760839987, "stacks": 31, "failed": 0},
            "prune": {"result": null, "last_success": 1760234401},
            "check": {"result": null, "last_success": 1760234401, "subset": null},
            "orphan_stacks": [], "snapshots": 412,
            "stats": {"total_size": 190000000000, "total_uncompressed_size": 260000000000,
                      "snapshots_count": 412, "total_blob_count": 1800000}},
 "restore_verified": {"tar": {"time": 1760200000, "version": "0.8.0", "ref": "drill: dsb-drill.tar"},
                      "restic": {"time": 1760200100, "version": "0.8.0", "ref": "drill snapshot 1eccf1bd"}},
 "counts": {"found": 35, "backed_up": 31, "skipped": 4, "failed": 0},
 "bytes_total": 89120000000,
 "dest": {"path": "/mnt/atlas/forge/backups/docker-backups", "free_bytes": 40000000000000},
 "last_success": 1760839987,
 "stack_last_success": {"signoz": 1760839987, "...": 0},
 "stacks": [
  {"name": "signoz", "result": "backed_up", "reason": null, "mode": "running",
   "archive": "20261019_020001/signoz.tar", "bytes": 38654705664,
   "started": 1760839300, "finished": 1760839450, "downtime_s": 9,
   "last_success": 1760839450,
   "coverage": {"status": "ok", "error": null, "items": [
     {"service": "clickhouse", "class": "archived", "type": "bind",
      "source": "/opt/appdata/signoz/clickhouse", "target": "/var/lib/clickhouse",
      "rw": true, "alerting": false, "exempt": null}]},
   "x_backup": {"status": "none", "errors": [], "run_kind": "daily", "excluded": [],
                "stale": [], "retention": null},
   "snapshot": {"backend": "btrfs", "used": true, "fallback_reason": null, "snapshot_s": 1},
   "backends": {"restic": {"result": "ok", "reason": null, "snapshot_id": "…64 hex…",
                           "duration_s": 95, "files_new": 12, "files_changed": 140,
                           "files_unmodified": 9210, "data_added": 1900000000,
                           "forget": {"result": "ok", "retention": {"daily": 7, "weekly": 4, "monthly": 0},
                                      "kept": 11, "removed": 1}}}},
  {"name": "ollama", "...": "...",
   "x_backup": {"status": "ok", "errors": [], "run_kind": "daily",
                "excluded": [{"path": "ollama/models/blobs", "reason": "re-pull with ollama pull",
                              "tier": "exclude", "action": "excluded", "exists": true}],
                "stale": [], "retention": null},
   "snapshot": {"backend": "btrfs", "used": false, "fallback_reason": "nested-subvolume",
                "snapshot_s": null}}
 ],
 "unowned_appdata": [
  {"dir": "dockhand.pre-v1046-20260907-1525", "bytes": 42991616, "estimate": false, "exempt": null}
 ],
 "exemptions": {"file": "/usr/local/bin/coverage-exemptions.conf", "status": "ok",
                "errors": [], "stale": []},
 "coverage": {"status": "uncovered", "stacks_unknown": 0, "stacks_uncovered": 1,
              "uncovered_items": 1, "unowned_appdata": 1, "unowned_appdata_unexempt": 1,
              "xbackup_config_errors": 0,
              "by_class": {"archived": 95, "named-volume": 7}}
}
```

| Field | Meaning |
|---|---|
| `outcome` | `success`: no stack failed. `partial`: some failed, some backed up. `failed`: none backed up and at least one failed. `aborted`: the loop never ran, or did not finish. A run that finds no stacks is `success` with zero counts; alert on `counts.found`, not on the outcome. |
| `abort_reason` | `not-privileged`, `invalid-config` (a numeric setting, `FULL_RUN_DAY` or `PLATFORM` did not parse), `preflight-failed`, `interrupted` (INT/TERM, or an unexpected exit mid-run, including during the final status step). `null` unless aborted. A signal during a stack lets that stack finish (its services are started again) and stops the loop after it; the stacks done so far are in `stacks`. A second signal exits at once, and the stack it interrupted is recorded as `failed` / `interrupted` (its services may be stopped). `lock-held` is reserved: such a run writes nothing. |
| `run_kind` | `daily` or `full` (0.7.0): `full` on `FULL_RUN_DAY` or with `--full`. On a daily run the x-backup `weekly` tier is deferred. |
| `platform` | the resolved platform profile (0.7.0): `debian`, `truenas` or `generic`. |
| `snapshot_backend` | the snapshot backend this run resolved to (0.7.0): `none`, `btrfs` or `zfs`. |
| `snapshot_note` | why a requested backend (`auto`, or one from the platform profile) resolved to `none`, e.g. `"btrfs: SNAPSHOT_HELPER_PATH is not set"`. `null` otherwise. |
| `last_success` | `finished` of the last `success` run, carried forward otherwise. `null` = never (that this file knows of). |
| `stack_last_success` | per stack, the `finished` of its last `backed_up`, carried forward. In a completed run it lists only the stacks found this run (a removed stack drops out); an aborted run keeps the previous map whole. |
| `stacks[].result` / `reason` | see [USAGE.md, "Stack results and reasons"](USAGE.md#stack-results-and-reasons). |
| `stacks[].mode` | `running` (stopped, archived, started; or stopped, snapshotted, started, archived from the snapshot) or `stopped` (archived as it was). |
| `stacks[].archive` / `bytes` | path relative to `$BACKUP_DEST/$HOSTNAME`, and the archive's actual size. Also set for `restart-failed`, where the archive was written. |
| `stacks[].downtime_s` | `compose stop` until `restart_stack_with_retry` reports every service up. `0` for a stopped stack; `null` if never stopped, or never started again. Post-restart hooks are not included. With a snapshot the stack is started before the archive is written, so this no longer includes the archive time. |
| `stacks[].coverage` | `status`: `ok`, `uncovered` (an alerting item without an exemption) or `unknown` (`docker compose config` failed; `error` has its first stderr line). `null` on an aborted run. |
| `stacks[].x_backup` | the stack's backup tiers as this run applied them (0.7.0; USAGE.md "Backup tiers"). `status`: `none` (no block), `ok`, `config-error` (the block was rejected: `errors` says why, and the stack was backed up **in full**) or `unknown` (`docker compose config` failed, or the reader did; backed up in full). `excluded` lists what was left out: `tier` is `exclude` or `weekly`, `action` is `excluded` or `deferred` (a weekly path on a daily run; not the same thing for alerting), `exists` is `true`/`false`/`null` (could not be told, e.g. a root-only dir on an unprivileged run). `stale`: declared paths that do not exist (still excluded, not an error). `retention`: reserved for restic (0.8.0). `null` for a stack that never got that far (skipped before the stop, or an aborted run). |
| `stacks[].snapshot` | present when a snapshot backend is in use (0.7.0; USAGE.md "Snapshots"), else `null`. `used`: archived from a snapshot. `fallback_reason` (archived the old way, stopped): `nested-subvolume`, `nested-dataset`, `mountpoint`, `snapdir-disabled`, `check-failed`, `create-failed`; `null` when the snapshot was used or the stack was stopped already (nothing to quiesce). `snapshot_s`: seconds to take it. `delete_failed`: the snapshot could not be deleted after its archive (the next run's sweep retries). |
| `backends` / `tar_schedule` / `tar_ran` | the configured backends, tar's schedule (`daily` or `full`) and whether tar ran this run (0.8.0; RESTIC.md). |
| `backend_last_success` | per backend, the `finished` of the last run in which it ran and failed for no stack, carried forward like `last_success`. A weekly tar keeps its time through the six days it does not run. `null` = never. |
| `stacks[].backends` | per backend that ran for this stack (0.8.0): `tar` {`result`, `archive`, `bytes`}; `restic` {`result`, `reason` (on failure), `snapshot_id`, `duration_s`, `files_new`, `files_changed`, `files_unmodified`, `data_added`, `forget` {`result`: `ok`/`failed`/`refused`, `retention` {daily, weekly, monthly}, `kept`, `removed`}}. `result` is `ok` or `failed`; a stack is `backed_up` only if every backend scheduled for it succeeded, and its `reason` is then the first failure (`archive-failed` before a restic reason). The top-level `archive`/`bytes` stay tar's. `null` for a stack that never got that far. |
| `restic` | with restic in `BACKENDS`, else `null` (0.8.0). `problem`: why restic could not be used at all this run (`restic-repo-missing`, `restic-password-wrong`, `restic-repo-locked`, `restic-helper-refused`, `restic-helper-failed`, `restic-repo-error`), else `null`. `forget`/`prune`/`check`: `result` this run (`ok`, `failed`, or `null` = not run), `last_success` carried forward. forget is `ok` only if every stack's forget was; `check.subset` is what was read. `orphan_stacks`: stacks with snapshots and no stack dir (their snapshots are never forgotten). `snapshots`, `stats`: the repository, from the helper. |
| `restore_verified` | per backend, the last passing restore drill (`tests/host/restore-drill.sh --record-dest`), read from `restore-verified.json` next to `status.json`. That file is on the share and read like the previous status.json (untrusted: regular file, ≤ 64 KiB, this host, integer times in range, bounded printable strings). `null` if there is none. |
| `snapshot_cleanup` | with a snapshot backend, else `null`: `failed` counts the deletes that failed this run, plus 1 if the start-of-run sweep failed; `swept` counts the leftovers from earlier runs that the sweep removed. A snapshot that is never deleted pins disk and keeps a frozen copy of the whole subvolume, so `failed > 0` is also in the notification text. |
| `unowned_appdata` | every **directory** in `APPDATA_PATH` that matches no stack. Regular files and symlinks are skipped. `estimate: true` when `du` could not read everything (e.g. root-owned appdata, unprivileged run). `null` on an aborted run. |
| `exemptions.status` | `ok`, `missing` (no file; no exemptions) or `config-error` (lines were rejected; `errors` lists them; the valid lines still apply). |
| `coverage.status` | `config-error` > `unknown` > `uncovered` > `ok`, the worst that applies to the run. `config-error` covers the exemptions file and, from 0.7.0, any stack whose x-backup block was rejected (`xbackup_config_errors` counts them). `unknown` also when `APPDATA_PATH` could not be listed: then `coverage.unowned_appdata_status` is `unknown` and `unowned_appdata_error` says why. An unreadable area is never reported as an empty one. |

## Coverage classes

The classifier runs once per real run, after every stack is back up, so no stack's
downtime grows (forge: 35 stacks in 1.3 s). It runs `docker compose config --format json`
in each stack dir. Compose resolves `${VAR}`, short and long volume syntax, `extends` and
relative paths; the YAML is never parsed or grepped here. **Every stack is classified,
skipped, stopped and failed ones included**: the config is static, and a stack that is
stopped now (a cron one-shot like renovate) still has state.

**The classifier reports; it does not select.** Selection is still "the compose file
names `APPDATA_PATH`" (`stack_has_appdata`), unchanged.

| Class | Rule | Alerting |
|---|---|---|
| `archived` | bind source is `$APPDATA_PATH/<stack>` or below | no |
| `other-stack-appdata` | bind source under `$APPDATA_PATH/<other>`; `other_stack` names it, `other_backed_up` says whether it was backed up this run | only if `<other>` was not backed up |
| `stack-dir` | **read-only** bind source inside the stack dir: config, which is git's job (the archive takes only the compose file and `.env` from there) | no |
| `stack-dir-rw` | **writable** bind source inside the stack dir (e.g. `./pgdata:/var/lib/postgresql/data`): state the container writes, usually git-ignored, and in no backup | **yes** |
| `system` | `/var/run`, `/run`, `/proc`, `/sys`, `/dev`, `/etc/localtime`, `/etc/timezone`, `/lib/modules`, plus `COVERAGE_IGNORE_PATHS`, read-only or not. These are sockets, tmpfs, devices and host clock/kernel files, not state worth archiving. Anything else you put under them is not reported either; keep stack state out of `/run` | no |
| `input-ro` | any other host bind with `read_only: true` | no |
| `uncovered` | any other **writable** host bind | **yes** |
| `named-volume` | `type: volume`, named or anonymous (`volume_name` = the docker name if compose sets one) | **yes** |
| `tmpfs`, `other` | | no |

Paths on both sides are normalised (`.`/`..`, duplicate slashes) without touching the
filesystem: no symlink on the share or in appdata steers a decision. The configured roots
(the stack dir, `APPDATA_PATH`) are compared in both their configured and resolved
spelling, because compose reports paths resolved from its working directory.

In `--coverage-report` (no run happened), `other_backed_up` is `null` and an
`other-stack-appdata` item is alerting only if `<other>` is not a stack at all.

## Exemptions

`$SCRIPT_DIR/coverage-exemptions.conf`, or `COVERAGE_EXEMPTIONS_FILE`. Start from
`coverage-exemptions.example.conf`; the live file is git-ignored.

```
# <kind>|<subject>|<reason>
stack|sandbox-db|disposable scratch databases; restart: "no", recreated on demand
mount|code-server:/home/me/repos|git working trees; every repo has a remote
mount|jobsearch:volume:pgdata|dumped nightly to /opt/appdata/jobsearch/dumps
appdata|old-service.pre-migration-20260101|kept until 2026-12-01, then delete
```

- `stack|<stack>` covers every alerting item of the stack. It does not cover `unknown`: a
  stack whose config cannot be read is always reported.
- `mount|<stack>:<path>` matches a bind whose normalised source equals the path;
  `mount|<stack>:volume:<name>` matches a named volume by its key under `volumes:`.
  A stack name containing `:` cannot be used in a mount line.
- `appdata|<dir>` matches an unowned appdata dir by name.

Every exemption needs a reason. An exempted item keeps its class and gains
`exempt: "<reason>"`; it stops counting as uncovered. **An entry that matches nothing in a
run is listed in `exemptions.stale`** and counted in the metrics: the thing it excused is
gone or has changed, so the reason may no longer be true.

The file is data: it is **never sourced or evaluated**, and no field reaches the shell.
A line with an unknown kind, an empty field, a malformed mount subject, invalid UTF-8 or
a control character is rejected and logged (made printable). A file over 1 MiB, or one
that is not a regular file, is rejected whole. Either way the backup runs, and
`exemptions.status` is `config-error`.

## Carry-forward and the untrusted share

`last_success` and `stack_last_success` make "no successful backup in 26 h" alertable
from one file, so each run reads the previous `status.json` before replacing it.

That file is on the backup share, and **the share is a root trust boundary** (see
USAGE.md): anyone who can write it can put anything there. So the previous file is
treated as attacker input:

- It is read only by `dsb_status.py`, never by the shell, and no value from it reaches
  `$(( ))`, `eval` or a command line.
- It is opened with `O_NOFOLLOW | O_NONBLOCK` and must be a regular file (a symlink or a
  FIFO is ignored, and cannot hang the run) of at most 4 MiB.
- It must be valid UTF-8 JSON (no `NaN`/`Infinity`), with `tool`, `schema: 1` and this
  run's `host`.
- A carried time must be a JSON integer (not a float, string, `true` or object) between
  2020-01-01 and now + 1 day. Anything else is dropped, with a warning in the log.
- Any doubt means "no previous success". It is never an error that stops the run.

`tests/status-carry-forward.bats` shows each probe firing on a deliberately naive reader
before showing the real one reject it.

## Prometheus textfile

Plain node_exporter textfile format: `# HELP` / `# TYPE` once per metric, gauges only,
integer values. Nothing in it is specific to one consumer. node_exporter's textfile
collector, Alloy's `prometheus.exporter.unix` textfile block or anything else that reads
`*.prom` will do.

Every series carries `host`. **Labels are stack names and fixed enums only**: no paths,
volume names or free text (those are in `status.json`). A host or stack name outside
`[A-Za-z0-9._-]` is reported as `_invalid` (and logged), never escaped. Several invalid
stacks are merged into one series: counts and bytes are summed, downtime takes the
maximum, last success takes the oldest.

| Metric | Labels | Value |
|---|---|---|
| `dsb_build_info` | `version` | 1 |
| `dsb_last_run_timestamp_seconds` | | when the last run finished |
| `dsb_last_run_duration_seconds` | | |
| `dsb_last_run_outcome` | `outcome` | one-hot over success/partial/failed/aborted |
| `dsb_last_success_timestamp_seconds` | | carried forward; **0 = never** |
| `dsb_stacks_found` | | |
| `dsb_stacks` | `result` | count per backed_up/skipped/failed |
| `dsb_stack_result` | `stack`, `result`, `reason` | 1 (`reason="none"` when there is none) |
| `dsb_stack_last_success_timestamp_seconds` | `stack` | carried forward |
| `dsb_stack_archive_bytes` | `stack` | stacks with an archive |
| `dsb_stack_downtime_seconds` | `stack` | stacks that were stopped |
| `dsb_coverage_items` | `stack`, `class` | count per class present |
| `dsb_coverage_uncovered` | `stack` | alerting items without an exemption |
| `dsb_coverage_unknown` | `stack` | 1 if `docker compose config` failed |
| `dsb_unowned_appdata_dirs` | | |
| `dsb_unowned_appdata_unexempt` | | |
| `dsb_unowned_appdata_unknown` | | 1 if `APPDATA_PATH` could not be listed |
| `dsb_exemptions_stale` | | |
| `dsb_exemptions_config_error` | | 1 if lines were rejected |
| `dsb_last_run_kind` | `kind` | one-hot over daily/full (0.7.0) |
| `dsb_stack_xbackup_paths` | `stack`, `state` | declared paths per state: `excluded`, `deferred` (weekly tier on a daily run), `stale` (missing) (0.7.0) |
| `dsb_stack_xbackup_config_error` | `stack` | 1 if the stack's x-backup block was rejected and it was backed up in full (0.7.0) |
| `dsb_stack_snapshot_used` | `stack` | 1 if archived from a snapshot; only with a snapshot backend (0.7.0) |
| `dsb_snapshot_fallbacks` | | stacks archived the old way although a backend is set; only with a snapshot backend (0.7.0) |
| `dsb_snapshot_cleanup_failures` | | snapshot deletes that failed, +1 if the sweep failed; only with a snapshot backend (0.7.0) |
| `dsb_snapshot_leftovers_swept` | | leftovers from earlier runs removed by this run's sweep; only with a snapshot backend (0.7.0) |
| `dsb_backend_enabled` | `backend` | 1 per configured backend (0.8.0) |
| `dsb_backend_ran` | `backend` | 1 if the backend was scheduled in the last run (0.8.0) |
| `dsb_backend_last_success_timestamp_seconds` | `backend` | carried forward; **0 = never** (0.8.0) |
| `dsb_stack_backend_ok` | `stack`, `backend` | 1 ok / 0 failed; absent if the backend did not run for the stack (0.8.0) |
| `dsb_stack_restic_files` | `stack`, `state` | files in the stack's restic snapshot: `new`, `changed`, `unmodified` (0.8.0) |
| `dsb_stack_restic_data_added_bytes` | `stack` | (0.8.0) |
| `dsb_stack_restic_duration_seconds` | `stack` | (0.8.0) |
| `dsb_restic_repo_available` | | 0 when `restic.problem` is set (0.8.0) |
| `dsb_restic_task_last_success_timestamp_seconds` | `task` | forget/prune/check, carried forward; **0 = never** (0.8.0) |
| `dsb_restic_task_failed` | `task` | 1 if the task ran and failed in the last run (0.8.0) |
| `dsb_restic_orphan_stacks` | | (0.8.0) |
| `dsb_restic_snapshots` | | this host's snapshots in the repository (0.8.0) |
| `dsb_restic_repo_bytes` / `dsb_restic_repo_uncompressed_bytes` | | repository size (0.8.0) |
| `dsb_restore_verified_timestamp_seconds` | `backend` | last passing restore drill; absent if none recorded (0.8.0) |

On an aborted run the per-stack result and coverage series are absent (the loop did not
run); the host series and `dsb_stack_last_success_timestamp_seconds` are still written.

## Example alerts

The textfile is rewritten once a night, so allow for the run itself in `for:` (forge's
Prometheus is itself stopped for about 2.5 minutes inside the backup window).

**Aggregate every term** of an expression that adds metrics together. Once the scrape
adds `job`/`instance` labels, a bare series and a `sum by (host)` result no longer share
a label set, and `+` matches nothing: the alert can never fire. Up to 0.6.0 this file's
`DockerStackBackupUncovered` example had exactly that bug.

```yaml
# No successful run for 26 h (0 = never, which also fires).
- alert: DockerStackBackupStale
  expr: time() - dsb_last_success_timestamp_seconds > 26 * 3600
  for: 30m

# Any stack failed in the last run.
- alert: DockerStackBackupFailed
  expr: dsb_stacks{result="failed"} > 0 or dsb_last_run_outcome{outcome="aborted"} == 1
  for: 10m

# State the archive does not cover: uncovered mounts, unknown coverage, unowned appdata,
# and x-backup blocks that were rejected (those stacks were backed up in full, but the
# declaration someone relies on is not being applied).
- alert: DockerStackBackupUncovered
  expr: >
    sum by (host) (dsb_coverage_uncovered) + sum by (host) (dsb_coverage_unknown)
    + sum by (host) (dsb_unowned_appdata_unexempt) + sum by (host) (dsb_unowned_appdata_unknown)
    + sum by (host) (dsb_stack_xbackup_config_error) > 0
  for: 1h

# A snapshot could not be deleted (or the sweep failed): it pins disk and holds a frozen
# copy of the whole subvolume until a later sweep succeeds.
- alert: DockerStackBackupSnapshotCleanup
  expr: sum by (host) (dsb_snapshot_cleanup_failures) > 0
  for: 1h

# Snapshots configured, but a stack was archived the old way (stopped for the whole
# archive). Informational: the backup itself is fine.
- alert: DockerStackBackupSnapshotFallback
  expr: sum by (host) (dsb_snapshot_fallbacks) > 0
  for: 1h
  labels: {severity: info}
```

For restic (0.8.0). The "never ran" cases are deliberate: a restic run whose forget, prune
or check has never succeeded has 0 there, and fires.

```yaml
# restic unusable this run (missing repository, wrong password, helper failure).
- alert: DockerStackBackupResticUnavailable
  expr: dsb_restic_repo_available == 0
  for: 10m

# Retention is not running: no successful forget for 2 days, or prune/check for 9 days
# (both run on the weekly full run by default). "Configured" is not evidence; this is.
- alert: DockerStackBackupResticForgetStale
  expr: dsb_backend_enabled{backend="restic"} == 1 and on (host) (time() - dsb_restic_task_last_success_timestamp_seconds{task="forget"} > 2 * 86400)
  for: 1h
- alert: DockerStackBackupResticMaintenanceStale
  expr: dsb_backend_enabled{backend="restic"} == 1 and on (host) (time() - dsb_restic_task_last_success_timestamp_seconds{task=~"prune|check"} > 9 * 86400)
  for: 1h
- alert: DockerStackBackupResticCheckFailed
  expr: dsb_restic_task_failed{task="check"} == 1

# A backend has not had a good run in its window: a day for daily, 8 days for a weekly tar.
- alert: DockerStackBackupBackendStale
  expr: >
    (time() - dsb_backend_last_success_timestamp_seconds{backend="restic"} > 26 * 3600)
    or (time() - dsb_backend_last_success_timestamp_seconds{backend="tar"} > 8 * 86400)
  for: 30m

# No verified restore of a backend for 35 days (0.8.0: tests/host/restore-drill.sh).
# Absent until the first drill is recorded; the `absent` arm makes that fire too.
- alert: DockerStackBackupRestoreUnverified
  expr: >
    (time() - dsb_restore_verified_timestamp_seconds > 35 * 86400)
    or on (host, backend) (dsb_backend_enabled == 1 unless on (host, backend) dsb_restore_verified_timestamp_seconds)
  for: 1h
```

`dsb_stack_xbackup_config_error` exists from 0.7.0. On a host still on 0.6.0 that term
has no series, and `+` with an empty side returns nothing: deploy 0.7.0 before adding it,
or wrap it as `(sum by (host) (dsb_stack_xbackup_config_error) or sum by (host) (dsb_stacks_found) * 0)`.

## Liveness ping

`PING_URL` (empty = off) uses the Healthchecks.io URL scheme, which forge's self-hosted
Healthchecks speaks too:

| When | URL |
|---|---|
| before the backup loop | `$PING_URL/start` |
| `success` | `$PING_URL` |
| `partial`, `failed`, `aborted`, or the status could not be written | `$PING_URL/fail` |

curl gets 10 s and 2 retries, and a ping error is a warning, never a failed run. This
gives a cron-liveness signal that does not depend on the metrics pipeline.

The URL may carry a secret ping key. It is passed to curl as a config on a file
descriptor (`-K`), never on the command line where `ps` shows it, and it is never
logged. It must be `http://` or `https://` with no control characters, or the ping is
skipped with a warning.

## Configuration

All optional; with none of them set the run writes `status.json` and nothing else.

| Key | Default | Notes |
|---|---|---|
| `STATUS_ENABLED` | `true` | `false`: no `status.json` (and nothing to carry forward from) |
| `STATUS_FILE` | `$BACKUP_DEST/$HOSTNAME/status.json` | a regular file, never a dir |
| `PROM_TEXTFILE_DIR` | empty (off) | the dir your collector reads `*.prom` from; must exist |
| `COVERAGE_EXEMPTIONS_FILE` | `$SCRIPT_DIR/coverage-exemptions.conf` | missing = no exemptions |
| `COVERAGE_IGNORE_PATHS` | empty | colon-separated extra `system` prefixes |
| `PING_URL` | empty (off) | secret; never logged |

`docker-stack-backup.sh --coverage-report` prints the classifier's JSON for every stack,
with exemptions applied, and exits. It stops, archives and writes nothing, and takes no
lock, so it is safe to run at any time, as the backup user.
