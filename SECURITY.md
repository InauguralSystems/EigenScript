# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in EigenScript, please report it responsibly.

**Email**: contact@inauguralsystems.com
**Subject prefix**: `[SECURITY]`

Please do not file public GitHub issues for suspected vulnerabilities.
Security reports are triaged before general support mail.

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact

We will acknowledge receipt within 48 hours and aim to provide a fix or mitigation within 7 days for critical issues.

## Threat Model

EigenScript treats the **script author as trusted**. A `.eigs` file is
equivalent to running a shell script or a Python program: it can read and
write files, spawn subprocesses via `exec_capture`, open network sockets, and
access any data the host user can access. Running an untrusted `.eigs` file is
not a supported use case, and file-system or process access from a script is
not, on its own, a vulnerability.

The runtime is responsible for protecting the **host and remote callers** from
bugs in the interpreter itself and from malicious **external** input.

## Scope

In-scope security issues:
- Buffer overflows or memory corruption in the C runtime, triggerable by
  attacker-controlled input (malformed source, crafted HTTP requests, malicious
  model files, etc.).
- Command injection where untrusted data reaches a shell via a runtime
  builtin. (`exec_capture` uses `execvp` with an argv list and does not invoke
  a shell; injection there would be a bug.)
- HTTP server vulnerabilities in the extension build: request-parsing bugs,
  path traversal out of the configured `static_dir`, response splitting,
  unbounded resource consumption.
- Deserialization flaws in `model_io` when loading untrusted weight files.
- SQL injection in the DB extension's own code paths. (Callers that
  concatenate untrusted data into SQL via the `db_query*` string argument are
  responsible for parameterising their own queries.)

Out of scope:
- Anything an EigenScript program can already do by virtue of running on the
  host (reading `~/.ssh/id_rsa`, deleting files, etc.). If the threat is
  "malicious script", the fix is "do not run malicious scripts".
- **The destination of an outbound request.** `http_get`/`http_post` check only
  that the URL is `http://` or `https://` and is not a curl option; there is no
  loopback, link-local, or private-range blocklist. A script that builds a URL
  out of request data is therefore an SSRF pivot — reaching `127.0.0.1` or
  `169.254.169.254` is the script's decision, and the script is trusted.
  Stated explicitly because the transport side *is* guarded (`--proto` and
  `--proto-redir` are pinned to `http,https`, which closes `file://` via
  redirect), and a half-guarded client invites the assumption that the
  destination is guarded too. **If you write a route that forwards a
  client-supplied URL, you must validate the destination yourself.**

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.33.x  | Yes      |
| < 0.33  | No       |

## Contact Routing

All project contact uses `contact@inauguralsystems.com`. Use one of these
subject prefixes so reports can be triaged quickly:

- `[SECURITY]` Vulnerabilities or suspected security issues
- `[BUG]` Reproducible EigenScript bugs
- `[SUPPORT]` Installation, usage, or release questions
- `[PRESS]` Media, interviews, or public inquiries
- `[LEGAL]` Licensing or trademark questions
