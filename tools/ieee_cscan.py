#!/usr/bin/env python3
"""#1746 Phase 1: the ONE C scanner shared by the ieee gates
(ieee_accessor_gate.py, ieee_effect_order.py, ieee_failret_coverage.py,
ieee_format_sites.py), so the gates cannot disagree about what a function,
a call or a macro argument is.

  hosted_sources(root)        `make print-HOSTED_SOURCES`, refuses an empty list
  strip(text)                 comments blanked, string/char literal CONTENTS blanked,
                              and the NON-ieee arm of every #ifdef/#ifndef EIGS_IEEE
                              blanked (the gates judge the ieee build); lengths and
                              newlines kept, so offsets and lines hold
  functions(text)             [(name, ret_type, body_start, body_end, header_start)]
                              for every top-level function definition
  calls(text, lo, hi)         [(name, open_paren_offset, close_paren_offset)]
  line_of(text, off)          1-based line
"""
import os, re, subprocess

def hosted_sources(root):
    out = subprocess.run(['make', '-s', '-C', root, 'print-HOSTED_SOURCES'],
                         capture_output=True, text=True, check=True).stdout.split()
    if not out:
        raise SystemExit('FAIL: make print-HOSTED_SOURCES listed nothing')
    return out

def ieee_view(s):
    """Blank the lines the ieee build does not compile: the #else arm of
    `#ifdef EIGS_IEEE`, the body of `#ifndef EIGS_IEEE` (keeping its #else).
    Other conditionals keep both arms (conservative: more code is seen)."""
    out, stack = [], []          # stack of: None (other #if) or [keep_now]
    for line in s.split('\n'):
        d = line.strip()
        dead = any(st is not None and not st[0] for st in stack)
        if re.match(r'#\s*if', d):
            if re.match(r'#\s*ifdef\s+EIGS_IEEE\b', d): stack.append([True])
            elif re.match(r'#\s*ifndef\s+EIGS_IEEE\b', d): stack.append([False])
            else: stack.append(None)
            out.append(line if not dead else ' ' * len(line)); continue
        if re.match(r'#\s*else', d) and stack:
            if stack[-1] is not None: stack[-1][0] = not stack[-1][0]
            out.append(' ' * len(line)); continue
        if re.match(r'#\s*endif', d) and stack:
            stack.pop(); out.append(' ' * len(line)); continue
        out.append(' ' * len(line) if dead else line)
    return '\n'.join(out)

def strip(s):
    s = ieee_view(s)
    out, i, n = [], 0, len(s)
    while i < n:
        if s.startswith('/*', i):
            j = s.find('*/', i + 2); j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', s[i:j])); i = j
        elif s.startswith('//', i):
            j = s.find('\n', i); j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j
        elif s[i] in '"\'':
            q, j = s[i], i + 1
            while j < n and s[j] != q:
                j += 2 if s[j] == '\\' else 1
            out.append(q + re.sub(r'[^\n]', ' ', s[i + 1:j]) + q); i = j + 1
        else:
            out.append(s[i]); i += 1
    return ''.join(out)

def match_paren(t, i):
    """t[i] == '(' ; returns the offset of its matching ')'."""
    d = 0
    for j in range(i, len(t)):
        if t[j] == '(': d += 1
        elif t[j] == ')':
            d -= 1
            if d == 0: return j
    return len(t) - 1

_FDEF = re.compile(r'^([A-Za-z_][\w \t\*]*?)\b([A-Za-z_]\w*)\s*\(', re.M)
_KW = {'if', 'for', 'while', 'switch', 'return', 'sizeof', 'else', 'do', 'case'}

def functions(t):
    res = []
    for m in _FDEF.finditer(t):
        name, ret = m.group(2), m.group(1).strip()
        if name in _KW or ret in ('', 'return', 'else') or ret.startswith('#'): continue
        if m.start() > 0 and t[m.start() - 1] not in '\n': continue
        p = match_paren(t, m.end() - 1)
        k = p + 1
        while k < len(t) and t[k] in ' \t\n': k += 1
        if k >= len(t) or t[k] != '{': continue
        d, e = 0, k
        while e < len(t):
            if t[e] == '{': d += 1
            elif t[e] == '}':
                d -= 1
                if d == 0: break
            e += 1
        res.append((name, ret, k, e, m.start()))
    return res

_CALL = re.compile(r'\b([A-Za-z_]\w*)\s*\(')

def calls(t, lo, hi):
    res = []
    for m in _CALL.finditer(t, lo, hi):
        if m.group(1) in _KW: continue
        p = m.end() - 1
        res.append((m.group(1), p, match_paren(t, p)))
    return res

def line_of(t, off):
    return t.count('\n', 0, off) + 1
