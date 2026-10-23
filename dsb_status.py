#!/usr/bin/env python3
"""Status contract helper for docker-stack-backup (see STATUS.md).

Run as `python3 -I dsb_status.py <command> ...`. Standard library only: TrueNAS SCALE
and fresh Debian hosts are targets, so no jq, no PyYAML.

Commands:
  record <records-file> <name> <result> <reason> <mode> <archive> <bytes> <started>
         <finished> <downtime>
      Append one per-stack JSON line. Called once per stack by docker-stack-backup.sh.
  finalize --records ... --status-file ... [--prom-dir ...] [--aborted REASON] ...
      Classify coverage, carry last_success forward, write status.json (both copies)
      and the .prom file. Prints a one-line summary on stdout; diagnostics on stderr.
  coverage-report --stack-base ... --appdata ... <stack-name>...
      Print the coverage classifier's JSON for the named stacks. Writes nothing.
  xbackup --stack-path ... --appdata-dir ... --run-kind daily|full --out FILE
      Read and validate the stack's `x-backup` block (USAGE.md). Writes the per-stack
      x_backup record to FILE and prints the paths to exclude this run on stdout,
      NUL-terminated. An invalid block prints nothing: the stack is backed up in full.
  retention <xbackup-file> <daily> <weekly> <monthly>
      Print the stack's restic retention, "d w m": x-backup.retention key by key, else
      the host defaults given.
  restore-verified --file F --backend tar|restic --host H --version V --ref REF
      Record a verified restore (tests/host/restore-drill.sh) in F, atomically.

Everything this reads back from the backup share (the previous status.json) or from an
operator file (the exemptions file) is data. It is parsed here, validated, and never
handed back to the shell for evaluation. The share is a root trust boundary (USAGE.md).
"""

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import time

SCHEMA = 1
TOOL = "docker-stack-backup"

RESULTS = ("backed_up", "skipped", "failed")
# Every reason docker-stack-backup.sh can record. A contract: STATUS.md lists them.
REASONS = (
    "no-compose-file", "no-appdata-reference", "appdata-missing", "appdata-empty",
    "not-running", "compose-ps-failed", "running-state-mismatch", "stop-failed",
    "archive-failed", "restart-failed", "interrupted",
    # restic (0.8.0): the stack's restic backup failed, or restic could not be used this
    # run at all (the same reason is then in restic.problem).
    "restic-backup-failed", "restic-repo-missing", "restic-repo-locked",
    "restic-password-wrong", "restic-repo-error", "restic-helper-failed",
    "restic-helper-refused",
)
RESTIC_PROBLEMS = REASONS[REASONS.index("restic-repo-missing"):]
MODES = ("running", "stopped")
OUTCOMES = ("success", "partial", "failed", "aborted")
ABORT_REASONS = (
    "not-privileged", "invalid-config", "lock-held", "preflight-failed", "interrupted",
)
CLASSES = (
    "archived", "other-stack-appdata", "stack-dir", "stack-dir-rw", "system", "input-ro",
    "uncovered",
    "named-volume", "tmpfs", "other",
)
SYSTEM_PATHS = (
    "/var/run", "/run", "/proc", "/sys", "/dev", "/etc/localtime", "/etc/timezone",
    "/lib/modules",
)
EXEMPTION_KINDS = ("stack", "mount", "appdata")
RUN_KINDS = ("daily", "full")
SNAPSHOT_BACKENDS = ("none", "btrfs", "zfs")
# Why a stack with a snapshot backend was archived the old way (stop-archive-start).
FALLBACK_REASONS = (
    "nested-subvolume", "nested-dataset", "mountpoint", "snapdir-disabled",
    "check-failed", "create-failed",
)
PLATFORMS = ("debian", "truenas", "generic")
BACKENDS = ("tar", "restic")
BACKEND_RESULTS = ("ok", "failed")
TAR_SCHEDULES = ("daily", "full")
FORGET_RESULTS = ("ok", "failed", "refused")
TASK_RESULTS = ("ok", "failed")
RESTIC_TASKS = ("forget", "prune", "check")
HEX64 = re.compile(r"[0-9a-f]{64}")
RESTIC_SUMMARY_INTS = ("files_new", "files_changed", "files_unmodified", "data_added",
                       "data_added_packed", "total_files_processed", "total_bytes_processed")
RESTIC_STATS_INTS = ("total_size", "total_uncompressed_size", "snapshots_count",
                     "total_blob_count")
SUBSET_OK = re.compile(r"[0-9]{1,4}/[0-9]{1,4}|[0-9]{1,3}(\.[0-9]{1,2})?%")
RESTIC_JSON_MAX = 64 * 1024 * 1024

# x-backup limits (USAGE.md "Backup tiers").
XB_LISTS = ("exclude", "weekly")
XB_KEYS = XB_LISTS + ("retention",)
XB_RETENTION_KEYS = ("daily", "weekly", "monthly")
XB_MAX_ENTRIES = 64
XB_MAX_PATH = 255
XB_MAX_REASON = 200
XB_COMPONENT = re.compile(r"[A-Za-z0-9._-]+")

# Carry-forward guards. 2020-01-01T00:00:00Z is the floor; now + 1 day the ceiling.
TS_FLOOR = 1577836800
TS_SLACK = 86400
PREV_MAX_BYTES = 4 * 1024 * 1024
PREV_MAX_STACKS = 10000
EXEMPTIONS_MAX_BYTES = 1024 * 1024
COMPOSE_TIMEOUT_S = 60

LABEL_OK = re.compile(r"[A-Za-z0-9._-]+")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def clean(s):
    """A str that is safe in JSON for every consumer: undecodable bytes (surrogate
    escapes from os/argv) become U+FFFD, and nothing else changes."""
    if s is None:
        return None
    if isinstance(s, bytes):
        return s.decode("utf-8", "replace")
    return s.encode("utf-8", "surrogateescape").decode("utf-8", "replace")


def printable(s):
    """For diagnostics that bash will put in the log: control bytes become '?'."""
    return CONTROL.sub("?", clean(str(s)))


def diag(msg):
    print(printable(msg), file=sys.stderr)


def opt_int(s):
    """argv from bash: digits or empty. Anything else is None."""
    if s is None or not re.fullmatch(r"[0-9]{1,19}", s):
        return None
    return int(s)


def norm(p):
    """`realpath -m`-style normalisation without touching the filesystem: no symlink
    is followed, so nothing on the share or in appdata steers a decision."""
    return os.path.normpath(p) if p else p


def under(path, root):
    if root == "/":
        return path.startswith("/")
    return path == root or path.startswith(root.rstrip("/") + "/")


def roots_of(path):
    """The configured spelling and the resolved one. Resolving a configured root (the
    stack dir, APPDATA_PATH) is resolving config, not data: compose reports paths
    resolved from its working dir."""
    out = [norm(path)]
    try:
        real = os.path.realpath(path)
        if real not in out:
            out.append(real)
    except OSError:
        pass
    return out


#######################################
# record
#######################################
def cmd_record(argv):
    if len(argv) < 10:
        diag("record: expected 10 arguments")
        return 2
    path, name, result, reason, mode, archive, nbytes, started, finished, downtime = argv[:10]
    ap = argparse.ArgumentParser(prog="dsb_status.py record")
    ap.add_argument("--xbackup", default=None)
    ap.add_argument("--snapshot-backend", default="")
    ap.add_argument("--snapshot-used", default="")
    ap.add_argument("--snapshot-fallback", default="")
    ap.add_argument("--snapshot-s", default="")
    ap.add_argument("--snapshot-delete-failed", default="")
    ap.add_argument("--tar-result", default="")
    ap.add_argument("--restic-result", default="")
    ap.add_argument("--restic-reason", default="")
    ap.add_argument("--restic-summary", default="")
    ap.add_argument("--restic-s", default="")
    ap.add_argument("--forget-result", default="")
    ap.add_argument("--forget-file", default="")
    ap.add_argument("--retention", default="")
    opts = ap.parse_args(argv[10:])
    rec = {
        "name": clean(name),
        "result": result if result in RESULTS else "failed",
        "reason": reason if reason in REASONS else (None if not reason else "unknown"),
        "mode": mode if mode in MODES else None,
        "archive": clean(archive) or None,
        "bytes": opt_int(nbytes),
        "started": opt_int(started),
        "finished": opt_int(finished),
        "downtime_s": opt_int(downtime),
        "x_backup": None if opts.xbackup is None else read_xbackup_result(opts.xbackup),
        "snapshot": None,
        "backends": record_backends(opts, archive, nbytes),
    }
    if opts.snapshot_backend in SNAPSHOT_BACKENDS and opts.snapshot_backend != "none":
        fb = opts.snapshot_fallback
        rec["snapshot"] = {
            "backend": opts.snapshot_backend,
            "used": opts.snapshot_used == "1",
            "fallback_reason": fb if fb in FALLBACK_REASONS else (None if not fb else "unknown"),
            "snapshot_s": opt_int(opts.snapshot_s),
            "delete_failed": opts.snapshot_delete_failed == "1",
        }
    line = json.dumps(rec, ensure_ascii=True) + "\n"
    with open(path, "a", encoding="ascii") as f:
        f.write(line)
    return 0


def read_json_file(path, limit=RESTIC_JSON_MAX):
    """A JSON document the run itself wrote (helper output in its private temp dir).
    None if missing or unparsable."""
    if not path:
        return None
    try:
        with open(path, "rb") as f:
            data = f.read(limit + 1)
        if len(data) > limit:
            return None
        return json.loads(data)
    except (OSError, ValueError, RecursionError):
        return None


def read_restic_summary(path):
    """The `message_type: summary` line of restic backup --json (the last one)."""
    if not path:
        return None
    try:
        with open(path, "rb") as f:
            lines = f.read(RESTIC_JSON_MAX).splitlines()
    except OSError:
        return None
    for raw in reversed(lines):
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("message_type") == "summary":
            return d
    return None


def uint(v):
    return v if type(v) is int and v >= 0 else None


def record_backends(opts, archive, nbytes):
    """Per-backend results for this stack: only the backends that ran for it."""
    out = {}
    if opts.tar_result in BACKEND_RESULTS:
        out["tar"] = {"result": opts.tar_result, "archive": clean(archive) or None,
                      "bytes": opt_int(nbytes)}
    if opts.restic_result in BACKEND_RESULTS:
        r = {"result": opts.restic_result, "reason": None, "snapshot_id": None,
             "duration_s": opt_int(opts.restic_s), "forget": None}
        for k in ("files_new", "files_changed", "files_unmodified", "data_added"):
            r[k] = None
        if opts.restic_result == "failed":
            rr = opts.restic_reason
            r["reason"] = rr if rr in REASONS else "restic-backup-failed"
        summary = read_restic_summary(opts.restic_summary) if opts.restic_result == "ok" else None
        if summary is not None:
            sid = summary.get("snapshot_id")
            r["snapshot_id"] = sid if isinstance(sid, str) and HEX64.fullmatch(sid) else None
            for k in ("files_new", "files_changed", "files_unmodified", "data_added"):
                r[k] = uint(summary.get(k))
        if opts.forget_result in FORGET_RESULTS:
            f = {"result": opts.forget_result, "retention": None, "kept": None, "removed": None}
            parts = opts.retention.split()
            if len(parts) == 3 and all(re.fullmatch(r"[0-9]{1,4}", x) for x in parts):
                f["retention"] = dict(zip(XB_RETENTION_KEYS, (int(x) for x in parts)))
            groups = read_json_file(opts.forget_file) if opts.forget_result == "ok" else None
            if isinstance(groups, list):
                kept = removed = 0
                for g in groups:
                    if isinstance(g, dict):
                        kept += len(g.get("keep") or [])
                        removed += len(g.get("remove") or [])
                f["kept"], f["removed"] = kept, removed
            r["forget"] = f
        out["restic"] = r
    return out or None


def read_records(path):
    recs = []
    try:
        with open(path, "rb") as f:
            for raw in f:
                try:
                    r = json.loads(raw)
                except ValueError:
                    diag("records: unparsable line dropped")
                    continue
                if isinstance(r, dict) and isinstance(r.get("name"), str):
                    recs.append(r)
    except FileNotFoundError:
        pass
    return recs


#######################################
# Exemptions
#######################################
def load_exemptions(path):
    """Returns (entries, status, errors). The file is data: never sourced, never
    evaluated. A bad line is reported and skipped; it does not stop the backup."""
    entries, errors = [], []
    if not path:
        return entries, "missing", errors
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return entries, "missing", errors
    except OSError as e:
        errors.append({"line": 0, "error": "cannot stat: %s" % e.strerror})
        return entries, "config-error", errors
    if not stat.S_ISREG(st.st_mode):
        errors.append({"line": 0, "error": "not a regular file"})
        return entries, "config-error", errors
    if st.st_size > EXEMPTIONS_MAX_BYTES:
        errors.append({"line": 0, "error": "larger than %d bytes" % EXEMPTIONS_MAX_BYTES})
        return entries, "config-error", errors
    try:
        with open(path, "rb") as f:
            data = f.read(EXEMPTIONS_MAX_BYTES + 1)
    except OSError as e:
        errors.append({"line": 0, "error": "cannot read: %s" % e.strerror})
        return entries, "config-error", errors

    for n, raw in enumerate(data.split(b"\n"), 1):
        if raw.endswith(b"\r"):
            raw = raw[:-1]
        try:
            line = raw.decode("utf-8")
        except UnicodeDecodeError:
            errors.append({"line": n, "error": "not valid UTF-8"})
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if CONTROL.search(line):
            errors.append({"line": n, "error": "control character"})
            continue
        parts = line.split("|", 2)
        if len(parts) != 3:
            errors.append({"line": n, "error": "expected <kind>|<subject>|<reason>"})
            continue
        kind, subject, reason = (p.strip() for p in parts)
        if kind not in EXEMPTION_KINDS:
            errors.append({"line": n, "error": "unknown kind"})
            continue
        if not subject:
            errors.append({"line": n, "error": "empty subject"})
            continue
        if not reason:
            errors.append({"line": n, "error": "empty reason"})
            continue
        e = {"line": n, "kind": kind, "subject": subject, "reason": reason, "matched": 0}
        if kind == "mount":
            stack, sep, what = subject.partition(":")
            if not sep or not stack or not what:
                errors.append({"line": n, "error": "mount subject must be <stack>:<path> or <stack>:volume:<name>"})
                continue
            e["stack"] = stack
            if what.startswith("volume:") and what[len("volume:"):]:
                e["volume"] = what[len("volume:"):]
            elif what.startswith("/"):
                e["path"] = norm(what)
            else:
                errors.append({"line": n, "error": "mount target must be an absolute path or volume:<name>"})
                continue
        entries.append(e)
    return entries, ("config-error" if errors else "ok"), errors


def apply_exemptions(entries, stacks_cov, unowned):
    for st in stacks_cov:
        for item in st["coverage"]["items"]:
            if not item["alerting"]:
                continue
            for e in entries:
                hit = False
                if e["kind"] == "stack" and e["subject"] == st["name"]:
                    hit = True
                elif e["kind"] == "mount" and e["stack"] == st["name"]:
                    if "volume" in e:
                        hit = item["class"] == "named-volume" and item.get("source") == e["volume"]
                    else:
                        hit = item.get("type") == "bind" and item.get("source") == e["path"]
                if hit:
                    e["matched"] += 1
                    if item["exempt"] is None:
                        item["exempt"] = e["reason"]
    for u in unowned:
        for e in entries:
            if e["kind"] == "appdata" and e["subject"] == u["dir"]:
                e["matched"] += 1
                if u["exempt"] is None:
                    u["exempt"] = e["reason"]


#######################################
# Coverage classifier
#######################################
def compose_config(stack_path):
    """(config dict, None) or (None, first stderr line). Runs `docker compose config
    --format json`, which resolves ${VAR}, short and long volume syntax, extends, and
    relative paths. YAML is never parsed here."""
    env = dict(os.environ)
    env["PWD"] = stack_path
    try:
        p = subprocess.run(
            ["docker", "compose", "config", "--format", "json"],
            cwd=stack_path, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=COMPOSE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return None, "docker compose config timed out after %d s" % COMPOSE_TIMEOUT_S
    except OSError as e:
        return None, "cannot run docker compose config: %s" % e.strerror
    if p.returncode != 0:
        first = p.stderr.decode("utf-8", "replace").strip().splitlines()
        return None, printable(first[0] if first else "docker compose config exited %d" % p.returncode)
    try:
        cfg = json.loads(p.stdout)
    except ValueError:
        return None, "docker compose config printed no valid JSON"
    if not isinstance(cfg, dict) or not isinstance(cfg.get("services", {}), dict):
        return None, "docker compose config printed an unexpected shape"
    return cfg, None


#######################################
# x-backup: per-stack backup tiers (USAGE.md "Backup tiers")
#######################################
def xb_path_error(p):
    """None if p is a valid declared path, else why not. The value itself is never put
    in the message: it may be long or hold control bytes."""
    if not isinstance(p, str):
        return "must be a string"
    if not p:
        return "is empty"
    if len(p.encode("utf-8", "surrogateescape")) > XB_MAX_PATH:
        return "is longer than %d bytes" % XB_MAX_PATH
    if p.startswith("/"):
        return "must be relative to the stack's appdata dir (leading '/')"
    for c in p.split("/"):
        if not c:
            return "has an empty component ('//' or a trailing '/')"
        if c in (".", ".."):
            return "has a '.' or '..' component"
        if c.startswith("-"):
            return "has a component starting with '-'"
        if not XB_COMPONENT.fullmatch(c):
            return "may only use A-Z a-z 0-9 . _ - and '/' (no globs, no spaces)"
    return None


def xb_reason_error(r):
    if not isinstance(r, str):
        return "must be a string"
    if not r.strip():
        return "is empty"
    if len(r) > XB_MAX_REASON:
        return "is longer than %d characters" % XB_MAX_REASON
    if CONTROL.search(r):
        return "has a control character"
    return None


def parse_xbackup(block):
    """(declarations, retention, errors). declarations: [(tier, path, reason)]. Any
    error makes the whole block void: the caller backs the stack up in full."""
    errors = []
    decls = []
    retention = None
    if not isinstance(block, dict):
        return [], None, ["x-backup must be a mapping"]
    for k in block:
        if k not in XB_KEYS:
            errors.append("x-backup: unknown key %r" % printable(k)[:40])
    seen = {}
    for tier in XB_LISTS:
        if tier not in block:
            continue
        entries = block[tier]
        if not isinstance(entries, list):
            errors.append("x-backup.%s must be a list" % tier)
            continue
        if len(entries) > XB_MAX_ENTRIES:
            errors.append("x-backup.%s has more than %d entries" % (tier, XB_MAX_ENTRIES))
            continue
        for n, e in enumerate(entries):
            where = "x-backup.%s[%d]" % (tier, n)
            if not isinstance(e, dict):
                errors.append("%s must be a mapping with path and reason" % where)
                continue
            for k in e:
                if k not in ("path", "reason"):
                    errors.append("%s: unknown key %r" % (where, printable(k)[:40]))
            if "path" not in e or "reason" not in e:
                errors.append("%s needs both path and reason" % where)
                continue
            perr = xb_path_error(e["path"])
            if perr:
                errors.append("%s.path %s" % (where, perr))
            rerr = xb_reason_error(e["reason"])
            if rerr:
                errors.append("%s.reason %s" % (where, rerr))
            if perr or rerr:
                continue
            if e["path"] in seen:
                errors.append("%s.path is also declared in x-backup.%s" % (where, seen[e["path"]]))
                continue
            seen[e["path"]] = tier
            decls.append((tier, e["path"], e["reason"]))
    if "retention" in block:
        r = block["retention"]
        if not isinstance(r, dict):
            errors.append("x-backup.retention must be a mapping")
        else:
            retention = {}
            for k, v in r.items():
                if k not in XB_RETENTION_KEYS:
                    errors.append("x-backup.retention: unknown key %r" % printable(k)[:40])
                elif type(v) is not int or not 0 <= v <= 1000:
                    errors.append("x-backup.retention.%s must be an integer 0-1000" % k)
                else:
                    retention[k] = v
    if errors:
        return [], None, errors
    return decls, retention, []


def path_exists(stack_dir, rel):
    """True/False, or None when it cannot be told (an unreadable dir on the way)."""
    try:
        os.lstat(os.path.join(stack_dir, rel))
        return True
    except FileNotFoundError:
        return False
    except NotADirectoryError:
        return False
    except OSError:
        return None


def xbackup_for(cfg, cfg_err, stack_dir, run_kind):
    """The per-stack x_backup record and the paths to exclude this run.
    cfg is the `docker compose config` dict, or None with cfg_err set."""
    doc = {"status": "none", "errors": [], "run_kind": run_kind, "excluded": [],
           "stale": [], "retention": None}
    if cfg is None:
        doc["status"] = "unknown"
        doc["errors"] = [printable(cfg_err or "docker compose config failed")]
        return doc, []
    if "x-backup" not in cfg:
        return doc, []
    decls, retention, errors = parse_xbackup(cfg["x-backup"])
    if errors:
        doc["status"] = "config-error"
        doc["errors"] = errors
        return doc, []
    doc["status"] = "ok"
    doc["retention"] = retention
    paths = []
    for tier, path, reason in decls:
        exists = path_exists(stack_dir, path)
        if exists is False:
            doc["stale"].append(path)
        if tier == "exclude":
            action = "excluded"
        elif run_kind == "daily":
            action = "deferred"
        else:
            continue   # a weekly path on the full run is backed up
        doc["excluded"].append({"path": path, "reason": clean(reason), "tier": tier,
                                "action": action, "exists": exists})
        paths.append(path)
    return doc, paths


def read_xbackup_result(path):
    """The x_backup record xbackup wrote for this stack (our own file, in the run's
    private temp dir). Missing or unreadable: the reader failed, so the stack was backed
    up in full; say so rather than report "none"."""
    try:
        with open(path, "rb") as f:
            doc = json.loads(f.read(1024 * 1024))
        if isinstance(doc, dict) and doc.get("status") in ("none", "ok", "config-error", "unknown"):
            return doc
    except (OSError, ValueError):
        pass
    return {"status": "unknown", "errors": ["x-backup reader failed; backed up in full"],
            "run_kind": None, "excluded": [], "stale": [], "retention": None}


def cmd_retention(argv):
    """`retention <xbackup-file> <d> <w> <m>`: the stack's x-backup.retention, key by
    key, over the host defaults. Prints "d w m"."""
    if len(argv) != 4 or not all(re.fullmatch(r"[0-9]{1,4}", x) for x in argv[1:]):
        diag("retention: expected <xbackup-file> <daily> <weekly> <monthly>")
        return 2
    keep = dict(zip(XB_RETENTION_KEYS, (int(x) for x in argv[1:])))
    doc = read_xbackup_result(argv[0])
    r = doc.get("retention") if doc.get("status") == "ok" else None
    if isinstance(r, dict):
        for k in XB_RETENTION_KEYS:
            v = r.get(k)
            if type(v) is int and 0 <= v <= 1000:
                keep[k] = v
    print("%d %d %d" % (keep["daily"], keep["weekly"], keep["monthly"]))
    return 0


def cmd_xbackup(argv):
    ap = argparse.ArgumentParser(prog="dsb_status.py xbackup")
    ap.add_argument("--stack-path", required=True)
    ap.add_argument("--appdata-dir", required=True)
    ap.add_argument("--run-kind", required=True, choices=RUN_KINDS)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    cfg, err = compose_config(a.stack_path)
    doc, paths = xbackup_for(cfg, err, a.appdata_dir, a.run_kind)
    for e in doc["errors"]:
        diag("x-backup: %s" % e)
    with open(a.out, "w", encoding="ascii") as f:
        f.write(json.dumps(doc, ensure_ascii=True))
    out = sys.stdout.buffer
    for p in paths:
        out.write(p.encode("ascii") + b"\0")
    out.flush()
    return 0


def cmd_xbackup_describe(argv):
    """Human-readable lines for the dry run, from an xbackup result file."""
    if len(argv) != 1:
        diag("xbackup-describe: expected 1 argument")
        return 2
    doc = read_xbackup_result(argv[0])
    st = doc["status"]
    if st == "none":
        print("x-backup: none (backed up in full)")
    elif st == "ok":
        print("x-backup: ok (%s run)" % doc.get("run_kind"))
        for e in doc["excluded"]:
            print("  %s: %s — %s" % (e["action"], e["path"], printable(e["reason"])))
        for p in doc["stale"]:
            print("  stale (path does not exist): %s" % p)
        if not doc["excluded"]:
            print("  nothing left out this run")
    else:
        print("x-backup: %s — backed up in full" % st)
        for e in doc["errors"]:
            print("  %s" % printable(e))
    return 0


def classify_mount(m, ctx):
    """One service mount -> item dict (without service/exempt)."""
    mtype = m.get("type")
    source = m.get("source")
    ro = bool(m.get("read_only", False))
    item = {"type": clean(mtype) if isinstance(mtype, str) else None,
            "source": clean(source) if isinstance(source, str) else None,
            "target": clean(m.get("target")) if isinstance(m.get("target"), str) else None,
            "rw": not ro}

    if mtype == "tmpfs":
        item["class"] = "tmpfs"
        return item
    if mtype == "volume":
        item["class"] = "named-volume"
        vol = ctx["volumes"].get(source) if isinstance(source, str) else None
        if isinstance(vol, dict) and isinstance(vol.get("name"), str):
            item["volume_name"] = clean(vol["name"])
        if isinstance(vol, dict) and vol.get("external"):
            item["external"] = True
        return item
    if mtype != "bind" or not isinstance(source, str) or not source:
        item["class"] = "other"
        return item

    src = source if source.startswith("/") else os.path.join(ctx["stack_path"], source)
    src = norm(src)
    item["source"] = clean(src)
    stack = ctx["stack"]

    for root in ctx["appdata_roots"]:
        if under(src, root) and src != root:
            first = src[len(root.rstrip("/")) + 1:].split("/", 1)[0]
            if first == stack:
                item["class"] = "archived"
                return item
            item["class"] = "other-stack-appdata"
            item["other_stack"] = clean(first)
            return item
    for root in ctx["stack_roots"]:
        if under(src, root):
            # The archive takes only the compose file and .env from the stack dir. A
            # read-only bind there is config (git's job); a writable one is state the
            # container writes (./pgdata), which is in no backup (audit F-01).
            item["class"] = "stack-dir" if ro else "stack-dir-rw"
            return item
    for root in ctx["system_paths"]:
        if under(src, root):
            item["class"] = "system"
            return item
    item["class"] = "input-ro" if ro else "uncovered"
    return item


def classify_stack(stack_base, name, appdata_roots, system_paths, backed_up, known_stacks,
                   run_kind=None, appdata=None):
    """Coverage of one stack. backed_up: set of stacks backed up this run, or None in
    report mode (no run happened). With run_kind (report mode), the stack's x_backup
    record rides along under the "x_backup" key; finalize takes the one the run applied."""
    stack_path = os.path.join(stack_base, name)
    cfg, err = compose_config(stack_path)
    xb = None
    if run_kind is not None:
        xb, _ = xbackup_for(cfg, err, os.path.join(appdata, name), run_kind)
    if cfg is None:
        return {"status": "unknown", "error": err, "items": [], "x_backup": xb}
    ctx = {
        "stack": name,
        "stack_path": stack_path,
        "stack_roots": roots_of(stack_path),
        "appdata_roots": appdata_roots,
        "system_paths": system_paths,
        "volumes": cfg.get("volumes") if isinstance(cfg.get("volumes"), dict) else {},
    }
    items = []
    for svc in sorted(cfg.get("services", {})):
        spec = cfg["services"][svc]
        mounts = spec.get("volumes") if isinstance(spec, dict) else None
        if not isinstance(mounts, list):
            continue
        for m in mounts:
            if not isinstance(m, dict):
                continue
            item = classify_mount(m, ctx)
            item["service"] = clean(svc)
            cls = item["class"]
            if cls in ("uncovered", "named-volume", "stack-dir-rw"):
                item["alerting"] = True
            elif cls == "other-stack-appdata":
                other = item["other_stack"]
                if backed_up is None:
                    item["other_backed_up"] = None
                    item["alerting"] = other not in known_stacks
                else:
                    item["other_backed_up"] = other in backed_up
                    item["alerting"] = other not in backed_up
            else:
                item["alerting"] = False
            item["exempt"] = None
            items.append(item)
    return {"status": "ok", "error": None, "items": items, "x_backup": xb}


def unowned_appdata(appdata, known_stacks):
    """(dirs, error). Every directory in APPDATA_PATH whose name matches no stack.
    Regular files and symlinks are skipped (symlinks are not followed). If APPDATA_PATH
    cannot be listed, error says why: an unreadable area is "unknown", never an empty
    one. An entry that cannot be stat'ed is kept (with `error`), not dropped."""
    out = []
    try:
        entries = sorted(os.scandir(appdata), key=lambda e: e.name)
    except OSError as e:
        msg = "cannot list %s: %s" % (appdata, e.strerror)
        diag(msg)
        return out, printable(msg)
    for ent in entries:
        if ent.name in known_stacks:
            continue
        try:
            if not ent.is_dir(follow_symlinks=False):
                continue
        except OSError as e:
            out.append({"dir": clean(ent.name), "bytes": None, "estimate": True,
                        "exempt": None, "error": "cannot stat: %s" % e.strerror})
            continue
        nbytes, estimate = du_bytes(ent.path)
        out.append({"dir": clean(ent.name), "bytes": nbytes, "estimate": estimate,
                    "exempt": None})
    return out, None


def du_bytes(path):
    """lib.sh du_size, in python: (bytes, estimate). du still prints a total when it
    meets unreadable paths; that total is an estimate."""
    try:
        p = subprocess.run(["du", "-sb", "--", path], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=600)
    except (OSError, subprocess.TimeoutExpired):
        return None, True
    first = p.stdout.split(b"\t", 1)[0].strip()
    nbytes = int(first) if re.fullmatch(rb"[0-9]{1,19}", first) else None
    return nbytes, p.returncode != 0 or nbytes is None


def finish_stack_status(cov):
    if cov["status"] == "unknown":
        return
    if any(i["alerting"] and i["exempt"] is None for i in cov["items"]):
        cov["status"] = "uncovered"


def coverage_for(names, stack_base, appdata, ignore_paths, exemptions_file, backed_up,
                 run_kind=None):
    appdata_roots = roots_of(appdata)
    system_paths = list(SYSTEM_PATHS)
    for p in (ignore_paths or "").split(":"):
        if p.startswith("/"):
            system_paths.append(norm(p))
    known = set(names)
    per_stack = []
    for name in names:
        cov = classify_stack(stack_base, name, appdata_roots, system_paths, backed_up, known,
                             run_kind, appdata)
        xb = cov.pop("x_backup")
        entry = {"name": name, "coverage": cov}
        if run_kind is not None:
            entry["x_backup"] = xb
        per_stack.append(entry)
    unowned, unowned_error = unowned_appdata(appdata, known)
    entries, ex_status, ex_errors = load_exemptions(exemptions_file)
    apply_exemptions(entries, per_stack, unowned)
    for st in per_stack:
        finish_stack_status(st["coverage"])
    stale = [{"line": e["line"], "kind": e["kind"], "subject": clean(e["subject"])}
             for e in entries if e["matched"] == 0]
    for err in ex_errors:
        diag("coverage exemptions %s line %d: %s" % (exemptions_file, err["line"], err["error"]))
    for s in stale:
        diag("coverage exemption matched nothing (stale): line %d %s|%s"
             % (s["line"], s["kind"], s["subject"]))
    exemptions = {"file": clean(exemptions_file), "status": ex_status,
                  "errors": ex_errors, "stale": stale}
    if unowned_error:
        # Rides with the exemptions/summary so both callers carry it without a new
        # return value; coverage_summary turns it into status "unknown".
        exemptions["unowned_appdata_error"] = unowned_error
    return per_stack, unowned, exemptions


def coverage_summary(per_stack, unowned, exemptions, xbackup_errors=0):
    """xbackup_errors: stacks whose x-backup block was rejected (each was backed up in
    full). It outranks every other state, like an exemptions config error."""
    by_class = {}
    uncovered_items = 0
    stacks_uncovered = 0
    stacks_unknown = 0
    for st in per_stack:
        cov = st["coverage"]
        if cov["status"] == "unknown":
            stacks_unknown += 1
        if cov["status"] == "uncovered":
            stacks_uncovered += 1
        for i in cov["items"]:
            by_class[i["class"]] = by_class.get(i["class"], 0) + 1
            if i["alerting"] and i["exempt"] is None:
                uncovered_items += 1
    unowned_unexempt = sum(1 for u in unowned if u["exempt"] is None)
    unowned_error = exemptions.get("unowned_appdata_error")
    if exemptions["status"] == "config-error" or xbackup_errors:
        status = "config-error"
    elif stacks_unknown or unowned_error:
        status = "unknown"
    elif uncovered_items or unowned_unexempt:
        status = "uncovered"
    else:
        status = "ok"
    return {"status": status, "stacks_unknown": stacks_unknown,
            "stacks_uncovered": stacks_uncovered, "uncovered_items": uncovered_items,
            "unowned_appdata": len(unowned), "unowned_appdata_unexempt": unowned_unexempt,
            "unowned_appdata_status": "unknown" if unowned_error else "ok",
            "unowned_appdata_error": unowned_error,
            "xbackup_config_errors": xbackup_errors,
            "by_class": dict(sorted(by_class.items()))}


#######################################
# Carry-forward: the previous status.json is attacker input
#######################################
def valid_ts(v, now):
    # type() is int, not isinstance: bool is an int subclass, and `true` is not a time.
    return type(v) is int and TS_FLOOR <= v <= now + TS_SLACK


def read_share_json(path, what, limit=PREV_MAX_BYTES):
    """A JSON document from the backup share, or None. Any doubt means None, reported:
    the file is never an error that stops the run."""
    if not path:
        return None
    # Type check BEFORE open: open() on a device node runs the driver's open handler
    # (tape rewind, watchdog arming) before fstat could refuse it, and an NFS share
    # mounted without nodev resolves device nodes locally (audit F-02). Then fstat must
    # name the same inode, so a swap between lstat and open is refused too.
    try:
        lst = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as e:
        diag("%s ignored: cannot stat (%s)" % (what, e.strerror))
        return None
    if not stat.S_ISREG(lst.st_mode):
        diag("%s ignored: not a regular file" % what)
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as e:
        diag("%s ignored: cannot open (%s)" % (what, e.strerror))
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or (st.st_dev, st.st_ino) != (lst.st_dev, lst.st_ino):
            diag("%s ignored: not a regular file, or replaced while opening" % what)
            return None
        if st.st_size > limit:
            diag("%s ignored: larger than %d bytes" % (what, limit))
            return None
        with os.fdopen(fd, "rb", closefd=False) as f:
            data = f.read(limit + 1)
    except OSError as e:
        diag("%s ignored: cannot read (%s)" % (what, e.strerror))
        return None
    finally:
        os.close(fd)
    if len(data) > limit:
        diag("%s ignored: larger than %d bytes" % (what, limit))
        return None

    def no_constants(name):
        raise ValueError("non-finite number")

    try:
        return json.loads(data.decode("utf-8"), parse_constant=no_constants)
    except Exception:  # UnicodeDecodeError, ValueError, RecursionError, …
        diag("%s ignored: not valid UTF-8 JSON" % what)
        return None


def read_previous(path, host):
    """The previous status.json if it is ours (tool, schema, host), else None."""
    doc = read_share_json(path, "previous status file")
    if doc is None:
        return None
    if not isinstance(doc, dict) or doc.get("tool") != TOOL \
            or type(doc.get("schema")) is not int or doc.get("schema") != SCHEMA:
        diag("previous status file ignored: not a schema %d %s status file" % (SCHEMA, TOOL))
        return None
    if doc.get("host") != host:
        diag("previous status file ignored: written for another host")
        return None
    return doc


def previous_success(doc, now):
    """(last_success or None, {stack: last_success}) from a previous status doc. No value
    from it reaches anything but an integer range check."""
    if doc is None:
        return None, {}
    last = doc.get("last_success")
    if last is not None and not valid_ts(last, now):
        diag("previous status file: last_success rejected (not an integer time in range)")
        last = None

    stacks = {}
    m = doc.get("stack_last_success")
    if isinstance(m, dict) and len(m) <= PREV_MAX_STACKS:
        for k, v in m.items():
            if isinstance(k, str) and 0 < len(k) <= 255 and valid_ts(v, now):
                stacks[k] = v
            else:
                diag("previous status file: a stack_last_success entry was rejected")
    elif m is not None:
        diag("previous status file: stack_last_success rejected")
    return last, stacks


def previous_times(doc, now):
    """The carried last-success times added in 0.8.0: {"backend": {tar|restic: ts},
    "restic": {forget|prune|check: ts}}. Each value an integer time in range, or absent."""
    out = {"backend": {}, "restic": {}}
    if doc is None:
        return out
    bl = doc.get("backend_last_success")
    if isinstance(bl, dict):
        for b in BACKENDS:
            if valid_ts(bl.get(b), now):
                out["backend"][b] = bl[b]
    r = doc.get("restic")
    if isinstance(r, dict):
        for t in RESTIC_TASKS:
            task = r.get(t)
            if isinstance(task, dict) and valid_ts(task.get("last_success"), now):
                out["restic"][t] = task["last_success"]
    return out


def load_previous(path, host, now):
    """(last_success or None, {stack: last_success}). Any doubt means "no previous
    success": the file is never an error that stops the run, and no value from it
    reaches anything but an integer range check."""
    return previous_success(read_previous(path, host), now)


#######################################
# Writing
#######################################
# SECURITY[accepted]: O_NOFOLLOW covers the temp name only. A share writer who makes a
# directory above it a symlink (e.g. $BACKUP_DEST/$HOSTNAME) redirects this write, with a
# fixed name and non-secret content, into another directory. The archives, `mkdir -p`
# and the .incomplete files trust the same components; whoever can write the share is as
# trusted as root (USAGE.md, #1100). Audit: 2026-10-18/docker-stack-backup-2026-10-p3c-status-contract (F-05).
def atomic_write(path, tmp, data):
    """Write tmp in the same dir, then rename. O_EXCL|O_NOFOLLOW: a file or symlink
    planted at the temp name is never followed or reused. That covers the last path
    component only; the directories above it are trusted the same way the archives in
    them are (whoever can write the share is as trusted as root: USAGE.md). Mode 0644
    whatever the umask: names, sizes, paths; no secrets."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        fd = os.open(tmp, flags, 0o644)
    except FileExistsError:
        os.unlink(tmp)
        fd = os.open(tmp, flags, 0o644)
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "wb", closefd=False) as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:
        os.close(fd)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.close(fd)
    try:
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def is_real_dir(path):
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


#######################################
# Prometheus textfile
#######################################
class Prom:
    """Gauges in node_exporter textfile format. Series with the same labels are merged
    by `merge` (sum/min/max), so a `_invalid` stack label never duplicates a series."""

    def __init__(self):
        self.metrics = {}

    def add(self, name, helptext, labels, value, merge="sum"):
        m = self.metrics.setdefault(name, {"help": helptext, "series": {}})
        key = tuple(sorted(labels.items()))
        cur = m["series"].get(key)
        if cur is None:
            m["series"][key] = value
        elif merge == "sum":
            m["series"][key] = cur + value
        elif merge == "min":
            m["series"][key] = min(cur, value)
        else:
            m["series"][key] = max(cur, value)

    def render(self):
        out = []
        for name, m in self.metrics.items():
            out.append("# HELP %s %s" % (name, m["help"]))
            out.append("# TYPE %s gauge" % name)
            for key, value in m["series"].items():
                lbl = ",".join('%s="%s"' % (k, v) for k, v in key)
                out.append("%s{%s} %d" % (name, lbl, value))
        return ("\n".join(out) + "\n").encode("ascii")


def label(v):
    """A label value is a stack/host name or a fixed enum. Anything that would need
    escaping is reported as _invalid, never escaped."""
    return v if isinstance(v, str) and LABEL_OK.fullmatch(v) else "_invalid"


def build_prom(doc):
    p = Prom()
    host = label(doc["host"])
    h = {"host": host}
    if host == "_invalid":
        diag("hostname is not a valid metric label value; metrics use host=\"_invalid\"")
    p.add("dsb_build_info", "docker-stack-backup version that wrote this file.",
          dict(h, version=label(doc["version"])), 1)
    p.add("dsb_last_run_timestamp_seconds", "When the last run finished (Unix time).", h,
          doc["finished"] or 0)
    p.add("dsb_last_run_duration_seconds", "Duration of the last run.", h, doc["duration_s"] or 0)
    for o in OUTCOMES:
        p.add("dsb_last_run_outcome", "Outcome of the last run, one-hot.", dict(h, outcome=o),
              1 if doc["outcome"] == o else 0)
    p.add("dsb_last_success_timestamp_seconds",
          "Last run with no failed stack (Unix time), carried forward; 0 = never.", h,
          doc["last_success"] or 0)
    p.add("dsb_stacks_found", "Stacks with a compose file found by the last run.", h,
          doc["counts"]["found"])
    for r in RESULTS:
        p.add("dsb_stacks", "Stacks by result in the last run.", dict(h, result=r),
              doc["counts"][r])
    if doc.get("run_kind") in RUN_KINDS:
        for k in RUN_KINDS:
            p.add("dsb_last_run_kind", "Kind of the last run (daily or full), one-hot.",
                  dict(h, kind=k), 1 if doc["run_kind"] == k else 0)
    fallbacks = 0

    invalid = 0
    for s in doc["stacks"]:
        sl = label(s["name"])
        if sl == "_invalid":
            invalid += 1
        st = dict(h, stack=sl)
        p.add("dsb_stack_result", "1 per stack and result/reason in the last run.",
              dict(st, result=s["result"], reason=s["reason"] or "none"), 1)
        if s["bytes"] is not None:
            p.add("dsb_stack_archive_bytes", "Archive size written by the last run.", st,
                  s["bytes"])
        if s["downtime_s"] is not None:
            p.add("dsb_stack_downtime_seconds", "Stop-to-started time in the last run.", st,
                  s["downtime_s"], merge="max")
        cov = s.get("coverage")
        if cov is not None:
            counts = {}
            uncovered = 0
            for i in cov["items"]:
                counts[i["class"]] = counts.get(i["class"], 0) + 1
                if i["alerting"] and i["exempt"] is None:
                    uncovered += 1
            for c, n in sorted(counts.items()):
                p.add("dsb_coverage_items", "Service mounts by coverage class.",
                      dict(st, **{"class": c}), n)
            p.add("dsb_coverage_uncovered",
                  "Mounts holding state the archive does not cover, not exempt.", st, uncovered)
            p.add("dsb_coverage_unknown",
                  "1 if docker compose config failed, so coverage is unknown.", st,
                  1 if cov["status"] == "unknown" else 0)
        xb = s.get("x_backup")
        if isinstance(xb, dict):
            n = {"excluded": 0, "deferred": 0}
            for e in xb.get("excluded") or []:
                if e.get("action") in n:
                    n[e["action"]] += 1
            n["stale"] = len(xb.get("stale") or [])
            for state in ("excluded", "deferred", "stale"):
                p.add("dsb_stack_xbackup_paths",
                      "Declared x-backup paths: excluded, deferred (weekly tier on a daily run), stale (missing).",
                      dict(st, state=state), n[state])
            p.add("dsb_stack_xbackup_config_error",
                  "1 if the stack's x-backup block was rejected (backed up in full).", st,
                  1 if xb.get("status") == "config-error" else 0, merge="max")
        be = s.get("backends")
        if isinstance(be, dict):
            for b in BACKENDS:
                e = be.get(b)
                if isinstance(e, dict) and e.get("result") in BACKEND_RESULTS:
                    p.add("dsb_stack_backend_ok",
                          "1 if the backend succeeded for the stack in the last run, 0 if it failed; absent if it did not run.",
                          dict(st, backend=b), 1 if e["result"] == "ok" else 0, merge="min")
            r = be.get("restic")
            if isinstance(r, dict) and r.get("result") == "ok":
                for state in ("new", "changed", "unmodified"):
                    v = r.get("files_" + state)
                    if type(v) is int:
                        p.add("dsb_stack_restic_files",
                              "Files in the stack's last restic snapshot: new, changed or unmodified since its parent.",
                              dict(st, state=state), v)
                if type(r.get("data_added")) is int:
                    p.add("dsb_stack_restic_data_added_bytes",
                          "Data the stack's last restic backup added to the repository (uncompressed).",
                          st, r["data_added"])
                if type(r.get("duration_s")) is int:
                    p.add("dsb_stack_restic_duration_seconds",
                          "Duration of the stack's last restic backup.", st, r["duration_s"], merge="max")
        snap = s.get("snapshot")
        if isinstance(snap, dict):
            p.add("dsb_stack_snapshot_used",
                  "1 if the stack was archived from a snapshot in the last run.", st,
                  1 if snap.get("used") else 0, merge="min")
            if snap.get("fallback_reason"):
                fallbacks += 1
    if doc.get("snapshot_backend") in SNAPSHOT_BACKENDS and doc["snapshot_backend"] != "none":
        p.add("dsb_snapshot_fallbacks",
              "Stacks archived the old way (stop-archive-start) although a snapshot backend is set.",
              h, fallbacks)
        sc = doc.get("snapshot_cleanup") or {}
        p.add("dsb_snapshot_cleanup_failures",
              "Snapshot deletes that failed in the last run, +1 if its start-of-run sweep failed.",
              h, sc.get("failed") or 0)
        p.add("dsb_snapshot_leftovers_swept",
              "Leftover snapshots from earlier runs that the last run's sweep removed.",
              h, sc.get("swept") or 0)
    for b in doc.get("backends") or []:
        if b not in BACKENDS:
            continue
        p.add("dsb_backend_enabled", "1 per backend configured (BACKENDS).", dict(h, backend=b), 1)
        ran = doc.get("tar_ran") if b == "tar" else (doc.get("restic") or {}).get("ran")
        p.add("dsb_backend_ran", "1 if the backend was scheduled in the last run.",
              dict(h, backend=b), 1 if ran else 0)
        p.add("dsb_backend_last_success_timestamp_seconds",
              "Last run in which the backend ran and failed for no stack (Unix time), carried forward; 0 = never.",
              dict(h, backend=b), (doc.get("backend_last_success") or {}).get(b) or 0)
    rs = doc.get("restic")
    if isinstance(rs, dict):
        p.add("dsb_restic_repo_available",
              "1 if the restic repository could be used in the last run (no restic.problem).",
              h, 0 if rs.get("problem") else 1)
        for t in RESTIC_TASKS:
            task = rs.get(t) or {}
            p.add("dsb_restic_task_last_success_timestamp_seconds",
                  "Last successful restic forget/prune/check (Unix time), carried forward; 0 = never.",
                  dict(h, task=t), task.get("last_success") or 0)
            p.add("dsb_restic_task_failed", "1 if the restic task ran and failed in the last run.",
                  dict(h, task=t), 1 if task.get("result") == "failed" else 0)
        if isinstance(rs.get("orphan_stacks"), list):
            p.add("dsb_restic_orphan_stacks",
                  "Stacks with restic snapshots but no stack dir: their snapshots are never forgotten.",
                  h, len(rs["orphan_stacks"]))
        if type(rs.get("snapshots")) is int:
            p.add("dsb_restic_snapshots", "Snapshots of this host in the restic repository.", h,
                  rs["snapshots"])
        st_ = rs.get("stats") or {}
        if type(st_.get("total_size")) is int:
            p.add("dsb_restic_repo_bytes", "restic repository size (raw data, after compression).", h,
                  st_["total_size"])
        if type(st_.get("total_uncompressed_size")) is int:
            p.add("dsb_restic_repo_uncompressed_bytes",
                  "restic repository size before compression.", h, st_["total_uncompressed_size"])
    rv = doc.get("restore_verified")
    if isinstance(rv, dict):
        for b in BACKENDS:
            e = rv.get(b)
            if isinstance(e, dict) and type(e.get("time")) is int:
                p.add("dsb_restore_verified_timestamp_seconds",
                      "Last verified restore drill of the backend (Unix time), from restore-verified.json.",
                      dict(h, backend=b), e["time"])
    for name, ts in sorted(doc["stack_last_success"].items()):
        p.add("dsb_stack_last_success_timestamp_seconds",
              "Last successful backup of the stack (Unix time), carried forward.",
              dict(h, stack=label(name)), ts, merge="min")
    if invalid:
        diag("%d stack name(s) are not valid metric label values; reported as stack=\"_invalid\"" % invalid)

    unowned = doc.get("unowned_appdata") or []
    ex = doc.get("exemptions") or {}
    p.add("dsb_unowned_appdata_dirs", "Appdata dirs that match no stack.", h, len(unowned))
    p.add("dsb_unowned_appdata_unexempt", "Unowned appdata dirs with no exemption.", h,
          sum(1 for u in unowned if u["exempt"] is None))
    if doc.get("coverage") is not None:
        p.add("dsb_unowned_appdata_unknown",
              "1 if APPDATA_PATH could not be listed, so unowned appdata is unknown.", h,
              1 if doc["coverage"].get("unowned_appdata_status") == "unknown" else 0)
    p.add("dsb_exemptions_stale", "Exemption entries that matched nothing.", h,
          len(ex.get("stale") or []))
    p.add("dsb_exemptions_config_error", "1 if the exemptions file has rejected lines.", h,
          1 if ex.get("status") == "config-error" else 0)
    return p.render()


#######################################
# finalize
#######################################
def cmd_finalize(argv):
    ap = argparse.ArgumentParser(prog="dsb_status.py finalize")
    ap.add_argument("--records", required=True)
    ap.add_argument("--stack-base", required=True)
    ap.add_argument("--appdata", required=True)
    ap.add_argument("--exemptions", default="")
    ap.add_argument("--ignore-paths", default="")
    ap.add_argument("--status-file", default="")
    ap.add_argument("--run-dir", default="")
    ap.add_argument("--prom-dir", default="")
    ap.add_argument("--host", required=True)
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--started", required=True)
    ap.add_argument("--dest", default="")
    ap.add_argument("--aborted", default="")
    ap.add_argument("--run-kind", default="")
    ap.add_argument("--platform", default="")
    ap.add_argument("--snapshot-backend", default="")
    ap.add_argument("--snapshot-note", default="")
    ap.add_argument("--snapshot-cleanup-failed", default="")
    ap.add_argument("--snapshot-swept", default="")
    ap.add_argument("--backends", default="tar")
    ap.add_argument("--tar-schedule", default="daily")
    ap.add_argument("--tar-ran", default="")
    ap.add_argument("--restic-ran", default="")
    ap.add_argument("--restic-problem", default="")
    ap.add_argument("--restic-repo-id", default="")
    ap.add_argument("--restic-prune", default="")
    ap.add_argument("--restic-check", default="")
    ap.add_argument("--restic-check-subset", default="")
    ap.add_argument("--restic-snapshots", default="")
    ap.add_argument("--restic-stats", default="")
    ap.add_argument("--restore-verified", default="")
    a = ap.parse_args(argv)

    now = int(time.time())
    started = opt_int(a.started)
    host = clean(a.host)
    recs = read_records(a.records)
    aborted = a.aborted or None
    if aborted is not None and aborted not in ABORT_REASONS:
        aborted = "interrupted"

    prev_doc = read_previous(a.status_file, host)
    prev_last, prev_stacks = previous_success(prev_doc, now)
    prev_times = previous_times(prev_doc, now)

    counts = {"found": len(recs), "backed_up": 0, "skipped": 0, "failed": 0}
    for r in recs:
        counts[r["result"]] = counts.get(r["result"], 0) + 1
    if aborted:
        outcome = "aborted"
    elif counts["failed"] == 0:
        outcome = "success"
    elif counts["backed_up"] > 0:
        outcome = "partial"
    else:
        outcome = "failed"

    per_stack, unowned, exemptions = [], None, None
    if not aborted:
        names = [r["name"] for r in recs]
        backed = {r["name"] for r in recs if r["result"] == "backed_up"}
        per_stack, unowned, exemptions = coverage_for(
            names, a.stack_base, a.appdata, a.ignore_paths, a.exemptions, backed)
    cov_by_name = {s["name"]: s["coverage"] for s in per_stack}

    stacks = []
    stack_last = {}
    for r in recs:
        ls = r.get("finished") if r["result"] == "backed_up" else None
        if not valid_ts(ls, now):
            ls = prev_stacks.get(r["name"])
        if ls is not None:
            stack_last[r["name"]] = ls
        stacks.append({
            "name": r["name"], "result": r["result"], "reason": r.get("reason"),
            "mode": r.get("mode"), "archive": r.get("archive"), "bytes": r.get("bytes"),
            "started": r.get("started"), "finished": r.get("finished"),
            "downtime_s": r.get("downtime_s"), "last_success": ls,
            "coverage": cov_by_name.get(r["name"]),
            "x_backup": r.get("x_backup"), "snapshot": r.get("snapshot"),
            "backends": r.get("backends"),
        })
    xbackup_errors = sum(1 for s in stacks
                         if isinstance(s["x_backup"], dict) and s["x_backup"].get("status") == "config-error")
    if aborted:
        # The loop did not run (or did not finish): keep every stack's carried history,
        # or one aborted night would erase it.
        for k, v in prev_stacks.items():
            stack_last.setdefault(k, v)

    last_success = now if outcome == "success" else prev_last
    backends = [b for b in a.backends.split() if b in BACKENDS] or ["tar"]
    ran = {"tar": a.tar_ran == "true", "restic": a.restic_ran == "true"}
    backend_last = run_backend_last(stacks, backends, ran, aborted, now, prev_times)
    restic = run_restic(a, stacks, recs, aborted, now, prev_times) if "restic" in backends else None
    free = None
    if a.dest:
        try:
            sv = os.statvfs(a.dest)
            free = sv.f_bavail * sv.f_frsize
        except OSError:
            pass

    doc = {
        "schema": SCHEMA, "tool": TOOL, "version": clean(a.version),
        "host": host, "run_id": clean(a.run_id),
        "started": started, "finished": now,
        "duration_s": (now - started) if started is not None else None,
        "outcome": outcome, "abort_reason": aborted,
        "run_kind": a.run_kind if a.run_kind in RUN_KINDS else None,
        "platform": a.platform if a.platform in PLATFORMS else None,
        "snapshot_backend": a.snapshot_backend if a.snapshot_backend in SNAPSHOT_BACKENDS else None,
        "snapshot_note": printable(a.snapshot_note)[:200] or None,
        "snapshot_cleanup": ({"failed": opt_int(a.snapshot_cleanup_failed) or 0,
                              "swept": opt_int(a.snapshot_swept) or 0}
                             if a.snapshot_backend in ("btrfs", "zfs") else None),
        "backends": backends,
        "tar_schedule": a.tar_schedule if a.tar_schedule in TAR_SCHEDULES else None,
        "tar_ran": ran["tar"],
        "backend_last_success": backend_last,
        "restic": restic,
        "restore_verified": read_restore_verified(a.restore_verified, host, now),
        "counts": counts,
        "bytes_total": sum(s["bytes"] or 0 for s in stacks if s["result"] == "backed_up"),
        "dest": {"path": clean(a.dest), "free_bytes": free},
        "last_success": last_success,
        "stack_last_success": dict(sorted(stack_last.items())),
        "stacks": stacks,
        "unowned_appdata": unowned,
        "exemptions": exemptions,
        "coverage": (coverage_summary(per_stack, unowned, exemptions, xbackup_errors)
                     if exemptions else None),
    }

    rc = 0
    data = (json.dumps(doc, indent=1, ensure_ascii=True) + "\n").encode("ascii")
    if a.status_file:
        try:
            atomic_write(a.status_file, "%s.tmp.%d" % (a.status_file, os.getpid()), data)
        except OSError as e:
            diag("cannot write %s: %s" % (a.status_file, e.strerror))
            rc = 1
        # The run-dir copy is history for trends. Only if the dir survived the
        # rmdir-if-empty, and never created here (that would stop the rmdir).
        if a.run_dir and not aborted and is_real_dir(a.run_dir):
            target = os.path.join(a.run_dir, "status.json")
            try:
                atomic_write(target, "%s.tmp.%d" % (target, os.getpid()), data)
            except OSError as e:
                diag("cannot write %s: %s" % (target, e.strerror))
                rc = 1
    if a.prom_dir:
        target = os.path.join(a.prom_dir, "docker_stack_backup.prom")
        try:
            # The temp name must not end in .prom: collectors read every *.prom.
            atomic_write(target, "%s.%d" % (target, os.getpid()), build_prom(doc))
        except OSError as e:
            diag("cannot write %s: %s" % (target, e.strerror))
            rc = 1

    cov = doc["coverage"]
    if cov is not None:
        print("Coverage: %s — %d uncovered item(s), %d stack(s) unknown, %d unowned appdata "
              "dir(s) (%d not exempt), %d stale exemption(s)"
              % (cov["status"], cov["uncovered_items"], cov["stacks_unknown"],
                 cov["unowned_appdata"], cov["unowned_appdata_unexempt"],
                 len(exemptions["stale"])))
        if xbackup_errors:
            print("x-backup: %d stack(s) with an invalid x-backup block, backed up in full"
                  % xbackup_errors)
    return rc


def run_backend_last(stacks, backends, ran, aborted, now, prev_times):
    """Per backend: now if it ran this run and failed for no stack (and the run was not
    aborted), else carried forward from the previous status.json."""
    out = {}
    for b in backends:
        last = prev_times["backend"].get(b)
        if ran.get(b) and not aborted:
            failed = any(isinstance(s.get("backends"), dict)
                         and isinstance(s["backends"].get(b), dict)
                         and s["backends"][b].get("result") == "failed" for s in stacks)
            if not failed:
                last = now
        out[b] = last
    return out


def restic_task(result, last, now, extra=None):
    doc = {"result": result, "last_success": now if result == "ok" else last}
    if extra:
        doc.update(extra)
    return doc


def orphan_stacks(snapshots, names):
    """Stacks with dsb snapshots in the repository and no compose dir any more: their
    snapshots are never forgotten (nothing forgets an absent tag). Reported, not deleted."""
    if not isinstance(snapshots, list):
        return None
    seen = set()
    for snap in snapshots:
        tags = snap.get("tags") if isinstance(snap, dict) else None
        if not isinstance(tags, list):
            continue
        for t in tags:
            if isinstance(t, str) and t.startswith("stack:"):
                n = t[len("stack:"):]
                if LABEL_OK.fullmatch(n):
                    seen.add(n)
    return sorted(seen - set(names))


def run_restic(a, stacks, recs, aborted, now, prev_times):
    """The run-level restic record: repository, forget/prune/check with carried
    last-success times, orphan stacks, stats."""
    prev = prev_times["restic"]
    problem = a.restic_problem if a.restic_problem in RESTIC_PROBLEMS else (
        "restic-repo-error" if a.restic_problem else None)
    # forget: every stack whose restic backup succeeded runs one; ok only if all did.
    forgets = [s["backends"]["restic"]["forget"] for s in stacks
               if isinstance(s.get("backends"), dict) and isinstance(s["backends"].get("restic"), dict)
               and isinstance(s["backends"]["restic"].get("forget"), dict)]
    if not forgets:
        f_result = None
    elif all(f.get("result") == "ok" for f in forgets):
        f_result = "ok"
    else:
        f_result = "failed"
    if aborted and f_result == "ok":
        f_result = None   # an interrupted run did not forget for every stack
    forget = restic_task(f_result, prev.get("forget"), now,
                         {"stacks": len(forgets),
                          "failed": sum(1 for f in forgets if f.get("result") != "ok")})
    prune = restic_task(a.restic_prune if a.restic_prune in TASK_RESULTS else None,
                        prev.get("prune"), now)
    check = restic_task(a.restic_check if a.restic_check in TASK_RESULTS else None,
                        prev.get("check"), now,
                        {"subset": a.restic_check_subset
                         if SUBSET_OK.fullmatch(a.restic_check_subset or "") else None})
    snaps = None if aborted else read_json_file(a.restic_snapshots)
    orphans = orphan_stacks(snaps, [r["name"] for r in recs]) if not aborted else None
    stats_doc = None if aborted else read_json_file(a.restic_stats)
    stats = None
    if isinstance(stats_doc, dict):
        stats = {k: uint(stats_doc.get(k)) for k in RESTIC_STATS_INTS}
    repo_id = a.restic_repo_id if HEX64.fullmatch(a.restic_repo_id or "") else None
    return {
        "ran": a.restic_ran == "true",
        "repo_id": repo_id,
        "problem": problem,
        "forget": forget, "prune": prune, "check": check,
        "orphan_stacks": orphans,
        "snapshots": len(snaps) if isinstance(snaps, list) else None,
        "stats": stats,
    }


#######################################
# restore-verified (tests/host/restore-drill.sh)
#######################################
RV_MAX_REF = 300
RV_MAX_VERSION = 32


def restore_verified_entries(doc, now):
    """The valid per-backend entries of a restore-verified.json document."""
    out = {}
    if not isinstance(doc, dict):
        return out
    b = doc.get("backends")
    if not isinstance(b, dict):
        return out
    for name in BACKENDS:
        e = b.get(name)
        if not isinstance(e, dict) or not valid_ts(e.get("time"), now):
            continue
        version = e.get("version")
        ref = e.get("ref")
        out[name] = {
            "time": e["time"],
            "version": printable(version)[:RV_MAX_VERSION] if isinstance(version, str) else None,
            "ref": printable(ref)[:RV_MAX_REF] if isinstance(ref, str) else None,
        }
    return out


# SECURITY[accepted]: anyone who can write the share can forge restore-verified.json and so
# make dsb_restore_verified_timestamp_seconds show a fresh drill. The share is a root trust
# boundary already (USAGE.md, vikunja#1100); this reader only bounds what such a file can
# put into status.json. Do not read the metric as tamper-evident. Audit:
# 2026-10-23/docker-stack-backup-2026-10-p5b-restic-backend (F-06).
def read_restore_verified(path, host, now):
    """restore-verified.json from the share: untrusted input, like the previous
    status.json. Only well-formed entries are carried, each value bounded and printable."""
    doc = read_share_json(path, "restore-verified file", limit=64 * 1024)
    if doc is None:
        return None
    if not isinstance(doc, dict) or doc.get("tool") != TOOL or doc.get("host") != host:
        diag("restore-verified file ignored: not ours, or written for another host")
        return None
    return restore_verified_entries(doc, now) or None


def cmd_restic_snapshots(argv):
    """`restic-snapshots <file>`: the helper's `snapshots` JSON as
    stack<TAB>id<TAB>time<TAB>kind lines, newest first, for the restore wizard. The
    repository is on the share: a tag or id that is not well-formed drops the snapshot."""
    if len(argv) != 1:
        diag("restic-snapshots: expected 1 argument")
        return 2
    doc = read_json_file(argv[0])
    if not isinstance(doc, list):
        diag("restic-snapshots: not a JSON list")
        return 1
    rows = []
    for snap in doc:
        if not isinstance(snap, dict):
            continue
        sid, t, tags = snap.get("id"), snap.get("time"), snap.get("tags")
        if not (isinstance(sid, str) and HEX64.fullmatch(sid) and isinstance(t, str)
                and isinstance(tags, list)):
            continue
        stacks = [x[6:] for x in tags if isinstance(x, str) and x.startswith("stack:")]
        kinds = [x[5:] for x in tags if isinstance(x, str) and x.startswith("kind:")]
        if len(stacks) != 1 or not LABEL_OK.fullmatch(stacks[0]) or stacks[0] in (".", ".."):
            continue
        kind = kinds[0] if len(kinds) == 1 and kinds[0] in RUN_KINDS else "?"
        when = printable(t)[:19].replace("T", " ")
        rows.append((t, stacks[0], sid, when, kind))
    rows.sort(key=lambda r: r[0], reverse=True)
    for _, stack, sid, when, kind in rows:
        print("%s\t%s\t%s\t%s" % (stack, sid, when, kind))
    return 0


def cmd_restore_verified(argv):
    ap = argparse.ArgumentParser(prog="dsb_status.py restore-verified")
    ap.add_argument("--file", required=True)
    ap.add_argument("--backend", required=True, choices=BACKENDS)
    ap.add_argument("--host", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--ref", required=True)
    a = ap.parse_args(argv)
    now = int(time.time())
    host = clean(a.host)
    prev = read_share_json(a.file, "restore-verified file", limit=64 * 1024)
    entries = {}
    if isinstance(prev, dict) and prev.get("tool") == TOOL and prev.get("host") == host:
        entries = restore_verified_entries(prev, now)
    entries[a.backend] = {"time": now, "version": printable(a.version)[:RV_MAX_VERSION],
                          "ref": printable(a.ref)[:RV_MAX_REF]}
    doc = {"schema": SCHEMA, "tool": TOOL, "host": host, "backends": entries}
    data = (json.dumps(doc, indent=1, ensure_ascii=True) + "\n").encode("ascii")
    try:
        atomic_write(a.file, "%s.tmp.%d" % (a.file, os.getpid()), data)
    except OSError as e:
        diag("cannot write %s: %s" % (a.file, e.strerror))
        return 1
    return 0


#######################################
# coverage-report
#######################################
def cmd_coverage_report(argv):
    ap = argparse.ArgumentParser(prog="dsb_status.py coverage-report")
    ap.add_argument("--stack-base", required=True)
    ap.add_argument("--appdata", required=True)
    ap.add_argument("--exemptions", default="")
    ap.add_argument("--ignore-paths", default="")
    ap.add_argument("--run-kind", default="daily", choices=RUN_KINDS)
    ap.add_argument("stacks", nargs="*")
    a = ap.parse_args(argv)
    names = [clean(n) for n in a.stacks]
    per_stack, unowned, exemptions = coverage_for(
        names, a.stack_base, a.appdata, a.ignore_paths, a.exemptions, None, a.run_kind)
    xbackup_errors = sum(1 for s in per_stack if s["x_backup"]["status"] == "config-error")
    doc = {"schema": SCHEMA, "tool": TOOL, "stack_base": clean(a.stack_base),
           "appdata": clean(a.appdata), "run_kind": a.run_kind, "stacks": per_stack,
           "unowned_appdata": unowned, "exemptions": exemptions,
           "summary": coverage_summary(per_stack, unowned, exemptions, xbackup_errors)}
    json.dump(doc, sys.stdout, indent=1, ensure_ascii=True)
    sys.stdout.write("\n")
    return 0


def main():
    if len(sys.argv) < 2:
        diag("usage: dsb_status.py record|finalize|coverage-report|xbackup ...")
        return 2
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "record":
        return cmd_record(rest)
    if cmd == "finalize":
        return cmd_finalize(rest)
    if cmd == "coverage-report":
        return cmd_coverage_report(rest)
    if cmd == "xbackup":
        return cmd_xbackup(rest)
    if cmd == "xbackup-describe":
        return cmd_xbackup_describe(rest)
    if cmd == "retention":
        return cmd_retention(rest)
    if cmd == "restore-verified":
        return cmd_restore_verified(rest)
    if cmd == "restic-snapshots":
        return cmd_restic_snapshots(rest)
    diag("unknown command")
    return 2


if __name__ == "__main__":
    sys.exit(main())
