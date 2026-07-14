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
