#!/usr/bin/env python3
"""Reject Lean proof placeholders after removing comments and strings."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def stripped(text):
    out = []
    i = 0
    depth = 0
    quoted = False
    while i < len(text):
        if depth:
            if text.startswith('/-', i): depth += 1; i += 2
            elif text.startswith('-/', i): depth -= 1; i += 2
            else: i += 1
        elif quoted:
            if text[i] == '\\': i += 2
            elif text[i] == '"': quoted = False; out.append(' '); i += 1
            else: i += 1
        elif text.startswith('/-', i): depth = 1; i += 2
        elif text.startswith('--', i):
            j = text.find('\n', i); i = len(text) if j < 0 else j
        elif text[i] == '"': quoted = True; out.append(' '); i += 1
        else: out.append(text[i]); i += 1
    return ''.join(out)

bad = []
for path in sorted((ROOT / 'spec/lean').rglob('*.lean')):
    if '.lake' in path.parts:
        continue
    for match in re.finditer(r'\b(?:sorry|admit)\b', stripped(path.read_text())):
        line = stripped(path.read_text())[:match.start()].count('\n') + 1
        bad.append(f'{path.relative_to(ROOT)}:{line}: proof placeholder')
if bad:
    print('\n'.join(bad), file=sys.stderr); sys.exit(1)
print('spec Lean placeholder gate: 0 sorry/admit')
