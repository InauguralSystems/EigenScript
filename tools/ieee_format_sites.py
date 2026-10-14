#!/usr/bin/env python3
"""#1746 Phase 1: enumerate every printf-family call in the ieee build's
sources whose format formats a floating-point value (%g/%e/%f/%a, any flags),
and require each such call to pass its double(s) through EIGS_NUM_CANON (the
one canonical NaN spelling, eigenscript.h) or to sit on the reviewed
internal-finite list (tools/ieee_format_internal.txt: `file:function reason`).

  python3 tools/ieee_format_sites.py        -> one row per site, then
  FORMAT_SITES: calls=<n> canon=<c> internal=<i> unrouted=<u> stale_internal=<s>

Population: `make print-HOSTED_SOURCES` plus the headers they include from
src/. Asserts calls > 0 and that every internal-list row matches a site
(both directions). Exit 0 iff unrouted == 0 and stale_internal == 0."""
import re, subprocess, sys, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
srcs = subprocess.run(['make', '-s', '-C', ROOT, 'print-HOSTED_SOURCES'],
                      capture_output=True, text=True, check=True).stdout.split()
files = sorted(set(srcs) | {f'src/{h}' for h in os.listdir(os.path.join(ROOT, 'src'))
                             if h.endswith('.h')})
FUNCS = r'(?:rt_error|snprintf|fprintf|printf|sprintf|strbuf_append_fmt|tp_printf|wf_printf|dprintf|vsnprintf)'
CALL = re.compile(r'\b(' + FUNCS + r')\s*\(')
FLT = re.compile(r'%[-+ #0-9.*]*l?[gGeEfFaA]')
FDEF = re.compile(r'^[A-Za-z_][\w\s\*]*?\b([A-Za-z_]\w*)\s*\([^;]*$')
def strip_comments(s):
    out, i, n = [], 0, len(s)
    while i < n:
        if s.startswith('/*', i):
            j = s.find('*/', i + 2); j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', s[i:j])); i = j
        elif s.startswith('//', i):
            j = s.find('\n', i); j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j
        elif s[i] == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == '\\' else 1
            out.append(s[i:j + 1]); i = j + 1
        elif s[i] == "'":
            j = i + 1
            while j < n and s[j] != "'":
                j += 2 if s[j] == '\\' else 1
            out.append(s[i:j + 1]); i = j + 1
        else:
            out.append(s[i]); i += 1
    return ''.join(out)
internal = {}
ipath = os.path.join(ROOT, 'tools', 'ieee_format_internal.txt')
for ln in open(ipath):
    ln = ln.strip()
    if not ln or ln.startswith('#'): continue
    key, reason = ln.split(None, 1)
    internal[key] = [reason, 0]
calls = canon = intern = unrouted = 0
for f in files:
    text = strip_comments(open(os.path.join(ROOT, f)).read())
    lines = text.split('\n')
    for m in CALL.finditer(text):
        if m.group(1) == 'vsnprintf' or text[max(0, m.start() - 8):m.start()].endswith('define '): continue
        i, d = m.end() - 1, 0
        while i < len(text):
            if text[i] == '"':
                i += 1
                while text[i] != '"': i += 2 if text[i] == '\\' else 1
            elif text[i] == '(': d += 1
            elif text[i] == ')':
                d -= 1
                if d == 0: break
            i += 1
        body = text[m.end():i]
        fmts = ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', body))
        if 'EIGS_NO_INT_REP_FMT' in body: fmts += '%.17g'
        if not FLT.search(fmts): continue
        calls += 1
        line = text.count('\n', 0, m.start()) + 1
        fn = '?'
        for j in range(line - 1, -1, -1):
            fm = FDEF.match(lines[j])
            if fm and '=' not in lines[j]: fn = fm.group(1); break
        key = f'{f}:{fn}'
        if 'EIGS_NUM_CANON' in body:
            canon += 1; verdict = 'canon'
        elif key in internal:
            intern += 1; internal[key][1] += 1; verdict = 'internal'
        else:
            unrouted += 1; verdict = 'UNROUTED'
        print(f'{verdict:9s} {f}:{line} {fn}: {m.group(1)}("{fmts[:60]}")')
stale = [k for k, v in internal.items() if v[1] == 0]
for k in stale: print(f'STALE internal row: {k}')
print(f'FORMAT_SITES: calls={calls} canon={canon} internal={intern} unrouted={unrouted} stale_internal={len(stale)}')
sys.exit(0 if calls > 0 and unrouted == 0 and not stale else 1)
