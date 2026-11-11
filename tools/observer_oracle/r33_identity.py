#!/usr/bin/env python3
"""F0-only identity, R33-1 item 1. This module never computes experiment metrics.

The frozen scorer owns corpus emission, value/count checking and four-tier
witnesses. Explicit identity inputs additionally compare every scalar and
type at every index. A complete manifest must exist before any binary read.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

import derive
from gen import HarnessError, generate
import r33_fixtures as fixtures
import r33_population as population
from r33_port import Slot
from schema import PREDS
import score

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def encode(v):
    if v is None or type(v) in (bool, str, int):
        return v
    if isinstance(v, float):
        return {"float": v.hex()}
    if isinstance(v, dict):
        return {k: encode(x) for k, x in v.items()}
    return [encode(x) for x in v]


def same(a, b):
    if type(a) is not type(b):
        return False
    if isinstance(a, float):
        return (math.isnan(a) and math.isnan(b)) or struct.pack('>d', a) == struct.pack('>d', b)
    return a == b


def compare_records(expected, actual, label):
    """Membership both ways; empty never passes. Used by real run and plants."""
    if not expected or not actual:
        raise HarnessError(f"INCOMPLETE {label}: empty comparison")
    if expected.keys() != actual.keys():
        missing, extra = sorted(expected.keys()-actual.keys()), sorted(actual.keys()-expected.keys())
        raise HarnessError(f"MISSING {label}: missing={missing[:3]} extra={extra[:3]}")
    wrong = [k for k in expected if not same(expected[k], actual[k])]
    if wrong:
        k = wrong[0]
        raise HarnessError(f"MISMATCH {label}: {k}: port={expected[k]!r} binary={actual[k]!r}")
    return len(expected)


def verify_manifest(path):
    m = json.loads(Path(path).read_text())
    if m['subject']['commit'] != '54008422b7bb4950131f4dd4d15ead942a2ecb2e':
        raise HarnessError('subject is not fixed F0')
    for name, want in m['files'].items():
        p = ROOT/name
        if not p.is_file() or sha(p) != want:
            raise HarnessError(f'MANIFEST changed or missing file: {name}')
    base = 'tools/observer_oracle/'
    data = base+'r33_data/populations/'
    required = {'canonical':base+'corpus.json','released-hcal':base+'hcal/corpus.json'}
    for group,scales in (('cal',('x1','x1e-3','x1e3')),
                         ('confirm-cal',('x1','x1e6')),
                         ('confirm-hcal',tuple(population.SCALES))):
        required.update({group+'-'+s:data+group+'/'+s+'/corpus.json' for s in scales})
    actual = {entry['name']:entry['corpus'] for entry in m['sets']}
    if actual != required or len(m['sets']) != len(required):
        raise HarnessError('MANIFEST incomplete or duplicate identity population roster')
    mandatory = set(required.values())
    for corpus_path in required.values():
        parent = Path(corpus_path).parent
        mandatory.update(str(parent/name) for name in ('certificate.json','labels.json'))
    mandatory.update(str(p.relative_to(ROOT)) for p in (ROOT/base).glob('r33_*.py'))
    mandatory.update(str(p.relative_to(ROOT)) for p in (ROOT/base/'r33_data').rglob('*')
                     if p.is_file() and p.name != 'MANIFEST.json')
    if not mandatory <= m['files'].keys():
        raise HarnessError('MANIFEST omits mandatory instrument, population or fixture files')
    expected_inputs = [base+'r33_data/identity/seeded.jsonl',base+'r33_data/identity/anchors.jsonl']
    if m['identity_inputs'] != expected_inputs or m['identity_programs'] != base+'r33_data/identity/programs':
        raise HarnessError('MANIFEST incomplete fixed identity input roster')
    inputs = [json.loads(line) for name in expected_inputs for line in (ROOT/name).read_text().splitlines()]
    if inputs != list(fixtures.fixtures()):
        raise HarnessError('MANIFEST identity inputs differ from fixed 512 sequences plus four anchors')
    if len(inputs) != 516 or any(row['checkpoints'] != list(range(32)) for row in inputs):
        raise HarnessError('MANIFEST missing declared fixture index')
    counts = json.loads((ROOT/data/'confirmation-counts.json').read_text())
    if m['confirmation'] != counts:
        raise HarnessError('MANIFEST confirmation receipt differs from certified populations')
    for name, relative in required.items():
        corpus = derive.load_corpus(str(ROOT/relative))
        got = (len(corpus['rows']),sum(len(row['checkpoints']) for row in corpus['rows']))
        want = ((72,118) if name=='canonical' else (32,96) if name=='released-hcal' else
                (61,97) if name.startswith('cal-') else
                tuple(counts['comparison_sets']['i' if name.startswith('confirm-hcal-') else 'ii'][k]
                      for k in ('rows','checkpoints')))
        if got != want:
            raise HarnessError(f'MANIFEST {name}: identity population {got} differs from {want}')
    return m


def model_values(row):
    xs = generate(row['gen'], row['n'])
    out = []
    for step in score.steps(row, xs, row['n']):
        out.append(step[1] if step[0] == 'set' else out[-1]*step[1]+step[2])
    return out


def model_corpus(corpus, name):
    result, records = {}, []
    for row in corpus['rows']:
        slot = Slot(policy='F0')
        checks = set(row['checkpoints'])
        for at, value in enumerate(model_values(row)):
            slot.record(value)
            if at in checks:
                reading = slot.reading()
                for p in PREDS:
                    for tier, form in score.ARMS:
                        result[(tier, form, row['id'], at, p)] = reading[p]
                records.append(dict(set=name, row=row['id'], at=at,
                                    predicates={p: reading[p] for p in PREDS}))
    return result, records


def primitive(token, kind=None):
    if token == 'null':
        return None
    if kind == 'int':
        return int(token)
    return float(token)


def fixture_output(row, lines):
    if not lines or lines[-1] != 'DONE '+row['id']:
        raise HarnessError(f'MISSING {row["id"]}: final marker')
    actual = {}
    fields = (*PREDS, 'report', 'where', 'where_kind', 'why', 'why_kind', 'how', 'count')
    for line in lines[:-1]:
        parts = line.split()
        if len(parts) != 18 or parts[:2] != ['I', row['id']]:
            raise HarnessError(f'MALFORMED {row["id"]}: {line!r}')
        at = int(parts[2])
        if at not in row['checkpoints']:
            raise HarnessError(f'EXTRA {row["id"]}@{at}')
        if any(x not in ('true', 'false') for x in parts[3:9]):
            raise HarnessError(f'MALFORMED boolean {line!r}')
        values = [x == 'true' for x in parts[3:9]] + [parts[9], primitive(parts[10], parts[11]), parts[11],
                  primitive(parts[12], parts[13]), None if parts[13] == 'null' else parts[13],
                  primitive(parts[14]), int(parts[15])]
        if any(x not in ('true', 'false') for x in parts[16:18]):
            raise HarnessError(f'MALFORMED zero sign {line!r}')
        # The fixed scorer does not rely on printed zero signs either.
        for index, negative in ((7, parts[16] == 'true'), (9, parts[17] == 'true')):
            if type(values[index]) is float and values[index] == 0.0:
                values[index] = math.copysign(0.0, -1.0 if negative else 1.0)
        for key, value in zip(fields, values):
            if (at, key) in actual:
                raise HarnessError(f'DUPLICATE {row["id"]}@{at} {key}')
            actual[(at, key)] = value
    return actual


def model_fixture(row):
    result = {}
    slot = Slot(policy='F0')
    for at, typed_value in enumerate(row['values']):
        slot.record(fixtures.untyped(typed_value))
        r = slot.reading()
        for p in (*PREDS, 'report', 'where', 'where_kind', 'why', 'why_kind', 'how', 'count'):
            result[(at, p)] = r[p]
    return result


def write_json(path, value):
    Path(path).write_text(json.dumps(encode(value), indent=2, sort_keys=True)+'\n')


def run(manifest_path, binary, out):
    m = verify_manifest(manifest_path)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    binary = str(Path(binary).resolve())
    stamp = json.loads((Path(binary).parents[2]/'arm.json').read_text())
    if stamp['source_sha'] != m['subject']['commit'] or stamp['recipe_id'] != m['subject']['recipe_sha256']:
        raise HarnessError('identity binary is not recipe-built fixed subject')
    if stamp['recipe_id'] != sha(ROOT/m['subject']['recipe_script']):
        raise HarnessError('identity recipe script differs from binary stamp')
    if sha(binary) != stamp['binary_sha256']:
        raise HarnessError('identity binary differs from recipe stamp')
    ieee, caps, probes = score.capabilities(binary)
    if not ieee or not all(caps.values()):
        raise HarnessError(f'F0 missing capabilities: {caps}')
    write_json(out/'subject.json', dict(manifest_sha256=sha(manifest_path), stamp=stamp, probes=probes))
    all_records, counts, binary_a, binary_b = [], [], [], []
    for entry in m['sets']:
        path = ROOT/entry['corpus']
        corpus = derive.load_corpus(str(path))
        want, records = model_corpus(corpus, entry['name'])
        got = score.measure(binary, corpus, caps)
        if got['skipped']:
            raise HarnessError(f'MISSING {entry["name"]}: {got["skipped"]}')
        score.check_witnessed(got)
        if score.findings(got):
            raise HarnessError(f'TIER MISMATCH {entry["name"]}: {score.findings(got)[:1]}')
        try:
            compared = compare_records(want, got['read'], entry['name'])
        except HarnessError as error:
            differing = next((k for k in want if k not in got['read'] or not same(want[k], got['read'][k])), None)
            window = None
            if differing is not None:
                row = next(r for r in corpus['rows'] if r['id'] == differing[2])
                window = model_values(row)[max(0,differing[3]-10):differing[3]+1]
            write_json(out/(entry['name']+'.mismatch.json'),dict(error=str(error),key=differing,window=window))
            raise
        write_json(out/(entry['name']+'.binary.json'),
                   dict(readings=[dict(key=list(k), value=v) for k,v in sorted(got['read'].items())],
                        witnesses=[dict(key=list(k), value=v) for k,v in sorted(got['wit'].items())],
                        runs=got['runs']))
        values = sum(len(v) for v in got['held'].values())
        summary = dict(set=entry['name'], rows=len(corpus['rows']),
                       checkpoints=sum(len(r['checkpoints']) for r in corpus['rows']),
                       predicate_readings=compared, assignment_values_checked=values, mismatches=0)
        counts.append(summary)
        all_records.extend(records)
        # A/A repeats the real fixed-subject binary, including the frozen
        # value/count and four-tier witness checks, with fresh observer state.
        second = score.measure(binary, corpus, caps)
        score.check_witnessed(second)
        if second['skipped'] or score.findings(second):
            raise HarnessError(f'A/A incomplete or tier mismatch {entry["name"]}')
        compare_records(got['read'],second['read'],entry['name']+' binary A/A')
        write_json(out/(entry['name']+'.binary-aa.json'),
                   dict(readings=[dict(key=list(k),value=v) for k,v in sorted(second['read'].items())],
                        witnesses=[dict(key=list(k),value=v) for k,v in sorted(second['wit'].items())],
                        runs=second['runs']))
        for result, target in ((got,binary_a),(second,binary_b)):
            target.extend(dict(set=entry['name'],key=list(k),value=v) for k,v in sorted(result['read'].items()))
        summary['binary_aa_predicate_readings'] = len(second['read'])
        print('IDENTITY '+json.dumps(summary, sort_keys=True), flush=True)
    fixture_counts = {'seeded': 0, 'anchors': 0}
    for relative in m['identity_inputs']:
        for line in (ROOT/relative).read_text().splitlines():
            row = json.loads(line)
            program = ROOT/m['identity_programs']/(row['id']+'.eigs')
            # Lint reads fixtures too: it happens only after committed manifest.
            lint = score.run_group([binary, '--lint', '--json', str(program)], 120,
                                   env=score.scrubbed({'EIGS_JIT_OFF': '1'}))
            (out/(row['id']+'.lint.json')).write_text(lint.stdout)
            if lint.returncode or any(x.get('severity') == 'error' for x in json.loads(lint.stdout)):
                raise HarnessError(f'LINT {row["id"]}: rc={lint.returncode} {lint.stderr}')
            rc, lines, errors, stderr, _ = score.run(binary, str(program), {'EIGS_JIT_OFF': '1'})
            (out/(row['id']+'.stdout')).write_text('\n'.join(lines)+'\n')
            (out/(row['id']+'.stderr')).write_text(stderr)
            if rc or errors:
                raise HarnessError(f'FIXTURE {row["id"]}: rc={rc} {errors}')
            want, actual = model_fixture(row), fixture_output(row, lines)
            try:
                compare_records(want, actual, row['id'])
            except HarnessError as error:
                write_json(out/(row['id']+'.mismatch.json'), dict(error=str(error), values=row['values'],
                                                               port=[(list(k),v) for k,v in want.items()]))
                raise
            rc2, lines2, errors2, stderr2, _ = score.run(binary,str(program),{'EIGS_JIT_OFF':'1'})
            if rc2 or errors2:
                raise HarnessError(f'A/A FIXTURE {row["id"]}: rc={rc2} {errors2}')
            (out/(row['id']+'.aa.stdout')).write_text('\n'.join(lines2)+'\n')
            second = fixture_output(row,lines2)
            compare_records(actual,second,row['id']+' binary A/A')
            for result,target in ((actual,binary_a),(second,binary_b)):
                target.extend(dict(set='fixture',row=row['id'],key=list(k),value=encode(v))
                              for k,v in sorted(result.items()))
            group = 'seeded' if row['id'].startswith('seeded-') else 'anchors'
            fixture_counts[group] += len(row['checkpoints'])
            for at in row['checkpoints']:
                all_records.append(dict(set=group, row=row['id'], at=at,
                                        predicates={p: want[(at,p)] for p in PREDS}))
    # A/A is a second independent F0 port evaluation, with no metric reduction.
    repeated = []
    for entry in m['sets']:
        _, records = model_corpus(derive.load_corpus(str(ROOT/entry['corpus'])), entry['name'])
        repeated.extend(records)
    for relative in m['identity_inputs']:
        for line in (ROOT/relative).read_text().splitlines():
            row = json.loads(line)
            want = model_fixture(row)
            group = 'seeded' if row['id'].startswith('seeded-') else 'anchors'
            repeated.extend(dict(set=group, row=row['id'], at=at, predicates={p:want[(at,p)] for p in PREDS})
                            for at in row['checkpoints'])
    for name, records in (('f0-aa-1.jsonl',all_records), ('f0-aa-2.jsonl',repeated)):
        (out/name).write_text(''.join(json.dumps(r, sort_keys=True)+'\n' for r in records))
    if sha(out/'f0-aa-1.jsonl') != sha(out/'f0-aa-2.jsonl'):
        raise HarnessError('A/A MISMATCH: independent F0 repetitions differ')
    for name,records in (('binary-aa-1.jsonl',binary_a),('binary-aa-2.jsonl',binary_b)):
        (out/name).write_text(''.join(json.dumps(r,sort_keys=True)+'\n' for r in records))
    if sha(out/'binary-aa-1.jsonl') != sha(out/'binary-aa-2.jsonl'):
        raise HarnessError('A/A MISMATCH: independent real F0 binary repetitions differ')
    counts.extend(dict(set=k, checkpoints=v, predicate_readings=v*6, scalar_fields=7,
                       total_fields_compared=v*13, mismatches=0) for k,v in fixture_counts.items())
    write_json(out/'counts.json', dict(sets=counts, aa_sha256=sha(out/'f0-aa-1.jsonl'),
                                    binary_aa_sha256=sha(out/'binary-aa-1.jsonl'),
                                    manifest_sha256=sha(manifest_path), mismatches=0))
    print('IDENTITY zero mismatches; every declared checkpoint and fixture index compared')
    print('F0 A/A byte-identical '+sha(out/'f0-aa-1.jsonl'))
    print('F0 binary A/A byte-identical '+sha(out/'binary-aa-1.jsonl'))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', required=True)
    p.add_argument('--binary', required=True)
    p.add_argument('--out', required=True)
    args = p.parse_args()
    try:
        run(args.manifest, args.binary, args.out)
    except (HarnessError, OSError, ValueError) as error:
        print('IDENTITY REFUSED: '+str(error), file=sys.stderr)
        raise SystemExit(2)
