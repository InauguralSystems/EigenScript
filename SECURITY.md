# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in EigenScript, please report it responsibly.

**Email**: InauguralPhysicist@gmail.com

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact

We will acknowledge receipt within 48 hours and aim to provide a fix or mitigation within 7 days for critical issues.

## Scope

EigenScript is a programming language runtime. Security-relevant areas include:
- Buffer overflows or memory corruption in the C runtime
- Command injection via `exec_capture`
- Path traversal in file I/O builtins
- HTTP server vulnerabilities (extension build)

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.5.x   | Yes      |
