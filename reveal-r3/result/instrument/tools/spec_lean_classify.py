#!/usr/bin/env python3
"""Exercise the stable EigenCore classification contract through eigs-ref."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'spec/lean/.lake/build/bin/eigs-ref'
MODEL_VERSION = '0.0.0-model'

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
    'implicit-parameter definition': ('define square as:\n    return 1\n', 'in-subset'),
    'explicit-parameter definition': ('define add(x, y) as:\n    return x + y\n', 'in-subset'),
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

# Nested definitions are closures in step 2b-iii.
with tempfile.NamedTemporaryFile('w', suffix='.eigs') as source:
    source.write('define f as:\n    define inner as:\n        return 1\n    return inner of 1\n'); source.flush()
    result = subprocess.run([EXE, '--version', MODEL_VERSION, source.name], text=True, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(f'evaluator refused nested function definition: {result.stderr}')
print('modeled evaluator closure: nested function definition passed')
