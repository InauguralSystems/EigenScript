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
import os
from pathlib import Path
import struct
import sys
import tempfile

import derive
from gen import HarnessError, generate
import r33_fixtures as fixtures
import r33_boundaries as boundaries
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
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, (list, tuple)):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
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
    coverage = m['site_coverage']
    casepath = ROOT/coverage['inputs']
    cases = [json.loads(line) for line in casepath.read_text().splitlines()]
    if cases != boundaries.fixtures() or not cases or any(r['window'] != 10 for r in cases):
        raise HarnessError('MANIFEST purpose inputs differ from written F0 windows')
    if {p.name for p in (ROOT/coverage['programs']).iterdir()} != {r['id']+'.eigs' for r in cases}:
        raise HarnessError('MANIFEST missing or extra purpose program')
    for row in cases:
        program = ROOT/coverage['programs']/(row['id']+'.eigs')
        if program.read_text() != fixtures.emit(row):
            raise HarnessError('MANIFEST purpose program differs from declared window: '+row['id'])
    import r33_surfaces as surfaces
    surfaces.verify(ROOT/coverage['surfaces'])
    if 'imports' in coverage:
        import r33_imports as imports
        imports.verify(ROOT/coverage['imports'])
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


def model_fixture(row, slot_type=Slot):
    result = {}
    slot = slot_type(policy='F0', window=row.get('window',10))
    for at, typed_value in enumerate(row['values']):
        slot.record(fixtures.untyped(typed_value))
        r = slot.reading()
        for p in (*PREDS, 'report', 'where', 'where_kind', 'why', 'why_kind', 'how', 'count'):
            result[(at, p)] = r[p]
    return result


def write_json(path, value):
    Path(path).write_text(json.dumps(encode(value), indent=2, sort_keys=True)+'\n')


def build_claim(binary, name, commit, arm, manifest, choice_path=None):
    """Validate a declared future build without replacing F0's fixed subject.

    The default run() below remains fixed to F0. This separate path serves
    item 18 and its independent replication. A non-F0 build needs the posted
    calibration choice before any confirmation population is opened.
    """
    import r33_metrics as metrics
    from r33_port import POLICIES
    if not isinstance(name, str) or not name or arm not in POLICIES:
        raise HarnessError('BUILD CLAIM: named build and registered claimed arm required')
    if not isinstance(commit, str) or len(commit) != 40 or any(c not in '0123456789abcdef' for c in commit):
        raise HarnessError('BUILD CLAIM: declared commit must be a full lowercase SHA')
    choice_digest = None
    if arm != 'F0':
        choice, choice_digest = metrics.choice_file(choice_path)
        if arm not in (choice['arm'], 'STD-rel'):
            raise HarnessError('BUILD CLAIM: claimed arm differs from provisional choice/STD-rel')
    elif commit != manifest['subject']['commit']:
        raise HarnessError('BUILD CLAIM: F0 is the fixed subject commit')
    binary = Path(binary).resolve()
    stamp = json.loads((binary.parents[2]/'arm.json').read_text())
    if stamp.get('source_sha') != commit or stamp.get('recipe_id') != sha(ROOT/'tools/observer_oracle/build_arm.sh'):
        raise HarnessError('BUILD CLAIM: declared commit/recipe differs from build stamp')
    if stamp.get('binary_sha256') != sha(binary):
        raise HarnessError('BUILD CLAIM: binary differs from build stamp')
    return dict(name=name, commit=commit, arm=arm, choice_sha256=choice_digest, stamp=stamp)


def baseline_claim(manifest, binary=None):
    """The local F0 recipe build used by the later paired judge, without running it."""
    subject = manifest['subject']
    if binary is None:
        cache = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home()/'.cache')))
        binary = cache/'eigs-oracle-arms'/subject['recipe_sha256']/subject['commit']/'build/release/eigenscript'
    binary = Path(binary).resolve()
    stamp = json.loads((binary.parents[2]/'arm.json').read_text())
    if (stamp.get('source_sha') != subject['commit']
            or stamp.get('recipe_id') != subject['recipe_sha256']
            or stamp.get('binary_sha256') != sha(binary)):
        raise HarnessError('BUILD CLAIM: local F0 baseline differs from its source/recipe/stamp')
    return {key:stamp[key] for key in ('source_sha','recipe_id','binary_sha256')}


def compare_build_records(want, actual, *, name, commit, arm, checkpoints,
                          manifest_sha256, choice_sha256=None):
    """Common strict comparison and proof envelope, also shown on hand inputs."""
    if type(checkpoints) is not int or checkpoints <= 0:
        raise HarnessError('BUILD IDENTITY: no declared confirmation checkpoints')
    compared = compare_records(want, actual, name+' build against '+arm)
    if compared != checkpoints * 13:
        raise HarnessError('BUILD IDENTITY: every confirmation checkpoint needs all 13 queried fields')
    return dict(format='r33-build-identity/1', name=name, commit=commit, arm=arm,
                status='MATCH', mismatches=0, checkpoints=checkpoints,
                fields_compared=compared, manifest_sha256=manifest_sha256,
                choice_sha256=choice_sha256)


def confirmation_build(manifest_path, binary, out, *, name, commit, arm, choice_path=None, f0_binary=None):
    """Item18: a named recipe build versus its claimed policy, all guard/U/Z/K rows.

    The confirmation's released72+H-cal BA guards are included as well as
    both scaled comparison sets. Exact K is present in canonical. Every
    queried field used by F0 identity is compared at each checkpoint;
    quiet remains unqueryable. No experiment metric is computed here.
    """
    manifest = verify_manifest(manifest_path)
    claim = build_claim(binary, name, commit, arm, manifest, choice_path)
    baseline = baseline_claim(manifest, f0_binary)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    write_json(out/'claim.json', dict(manifest_sha256=sha(manifest_path), **claim))
    wanted, actual, summaries = {}, {}, []
    fields = (*PREDS, 'report', 'where', 'where_kind', 'why', 'why_kind', 'how', 'count')
    selected = [entry for entry in manifest['sets']
                if entry['name'].startswith('confirm-') or entry['name'] in ('canonical','released-hcal')]
    if not selected:
        raise HarnessError('BUILD IDENTITY: manifest declares no confirmation populations')
    with tempfile.TemporaryDirectory(prefix='r33_build_identity_') as temporary:
        for entry in selected:
            corpus = derive.load_corpus(str(ROOT/entry['corpus']))
            declared_count = 0
            for row in corpus['rows']:
                values = model_values(row)
                fixture = dict(id='build-'+row['id'], values=[fixtures.typed(value) for value in values],
                               checkpoints=list(range(len(values))))
                program = Path(temporary)/(fixture['id']+'.eigs')
                program.write_text(fixtures.emit(fixture))
                rc, lines, errors, stderr, _ = score.run(str(binary), str(program), {'EIGS_JIT_OFF':'1'})
                prefix = entry['name']+'--'+row['id']
                (out/(prefix+'.stdout.txt')).write_text('\n'.join(lines)+'\n')
                (out/(prefix+'.stderr.txt')).write_text(stderr)
                if rc or errors:
                    raise HarnessError(f'BUILD IDENTITY {prefix}: rc={rc} errors={errors} stderr={stderr}')
                read = fixture_output(fixture, lines)
                slot = Slot(policy=arm)
                for at, value in enumerate(values):
                    slot.record(value)
                    if at not in row['checkpoints']:
                        continue
                    port = slot.reading()
                    for field in fields:
                        key = (entry['name'], row['id'], at, field)
                        wanted[key], actual[key] = port[field], read[at, field]
                    declared_count += 1
                try:
                    compare_records({key:value for key,value in wanted.items() if key[:2] == (entry['name'],row['id'])},
                                    {key:value for key,value in actual.items() if key[:2] == (entry['name'],row['id'])}, prefix)
                except HarnessError as error:
                    write_json(out/'mismatch.json', dict(error=str(error), set=entry['name'],row=row['id'],
                               checkpoints=row['checkpoints'], values=values))
                    raise
            summaries.append(dict(set=entry['name'], rows=len(corpus['rows']), checkpoints=declared_count,
                                  fields_compared=declared_count*13, mismatches=0))
    result = compare_build_records(wanted, actual, name=name, commit=commit, arm=arm,
        checkpoints=sum(summary['checkpoints'] for summary in summaries),
        manifest_sha256=sha(manifest_path), choice_sha256=claim['choice_sha256'])
    result['sets'] = summaries
    result['binary_sha256'] = claim['stamp']['binary_sha256']
    result['recipe_id'] = claim['stamp']['recipe_id']
    result['f0'] = baseline
    write_json(out/'build-identity.json',result)
    write_json(out/'port-readings.json',dict(readings=[dict(key=list(key),value=value) for key,value in sorted(wanted.items())]))
    write_json(out/'binary-readings.json',dict(readings=[dict(key=list(key),value=value) for key,value in sorted(actual.items())]))
    print('BUILD IDENTITY zero mismatches; every confirmation checkpoint and queried field compared')
    return result


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
    fixture_counts = {'seeded': 0, 'anchors': 0, 'site-windows': 0}
    site_records = []
    fixture_specs = [(relative, m['identity_programs']) for relative in m['identity_inputs']]
    fixture_specs.append((m['site_coverage']['inputs'],m['site_coverage']['programs']))
    for relative, program_directory in fixture_specs:
        for line in (ROOT/relative).read_text().splitlines():
            row = json.loads(line)
            program = ROOT/program_directory/(row['id']+'.eigs')
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
            group = ('seeded' if row['id'].startswith('seeded-') else
                     'anchors' if row['id'].startswith('ieee-anchor-') else 'site-windows')
            if group == 'site-windows':
                site_records.extend(dict(key=[row['id'],*k],value=encode(v)) for k,v in sorted(actual.items()))
            fixture_counts[group] += len(row['checkpoints'])
            for at in row['checkpoints']:
                all_records.append(dict(set=group, row=row['id'], at=at,
                                        predicates={p: want[(at,p)] for p in PREDS}))
    # A/A is a second independent F0 port evaluation, with no metric reduction.
    repeated = []
    for entry in m['sets']:
        _, records = model_corpus(derive.load_corpus(str(ROOT/entry['corpus'])), entry['name'])
        repeated.extend(records)
    for relative, _ in fixture_specs:
        for line in (ROOT/relative).read_text().splitlines():
            row = json.loads(line)
            want = model_fixture(row)
            group = ('seeded' if row['id'].startswith('seeded-') else
                     'anchors' if row['id'].startswith('ieee-anchor-') else 'site-windows')
            repeated.extend(dict(set=group, row=row['id'], at=at, predicates={p:want[(at,p)] for p in PREDS})
                            for at in row['checkpoints'])
    import r33_surfaces as surfaces
    surface_sets = [(surfaces, 'surfaces', 'surface', 'language-surfaces')]
    if 'imports' in m['site_coverage']:
        import r33_imports as imports
        surface_sets.append((imports, 'imports', 'import', 'trajectory-imports'))
    surface_summaries = []
    for module, manifest_key, record_set, summary_name in surface_sets:
        surface_count, surface_records = 0, []
        for row in module.cases():
            program = ROOT/m['site_coverage'][manifest_key]/'programs'/(row['id']+'.eigs')
            lint = score.run_group([binary,'--lint','--json',str(program)],120,
                                   env=score.scrubbed({'EIGS_JIT_OFF':'1'}))
            (out/(row['id']+'.lint.json')).write_text(lint.stdout)
            if lint.returncode or any(x.get('severity')=='error' for x in json.loads(lint.stdout)):
                raise HarnessError(f'SURFACE LINT {row["id"]}: {lint.stdout} {lint.stderr}')
            want = module.model(row)
            actuals = []
            for suffix in ('stdout','aa.stdout'):
                rc,lines,errors,stderr,_ = score.run(binary,str(program),{'EIGS_JIT_OFF':'1'})
                (out/(row['id']+'.'+suffix)).write_text('\n'.join(lines)+'\n')
                (out/(row['id']+'.'+suffix+'.stderr')).write_text(stderr)
                if rc or errors:
                    raise HarnessError(f'SURFACE {row["id"]}: rc={rc} {errors} {stderr}')
                actuals.append(module.parse(row,lines))
            try:
                surface_count += compare_records(want,actuals[0],row['id'])
                compare_records(actuals[0],actuals[1],row['id']+' binary A/A')
            except HarnessError as error:
                write_json(out/(row['id']+'.mismatch.json'),dict(error=str(error),input=row,
                    port=[dict(key=list(k),value=encode(v)) for k,v in sorted(want.items())],
                    binary=[dict(key=list(k),value=encode(v)) for k,v in sorted(actuals[0].items())]))
                raise
            for actual, target in zip(actuals,(binary_a,binary_b)):
                target.extend(dict(set=record_set,row=row['id'],key=list(k),value=encode(v))
                              for k,v in sorted(actual.items()))
            surface_records.extend(dict(key=[row['id'],*k],value=encode(v)) for k,v in sorted(actuals[0].items()))
            # Persist scalar identity answers only; no population metric reduction.
            all_records.extend(dict(set=record_set,row=row['id'],key=list(k),value=encode(v)) for k,v in sorted(want.items()))
            repeated.extend(dict(set=record_set,row=row['id'],key=list(k),value=encode(v)) for k,v in sorted(module.model(row).items()))
        write_json(out/(record_set+'-binary-readings.json'),
                   dict(format='r33-'+record_set+'-binary/1',readings=surface_records))
        surface_summaries.append(dict(set=summary_name,windows=len(module.cases()),
                                      total_fields_compared=surface_count,mismatches=0))
    write_json(out/'site-binary-readings.json',dict(format='r33-site-binary/1',readings=site_records))
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
    counts.extend(surface_summaries)
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
    p.add_argument('--build-name', help='item18/20 declared build identity instead of fixed F0 fixture identity')
    p.add_argument('--commit', help='full declared build commit for --build-name')
    p.add_argument('--claimed-arm', help='registered policy claimed by --build-name')
    p.add_argument('--choice', help='posted calibration choice for a non-F0 build')
    p.add_argument('--f0', help='local recipe-built F0 baseline for build/judge linkage; defaults to recipe cache')
    args = p.parse_args()
    try:
        if args.build_name:
            confirmation_build(args.manifest,args.binary,args.out,name=args.build_name,
                               commit=args.commit,arm=args.claimed_arm,choice_path=args.choice,f0_binary=args.f0)
        else:
            if args.commit or args.claimed_arm or args.choice or args.f0:
                raise HarnessError('BUILD CLAIM: build metadata requires --build-name')
            run(args.manifest, args.binary, args.out)
    except (HarnessError, OSError, ValueError) as error:
        print('IDENTITY REFUSED: '+str(error), file=sys.stderr)
        raise SystemExit(2)
