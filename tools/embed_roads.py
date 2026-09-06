#!/usr/bin/env python3
"""Run the embedding provenance test with either CLI build layout."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def select_variant(root, sanitize=False):
    # build.sh creates a standalone CLI; make uses an objdir hard link.
    # With no unique match, build from the same SOURCES via embed-roads.
    cli = root / 'src/eigenscript'
    cli.stat()  # A missing CLI is still a setup failure, not a fallback case.
    variants = [p.parent.name for p in (root / 'build').glob('*/eigenscript')
                if p.samefile(cli)]
    variant = variants[0] if len(variants) == 1 else ('asan' if sanitize else 'release')
    return variant, len(variants)


def run(binary, fixtures, *extra):
    try:
        result = subprocess.run([str(binary), str(fixtures), *extra], capture_output=True,
                                text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, f"embed_roads: FAIL: {error}\n"
    totals = re.findall(r"^embed_roads: checks=(\d+) scope_checks=(\d+) failures=(\d+)$",
                        result.stdout, re.M)
    good = (result.returncode == 0 and not result.stderr and len(totals) == 1 and
            int(totals[0][0]) >= 20 and int(totals[0][1]) >= 12 and int(totals[0][2]) == 0)
    output = result.stdout + result.stderr
    if not good:
        output += f"embed_roads: FAIL: child rc={result.returncode}, expected clean exit and nonempty checks\n"
    return int(not good), output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args()
    binary = args.binary
    if binary is None:
        try:
            variant, matches = select_variant(ROOT, bool(os.environ.get('ASAN_OPTIONS')))
        except OSError as error:
            print(f'embed_roads: FAIL: cannot inspect CLI variant: {error}')
            return 1
        print(f'embed_roads: build={variant} ({matches} matching CLI variants; ' +
              ('matching objects)' if matches == 1 else 'dedicated source build)'))
        build = subprocess.run(['make', '-s', '-C', str(ROOT), 'embed-roads',
                                'ROAD_VARIANT=' + variant], capture_output=True, text=True)
        if build.returncode:
            print('embed_roads: FAIL: build failed\n' + build.stdout + build.stderr)
            return 1
        binary = ROOT / 'build' / variant / 'embed_roads'
    binary = binary.resolve()
    status, output = run(binary, ROOT / 'tests/embed_roads')
    print(output, end='')
    if status or not args.selftest:
        return status
    with tempfile.TemporaryDirectory(prefix='embed-road-plants-') as tmp:
        layout = Path(tmp) / 'layout'
        (layout / 'src').mkdir(parents=True)
        cli = layout / 'src/eigenscript'
        cli.touch()  # Metadata control, never a copied runtime binary.
        if select_variant(layout) != ('release', 0):
            print('embed_roads selftest: FAIL: standalone build.sh layout')
            return 1
        for name in ('asan', 'release'):
            target = layout / 'build' / name / 'eigenscript'
            target.parent.mkdir(parents=True)
            os.link(cli, target)
            expected = ('asan', 1) if name == 'asan' else ('release', 2)
            if select_variant(layout) != expected:
                print(f'embed_roads selftest: FAIL: {name} layout: {expected}')
                return 1
        if select_variant(layout, sanitize=True) != ('asan', 2):
            print('embed_roads selftest: FAIL: ambiguous sanitizer layout')
            return 1
        print('embed_roads selftest: GREEN: standalone, unique, ambiguous, sanitizer layouts')
        status, output = run(binary, ROOT / 'tests/embed_roads', '--plant-override')
        if (status == 0 or 'FAIL: execution override at planted execution: planted-override' not in output or
                'checks=32 scope_checks=21 failures=1' not in output or
                'FAIL: child rc=1,' not in output):
            print('embed_roads selftest: FAIL: execution-scope probe missed planted override\n' + output)
            return 1
        print('embed_roads selftest: RED: execution-scope override')
        tree = Path(tmp) / 'fixtures'
        shutil.copytree(ROOT / 'tests/embed_roads', tree)
        peer = tree / 'helper/peer.eigs'
        peer.write_text(peer.read_text().replace('"HELPER"', '"WRONG"'))
        status, output = run(binary, tree)
        if status == 0 or 'embed_roads: FAIL: eval_file expected HELPER / HELPER' not in output:
            print('embed_roads selftest: FAIL: wrong helper peer survived\n' + output)
            return 1
        print('embed_roads selftest: RED: wrong helper peer')
        status, output = run(binary, tree / 'missing')
        if status == 0 or 'embed_roads: FAIL: missing fixture tree' not in output:
            print('embed_roads selftest: FAIL: missing fixture tree survived\n' + output)
            return 1
        print('embed_roads selftest: RED: missing fixture tree')
        # A correct C result cannot excuse a bad process envelope or zero work.
        for symptom in ('exit', 'stderr', 'zero_checks'):
            wrapper = Path(tmp) / symptom
            wrapper.write_text(f'#!{sys.executable}\n'
                               'import re, subprocess, sys\n'
                               f'r = subprocess.run([{str(binary)!r}, *sys.argv[1:]], capture_output=True, timeout=20)\n'
                               'if r.returncode or r.stderr: raise SystemExit(99)\n'
                               'out = r.stdout\n' +
                               ('out = re.sub(rb"checks=\\d+ scope_checks=\\d+", b"checks=0 scope_checks=0", out)\n'
                                if symptom == 'zero_checks' else '') +
                               'sys.stdout.buffer.write(out)\n' +
                               ('raise SystemExit(17)\n' if symptom == 'exit' else
                                'sys.stderr.write("planted warning\\n")\n' if symptom == 'stderr' else ''))
            wrapper.chmod(0o755)
            status, output = run(wrapper, ROOT / 'tests/embed_roads')
            expected_rc = 17 if symptom == 'exit' else 0
            expected_checks = 'checks=0 scope_checks=0' if symptom == 'zero_checks' else 'checks=31 scope_checks=20'
            if (status == 0 or f'embed_roads: FAIL: child rc={expected_rc},' not in output or
                    expected_checks + ' failures=0' not in output or
                    ('planted warning\n' in output) != (symptom == 'stderr')):
                print(f'embed_roads selftest: FAIL: {symptom} survived\n' + output)
                return 1
            print(f'embed_roads selftest: RED: {symptom}')
    print('embed_roads selftest: controls=5 plants=6 failures=0')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
