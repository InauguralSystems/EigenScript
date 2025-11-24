# Security Policy

## Supported Versions

EigenScript is currently in alpha development. Security updates are provided for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1.0 | :x:                |

## Security Considerations

EigenScript is an **experimental alpha language** and should **NOT** be used for:
- Production systems
- Critical infrastructure
- Security-sensitive applications
- Processing untrusted user input in production environments

### Known Security Limitations

1. **Sandboxing**: EigenScript does not currently provide sandboxing for code execution. Malicious code can access the filesystem and system resources.

2. **Input Validation**: While basic input validation exists, comprehensive security hardening for untrusted input is not yet implemented.

3. **Resource Limits**: No built-in resource limits (CPU, memory, recursion depth) beyond Python's defaults.

4. **File I/O**: File operations have access to the entire filesystem based on the running process's permissions.

## Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security issue, please report it responsibly:

### How to Report

**Email**: [inauguralphysicist@gmail.com](mailto:inauguralphysicist@gmail.com)

**Subject Line**: `[SECURITY] Brief description of the issue`

### What to Include

Please include the following information in your report:

1. **Description**: Clear description of the vulnerability
2. **Impact**: What could an attacker achieve?
3. **Steps to Reproduce**: Detailed steps to reproduce the issue
4. **Proof of Concept**: If possible, include a minimal EigenScript program demonstrating the vulnerability
5. **Affected Versions**: Which versions are affected?
6. **Suggested Fix**: If you have suggestions for fixing the issue

### What to Expect

- **Acknowledgment**: We will acknowledge receipt of your report within 48 hours
- **Assessment**: We will assess the vulnerability and determine its severity
- **Timeline**: We aim to provide an initial response within 7 days
- **Fix**: Critical vulnerabilities will be prioritized for immediate fixes
- **Credit**: We will credit you in the CHANGELOG and security advisory (unless you prefer to remain anonymous)

### Public Disclosure

Please do **NOT** publicly disclose the vulnerability until:
1. We have confirmed and assessed the issue
2. A fix has been prepared and released
3. We have agreed on a disclosure timeline

We request a minimum of 30 days before public disclosure to allow time for fixes and user updates.

## Security Best Practices

If you're using EigenScript, follow these best practices:

### For Developers

1. **Do NOT run untrusted code**: Only execute EigenScript programs from trusted sources
2. **Validate Input**: Always validate and sanitize user input before processing
3. **Limit File Access**: Run EigenScript with minimal filesystem permissions
4. **Update Regularly**: Keep EigenScript updated to the latest version
5. **Review Dependencies**: Regularly audit Python dependencies for vulnerabilities

### For Production (NOT RECOMMENDED)

EigenScript is **NOT production-ready**. If you absolutely must use it in a production-like environment:

1. **Isolate**: Run in a sandboxed container (Docker, VM)
2. **Restrict**: Use process isolation and resource limits
3. **Monitor**: Log all execution and monitor for suspicious activity
4. **Network**: Disable network access if not needed
5. **Backup**: Maintain backups of critical data

## Security Features

### Current

- ✅ No arbitrary code execution via string evaluation (no `eval()` equivalent)
- ✅ No shell command execution capabilities
- ✅ Type safety through LRVM vector space
- ✅ Dependency security: Only numpy as runtime dependency
- ✅ Static code analysis in CI pipeline

### Planned

- 🔜 Sandboxing for code execution
- 🔜 Resource limits (CPU time, memory, recursion depth)
- 🔜 File access restrictions and whitelisting
- 🔜 Input validation framework
- 🔜 Security audit and penetration testing
- 🔜 Formal security documentation

## Vulnerability Disclosure

Confirmed vulnerabilities will be:

1. **Fixed**: Patched in the next release
2. **Documented**: Listed in CHANGELOG.md
3. **Announced**: Published as GitHub Security Advisory
4. **Credited**: Reporter credited (with permission)

## Security Checklist for Contributors

When contributing code, ensure:

- [ ] No use of `eval()`, `exec()`, or similar dynamic code execution
- [ ] Input validation for all external inputs
- [ ] No bare `except:` clauses (use `except Exception:`)
- [ ] No SQL injection vectors (N/A currently, but for future database support)
- [ ] No path traversal vulnerabilities in file operations
- [ ] Dependencies checked with `safety` and `bandit`
- [ ] Security scan passes in CI pipeline

## Contact

For security concerns: [inauguralphysicist@gmail.com](mailto:inauguralphysicist@gmail.com)

For general issues: [GitHub Issues](https://github.com/InauguralPhysicist/EigenScript/issues)

---

**Note**: This security policy will be updated as EigenScript matures and additional security features are implemented.
