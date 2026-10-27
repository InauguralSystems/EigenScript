#!/usr/bin/env python3
"""Check the declared theorem inventory against the allowed axiom set."""
from pathlib import Path
import re
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / 'spec/lean/Tests/Axioms.lean'
names = re.findall(r'^#print axioms\s+(\S+)', TEST.read_text(), re.M)
if not names:
    sys.exit('axiom gate: theorem list is empty')
p = subprocess.run(['lake', 'env', 'lean', 'Tests/Axioms.lean'], cwd=ROOT/'spec/lean', text=True, capture_output=True)
output = p.stdout + p.stderr
if p.returncode:
    print(output, end='', file=sys.stderr); sys.exit(p.returncode)
allowed = {'propext', 'Classical.choice', 'Quot.sound'}
reports = re.findall(r'(?:depends on )?axioms:\s*\[([^]]*)\]', output)
seen = {
    axiom.strip()
    for report in reports
    for axiom in report.split(',')
    if axiom.strip()
}
unexpected = seen - allowed
if unexpected:
    sys.exit('axiom gate: unexpected axioms: ' + ', '.join(sorted(unexpected)))
for name in names:
    if name not in output:
        sys.exit(f'axiom gate: no output for {name}')
print(f'axiom gate: {len(names)} theorem(s), allowed axioms only')
