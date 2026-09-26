#!/bin/bash
# Message stores use eigs_utf8_sanitize. Each --lint --json %s is a whole
# lint_json_escape destination, or a literal / .code / .level / error-code
# field (`esc` does not match inside `pesc`). Zero writers is RED.
# Residual (a textual check, not a proof): pointer aliases; a store call split
# across lines; strcat/strncat/memmove/stpcpy or indexed stores into .message;
# a printf whose severity and message sit more than 8 lines apart.
set -eu
cd "$(dirname "$0")/.."
exec python3 - << 'PY'
import pathlib, re, sys
root, fail, messages, jsons = pathlib.Path(".").resolve(), 0, 0, 0
msg_re = re.compile(r"(eigs_utf8_sanitize|snprintf|sprintf|vsnprintf|strcpy|strncpy|memcpy)\s*\([^;]*(?:->|\.)message")
esc_re = re.compile(r"lint_json_escape\s*\([^,]+,\s*([A-Za-z_][A-Za-z0-9_]*)")
ident_re = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")
allow = {"printf", "fprintf", "i", "ctx", "warnings", "warning_count", "code", "level", "line",
         "g_first_error_code", "g_first_error_line", "g_first_error_col"}
def bare(s):
    return re.sub(r'"(?:\\.|[^"\\])*"', " ", s)
for path in sorted((root / "src").glob("*.c")):
    lines, rel = path.read_text(errors="surrogateescape").splitlines(), str(path.relative_to(root))
    for n, line in enumerate(lines, 1):
        if not msg_re.search(line): continue
        messages += 1
        if "eigs_utf8_sanitize" not in line:
            print(f"FAIL: {rel}:{n} writes a diagnostic message outside eigs_utf8_sanitize"); fail += 1
    i = 0
    while i < len(lines):
        if not re.search(r"\b(printf|fprintf)\s*\(", lines[i]): i += 1; continue
        j = i
        while j < len(lines) and j < i + 8 and ";" not in lines[j]: j += 1
        text = "\n".join(lines[i:j + 1]); start = i + 1; i = j + 1
        if "severity" not in text or "message" not in text: continue
        jsons += 1
        dests = set(esc_re.findall("\n".join(lines[max(0, start - 26):j + 1])))
        bad = [n for n in ident_re.findall(bare(text)) if n not in dests and n not in allow]
        if ".message" in bare(text) or bad:
            shown = ", ".join(bad) if bad else ".message"
            print(f"FAIL: {rel}:{start} --lint --json %s is not an escaped buffer: {shown}"); fail += 1
examined = messages + jsons
if not messages or not jsons:
    print(f"FAIL: writers examined={examined} message={messages} json={jsons} (zero is RED)"); sys.exit(1)
if fail:
    print(f"FAILED: {fail} writer(s) outside the chokepoint; examined={examined}"); sys.exit(1)
print(f"lint-diag-writers: OK examined={examined} message={messages} json={jsons}")
PY
