#!/usr/bin/env python3
"""R33-1 population construction and label-only inventory; no subject imports.

Generate only released calibration/H-cal transforms. Certify/derive stay frozen
and are run as programs, serially. Under R33-1 addendum 1 a refused confirmation
copy excludes its base from that comparison component at every scale. The
three-scale calibration remains fixed. No subject or metric runs live here.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
import derive
from gen import HarnessError, generate
from schema import PREDS

SCALES = {'x1': 1.0, 'x1e-3': 1e-3, 'x1e3': 1e3, 'x1e6': 1e6}
Z_EXPECTED = {'geo_decay_0.5', 'geo_decay_0.9', 'damped_osc_0.9',
              'neg_decay', 'two_vars', 'issue1891_repeated_tail'}
EXPECTED = {'corpus_rows': (1, 72), 'corpus_checkpoints': (1, 118),
            'runnable_rows': (3, 63), 'runnable_checkpoints': (3, 100),
            'bases': (3, 61), 'base_checkpoints': (3, 97),
            'scaled_rows': (3, 183), 'calibration_comparisons': (3, 194),
            'calibration_above_comparisons': (8, 50),
            'hcal_rows': (12, 32)}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def require_nonempty(items, name):
    if not items:
        raise HarnessError(f'INCOMPLETE: empty {name}')
    return items


def check_counts(counts):
    for name, (item, expected) in EXPECTED.items():
        if counts.get(name) != expected:
            raise HarnessError(f'STOP R33-1 item {item}: {name}: derived {counts.get(name)!r}, ruling {expected}')


def staged_counts(dest):
    """Re-derive the actual staged calibration roster and masks for its gate.

    This reads the three corpus files the identity/sweep consumes, rather
    than handing the checker its own expected-count dictionary.
    """
    dest=Path(dest)
    source, hcal, bases, hbases, receipt=sources()
    counts=dict(receipt['counts'])
    corpora={s:derive.load_corpus(str(dest/'cal'/s/'corpus.json')) for s in ('x1','x1e-3','x1e3')}
    reference={r['id'] for r in bases}
    for scale,corpus in corpora.items():
        if {r['id'] for r in corpus['rows']} != reference:
            raise HarnessError(f'STOP R33-1 item3: staged calibration {scale} row roster differs from the ruled source')
    rows=corpora['x1']['rows']
    checkpoints=sum(len(r['checkpoints']) for r in rows)
    counts.update(bases=len(rows),base_checkpoints=checkpoints,
                  scaled_rows=sum(len(c['rows']) for c in corpora.values()),calibration_comparisons=checkpoints*2)
    minimum=corpora['x1e-3']['rows']
    above=0
    for row in minimum:
        xs=generate(row['gen'],row['n'])
        above+=sum(all(math.isfinite(v) and abs(v)>=1e-2 for v in xs[max(0,at-10):at+1])
                   for at in row['checkpoints'])
    counts['calibration_above_comparisons']=above*2
    check_counts(counts)
    return counts


def scale_gen(g, scale):
    """Positive unit transform: parameters regenerate each sequence in binary64.

    A recurrence becomes y_n = scale*f(y_(n-1)/scale,n). Closed forms
    multiply their output. For in-program affine maps x0 and b carry units,
    while a does not. Every numeric program is float, x1 included.
    """
    if scale not in SCALES.values():
        raise HarnessError(f'unregistered scale {scale!r}')
    q = copy.deepcopy(g)
    q.pop('int', None)
    kind = q['kind']
    if kind == 'affine':
        q.update(x0=float(q['x0']) * scale, a=float(q['a']), b=float(q['b']) * scale)
    elif kind == 'pieces':
        for piece in q['pieces']:
            for key in ('x0', 'b'):
                if key in piece:
                    piece[key] = float(piece[key]) * scale
            piece['a'] = float(piece['a'])
    elif kind == 'closed':
        q['expr'] = f'({q["expr"]}) * {scale!r}'
    elif kind == 'recur':
        q['x0'] = float(q['x0']) * scale
        expr = re.sub(r'\bx\b', f'(x / {scale!r})', q['expr'])
        q['expr'] = f'({expr}) * {scale!r}'
    elif kind == 'cycle':
        q['values'] = [float(v) * scale for v in q['values']]
    elif kind == 'noise':
        for key in ('center', 'amp'):
            q[key] = float(q[key]) * scale
    elif kind in ('walk', 'uwalk'):
        for key in ('x0', 'step'):
            q[key] = float(q[key]) * scale
    elif kind == 'ar1':
        for key in ('mu', 'sigma'):
            q[key] = float(q[key]) * scale
    else:
        raise HarnessError(f'no registered scaling recipe for {kind!r}')
    return q


def scale_row(row, scale):
    out = copy.deepcopy(row)
    for key in ('gen', 'second'):
        if key in out:
            out[key] = scale_gen(out[key], scale)
    if out['props']['limit'] is not None:
        out['props']['limit'] = float(out['props']['limit']) * scale
    if 'manual' in out:
        m = out['manual']
        if m['claims']['limit'] is not None:
            m['claims']['limit'] = float(m['claims']['limit']) * scale
        m['argument'] = (f'Positive unit transform y={scale!r}*x; apply the following source '
                         'argument in the coordinate x=y/scale. Finite limits multiply by scale; '
                         'boundedness and the sign of an infinite limit are preserved. '
                         + m['argument'])
    out.pop('capability', None)
    cap = derive.capability(out)
    if cap:
        out['capability'] = cap
    return out


def values(row, scale, second=False):
    return generate(scale_gen(row['second' if second else 'gen'], scale), max(row['checkpoints']))


def eligible(rows):
    kept, excluded = [], []
    for row in rows:
        failures = []
        for name, scale in SCALES.items():
            for second in ((False, True) if 'second' in row else (False,)):
                for index, value in enumerate(values(row, scale, second)):
                    if not math.isfinite(value) or abs(value) >= 1e305:
                        failures.append({'scale': name, 'binding': 'y' if second else 'x',
                                         'index': index, 'value': repr(value)})
                        break
        if failures:
            excluded.append({'id': row['id'], 'failures': failures})
        else:
            kept.append(row)
    return kept, excluded


def above_floor(rows, scale):
    out = []
    for row in rows:
        xs = values(row, scale)
        for at in row['checkpoints']:
            window = xs[max(0, at - 10):at + 1]
            if all(math.isfinite(v) and abs(v) >= 1e-2 for v in window):
                out.append({'id': row['id'], 'checkpoint': at, 'minimum_abs': min(abs(v) for v in window)})
    return out


def sources():
    cal = derive.load_corpus(str(HERE / 'corpus.json'))
    hcal = derive.load_corpus(str(HERE / 'hcal/corpus.json'))
    common = [r for r in cal['rows'] if not r.get('capability')]
    bases, excluded = eligible(common)
    hbases, hexcluded = eligible(hcal['rows'])
    ca, ha, cx = above_floor(bases, 1e-3), above_floor(hbases, 1e-3), above_floor(bases, 1.0)
    counts = {'corpus_rows': len(cal['rows']), 'corpus_checkpoints': sum(len(r['checkpoints']) for r in cal['rows']),
              'runnable_rows': len(common), 'runnable_checkpoints': sum(len(r['checkpoints']) for r in common),
              'bases': len(bases), 'base_checkpoints': sum(len(r['checkpoints']) for r in bases),
              'scaled_rows': len(bases)*3, 'calibration_comparisons': sum(len(r['checkpoints']) for r in bases)*2,
              'calibration_above_comparisons': len(ca)*2,
              'hcal_rows': len(hbases), 'hcal_checkpoints': sum(len(r['checkpoints']) for r in hbases),
              'hcal_above_comparisons': len(ha)*3, 'hcal_above_checkpoints': len(ha),
              'hcal_above_trajectories': len({v['id'] for v in ha}),
              'calibration_x1_x1e6_above_comparisons': len(cx)}
    check_counts(counts)
    return cal, hcal, bases, hbases, {'ruling_counts': [dict(name=k,item=v[0],derived=counts[k],ruling=v[1]) for k,v in EXPECTED.items()],
        'counts': counts, 'excluded_calibration': excluded, 'excluded_hcal': hexcluded,
        'calibration_above': ca, 'hcal_above': ha, 'calibration_x1_x1e6_above': cx,
        'hcal_above_trajectories': sorted({v['id'] for v in ha}),
        'retained_calibration': [r['id'] for r in bases], 'retained_hcal': [r['id'] for r in hbases]}


def stage(dest):
    dest = Path(dest)
    cal, hcal, bases, hbases, receipt = sources()
    for name, original, rows in (('cal', cal, bases), ('hcal', hcal, hbases)):
        for scale_name, scale in SCALES.items():
            c = copy.deepcopy(original)
            c['rows'] = [scale_row(r, scale) for r in rows]
            write_json(dest / name / scale_name / 'corpus.json', c)
    # Item12's fallback is all 72+32 released rows exactly as they stand.
    for name, original in (('calibration', HERE), ('hcal', HERE / 'hcal')):
        path = dest / 'judge' / name
        path.mkdir(parents=True, exist_ok=True)
        for filename in ('corpus.json', 'certificate.json', 'labels.json'):
            (path / filename).write_bytes((original / filename).read_bytes())
    write_json(dest / 'source-inventory.json', receipt)
    return receipt


def set_dirs(dest):
    """The fixed calibration study; confirmation has its own ruled builder."""
    return [Path(dest) / 'cal' / scale for scale in ('x1', 'x1e-3', 'x1e3')]


def certify_one(corpus_path, python, log_path):
    command = [str(python), '-B', str(HERE / 'certify.py'), '--corpus', str(corpus_path)]
    with Path(log_path).open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise HarnessError(f'CERTIFIER REFUSED/ERROR: rc={result.returncode}; corpus={corpus_path}; log={log_path}; no exclusion permitted')
    return {'command': command, 'rc': result.returncode, 'log': str(log_path), 'log_sha256': sha(log_path)}


def run_oracles(dest, logs, python):
    logs = Path(logs)
    logs.mkdir(parents=True, exist_ok=True)
    receipts = []
    for path in set_dirs(dest):
        stem = '-'.join(path.parts[-2:])
        receipts.append(certify_one(path / 'corpus.json', python, logs / f'{stem}-certify.log'))
        command = [str(python), '-B', str(HERE / 'derive.py'), '--corpus', str(path / 'corpus.json'), '--write']
        logfile = logs / f'{stem}-derive.log'
        with logfile.open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        receipts.append({'command': command, 'rc': result.returncode, 'log': str(logfile), 'log_sha256': sha(logfile)})
        if result.returncode:
            raise HarnessError(f'DERIVER REFUSED/ERROR: rc={result.returncode}; corpus={path}; log={logfile}; no exclusion permitted')
        print(f'LABELS {stem}: certified and derived', flush=True)
    write_json(Path(dest) / 'oracle-commands.json', receipts)
    return receipts


def load_set(path):
    path = Path(path)
    corpus = derive.load_corpus(str(path / 'corpus.json'))
    cert = derive.load_certificates(corpus, str(path / 'certificate.json'))
    labels = derive.derive(corpus, cert)
    if labels != json.loads((path / 'labels.json').read_text()):
        raise HarnessError(f'{path}: stored labels differ from unchanged derive')
    return corpus, labels


def inventory(dest):
    dest = Path(dest)
    _, _, bases, _, receipt = sources()
    cal_labels = {name: load_set(dest / 'cal' / name)[1] for name in ('x1', 'x1e-3', 'x1e3')}
    cal_labels['x1e6'] = load_set(dest / 'confirm-cal' / 'x1e6')[1]
    candidates = [r for r in bases if r['props']['limit'] == 0]
    zero = [{'id': r['id'], 'checkpoint': max(r['checkpoints']),
             'labels': {name: cal_labels[name].get(f"{r['id']}@{max(r['checkpoints'])}", {}).get('converged', [None, None])[1]
                        for name in SCALES}}
            for r in candidates]
    roster = [r for r in zero if all(r['labels'][name] for name in ('x1', 'x1e-3', 'x1e3'))]
    if {r['id'] for r in roster} != Z_EXPECTED:
        raise HarnessError(f'STOP R33-1 item9: derived Z roster {[r["id"] for r in roster]}, ruling {sorted(Z_EXPECTED)}')
    if any(type(r['labels']['x1e6']) is not bool for r in roster):
        raise HarnessError('STOP R33-1 item12: a fixed Z row lacks a certified x1e6 label')
    _, labels = load_set(dest / 'judge' / 'hcal')
    support = {p: {'positive': sum(v[p][1] for v in labels.values() if v[p][0] != 'REPORTED'),
                   'negative': sum(not v[p][1] for v in labels.values() if v[p][0] != 'REPORTED')} for p in PREDS}
    for v in support.values():
        v['both_labels'] = bool(v['positive'] and v['negative'])
    for path in set_dirs(dest):
        load_set(path)
    confirmation = json.loads((dest / 'confirmation-counts.json').read_text())
    validate_exclusions(dest, confirmation['attempts'])
    staged_counts(dest)
    for corpus_path in confirmation['sets'].values():
        load_set((ROOT / corpus_path).parent)
    load_set(dest / 'judge' / 'calibration')
    load_set(dest / 'judge' / 'hcal')
    receipt.update(Z_roster=roster, zero_candidates=zero, Hcal_label_support=support,
                   confirmation=confirmation,
                   scales=SCALES, python=sys.version,
                   files={str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p):sha(p)
                          for p in sorted(dest.rglob('*')) if p.is_file() and p.name != 'inventory.json'})
    write_json(dest / 'inventory.json', receipt)
    return receipt


def parse_attempt(corpus_path, command, rc, log_path):
    """A certifier refusal is distinct from a crash, malformed report or missing row."""
    corpus_path, log_path = (Path(p) if Path(p).is_absolute() else ROOT/Path(p)
                             for p in (corpus_path, log_path))
    text = Path(log_path).read_text()
    corpus = derive.load_corpus(str(corpus_path))
    ids = {r['id'] for r in corpus['rows']}
    refused = []
    for line in text.splitlines():
        if line.startswith('REFUSED '):
            rid, separator, message = line[8:].partition(': ')
            if not separator or rid not in ids or rid in {r['id'] for r in refused}:
                raise HarnessError(f'INCOMPLETE: malformed refusal in {log_path}: {line}')
            refused.append({'id': rid, 'message': message, 'line': line})
    summaries = re.findall(r'^certified: .*; refused=(\d+) of (\d+) rows$', text, re.M)
    if len(summaries) != 1 or tuple(map(int, summaries[0])) != (len(refused), len(ids)):
        raise HarnessError(f'INCOMPLETE: certifier accounting differs from corpus in {log_path}')
    if rc != (1 if refused else 0):
        raise HarnessError(f'INCOMPLETE: certifier internal error or inconsistent rc={rc}: {log_path}')
    reference = lambda p: str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p)
    return {'command': command, 'rc': rc, 'log': reference(log_path), 'log_sha256': sha(log_path),
            'corpus': reference(corpus_path), 'corpus_sha256': sha(corpus_path), 'rows': len(ids),
            'refused': refused, 'certifier_sha256': sha(HERE / 'certify.py')}


def attempt(corpus_path, python, log_path):
    command = [str(python), '-B', str(HERE / 'certify.py'), '--corpus', str(corpus_path)]
    Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    with Path(log_path).open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    return parse_attempt(corpus_path, command, result.returncode, log_path)


def derive_one(path, python, log_path):
    command = [str(python), '-B', str(HERE / 'derive.py'), '--corpus', str(Path(path) / 'corpus.json'), '--write']
    with Path(log_path).open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise HarnessError(f'INCOMPLETE: derive rc={result.returncode}: {log_path}')
    return {'command': command, 'rc': result.returncode, 'log': str(log_path), 'log_sha256': sha(log_path)}


def exclusions_from_attempts(attempts):
    excluded = {}
    for population in ('hcal', 'calibration'):
        rows = {}
        for rec in attempts[population]:
            for refused in rec['refused']:
                rows.setdefault(refused['id'], []).append({'scale': rec['scale'], 'message': refused['message'],
                    'line': refused['line'], 'log': rec['log'], 'log_sha256': rec['log_sha256']})
        excluded[population] = [{'id': rid, 'refusals': rows[rid]} for rid in sorted(rows)]
    return excluded


def validate_exclusions(dest, attempts):
    """The actual comparison sets equal source minus parsed full-copy refusals.

    Membership is checked both ways at every scale. Existing logs are parsed
    again, so deleting a refusal from progress metadata cannot restore a row.
    This validator neither imports sympy nor starts an oracle/binary process.
    """
    dest=Path(dest)
    checked=copy.deepcopy(attempts)
    for population,records in checked.items():
        for rec in records:
            if rec.get('validated_cached_certificate'):
                continue
            parsed=parse_attempt(rec['corpus'],rec['command'],rec['rc'],rec['log'])
            if parsed['refused'] != rec['refused'] or parsed['log_sha256'] != rec['log_sha256'] or parsed['corpus_sha256'] != rec['corpus_sha256']:
                raise HarnessError(f'INCOMPLETE: changed refusal evidence {population}/{rec["scale"]}')
    excluded=exclusions_from_attempts(checked)
    originals={'calibration':derive.load_corpus(str(dest/'cal'/'x1'/'corpus.json')),
               'hcal':derive.load_corpus(str(dest/'judge'/'hcal'/'corpus.json'))}
    for population,name,scales in (('calibration','confirm-cal',('x1','x1e6')),
                                   ('hcal','confirm-hcal',tuple(SCALES))):
        want={r['id'] for r in originals[population]['rows']}-{r['id'] for r in excluded[population]}
        for scale in scales:
            corpus=derive.load_corpus(str(dest/name/scale/'corpus.json'))
            actual={r['id'] for r in corpus['rows']}
            if actual != want:
                raise HarnessError(f'INCOMPLETE: confirmation exclusion roster {name}/{scale}: '
                                   f'extra={sorted(actual-want)} missing={sorted(want-actual)}')
    return excluded


def confirmation(dest, logs, attempts_dir, counts_path, python, prior_cal_log=None):
    """Addendum 1: all full confirmation attempts precede mechanical exclusions.

    Existing three-scale calibration corpora, certificates and labels are read
    and validated, never rewritten. Attempt snapshots remain evidence, not
    scored sets; every retained comparison set is certified and derived afresh.
    """
    dest, logs, attempts_dir = Path(dest).resolve(), Path(logs).resolve(), Path(attempts_dir).resolve()
    logs.mkdir(parents=True, exist_ok=True)
    cal, hcal, bases, hbases, _ = sources()
    attempts, commands = {'calibration': [], 'hcal': []}, []
    calibration_before = {str(p): sha(p) for scale in ('x1', 'x1e-3', 'x1e3')
                          for p in (dest / 'cal' / scale).iterdir() if p.is_file()}
    for scale in ('x1', 'x1e-3', 'x1e3'):
        load_set(dest / 'cal' / scale)
    # H-cal at all four scales is the first new certifier work.
    for scale in SCALES:
        original = dest / 'hcal' / scale / 'corpus.json'
        snapshot = attempts_dir / 'hcal' / scale / 'corpus.json'
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        snapshot.write_bytes(original.read_bytes())
        rec = attempt(snapshot, python, logs / f'hcal-{scale}-full-certify.log')
        rec['scale'] = scale
        attempts['hcal'].append(rec)
        write_json(logs / 'attempts-progress.json', attempts)
        print(f'ATTEMPT hcal/{scale}: rc={rec["rc"]} refused={len(rec["refused"])}', flush=True)
    # Reuse the real full calibration x1e6 attempt when supplied; no data are
    # changed to force acceptance. Fresh replication can omit this option.
    snapshot = attempts_dir / 'calibration' / 'x1e6' / 'corpus.json'
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    snapshot.write_bytes((dest / 'cal' / 'x1e6' / 'corpus.json').read_bytes())
    if prior_cal_log:
        preserved = logs / 'calibration-x1e6-full-certify.log'
        preserved.write_bytes(Path(prior_cal_log).read_bytes())
        rec = parse_attempt(snapshot,
                            [str(python), '-B', str(HERE / 'certify.py'), '--corpus',
                             str(dest / 'cal' / 'x1e6' / 'corpus.json')], 1, preserved)
        rec['reused_original_attempt'] = True
    else:
        rec = attempt(snapshot, python, logs / 'calibration-x1e6-full-certify.log')
    rec['scale'] = 'x1e6'
    attempts['calibration'].append(rec)
    # The other calibration scales already carry complete frozen certificates.
    for scale in ('x1', 'x1e-3', 'x1e3'):
        corpus, _labels = load_set(dest / 'cal' / scale)
        attempts['calibration'].append({'scale': scale, 'rc': 0, 'refused': [],
            'rows': len(corpus['rows']), 'validated_cached_certificate': True,
            'corpus_sha256': sha(dest / 'cal' / scale / 'corpus.json'),
            'certificate_sha256': sha(dest / 'cal' / scale / 'certificate.json')})
    write_json(logs / 'attempts-progress.json', attempts)
    excluded = exclusions_from_attempts(attempts)
    retained = {'hcal': [r for r in hbases if r['id'] not in {e['id'] for e in excluded['hcal']}],
                'calibration': [r for r in bases if r['id'] not in {e['id'] for e in excluded['calibration']}]}
    components = {}
    for key, rows, minimum_scale, multipliers in (('i', retained['hcal'], 1e-3, 3),
                                                  ('ii', retained['calibration'], 1.0, 1)):
        mask = above_floor(rows, minimum_scale)
        require_nonempty(mask, f'confirmation component ({key}) above-floor comparison')
        checkpoints = sum(len(r['checkpoints']) for r in rows)
        components[key] = {'rows': len(rows), 'checkpoints': checkpoints,
                           'all_comparisons': checkpoints * multipliers, 'above_comparisons': len(mask) * multipliers,
                           'above_checkpoints': mask, 'above_trajectories': sorted({r['id'] for r in mask})}
    # Materialize matched retained rows only; calibration selection stays61.
    new_sets = {}
    for name, source, rows, scales in (('confirm-cal', cal, retained['calibration'], ('x1', 'x1e6')),
                                     ('confirm-hcal', hcal, retained['hcal'], tuple(SCALES))):
        for scale in scales:
            path = dest / name / scale
            corpus = copy.deepcopy(source)
            corpus['rows'] = [scale_row(r, SCALES[scale]) for r in rows]
            write_json(path / 'corpus.json', corpus)
            new_sets[f'{name}/{scale}'] = path
    # Counts are useful progress evidence but not final until fresh reduced
    # certificates and labels have all been validated below.
    write_json(logs / 'comparison-progress.json', {'status': 'PENDING_REDUCED_CERTIFICATES',
                                                  'exclusions': excluded, 'comparison_sets': components})
    print(json.dumps({'exclusions': excluded, 'comparison_sets': components}, sort_keys=True), flush=True)
    for name, path in new_sets.items():
        stem = name.replace('/', '-')
        rec = attempt(path / 'corpus.json', python, logs / f'{stem}-certify.log')
        commands.append(rec)
        if rec['refused']:
            raise HarnessError(f'INCOMPLETE: retained rows refused during subset recertification: {rec["refused"]}')
        commands.append(derive_one(path, python, logs / f'{stem}-derive.log'))
        load_set(path)
        print(f'CONFIRMATION LABELS {name}: {rec["rows"]} rows certified/derived', flush=True)
    return finish_confirmation(dest, logs, counts_path, attempts, components, excluded,
                               retained, commands, calibration_before)


def finish_confirmation(dest, logs, counts_path, attempts, components, excluded,
                        retained, commands, calibration_before):
    """Verify labels and emit a receipt only after every reduced set exists."""
    dest, logs = Path(dest).resolve(), Path(logs).resolve()
    validate_exclusions(dest, attempts)
    _cal, _hcal, bases, _hbases, _source = sources()
    new_sets = {f'{name}/{scale}': dest / name / scale
                for name, scales in (('confirm-cal', ('x1', 'x1e6')), ('confirm-hcal', tuple(SCALES)))
                for scale in scales}
    for path in new_sets.values():
        load_set(path)
    cal_labels = {s: load_set(dest / 'cal' / s)[1] for s in ('x1', 'x1e-3', 'x1e3')}
    last_labels = load_set(dest / 'confirm-cal' / 'x1e6')[1]
    roster = []
    for row in bases:
        if row['props']['limit'] != 0:
            continue
        key = f'{row["id"]}@{max(row["checkpoints"])}'
        if all(cal_labels[s][key]['converged'][1] for s in cal_labels):
            label = last_labels.get(key, {}).get('converged', [None, None])[1]
            roster.append({'id': row['id'], 'checkpoint': max(row['checkpoints']), 'label_x1e6': label})
    if {r['id'] for r in roster} != Z_EXPECTED or any(type(r['label_x1e6']) is not bool for r in roster):
        raise HarnessError(f'STOP: fixed Z roster absent or missing certified x1e6 labels: {roster}')
    _hc, hl = load_set(dest / 'judge' / 'hcal')
    support = {p: {'positive': sum(v[p][1] for v in hl.values() if v[p][0] != 'REPORTED'),
                   'negative': sum(not v[p][1] for v in hl.values() if v[p][0] != 'REPORTED')} for p in PREDS}
    for value in support.values():
        value['both_labels'] = bool(value['positive'] and value['negative'])
    changed = [name for name, stamp in calibration_before.items() if sha(name) != stamp]
    if changed:
        raise HarnessError(f'STOP: calibration changed during confirmation: {changed}')
    receipt = {'format': 'r33-confirmation-counts/1', 'status': 'CERTIFIED_BEFORE_BINARY',
               'comparison_sets': components, 'exclusions': excluded, 'attempts': attempts,
               'oracle_commands': commands, 'Z_roster': roster, 'Hcal_label_support': support,
               'BA_guard': {'primary': 'judge/hcal (all original32)',
                            'fallback': 'judge/calibration + judge/hcal (all original72+32)'},
               'retained': {name: [r['id'] for r in rows] for name, rows in retained.items()},
               'sets': {name: str(path.relative_to(ROOT) / 'corpus.json') for name, path in new_sets.items()},
               'calibration_unchanged': calibration_before, 'python': sys.version,
               'files': {str(p.relative_to(ROOT)): sha(p) for path in new_sets.values() for p in sorted(path.iterdir()) if p.is_file()}}
    write_json(dest / 'confirmation-counts.json', receipt)
    Path(counts_path).write_bytes((dest / 'confirmation-counts.json').read_bytes())
    return receipt


def finalize_existing(dest, logs, counts_path, python):
    """Recover finalization after completed programs without re-running them.

    Every retained corpus, frozen certificate, derived label and program log
    is validated. The count masks are derived afresh, never accepted solely
    because a progress file says what they were.
    """
    dest, logs = Path(dest).resolve(), Path(logs).resolve()
    _cal, _hcal, bases, hbases, _source = sources()
    attempts = json.loads((logs / 'attempts-progress.json').read_text())
    progress = json.loads((logs / 'comparison-progress.json').read_text())
    for population, records in attempts.items():
        for rec in records:
            if rec.get('validated_cached_certificate'):
                path = dest / 'cal' / rec['scale']
                load_set(path)
                if sha(path / 'corpus.json') != rec['corpus_sha256'] or sha(path / 'certificate.json') != rec['certificate_sha256']:
                    raise HarnessError('INCOMPLETE: cached calibration certificate or corpus changed')
                continue
            checked = parse_attempt(rec['corpus'], rec['command'], rec['rc'], rec['log'])
            for key in ('refused', 'log_sha256', 'corpus_sha256', 'certifier_sha256'):
                if checked[key] != rec[key]:
                    raise HarnessError(f'INCOMPLETE: attempt evidence changed: {population}/{rec["scale"]}/{key}')
    excluded = exclusions_from_attempts(attempts)
    if excluded != progress['exclusions']:
        raise HarnessError('INCOMPLETE: exclusions differ from actual full-population certifier reports')
    retained = {'hcal': [r for r in hbases if r['id'] not in {e['id'] for e in excluded['hcal']}],
                'calibration': [r for r in bases if r['id'] not in {e['id'] for e in excluded['calibration']}]}
    components = {}
    for key, rows, minimum_scale, multipliers in (('i', retained['hcal'], 1e-3, 3),
                                                  ('ii', retained['calibration'], 1.0, 1)):
        mask = above_floor(rows, minimum_scale)
        require_nonempty(mask, f'confirmation component ({key}) above-floor comparison')
        checkpoints = sum(len(r['checkpoints']) for r in rows)
        components[key] = {'rows': len(rows), 'checkpoints': checkpoints,
                           'all_comparisons': checkpoints * multipliers, 'above_comparisons': len(mask) * multipliers,
                           'above_checkpoints': mask, 'above_trajectories': sorted({r['id'] for r in mask})}
    if components != progress['comparison_sets']:
        raise HarnessError('INCOMPLETE: confirmation count masks differ from pre-certification progress')
    commands = []
    for name, scales in (('confirm-cal', ('x1', 'x1e6')), ('confirm-hcal', tuple(SCALES))):
        for scale in scales:
            path = dest / name / scale
            stem = f'{name}-{scale}'
            rec = parse_attempt(path / 'corpus.json',
                                [str(python), '-B', str(HERE / 'certify.py'), '--corpus', str(path / 'corpus.json')],
                                0, logs / f'{stem}-certify.log')
            commands.append(rec)
            logfile = logs / f'{stem}-derive.log'
            if not logfile.exists():
                raise HarnessError(f'INCOMPLETE: missing derive log {logfile}')
            load_set(path)
            commands.append({'command': [str(python), '-B', str(HERE / 'derive.py'), '--corpus',
                                         str(path / 'corpus.json'), '--write'],
                             'rc': 0, 'log': str(logfile), 'log_sha256': sha(logfile),
                             'receipt_reconstructed_after_programs': True})
    before = {str(p): sha(p) for scale in ('x1', 'x1e-3', 'x1e3')
              for p in (dest / 'cal' / scale).iterdir() if p.is_file()}
    return finish_confirmation(dest, logs, counts_path, attempts, components, excluded,
                               retained, commands, before)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('stage', 'certify', 'audit', 'confirmation', 'finalize'))
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--logs', type=Path)
    p.add_argument('--python', default=sys.executable,
                   help='Sympy-capable interpreter for frozen certification during manifest construction; CI reading plants use only stdlib')
    p.add_argument('--attempts', type=Path)
    p.add_argument('--counts', type=Path)
    p.add_argument('--prior-cal-log', type=Path)
    args = p.parse_args()
    if sys.version_info[:3] != (3, 12, 3):
        raise HarnessError(f'R33-1 fixtures require Python3.12.3, got {sys.version.split()[0]}')
    if args.action == 'stage':
        result = stage(args.out)
    elif args.action == 'certify':
        if not args.logs:
            p.error('certify requires --logs')
        result = run_oracles(args.out, args.logs, args.python)
    elif args.action == 'confirmation':
        if not (args.logs and args.attempts and args.counts):
            p.error('confirmation requires --logs, --attempts and --counts')
        result = confirmation(args.out, args.logs, args.attempts, args.counts, args.python, args.prior_cal_log)
    elif args.action == 'finalize':
        if not (args.logs and args.counts):
            p.error('finalize requires --logs and --counts')
        result = finalize_existing(args.out, args.logs, args.counts, args.python)
    else:
        result = inventory(args.out)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except HarnessError as e:
        print(f'R33_POPULATION_ERROR: {e}', file=sys.stderr)
        sys.exit(2)
