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


def writers(p):
    """Observable targets, including a late wrong element after a good one."""
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


def measure_writers(binary, scratch, selected=None):
    rows = []
    p = scratch / 'target'
    for name, (before, expression, after) in writers(p).items():
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
    rows.extend(measure_writers(binary, scratch))
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
    parser.add_argument('--writer', choices=['all', *writers('unused').keys()])
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
            rows = measure_writers(args.binary.resolve(), Path(tmp),
                                   None if args.writer == 'all' else args.writer)
        expected = len(writers('unused')) * 3 if args.writer == 'all' else 3
        assert len(rows) == expected > 0
        bad = [r for r in rows if r['broken'] or not r['unchanged'] or
               'error:type_mismatch\n' not in r['out']]
        for r in bad:
            print('FAIL: writer', r['name'], r['mode'], repr(r['out']),
                  'unchanged=' + str(r['unchanged']), repr(r['err']))
        print(f"{'FAIL' if bad else 'PASS'}: writers2502 examined={len(rows)}/{expected} failed={len(bad)}")
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
