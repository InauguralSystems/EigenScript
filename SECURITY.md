# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in EigenScript, please report it responsibly.

**Email**: InauguralPhysicist@gmail.com

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

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.5.x   | Yes      |
