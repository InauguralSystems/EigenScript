#!/usr/bin/env bash
# Compare release Ir on the in-repo CodSpeed workload set, in BOTH VM tiers.
# The target list has one home: codspeed.yml. Consumer targets live elsewhere.
# Undeclared rows allow +0.3%; declared temporary costs are bounded per row.
# TSV: workload, tier, max_delta_pct, recover_round, reason (no header).
# --final requires the declarations file to be empty before integration merges.
set -eu
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import argparse
from decimal import Decimal, InvalidOperation
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

THRESHOLD_PCT = Decimal('0.3')
root = Path.cwd()
ap = argparse.ArgumentParser(prog='tools/phase2_cost.sh')
ap.add_argument('--final', action='store_true',
                help='require an empty cost_expect.txt (the pre-merge condition)')
ap.add_argument('base', nargs='?')
ap.add_argument('cand', nargs='?')
args = ap.parse_args()
expect_path = root / 'tests/phase2/cost_expect.txt'
if not expect_path.is_file():
    sys.exit('phase2-cost: FAIL: missing tests/phase2/cost_expect.txt')
expect_text = expect_path.read_text()
if args.final and expect_text:
    sys.exit('phase2-cost: FAIL: --final requires an empty tests/phase2/cost_expect.txt')
if bool(args.base) != bool(args.cand) or (not args.base and not args.final):
    ap.error('supply <base-bin> <cand-bin>, or --final alone')
if not args.base:
    print('phase2-cost: final declarations=0 PASS')
    sys.exit(0)
local_workload = re.compile(r'(?:bench/[^/]+|tests/bench_[^/]+)\.eigs')
workloads = set()
for line in (root / 'codspeed.yml').read_text().splitlines():
    m = re.match(r'\s*exec:\s*(.*)', line)
    if not m:
        continue
    argv = shlex.split(m[1])
    local = [p for p in argv if local_workload.fullmatch(p)]
    if local:
        if len(local) != 1 or argv[-2:] != ['./src/eigenscript', local[0]]:
            sys.exit('phase2-cost: FAIL: unsupported local CodSpeed command: ' + m[1])
        workloads.add(local[0])
if not workloads:
    sys.exit('phase2-cost: FAIL: no in-repo CodSpeed workloads')
# The execution list has one home; tracked sources anchor its coverage.
tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
expected = {p for p in tracked if local_workload.fullmatch(p)}
if workloads != expected:
    sys.exit('phase2-cost: FAIL: CodSpeed workload coverage missing=%s stale=%s' %
             (sorted(expected - workloads), sorted(workloads - expected)))
expectations = {}
for n, line in enumerate(expect_text.splitlines(), 1):
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    fields = line.split('\t')
    if len(fields) != 5:
        sys.exit('phase2-cost: FAIL: cost_expect.txt:%d: expected five TSV fields '
                 '(workload, tier, max_delta_pct, recover_round, reason)' % n)
    workload, tier, maximum, recover_round, reason = (f.strip() for f in fields)
    if workload not in workloads or tier not in ('jit', 'off'):
        sys.exit('phase2-cost: FAIL: cost_expect.txt:%d: unknown workload/tier: %s %s' %
                 (n, workload, tier))
    key = (workload, tier)
    if key in expectations:
        sys.exit('phase2-cost: FAIL: cost_expect.txt:%d: duplicate workload/tier: %s %s' %
                 (n, workload, tier))
    try:
        maximum = Decimal(maximum)
    except InvalidOperation:
        maximum = Decimal('NaN')
    if not maximum.is_finite() or maximum < 0:
        sys.exit('phase2-cost: FAIL: cost_expect.txt:%d: max_delta_pct must be finite and >= 0' % n)
    if not re.fullmatch(r'R[1-9][0-9]*(?:\.[1-9][0-9]*)?', recover_round) or not reason:
        sys.exit('phase2-cost: FAIL: cost_expect.txt:%d: recover_round and reason are required' % n)
    expectations[key] = (maximum, recover_round, reason)
if not shutil.which('valgrind'):
    sys.exit('phase2-cost: FAIL: valgrind is required')
bins = [str(Path(p).resolve(strict=True)) for p in (args.base, args.cand)]
for binary in bins:
    if not os.access(binary, os.X_OK):
        sys.exit('phase2-cost: FAIL: not executable: ' + binary)
    symbols = subprocess.run(['nm', '-D', binary], capture_output=True, text=True, check=True).stdout
    if re.search(r'__(?:asan|ubsan)', symbols):
        sys.exit('phase2-cost: FAIL: sanitizer binary: ' + binary)
logdir = Path(tempfile.mkdtemp(prefix='phase2-cost-'))
print('phase2-cost: source=codspeed.yml workloads=%d tiers=2 undeclared_max=+%s%% declarations=%d logs=%s' %
      (len(workloads), THRESHOLD_PCT, len(expectations), logdir), flush=True)
over = 0
for workload in sorted(workloads):
    for tier in ('jit', 'off'):
        results = []
        for arm, binary in zip(('base', 'cand'), bins):
            prefix = logdir / (workload.replace('/', '_') + '.' + tier + '.' + arm)
            env = {k: v for k, v in os.environ.items() if not k.startswith('EIGS_')}
            if tier == 'off':
                env['EIGS_JIT_OFF'] = '1'
            with prefix.with_suffix(prefix.suffix + '.stdout').open('wb') as stdout, \
                 prefix.with_suffix(prefix.suffix + '.stderr').open('wb') as stderr:
                run = subprocess.run(['valgrind', '--tool=cachegrind', '--cache-sim=no',
                    '--branch-sim=no', '--cachegrind-out-file=' + str(prefix) + '.cg',
                    binary, workload], cwd=root, env=env, stdin=subprocess.DEVNULL,
                    stdout=stdout, stderr=stderr, timeout=900)
            if run.returncode:
                sys.exit('phase2-cost: FAIL: %s %s %s rc=%d (see %s)' %
                         (workload, tier, arm, run.returncode, prefix))
            summary = re.findall(r'^summary:\s*(\d+)\s*$', Path(str(prefix) + '.cg').read_text(), re.M)
            if len(summary) != 1 or int(summary[0]) <= 0:
                sys.exit('phase2-cost: FAIL: missing/ambiguous Ir: ' + str(prefix))
            out = Path(str(prefix) + '.stdout').read_bytes()
            # The bench prints elapsed milliseconds; compare every result field.
            out = re.sub(rb'\b[0-9]+(?:\.[0-9]+)?ms\b', b'<elapsed>ms', out)
            err = Path(str(prefix) + '.stderr').read_text()
            err = re.sub(r'^==\d+==.*\n?', '', err, flags=re.M)
            results.append((int(summary[0]), out, err))
        (base, out_a, err_a), (cand, out_b, err_b) = results
        if (out_a, err_a) != (out_b, err_b):
            sys.exit('phase2-cost: FAIL: output differs: %s %s (see %s)' % (workload, tier, logdir))
        delta = 100 * (cand - base) / base
        maximum, recover_round, reason = expectations.get((workload, tier),
                                                         (THRESHOLD_PCT, None, None))
        fail = Decimal((cand - base) * 100) > maximum * base
        over += fail
        print('%-34s %-3s base=%12d cand=%12d delta=%+.4f%% max=+%s%% %s%s' %
              (workload, tier, base, cand, delta, maximum, 'OVER' if fail else 'ok',
               (' recover_round=%s reason=%s' % (recover_round, reason)) if recover_round else ''), flush=True)
print('phase2-cost: workloads=%d rows=%d over_declared_max=%d %s' %
      (len(workloads), len(workloads) * 2, over, 'FAIL' if over else 'PASS'))
sys.exit(bool(over))
PY
