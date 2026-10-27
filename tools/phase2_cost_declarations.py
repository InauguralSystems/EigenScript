#!/usr/bin/env python3
"""One schema and two-sided predicate for Phase 2's per-method cost bounds."""
import argparse
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
import re
import sys

NOISE = Decimal('0.2')
STALE_TOLERANCE = 2 * NOISE + Decimal('0.1')
METHODS = ('local', 'ci')
UNDECLARED_MAX = {'local': Decimal('0.3'), 'ci': Decimal('5')}


@dataclass(frozen=True)
class Declaration:
    max_local: Decimal
    max_ci: Decimal
    recover_round: str
    reason: str

    def maximum(self, method):
        if method not in METHODS:
            raise ValueError('unknown cost method: ' + method)
        return getattr(self, 'max_' + method)


def parse_declarations(text, workloads=None):
    expectations = {}
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = [f.strip() for f in line.split('\t')]
        where = 'cost_expect.txt:%d: ' % n
        if len(fields) != 6:
            raise ValueError(where + 'expected six TSV fields '
                             '(workload, tier, max_local, max_ci, recover_round, reason)')
        workload, tier, local, ci, recover_round, reason = fields
        if (workloads is not None and workload not in workloads) or tier not in ('jit', 'off'):
            raise ValueError(where + 'unknown workload/tier: %s %s' % (workload, tier))
        key = (workload, tier)
        if key in expectations:
            raise ValueError(where + 'duplicate workload/tier: %s %s' % key)
        maxima = []
        for column, value in (('max_local', local), ('max_ci', ci)):
            try:
                maximum = Decimal(value)
            except InvalidOperation:
                maximum = Decimal('NaN')
            if not maximum.is_finite() or maximum < 0:
                raise ValueError(where + column + ' must be finite and >= 0')
            maxima.append(maximum)
        if not re.fullmatch(r'R[1-9][0-9]*(?:\.[1-9][0-9]*)?', recover_round) or not reason:
            raise ValueError(where + 'recover_round and reason are required')
        expectations[key] = Declaration(*maxima, recover_round, reason)
    return expectations


def assess_row(expectations, workload, tier, method, base, cand):
    """Return this method's maximum, declaration and exact two-sided verdict."""
    if method not in METHODS:
        raise ValueError('unknown cost method: ' + method)
    if base <= 0 or cand <= 0:
        raise ValueError('instruction counts must be positive')
    declaration = expectations.get((workload, tier))
    maximum = declaration.maximum(method) if declaration else UNDECLARED_MAX[method]
    difference = Decimal((cand - base) * 100)
    if difference > maximum * base:
        verdict = 'OVER'
    elif declaration and difference < (maximum - STALE_TOLERANCE) * base:
        verdict = 'STALE'
    else:
        verdict = 'ok'
    return maximum, declaration, verdict


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--method', choices=METHODS, required=True)
    ap.add_argument('--row', nargs=4, metavar=('WORKLOAD', 'TIER', 'BASE_IR', 'CAND_IR'), required=True)
    args = ap.parse_args()
    workload, tier, base, cand = args.row
    try:
        base, cand = int(base), int(cand)
        root = Path(__file__).resolve().parents[1]
        expectations = parse_declarations((root / 'tests/phase2/cost_expect.txt').read_text())
        if tier not in ('jit', 'off'):
            raise ValueError('unknown tier: ' + tier)
        maximum, declaration, verdict = assess_row(expectations, workload, tier, args.method, base, cand)
    except (OSError, ValueError) as error:
        print('phase2-cost: FAIL: ' + str(error), file=sys.stderr)
        return 2
    delta = Decimal((cand - base) * 100) / base
    label = ('REGRESSION' if verdict == 'OVER' else 'STALE DECLARATION' if verdict == 'STALE'
             else 'DECLARED' if declaration else 'ok')
    print('  %s: %s tier=%s  Ir %d -> %d  delta=%+.4f%% max_%s=+%s%%%s' %
          (label, workload, tier, base, cand, delta, args.method, maximum,
           (' recover_round=' + declaration.recover_round) if declaration else ''))
    return int(verdict != 'ok')


if __name__ == '__main__':
    sys.exit(main())
