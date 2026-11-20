#!/usr/bin/env python3
"""Derive tools/make381_cases.json from two real makes (#2448).

The macOS runners' make is GNU Make 3.81.  It reads a number sign inside a
variable reference or a function call as the start of a comment on some kinds
of line; GNU Make 4.3 and later do not.  tools/make381_number_sign_check.py
refuses such lines without running a make.  This tool is where that check's
expectations come from: it runs every case of the case file through a real
GNU Make 3.81 and through a second make, and records what each prints and
whether they agree.

It is run by hand, on a machine that has a GNU Make 3.81, when a case is added
or changed; no gate runs it, because no runner has both makes.  Building one
(about a minute):

    curl -LO https://ftp.gnu.org/gnu/make/make-3.81.tar.gz
    # sha256 16b77de9f013bcd536b7bc1efbe314223aedfe250f9063e33cbb4dfd347215a2
    tar -xzf make-3.81.tar.gz && cd make-3.81
    # A current C library needs this one edit in two files:
    sed -i 's/_GNU_GLOB_INTERFACE_VERSION == GLOB_INTERFACE_VERSION/_GNU_GLOB_INTERFACE_VERSION >= GLOB_INTERFACE_VERSION/' configure glob/glob.c
    ./configure && make          # the binary is ./make

Usage:
    make381_oracle.py --check  MAKE381 [--make4 MAKE]   compare with the file
    make381_oracle.py --update MAKE381 [--make4 MAKE]   rewrite the file's results

A case is its "text" followed by a line that prints the variable X and by an
"all" rule (and an empty "all2" rule when the text has none).  "differ" is
whether the two makes' exit code or output differ.  The fields "kind",
"expect" and "why" are written by a person and are never changed here; --check
also refuses a case whose "expect" contradicts "differ" without saying why.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, 'make381_cases.json')


def case_makefile(text):
    """The makefile a case is run as."""
    if 'all2:' in text:
        return text + "\n$(info X=[$(X)])\nall: all2 ; @:\n"
    return text + "\n$(info X=[$(X)])\nall: all2 ; @:\nall2:\n"


def run(make, path):
    q = subprocess.run([make, '-f', path, 'all'], capture_output=True,
                       text=True, timeout=30, cwd=os.path.dirname(path))
    out = (q.stdout + q.stderr).strip()
    # 3.81 quotes with a grave accent where later makes use an apostrophe.
    out = out.replace(path, 'case.mk').replace('`', "'")
    return {'rc': q.returncode, 'out': out}


def expectation_fault(case):
    """Why a case's hand-written fields contradict its results, or None."""
    kind, expect, why = case.get('kind'), case.get('expect'), case.get('why', '')
    if kind not in ('number-sign', 'other-construct'):
        return 'kind is %r' % kind
    if expect not in ('finding', 'clean'):
        return 'expect is %r' % expect
    if kind == 'other-construct':
        if expect != 'clean' or not why.startswith('not covered: '):
            return 'an other-construct case must expect clean and say "not covered: ..."'
        return None
    if case['differ']:
        if expect != 'finding':
            return 'the makes differ but the case expects clean'
        return None
    if expect == 'finding' and not why.startswith('stricter than the makes: '):
        return 'the makes agree, the case expects a finding, and "why" does not say "stricter than the makes: ..."'
    return None


def main():
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', metavar='MAKE381')
    mode.add_argument('--update', metavar='MAKE381')
    ap.add_argument('--make4', default='make')
    args = ap.parse_args()
    make381 = os.path.abspath(args.check or args.update)
    version = subprocess.run([make381, '--version'], capture_output=True,
                             text=True).stdout.split('\n')[0]
    if version != 'GNU Make 3.81':
        print('make381-oracle: FAIL: %s says %r, not GNU Make 3.81' % (make381, version))
        return 2
    with open(CASES) as f:
        doc = json.load(f)
    cases = doc['cases']
    names = [c['name'] for c in cases]
    if len(set(names)) != len(names) or not cases:
        print('make381-oracle: FAIL: no cases, or a case name twice')
        return 2
    moved = faults = 0
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'case.mk')
        for case in cases:
            with open(path, 'w') as f:
                f.write(case_makefile(case['text']))
            r381 = run(make381, path)
            r4 = run(args.make4, path)
            new = {'make381': r381, 'make4': r4, 'differ': r381 != r4}
            if any(case.get(k) != v for k, v in new.items()):
                moved += 1
                print('  MOVED: %s: 3.81 %r | other %r' % (case['name'], r381, r4))
            if args.update:
                case.update(new)
            fault = expectation_fault(case)
            if fault:
                faults += 1
                print('  FAULT: %s: %s' % (case['name'], fault))
    if args.update:
        with open(CASES, 'w') as f:
            json.dump(doc, f, indent=1, sort_keys=True)
            f.write('\n')
    verdict = 'PASS' if (faults == 0 and (moved == 0 or args.update)) else 'FAIL'
    print('make381-oracle: %s examined=%d declared=%d moved=%d expectation-faults=%d' % (
        verdict, len(cases), len(names), moved, faults))
    return 0 if verdict == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
