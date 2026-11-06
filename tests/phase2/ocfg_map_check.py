#!/usr/bin/env python3
"""O3 plants use the actual MAP row's runs and exact expected transcript.

A selected case retains the valid four-field control in every MAP tier.
The transverse plant removes only the selected mismatch's failure assertion.
Child --step crashes are captured by the row as case rc/label/stderr, so a
planted reader crash is a named mismatch. A failed row harness is BROKEN.
"""
from pathlib import Path
import argparse
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from phase2_check import TIERS, TIER_ENV, header, run  # noqa: E402


def pairs(text):
    lines = text.splitlines()
    if not lines or len(lines) % 2:
        raise ValueError('missing or incomplete case transcript: ' + repr(text))
    result = {}
    for i in range(0, len(lines), 2):
        name = lines[i].split(' ', 1)[0]
        if name in result or not lines[i + 1].startswith(name + ' first-stderr='):
            raise ValueError('duplicate or malformed case: ' + name)
        result[name] = lines[i:i + 2]
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('binary')
    p.add_argument('--case', choices=('cfg-5-fields', 'cfg-6-fields', 'cfg-3-fields',
                                    'cfg-4-window-hex', 'cfg-install-window',
                                    'cfg-install-dh-zero', 'cfg-install-dh-small',
                                    'cfg-install-scale'))
    args = p.parse_args()
    row = ROOT / 'tests/phase2/rows/O3.ocfg-no-hlow.sh'
    if header(str(row)).get('TIERS', '').split() != TIERS:
        raise ValueError('O3 must retain all four MAP tiers')
    expected = pairs(row.with_suffix('.out').read_text())
    selected = [args.case] if args.case else list(expected)
    examined = failures = mismatches = controls = control_failures = 0
    with tempfile.TemporaryDirectory(prefix='r32-map-') as scratch:
        for tier in TIERS:
            rc, stdout, stderr = run(str(Path(args.binary).resolve()), str(row),
                                     TIER_ENV[tier], scratch)
            if rc != 0 or stderr:
                raise ValueError('row tier=%s rc=%s stderr=%r' % (tier, rc, stderr))
            actual = pairs(stdout)
            if actual.keys() != expected.keys():
                raise ValueError('case population differs')
            controls += 1
            if actual['cfg-4-fields'] != expected['cfg-4-fields']:
                control_failures += 1
                print('ocfg-map: CONTROL-FAIL O3.ocfg-no-hlow tier=' + tier)
            for name in selected:
                examined += 1
                matched = actual[name] == expected[name]
                mismatches += not matched
                if not matched:
                    failures += 1
                    print('ocfg-map: FAIL O3.ocfg-no-hlow case=%s tier=%s actual=%r' %
                          (name, tier, actual[name]))
    print('ocfg-map: examined=%d mismatches=%d failures=%d controls=%d control_failures=%d' %
          (examined, mismatches, failures, controls, control_failures))
    return int(failures > 0 or control_failures > 0)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print('ocfg-map: BROKEN ' + str(error))
        raise SystemExit(2)
