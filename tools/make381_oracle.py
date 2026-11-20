#!/usr/bin/env python3
"""Derive tools/make381_cases.json from two real makes (#2448).

The macOS runners' make is GNU Make 3.81.  It reads a number sign inside a
variable reference or a function call as the start of a comment on some kinds
of line; GNU Make 4.3 and later do not.  tools/make381_number_sign_check.py
refuses such lines without running a make.  This tool is where that check's
expectations come from: it runs every case of the case file through a real
GNU Make 3.81 and through a second make, and records what each prints and
whether they agree.

--check and --update are run by hand, on a machine that has a GNU Make 3.81,
when a case is added or changed; no gate runs them, because no runner has both
makes.  --selftest needs no make: it holds the hand-written fields of every
case to its recorded results, and the gates run it.  Building a 3.81 (about a
minute):

    curl -LO https://ftp.gnu.org/gnu/make/make-3.81.tar.gz
    # sha256 16b77de9f013bcd536b7bc1efbe314223aedfe250f9063e33cbb4dfd347215a2
    tar -xzf make-3.81.tar.gz && cd make-3.81
    # A current C library needs this one edit in two files:
    sed -i 's/_GNU_GLOB_INTERFACE_VERSION == GLOB_INTERFACE_VERSION/_GNU_GLOB_INTERFACE_VERSION >= GLOB_INTERFACE_VERSION/' configure glob/glob.c
    ./configure && make          # the binary is ./make

Usage:
    make381_oracle.py --check  MAKE381 [--make4 MAKE]   compare with the file
    make381_oracle.py --update MAKE381 [--make4 MAKE]   rewrite the file's results
    make381_oracle.py --selftest                        the file against itself

A case is its "text" followed by two lines that print the variables X and Z
and the names of the variables that begin with X, Z or N (so that a variable
defined under another name than the one meant is seen), and by an "all" rule
(and an empty "all2" rule when the text has none).  "differ" is
true when the two makes' exit codes differ or their standard output differs;
what they write to standard error is recorded and not compared (the two word
their messages differently).  The fields "kind", "expect" and "why" are
written by a person and are never changed here.  "expect" must follow
"differ" unless "why" says, in its first words, that the check is stricter or
looser than the makes there, or that the construct is not covered.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, 'make381_cases.json')
STRICTER = 'stricter than the makes: '
LOOSER = 'looser than the makes: '
NOT_COVERED = 'not covered: '


def case_makefile(text):
    """The makefile a case is run as."""
    tail = ("\n$(info X=[$(X)] Z=[$(Z)])"
            "\n$(info V=[$(sort $(filter X% Z% N%,$(.VARIABLES)))])"
            "\nall: all2 ; @:\n")
    return text + tail + ("" if "all2:" in text else "all2:\n")


def run(make, path):
    # A fixed environment: make takes every environment variable as a variable
    # of its own, and the cases print variables by name.
    q = subprocess.run([make, '-f', path, 'all'], capture_output=True,
                       timeout=30, cwd=os.path.dirname(path),
                       env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
    # Decoded here, not by subprocess: its text mode turns a carriage return
    # that make printed into a newline.
    out = q.stdout.decode('utf-8', 'replace').strip(' \t\n')
    # 3.81 quotes with a grave accent where later makes use an apostrophe.
    err = q.stderr.decode('utf-8', 'replace').strip(' \t\n').replace(path, 'case.mk').replace('`', "'")
    return {'rc': q.returncode, 'out': out, 'err': err}


def results_differ(r381, r4):
    return r381['rc'] != r4['rc'] or r381['out'] != r4['out']


def expectation_fault(case):
    """Why a case's hand-written fields contradict its results, or None."""
    kind, expect, why = case.get('kind'), case.get('expect'), case.get('why', '')
    if kind not in ('number-sign', 'other-construct'):
        return 'kind is %r' % kind
    if expect not in ('finding', 'clean'):
        return 'expect is %r' % expect
    for key in ('make381', 'make4'):
        if not isinstance(case.get(key), dict) or 'rc' not in case[key] or 'out' not in case[key]:
            return 'no recorded result for %s' % key
    if case.get('differ') is not results_differ(case['make381'], case['make4']):
        return '"differ" does not follow from the two recorded results'
    if kind == 'other-construct':
        if expect != 'clean' or not why.startswith(NOT_COVERED):
            return 'an other-construct case must expect clean and say "%s..."' % NOT_COVERED
        return None
    if case['differ']:
        if expect == 'clean' and not why.startswith(LOOSER):
            return 'the makes differ, the case expects clean, and "why" does not say "%s..."' % LOOSER
        if expect == 'finding' and why != 'the two makes differ':
            return 'the makes differ and "why" says something else'
        return None
    if expect == 'finding' and not why.startswith(STRICTER):
        return 'the makes agree, the case expects a finding, and "why" does not say "%s..."' % STRICTER
    if expect == 'clean' and why != 'the two makes agree':
        return 'the makes agree and "why" says something else'
    return None


def load():
    with open(CASES) as f:
        doc = json.load(f)
    cases = doc['cases']
    names = [c.get('name') for c in cases]
    if not cases or len(set(names)) != len(names) or None in names:
        raise ValueError('no cases, a case without a name, or a name twice')
    return doc, cases


def selftest():
    """The stored file against itself, then four planted contradictions."""
    try:
        _, cases = load()
    except (OSError, ValueError, KeyError) as exc:
        print('MAKE381_ORACLE_SELFTEST: ERROR: %s' % exc)
        return 2
    faults = 0
    for case in cases:
        fault = expectation_fault(case)
        if fault:
            faults += 1
            print('FAIL: %s: %s' % (case['name'], fault))
    agree = {'rc': 0, 'out': 'X=[a]', 'err': ''}
    stop = {'rc': 2, 'out': '', 'err': 'stop'}
    base = {'name': 'planted', 'text': '', 'kind': 'number-sign'}
    plants = [
        ('the makes differ, clean expected, no reason',
         dict(base, make381=stop, make4=agree, differ=True, expect='clean', why='the two makes agree')),
        ('the makes agree, a finding expected, no reason',
         dict(base, make381=agree, make4=agree, differ=False, expect='finding', why='the two makes differ')),
        ('"differ" contradicts the recorded results',
         dict(base, make381=stop, make4=agree, differ=False, expect='clean', why='the two makes agree')),
        ('another construct that expects a finding',
         dict(base, kind='other-construct', make381=stop, make4=agree, differ=True, expect='finding',
              why=NOT_COVERED + 'x')),
    ]
    caught = 0
    for label, case in plants:
        if expectation_fault(case):
            caught += 1
        else:
            print('FAIL: planted contradiction passed: %s' % label)
    controls = [
        dict(base, make381=stop, make4=agree, differ=True, expect='finding', why='the two makes differ'),
        dict(base, make381=agree, make4=agree, differ=False, expect='clean', why='the two makes agree'),
        dict(base, make381=agree, make4=agree, differ=False, expect='finding', why=STRICTER + 'x'),
        dict(base, make381=stop, make4=agree, differ=True, expect='clean', why=LOOSER + 'x'),
    ]
    accepted = sum(1 for case in controls if expectation_fault(case) is None)
    ok = faults == 0 and caught == len(plants) and accepted == len(controls)
    print('MAKE381_ORACLE_SELFTEST: cases=%d faults=%d planted=%d caught=%d controls=%d accepted=%d %s' % (
        len(cases), faults, len(plants), caught, len(controls), accepted, 'PASS' if ok else 'FAIL'))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', metavar='MAKE381')
    mode.add_argument('--update', metavar='MAKE381')
    mode.add_argument('--selftest', action='store_true')
    ap.add_argument('--make4', default='make')
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    make381 = os.path.abspath(args.check or args.update)
    version = subprocess.run([make381, '--version'], capture_output=True,
                             text=True).stdout.split('\n')[0]
    if version != 'GNU Make 3.81':
        print('make381-oracle: FAIL: %s says %r, not GNU Make 3.81' % (make381, version))
        return 2
    try:
        doc, cases = load()
    except (OSError, ValueError, KeyError) as exc:
        print('make381-oracle: FAIL: %s' % exc)
        return 2
    moved = faults = 0
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'case.mk')
        for case in cases:
            with open(path, 'w') as f:
                f.write(case_makefile(case['text']))
            r381 = run(make381, path)
            r4 = run(args.make4, path)
            new = {'make381': r381, 'make4': r4, 'differ': results_differ(r381, r4)}
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
    print('make381-oracle: %s examined=%d moved=%d expectation-faults=%d' % (
        verdict, len(cases), moved, faults))
    return 0 if verdict == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
