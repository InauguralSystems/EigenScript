#!/usr/bin/env python3
"""Direct R33 port checks on handwritten windows only; no data files read."""
import argparse
import math
from pathlib import Path
import struct
import subprocess
import sys
import types
import r33_port as P

CHECKS = 0


def check(name, condition):
    global CHECKS
    if not condition:
        raise AssertionError(name)
    CHECKS += 1
    print(f"PORT UNIT {name}: ok")


def same(a, b):
    if type(a) is not type(b):
        return False
    if type(a) is float:
        return math.isnan(a) and math.isnan(b) or struct.pack('>d', a) == struct.pack('>d', b)
    if type(a) is dict:
        return a.keys() == b.keys() and all(same(a[key], b[key]) for key in a)
    if type(a) in (tuple, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def handwritten_windows():
    """Direct unit inputs; never a corpus row or an identity-fixture file."""
    return [[5.0] * 15,
            [1000.0 - 0.5 * i for i in range(21)],
            [1000.0] + [i / 1000.0 for i in range(1, 24)],
            [0.0, -0.0, 0.0001, -0.0002, 0.0] * 4,
            [2**53 + i for i in range(21)],
            [-(2**63), 2**63 - 1, 0, 2**53, float(2**53)] * 4,
            [0.0, math.inf, math.nan, -math.inf] + [1.0] * 14]


def compare_prior(repository, commit):
    """Optional one-time compatibility check against the delivered port.

    Only the prior source module is read from git. Both ports receive the
    handwritten in-memory windows above; neither reads population files.
    The repository location is supplied by the caller, keeping this test
    portable across the registered independent-replication machines.
    """
    source = subprocess.check_output(['git', '-C', str(repository), 'show',
                                      f'{commit}:tools/observer_oracle/r33_port.py'], text=True)
    prior = types.ModuleType('_r33_prior_port')
    prior.__file__ = f'{commit}:tools/observer_oracle/r33_port.py'
    sys.modules[prior.__name__] = prior
    exec(compile(source, prior.__file__, 'exec'), prior.__dict__)
    readings = 0
    for policy in P.POLICIES:
        for values in handwritten_windows():
            original = prior.Slot(policy)
            grouped = P.Slot(policy, groups=P.GROUPS)
            for value in values:
                original.record(value)
                grouped.record(value)
                if not same(original.reading(), grouped.reading()):
                    raise AssertionError(f'all-groups compatibility differs: {policy}, index {grouped.count-1}')
                readings += 1
    check(f'all groups equal prior {commit} on {readings} handwritten readings', True)


def main():
    check("eleven policies", len(P.POLICIES) == 11 and len(set(P.POLICIES)) == 11)
    slot = P.Slot()
    slot.record(5.0)
    first = slot.reading()
    check("first observation", first["report"] == "equilibrium" and first["why"] is None and
          first["how"] is None and not first["quiet"] and first["count"] == 1)
    for _ in range(10):
        slot.record(5.0)
    reading = slot.reading()
    check("constant float", reading["converged"] and reading["stable"] and reading["equilibrium"] and
          reading["quiet"] and reading["how"] == 1.0 and reading["why_kind"] == "float")
    bits = []
    for policy in P.POLICIES:
        counter = P.Slot(policy)
        for i in range(11):
            counter.record(2**53 + i)
        answer = counter.reading()
        bits.append(tuple(answer[p] for p in ("converged", "stable", "diverging")))
        if policy == "F0":
            check("exact boxed scalar", answer["where"] == 2**53 + 10 and answer["why"] == 1 and
                  answer["where_kind"] == answer["why_kind"] == "int")
    check("exact rules in every arm", all(bit == (False, False, True) for bit in bits))
    overflow = P.Slot()
    overflow.record(-(2**63)).record(2**63 - 1)
    check("subtraction overflow is inexact", not overflow.all_exact() and
          overflow.reading()["why_kind"] == "float" and overflow.reading()["why"] == float(2**64 - 1))
    zeros = P.Slot("STD-rel")
    zeros.record(-0.0).record(0.0).record(1.0).record(0.0)
    check("STD zero rule", zeros.steps() == [0.0, 1.0, -1.0])
    zero_c = P.Slot("C_1e-6^hist")
    zero_c.record(0.0).record(-0.0)
    check("C zero guard", zero_c.steps() == [-0.0] and math.copysign(1.0, zero_c.steps()[0]) < 0.0)
    query = P.Slot("C_1e-2^win")
    query.record(1000.0).record(0.001).record(0.002)
    temporal = query.snapshot()
    for i in range(3, 13):
        query.record(i / 1000.0)
    check("C query peak", query.peak() == 0.012 and query.steps()[0] > 0.3)
    check("temporal snapshot", temporal["where"] == 0.002 and temporal["how"] > 0.9 and
          query.reading()["how"] < 0.02)
    hist = P.Slot("C_1e-2^hist")
    for value in [1000.0] + [i / 1000.0 for i in range(1, 13)]:
        hist.record(value)
    check("historical peak survives eviction", hist.peak() == 1000.0 and hist.steps()[0] < 0.001)
    exported = query.trajectory()
    exported["rel"] = [123.0] * len(exported["rel"])
    restored = P.Slot.from_trajectory(exported, "C_1e-2^win")
    check("C import ignores stored relatives", restored.steps() == query.steps())
    restored_hist = P.Slot.from_trajectory(hist.trajectory(), "C_1e-2^hist")
    check("historical peak carried on import", restored_hist.peak() == 1000.0 and
          restored_hist.steps() == hist.steps())
    ieee = P.Slot()
    ieee.record(math.inf)
    check("initial infinity", ieee.reading()["diverging"] and ieee.reading()["how"] is None)
    ieee.record(-math.inf)
    check("opposite infinity", ieee.reading()["oscillating"] and not ieee.reading()["diverging"] and
          ieee.reading()["how"] == 0.0)
    ieee.record(math.nan)
    check("NaN position", ieee.reading()["report"] == "undefined" and
          not any(ieee.reading()[p] for p in P.PREDS) and math.isnan(ieee.reading()["how"]))
    for _ in range(11):
        ieee.record(1.0)
    check("IEEE recovery", ieee.reading()["converged"] and ieee.reading()["stable"])
    for depth in (1,64):
        fixed=P.Slot(window=depth)
        for _ in range(depth+1):
            fixed.record(5.0)
        answer=fixed.reading()
        check(f"window {depth}",answer['converged'] and answer['stable'] and answer['equilibrium']
              and len(fixed.raw)==depth and len(fixed.values)==depth+1)
    copied=hist.copy()
    copied.record(9999.0)
    check("copy isolation",hist.peak()==1000.0 and copied.peak()==9999.0)
    copied.reset()
    check("reset state",copied.count==0 and copied.peak()==0.0 and not copied.values
          and copied.reading()['where'] is None and copied.reading()['report']=='equilibrium')
    all_on = all_off = 0
    for policy in P.POLICIES:
        for values in handwritten_windows():
            default = P.Slot(policy)
            explicit = P.Slot(policy, groups=P.GROUPS)
            disabled = P.Slot(policy, groups=())
            baseline = P.Slot('F0')
            for value in values:
                for current in (default, explicit, disabled, baseline):
                    current.record(value)
                if not same(default.reading(), explicit.reading()):
                    raise AssertionError(f'all-group selector differs at {policy}/{default.count}')
                if not same(disabled.reading(), baseline.reading()):
                    raise AssertionError(f'all-off differs from F0 at {policy}/{default.count}')
                all_on += 1
                all_off += 1
    check(f'all groups match default on {all_on} handwritten readings', True)
    check(f'all groups off match F0 on {all_off} handwritten readings', True)
    grouped = P.Slot('C_1e-3^hist', groups=('reference',))
    check('reference group sites', all(grouped.policy_for(site).name == grouped.policy.name
          for site in P.REFERENCE_SITES) and grouped.policy_for('S1').name == 'F0'
          and grouped.policy_for('N1').name == 'F0')
    s1 = P.Slot('STD-rel', groups=('S1',))
    s1.record(0.0).record(0.0001)
    check('S1-only policy', s1.steps() == [1.0]
          and s1.noise_floor() == 4.0*sys.float_info.epsilon*(1.0+0.0001)
          and s1.magnitude('S6', 0.0001) == 0.001)
    n1 = P.Slot('STD-rel', groups=('N1',))
    n1.record(0.0).record(0.0001)
    check('N1-only policy', n1.steps() == [0.1]
          and n1.noise_floor() == 4.0*sys.float_info.epsilon*0.0001
          and n1.magnitude('S6', 0.0001) == 0.001)
    for policy in P.POLICIES:
        for selected in ((), ('S1',), ('N1',), ('reference',), P.GROUPS):
            zero_window = P.Slot(policy, groups=selected)
            for _ in range(11):
                zero_window.record(0.0)
            check(f'finite zero step {policy}/{selected}',
                  zero_window.steps() == [0.0]*10 and zero_window.reading()['equilibrium']
                  and zero_window.reading()['how'] == 1.0)
    s1_zero = P.Slot('STD-rel', groups=('S1',))
    for value in [0.0, -0.0, 1.0, 0.0]:
        s1_zero.record(value)
    check('S1-only arm carries zero rule', s1_zero.steps() == [-0.0, 1.0, -1.0])
    reference_zero = P.Slot('STD-rel', groups=('reference',)).record(0.0).record(0.0)
    check('reference group has no zero rule', reference_zero.steps() == [0.0]
          and reference_zero.magnitude('S6', 0.0) == 0.0)
    shrinking = P.Slot(window=10)
    for value in range(11):
        shrinking.record(float(value))
    original = shrinking.trajectory()
    shrinking.set_window(4)
    check('window shrink reads active suffix', shrinking.values == original['values'][-5:]
          and shrinking.raw == original['raw'][-4:] and shrinking.capacity == 10)
    shrinking.set_window(10)
    check('window expansion restores retained samples', shrinking.trajectory() == original)
    shrinking.set_window(4).record(11.0)
    shrinking.set_window(10)
    check('push under smaller window retains capacity', shrinking.values == [float(i) for i in range(1, 12)]
          and len(shrinking.raw) == 10 and shrinking.capacity == 10)
    shrinking.set_window(64)
    before = shrinking.values[:]
    check('larger query does not allocate', shrinking.capacity == 10 and shrinking.values == before)
    shrinking.record(12.0)
    check('larger push grows and preserves', shrinking.capacity == 64 and shrinking.values == before+[12.0])
    detour = P.Slot()
    for value in (5.0, 4.0, 3.0):
        detour.record(value)
    best, since, last, values = detour.best, detour.since, detour.values[-1], detour.values[:]
    detour.detour('ab')
    exported = detour.trajectory()
    check('string detour preserves numeric state', not exported['numeric'] and exported['observed']
          and exported['best'] == best and exported['since'] == since
          and exported['last_value'] == last and exported['values'] == values
          and exported['entropy'] == 1.0 and exported['dH'] == 1.0 and exported['dh'] == [1.0]
          and detour.count == 4)
    imported = P.Slot.from_trajectory(exported)
    check('nonnumeric trajectory import keeps value channel', not imported.numeric
          and imported.report_value() == detour.report_value()
          and imported.trajectory() == exported)
    detour.record(2.0)
    check('numeric return folds across detour', detour.numeric and detour.count == 5
          and detour.reading()['why'] == -1.0 and detour.best == 2.0 and detour.since == 0)
    historical = P.Slot('C_1e-3^hist').record(1000.0)
    saved = historical.snapshot()
    historical.detour('abcd').set_window(4)
    for value in (1.0, 0.5, 0.25, 0.125, 0.0625):
        historical.record(value)
    check('history peak survives detour and depth changes', historical.peak() == 1000.0
          and P.Slot.from_trajectory(historical.trajectory(), 'C_1e-3^hist').peak() == 1000.0)
    check('temporal snapshot is detached', saved['where'] == 1000.0 and saved['count'] == 1)


def cli():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prior-repository', type=Path)
    parser.add_argument('--prior-commit')
    args = parser.parse_args()
    if (args.prior_repository is None) != (args.prior_commit is None):
        parser.error('--prior-repository and --prior-commit must be supplied together')
    main()
    if args.prior_repository is not None:
        compare_prior(args.prior_repository, args.prior_commit)
    print(f'PORT UNIT: {CHECKS} checks passed')


if __name__ == "__main__":
    cli()
