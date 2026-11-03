#!/usr/bin/env python3
"""Plant3's named MAP checks using the real row runner and pinned transcripts.

The plant driver selects one row and removes only that row's assertion for
its transverse run. This is not a separate numeric semantics oracle.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from phase2_check import TIER_ENV, header, run  # noqa: E402

ROWS = ('N13.json-refuses-inf', 'N13.store-refuses-nan')


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ROWS:
        print('writer-map: BROKEN usage: writer_map_check.py ' + '|'.join(ROWS))
        return 2
    row = sys.argv[1]
    build = subprocess.run(['make'], cwd=ROOT, capture_output=True, text=True)
    build_text = build.stdout + build.stderr
    if build.returncode != 0 or 'warning:' in build_text:
        print('writer-map: BROKEN build: make rc=%d' % build.returncode)
        print(build_text)
        return 2
    path = ROOT / 'tests/phase2/rows' / (row + '.eigs')
    expected = path.with_suffix('.out').read_text()
    want_rc = int(header(str(path)).get('EXPECT-RC', '0'))
    failures = 0
    with tempfile.TemporaryDirectory(prefix='r23-map-') as scratch:
        for tier in ('off', 'default', 'osr'):
            rc, stdout, stderr = run(str(ROOT / 'src/eigenscript'), str(path),
                                     TIER_ENV[tier], scratch)
            if rc == 124 or rc < 0 or rc >= 128 or stderr:
                print('writer-map: BROKEN runtime %s tier=%s rc=%d stderr=%r' %
                      (row, tier, rc, stderr))
                return 2
            matched = rc == want_rc and stdout == expected
            if row == 'N13.json-refuses-inf' and not matched:
                failures += 1
                print('writer-map: FAIL N13.json-refuses-inf tier=%s rc=%d stdout=%r' %
                      (tier, rc, stdout))
            if row == 'N13.store-refuses-nan' and not matched:
                failures += 1
                print('writer-map: FAIL N13.store-refuses-nan tier=%s rc=%d stdout=%r' %
                      (tier, rc, stdout))
    print('writer-map: row=%s examined=3 failures=%d' % (row, failures))
    return int(failures != 0)


if __name__ == '__main__':
    raise SystemExit(main())
