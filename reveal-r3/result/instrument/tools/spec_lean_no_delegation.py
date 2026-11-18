#!/usr/bin/env python3
"""Reject process delegation and native escape hatches in the Lean model."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(r'\bIO\.Process(?:\.(?:spawn|output))?\b|@\[extern\b')
failures = []
for path in sorted((ROOT / 'spec/lean').rglob('*.lean')):
    if '.lake' in path.parts:
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if FORBIDDEN.search(line):
            failures.append(f'{path.relative_to(ROOT)}:{number}: {line.strip()}')
if failures:
    raise SystemExit('Lean delegation gate failed:\n' + '\n'.join(failures))
print('Lean delegation gate: no process spawning, shell-out, or extern declarations')
