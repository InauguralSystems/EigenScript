#!/bin/bash
# Message stores use eigs_utf8_sanitize. Each --lint --json %s is a whole
# lint_json_escape destination, or a literal / .code / .level / error-code
# field (`esc` does not match inside `pesc`). Zero writers is RED.
# eigenlsp (#1336): every strbuf_append* call in src/eigenlsp.c is examined
# (examined == raw substring count > 0). A non-literal string must be a
# json_escape_to argument or a WAIVED (buffer, argument) pair, and every
# waiver must be used. json_escape_to and lint_json_escape must both call
# eigs_json_escape_append, the one UTF-8 escape.
# Residual (a textual check, not a proof): pointer aliases; a store call split
# across lines; strcat/strncat/memmove/stpcpy or indexed stores into .message;
# a printf whose severity and message sit more than 8 lines apart; an eigenlsp
# JSON writer that is not a strbuf_append* call; a waived text buffer
# (det/hb/code/full) whose contents reach JSON other than through json_escape_to.
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
def body_after(lines, sig, window=30):
    for i, line in enumerate(lines):
        if sig in line and not line.rstrip().endswith(";"):
            return "\n".join(lines[i:i + window])
    return ""
lsp = (root / "src" / "eigenlsp.c").read_text(errors="surrogateescape")
lint_lines = (root / "src" / "lint_host.c").read_text(errors="surrogateescape").splitlines()
for rel, lines, fn in (("src/eigenlsp.c", lsp.splitlines(), "static void json_escape_to"),
                       ("src/lint_host.c", lint_lines, "static void lint_json_escape")):
    if "eigs_json_escape_append" not in body_after(lines, fn):
        print(f"FAIL: {rel} {fn.split()[-1]} does not call eigs_json_escape_append"); fail += 1
WAIVED = {("sb", "params_json"): "a JSON value its caller built",
          ("sb", "result_json"): "a JSON value its caller built",
          ("sb", 'g_first_error_code ? g_first_error_code : "E002"'): "a diagnostic code",
          ("sb", "diags[i].code"): "a diagnostic code",
          ("det", "s->name"): "det reaches JSON only via json_escape_to",
          ("det", "s->params[j]"): "det reaches JSON only via json_escape_to",
          ("hb", "s->name"): "hb reaches JSON via hover_text, then code",
          ("hb", "s->params[j]"): "hb reaches JSON via hover_text, then code",
          ("code", "hover_text"): "code reaches JSON only via json_escape_to",
          ("full", 'g_first_error_msg[0] ? g_first_error_msg : "invalid syntax"'):
              "full reaches JSON only via json_escape_to"}
STR = {'"': re.compile(r'"(?:\\.|[^"\\])*"'), "'": re.compile(r"'(?:\\.|[^'\\])*'")}
def call_args(src, k):
    """Top-level arguments of the call whose '(' ends just before k."""
    out, cur, depth = [], "", 1
    while True:
        c = src[k]
        if c in STR:
            q = STR[c].match(src, k).group(0); cur += q; k += len(q); continue
        depth += {"(": 1, "[": 1, ")": -1, "]": -1}.get(c, 0)
        if depth == 0: return out + [cur.strip()]
        if c == "," and depth == 1: out.append(cur.strip()); cur = ""
        else: cur += c
        k += 1
lit = re.compile(r'^(\s*"(?:\\.|[^"\\])*")+\s*$')
used, lsp_calls = set(), 0
for m in re.finditer(r"\bstrbuf_append(\w*)\s*\(", lsp):
    lsp_calls += 1
    n, args, kind = lsp.count("\n", 0, m.start()) + 1, call_args(lsp, m.end()), m.group(1)
    dest, raw = args[0].lstrip("&"), []
    if kind == "_char":
        raw = [] if re.fullmatch(r"'(?:\\.|[^'\\])'", args[1]) else [args[1]]
    elif kind in ("", "_n"):
        raw = [] if lit.match(args[1]) else [args[1]]
    elif kind == "_fmt":
        fmt = "".join(re.findall(r'"((?:\\.|[^"\\])*)"', args[1]))
        convs = [c for c in re.findall(r"%[-+ #0]*\d*(?:\.\d+)?[hlLzjt]*([a-zA-Z%])", fmt) if c != "%"]
        raw = [a for c, a in zip(convs, args[2:] + ["?"] * len(convs)) if c == "s"]
    else:
        raw = [f"unknown writer strbuf_append{kind}"]
    for a in (" ".join(r.split()) for r in raw):
        if (dest, a) in WAIVED: used.add((dest, a)); continue
        print(f"FAIL: src/eigenlsp.c:{n} {dest} gets a raw string outside json_escape_to: {a}"); fail += 1
table = lsp.count("strbuf_append")
if lsp_calls != table or not lsp_calls:
    print(f"FAIL: eigenlsp strbuf_append calls examined={lsp_calls} table={table} (zero is RED)"); fail += 1
for w in sorted(set(WAIVED) - used):
    print(f"FAIL: eigenlsp waiver {w} matches no site; delete it"); fail += 1
examined = messages + jsons + lsp_calls
if not messages or not jsons:
    print(f"FAIL: writers examined={examined} message={messages} json={jsons} (zero is RED)"); sys.exit(1)
if fail:
    print(f"FAILED: {fail} writer(s) outside the chokepoint; examined={examined}"); sys.exit(1)
print(f"lint-diag-writers: OK examined={examined} message={messages} json={jsons} eigenlsp={lsp_calls}")
PY
