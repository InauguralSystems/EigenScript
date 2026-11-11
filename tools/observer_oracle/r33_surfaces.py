#!/usr/bin/env python3
"""F0 query-surface acceptance inputs, separate from the immutable 512.

write/verify produce and check complete input/program bytes without running
a classifier. model evaluates F0 only; run executes the fixed binary only
when called by the committed-manifest identity harness. No experimental
policy, metric, family generator or network appears in this module.
"""
import argparse
import copy
import json
from pathlib import Path

from gen import HarnessError
from r33_fixtures import literal
from r33_port import PREDS, Slot

SCALARS = ('kind', 'entropy', 'dH', 'last_entropy', 'last_value', 'best',
           'since', 'observed', 'numeric', 'window')
ARRAYS = ('values', 'rel', 'raw', 'exact', 'dh')
LIVE = (*PREDS, 'report', 'report_value', 'where', 'why', 'how', 'count')


def record(value):
    return {'op': 'record', 'value': value}


def trajectory(values, window, raw=None, relative=None, best=None, since=None):
    """A transparent, legal numeric trajectory supplied by hand."""
    values = list(values)
    computed = [float(b)-float(a) for a, b in zip(values, values[1:])]
    if raw is None:
        raw = computed
    if relative is None:
        relative = [d/max(abs(float(a)), abs(float(b)), 0.001)
                    for d, a, b in zip(raw, values, values[1:])]
    return {'kind': 'trajectory', 'rel': list(relative), 'raw': list(raw),
            'exact': [False]*len(raw), 'values': values, 'dh': [],
            'entropy': None, 'dH': None, 'last_entropy': None,
            'last_value': values[-1], 'best': best, 'since': since,
            'observed': True, 'numeric': True, 'window': window}


def cases():
    slow = [record(1000.0-0.5*i) for i in range(24)]
    slow.insert(7, {'op': 'detour', 'value': 'ab'})
    exact = [record(2**53+i) for i in range(18)]
    exact.insert(5, {'op': 'detour', 'value': 'abcd'})
    rows = [
        {'id': 'string-first-temporal',
         'ops': [{'op':'detour','value':'ab'},record(1.0),
                 {'op':'detour','value':'abcd'},record(0.9),record(0.5)],
         'read_at':[1,3,4], 'export_at':[0,1,2,3,4], 'temporal':[1,3,4],
         'import_windows':[4,64]},
        {'id': 'string-detour-temporal', 'ops': slow,
         'read_at': [i for i, op in enumerate(slow) if op['op'] == 'record'],
         'export_at': [0, 6, 7, 8, 24], 'temporal': [0, 6, 8, 24],
         'import_windows': [4, 64]},
        {'id': 'exact-detour-temporal', 'ops': exact,
         'read_at': [i for i, op in enumerate(exact) if op['op'] == 'record'],
         'export_at': [0, 4, 5, 6, 18], 'temporal': [0, 4, 6, 18],
         'import_windows': [4, 64]},
        {'id': 'since-age-20', 'ops': [record(1.0), record(0.0)]+[record(0.0) for _ in range(20)],
         'read_at': [21], 'export_at': [21], 'temporal': [0, 1, 21],
         'import_windows': [4, 64]},
        {'id': 'since-age-260', 'ops': [record(1.0), record(0.0)]+[record(0.0) for _ in range(260)],
         'read_at': [261], 'export_at': [261], 'temporal': [254, 255, 256, 261],
         'import_windows': [4, 64]},
        {'id': 'custom-import-boundaries', 'ops': [], 'read_at': [], 'export_at': [], 'temporal': [],
         'trajectories': [
             {'name': 'raw-nonvanishing-ratio-equality',
              'data': trajectory([0.0]*5, 4, raw=[1.0,1.0,1.0-1e-9,1.0-1e-9],
                                 relative=[0.0]*4)},
             {'name': 'exact-import-raw-product-underflow',
              'data': {**trajectory([0]*11,10,raw=[1e-200,-1e-200]*5,
                                    relative=[0.0]*10), 'exact':[True]*10}},
             {'name': 'window4-three-step-oscillation',
              'data': trajectory([1.0, -1.0, 1.0, -1.0], 4)},
             {'name': 'window64-partial-drift',
              'data': trajectory([1000.0, 998.0, 996.0, 994.0], 64, best=994.0, since=0)},
             {'name': 'reference-positive-tau-equality',
              'data': trajectory([990.0+i for i in range(11)], 10,
                                 raw=[0.0]*10, relative=[0.0]*10, best=1000.0, since=0)},
             {'name': 'reference-negative-tau-equality',
              'data': trajectory([-990.0-i for i in range(11)], 10,
                                 raw=[0.0]*10, relative=[0.0]*10, best=-1000.0, since=0)},
             {'name': 'zero-window-flag-equality',
              'data': trajectory([1.0+i/1000.0 for i in range(11)], 10,
                                 raw=[1.0]*3+[-1.0]*4+[1.0]*3,
                                 relative=[0.001]*10)},
             {'name': 'equilibrium-mean-equality',
              'data': trajectory([1.0, 1.01, 1.005, 1.0, 1.01], 4,
                                 raw=[0.0, 0.0, 0.0, 1.0], relative=[0.001]*4)},
             {'name': 'equilibrium-variance-equality',
              'data': trajectory([1.0, 1.01, 1.005, 1.0, 1.01], 4,
                                 raw=[0.0, 0.0, 0.0, 1.0], relative=[-0.001, 0.001, -0.001, 0.001])}
         ]}
    ]
    return rows


def numeric_kind(value):
    return 'int' if type(value) is int else 'float' if type(value) is float else None


def put(result, op, field, value):
    for key, item in (((op, field), value), ((op, field+'.kind'), numeric_kind(value))):
        if key in result:
            raise HarnessError(f'SURFACE duplicate declared key {key!r}')
        result[key] = item


def put_trajectory(result, op, prefix, data):
    put(result, op, prefix+'.fields', len(data))
    for field in SCALARS:
        put(result, op, prefix+'.'+field, data[field])
    for field in ARRAYS:
        put(result, op, prefix+'.'+field+'.length', len(data[field]))
        for i, value in enumerate(data[field]):
            put(result, op, prefix+'.'+field+'.'+str(i), value)


def model(row, slot_type=Slot, cls=None):
    """Flat F0 expected readings; a mutant Slot may be injected by plants."""
    if cls is not None:
        slot_type = cls
    result, snapshots = {}, {}
    slot = slot_type(policy='F0')
    for i, operation in enumerate(row['ops']):
        if operation['op'] == 'record':
            slot.record(operation['value'])
            snapshots[i] = slot.snapshot()
        elif operation['op'] == 'detour':
            slot.detour(operation['value'])
        else:
            raise HarnessError(f'unknown surface operation {operation!r}')
        if i in row['read_at']:
            answer = slot.reading()
            for field in LIVE:
                value = slot.report_value() if field == 'report_value' else answer[field]
                put(result, i, 'live.'+field, value)
        if i in row['export_at']:
            exported = slot.trajectory()
            put_trajectory(result, i, 'trajectory', exported)
            put(result, i, 'trajectory.classify', slot_type.from_trajectory(exported).report_value())
            for depth in row.get('import_windows', []):
                changed = copy.deepcopy(exported)
                changed['window'] = depth
                put(result, i, f'classify.window{depth}', slot_type.from_trajectory(changed).report_value())
    for i in row['temporal']:
        answer = snapshots[i]
        for channel in ('at', 'when'):
            for field in ('where', 'why', 'how', 'count'):
                put(result, i, f'temporal.{channel}.{field}', answer[field])
    for i, custom in enumerate(row.get('trajectories', [])):
        prefix = 'custom.'+custom['name']
        put_trajectory(result, i, prefix, custom['data'])
        imported = slot_type.from_trajectory(copy.deepcopy(custom['data']))
        put(result, i, prefix+'.classify', imported.report_value())
    return result


def source_literal(value):
    if value is None:
        return 'null'
    if type(value) is bool:
        return 'true' if value else 'false'
    if type(value) is str:
        return json.dumps(value, ensure_ascii=False)
    if type(value) in (int, float):
        return literal(value)
    if type(value) is list:
        return '['+', '.join(source_literal(v) for v in value)+']'
    if type(value) is dict:
        return '{'+', '.join(source_literal(k)+': '+source_literal(v) for k, v in value.items())+'}'
    raise HarnessError(f'unsupported surface source literal {value!r}')


def scalar(out, row, op, field, expression, dynamic=False):
    """Two statements, with an explicit num_type witness for every scalar."""
    out.append('r33_value is ('+expression+')')
    field_expr = field if dynamic else source_literal(field)
    out.append('print of ("SURF " + (json_encode of {"surface": '+source_literal(row['id'])+
               ', "op": '+str(op)+', "field": '+field_expr+
               ', "kind": num_type of r33_value, "value": r33_value}))')


def emit_trajectory(out, row, op, prefix):
    scalar(out, row, op, prefix+'.fields', 'len of r33_traj')
    for field in SCALARS:
        scalar(out, row, op, prefix+'.'+field, 'r33_traj['+source_literal(field)+']')
    for field in ARRAYS:
        expression = 'r33_traj['+source_literal(field)+']'
        scalar(out, row, op, prefix+'.'+field+'.length', 'len of ('+expression+')')
        out.append('for r33_index in range of (len of ('+expression+')):')
        body = []
        scalar(body, row, op, 'f"'+prefix+'.'+field+'.{r33_index}"', expression+'[r33_index]', dynamic=True)
        out.extend('    '+line for line in body)


def emit(row):
    """Fully spelled assignments: temporal `at` uses their physical lines."""
    out, positions, ordinal = [], {}, 0
    for i, operation in enumerate(row['ops']):
        if operation['op'] not in ('record', 'detour'):
            raise HarnessError(f'unknown surface operation {operation!r}')
        line = len(out)+1
        out.append('x is '+source_literal(operation['value']))
        ordinal += 1
        positions[i] = line, ordinal
        if i in row['read_at']:
            for field in LIVE:
                expression = (field+' of x' if field in PREDS or field in ('report', 'report_value') else
                              'when is x' if field == 'count' else field+' is x')
                scalar(out, row, i, 'live.'+field, expression)
        if i in row['export_at']:
            out.append('r33_traj is trajectory of x')
            emit_trajectory(out, row, i, 'trajectory')
            scalar(out, row, i, 'trajectory.classify', 'classify of r33_traj')
            for depth in row.get('import_windows', []):
                out.append('r33_traj is trajectory of x')
                out.append('r33_traj["window"] is '+str(depth))
                scalar(out, row, i, f'classify.window{depth}', 'classify of r33_traj')
    for i in row['temporal']:
        line, when = positions[i]
        for channel, position in (('at', line), ('when', when)):
            for field in ('where', 'why', 'how', 'count'):
                word = 'when' if field == 'count' else field
                scalar(out, row, i, f'temporal.{channel}.{field}', f'{word} is x {channel} {position}')
    for i, custom in enumerate(row.get('trajectories', [])):
        prefix = 'custom.'+custom['name']
        out.append('r33_traj is '+source_literal(custom['data']))
        emit_trajectory(out, row, i, prefix)
        scalar(out, row, i, prefix+'.classify', 'classify of r33_traj')
    out.append('print of '+source_literal('SURF_DONE '+row['id']))
    return '\n'.join(out)+'\n'


def parse(row, lines):
    if isinstance(lines, str):
        lines = lines.splitlines()
    if not lines or lines[-1] != 'SURF_DONE '+row['id']:
        raise HarnessError(f'SURFACE MISSING {row["id"]}: final marker')
    result = {}
    for line in lines[:-1]:
        if not line.startswith('SURF '):
            raise HarnessError(f'SURFACE MALFORMED {row["id"]}: {line!r}')
        try:
            cell = json.loads(line[5:])
        except ValueError as error:
            raise HarnessError(f'SURFACE MALFORMED {row["id"]}: invalid JSON') from error
        if (type(cell) is not dict or set(cell) != {'surface', 'op', 'field', 'kind', 'value'}
                or cell['surface'] != row['id'] or type(cell['op']) is not int
                or type(cell['field']) is not str or not cell['field']):
            raise HarnessError(f'SURFACE MALFORMED {row["id"]}: unexpected cell schema')
        value, kind = cell['value'], cell['kind']
        if kind == 'int':
            if type(value) is not int:
                raise HarnessError('SURFACE MALFORMED: integer witness has noninteger JSON value')
        elif kind == 'float':
            if type(value) not in (int, float):
                raise HarnessError('SURFACE MALFORMED: float witness has nonnumeric JSON value')
            value = float(value)
        elif kind is not None or type(value) not in (type(None), str, bool):
            raise HarnessError('SURFACE MALFORMED: nonnumeric witness disagrees with JSON value')
        put(result, cell['op'], cell['field'], value)
        if result[(cell['op'], cell['field']+'.kind')] != kind:
            raise HarnessError('SURFACE MALFORMED: scalar kind witness differs')
    if not result:
        raise HarnessError('SURFACE INCOMPLETE: empty comparison')
    return result


def input_text(rows):
    return json.dumps({'format': 'r33-surfaces/1', 'rows': rows}, indent=2, sort_keys=True, allow_nan=False)+'\n'


def write(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    programs = destination/'programs'
    programs.mkdir(exist_ok=True)
    rows = cases()
    (destination/'inputs.json').write_text(input_text(rows))
    for row in rows:
        (programs/(row['id']+'.eigs')).write_text(emit(row))
    return {'cases': len(rows), 'programs': len(rows), 'classifier_or_binary_run': False}


def verify(destination):
    destination = Path(destination)
    rows = cases()
    if (destination/'inputs.json').read_text() != input_text(rows):
        raise HarnessError('SURFACE MANIFEST: fixed inputs changed')
    expected = {row['id']+'.eigs' for row in rows}
    if {p.name for p in (destination/'programs').iterdir()} != expected:
        raise HarnessError('SURFACE MANIFEST: missing or extra programs')
    for row in rows:
        if (destination/'programs'/(row['id']+'.eigs')).read_text() != emit(row):
            raise HarnessError(f'SURFACE MANIFEST: program differs: {row["id"]}')
    return rows


def run(binary, rootdir, outdir):
    """Called only by the identity harness after its manifest commit."""
    import score
    rows = verify(rootdir)
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    result = {'expected': {}, 'actual': {}, 'actual_aa': {}, 'cases': len(rows)}
    for row in rows:
        expected = model(row)
        result['expected'].update({(row['id'], *key): value for key, value in expected.items()})
        program = Path(rootdir)/'programs'/(row['id']+'.eigs')
        for number, target in ((1, 'actual'), (2, 'actual_aa')):
            rc, lines, errors, stderr, _hot = score.run(str(binary), str(program), {'EIGS_JIT_OFF': '1'})
            (outdir/(row['id']+f'.{number}.stdout')).write_text('\n'.join(lines)+'\n')
            (outdir/(row['id']+f'.{number}.stderr')).write_text(stderr)
            if rc or errors:
                raise HarnessError(f'SURFACE RUN {row["id"]}: rc={rc}, errors={errors}')
            actual = parse(row, lines)
            result[target].update({(row['id'], *key): value for key, value in actual.items()})
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('write', 'verify'))
    parser.add_argument('destination')
    arguments = parser.parse_args()
    value = write(arguments.destination) if arguments.action == 'write' else {'cases': len(verify(arguments.destination))}
    print(json.dumps(value, sort_keys=True))
