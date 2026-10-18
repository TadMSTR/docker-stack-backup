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
    "archive-failed", "restart-failed",
)
MODES = ("running", "stopped")
OUTCOMES = ("success", "partial", "failed", "aborted")
ABORT_REASONS = (
    "not-privileged", "invalid-config", "lock-held", "preflight-failed", "interrupted",
)
CLASSES = (
    "archived", "other-stack-appdata", "stack-dir", "system", "input-ro", "uncovered",
    "named-volume", "tmpfs", "other",
)
SYSTEM_PATHS = (
    "/var/run", "/run", "/proc", "/sys", "/dev", "/etc/localtime", "/etc/timezone",
    "/lib/modules",
)
EXEMPTION_KINDS = ("stack", "mount", "appdata")

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
    if len(argv) != 10:
        diag("record: expected 10 arguments")
        return 2
    path, name, result, reason, mode, archive, nbytes, started, finished, downtime = argv
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
    }
    line = json.dumps(rec, ensure_ascii=True) + "\n"
    with open(path, "a", encoding="ascii") as f:
        f.write(line)
    return 0


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
            item["class"] = "stack-dir"
            return item
    for root in ctx["system_paths"]:
        if under(src, root):
            item["class"] = "system"
            return item
    item["class"] = "input-ro" if ro else "uncovered"
    return item


def classify_stack(stack_base, name, appdata_roots, system_paths, backed_up, known_stacks):
    """Coverage of one stack. backed_up: set of stacks backed up this run, or None in
    report mode (no run happened)."""
    stack_path = os.path.join(stack_base, name)
    cfg, err = compose_config(stack_path)
    if cfg is None:
        return {"status": "unknown", "error": err, "items": []}
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
            if cls in ("uncovered", "named-volume"):
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
    return {"status": "ok", "error": None, "items": items}


def unowned_appdata(appdata, known_stacks):
    """Every directory in APPDATA_PATH whose name matches no stack. Regular files and
    symlinks are skipped (symlinks are not followed)."""
    out = []
    try:
        entries = sorted(os.scandir(appdata), key=lambda e: e.name)
    except OSError as e:
        diag("cannot list %s: %s" % (appdata, e.strerror))
        return out
    for ent in entries:
        try:
            if not ent.is_dir(follow_symlinks=False):
                continue
        except OSError:
            continue
        if ent.name in known_stacks:
            continue
        nbytes, estimate = du_bytes(ent.path)
        out.append({"dir": clean(ent.name), "bytes": nbytes, "estimate": estimate,
                    "exempt": None})
    return out


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


def coverage_for(names, stack_base, appdata, ignore_paths, exemptions_file, backed_up):
    appdata_roots = roots_of(appdata)
    system_paths = list(SYSTEM_PATHS)
    for p in (ignore_paths or "").split(":"):
        if p.startswith("/"):
            system_paths.append(norm(p))
    known = set(names)
    per_stack = []
    for name in names:
        per_stack.append({"name": name, "coverage": classify_stack(
            stack_base, name, appdata_roots, system_paths, backed_up, known)})
    unowned = unowned_appdata(appdata, known)
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
    return per_stack, unowned, exemptions


def coverage_summary(per_stack, unowned, exemptions):
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
    if exemptions["status"] == "config-error":
        status = "config-error"
    elif stacks_unknown:
        status = "unknown"
    elif uncovered_items or unowned_unexempt:
        status = "uncovered"
    else:
        status = "ok"
    return {"status": status, "stacks_unknown": stacks_unknown,
            "stacks_uncovered": stacks_uncovered, "uncovered_items": uncovered_items,
            "unowned_appdata": len(unowned), "unowned_appdata_unexempt": unowned_unexempt,
            "by_class": dict(sorted(by_class.items()))}


#######################################
# Carry-forward: the previous status.json is attacker input
#######################################
def valid_ts(v, now):
    # type() is int, not isinstance: bool is an int subclass, and `true` is not a time.
    return type(v) is int and TS_FLOOR <= v <= now + TS_SLACK


def load_previous(path, host, now):
    """(last_success or None, {stack: last_success}). Any doubt means "no previous
    success": the file is never an error that stops the run, and no value from it
    reaches anything but an integer range check."""
    if not path:
        return None, {}
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None, {}
    except OSError as e:
        diag("previous status file ignored: cannot open (%s)" % e.strerror)
        return None, {}
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            diag("previous status file ignored: not a regular file")
            return None, {}
        if st.st_size > PREV_MAX_BYTES:
            diag("previous status file ignored: larger than %d bytes" % PREV_MAX_BYTES)
            return None, {}
        with os.fdopen(fd, "rb", closefd=False) as f:
            data = f.read(PREV_MAX_BYTES + 1)
    except OSError as e:
        diag("previous status file ignored: cannot read (%s)" % e.strerror)
        return None, {}
    finally:
        os.close(fd)
    if len(data) > PREV_MAX_BYTES:
        diag("previous status file ignored: larger than %d bytes" % PREV_MAX_BYTES)
        return None, {}

    def no_constants(name):
        raise ValueError("non-finite number")

    try:
        doc = json.loads(data.decode("utf-8"), parse_constant=no_constants)
    except Exception:  # UnicodeDecodeError, ValueError, RecursionError, …
        diag("previous status file ignored: not valid UTF-8 JSON")
        return None, {}
    if not isinstance(doc, dict) or doc.get("tool") != TOOL \
            or type(doc.get("schema")) is not int or doc.get("schema") != SCHEMA:
        diag("previous status file ignored: not a schema %d %s status file" % (SCHEMA, TOOL))
        return None, {}
    if doc.get("host") != host:
        diag("previous status file ignored: written for another host")
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


#######################################
# Writing
#######################################
def atomic_write(path, tmp, data):
    """Write tmp in the same dir, then rename. O_EXCL|O_NOFOLLOW: a name planted on
    the share is never followed. Mode 0644 whatever the umask: names, sizes, paths;
    no secrets."""
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
    a = ap.parse_args(argv)

    now = int(time.time())
    started = opt_int(a.started)
    host = clean(a.host)
    recs = read_records(a.records)
    aborted = a.aborted or None
    if aborted is not None and aborted not in ABORT_REASONS:
        aborted = "interrupted"

    prev_last, prev_stacks = load_previous(a.status_file, host, now)

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
        })
    if aborted:
        # The loop did not run (or did not finish): keep every stack's carried history,
        # or one aborted night would erase it.
        for k, v in prev_stacks.items():
            stack_last.setdefault(k, v)

    last_success = now if outcome == "success" else prev_last
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
        "counts": counts,
        "bytes_total": sum(s["bytes"] or 0 for s in stacks if s["result"] == "backed_up"),
        "dest": {"path": clean(a.dest), "free_bytes": free},
        "last_success": last_success,
        "stack_last_success": dict(sorted(stack_last.items())),
        "stacks": stacks,
        "unowned_appdata": unowned,
        "exemptions": exemptions,
        "coverage": coverage_summary(per_stack, unowned, exemptions) if exemptions else None,
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
    return rc


#######################################
# coverage-report
#######################################
def cmd_coverage_report(argv):
    ap = argparse.ArgumentParser(prog="dsb_status.py coverage-report")
    ap.add_argument("--stack-base", required=True)
    ap.add_argument("--appdata", required=True)
    ap.add_argument("--exemptions", default="")
    ap.add_argument("--ignore-paths", default="")
    ap.add_argument("stacks", nargs="*")
    a = ap.parse_args(argv)
    names = [clean(n) for n in a.stacks]
    per_stack, unowned, exemptions = coverage_for(
        names, a.stack_base, a.appdata, a.ignore_paths, a.exemptions, None)
    doc = {"schema": SCHEMA, "tool": TOOL, "stack_base": clean(a.stack_base),
           "appdata": clean(a.appdata), "stacks": per_stack, "unowned_appdata": unowned,
           "exemptions": exemptions,
           "summary": coverage_summary(per_stack, unowned, exemptions)}
    json.dump(doc, sys.stdout, indent=1, ensure_ascii=True)
    sys.stdout.write("\n")
    return 0


def main():
    if len(sys.argv) < 2:
        diag("usage: dsb_status.py record|finalize|coverage-report ...")
        return 2
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "record":
        return cmd_record(rest)
    if cmd == "finalize":
        return cmd_finalize(rest)
    if cmd == "coverage-report":
        return cmd_coverage_report(rest)
    diag("unknown command")
    return 2


if __name__ == "__main__":
    sys.exit(main())
