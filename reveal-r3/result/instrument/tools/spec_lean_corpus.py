#!/usr/bin/env python3
"""Derive and classify the pre-registered EigenCore-0 corpus."""
from collections import Counter
from pathlib import Path
import importlib.util
import re
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('doc_examples', ROOT/'tests/test_doc_examples.py')
docs = importlib.util.module_from_spec(spec); spec.loader.exec_module(docs)
programs = []
for rel in docs.POPULATION:  # the checker's own, pinned doc-file list
    for line, info, args, text in docs.blocks(str(ROOT/rel)):
        if info != 'eigenscript': continue
        kind, _payload, error = docs.parse_tag(args)
        if error: raise SystemExit(f'{rel}:{line}: {error}')
        if kind in ('', 'check'):
            programs.append((f'{rel}:{line}', text))
tracked = subprocess.check_output([
    'git', 'ls-files', ':(glob)tests/**/*.eigs', ':(glob)examples/**/*.eigs'
], cwd=ROOT, text=True).splitlines()
# Check the pathspec census against a deliberately independent filesystem walk
# intersected with Git's complete tracked-file population.
all_tracked = set(subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines())
found = subprocess.check_output(
    ['find', 'tests', 'examples', '-type', 'f', '-name', '*.eigs'], cwd=ROOT, text=True).splitlines()
independent = sorted(set(found) & all_tracked)
if sorted(tracked) != independent:
    raise SystemExit('tracked .eigs census disagrees with independent find enumeration')
for rel in tracked:
    programs.append((rel, (ROOT/rel).read_text()))
expected = len(programs)
exe = ROOT/'spec/lean/.lake/build/bin/eigs-ref'
counts = Counter()
in_subset = 0
with tempfile.TemporaryDirectory() as td:
    for i, (label, source) in enumerate(programs):
        path = Path(td)/f'{i}.eigs'; path.write_text(source)
        p = subprocess.run([exe, '--classify', path], text=True, capture_output=True)
        if p.returncode or not p.stdout.strip():
            raise SystemExit(f'classifier failed for {label}: {p.stderr}')
        result = p.stdout.strip()
        if result == 'in-subset': in_subset += 1
        elif result.startswith('out: '):
            reason = re.sub(r' at line \d+$', '', result[5:]); counts[reason] += 1
        else: raise SystemExit(f'bad classifier output for {label}: {result}')
classified = in_subset + sum(counts.values())
assert classified == expected, (classified, expected)
print(f'classified / in_subset / out: {classified} / {in_subset} / {classified-in_subset}')
print('out-reason histogram:')
for reason, count in sorted(counts.items(), key=lambda x: (-x[1], x[0])):
    print(f'{count:4d}  {reason}')
