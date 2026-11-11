#!/usr/bin/env python3
"""One-time calibration of R33 checks; never an experimental arm sweep.

Mutation inputs are handwritten or label-only transforms. Binary/port
equivalence itself is established by r33_identity, not these toy records.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from gen import HarnessError
from r33_identity import compare_records
import r33_population as population


def expect_red(name, action, fragment, out=None):
    try:
        action()
    except (HarnessError, ValueError, OSError) as error:
        red = str(error)
        if fragment not in red:
            raise AssertionError(f'{name}: wrong detector: {red}')
    else:
        raise AssertionError(f'{name}: planted failure was accepted')
    line = f'PLANT {name}: RED {red}'
    print(line)
    if out:
        (Path(out)/(name+'.log')).write_text(line+'\n')


def certification_plant(tmp):
    """Real scaled corpus through the real certifier refusal path."""
    original = json.loads((population.HERE/'corpus.json').read_text())
    row = next(r for r in original['rows'] if r['id'] == 'const_5')
    row = population.scale_row(row, 1e3)
    row['props']['limit'] = 5001.0
    original['rows'] = [row]
    corpus = tmp/'corpus.json'
    population.write_json(corpus, original)
    return population.certify_one(corpus, '/home/jon/.local/venvs/oracle/bin/python', tmp/'certifier.log')


def missing_choice():
    with tempfile.TemporaryDirectory(prefix='r33-choice-plant-') as directory:
        refusal = Path(directory)/'refusal.json'
        absent_choice = Path(directory)/'missing-choice.json'
        proc = subprocess.run([sys.executable, '-B', str(population.HERE/'r33_run.py'),
                               '--confirm', '--choice', str(absent_choice),
                               '--data', '/must-not-open-r33-data', '--readings', '/must-not-open-r33-readings',
                               '--out', str(refusal)],
                              capture_output=True, text=True)
        if proc.returncode != 2 or not refusal.is_file():
            raise AssertionError(f'confirmation missing-choice path did not write its rc2 refusal: {proc.stdout} {proc.stderr}')
        result = json.loads(refusal.read_text())
    reason = result.get('reason', '')
    if (result.get('status') != 'REFUSED' or result.get('choice_sha256') is not None
            or 'choice' not in reason.lower()
            or any(s in reason for s in ('must-not-open-r33-data', 'must-not-open-r33-readings'))
            or not any(s in reason.lower() for s in ('missing', 'required', 'refus', 'no such'))):
        raise AssertionError(f'wrong confirmation failure or inputs opened before choice: {result}')
    raise HarnessError('CONFIRMATION REFUSED without choice: '+reason)


def main(out=None):
    if out:
        Path(out).mkdir(parents=True, exist_ok=True)
    expected = {('handwritten', 10, 'converged'): True, ('handwritten', 10, 'stable'): True}
    compare_records(expected, dict(expected), 'handwritten control')
    print('CONTROL complete reading comparison: GREEN')
    wrong = dict(expected)
    wrong[('handwritten', 10, 'converged')] = False
    expect_red('one-reading-differs', lambda: compare_records(expected, wrong, 'handwritten port mutant'),
               'MISMATCH', out)
    missing = dict(expected)
    missing.pop(('handwritten', 10, 'stable'))
    expect_red('missing-reading', lambda: compare_records(expected, missing, 'handwritten missing mutant'),
               'MISSING', out)
    counts = {k: want for k, (_item,want) in population.EXPECTED.items()}
    population.check_counts(counts)
    counts['bases'] -= 1
    expect_red('ruling-count-differs', lambda: population.check_counts(counts), 'STOP R33-1 item 3', out)
    expect_red('empty-comparison', lambda: compare_records({}, {}, 'empty plant'), 'INCOMPLETE', out)
    expect_red('confirmation-without-choice', missing_choice, 'REFUSED without choice', out)
    with tempfile.TemporaryDirectory(prefix='r33-certifier-plant-') as directory:
        tmp = Path(directory)
        expect_red('scaled-certifier-refusal', lambda: certification_plant(tmp), 'CERTIFIER REFUSED/ERROR', out)
        if out:
            (Path(out)/'scaled-certifier.stdout').write_bytes((tmp/'certifier.log').read_bytes())
            (Path(out)/'scaled-certifier-input.json').write_bytes((tmp/'corpus.json').read_bytes())
    print('R33 SELFTEST: 6 plants caught, 0 survived; complete control green')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selftest',action='store_true',help='explicit registry self-test mode')
    parser.add_argument('--out')
    args = parser.parse_args()
    try:
        main(args.out)
    except (AssertionError, HarnessError) as error:
        print('R33 SELFTEST FAILED: '+str(error), file=sys.stderr)
        raise SystemExit(1)
