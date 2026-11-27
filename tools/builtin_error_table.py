#!/usr/bin/env python3
"""Run the finite builtin error populations; generate only claims those rows test."""
import argparse
import collections
import functools
import copy
import json
import os
from pathlib import Path
import re
import resource
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / 'tests/builtin_errors'
SLOTS = {'tensor_load': ('path',), 'sgd_update': ('params', 'grad', 'lr'),
         'audio_music_play': ('path', 'loops')}
KINDS = {'bool', 'string', 'null', 'list', 'dict', 'buffer', 'number'}
STATES = (None, '0', '1')

class Unrun(Exception):
    pass
def answer_arms(row):
    return (row, dict(row, **row['device_unavailable'])) if row.get('device_unavailable') else (row,)
def read_tables(directory):
    tables = {b: [json.loads(x) for x in (directory / (b + '.jsonl')).read_text().splitlines()]
              for b in SLOTS}
    assert {p.stem for p in directory.glob('*.jsonl')} == set(SLOTS), 'unknown or missing builtin table'
    counts = json.loads((TABLES / 'populations.json').read_text())
    for builtin, rows in tables.items():
        assert len(rows) == counts[builtin] > 0, f'{builtin}: population missing (want {counts[builtin]})'
        assert len({r['id'] for r in rows}) == len(rows), f'{builtin}: duplicate id'
        for slot in SLOTS[builtin]:
            seen = set()
            for r in rows:
                assert r[slot + '_kind'] in KINDS, f"{r['id']}: {slot} kind is not a singleton"
                assert isinstance(r[slot + '_shape'], str) and isinstance(r[slot], str), r['id']
                shape = r[slot+'_shape']
                if r[slot+'_kind'] == 'list':
                    assert re.fullmatch(r'flat:[0-9]+|rows:[0-9]+(?:x[0-9]+|\[[0-9, ]*\])', shape), f'{builtin}/{r["id"]}: invalid list shape'
                seen.add(r[slot + '_kind'])
            assert seen == KINDS, f'{builtin}/{slot}: missing kinds {KINDS - seen}'
        assert all(set(r.get('device_unavailable', {})) <= {'expected_kind', 'written', 'result', 'errors'} for r in rows), f'{builtin}: invalid backend answer fields'
        for r in (arm for row in rows for arm in answer_arms(row)):
            assert r['order'] and all(isinstance(x, str) for x in r['order']), r['id']
            assert isinstance(r['written'], (bool, list)), r['id']
            assert isinstance(r['expected_kind'], (str, list)), r['id']
            assert set(r['errors']) <= set(r['order']), r['id']
            for answer in (r, *r['errors'].values()):
                for col in ('written', 'expected_kind', 'kind', 'message'):
                    if isinstance(answer.get(col), list):
                        assert len(answer[col]) == len(STATES), f"{r['id']}: incomplete states in {col}"
            assert all(c['kind'] and c['message'] for c in r['errors'].values()), r['id']
            for check, answer in r['errors'].items():
                mode = answer.get('match', 'exact')
                assert mode in ('exact', 'prefix', 'reason'), f"{builtin}/{r['id']}/{check}: unknown match"
                if (builtin, check) == ('audio_music_play', 'decode'):
                    # SDL_mixer's decode reason depends on its backend: only reason mode is green on both.
                    assert mode == 'reason', f"{builtin}/{r['id']}/{check}: a music decode line must use reason"
                if mode == 'reason':
                    # A library's reason text differs by backend (libmodplug vs libxmp): pin ours, not theirs.
                    assert isinstance(answer.get('why'), str) and answer['why'].strip(), f"{builtin}/{r['id']}/{check}: reason requires why"
                    assert (builtin, check) == ('audio_music_play', 'decode'), f"{builtin}/{r['id']}/{check}: reason has no library diagnostic"
                    head = f"{builtin}: '{r['path'].strip(chr(34))}': "
                    for s in range(len(STATES)):
                        message = per_state(answer['message'], s)
                        tail = message[len(head):]
                        assert message.startswith(head) and tail.endswith(': ') and ': ' not in tail[:-2] and tail[:-2].strip(), f"{builtin}/{r['id']}/{check}: reason must be our fixed text after the path, ending at the library's separator"
                if mode == 'prefix':
                    assert isinstance(answer.get('why'), str) and answer['why'].strip(), f"{builtin}/{r['id']}/{check}: prefix requires why"
                    assert builtin != 'sgd_update' and check in ('open', 'directory'), f"{builtin}/{r['id']}/{check}: prefix has no external diagnostic (a music decode line uses reason)"
                    for s in range(len(STATES)):
                        message = per_state(answer['message'], s)
                        head = f"{builtin}: '{r['path'].strip(chr(34))}': "
                        assert message.startswith(head) and len(message) > len(head) and '@' not in message.replace('@FILE@', ''), f"{builtin}/{r['id']}/{check}: prefix must include fixed text and extend beyond @FILE@"
            if builtin == 'tensor_load':
                # File-error checks replay exactly; cap/nonfinite verdicts hit the replay boundary.
                must_tape = r['path_kind'] == 'string' and all(
                    first_check(r, s) not in (None, 'cap', 'nonfinite') for s in range(len(STATES)))
                assert type(r.get('tape')) is bool and r['tape'] == must_tape, f"{builtin}/{r['id']}: tape must be {must_tape}"
    return tables

def per_state(value, index):
    return value[index] if isinstance(value, list) else value
def first_check(row, index):
    return next((c for c in row['order'] if c in row['errors']
                 and per_state(row['errors'][c]['kind'], index) != 'ok'), None)

def fixture(row, work):
    path = work / 'input.tensor'
    mode = row.get('fixture')
    if mode == 'directory':
        path.mkdir()
    elif mode == 'invalid':
        path.write_bytes(b'not an audio file')
    elif mode == 'wav':
        with wave.open(str(path), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(44100)
            w.writeframes(b'\0\0' * 128)
    elif 'header' in row:
        data = struct.pack('=' + 'I' * len(row['header']), *row['header'])
        if 'raw_bytes' in row:
            data = bytes.fromhex(row['raw_bytes'])
        n = row['payload_bytes'] // 8
        # Legacy three-word payload starts with 0.0, giving a fourth word of 0.
        vals = list(row.get('payload_values', [float(i + 1) for i in range(n)]))
        if len(row['header']) == 3 and vals:
            vals[0] = 0.0
        if row.get('nan'):
            vals[0] = float('nan')
        data += struct.pack('=' + 'd' * n, *vals)
        data += b'\0' * (row['payload_bytes'] % 8 + row['observer_bytes'] + row.get('trailing_bytes', 0))
        path.write_bytes(data)
    return str(path)

def program(builtin, row, path):
    values = {s: 'a_' + s for s in SLOTS[builtin]}
    setup = '''define snapshot(value) as:
    local k is type of value
    if k == "buffer":
        return [k, shape of value, [buf_get_bits of [value, i] for i in range of len of value]]
    if k == "list":
        return [k, [snapshot of cell for cell in value]]
    if k == "num":
        return [num_type of value, f64_bits of value]
    return [k, value]
''' + row.get('setup', '') + '\n' 
    for slot in SLOTS[builtin]:
        value = values[slot]
        setup += f"{value} is {row[slot].replace('@FILE@', path)}\n"
        shape = 'shape of ' + value if row[slot+'_kind'] in ('list', 'buffer') else 'null'
        lengths = '[len of cell for cell in ' + value + ']' if row[slot+'_shape'].startswith('rows:') else 'null'
        setup += f'print of ["ARG", "{slot}", type of {value}, {shape}, {lengths}]\n'
    if builtin == 'sgd_update':
        setup += f"p is {values['params']}\ng is {values['grad']}\n"
        snapshot = 'snapshot of p'
        setup += f'print of ["BEFORE", {snapshot}]\n'
        expr = f"sgd_update of [p, g, {values['lr']}]"
    else:
        snapshot = None
        args = ', '.join(values.values())
        expr = builtin + ' of ' + ('(' + args + ')' if len(values) == 1 else '[' + args + ']')
    shown = 'null' if builtin == 'sgd_update' else 'result'
    source = setup + f'try:\n    result is {expr}\n    print of ["ANSWER", "ok", {shown}]\ncatch e:\n    print of ["ANSWER", e.kind, e.message]\n'
    if snapshot:
        source += f'print of ["AFTER", {snapshot}]\n'
    return source + 'print of "TABLE_DONE"\n'

def filesystem(work):
    return {p.relative_to(work).as_posix(): p.read_bytes()
            for p in work.rglob('*') if p.is_file() and p.name not in ('program.eigs', 'call.tape')}

@functools.lru_cache(maxsize=None)
def instrumentation(binary):
    q = subprocess.run(['bash', '-c', '. "$1"; gfx_binary_instrumentation "$2"',
                        'instrumentation', str(ROOT/'tools/gfx_address_space.sh'), str(binary)],
                       text=True, capture_output=True, check=True)
    assert q.stdout.strip() in ('asan', 'ordinary'), q
    return q.stdout.strip()

def run(binary, source, work, strict, driver='dummy', tape=None):
    env = {k: v for k, v in os.environ.items() if k not in
           ('EIGS_STRICT', 'EIGS_TRACE', 'EIGS_REPLAY', 'EIGS_REPLAY_STRICT')}
    if strict is not None:
        env['EIGS_STRICT'] = strict
    env.update(SDL_AUDIODRIVER=driver, SDL_VIDEODRIVER='dummy')
    if tape:
        env[tape] = str(work / 'call.tape')
    script = work / 'program.eigs'
    script.write_text(source)
    is_asan = instrumentation(binary) == 'asan'
    def limits():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        # ASan needs its shadow address space. Release gfx calls retain the suite cap.
        if not is_asan and sys.platform != 'darwin':
            resource.setrlimit(resource.RLIMIT_AS, (1500000 * 1024, 1500000 * 1024))
    lint = subprocess.run([str(binary), '--lint', '--json', str(script)], cwd=work, env=env,
                          text=True, capture_output=True, timeout=15, preexec_fn=limits)
    if lint.returncode not in (0, 1) or re.search(r'"severity"\s*:\s*"error"', lint.stdout):
        raise Unrun(lint.stdout+lint.stderr)
    q = subprocess.run([str(binary), str(script)], cwd=work, env=env, input='',
                       text=True, capture_output=True, timeout=15, preexec_fn=limits)
    classified = subprocess.run(['sh', '-c', '. "$1"; lsan_classify "$(cat)"; printf "%s" "$?"',
                                 'classify', str(ROOT / 'tests/lsan_classify.sh')],
                                input=lint.stdout + lint.stderr + q.stdout + q.stderr, text=True, capture_output=True, check=True)
    # Every sanitizer diagnostic fails here, including leak-only reports.
    assert classified.stdout == '2', f'sanitizer diagnostic: {lint.stderr}{q.stderr}'
    if q.returncode != 0 or q.stdout.splitlines()[-1:] != ['TABLE_DONE']:
        raise Unrun(str((q.returncode, q.stdout, q.stderr)))
    return q

@functools.lru_cache(maxsize=None)
def audio_backend(driver):
    # Probe the real libraries/device independently of the builtin under test.
    code = r'''
import ctypes, json, sys

def load(names):
    for name in names:
        try: return ctypes.CDLL(name)
        except OSError: pass
    raise OSError("SDL library unavailable")
try:
    sdl = load(["libSDL2-2.0.so.0", "libSDL2.so"])
    mix = load(["libSDL2_mixer-2.0.so.0", "libSDL2_mixer.so"])
    for lib, names in zip((sdl, mix), json.loads(sys.argv[1])):
        examined = 0
        for name in names:
            getattr(lib, name)
            examined += 1
        assert examined == len(names) > 0
    sdl.SDL_Init(0x10)
    mix.Mix_Init(0x8)
    mix.Mix_OpenAudioDevice.argtypes = [ctypes.c_int,ctypes.c_uint16,ctypes.c_int,ctypes.c_int,ctypes.c_char_p,ctypes.c_int]
    ready = mix.Mix_OpenAudioDevice(44100,0x8010,2,2048,None,0) >= 0
    if ready: mix.Mix_CloseAudio()
    mix.Mix_Quit()
    sdl.SDL_QuitSubSystem(0x10)
except (OSError, AttributeError):
    ready = False
print("ready" if ready else "unavailable")
'''
    source = (ROOT/'src/ext_gfx.c').read_text()
    symbols = [re.findall(r'\bLOAD\((SDL_\w+)\)', source), re.findall(r'\bMLOAD\((Mix_\w+)\)', source)]
    env = dict(os.environ, SDL_AUDIODRIVER=driver)
    def cap():
        if sys.platform != 'darwin':
            resource.setrlimit(resource.RLIMIT_AS, (1500000*1024,1500000*1024))
    q = subprocess.run([sys.executable, '-c', code, json.dumps(symbols)], env=env, text=True,
                       capture_output=True, timeout=15, preexec_fn=cap)
    if q.returncode or q.stdout.strip() not in ('ready', 'unavailable'):
        raise Unrun('independent SDL probe failed: '+q.stdout+q.stderr)
    return q.stdout.strip() == 'ready'

def check_row(binary, builtin, row, state_index, work):
    row = answer_arms(row)[-1] if row.get('device_unavailable') and not audio_backend(row.get('driver', 'dummy')) else row
    path = fixture(row, work)
    source = program(builtin, row, path)
    before_files = filesystem(work)
    q = run(binary, source, work, STATES[state_index], row.get('driver', 'dummy'),
            'EIGS_TRACE' if row.get('tape') else None)
    kinds = {'str': 'string', 'num': 'number'}
    actual = [json.loads(x) for x in q.stdout.splitlines() if x.startswith('["ARG",')]
    assert len(actual) == len(SLOTS[builtin]) > 0, q.stdout
    for _, slot, kind, shape, lengths in actual:
        assert kinds.get(kind, kind) == row[slot+'_kind'], f'{slot}: actual {kind}, declared {row[slot+"_kind"]}'
        declared = row[slot+'_shape']
        if declared.startswith(('flat:', 'unshaped:')):
            assert shape == [int(re.search(r':(\d+)', declared)[1])], (declared, shape)
        elif row[slot+'_kind'] == 'buffer':
            assert shape == [int(x) for x in declared.split('x')], (declared, shape)
        elif declared.startswith('rows:'):
            spec = declared[5:]
            if 'x' in spec:
                r,c = map(int, spec.split('x'))
                expected_lengths = [c]*r
            else:
                r,cs = spec.split('[',1)
                expected_lengths = json.loads('['+cs)
                assert len(expected_lengths) == int(r)
            assert lengths == expected_lengths, (declared, lengths)
            assert shape == [len(expected_lengths), expected_lengths[0] if expected_lengths else 0], (declared, shape)
    answers = [json.loads(x) for x in q.stdout.splitlines() if x.startswith('["ANSWER",')]
    assert len(answers) == 1, q.stdout
    _, kind, detail = answers[0]
    answer = row['errors'].get(first_check(row, state_index), {'kind': 'ok', 'message': ''})
    expected, message = (per_state(answer[c], state_index) for c in ('kind', 'message'))
    assert kind == expected, f'kind {kind}, want {expected}; {detail}'
    assert expected == per_state(row['expected_kind'], state_index), 'order and expected_kind disagree'
    message = message.replace('@FILE@', path)
    if kind != 'ok':
        matched = message_matches(answer.get('match', 'exact'), detail, message)
        assert matched, f'message {detail!r}, want {answer.get("match", "exact")} {message!r}'
    if 'result' in row:
        assert detail == row['result'], (detail, row['result'])
    written = filesystem(work) != before_files
    if builtin == 'sgd_update':
        lines = q.stdout.splitlines()
        a = next(x.removeprefix('["BEFORE", ') for x in lines if x.startswith('["BEFORE",'))
        b = next(x.removeprefix('["AFTER", ') for x in lines if x.startswith('["AFTER",'))
        written |= a != b
    assert written == per_state(row['written'], state_index), f'writes={written}'
    if builtin == 'audio_music_play' and kind != 'ok':
        assert 'audio_music:' not in q.stderr, q.stderr
    if row.get('tape'):
        tape = (work / 'call.tape').read_text()
        assert len(re.findall(r'^N \d+ tensor_load=', tape, re.M)) == 1, tape
        # Only existing input removal proves replay did not consult that input.
        p = Path(path)
        removed = p.exists()
        if p.is_file():
            p.unlink()
        elif p.is_dir():
            p.rmdir()
        assert not p.exists(), f'{p}: input still present before replay'
        rep = run(binary, source, work, STATES[state_index], tape='EIGS_REPLAY')
        assert (q.stdout, q.stderr) == (rep.stdout, rep.stderr), (q.stdout, rep.stdout, q.stderr, rep.stderr)
    return (1, int(removed)) if row.get('tape') else (0, 0)

def message_matches(mode, detail, message):
    if mode == 'reason':
        return detail.startswith(message) and detail[len(message):].strip() != ''
    return detail.startswith(message) if mode == 'prefix' else detail == message

def execute(tables, binary, quiet=False):
    failures = []
    tape_replays = tape_pairs = 0
    with tempfile.TemporaryDirectory(prefix='builtin-error-table-') as scratch:
        root = Path(scratch)
        for builtin, rows in tables.items():
            ran = 0
            start = len(failures)
            for i, row in enumerate(rows):
                completed = 0
                line_ran = True
                for s, state in enumerate(STATES):
                    work = root / f'{builtin}-{i}-{s}'
                    work.mkdir()
                    try:
                        replayed, removed = check_row(binary, builtin, row, s, work)
                        tape_replays += replayed
                        tape_pairs += removed
                    except (Unrun, subprocess.SubprocessError, OSError) as e:
                        line_ran = False
                        failures.append((builtin, row['id'], state, str(e)))
                        if not quiet:
                            print(f"UNRUN: {builtin}/{row['id']} strict={state or 'unset'}: {e}")
                    except (AssertionError, ValueError) as e:
                        failures.append((builtin, row['id'], state, str(e)))
                        if not quiet:
                            print(f"FAIL: {builtin}/{row['id']} strict={state or 'unset'}: {e}")
                    completed += 1
                assert completed == len(STATES) > 0
                ran += int(line_ran)
            assert ran == len(rows) > 0, f'{builtin}: did not run population'
            if not quiet:
                print(f'builtin-error-table: {builtin} {ran} lines x 3 states, {len(failures)-start} failed')
                modes = collections.Counter(a.get('match', 'exact') for r in rows for arm in (r, r.get('device_unavailable', {})) for a in arm.get('errors', {}).values())
                print(f'message checks: {builtin} exact {modes["exact"]}, prefix {modes["prefix"]}, reason {modes["reason"]}')
    if not quiet:
        print(f'tape replays: {tape_replays}; tape pairs: {tape_pairs} (input removed)')
    if not quiet and any(r.get('tape') and r.get('fixture') != 'missing' for r in tables.get('tensor_load', [])):
        assert tape_pairs > 0, 'tape rows ran with no input removed before replay'
    return failures

def describe(builtin, row):
    text = ', '.join(f"{s} {row[s+'_kind']} ({row[s+'_shape']}; `{row[s]}`)" for s in SLOTS[builtin])
    if 'header' in row:
        text += f"; header {row['header']}, payload {row['payload_bytes']} bytes, observer {row['observer_bytes']} bytes"
    if 'payload_values' in row:
        text += '; payload values '+json.dumps(row['payload_values'])
    if row.get('setup'):
        text += '; setup `'+row['setup']+'`'
    if row.get('raw_bytes'):
        text += '; raw bytes '+row['raw_bytes']
    if row.get('fixture'):
        text += '; ' + row['fixture']
    if row.get('driver'):
        text += '; SDL driver ' + row['driver']
    if row.get('nan'):
        text += '; NaN payload'
    if 'trailing_bytes' in row:
        text += f"; {row['trailing_bytes']} trailing bytes"
    return text.replace('|', '&#124;')

def listing(builtin, rows):
    # Group identical outcomes; enumerate every concrete input.
    groups = collections.OrderedDict()
    for r in rows:
        answer = tuple(json.dumps(r.get(k)) for k in ('expected_kind', 'written', 'device_unavailable', 'result'))
        answer += ('result' in r, r.get('driver', 'dummy'))
        groups.setdefault(answer, []).append(r)
    items = []
    for rs in groups.values():
        r = rs[0]
        arms = [(r, '')] if not r.get('device_unavailable') else [
            (r, ' with usable '+r.get('driver', 'dummy')+' audio backend'),
            (dict(r, **r['device_unavailable']), ' when unavailable')]
        verdicts = []
        for arm, context in arms:
            kind = arm['expected_kind']
            shown = '/'.join(kind) + ' (unset/0/1)' if isinstance(kind, list) else kind
            result = '; result '+json.dumps(arm['result']) if 'result' in arm else ''
            verdicts.append(f'`{shown}`{result}; writes `{json.dumps(arm["written"])}`{context}')
        specs = '\n'.join(f"- `{x['id']}`: {describe(builtin, x)}." for x in rs)
        items.append('### ' + '; '.join(verdicts) + '\n\n' + specs)
    return f'<a id="{builtin}"></a>\n\n## `{builtin}`\n\n' + '\n\n'.join(items)

def generated(builtin, rows):
    answers = collections.defaultdict(dict)
    for r in rows:
        for arm in answer_arms(r):
            for s in range(len(STATES)):
                kind, wrote = per_state(arm['expected_kind'], s), per_state(arm['written'], s)
                answers[kind][r['id']] = answers[kind].get(r['id'], False) or wrote
    groups = []
    for wrote in (False, True):
        counts = [f'`{k}` {len(lines)}' for k, lines in sorted(answers.items()) if any(lines.values()) == wrote]
        if counts:
            groups.append(', '.join(counts) + (', some wrote' if wrote else ', nothing written'))
    summary = f'Lines ({len(rows)} total, {len(STATES)} states): ' + '; '.join(groups)
    return f'<!-- error-table:{builtin} --><a id="errors-{builtin}"></a>{summary}. [Every line](builtin-errors.md#{builtin}).<!-- /error-table -->'

def docs(tables, write, path=None):
    path = path or ROOT / 'docs/BUILTINS.md'
    page = path.with_name('builtin-errors.md')
    full = ('# Builtin error tables\n\nGenerated from `tests/builtin_errors/` by '
            '`tools/builtin_error_table.py --write`. Do not edit.\n\n'
            'Counts in [BUILTINS.md](BUILTINS.md) count each table line once per answer kind '
            'across its strictness states and backend alternatives.\n\n')
    text = path.read_text()
    for builtin, rows in tables.items():
        pattern = r'<!-- error-table:' + builtin + r' -->.*?<!-- /error-table -->'
        block = generated(builtin, rows)
        assert len(re.findall(pattern, text, re.S)) == 1, f'{builtin}: missing/duplicate generated block'
        updated = re.sub(pattern, lambda m: block, text, flags=re.S)
        row = next(l for l in (updated if write else text).splitlines() if l.startswith('| `'+builtin+'` |'))
        assert len(row) < 400, f'{builtin}: row length {len(row)} must be under 400 characters'
        if not write:
            assert updated == text, f'{builtin}: generated block differs; run --write'
        text = updated
        full += listing(builtin, rows) + '\n\n'
        row = re.sub(pattern, '', row, flags=re.S)
        assert row.count(' | ') == 2, f'{builtin}: malformed Markdown row'
        assert not re.search(r'\b(raises?|errors?|refuses?|fail(?:ure|s|ed)?)\b', row), f'{builtin}: handwritten error sentence'
    if write:
        path.write_text(text)
        page.write_text(full)
    else:
        assert page.read_text() == full, 'generated page differs; run --write'
    print('builtin-error-table: generated blocks and page ' + ('written' if write else 'match'))

def selftest(tables, binary):
    cli = [sys.executable, str(Path(__file__).resolve()), '--binary', str(binary)]
    control = subprocess.run(cli, text=True, capture_output=True, timeout=120)
    assert control.returncode == 0 and len(re.findall(r'^builtin-error-table: .* 0 failed$', control.stdout, re.M)) == len(SLOTS), control.stdout+control.stderr
    print('PASS: table selftest control green')
    unavailable = copy.deepcopy([r for r in tables['audio_music_play'] if r.get('device_unavailable')])
    assert len(unavailable) == 2
    for row in unavailable:
        row['driver'] = 'not-an-sdl-driver'
    assert not audio_backend('not-an-sdl-driver')
    assert not execute({'audio_music_play': unavailable}, binary, quiet=True), 'unavailable expectations failed'
    print('PASS: table selftest unavailable device expectations green: decode/valid, 6 state runs')
    variants = json.loads((TABLES/'populations.json').read_text())['selftest_variants']
    for examined, (name, builtin, line, edit, expected_rc) in enumerate(variants, 1):
        variant = copy.deepcopy(tables)
        victim = next(r for r in variant[builtin] if r['id'] == line)
        if not edit:
            variant[builtin].remove(victim)
        elif edit[0] == 'short-header':
            victim.pop('fixture', None)
            victim.update(header=[], payload_bytes=0, observer_bytes=0, raw_bytes='78')
        elif edit[0] in ('message', 'exact', 'prefix', 'reason'):
            answer = victim['errors'][first_check(victim, 0)]
            answer['message'] = edit[1]
            if edit[0] != 'message': answer['match'] = edit[0]
            if len(edit) == 3: answer['why'] = edit[2]
            elif edit[0] != 'message': answer.pop('why', None)
        elif edit[0] == 'order':
            a,b = (victim['order'].index(c) for c in edit[1:])
            victim['order'][a], victim['order'][b] = victim['order'][b], victim['order'][a]
        elif len(edit) == 1:
            del victim[edit[0]]
        else:
            victim[edit[0]] = edit[1]
        with tempfile.TemporaryDirectory(prefix='builtin-error-variant-') as tmp:
            p = Path(tmp)
            for name_b, rows in variant.items():
                (p / (name_b + '.jsonl')).write_text(''.join(json.dumps(r)+'\n' for r in rows))
            q = subprocess.run(cli+['--table-dir', str(p)], text=True, capture_output=True, timeout=120)
            rc = q.returncode
            output = q.stdout+q.stderr
            if expected_rc == 2:
                assert 'population' in output, output
                assert builtin in output, output
            else:
                assert line in output, output
            if name == 'same-kind order swapped' or name.startswith(('P', 'shape fragment', 'finite fragment')):
                if expected_rc == 1 and (builtin != 'audio_music_play' or audio_backend('dummy')): assert 'message ' in output and re.search(r'want (exact|reason) ', output), output
            assert rc == expected_rc, (name, rc)
        print(f'PASS: table selftest {name}: red rc={rc}, line={line}')
    assert examined == len(variants) > 0
    prefix = copy.deepcopy(next(r for r in tables['tensor_load'] if r['id'] == 'missing'))
    prefix['errors']['open'].update(match='prefix', message="tensor_load: '@FILE@': No such file", why='libc supplies the strerror suffix')
    assert not execute({'tensor_load': [prefix]}, binary, quiet=True)
    print('PASS: table selftest explicit prefix with why green')
    head = "audio_music_play: '/x.mod': cannot decode: "
    for detail, want in ((head + 'ModPlug_Load failed', True), (head + 'XMP: Unrecognized file format', True),
                         (head, False), (head + ' \t', False), ("audio_music_play: '/y.mod': cannot decode: ModPlug_Load failed", False),
                         ("audio_music_play: '/x.mod': No such file or directory", False)):
        assert message_matches('reason', detail, head) is want, (detail, want)
    print('PASS: table selftest reason match: any nonempty library reason after our fixed text, 6 cases')
    with tempfile.TemporaryDirectory(prefix='builtin-error-docs-') as tmp:
        doc = Path(tmp)/'BUILTINS.md'
        page = doc.with_name('builtin-errors.md')
        original = (ROOT/'docs/BUILTINS.md').read_text()
        full = (ROOT/'docs/builtin-errors.md').read_text()
        assert all(f'id="errors-{b}"' in original for b in tables), 'missing front-door anchor'
        doc.write_text(original)
        page.write_text(full)
        docs(tables, False, doc)
        marker = '<!-- error-table:tensor_load -->'
        plants = [('row drift', doc, original.replace(marker, marker+'drift', 1), 'tensor_load: generated block differs'),
                  ('page drift', page, full.replace('`path-bool`', '`changed`', 1), 'generated page differs'),
                  ('row length', doc, original.replace(marker, marker+'x'*400, 1), 'tensor_load: row length')]
        for examined_docs, (name, target, bad, diagnostic) in enumerate(plants, 1):
            assert bad != (original if target == doc else full), name
            target.write_text(bad)
            q = subprocess.run(cli+['--check', '--docs-file', str(doc)], text=True, capture_output=True, timeout=15)
            assert q.returncode == 2 and diagnostic in q.stderr, q.stdout+q.stderr
            target.write_text(original if target == doc else full)
            print(f'PASS: table selftest documentation {name}: red, tensor_load')
        assert examined_docs == len(plants) > 0
    arm_plants = [('expected_kind', 'value'), ('result', True), ('written', True)]
    for field, value in arm_plants:
        wrong = copy.deepcopy(tables)
        next(r for r in wrong['audio_music_play'] if r['id'] == 'decode')['device_unavailable'][field] = value
        with tempfile.TemporaryDirectory(prefix='builtin-error-arm-') as tmp:
            for builtin, rows in wrong.items():
                (Path(tmp)/(builtin+'.jsonl')).write_text(''.join(json.dumps(r)+'\n' for r in rows))
            q = subprocess.run(cli+['--table-dir', tmp, '--check'], text=True, capture_output=True, timeout=15)
            assert q.returncode == 2 and re.search(r'generated (block|page) differs', q.stderr), q.stdout+q.stderr
        print(f'PASS: table selftest unavailable {field} edit: red, line=decode')
    assert len(arm_plants) == 3
    print(f'builtin-error-table selftest: control green, {examined} variants red, docs row/page drift and row length red')

def c_mutants(tables, binary, scratch_root):
    current = (ROOT / 'src/builtins_tensor.c').read_text()
    changes = []
    a = current.index('    /* R1 (#2533):')
    b = current.index('\n    if (ndim_raw !=', a)
    legacy = '''    int has_observer = 0;
    if (flags <= 1) has_observer = (flags & 1);
    else { fseek(f, 0, SEEK_SET); uint32_t old_header[3];
        if (fread(old_header, sizeof(uint32_t), 3, f) != 3) { fclose(f); return file_recorded_error(EK_IO, "tensor_load", arg->data.str, "short legacy three-word header"); }
        ndim_raw = old_header[0]; rows_raw = old_header[1]; cols_raw = old_header[2]; }'''
    changes.append(('R1', current[:a]+legacy+current[b:], 'flags-seven'))
    a = current.index('    /* R2 (#2534):')
    b = current.index('    uint64_t total64', a)
    changes.append(('R2', current[:a]+current[b:], 'rows-five'))
    a = current.index('    /* R3 (#2529):')
    b = current.index('\n    fclose(f);', a)
    old_reader = '''    double *obs_data = NULL;
    if (has_observer) { obs_data = xmalloc_array(safe_size_mul((size_t)total, 5), sizeof(double));
        if (obs_data && (int)fread(obs_data, sizeof(double), total * 5, f) != total * 5) { free(obs_data); obs_data = NULL; } }'''
    old_restore = '    if (obs_data && result) { if (ndim == 1) restore_observer_1d(result, obs_data, total); else restore_observer_2d(result, obs_data, rows, cols); free(obs_data); }\n'
    noop = """static void restore_observer_1d(Value *v, double *d, int n) { (void)v; (void)d; (void)n; }
static void restore_observer_2d(Value *v, double *d, int r, int c) { (void)v; (void)d; (void)r; (void)c; }"""
    reverted = current[:a]+old_reader+current[b:]
    reverted = reverted.replace('        val_decref(result); tensor_load_record_verdict(0, 0);',
                                '        free(obs_data); val_decref(result); tensor_load_record_verdict(0, 0);')
    at = reverted.rindex('    tensor_load_record_verdict(0, 0);')
    reverted = reverted[:at]+old_restore+reverted[at:]
    reverted = reverted.replace('/* ==== BUILTIN: tensor_load ==== */', noop+'/* ==== BUILTIN: tensor_load ==== */')
    changes.append(('R3', reverted, 'observer-short'))
    a = current.index('} else if ((param->data.buffer.rows > 0)')
    b = current.index('\n        char ps[64]', a)
    changes.append(('R4', current[:a]+'} else if (param->data.buffer.count != grad->data.buffer.count) {'+current[b:],
                    'unshaped2-shaped12-lr-number'))
    assert len(changes) == 4 and all(text != current for _,text,_ in changes)
    tracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z']).decode().split('\0')
    extra = [str(p.relative_to(ROOT)) for p in TABLES.glob('*')]
    extra += ['tools/builtin_error_table.py']
    files = sorted(set(f for f in tracked+extra if f and f not in ('src/eigenscript','src/eigenlsp','src/eigsdap') and (ROOT/f).is_file()))
    for examined, (ruling, text, line) in enumerate(changes, 1):
        with tempfile.TemporaryDirectory(prefix='scratch-'+ruling+'-', dir=scratch_root) as tmp:
            tree = Path(tmp)
            copied = 0
            for f in files:
                dest = tree/f
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT/f, dest)
                copied += 1
            assert copied == len(files) > 0
            # Reuse unchanged object files, never an executable. A fresh link and
            # a recompile of the mutated translation unit are required below.
            objdir = tree/'build/release'
            objdir.mkdir(parents=True)
            objects = list((ROOT/'build/release').glob('*.o')) + list((ROOT/'build/release').glob('*.d'))
            assert objects
            for obj in objects:
                shutil.copy2(obj, objdir/obj.name)
            (tree/'src/builtins_tensor.c').write_text(text)
            q = subprocess.run(['make', '-C', str(tree), 'build'], text=True, capture_output=True, timeout=180)
            assert q.returncode == 0, (ruling, q.stdout, q.stderr)
            assert 'builtins_tensor.c' in q.stdout, 'mutated translation unit was not compiled'
            failures = execute(tables, tree/'build/release/eigenscript', quiet=True)
            assert any(f[1] == line for f in failures), (ruling, line, failures)
            reason = next(f[3] for f in failures if f[1] == line)
            print(f'PASS: C mutant {ruling}: red, line={line}, failed states={len(failures)}; {reason}', flush=True)
    assert examined == len(changes) > 0
    print(f'builtin-error-table mutants: {examined} rulings red')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--table-dir', type=Path, default=TABLES)
    parser.add_argument('--docs-file', type=Path)
    for flag in ('check', 'write', 'selftest', 'c-mutants'):
        parser.add_argument('--'+flag, action='store_true')
    parser.add_argument('--scratch-root', type=Path)
    args = parser.parse_args()
    try:
        if args.binary is None and not (args.check or args.write):
            # ./build.sh (the hosted self-test job's build) makes only src/eigenscript;
            # the C mutants also reuse build/release's objects. Build them as
            # tools/ui_surface_check.sh does, every time.
            # Always: a stale build/release would answer for another commit's source.
            args.binary = ROOT/'build/release/eigenscript'
            print('builtin-error-table: make build (no --binary)', flush=True)
            subprocess.run(['make', '--no-print-directory', '-C', str(ROOT), 'build'],
                           check=True, stdout=subprocess.DEVNULL)
        if args.binary is not None:
            assert args.binary.is_file(), f'no binary at {args.binary}'
        tables = read_tables(args.table_dir)
        if args.check or args.write:
            docs(tables, args.write, args.docs_file)
        elif args.selftest:
            selftest(tables, args.binary.resolve())
            if args.c_mutants:
                c_mutants(tables, args.binary.resolve(), args.scratch_root)
        else:
            return int(bool(execute(tables, args.binary.resolve())))
    except (AssertionError, KeyError, ValueError, OSError, subprocess.SubprocessError) as e:
        print(f'builtin-error-table: refused population: {e}', file=sys.stderr)
        return 2
    return 0

if __name__ == '__main__':
    sys.exit(main())
