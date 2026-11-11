#!/usr/bin/env python3
"""Portable R33 calibration on real staged inputs and saved F0 readings.

No runtime or certifier process, Sympy, experiment metric or non-F0 policy
runs here. The real binary oracle is captured after the fixture input seal.
The unchanged certifier's actual recorded output supplies refusal facts.
"""
import argparse
import contextlib
import copy
import io
import json
from pathlib import Path
import shutil
import sys
sys.dont_write_bytecode = True  # -I ignores PYTHONDONTWRITEBYTECODE; leave no tree writes.
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # Same python3 -I invocation as other oracle rows.
from gen import HarnessError
import r33_identity as identity
import r33_population as population
import r33_run as runner

DATA = HERE / 'r33_data'
SITES = frozenset(('S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7', 'S8', 'N1', 'D2'))


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
        (Path(out) / (name + '.log')).write_text(line + '\n')
    return 1


def decode(value):
    if isinstance(value, dict):
        return (float.fromhex(value['float']) if set(value) == {'float'} else
                {key: decode(item) for key, item in value.items()})
    return [decode(item) for item in value] if isinstance(value, list) else value


def saved_binary(path):
    obj = json.loads(Path(path).read_text())
    if obj.get('format') != 'r33-site-binary/1':
        raise HarnessError('INCOMPLETE: unrecognised real site-binary format')
    result = {}
    for record in obj['readings']:
        key = tuple(record['key'])
        if len(key) != 3 or key in result:
            raise HarnessError('INCOMPLETE: duplicate or malformed real site-binary key')
        result[key] = decode(record['value'])
    if not result:
        raise HarnessError('INCOMPLETE: empty saved real site-binary readings')
    return result


def site_control(cases_path, binary_path):
    expected = {}
    for line in Path(cases_path).read_text().splitlines():
        row = json.loads(line)
        for (at, field), value in identity.model_fixture(row).items():
            key = row['id'], at, field
            if key in expected:
                raise HarnessError('INCOMPLETE: duplicate site fixture')
            expected[key] = value
    binary = saved_binary(binary_path)
    n = identity.compare_records(expected, binary, 'real site-binary control')
    print(f'CONTROL real site-binary comparison: GREEN readings={n}')
    return expected, binary


def site_plants(cases_path, binary_path, out=None):
    import r33_mutants
    selection = json.loads((DATA / 'site-coverage' / 'site-plants.json').read_text())
    if selection.get('format') != 'r33-site-plants/1':
        raise HarnessError('INCOMPLETE: unknown committed site-plant selection')
    selected = {row['id']: row['site'] for row in selection['mutants']}
    if (len(selected) != len(selection['mutants']) or len(selected) != len(SITES)
            or set(selected.values()) != SITES):
        raise HarnessError('INCOMPLETE: committed site plants omit a ruled site or repeat a mutant')
    results = r33_mutants.verify_site_plants(cases_path, binary_path, identifiers=set(selected))
    if {row['id'] for row in results} != set(selected):
        raise AssertionError('committed site-plant IDs differ from the live mutation inventory')
    if not results or not SITES <= {row['site'] for row in results}:
        raise AssertionError('site plants do not cover S1-S8, N1 and D2')
    ids = set()
    for row in results:
        if (row['id'] in ids or row['caught'] is not True or not row.get('reading')
                or 'key' not in row['reading'] or row['site'] != selected[row['id']]):
            raise AssertionError(f'site mutant survived or lacks a catching reading: {row}')
        ids.add(row['id'])
        name = f'site-{row["site"]}-{row["id"]}'
        line = f'PLANT {name}: RED real F0 reading {json.dumps(row["reading"], sort_keys=True)}'
        print(line)
        if out:
            (Path(out) / (name + '.log')).write_text(line + '\n')
    return len(results)


def import_plants(out=None):
    """Two reachable import faults, killed by actual sealed F0 classify readings."""
    import r33_imports
    import r33_mutants
    path = DATA / 'site-coverage' / 'import-binary-readings.json'
    payload = json.loads(path.read_text())
    if payload.get('format') != 'r33-import-binary/1':
        raise HarnessError('INCOMPLETE: unknown real import-binary format')
    binary = {}
    for cell in payload['readings']:
        key = tuple(cell['key'])
        if key in binary:
            raise HarnessError('INCOMPLETE: duplicate real import-binary key')
        binary[key] = decode(cell['value'])
    all_rows = r33_imports.verify(DATA / 'site-coverage' / 'imports')
    # This CI sample keeps the three programs carrying its two planted
    # faults. The complete identity additionally covers routing probes.
    ci_ids = {'addendum3-trajectory-imports', 'addendum3-trajectory-refusals',
              'addendum3-import-store-targets'}
    if not ci_ids <= {row['id'] for row in all_rows}:
        raise HarnessError('INCOMPLETE: real CI import programs missing')
    rows = [row for row in all_rows if row['id'] in ci_ids]
    if any(key[0] not in {row['id'] for row in all_rows} for key in binary):
        raise HarnessError('INCOMPLETE: undeclared real import-binary row')
    binary = {key:value for key,value in binary.items() if key[0] in ci_ids}
    expected = {(row['id'], *key):value for row in rows
                for key,value in r33_imports.model(row).items()}
    compared = identity.compare_records(expected, binary, 'real import-binary control')
    print(f'CONTROL real import-binary comparison: GREEN readings={compared}')
    selected = ('from_traj_since_plus1', 'from_traj_best_store_scale')
    for identifier in selected:
        cls = r33_mutants.mutated_slot(identifier)
        got = {(row['id'], *key):value for row in rows
               for key,value in r33_imports.model(row, slot_type=cls).items()}
        identity.compare_records(expected, binary, 'real import-binary oracle')
        wrong = [key for key in sorted(binary) if not identity.same(binary[key], got[key])]
        if not wrong:
            raise AssertionError('import fault survived real binary readings: '+identifier)
        key = wrong[0]
        line = ('PLANT import-'+identifier+': RED real F0 reading '
                +json.dumps(dict(key=list(key), binary=identity.encode(binary[key]),
                                 mutant=identity.encode(got[key])), sort_keys=True))
        print(line)
        if out:
            (Path(out)/(identifier+'.log')).write_text(line+'\n')
    return len(selected)


def staged_counts(directory):
    """Actual staged-file derivation; no value comes from EXPECTED."""
    return population.staged_counts(directory)


def staged_count_plant(directory):
    path = Path(directory) / 'cal' / 'x1' / 'corpus.json'
    corpus = json.loads(path.read_text())
    # Keep the real row roster so the count check itself, rather than the
    # earlier row-membership check, must reject the derived checkpoint count.
    row = next(row for row in corpus['rows'] if len(row['checkpoints']) > 1)
    row['checkpoints'].pop(0)  # retain the required final checkpoint at n
    population.write_json(path, corpus)
    population.check_counts(staged_counts(directory))


def certifier_control(log_path):
    corpus = DATA / 'populations' / 'cal' / 'x1e6' / 'corpus.json'
    receipt = json.loads((DATA / 'populations' / 'confirmation-counts.json').read_text())
    recorded = next(row for row in receipt['attempts']['calibration']
                    if row['scale'] == 'x1e6' and not row.get('validated_cached_certificate'))
    if (population.sha(log_path) != recorded['log_sha256']
            or population.sha(corpus) != recorded['corpus_sha256']
            or population.sha(HERE / 'certify.py') != recorded['certifier_sha256']):
        raise HarnessError('INCOMPLETE: recorded refusal output/corpus/certifier changed')
    parsed = population.parse_attempt(corpus, recorded['command'], recorded['rc'], log_path)
    parsed['scale'] = 'x1e6'
    if {row['id'] for row in parsed['refused']} != {'cos_fixed_point'}:
        raise AssertionError('unexpected recorded certifier refusal roster')
    attempts = {'calibration': [parsed], 'hcal': []}
    excluded = population.exclusions_from_attempts(attempts)
    if {row['id'] for row in excluded['calibration']} != {'cos_fixed_point'}:
        raise AssertionError('real parsed refusal was not listed')
    population.validate_exclusions(DATA / 'populations', attempts)
    print('CONTROL recorded certifier refusal: GREEN parsed, listed, removed at every scale')
    return attempts


def unlisted_refusal_plant(log_path, tmp):
    mutant = Path(tmp) / 'refusal-without-row.log'
    mutant.write_text('\n'.join(line for line in Path(log_path).read_text().splitlines()
                               if not line.startswith('REFUSED cos_fixed_point: ')) + '\n')
    population.parse_attempt(DATA / 'populations' / 'cal' / 'x1e6' / 'corpus.json',
                             ['python3', 'certify.py'], 1, mutant)


def retained_refusal_plant(directory, attempts):
    original = json.loads((DATA / 'populations' / 'cal' / 'x1' / 'corpus.json').read_text())
    row = next(row for row in original['rows'] if row['id'] == 'cos_fixed_point')
    path = Path(directory) / 'confirm-cal' / 'x1' / 'corpus.json'
    corpus = json.loads(path.read_text())
    corpus['rows'].append(copy.deepcopy(row))
    population.write_json(path, corpus)
    population.validate_exclusions(directory, attempts)


def copy_corpora(source, target, groups):
    for group, scales in groups:
        for scale in scales:
            dst = Path(target) / group / scale / 'corpus.json'
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(Path(source) / group / scale / 'corpus.json', dst)


def missing_choice(tmp):
    tmp = Path(tmp)
    refusal = tmp / 'choice-refusal.json'
    with contextlib.redirect_stdout(io.StringIO()):
        rc = runner.main(['--confirm', '--choice', str(tmp / 'missing-choice.json'),
                          '--data', str(tmp / 'must-not-open-data'),
                          '--readings', str(tmp / 'must-not-open-readings'), '--out', str(refusal)])
    result = json.loads(refusal.read_text())
    reason = result.get('reason', '')
    if (rc != 2 or result.get('status') != 'REFUSED' or result.get('choice_sha256') is not None
            or 'choice' not in reason.lower()
            or any(word in reason for word in ('must-not-open-data', 'must-not-open-readings'))):
        raise AssertionError(f'wrong confirmation failure or input opened before choice: {result}')
    raise HarnessError('CONFIRMATION REFUSED without choice: ' + reason)


def main(out=None, cases=None, binary=None):
    out = Path(out) if out else None
    if out:
        out.mkdir(parents=True, exist_ok=True)
    cases = Path(cases) if cases else DATA / 'site-coverage' / 'cases.jsonl'
    binary = Path(binary) if binary else DATA / 'site-coverage' / 'binary-readings.json'
    if not cases.is_file() or not binary.is_file():
        raise HarnessError('INCOMPLETE: real binary site oracle has not been captured yet')
    expected, actual = site_control(cases, binary)
    plants = site_plants(cases, binary, out)
    plants += import_plants(out)
    wrong = copy.deepcopy(actual)
    key = next(key for key in sorted(wrong) if type(wrong[key]) is bool)
    wrong[key] = not wrong[key]
    plants += expect_red('one-reading-differs',
                         lambda: identity.compare_records(expected, wrong, 'one real binary reading changed'),
                         'MISMATCH', out)
    missing = dict(actual)
    missing.pop(next(iter(missing)))
    plants += expect_red('missing-reading',
                         lambda: identity.compare_records(expected, missing, 'one real binary reading missing'),
                         'MISSING', out)
    empty = dict(actual)
    empty.clear()
    plants += expect_red('empty-comparison',
                         lambda: identity.compare_records(expected, empty, 'real binary readings removed'),
                         'INCOMPLETE', out)
    population.check_counts(staged_counts(DATA / 'populations'))
    print('CONTROL staged population counts: GREEN derived from files')
    log_path = DATA / 'site-coverage' / 'certifier-refusal.txt'
    attempts = certifier_control(log_path)
    with tempfile.TemporaryDirectory(prefix='r33-selftest-') as directory:
        tmp = Path(directory)
        staged = tmp / 'staged'
        copy_corpora(DATA / 'populations', staged, (('cal', ('x1', 'x1e-3', 'x1e3')),))
        plants += expect_red('ruling-count-differs', lambda: staged_count_plant(staged),
                             'STOP R33-1 item 3', out)
        plants += expect_red('confirmation-refusal-unlisted', lambda: unlisted_refusal_plant(log_path, tmp),
                             'certifier accounting differs', out)
        copies = tmp / 'confirmation'
        copy_corpora(DATA / 'populations', copies,
                     (('confirm-cal', ('x1', 'x1e6')), ('confirm-hcal', tuple(population.SCALES)),
                      ('cal', ('x1',)), ('judge', ('hcal',))))
        plants += expect_red('confirmation-refusal-retained-copy',
                             lambda: retained_refusal_plant(copies, attempts), 'confirmation exclusion roster', out)
        plants += expect_red('confirmation-without-choice', lambda: missing_choice(tmp),
                             'REFUSED without choice', out)
    # Procedure tests are handwritten inputs only; all population-derived
    # checks above remain anchored to staged files and saved real readings.
    import r33_procedure_unit
    import r33_binary_unit
    import r33_port_unit
    r33_procedure_unit.run_hand_tests()
    binary_hands = r33_binary_unit.demonstrations()
    print(f'BINARY HAND: {len(binary_hands["events"])} demonstrations; no binary/population run')
    r33_port_unit.main()
    print(f'PORT UNIT: {r33_port_unit.CHECKS} checks passed')
    print(f'R33 SELFTEST: {plants} plants caught, 0 survived; real controls green')
    return plants


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selftest', action='store_true', help='explicit registry self-test mode')
    parser.add_argument('--out')
    parser.add_argument('--cases', type=Path)
    parser.add_argument('--binary-readings', type=Path)
    args = parser.parse_args()
    try:
        main(args.out, args.cases, args.binary_readings)
    except (AssertionError, HarnessError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        print('R33 SELFTEST FAILED: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
