#!/usr/bin/env python3
"""#2502: measure the runtime, including the incumbent, before changing it.

--record FILE writes observations; --check checks the ruling. Core membership
comes from the running binary's --api --json, never the source's bool policy.
Each probe is a fresh process, bounded, with stdin closed and all output kept.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODES = ('unset', '0', '1')
MARK = '2502:done'
BAD = ('AddressSanitizer', 'LeakSanitizer', 'UndefinedBehaviorSanitizer',
       'ThreadSanitizer', 'runtime error:', 'undefined variable')


def probe(binary, source, mode, scratch, trace=False):
    env = os.environ.copy()
    for key in ('EIGS_STRICT', 'EIGS_TRACE', 'EIGS_REPLAY', 'DISPLAY'):
        env.pop(key, None)
    env.update(SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
    if mode != 'unset':
        env['EIGS_STRICT'] = mode
    path = scratch / 'probe.eigs'
    path.write_text(source + '\nprint of "' + MARK + '"\n')
    if trace:
        env['EIGS_TRACE'] = str(scratch / 'probe.tape')
    def limits():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        # This population contains core builtins only, so it runs no gfx.
        # ASan must retain its shadow address space, including via src/ aliases.
    try:
        r = subprocess.run([str(binary), str(path)], cwd=ROOT, env=env,
                           input='', capture_output=True, text=True, timeout=15,
                           preexec_fn=limits)
        out, err, rc = r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired as exc:
        return dict(rc=124, out=str(exc.stdout), err=str(exc.stderr), broken=True)
    return dict(rc=rc, out=out.replace(str(scratch), '$TMP'),
                err=err.replace(str(scratch), '$TMP'),
                broken=rc != 0 or out.splitlines().count(MARK) != 1 or
                any(s in out + err for s in BAD))


def call(expression):
    return ('try:\n    answer is ' + expression +
            '\n    print of ("answer:" + str of answer)\ncatch e:\n'
            '    if ((type of e) == "dict") and (has_key of [e, "kind"]):\n'
            '        print of ("error:" + e.kind)\n'
            '    else:\n        print of ("thrown:" + str of e)\n')


def cleanup_mktemp(rows):
    # mktemp deliberately ignores container arguments. Remove only exact
    # paths returned by our own completed probes, never a filesystem sweep.
    for row in rows:
        if row['name'] != 'mktemp':
            continue
        for line in row['out'].splitlines():
            if re.fullmatch(r'answer:/tmp/eigen_[A-Za-z0-9]{6}', line):
                path = Path(line.removeprefix('answer:'))
                assert not path.is_symlink() and path.is_file() and path.stat().st_size == 0
                path.unlink()


def legacy_writers(p):
    """Round-one fixtures retained only for the historical census."""
    return {
        'write_text': ('', f'write_text of ["{p}", 7]', ''),
        'write_bytes': ('', f'write_bytes of ["{p}", [1, "wrong"]]', ''),
        'tensor_save': ('', f'tensor_save of [[[1, "wrong"]], "{p}"]', ''),
        'stream_open': ('', f'stream_open of ["{p}", "wrong"]', ''),
        'stream_write': (f'stream_open of ["{p}", 2]\n',
                         'stream_write of "wrong"', 'stream_close of null\n'),
        'rename': ('', f'rename of ["{p}", 7]', ''),
        'append': ('x is [41]\n', 'append of [x, 9, "extra"]', 'print of x\n'),
        'set_at': ('x is [41]\n', 'set_at of [x, "wrong", 9]', 'print of x\n'),
        'list_insert_at': ('x is [41]\n', 'list_insert_at of [x, "wrong", 9]', 'print of x\n'),
        'list_remove_at': ('x is [41]\n', 'list_remove_at of [x, "wrong"]', 'print of x\n'),
        'list_truncate': ('x is [41]\n', 'list_truncate of [x, "wrong"]', 'print of x\n'),
        'copy_into': ('x is buf_from_list of ([41.0, 42.0])\n',
                      'copy_into of [x, 0, [9.0, "wrong"]]', 'print of [x[0], x[1]]\n'),
        'dict_set': ('x is {"a": 41}\n', 'dict_set of [x, 7, 9]', 'print of x\n'),
        'dict_remove': ('x is {"a": 41}\n', 'dict_remove of [x, 7]', 'print of x\n'),
        'text_builder_append': ('x is text_builder_new of null\ntext_builder_append of [x, "keep"]\n',
                                'text_builder_append of [x, "bad", 9]',
                                'print of (text_builder_to_string of x)\n'),
        'text_builder_append_line': ('x is text_builder_new of null\ntext_builder_append of [x, "keep"]\n',
                                     'text_builder_append_line of [x, "bad", 9]',
                                     'print of (text_builder_to_string of x)\n'),
        'buf_set': ('x is buf_from_list of ([41.0])\n', 'buf_set of [x, 0, "wrong"]', 'print of (buf_get of [x, 0])\n'),
        'buf_set_bits': ('x is buf_from_list of ([41.0])\n', 'buf_set_bits of [x, 0, "wrong"]', 'print of (buf_get of [x, 0])\n'),
        'buf_fill': ('x is buf_from_list of ([41.0])\n', 'buf_fill of [x, 0, 1, "wrong"]', 'print of (buf_get of [x, 0])\n'),
        'buf_copy': ('x is buf_from_list of ([41.0])\ny is buf_from_list of ([9.0])\n', 'buf_copy of [y, 0, x, 0, "wrong"]', 'print of (buf_get of [x, 0])\n'),
        'buf_mix': ('x is buf_from_list of ([41.0])\ny is buf_from_list of ([9.0])\n', 'buf_mix of [x, y, 0, 0, 1, "wrong"]', 'print of (buf_get of [x, 0])\n'),
        'buf_scale_range': ('x is buf_from_list of ([41.0])\n', 'buf_scale_range of [x, 0, 1, "wrong"]', 'print of (buf_get of [x, 0])\n'),
        'sgd_update': ('x is [41.0, 42.0]\n', 'sgd_update of [x, [1.0, "wrong"], 0.1]', 'print of x\n'),
        'sgd_update_rows': ('x is [[41.0, 42.0]]\n', 'sgd_update_rows of [x, [[1.0, "wrong"]], [0], 0.1]', 'print of x\n'),
        'sgd_update_cols': ('x is [[41.0], [42.0]]\n', 'sgd_update_cols of [x, [[1.0], ["wrong"]], [0], 0.1]', 'print of x\n'),
        'sort': ('x is [3, "wrong", 1]\n', 'sort of x', 'print of x\n'),
        'store_count': (f's is store_open of "{p}.db"\n', 'store_count of [s, 7]',
                        'store_close of s\n'),
        'store_get': (f's is store_open of "{p}.db"\n', 'store_get of [s, 7, 1]',
                      'store_close of s\n'),
        'store_query': (f's is store_open of "{p}.db"\n', 'store_query of [s, 7]',
                        'store_close of s\n'),
        'store_put': (f's is store_open of "{p}.db"\n', 'store_put of [s, "items", 7]',
                      'print of (store_count of [s, "items"])\nstore_close of s\n'),
        'store_update': (f's is store_open of "{p}.db"\nk is store_put of [s, "items", {"{"}"v": 41{"}"}]\n',
                         'store_update of [s, "items", k, 7]',
                         'print of (store_get of [s, "items", k])\nstore_close of s\n'),
        'store_delete': (f's is store_open of "{p}.db"\nk is store_put of [s, "items", {"{"}"v": 41{"}"}]\n',
                         'store_delete of [s, 7, k]',
                         'print of (store_get of [s, "items", k])\nstore_close of s\n'),
        'store_drop': (f's is store_open of "{p}.db"\nk is store_put of [s, "items", {"{"}"v": 41{"}"}]\n',
                       'store_drop of [s, 7]',
                       'print of (store_get of [s, "items", k])\nstore_close of s\n'),
    }


def effect_inventory():
    """Conservative source-derived effect candidates, with the evidence line.

    Allocation of a fresh result is included: consumers must review whether
    the sink changes caller-owned state. This deliberately over-enumerates.
    """
    import sys
    sys.path.insert(0, str(ROOT / 'tools'))
    import strict_shape_contract as shape
    sources = {str(p.relative_to(ROOT)): p.read_text() for p in (ROOT / 'src').glob('*.c')}
    funcs = shape.functions(sources)
    public = shape.aliases(sources, (ROOT / 'src/ext_names.h').read_text())
    sinks = re.compile(r'\b(?:TRACE_NONDET_\w+|trace_nondet_value|xfopen_write|fwrite|'
                       r'list_(?:append\w*|set_\w+|remove\w*|insert\w*|sort)|'
                       r'dict_(?:set\w*|remove)|text_builder_append\w*|'
                       r'store_write\w*)\s*\(|data\.buffer\.data[^;]*=')
    evidence = {}
    calls = {}
    for name, defs in funcs.items():
        evidence[name] = sorted({line.strip() for d in defs for line in d['body'].splitlines()
                                 if sinks.search(line)})
        calls[name] = set(re.findall(r'\b(\w+)\s*\(', shape.masked('\n'.join(d['body'] for d in defs)))) & funcs.keys()
    reached = {n for n, lines in evidence.items() if lines}
    while True:
        more = {n for n, children in calls.items() if children & reached} - reached
        if not more:
            break
        reached |= more
    return {alias: dict(function=fn, direct=evidence[fn], calls=sorted(calls[fn] & reached))
            for fn in sorted(reached & public.keys()) for alias in sorted(public[fn])}


IEEE = {
    'overflow': '1e308 * 2.0', 'zero-divide': '1.0 / 0.0',
    'invalid-divide': '0.0 / 0.0', 'sqrt-domain': 'sqrt of -1.0',
    'log-domain': 'log of 0.0', 'asin-domain': 'asin of 5.0',
    'acos-domain': 'acos of -2.0', 'exp-overflow': 'exp of 999999.0',
    'pow-domain': 'pow of [-8.0, 0.5]',
    'finite': 'sqrt of 16.0',
}


def measure_legacy_writers(binary, scratch, selected=None):
    rows = []
    p = scratch / 'target'
    for name, (before, expression, after) in legacy_writers(p).items():
        if selected and name != selected:
            continue
        for mode in MODES:
            p.write_bytes(b'KEEP')
            db = scratch / 'target.db'
            db.unlink(missing_ok=True)
            control = probe(binary, before + after, mode, scratch)
            control_file = p.read_bytes().hex() if p.exists() else 'ABSENT'
            control_db = hashlib.sha256(db.read_bytes()).hexdigest() if db.exists() else 'ABSENT'
            p.write_bytes(b'KEEP')
            db.unlink(missing_ok=True)
            r = probe(binary, before + call(expression) + after, mode, scratch)
            r['file_after'] = p.read_bytes().hex() if p.exists() else 'ABSENT'
            r['control_out'] = control['out']
            r['control_file'] = control_file
            r['db_after'] = hashlib.sha256(db.read_bytes()).hexdigest() if db.exists() else 'ABSENT'
            r['control_db'] = control_db
            target_out = '\n'.join(line for line in r['out'].splitlines()
                                   if not line.startswith(('error:', 'answer:')))
            r['unchanged'] = (not control['broken'] and r['file_after'] == control_file
                              and r['db_after'] == control_db
                              and target_out == control['out'].rstrip('\n'))
            rows.append(dict(group='writer', name=name, shape='wrong-type', mode=mode, **r))
    return rows


def wrong_typed_args(args):
    """Yield (arguments, description), changing exactly one typed leaf.

    Literal forms are deliberately used instead of guessing a builtin's
    contract.  The shape corpus already contains a successful invocation, so
    a number/string exchange (including a numeric list element) is a genuine
    type change derived from that invocation.
    """
    choices = []
    for i in range(len(args) - 1, -1, -1):
        value = args[i]
        strings = list(re.finditer(r'"(?:[^"\\]|\\.)*"', value))
        if strings:
            m = strings[-1]
            changed = args[:]
            changed[i] = value[:m.start()] + '2502' + value[m.end():]
            choices.append((changed, f'arg{i + 1}:string->number'))
        numbers = list(re.finditer(r'(?<![A-Za-z_])(?:\d+(?:\.\d+)?)(?![A-Za-z_])', value))
        if numbers:
            m = numbers[-1]
            changed = args[:]
            changed[i] = value[:m.start()] + '"wrong"' + value[m.end():]
            kind = 'list-element' if '[' in value else 'number'
            choices.append((changed, f'arg{i + 1}:{kind}->string'))
    return choices


def tape_call_record(path, call_line):
    """Find a nondeterministic result attributed to the rejected call line."""
    if not path.exists():
        return 'no record'
    active = False
    for line in path.read_text(errors='replace').splitlines():
        fields = line.split()
        if fields[:1] == ['L'] and len(fields) >= 3:
            active = fields[2] == str(call_line)
        elif active and fields[:1] == ['N']:
            return line
    return 'no record'


def setup_snapshots(setup):
    """Serialize every module binding introduced by a shape setup."""
    names = []
    for line in setup.splitlines():
        match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*) is ', line)
        if match and match.group(1) not in names:
            names.append(match.group(1))
    lines = []
    for name in names:
        assignment = next(line for line in setup.splitlines()
                          if line.startswith(name + ' is '))
        if 'buf_' in assignment:
            value = f'[snapshot_item for snapshot_item in {name}]'
        elif 'text_builder_new' in assignment:
            value = f'text_builder_to_string of {name}'
        else:
            # json_encode is the stable envelope; str also makes opaque owned
            # handles snapshot-able without traversing or mutating them.
            value = f'str of {name}'
        lines.append(f'print of ("snapshot:{name}:" + (json_encode of ({value})))')
    return '\n'.join(lines)


def measure_shape_writers(binary, scratch, selected=None):
    """Exercise the complete core/shape intersection, never a writer heuristic."""
    api = subprocess.run([str(binary), '--api', '--json'], capture_output=True,
                         text=True, check=True, timeout=30)
    core = set(json.loads(api.stdout)['builtins'])
    cases = [c for c in json.loads((ROOT / 'tests/strict_shape_cases.json').read_text())
             if c['name'] in core and (selected in (None, 'all', c['name']))]
    assert cases
    rows = []
    for case_no, case in enumerate(cases):
        requirements = [r for r in case.get('requirements', [])
                        if r not in ('owned_temp', 'store_compiled')]
        candidates = wrong_typed_args(case['args'])
        # These writers must mutate the DATA candidate rather than merely
        # changing a path or append flag.
        data_arg = {'tensor_save': 0, 'write_bytes': 1}.get(case['name'])
        if data_arg is not None:
            candidates.sort(key=lambda item: not item[1].startswith(f'arg{data_arg + 1}:'))
        changed = description = None
        if not requirements:
            for candidate_no, (candidate, label) in enumerate(candidates):
                trial = scratch / f'trial-{case_no}-{candidate_no}'
                trial.mkdir()
                setup = case.get('setup', '')
                expression = case['name'] + ' of ([' + ', '.join(candidate) + '])'
                trial_source = (setup + '\n' + call(expression)).replace('@TMP@', str(trial))
                result = probe(binary, trial_source, 'unset', trial)
                if 'error:type_mismatch\n' in result['out']:
                    changed, description = candidate, label
                    break
        modes = MODES if not requirements and changed else ('-',)
        for mode in modes:
            if requirements:
                state = 'SKIPPED(' + ','.join(requirements) + ')'
                rows.append((case['name'], description or 'SKIPPED', state, '-', '-', '-'))
                break
            if changed is None:
                rows.append((case['name'], 'NO_WRONG_TYPE', 'NO_WRONG_TYPE', '-', '-', '-'))
                break
            owned = scratch / f'{case_no}-{mode}'
            owned.mkdir()
            invariant = ('try:\n' + ''.join('    ' + line + '\n' for line in case['unchanged'].splitlines()
                                             if line.strip() and not line.lstrip().startswith('#'))
                         + '    print of "state:unchanged"\ncatch state_error:\n'
                         + '    print of "state:changed"\n')
            setup = case.get('setup', '')
            expression = case['name'] + ' of ([' + ', '.join(changed) + '])'
            snapshots = setup_snapshots(setup)
            source = (setup + '\n' + snapshots + '\nprint of "snapshot:call"\n'
                      + call(expression) + snapshots + '\n' + invariant).replace('@TMP@', str(owned))
            # The invocation's own line in the program as written, after the
            # setup, its snapshots, the snapshot:call print and the try: line.
            source_lines = source.split('\n')
            call_line = next(i + 1 for i, line in enumerate(source_lines)
                             if i > source_lines.index('print of "snapshot:call"')
                             and line.startswith('    answer is '))
            r = probe(binary, source, mode, owned, trace=True)
            # A sanitizer report, an abnormal exit or a missing end marker
            # fails the row, whatever the markers before it said.
            raised = ('broken' if r['broken'] else
                      'yes' if 'error:type_mismatch\n' in r['out'] else 'no')
            snapshot_lines = [line for line in r['out'].splitlines()
                              if line.startswith('snapshot:')]
            try:
                split = snapshot_lines.index('snapshot:call')
                same_snapshots = snapshot_lines[:split] == snapshot_lines[split + 1:]
            except ValueError:
                same_snapshots = False
            unchanged = 'yes' if 'state:unchanged\n' in r['out'] and same_snapshots else 'no'
            tape = tape_call_record(owned / 'probe.tape', call_line)
            rows.append((case['name'], description, mode, raised, unchanged, tape))
    if selected == 'all':
        legacy = measure_legacy_writers(binary, scratch)
        for result in legacy:
            raised = 'yes' if 'error:type_mismatch\n' in result['out'] else 'no'
            unchanged = 'yes' if result['unchanged'] else 'no'
            rows.append((result['name'], 'legacy-data-or-mutation', result['mode'],
                         raised, unchanged, 'no record'))
    return cases, rows


def measure(binary, scratch, only=None):
    api = subprocess.run([str(binary), '--api', '--json'], cwd=ROOT,
                         capture_output=True, text=True, check=True, timeout=30)
    core = sorted(json.loads(api.stdout)['builtins'])
    assert len(core) == len(set(core)) > 0
    rows, rejected = [], []
    for name in core:
        # report is a reserved observer form: its operand must be a binding.
        source = ('bool_operand is true\n' + call('report of bool_operand')
                  if name == 'report' else call(name + ' of true'))
        r = probe(binary, source, 'unset', scratch)
        rows.append(dict(group='direct', name=name, shape='bool', mode='unset', **r))
        if 'error:type_mismatch\n' in r['out']:
            rejected.append(name)
    assert len([r for r in rows if r['group'] == 'direct']) == len(core) > 0
    if only == 'direct':
        return dict(core=core, population=rejected, rows=rows)
    shapes = {'depth1': '[true]', 'depth2': '[[true]]',
              'depth3': '[[[true]]]', 'depth4': '[[[[true]]]]',
              'dict': '{"k": true}', 'list-dict': '[{"k": true}]'}
    for name in rejected:
        for shape, value in shapes.items():
            for mode in MODES:
                rows.append(dict(group='nested', name=name, shape=shape, mode=mode,
                                 **probe(binary, call(name + ' of (' + value + ')'), mode, scratch)))
    assert len([r for r in rows if r['group'] == 'nested']) == len(rejected) * len(shapes) * len(MODES) > 0
    for name, expression in IEEE.items():
        for mode in MODES:
            rows.append(dict(group='ieee', name=name, shape='scalar', mode=mode,
                             **probe(binary, call(expression), mode, scratch)))
    rows.extend(measure_legacy_writers(binary, scratch))
    # Reuse reviewed target invariants, rather than inventing a second list of
    # mutations. Restrict this census to the running core, with no services.
    shape_cases = [c for c in json.loads((ROOT / 'tests/strict_shape_cases.json').read_text())
                   if c['name'] in core and 'assert of' in c['unchanged']
                   and not c.get('requirements')]
    for case in shape_cases:
        for mode in MODES:
            owned = scratch / (case['name'] + '-' + mode)
            owned.mkdir()
            expression = case['name'] + ' of ([' + ', '.join(case['args'] + ['"surplus"']) + '])'
            invariant = ('try:\n' + ''.join('    ' + line + '\n' for line in case['unchanged'].splitlines())
                         + '    print of "state:unchanged"\ncatch state_error:\n'
                         + '    print of ("state:changed:" + state_error.message)\n')
            source = (case.get('setup', '') + '\n' + call(expression) + invariant + '\n'
                      + case.get('strict_cleanup', case.get('cleanup', '')))
            source = source.replace('@TMP@', str(owned))
            rows.append(dict(group='shape_writer', name=case['name'], shape='surplus', mode=mode,
                             **probe(binary, source, mode, owned)))
    for name, expression in {'abs': 'abs of ([[[true]]])',
                             'bit_or': 'bit_or of [1, 2, 3]'}.items():
        for mode in MODES:
            rows.append(dict(group='example', name=name, shape='brief', mode=mode,
                             **probe(binary, call(expression), mode, scratch)))
    return dict(core=core, population=rejected, rows=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'build/release/eigenscript')
    parser.add_argument('--record', type=Path)
    parser.add_argument('--compare', type=Path, nargs=2, metavar=('MAIN', 'HEAD'))
    parser.add_argument('--table', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--only', choices=['direct'])
    parser.add_argument('--writers', action='store_true')
    parser.add_argument('--writer', metavar='BUILTIN')
    args = parser.parse_args()
    if args.compare:
        assert args.table, '--compare requires --table'
        main_data, head_data = [json.loads(p.read_text()) for p in args.compare]
        assert main_data['core'] == head_data['core'] and len(head_data['core']) > 0
        assert main_data['population'] == head_data['population']
        def keyed(data):
            rows = {(r['group'], r['name'], r['shape'], r['mode']): r for r in data['rows']}
            assert len(rows) == len(data['rows']) > 0
            return rows
        old, new = keyed(main_data), keyed(head_data)
        assert old.keys() == new.keys()
        lines = ['group\tbuiltin\tshape\tmode\tmain_rc\tmain_stdout\thead_rc\thead_stdout\thead_unchanged']
        for key in old:
            a, b = old[key], new[key]
            lines.append('\t'.join([*key, str(a['rc']), json.dumps(a['out']),
                                    str(b['rc']), json.dumps(b['out']), str(b.get('unchanged', ''))]))
        args.table.write_text('\n'.join(lines) + '\n')
        ieee = [k for k in old if k[0] == 'ieee']
        assert len(ieee) == len(IEEE) * len(MODES) > 0
        assert all((old[k]['rc'], old[k]['out'], old[k]['err']) ==
                   (new[k]['rc'], new[k]['out'], new[k]['err']) for k in ieee)
        assert not any(r['broken'] for r in [*old.values(), *new.values()])
        print(f'COMPARISON2502: rows={len(old)} IEEE_unchanged={len(ieee)}; literal nested census retains failures')
        return 0
    if args.writers:
        print(json.dumps(effect_inventory(), indent=2))
        return 0
    if args.writer:
        with tempfile.TemporaryDirectory(prefix='eigs2502-') as tmp:
            cases, rows = measure_shape_writers(args.binary.resolve(), Path(tmp), args.writer)
        print('builtin\targument changed\tstate\traised\tunchanged\ttape')
        for row in rows:
            print('\t'.join(row))
        skipped = sum(r[2].startswith('SKIPPED(') for r in rows)
        no_type = sum(r[2] == 'NO_WRONG_TYPE' for r in rows)
        run = len(rows) - skipped - no_type
        bad = [r for r in rows if r[2] in MODES and
               (r[3] != 'yes' or r[4] != 'yes' or r[5] != 'no record')]
        print(f"{'FAIL' if bad else 'PASS'}: writers2502 examined={len(cases)} "
              f"rows={len(rows)} run={run} skipped={skipped} "
              f"no_wrong_type={no_type} failed={len(bad)}")
        return int(bool(bad))
    with tempfile.TemporaryDirectory(prefix='eigs2502-') as tmp:
        data = measure(args.binary.resolve(), Path(tmp), args.only)
        cleanup_mktemp(data['rows'])
    if args.record:
        args.record.write_text(json.dumps(data, indent=2) + '\n')
    broken = [r for r in data['rows'] if r['broken']]
    failures = [r for r in data['rows'] if r['group'] in ('nested', 'writer', 'shape_writer', 'example')
                and ('error:type_mismatch\n' not in r['out'] or
                     (r['group'] == 'writer' and not r['unchanged']) or
                     (r['group'] == 'shape_writer' and 'state:unchanged\n' not in r['out']))]
    for row in (broken + failures)[:30]:
        print('FAIL:', row['group'], row['name'], row['shape'], row['mode'], repr(row['out']), repr(row['err']))
    print(f"CENSUS2502: examined={len(data['core'])}/{len(data['core'])} population={len(data['population'])} rows={len(data['rows'])} broken={len(broken)} ruling_misses={len(failures)}")
    return int(bool(broken or failures)) if args.check else int(bool(broken))


if __name__ == '__main__':
    raise SystemExit(main())
