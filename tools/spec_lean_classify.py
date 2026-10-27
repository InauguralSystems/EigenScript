#!/usr/bin/env python3
"""Exercise the stable EigenCore classification contract through eigs-ref."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'spec/lean/.lake/build/bin/eigs-ref'

# These cases intentionally use the command-line boundary: the step-2 parser
# must retain the same verdicts when it replaces the step-1 classifier.
CASES = {
    'integer assignment': ('x is 1\n', 'in-subset'),
    'string containing delimiter': ('message is "this is text"\n', 'in-subset'),
    'boolean/null/operators': ('x is not false and (null == null)\n', 'in-subset'),
    'call argument pack': ('answer is add of [1, 2]\n', 'out'),
    'empty argument pack': ('answer is f of []\n', 'out'),
    'equality merge': ('print of (1 == 1)\n', 'in-subset'),
    'identifier containing e': ('age is when is x\n', 'in-subset'),
    'local temporal read': ('local age is when is x\n', 'in-subset'),
    'implicit-parameter definition': ('define square as:\n    return 1\n', 'out'),
    'explicit-parameter definition': ('define add(x, y) as:\n    return x + y\n', 'out'),
    'branch and loop': ('if true:\n    loop while false:\n        print of 1\nelse:\n    print of 2\n', 'in-subset'),
    'bare list after print': ('print of [1, 2]\n', 'out'),
    'index after print': ('print of xs[0]\n', 'out'),
    'nested list in argument pack': ('f of [[1]]\n', 'out'),
    'float': ('x is 1.5\n', 'out'),
    'unsupported loop': ('for x in y:\n    print of x\n', 'out'),
}

failures = []
with tempfile.TemporaryDirectory() as td:
    for number, (label, (source, expected)) in enumerate(CASES.items()):
        path = Path(td) / f'{number}.eigs'
        path.write_text(source)
        result = subprocess.run([EXE, '--classify-runtime', path], text=True, capture_output=True)
        actual = result.stdout.strip()
        verdict = 'out' if actual.startswith('out: ') else actual
        if result.returncode or verdict != expected:
            failures.append(f'{label}: expected {expected}, got {actual or result.stderr.strip()}')

if failures:
    raise SystemExit('classification table failed:\n  ' + '\n  '.join(failures))
print(f'classification table: {len(CASES)} cases passed')

# Evaluation must refuse rather than silently executing around a definition.
with tempfile.NamedTemporaryFile('w', suffix='.eigs') as source:
    source.write('define f as:\n    return 1\nprint of 2\n'); source.flush()
    result = subprocess.run([EXE, source.name], text=True, capture_output=True)
    expected = 'unsupported in EigenCore-0 step 2a: function definition'
    if result.returncode == 0 or expected not in result.stderr:
        raise SystemExit(f'evaluator did not refuse function definition: {result.stderr}')
print('unsupported evaluator refusal: function definition passed')
