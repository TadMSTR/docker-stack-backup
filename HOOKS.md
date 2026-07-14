# Post-Restart Hooks

`POST_RESTART_HOOKS` lets you run custom logic after each stack's containers are
restarted at the end of its backup. This is useful for deployment-specific fixups that
must run once the containers are back up — for example, correcting file ownership that a
container resets on start, or nudging a dependent service.

## How it works

Set `POST_RESTART_HOOKS` in `config.sh` to an array of **shell function names** (defined
in `config.sh`) or **command names**. After a stack backs up and its containers restart
successfully, each entry is invoked as:

```
<hook> <stack_name> <stack_path>
```

- `stack_name` — the stack directory name (e.g. `nextcloud`)
- `stack_path` — the full path to the stack directory

Hooks run in array order. A hook that exits non-zero (or does not exist) is **logged as
a warning and does not abort the backup** — a broken hook must never fail an otherwise
successful run. Hooks fire only in the automated `docker-stack-backup.sh` run.

## Example: fix ownership after restart

Some services `chown` their data directory to an internal UID on start, which can break
a subsequent restore if the host expects a different owner. A hook can normalize it:

```bash
# --- in config.sh ---

APPDATA_PATH="/opt/appdata"

fix_valkey_ownership() {
    local stack_name="$1"
    local stack_path="$2"

    # Only act on the stack we care about
    [[ "$stack_name" == "myapp" ]] || return 0

    chown -R 999:999 "$APPDATA_PATH/$stack_name/valkey"
}

POST_RESTART_HOOKS=(fix_valkey_ownership)
```

## Example: multiple hooks

```bash
notify_dependent() {
    local stack_name="$1"
    curl -fsS -X POST "http://127.0.0.1:8080/reload?stack=$stack_name" >/dev/null
}

touch_healthcheck() {
    local stack_name="$1"
    touch "/var/run/backup-done-$stack_name"
}

POST_RESTART_HOOKS=(notify_dependent touch_healthcheck)
```

## Notes

- Each entry is invoked as a single command/function name — arguments are supplied by
  the backup (`stack_name`, `stack_path`), not baked into the array entry. If you need
  arguments, wrap the logic in a function.
- Hooks run with the same privileges as the backup script. Keep them minimal and treat
  them as trusted code (they live in your root-readable `config.sh`).
- Empty-string entries are skipped.
