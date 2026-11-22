#!/usr/bin/env python3
"""R3.1 plants' named MAP checks, using the real runner and transcripts.

This helper is an adapter for the existing MAP assertions, not a second
numeric oracle. The plant driver deletes only the selected row assertion in
its transverse copy; the runtime runs, tier witness and control remain live.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from phase2_check import TIERS, TIER_ENV, header, parse_witness, run, witness  # noqa: E402

ROWS = (
    'O2.int-counter-2p53', 'O2.int-down-counter-2p53',
    'O2.int-smi-alternating', 'O1.unobserved-jit-sample',
    'O2.nan-all-false', 'O2.inf-alternating-oscillates',
    'O2.harmonic-not-converged', 'O2.report-noisy-loss',
    'O2.noisy-loss-improving-count', 'O2.nan-report-undefined',
    'O1.where-is-value', 'O4.how-infinite-step',
)
CONTROL = 'O2.counter-pause-not-converged'


def execute(row, scratch):
    path = ROOT / 'tests/phase2/rows' / (row + '.eigs')
    info = header(str(path))
    if info.get('ROW') != row:
        raise ValueError('header does not name ' + row)
    expected = path.with_suffix('.out').read_text()
    want_rc = int(info.get('EXPECT-RC', '0'))
    tiers = info.get('TIERS', ' '.join(TIERS)).split()
    if tiers != TIERS:
        raise ValueError('%s must retain all four MAP tiers, got %r' % (row, tiers))
    results = []
    for tier in tiers:
        rc, stdout, stderr = run(str(ROOT / 'src/eigenscript'), str(path),
                                 TIER_ENV[tier], scratch)
        if rc == 124 or rc < 0 or rc >= 128 or stderr:
            raise ValueError('runtime %s tier=%s rc=%d stderr=%r' %
                             (row, tier, rc, stderr))
        results.append((tier, rc == want_rc and stdout == expected, rc, stdout))
    w = parse_witness(info.get('WITNESS', 'none'))
    if not w or w['kind'] != 'none':
        if not w:
            raise ValueError('missing witness for ' + row)
        holds, evidence = witness(str(ROOT / 'src/eigenscript'), str(path), w, scratch)
        if not holds:
            raise ValueError('witness %s: %s' % (row, evidence))
        print('observer-map: WITNESS %s %s' % (row, evidence))
    return results, int(w['kind'] != 'none')


def main():
    rows = sys.argv[1:]
    if not rows or len(rows) != len(set(rows)) or any(r not in ROWS for r in rows):
        print('observer-map: BROKEN usage: observer_map_check.py ROW [ROW ...]; '
              'rows must be distinct R3.1 plant checks')
        return 2
    env = dict(os.environ)
    for key in ('MAKEFLAGS', 'MFLAGS'):
        env.pop(key, None)             # serial make, even inside a parent make
    build = subprocess.run(['make'], cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=1200)
    build_text = build.stdout + build.stderr
    if build.returncode != 0 or 'warning:' in build_text:
        print('observer-map: BROKEN build: make rc=%d' % build.returncode)
        print(build_text)
        return 2
    failures = mismatches = examined = witnesses = control_failures = 0
    with tempfile.TemporaryDirectory(prefix='r31-map-') as scratch:
        for row in rows:
            results, nw = execute(row, scratch)
            witnesses += nw
            for tier, matched, rc, stdout in results:
                examined += 1
                mismatches += not matched
                if not matched:
                    failures += 1
                    print('observer-map: FAIL %s tier=%s rc=%d stdout=%r' %
                          (row, tier, rc, stdout))
        control, nw = execute(CONTROL, scratch)
        witnesses += nw
        for tier, matched, rc, stdout in control:
            if not matched:
                control_failures += 1
                print('observer-map: CONTROL-FAIL %s tier=%s rc=%d stdout=%r' %
                      (CONTROL, tier, rc, stdout))
    if examined != len(rows) * len(TIERS) or len(control) != len(TIERS):
        raise ValueError('incomplete row/control population')
    ok = failures == 0 and control_failures == 0
    print('observer-map: %s rows=%s examined=%d mismatches=%d failures=%d '
          'controls=%d control_failures=%d witnesses=%d' %
          ('PASS' if ok else 'RED', ','.join(rows), examined, mismatches,
           failures, len(control), control_failures, witnesses))
    return 0 if ok else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print('observer-map: BROKEN ' + str(error))
        raise SystemExit(2)
