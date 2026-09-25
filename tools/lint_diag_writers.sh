#!/bin/bash
# Writers of lint messages and --lint --json strings (#1048, #1275).
# Derived from src/*.c, not from a list. A message writer stores into a
# `.message` buffer; a JSON emitter is a printf whose format carries
# "severity" and "message". Message stores must be eigs_utf8_sanitize
# (what lint_vdiag copies through). JSON emitters must hand the call a
# lint_json_escape destination. Zero writers examined is RED.
# Residual: a store through a pointer alias, or a JSON printf split so
# "severity" and "message" are more than 8 lines apart, is not seen.
set -eu
cd "$(dirname "$0")/.."
exec python3 - << 'PY'
import pathlib, re, sys
root = pathlib.Path(".").resolve()
msg_re = re.compile(
    r"(eigs_utf8_sanitize|snprintf|sprintf|vsnprintf|strcpy|strncpy|memcpy)\s*\([^;]*(?:->|\.)message")
esc_re = re.compile(r"lint_json_escape\s*\([^,]+,\s*([A-Za-z_][A-Za-z0-9_]*)")
printf_re = re.compile(r"\b(printf|fprintf)\s*\(")
fail = 0
messages = []
jsons = []
for path in sorted((root / "src").glob("*.c")):
    lines = path.read_text(errors="surrogateescape").splitlines()
    rel = path.relative_to(root)
    for n, line in enumerate(lines, 1):
        if not msg_re.search(line):
            continue
        messages.append(f"{rel}:{n}")
        if "eigs_utf8_sanitize" not in line:
            print(f"FAIL: {rel}:{n} writes a diagnostic message outside eigs_utf8_sanitize")
            fail += 1
    i = 0
    while i < len(lines):
        if not printf_re.search(lines[i]):
            i += 1
            continue
        j = i
        while j < len(lines) and j < i + 8:
            if ";" in lines[j]:
                break
            j += 1
        text = "\n".join(lines[i:j + 1])
        if "severity" in text and "message" in text:
            jsons.append(f"{rel}:{i + 1}")
            window = "\n".join(lines[max(0, i - 20):j + 1])
            dests = esc_re.findall(window)
            if not any(d in text for d in dests):
                print(f"FAIL: {rel}:{i + 1} --lint --json string bypasses lint_json_escape")
                fail += 1
        i = j + 1
examined = len(messages) + len(jsons)
if not messages or not jsons:
    print(f"FAIL: writers examined={examined} message={len(messages)} json={len(jsons)} (zero is RED)")
    sys.exit(1)
if fail:
    print(f"FAILED: {fail} writer(s) outside the chokepoint; examined={examined}")
    sys.exit(1)
print(f"lint-diag-writers: OK examined={examined} message={len(messages)} json={len(jsons)}")
PY
