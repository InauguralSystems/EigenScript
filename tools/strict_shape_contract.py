#!/usr/bin/env python3
"""Reviewable fixed-list contracts; discovery does not consult max guards.

This is a lexical C inventory, not a C parser or proof about arbitrary pointers.
It follows calls passing the complete argument to named helpers. New source
surfaces must be classified; changed exempt bodies need renewed review. Use
``--repin NAME`` to preview renewed pins and ``--repin NAME --write`` to apply
them without reformatting the contracts file.
"""
import argparse
import contextlib
import copy
import hashlib
import io
import json
import re
import shutil
import tempfile
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


PUNCTUATORS = {
    '++', '--', '->', '<<', '>>', '<=', '>=', '==', '!=', '&&', '||',
    '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '##', '.*', '...',
    '<<=', '>>=', '->*', '//', '/*', '*/', '..', '<:', ':>', '<%', '%>',
    '%:', '::', '??',
}


def needs_separator(left, right):
    """Whether removing whitespace between two characters changes C tokens."""
    return ((left.isascii() and (left.isalnum() or left == '_') and
             right.isascii() and (right.isalnum() or right == '_')) or
            left + right in PUNCTUATORS or
            (left == '.' and right.isdigit()) or
            (left.isdigit() and right == '.'))


def normalized(source):
    """Remove comments and insignificant whitespace, preserving C token boundaries."""
    # C11 translation phase 2 happens before comments and tokens are recognized.
    source = re.sub(r'\\\r?\n', '', source)
    pieces = []
    pending_space = False
    pending_directive_newline = False
    line_has_code = False
    directive = False

    def whitespace(text):
        nonlocal pending_space, pending_directive_newline, line_has_code, directive
        if not text:
            return
        pending_space = True
        if '\n' in text:
            if directive:
                pending_directive_newline = True
            line_has_code = False
            directive = False

    def emit(token):
        nonlocal pending_space, pending_directive_newline, line_has_code, directive
        if pending_directive_newline:
            pieces.append('\n')
        elif pending_space and pieces and pieces[-1] != '\n' and needs_separator(pieces[-1][-1], token[0]):
            pieces.append(' ')
        if not line_has_code and token[0] == '#':
            directive = True
        pieces.append(token)
        line_has_code = True
        pending_space = pending_directive_newline = False

    end = 0
    for match in MASK.finditer(source):
        for part in re.split(r'(\s+)', source[end:match.start()]):
            whitespace(part) if part.isspace() else (emit(part) if part else None)
        token = match.group()
        if token.startswith(('"', "'")):
            emit(token)
        else:
            whitespace(token)
        end = match.end()
    for part in re.split(r'(\s+)', source[end:]):
        whitespace(part) if part.isspace() else (emit(part) if part else None)
    if pending_directive_newline:
        pieces.append('\n')
    return ''.join(pieces)


def body_hash(body):
    """The single implementation of an exempt source-body hash."""
    return hashlib.sha256(normalized(body).encode()).hexdigest()


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
            direct = bool(re.search(r'\bVAL_LIST\b|data\.list|\blist_(?:get|set|iter|values)_\w*\(|\blist_sort\(|\bARG_COUNT\b|\bARG_AT\b', code))
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
    return {key: sorted(body_hash(d['body']) for d in funcs[key])
            for key in sorted(seen)}


def replace_row_hashes(text, row, replacement):
    """Replace one row's pins by key, preserving bytes outside the pin values."""
    marker = '"function": ' + json.dumps(row['function'])
    middle = text.index(marker)
    start = text.rfind('  {', 0, middle)
    end = text.find('\n  }', middle) + len('\n  }')
    row_text = text[start:end]
    body_start = row_text.index('"body_sha256"')
    body_left = row_text.index('[', body_start)
    body_right = closing(row_text, body_left, '[', ']') + 1
    old_body = row.get('body_sha256', [])
    new_body = replacement.get('body_sha256', [])
    if len(old_body) != len(new_body):
        raise ValueError('function definition count changed')
    body_text = row_text[body_left:body_right]
    for old, new in zip(old_body, new_body):
        body_text, count = re.subn('"' + re.escape(old) + '"', '"' + new + '"', body_text, count=1)
        if count != 1:
            raise ValueError('on-disk body hashes do not match the parsed row')
    changed = row_text[:body_left] + body_text + row_text[body_right:]

    source_start = changed.index('"source_sha256"')
    source_left = changed.index('{', source_start)
    source_right = closing(changed, source_left, '{', '}') + 1
    line_start = changed.rfind('\n', 0, source_start) + 1
    key_indent = changed[line_start:source_start]
    rendered = json.dumps(replacement['source_sha256'], indent=2, sort_keys=True)
    rendered = rendered.replace('\n', '\n' + key_indent)
    changed = changed[:source_left] + rendered + changed[source_right:]
    return text[:start] + changed + text[end:]


def repin(name, write, sources, contracts, data_path=DATA):
    row = next((item for item in contracts if item['function'] == name), None)
    if row is None:
        print(f'REFUSED: {name}: no contract row')
        return 2
    if row.get('disposition') != 'exempt':
        print(f"REFUSED: {name}: disposition is {row.get('disposition')}, not exempt: {row.get('reason', '')}")
        return 2
    funcs = functions(sources)
    if name not in funcs:
        print(f'REFUSED: {name}: function is absent from current sources')
        return 2
    current_sources = exemption_sources(name, funcs)
    replacement = copy.deepcopy(row)
    replacement['body_sha256'] = sorted(body_hash(d['body']) for d in funcs[name])
    replacement['source_sha256'] = current_sources
    pinned_sources = row.get('source_sha256', {})
    members = sorted(set(pinned_sources) | set(current_sources) | {name})
    for member in members:
        pinned = row.get('body_sha256', []) if member == name else pinned_sources.get(member, [])
        current = replacement['body_sha256'] if member == name else current_sources.get(member, [])
        print(f"{member}: pinned={','.join(pinned) or '<missing>'} current={','.join(current) or '<missing>'} "
              + ('CHANGED' if pinned != current else 'same'))
    if (row.get('body_sha256', []) == replacement['body_sha256'] and
            pinned_sources == current_sources):
        print(f'REPIN: {name}: no changes')
        return 0
    if not write:
        print(f'REPIN: {name}: dry run; use --write after review')
        return 0
    try:
        updated = replace_row_hashes(data_path.read_text(), row, replacement)
    except ValueError as error:
        print(f'REFUSED: {name}: {error}')
        return 2
    data_path.write_text(updated)
    print(f'REPIN: {name}: wrote reviewed source pins')
    return 0


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
            hashes = sorted(body_hash(d['body']) for d in defs)
            actual_sources = exemption_sources(name, funcs)
            pinned_sources = row.get('source_sha256', {})
            changed_members = {member for member in set(actual_sources) | set(pinned_sources)
                               if actual_sources.get(member) != pinned_sources.get(member)}
            if hashes != row.get('body_sha256'):
                changed_members.add(name)
            for member in sorted(changed_members):
                errors.append(name + ': exempt source/helper changed (' + member + '); review the contract')
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
    int token = 1;
    const char *block = "/*";
    int slash = '//';
    return helper(arg);
}
static double *helper(Value *arg) {
    /* helper explanation */
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
    contract[1]['body_sha256'] = [body_hash(functions(sources)['builtin_data'][0]['body'])]
    contract[1]['source_sha256'] = exemption_sources('builtin_data', functions(sources))
    cases = [dict(name='pair', args=['[2, 3]', '0'], observe='print of shape_result',
                  unchanged='assert of [1, "pure call"]', claim='ordinary finite pair', requirements=[])]
    scenarios = []
    def add(label, expected, source_edit=None, contract_edit=None, case_edit=None, header='', named=None):
        s, c, k = copy.deepcopy(sources), copy.deepcopy(contract), copy.deepcopy(cases)
        if source_edit:
            source_edit(s)
        if contract_edit:
            contract_edit(c)
        if case_edit:
            case_edit(k)
        scenarios.append((label, expected, s, header, c, k, named))
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
    add('one-token code change in exempt builtin names function', False,
        replace('int token = 1;', 'int token = 2;'), named='builtin_data')
    add('one-token code change in closure helper names function', False,
        replace('return arg->data.list.items[0];\n}\nvoid register_all', 'return arg->data.list.items[1];\n}\nvoid register_all'),
        named='builtin_data')
    add('comment-only edit to exempt builtin', True,
        replace('return helper(arg);', '/* revised explanation */ return helper(arg);'))
    add('comment-only edit to closure helper', True,
        replace('/* helper explanation */', '// revised helper explanation'))
    add('block-comment opener inside string is code', False, replace('"/*"', '"/**"'))
    add('line-comment opener inside char literal is code', False, replace("'//'", "'/**'"))
    add('whitespace-only change between tokens', True, replace('int token', 'int   token'))
    add('joining two tokens changes code', False, replace('int token', 'inttoken'))
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
    for label, expected, s, header, c, k, named in scenarios:
        errors, _, _ = audit(s, header, c, k)
        ok = (not errors) == expected and (named is None or any(named in e for e in errors))
        print(('PASS: ' if ok else 'FAIL: ') + label)
        passed += ok

    normalization_cases = [
        ('char literal protects following code',
         "int slash = '//'; int after = 1;", "int slash = '//'; int after = 2;", False),
        ('string protects code before later comment close',
         'char *s = "/*"; int between = 1; /* later */',
         'char *s = "/*"; int between = 2; /* later */', False),
        ('literal whitespace is verbatim', 'char *s = "a  b";', 'char *s = "a b";', False),
        ('comment separates words', 'int/**/x;', 'intx;', False),
        ('comment beside punctuation is ignored', 'f(1 /* max */);', 'f(1);', True),
        ('punctuation whitespace is ignored', 'a+b;', 'a + b;', True),
        ('punctuation token boundary is retained', 'a - -b;', 'a--b;', False),
        ('preprocessor line cannot merge', '#define X 1\nfoo', '#define X 1 foo', False),
        ('line splices precede tokenization', 'int x = a\\\n+b;', 'int x=a+b;', True),
    ]
    for label, left, right, expected in normalization_cases:
        ok = (normalized(left) == normalized(right)) == expected
        print(('PASS: ' if ok else 'FAIL: ') + label)
        passed += ok

    # Re-pin tests use only a temporary contracts file; never touch the real pins.
    repin_source = source
    repin_sources = {'src/example.c': repin_source}
    repin_contract = copy.deepcopy(contract)
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory) / 'contracts.json'

        def run_repin(label, name, write, active_sources, active_contract, predicate):
            scratch.write_text(json.dumps(active_contract, indent=2) + '\n')
            before = scratch.read_text()
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                rc = repin(name, write, active_sources, active_contract, scratch)
            after = scratch.read_text()
            ok = predicate(rc, output.getvalue(), before, after)
            nonlocal_pass[0] += ok
            print(('PASS: ' if ok else 'FAIL: ') + label)

        nonlocal_pass = [0]
        run_repin('repin no-op', 'builtin_data', True, repin_sources, repin_contract,
                  lambda rc, out, before, after: rc == 0 and 'no changes' in out and before == after)
        run_repin('repin refuses guarded row', 'builtin_pair', True, repin_sources, repin_contract,
                  lambda rc, out, before, after: rc == 2 and 'disposition is guarded' in out and before == after)

        prefix_contract = copy.deepcopy(repin_contract)
        prefix_contract.insert(0, dict(prefix_contract[1], function='builtin_data_more'))
        run_repin('repin exact prefix name', 'builtin_data', True, repin_sources, prefix_contract,
                  lambda rc, out, before, after: rc == 0 and 'no changes' in out and before == after)

        changed_sources = {'src/example.c': repin_source.replace('int token = 1;', 'int token = 2;')}
        unsorted = copy.deepcopy(repin_contract)
        source_pins = unsorted[1]['source_sha256']
        unsorted[1]['source_sha256'] = {key: source_pins[key] for key in reversed(source_pins)}
        run_repin('repin maps unsorted keys correctly', 'builtin_data', True, changed_sources, unsorted,
                  lambda rc, out, before, after: rc == 0 and
                  json.loads(after)[1]['source_sha256'] == exemption_sources('builtin_data', functions(changed_sources)))

        expanded_source = repin_source.replace(
            'static double *helper(Value *arg) {\n    /* helper explanation */\n    return arg->data.list.items[0];',
            'static Value *extra(Value *arg) { return arg->data.list.items[0]; }\n'
            'static double *helper(Value *arg) {\n    /* helper explanation */\n    return extra(arg);')
        expanded_sources = {'src/example.c': expanded_source}

        def shape_written(rc, out, before, after):
            parsed = json.loads(after)
            return (rc == 0 and 'extra' in parsed[1]['source_sha256'] and
                    parsed[1]['source_sha256'] == exemption_sources('builtin_data', functions(expanded_sources)))

        run_repin('repin writes closure-shape changes', 'builtin_data', True,
                  expanded_sources, repin_contract, shape_written)

        def outside_source_object(text):
            marker = '"source_sha256"'
            left = text.index('{', text.index(marker))
            right = closing(text, left, '{', '}') + 1
            return text[:left] + '<SOURCE_PINS>' + text[right:]

        run_repin('repin preserves bytes outside changed pin objects', 'builtin_data', True,
                  expanded_sources, repin_contract,
                  lambda rc, out, before, after: rc == 0 and
                  outside_source_object(before) == outside_source_object(after))
        passed += nonlocal_pass[0]
    scenarios.extend([(label, expected, None, None, None, None, None)
                      for label, _, _, expected in normalization_cases])
    scenarios.extend([('repin', True, None, None, None, None, None)] * 6)
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
    parser.add_argument('--repin', metavar='NAME', help='preview current hashes for one exempt row')
    parser.add_argument('--write', action='store_true', help='with --repin, update only that row\'s source pins')
    args = parser.parse_args()
    if args.write and not args.repin:
        parser.error('--write requires --repin NAME')
    if args.selftest:
        return selftest()
    sources = {p.relative_to(ROOT).as_posix(): p.read_text() for p in (ROOT / 'src').glob('*.c')}
    contracts = json.loads(DATA.read_text())
    if args.repin:
        return repin(args.repin, args.write, sources, contracts)
    errors, total, guarded = audit(sources, (ROOT / 'src/ext_names.h').read_text(),
                                  contracts, json.loads(CASES.read_text()))
    for error in errors:
        print('FAIL: shape-contract: ' + error)
    print(f'SHAPE_CONTRACT: candidates={total} guarded={guarded} exempt={total-guarded} errors={len(errors)}')
    if not errors and args.render:
        render(args.render, json.loads(CASES.read_text()))
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
