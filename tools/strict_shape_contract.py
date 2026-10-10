#!/usr/bin/env python3
"""Reviewable fixed-list contracts; discovery does not consult max guards.

This is a lexical C inventory, not a C parser or proof about arbitrary pointers.
It follows calls passing the complete argument to named helpers. New source
surfaces must be classified; changed exempt bodies need renewed review.
"""
import argparse
import copy
import hashlib
import json
import re
import shutil
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'tools/strict_shape_contracts.json'
CASES = ROOT / 'tests/strict_shape_cases.json'
MASK = re.compile(r'/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')
DEF = re.compile(r'(?m)^[ \t]*(?:(?:static|inline|const|unsigned|signed)\s+)*[A-Za-z_]\w*(?:\s+\**\s*|\*+\s*)([A-Za-z_]\w*)\s*\([^;{}]*\)\s*\{')
KEYWORDS = {'if', 'else', 'for', 'while', 'switch', 'return', 'sizeof', 'do'}
GUARD = re.compile(r'STRICT_LIST_MAX\(arg,\s*(\d+),\s*"([^"]+)"\)\s*;')


def masked(source):
    return MASK.sub(lambda m: re.sub(r'[^\n]', ' ', m.group()), source)


def closing(source, start, left, right):
    depth = 1
    for i in range(start + 1, len(source)):
        if source[i] == left:
            depth += 1
        elif source[i] == right:
            depth -= 1
            if depth == 0:
                return i
    raise ValueError('unbalanced source at offset ' + str(start))


def functions(sources):
    out = {}
    for path, source in sorted(sources.items()):
        mask = masked(source)
        for match in DEF.finditer(mask):
            name = match[1]
            if name in KEYWORDS:
                continue
            end = closing(mask, match.end() - 1, '{', '}') + 1
            body = source[match.start():end]
            code = mask[match.end():end - 1]
            # Deliberately remove annotations before candidate discovery.
            code = re.sub(r'STRICT_LIST_MAX\([^;]*;', '', code)
            # data.list or its #1665 container.h accessors (list_get_*/list_iter_*/...)
            direct = bool(re.search(r'\bVAL_LIST\b|data\.list|\blist_(?:get|set|iter|values)_\w*\(|\bARG_COUNT\b|\bARG_AT\b', code))
            direct |= 'arg->data.dict' in code and bool(re.search(r'\bmake_list\s*\(', code))
            helpers = set()
            for call in re.finditer(r'\b([A-Za-z_]\w*)\s*\(', code):
                if call[1] in KEYWORDS:
                    continue
                last = closing(code, call.end() - 1, '(', ')')
                arguments = code[call.end():last]
                if re.search(r'(?:^|,)\s*arg\s*(?:,|$)', arguments):
                    helpers.add(call[1])
            out.setdefault(name, []).append(dict(file=path, body=body, direct=direct,
                                                  helpers=helpers))
    return out


def discover(funcs):
    reached = {name for name, defs in funcs.items() if any(d['direct'] for d in defs)}
    while True:
        more = {name for name, defs in funcs.items()
                if any(d['helpers'] & reached for d in defs)} - reached
        if not more:
            return {name for name in reached if name.startswith('builtin_')}
        reached |= more


def aliases(sources, header):
    pairs = re.findall(r'"([A-Za-z0-9_]+)"\s*,\s*make_builtin\(\s*(builtin_\w+)\s*\)', '\n'.join(sources.values()))
    pairs += re.findall(r'\bX\(\s*(\w+)\s*,\s*(builtin_\w+)\s*\)', header)
    out = {}
    for public, function in pairs:
        out.setdefault(function, set()).add(public)
    return out



def exemption_sources(name, funcs):
    """Pin the whole-argument helper closure as well as the public wrapper."""
    pending, seen = [name], set()
    while pending:
        current = pending.pop()
        if current in seen or current not in funcs:
            continue
        seen.add(current)
        for definition in funcs[current]:
            pending.extend(definition['helpers'])
    return {key: sorted(hashlib.sha256(d['body'].encode()).hexdigest() for d in funcs[key])
            for key in sorted(seen)}


def audit(sources, header, contracts, cases):
    errors = []
    funcs = functions(sources)
    found = discover(funcs)
    named = [r['function'] for r in contracts]
    if len(named) != len(set(named)):
        errors.append('duplicate contract function')
    if found != set(named):
        errors.append('population missing=' + repr(sorted(found - set(named))) +
                      ' stale=' + repr(sorted(set(named) - found)))
    registered = aliases(sources, header)
    controls = [r['name'] for r in cases]
    if len(controls) != len(set(controls)):
        errors.append('duplicate control name')
    expected_controls = set()
    for row in contracts:
        name = row['function']
        defs = funcs.get(name, [])
        if not defs:
            continue
        actual_names = registered.get(name, {name.removeprefix('builtin_')})
        if set(row['public_names']) != actual_names:
            errors.append(name + ': public registrations changed')
        if not row.get('reason'):
            errors.append(name + ': missing classification reason')
        guards = [g.groups() for d in defs for g in GUARD.finditer(d['body'])]
        if row['disposition'] == 'guarded':
            public = row['public_names'][0]
            maximum = row['maximum']
            expected_controls.add(public)
            if guards != [(str(maximum), public)]:
                errors.append(name + ': expected one named max-' + str(maximum) + ' guard')
            for d in defs:
                # A Value-returning entry guard must precede every statement.
                body = d['body'][d['body'].index('{') + 1:]
                first = GUARD.search(body)
                if first is None or masked(body[:first.start()]).strip():
                    errors.append(name + ': max guard is not first')
            case = next((c for c in cases if c['name'] == public), None)
            if case is not None:
                if len(case.get('args', [])) != maximum:
                    errors.append(public + ': valid tuple width differs from contract')
                if row['category'].startswith('optional') and not (case.get('optional_args') or case.get('scalar_forms')):
                    errors.append(public + ': missing optional/scalar control')
                if not case.get('claim') or not isinstance(case.get('requirements', []), list):
                    errors.append(public + ': missing control scope/requirements')
                if not case.get('observe') or not case.get('unchanged'):
                    errors.append(public + ': missing result or no-effect observation')
                required = set(case.get('requirements', []))
                backend = ('mixer' if 'sdl_mixer' in required else
                           'sdl' if required & {'sdl_dummy_audio', 'sdl_dummy_video'} else '')
                if case.get('backend', '') != backend:
                    errors.append(public + ': device requirement/backend classification differs')
                if backend:
                    absent = case.get('backend_absent', {})
                    states = {'absent-sdl', 'absent-mixer'} if backend == 'mixer' else {'absent-sdl'}
                    if (not isinstance(absent, dict) or
                            not all(isinstance(absent.get(k), str) for k in
                                    ('setup', 'valid_assert', 'observe', 'unchanged', 'claim')) or
                            set(absent.get('outputs', {})) != states or
                            not all(isinstance(v, str) and v.endswith('\nshape-complete')
                                    for v in absent.get('outputs', {}).values())):
                        errors.append(public + ': incomplete documented backend-absence controls')
        elif row['disposition'] == 'exempt':
            if guards:
                errors.append(name + ': exempt function has a max guard')
            hashes = sorted(hashlib.sha256(d['body'].encode()).hexdigest() for d in defs)
            if hashes != row.get('body_sha256') or exemption_sources(name, funcs) != row.get('source_sha256'):
                errors.append(name + ': exempt source/helper changed; review the contract')
        else:
            errors.append(name + ': unknown disposition')
    if set(controls) != expected_controls:
        errors.append('controls missing=' + repr(sorted(expected_controls - set(controls))) +
                      ' stale=' + repr(sorted(set(controls) - expected_controls)))
    return errors, len(found), len(expected_controls)


def selftest():
    # Inert source text only. No compiler/runtime or intentionally unsafe input.
    source = '''Value* builtin_pair(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "pair");
    return arg->data.list.items[0];
}
Value* builtin_data(Value *arg) {
    return helper(arg);
}
static double *helper(Value *arg) {
    return arg->data.list.items[0];
}
void register_all(Env *env) {
    env_set_local_owned(env, "pair", make_builtin(builtin_pair));
    env_set_local_owned(env, "data", make_builtin(builtin_data));
}
'''
    sources = {'src/example.c': source}
    contract = [dict(function='builtin_pair', public_names=['pair'], disposition='guarded',
                     category='fixed', maximum=2, reason='two operands'),
                dict(function='builtin_data', public_names=['data'], disposition='exempt',
                     reason='whole list data', body_sha256=[])]
    contract[1]['body_sha256'] = [hashlib.sha256(functions(sources)['builtin_data'][0]['body'].encode()).hexdigest()]
    contract[1]['source_sha256'] = exemption_sources('builtin_data', functions(sources))
    cases = [dict(name='pair', args=['[2, 3]', '0'], observe='print of shape_result',
                  unchanged='assert of [1, "pure call"]', claim='ordinary finite pair', requirements=[])]
    scenarios = []
    def add(label, expected, source_edit=None, contract_edit=None, case_edit=None, header=''):
        s, c, k = copy.deepcopy(sources), copy.deepcopy(contract), copy.deepcopy(cases)
        if source_edit:
            source_edit(s)
        if contract_edit:
            contract_edit(c)
        if case_edit:
            case_edit(k)
        scenarios.append((label, expected, s, header, c, k))
    def replace(a, b):
        return lambda s: s.update({'src/example.c': s['src/example.c'].replace(a, b)})
    add('healthy', True)
    add('missing guard', False, replace('    STRICT_LIST_MAX(arg, 2, "pair");\n', ''))
    add('guard plus contract/control omitted', False,
        replace('    STRICT_LIST_MAX(arg, 2, "pair");\n', ''), lambda c: c.pop(0), lambda k: k.clear())
    add('wrong maximum', False, replace('MAX(arg, 2', 'MAX(arg, 3'))
    add('wrong public diagnostic', False, replace('2, "pair"', '2, "other"'))
    add('late guard', False, replace('    STRICT_LIST_MAX', '    touch(arg);\n    STRICT_LIST_MAX'))
    add('missing control', False, case_edit=lambda k: k.clear())
    add('duplicate control', False, case_edit=lambda k: k.append(copy.deepcopy(k[0])))
    add('wrong valid width', False, case_edit=lambda k: k[0]['args'].pop())
    add('stale exemption', False, replace('return helper(arg);', 'return another(arg);'))
    add('changed exemption helper', False, replace('return arg->data.list.items[0];\n}\nvoid register_all', 'return arg->data.list.items[1];\n}\nvoid register_all'))
    add('changed exemption body', False, replace('return helper(arg);', 'return helper(arg); /* reviewed body changed */'))
    add('unclassified new helper caller', False, replace('void register_all', 'Value* builtin_extra(Value *arg) { return helper(arg); }\nvoid register_all'))
    add('registry alias change', False, replace('"pair", make_builtin', '"renamed", make_builtin'))
    add('macro registry alias change', False, header='X(renamed, builtin_pair)')
    add('comments and strings are not new functions', True, replace('void register_all', '/* Value* builtin_ghost(Value *arg) { return arg->data.list; } */\nvoid register_all'))
    add('optional positive missing', False, contract_edit=lambda c: c[0].update(category='optional'))
    add('device requirement without backend classification', False,
        case_edit=lambda k: k[0].update(requirements=['sdl_dummy_audio']))
    add('backend classification without absence controls', False,
        case_edit=lambda k: k[0].update(requirements=['sdl_dummy_audio'], backend='sdl'))
    add('pure control must not become backend absent', False,
        case_edit=lambda k: k[0].update(backend='sdl'))
    passed = 0
    for label, expected, s, header, c, k in scenarios:
        errors, _, _ = audit(s, header, c, k)
        ok = (not errors) == expected
        print(('PASS: ' if ok else 'FAIL: ') + label)
        passed += ok
    print(f'SHAPE_CONTRACT_SELFTEST: {passed} passed, {len(scenarios)-passed} failed, {len(scenarios)} declared')
    return 0 if passed == len(scenarios) else 1



def render_program(row, form, operands, operation, scalar=False):
    """Render data for the existing differential; never execute a program."""
    surplus = operation in ('surplus', 'strict')
    args = operands + ['"shape-surplus"'] if surplus else operands
    value = args if scalar else '[' + ', '.join(args) + ']'
    expression = row['name'] + ' of (' + value + ')'
    parts = [row.get('setup', '')]
    if operation == 'strict':
        expected = row['name'] + ': expected a fixed-shape list with at most ' + str(len(row['args'])) + ' elements'
        parts += ['shape_caught is 0', 'try:', '    shape_result is ' + expression,
                  'catch shape_error:',
                  '    assert of [shape_error.kind == "type_mismatch", "wrong surplus kind"]',
                  '    assert of [shape_error.message == ' + json.dumps(expected) + ', "wrong surplus message"]',
                  '    shape_caught is 1',
                  'assert of [shape_caught == 1, "surplus call returned"]', row['unchanged']]
    else:
        assertion = row.get('form_asserts', {}).get(form, row['valid_assert'])
        observation = row['observe']
        if surplus and row.get('legacy_surplus_null'):
            assertion, observation = 'shape_result == null', 'print of shape_result'
        if surplus and row.get('legacy_surplus_assert'):
            assertion = row['legacy_surplus_assert']
            observation = row.get('legacy_surplus_observe', 'print of shape_result')
        parts += ['shape_result is ' + expression,
                  'assert of [' + assertion + ', "valid shape result"]', observation]
    cleanup = row.get('strict_cleanup', row.get('cleanup', '')) if operation == 'strict' else row.get('cleanup', '')
    parts += [cleanup, 'print of "shape-complete"']
    return '\n'.join(p for p in parts if p) + '\n'


def render(directory, cases):
    """Fresh resources per binary/mode/form; TSV is consumed by the old gate."""
    directory.mkdir(parents=True, exist_ok=False)
    manifest = []
    for row in cases:
        name = row['name']
        forms = [('max', row['args'], False)]
        forms += [('optional-' + str(i), value, False) for i, value in enumerate(row.get('optional_args', []))]
        forms += [('scalar-' + str(i), value, True) for i, value in enumerate(row.get('scalar_forms', []))]
        pending = row.get('pending', '')
        for tool, placeholder in [('cat', '@CAT@'), ('printf', '@PRINTF@')]:
            if placeholder in json.dumps(row) and not shutil.which(tool):
                pending = 'required ordinary tool unavailable: ' + tool
        (directory / name).mkdir()
        (directory / name / 'pending').write_text(pending + '\n')
        variants = [('', row)]
        if row.get('backend'):
            variants.append(('-absent', dict(row, **row['backend_absent'])))
            for state, output in row['backend_absent']['outputs'].items():
                (directory / name / state).write_text('0\n' + output + '\n')
        for suffix, active in variants:
            for which in ('subject' + suffix, 'baseline' + suffix):
                for mode in ('0', '1', 'default'):
                    for form, values, scalar in forms + [('surplus', row['args'], False), ('strict', row['args'], False)]:
                        owned = directory / name / which / mode / form
                        owned.mkdir(parents=True)
                        operation = form if form in ('surplus', 'strict') else 'valid'
                        assertion_form = form.replace('optional-', 'optional:').replace('scalar-', 'scalar:')
                        source = render_program(active, assertion_form, values, operation, scalar)
                        substitutions = {'@TMP@': str(owned), '@CAT@': shutil.which('cat') or '', '@PRINTF@': shutil.which('printf') or '', '@WAV@': str(owned / 'sample.wav')}
                        if '@WAV@' in source:
                            with wave.open(str(owned / 'sample.wav'), 'wb') as wav:
                                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(44100)
                                wav.writeframes(b'\0\0' * 32)
                        for before, after in substitutions.items():
                            source = source.replace(before, json.dumps(after)[1:-1])
                        (owned / 'case.eigs').write_text(source)
                        if active.get('http_context'):
                            (owned / 'http-context').write_text(active['http_context'] + '\n')
                        if 'stdin_bytes' in active.get('requirements', []):
                            (owned / 'stdin-context').write_text('abc')
        legacy = int(bool(row.get('legacy_surplus_null') or row.get('legacy_surplus_assert')))
        manifest.append('|'.join([name, str(len(row['args'])), ','.join(f[0] for f in forms), str(legacy), str(int(bool(row.get('exits')))), str(int(bool(pending))), row.get('backend', 'none')]))
    (directory / 'rows').write_text('\n'.join(manifest) + '\n')
    # Ordinary dependency witnesses use the same owning runtime and dummy drivers.
    backend_dir = directory / 'backend'
    backend_dir.mkdir()
    wav_path = backend_dir / 'sample.wav'
    with wave.open(str(wav_path), 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(44100)
        wav.writeframes(b'\0\0' * 32)
    (backend_dir / 'sdl.eigs').write_text(
        'shape_backend_result is gfx_open of [8, 8, "shape-backend"]\n'
        'print of ("shape-backend: " + (str of shape_backend_result))\n'
        'gfx_close of null\n')
    (backend_dir / 'mixer.eigs').write_text(
        'shape_backend_result is audio_music_play of [' + json.dumps(str(wav_path)) + ', 0]\n'
        'print of ("shape-backend: " + (str of shape_backend_result))\n'
        'audio_music_stop of null\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selftest', action='store_true')
    parser.add_argument('--render', type=Path, help='render inert fixtures after checking source contracts')
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    sources = {p.relative_to(ROOT).as_posix(): p.read_text() for p in (ROOT / 'src').glob('*.c')}
    errors, total, guarded = audit(sources, (ROOT / 'src/ext_names.h').read_text(),
                                  json.loads(DATA.read_text()), json.loads(CASES.read_text()))
    for error in errors:
        print('FAIL: shape-contract: ' + error)
    print(f'SHAPE_CONTRACT: candidates={total} guarded={guarded} exempt={total-guarded} errors={len(errors)}')
    if not errors and args.render:
        render(args.render, json.loads(CASES.read_text()))
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
