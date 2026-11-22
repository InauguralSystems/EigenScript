#!/usr/bin/env python3
"""Plant2's program half: the real N12 MAP row, isolated by payload under ASan.

The C slot test keeps its RC and finite controls. This helper adds the
language boundary without letting an early HEAP-tag crash skip later payloads.
Its transverse deletion is the subprocess-result assertion, so the exact
same crashed children still run when that assertion is removed.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from phase2_check import TIER_ENV, header, run  # noqa: E402

ROW = 'N12.nan-payload-tags'
PAYLOADS = ('0xFFF8000000000000', '0xFFF9000000000001',
            '0xFFFA000000000005', '0xFFFB000000001000',
            '0xFFFF000000000000')
PAYLOAD_LOOP = 'for p in [' + ', '.join(PAYLOADS) + ']:'
TIERS = ('off', 'default', 'osr')
SAN_ENV = {'ASAN_OPTIONS': 'detect_leaks=1:halt_on_error=1',
           'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1'}


def main():
    if len(sys.argv) != 1:
        print('nan-payload-map: BROKEN usage: nan_payload_map_check.py')
        return 2
    path = ROOT / 'tests/phase2/rows' / (ROW + '.eigs')
    source = path.read_text()
    expected = path.with_suffix('.out').read_text().splitlines(keepends=True)
    row_header = header(str(path))
    if (source.count(PAYLOAD_LOOP) != 1 or len(expected) != len(PAYLOADS) or
            len(set(expected)) != 1 or not expected[0].endswith('\n') or
            row_header.get('ROW') != ROW or row_header.get('EXPECT-RC') != '0'):
        print('nan-payload-map: BROKEN expected one exact five-payload loop, '
              'five equal transcript lines and the rc-0 N12 row header')
        return 2
    control = path.with_name('N12.f64-bits.eigs')
    control_expected = control.with_suffix('.out').read_text()
    control_rc = int(header(str(control)).get('EXPECT-RC', '0'))
    build = subprocess.run(['make', 'asan'], cwd=ROOT,
                           capture_output=True, text=True)
    build_text = build.stdout + build.stderr
    if build.returncode != 0 or 'warning:' in build_text:
        print('nan-payload-map: BROKEN build: make asan rc=%d' % build.returncode)
        print(build_text)
        return 2
    binary = str(ROOT / 'build/asan/eigenscript')
    failures = examined = controls = control_failures = timeouts = 0
    with tempfile.TemporaryDirectory(prefix='r24-nan-map-') as scratch:
        for payload, want in zip(PAYLOADS, expected):
            isolated = Path(scratch) / (payload + '.eigs')
            isolated.write_text(source.replace(PAYLOAD_LOOP,
                                               'for p in [' + payload + ']:'))
            for tier in TIERS:
                rc, stdout, stderr = run(binary, str(isolated),
                                         dict(TIER_ENV[tier], **SAN_ENV), scratch)
                examined += 1
                timeouts += rc == 124
                payload_matched = rc == 0 and stdout == want and not stderr
                # Plant2 deletes only this returned-result assertion. A child
                # signal or sanitizer report cannot stop the remaining cases.
                if not payload_matched:
                    failures += 1
                    print('nan-payload-map: FAIL %s payload=%s tier=%s '
                          'rc=%d stdout=%r stderr=%r' %
                          (ROW, payload, tier, rc, stdout, stderr))
        for tier in TIERS:
            rc, stdout, stderr = run(binary, str(control),
                                     dict(TIER_ENV[tier], **SAN_ENV), scratch)
            controls += 1
            if rc != control_rc or stdout != control_expected or stderr:
                control_failures += 1
                print('nan-payload-map: BROKEN finite control tier=%s '
                      'rc=%d stdout=%r stderr=%r' % (tier, rc, stdout, stderr))
    print('nan-payload-map: row=%s payloads=%d tiers=%d examined=%d '
          'failures=%d controls=%d control_failures=%d timeouts=%d' %
          (ROW, len(PAYLOADS), len(TIERS), examined, failures, controls,
           control_failures, timeouts))
    if timeouts or control_failures:
        print('nan-payload-map: BROKEN timeout or finite control failure')
        return 2
    return int(failures != 0)


if __name__ == '__main__':
    raise SystemExit(main())
