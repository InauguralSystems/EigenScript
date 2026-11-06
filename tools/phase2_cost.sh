#!/usr/bin/env bash
# Compare release Ir on the in-repo CodSpeed workload set, in BOTH VM tiers.
# The target list has one home: codspeed.yml. Consumer targets live elsewhere.
# Undeclared rows allow +0.3%; declared temporary costs are bounded per row.
# TSV: workload, tier, max_local, max_ci, recover_round, reason (no header).
# #1939: this gate measures and enforces max_local; CI measures max_ci.
# Each column is ceil(delta+0.2, 0.1) from its own gate, never the other method.
# A declared row is bounded on BOTH sides. Above its max it fails (OVER).
# More than STALE_TOLERANCE points below its max it also fails (STALE): a
# round recovered cost and the declaration must come down, or a NEW
# regression could hide under the loose bound. A declaration is written as
# ceil to 0.1 of (measured delta + NOISE), so a fresh one fires neither way
# unless a re-run moves by more than NOISE (STALE_TOLERANCE = 2*NOISE + 0.1).
# NOISE = 0.2 points, the largest measured shift rounded up (R1.3 CI fix):
# run to run, a workload that prints elapsed time moved by 0.026 points; with
# the same binaries a different workload path moved bench/alloc_heavy by
# 0.160 points (the heap layout shifts a short string across a strlen
# alignment boundary, a million times).
# --declared TIER --method METHOD prints validated rows of one tier
# (workload, that method's max, recover_round); all includes tier as field 2.
# METHOD defaults to local.
# bench/check_regression.sh explicitly requests ci, and STALE-checks max_ci.
# --final requires the declarations file to be empty before integration merges,
# and the observer oracle's (tests/phase2/oracle_expect.txt, score.py --declared,
# #1830) as well: #1776 merges only when neither declares anything.
set -eu
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import argparse
import math
import struct
from decimal import Decimal
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path.cwd() / 'tools'))
from phase2_cost_declarations import (STALE_TOLERANCE, UNDECLARED_MAX,
                                      assess_row, parse_declarations)

THRESHOLD_PCT = UNDECLARED_MAX['local']
# N6 is an explicit cost-only comparison mode. Corpus diffs remain exact.
# Legacy unadorned integer text can denote an integral float; allow its .0 or
# scientific repr only when conversion retains its exact integer value.
NUMBER = re.compile(rb'(?<![A-Za-z_0-9.])[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?(?![A-Za-z_0-9.])')
INTEGER = re.compile(rb'[+-]?[0-9]+')


def elapsed_text(out):
    # Existing cost-gate exception: only numeric fields immediately before ms.
    return re.sub(rb'\b[0-9]+(?:\.[0-9]+)?ms\b', b'<elapsed>ms', out)


def output_tokens(text):
    matches = list(NUMBER.finditer(text))
    parts, end = [], 0
    for match in matches:
        parts.append(text[end:match.start()])
        end = match.end()
    return parts + [text[end:]], [match.group() for match in matches]


def compare_result_text(old, new, n6_text=False):
    if not n6_text:
        if old != new:
            raise ValueError('strict byte comparison differs')
        return 0
    before, a = output_tokens(old)
    after, b = output_tokens(new)
    if before != after or len(a) != len(b):
        raise ValueError('non-numeric bytes, numeric positions or token count differ')
    changed = 0
    for ordinal, (left, right) in enumerate(zip(a, b), 1):
        where = 'numeric token %d: ' % ordinal
        x, y = float(left), float(right)
        if not math.isfinite(x) or not math.isfinite(y):
            raise ValueError(where + 'non-finite decimal token')
        old_bits, new_bits = struct.pack('>d', x), struct.pack('>d', y)
        if old_bits != new_bits:
            raise ValueError(where + 'binary64 value/sign bits differ')
        if left == right:
            continue
        if INTEGER.fullmatch(right):
            raise ValueError(where + 'exact integer text changed or float became integer')
        if INTEGER.fullmatch(left) and int(x) != int(left):
            raise ValueError(where + 'integer-to-float conversion loses exact digits')
        if right != repr(y).encode('ascii'):
            raise ValueError(where + 'changed float text is not Python repr')
        changed += 1
    return changed


def output_self_test():
    good = [
        (b'answer=[3, 0.10000000000000001]\n', b'answer=[3.0, 0.1]\n'),
        (b'x=1e+15\n', b'x=1000000000000000.0\n'),
        (b'x=-0\n', b'x=-0.0\n'),
        (b'x=9007199254740994\n', b'x=9007199254740994.0\n'),
        (b'x=10000000000000000\n', b'x=1e+16\n'),
        (b'x=3 time=1.5ms\n', b'x=3.0 time=999ms\n'),
    ]
    bad = [
        ('value', b'x=1.0\n', b'x=1.0000000000000002\n'),
        ('float-to-int-kind', b'x=3.0\n', b'x=3\n'),
        ('integer-digits', b'x=9007199254740993\n', b'x=9007199254740992\n'),
        ('integer-precision', b'x=9007199254740993\n', b'x=9007199254740992.0\n'),
        ('int64-precision', b'x=9223372036854775807\n', b'x=9.223372036854776e+18\n'),
        ('integer-spelling', b'x=3\n', b'x=03\n'),
        ('signed-zero-erased', b'x=-0.0\n', b'x=0.0\n'),
        ('signed-zero-added', b'x=0\n', b'x=-0.0\n'),
        ('noncanonical-float', b'x=0.10000000000000001\n', b'x=0.100000000000000010\n'),
        ('non-finite-decimal', b'x=1e+308\n', b'x=1e+309\n'),
        ('non-numeric', b'answer=3\n', b'wrong=3.0\n'),
        ('missing-token', b'x=[3, 4]\n', b'x=[3.0]\n'),
        ('extra-token', b'x=3\n', b'x=[3.0, 4.0]\n'),
        ('position', b'x=3 y=4\n', b'x=4.0 y=3.0\n'),
        ('non-finite-text', b'x=inf\n', b'x=nan\n'),
    ]
    for old, new in good:
        if compare_result_text(elapsed_text(old), elapsed_text(new), True) <= 0:
            raise ValueError('self-test positive did not compare a changed token')
    for label, old, new in bad:
        try:
            compare_result_text(elapsed_text(old), elapsed_text(new), True)
        except ValueError:
            continue
        raise ValueError('self-test plant survived: ' + label)
    # The default remains byte strict, including the permitted N6 changes.
    try:
        compare_result_text(good[0][0], good[0][1])
    except ValueError:
        pass
    else:
        raise ValueError('self-test strict comparison accepted N6 text')
    identical = b'x=3 0.10000000000000001\n'
    for n6_text in (False, True):
        if compare_result_text(identical, identical, n6_text) != 0:
            raise ValueError('self-test unchanged text failed')
        if compare_result_text(elapsed_text(b'x=3 time=1.25ms\n'),
                               elapsed_text(b'x=3 time=999ms\n'), n6_text) != 0:
            raise ValueError('self-test elapsed milliseconds handling failed')
    print('phase2-cost-self-test: positive=%d rejected=%d strict=PASS elapsed=PASS PASS' % (len(good), len(bad)))


root = Path.cwd()
ap = argparse.ArgumentParser(prog='tools/phase2_cost.sh')
ap.add_argument('--n6-text', action='store_true',
                help='cost only: allow exact-value Python-repr float text changes; integer digits stay exact')
ap.add_argument('--self-test', action='store_true',
                help='one-time output-comparator calibration; runs no workload or build')
ap.add_argument('--final', action='store_true',
                help='require empty cost_expect.txt and oracle_expect.txt (the pre-merge condition)')
ap.add_argument('--declared', choices=('jit', 'off', 'all'),
                help='print validated declarations (workload, method max, recover_round); all includes tier as field 2')
ap.add_argument('--method', choices=('local', 'ci'),
                help='column for --declared only (default: local); cost runs always enforce max_local')
ap.add_argument('base', nargs='?')
ap.add_argument('cand', nargs='?')
args = ap.parse_args()
if args.self_test:
    if args.base or args.cand or args.final or args.declared or args.n6_text or args.method:
        ap.error('--self-test runs alone')
    try:
        output_self_test()
    except (AssertionError, ValueError, OverflowError) as error:
        sys.exit('phase2-cost-self-test: FAIL: ' + str(error))
    sys.exit(0)
if args.method and not args.declared:
    ap.error('--method requires --declared; cost runs enforce max_local')
if args.n6_text and (not args.base or not args.cand or args.declared):
    ap.error('--n6-text requires <base-bin> <cand-bin>')
expect_path = root / 'tests/phase2/cost_expect.txt'
if not expect_path.is_file():
    sys.exit('phase2-cost: FAIL: missing tests/phase2/cost_expect.txt')
expect_text = expect_path.read_text()
if args.final and expect_text:
    sys.exit('phase2-cost: FAIL: --final requires an empty tests/phase2/cost_expect.txt')
oracle_path = root / 'tests/phase2/oracle_expect.txt'
if args.final and not oracle_path.is_file():
    sys.exit('phase2-cost: FAIL: missing tests/phase2/oracle_expect.txt')
if args.final and oracle_path.read_text():
    sys.exit('phase2-cost: FAIL: --final requires an empty tests/phase2/oracle_expect.txt'
             ' (%d observer-oracle declaration(s) remain)' % len(oracle_path.read_text().splitlines()))
if bool(args.base) != bool(args.cand) or (not args.base and not args.final and not args.declared) \
        or (args.declared and (args.base or args.final)):
    ap.error('supply <base-bin> <cand-bin>, or --final alone, or --declared TIER alone')
if not args.base and not args.declared:
    print('phase2-cost: final declarations=0 oracle_declarations=0 PASS')
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
try:
    expectations = parse_declarations(expect_text, workloads)
except ValueError as error:
    sys.exit('phase2-cost: FAIL: ' + str(error))
if args.declared:
    for (workload, tier), declaration in sorted(expectations.items()):
        if tier == args.declared or args.declared == 'all':
            fields = [workload]
            if args.declared == 'all':
                fields.append(tier)
            fields += [str(declaration.maximum(args.method or 'local')), declaration.recover_round]
            print('\t'.join(fields))
    sys.exit(0)
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
print('phase2-cost: source=codspeed.yml workloads=%d tiers=2 undeclared_max=+%s%% declarations=%d '
      'stale_below_max=%s logs=%s method=local column=max_local' %
      (len(workloads), THRESHOLD_PCT, len(expectations), STALE_TOLERANCE, logdir), flush=True)
if args.n6_text:
    print('phase2-cost: output_compare=n6-text (exact values/bits, exact integer digits, Python repr)', flush=True)
over = stale = 0
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
            out = elapsed_text(out)
            err = Path(str(prefix) + '.stderr').read_text()
            err = re.sub(r'^==\d+==.*\n?', '', err, flags=re.M)
            results.append((int(summary[0]), out, err))
        (base, out_a, err_a), (cand, out_b, err_b) = results
        try:
            changed = compare_result_text(out_a, out_b, args.n6_text)
            changed += compare_result_text(err_a.encode(), err_b.encode(), args.n6_text)
        except (ValueError, OverflowError) as error:
            sys.exit('phase2-cost: FAIL: output differs: %s %s: %s (see %s)' %
                     (workload, tier, error, logdir))
        if args.n6_text and changed:
            print('phase2-cost: n6-text workload=%s tier=%s changed_tokens=%d' %
                  (workload, tier, changed), flush=True)
        delta = 100 * (cand - base) / base
        maximum, declaration, verdict = assess_row(expectations, workload, tier, 'local', base, cand)
        recover_round = declaration.recover_round if declaration else None
        reason = declaration.reason if declaration else None
        over += verdict == 'OVER'
        stale += verdict == 'STALE'
        print('%-34s %-3s base=%12d cand=%12d delta=%+.4f%% max=+%s%% %s%s' %
              (workload, tier, base, cand, delta, maximum, verdict,
               (' recover_round=%s reason=%s' % (recover_round, reason)) if recover_round else ''), flush=True)
print('phase2-cost: workloads=%d rows=%d over_declared_max=%d stale_declarations=%d %s' %
      (len(workloads), len(workloads) * 2, over, stale, 'FAIL' if over or stale else 'PASS'))
sys.exit(bool(over or stale))
PY
