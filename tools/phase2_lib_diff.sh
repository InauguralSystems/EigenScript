#!/usr/bin/env bash
# The stdlib's int differential (#1848, #1758 Phase 2): every exported function
# of every tracked lib/*.eigs module, called with INT arguments on origin/main
# and on the branch. Both binaries run the SAME lib source (a copy of this
# tree's lib/ under a scratch project root), so only the runtime differs.
#   bash tools/phase2_lib_diff.sh <main-bin> <branch-bin>
# The stated range: every int n in [-3, 110]; arity 1 calls f(n), arity k >= 2
# calls the diagonal f(n, ..., n) and, per position, n there with 1 elsewhere.
# A `define f as:` takes the implicit parameter n (arity 1); arity 0 is not
# called. The population is the module's import namespace (its `fn` keys),
# checked against the module's column-0 `define` lines in both directions.
# A call LISTED is one main completes and the branch raises or never reaches.
# Each listed function must be an integer-domain function declared in
# tests/phase2/lib_int_domain.txt (decision (A): int overflow raises), and each
# declaration must be listed (a stale one fails). Every other listing fails.
# N4 also compares successful JSON values (numeric kinds compare equal) for
# the source-derived closure of modulo users. Negative-boundary and evaluator
# probes reach paths the uniform int sweep cannot. Changes require an N4 reason
# in lib_floor_mod.txt; unused declarations fail. The final summary keeps the
# original contract consumed by phase2_ci.sh and includes both kinds of change.
set -eu
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

RANGE = list(range(-3, 111))
TIMEOUT = 120
root = Path.cwd()
ap = argparse.ArgumentParser(prog='tools/phase2_lib_diff.sh')
ap.add_argument('main')
ap.add_argument('branch')
args = ap.parse_args()


def fail(msg):
    print('phase2-lib-diff: FAIL: ' + msg, flush=True)
    sys.exit(1)


bins = {}
for arm in ('main', 'branch'):
    p = Path(getattr(args, arm))
    if not p.is_file() or not os.access(p, os.X_OK):
        fail('not an executable: %s' % p)
    bins[arm] = str(p.resolve())
def declarations(name, rule=None):
    rows = {}
    for n, line in enumerate((root / 'tests/phase2' / name).read_text().splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        f = line.split('\t')
        if len(f) != 2 or not re.fullmatch(r'\w+\.\w+', f[0]) or not f[1].strip() or f[0] in rows:
            fail('%s:%d: want one "module.function<TAB>reason" row per function' % (name, n))
        if rule and not f[1].startswith(rule + ': '):
            fail('%s:%d: reason must name %s' % (name, n, rule))
        rows[f[0]] = f[1].strip()
    return rows


declared = declarations('lib_int_domain.txt')
floor_declared = declarations('lib_floor_mod.txt', 'N4')
mods = sorted(m for m in subprocess.check_output(['git', 'ls-files', '-z', 'lib/*.eigs'],
                                                 cwd=root).decode().split('\0')
              if re.fullmatch(r'lib/[a-z_0-9]+\.eigs', m))
if not mods:
    fail('no tracked lib/*.eigs modules')
work = Path(tempfile.mkdtemp(prefix='phase2-libdiff-'))
(work / 'lib').mkdir()
for m in mods:
    shutil.copy(root / m, work / m)
(work / 'eigs.json').write_text('{}\n')
env = {k: v for k, v in os.environ.items()
       if not k.startswith('EIGS_') and k not in ('DISPLAY', 'XAUTHORITY', 'WAYLAND_DISPLAY')}
env.update(SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')


def run(arm, name, text):
    """Run one probe in its own session and cwd; a timeout kills the group."""
    prog = work / (name + '.eigs')
    prog.write_text(text)
    cwd = work / ('cwd-' + arm)
    cwd.mkdir(exist_ok=True)
    proc = subprocess.Popen([bins[arm], str(prog)], cwd=cwd, env=dict(env, HOME=str(cwd)),
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=TIMEOUT)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, _ = proc.communicate()
        rc = 124
    return rc, out.decode(errors='replace').splitlines()


def tuples(arity):
    rows = [(n,) * arity for n in RANGE]
    if arity >= 2:
        rows += [tuple(n if i == j else 1 for i in range(arity)) for j in range(arity) for n in RANGE]
    return sorted(dict.fromkeys(rows), key=lambda t: (max(abs(x) for x in t), t))


def same_value(a, b):
    # Ignore only the intended numeric-kind distinction, recursively. Python's
    # plain equality would also treat true as 1 and hide a semantic change.
    if type(a) in (int, float) and type(b) in (int, float):
        return a == b
    if type(a) is not type(b):
        return False
    if isinstance(a, list):
        return len(a) == len(b) and all(same_value(x, y) for x, y in zip(a, b))
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same_value(a[k], b[k]) for k in a)
    return a == b


def call_text(mod, fn, t):
    if isinstance(t, dict):
        return 'r is ' + t['call']
    a = t if isinstance(t, str) else (str(t[0]) if len(t) == 1 else '[%s]' % ', '.join(map(str, t)))
    return 'r is %s.%s of %s' % (mod, fn, a)


define_re = re.compile(r'^define ([A-Za-z_]\w*)(?:\(([^)]*)\))? as:', re.M)
own = {m: {name: 1 if params is None else len([p for p in params.split(',') if p.strip()])
           for name, params in define_re.findall((root / m).read_text()) if not name.startswith('_')}
       for m in mods}
# A conservative named-reference closure: include private helpers and callbacks,
# not only `f of` calls. Ordinary strings and comments cannot seed a modulo user;
# f-string contents remain visible so an interpolated `%` cannot be missed.
# Over-approximation can add comparisons but never waive a changed result.
def code_only(source):
    pattern = r'#[^\n]*|(?:f)?"(?:\\.|[^"\\])*"|(?:f)?\'(?:\\.|[^\'\\])*\''
    def mask(match):
        text = match[0]
        return text if text.startswith(('f"', "f'")) else re.sub(r'[^\n]', ' ', text)
    return re.sub(pattern, mask, source)


bodies = {}
for m in mods:
    source = code_only((root / m).read_text())
    definitions = list(define_re.finditer(source))
    for match in definitions:
        end = match.end()
        # A function ends at the next nonblank, nonindented source line.
        for line in source[end:].splitlines(keepends=True):
            if line.strip() and not line[0].isspace():
                break
            end += len(line)
        bodies[(m, match[1])] = source[match.start():end]
by_name = {}
for key in bodies:
    by_name.setdefault(key[1], set()).add(key)
refs = {key: set().union(*(by_name.get(name, set()) for name in re.findall(r'\b[A-Za-z_]\w*\b', body))) - {key}
        for key, body in bodies.items()}
floor_scope = {key for key, body in bodies.items() if '%' in body}
while True:
    widened = floor_scope | {key for key in bodies if refs[key] & floor_scope}
    if widened == floor_scope:
        break
    floor_scope = widened
if not floor_scope:
    fail('no modulo function found in tracked stdlib sources')
# These are public API input shapes, not exemptions. They exercise the two
# meta-interpreter entries whose numeric int arguments cannot reach a binop.
floor_inputs = {
    ('lib/checksum.eigs', 'adler32'): ['buf_from_list of ([-7.0, 2.0])'],
    ('lib/checksum.eigs', 'sum8'): ['buf_from_list of ([-7.0, 2.0])'],
    ('lib/supervise.eigs', 'supervise_step'): [{'call': '_phase2_negative_step of []'}],
    ('lib/supervise.eigs', 'supervise_run'): [{'call': '_phase2_negative_run of []'}],
    ('lib/eigen.eigs', 'eigen_eval'): ['[["binop", "%", ["num", -7], ["num", 3]], {}]',
                                      '[["binop", "%", ["num", 7], ["num", -3]], {}]',
                                      '[["binop", "%", ["num", -7.5], ["num", 2]], {}]',
                                      '[["binop", "%", ["num", 7.5], ["num", -2]], {}]'],
    ('lib/eigen.eigs', 'eigen_run'): ['"return -7 % 3"', '"return 7 % -3"',
                                    '"return -7.5 % 2"', '"return 7.5 % -2"'],
}
# A negative heartbeat changes an observer feed even when this tick's returned
# restart count is still zero. Observe the feed and the public result together;
# one cooperative task is alive for the tick and explicitly killed afterwards.
floor_prelude = {}
for fn, call in (('supervise_step', 'supervise_step of sup'),
                 ('supervise_run', 'supervise_run of [sup, 1]')):
    suffix = 'step' if fn == 'supervise_step' else 'run'
    floor_prelude[('lib/supervise.eigs', fn)] = (
        'load_file of "lib/supervise.eigs"\n'
        'define _phase2_worker(slot) as:\n'
        '    task_yield of null\n'
        '    return null\n'
        'define _phase2_negative_%s() as:\n'
        '    local sup is supervisor_new of 0\n'
        '    local child is supervise of [sup, _phase2_worker, 0]\n'
        '    heartbeat of [0, -7]\n'
        '    local result is %s\n'
        '    task_kill of child.id\n'
        '    return [result, _sup_o0]\n' % (suffix, call))
for key in floor_inputs:
    if key not in floor_scope or key[1] not in own.get(key[0], {}):
        fail('N4 API probe no longer belongs to an exported modulo user: %s.%s' % key)
defined_anywhere = set().union(*own.values())
# The one module that is not a library: importing it runs a command line.
NOT_LIBRARY = {'lib/pkg.eigs': 'the `eigenscript --pkg` command; importing it runs the CLI'}
# Pass 1: each module's import namespace (its `fn` keys), on both binaries.
ns, unimportable = {}, {}
for m in mods:
    mod = Path(m).stem
    keys, rcs = {}, {}
    for arm in bins:
        rcs[arm], out = run(arm, 'keys_' + mod, 'import %s\nfor k in keys of %s:\n    if (type of %s[k]) == "fn":\n'
                            '        print of f"K {k}"\nprint of "KEYS-DONE"\n' % (mod, mod, mod))
        keys[arm] = {line[2:] for line in out if line.startswith('K ')} if 'KEYS-DONE' in out else None
    if keys['main'] is None and keys['branch'] is None:
        unimportable[m] = rcs
        continue
    if keys['main'] != keys['branch'] or not set(own[m]) <= keys['branch'] \
            or not keys['branch'] <= defined_anywhere:
        fail('%s: namespaces disagree (rc main=%d branch=%d): main-only=%s branch-only=%s undefined=%s '
             'not-exported=%s' % (m, rcs['main'], rcs['branch'], sorted((keys['main'] or set()) - (keys['branch'] or set())),
                                  sorted((keys['branch'] or set()) - (keys['main'] or set())),
                                  sorted((keys['branch'] or set()) - defined_anywhere),
                                  sorted(set(own[m]) - (keys['branch'] or set()))))
    ns[m] = keys['branch']
# Pass 2: each defined function is examined once, through its own module or,
# when that cannot be imported alone (ui.eigs loads its ui_w_* fragments),
# through a module whose namespace re-exports it.
plan, skipped = [], {}
for m in mods:
    for fn, arity in sorted(own[m].items()):
        via = m if m in ns else next((x for x in mods if x in ns and fn in ns[x] and fn not in own[x]), None)
        if via is None:
            skipped.setdefault(m, []).append(fn)
        else:
            plan.append((m, via, fn, arity))
if set(skipped) != set(NOT_LIBRARY) or not set(NOT_LIBRARY) <= set(unimportable):
    fail('unexamined modules %s != the declared non-library modules %s' % (sorted(skipped), sorted(NOT_LIBRARY)))
counts = dict(modules=len(mods), importable=len(ns), functions=len(plan),
              via_reexport=sum(via not in own or fn not in own[via] for _, via, fn, _ in plan),
              no_params=0, calls=0, examined=0, unexamined=0, both_ok=0, both_raise=0, improved=0)
listed, unexamined, floor_changed = {}, {}, {}
floor_functions, floor_calls, floor_both_ok = 0, 0, 0
for source, via, fn, arity in plan:
    mod = Path(via).stem
    if arity == 0:
        counts['no_params'] += 1
        continue
    calls = tuples(arity)
    compare_value = (source, fn) in floor_scope
    if compare_value:
        floor_functions += 1
        # -7 reaches weekday_from_days; -719469 crosses civil_from_days'
        # epoch offset and exposes its private _fdiv's negative dividend.
        for n in (-7, -719469):
            calls += [(n,) * arity]
            calls += [tuple(n if i == j else 1 for i in range(arity)) for j in range(arity)]
        calls = list(dict.fromkeys(calls)) + floor_inputs.get((source, fn), [])
    value_line = '    print of f"V %d {json_encode of r}"\n' if compare_value else ''
    # load_file exposes private observer state in the targeted supervision
    # probe and also defines a function named supervise. Preserve the import
    # namespace before that definition so the original int sweep is unchanged.
    prelude = floor_prelude.get((source, fn), '')
    call_mod = '_phase2_libdiff_module' if prelude else mod
    header = 'import %s\n' % mod
    if prelude:
        header += '_phase2_libdiff_module is %s\n' % mod
    text = header + prelude + ''.join(
        ('try:\n    %s\n    print of f"R %d OK {type of r}"\n' % (call_text(call_mod, fn, t), i))
        + (value_line % i if compare_value else '')
        + ('catch e:\n    print of f"R %d RAISE {e}"\n' % i) for i, t in enumerate(calls))
    res = {}
    for arm in bins:
        rc, out = run(arm, 'call_%s_%s' % (mod, fn), text)
        got, values = {}, {}
        for line in out:
            r = re.match(r'R (\d+) (OK|RAISE) ?(.*)$', line)
            if r and int(r[1]) < len(calls) and int(r[1]) not in got:
                got[int(r[1])] = (r[2], r[3])
            v = re.match(r'V (\d+) (.*)$', line)
            if v and int(v[1]) < len(calls):
                if int(v[1]) in values:
                    fail('duplicate N4 value from %s %s.%s call %s' % (arm, mod, fn, v[1]))
                try:
                    values[int(v[1])] = json.loads(v[2])
                except ValueError:
                    fail('non-JSON N4 value from %s %s.%s: %s' % (arm, mod, fn, line))
        res[arm] = (rc, got, values)
    counts['calls'] += len(calls)
    if compare_value:
        floor_calls += len(calls)
    for i, t in enumerate(calls):
        a, b = res['main'][1].get(i), res['branch'][1].get(i)
        if a is None or (a[0] == 'RAISE' and b is None):
            counts['unexamined'] += 1
            unexamined.setdefault('%s.%s' % (mod, fn), [0, res['main'][0], res['branch'][0]])[0] += 1
            continue
        counts['examined'] += 1
        if a[0] == 'OK' and (b is None or b[0] == 'RAISE'):
            why = b[1] if b else 'not reached (branch rc=%d)' % res['branch'][0]
            listed.setdefault('%s.%s' % (mod, fn), []).append('%s -> %s' % (call_text(mod, fn, t)[5:], why))
        elif a[0] == b[0] == 'OK':
            counts['both_ok'] += 1
            if compare_value:
                floor_both_ok += 1
                if i not in res['main'][2] or i not in res['branch'][2]:
                    fail('missing successful N4 value for %s.%s call %d' % (mod, fn, i))
                av, bv = res['main'][2][i], res['branch'][2][i]
                if not same_value(av, bv):
                    floor_changed.setdefault('%s.%s' % (mod, fn), []).append(
                        '%s -> %s (main) / %s (branch)' % (call_text(mod, fn, t)[5:],
                                                           json.dumps(av), json.dumps(bv)))
        elif a[0] == b[0]:
            counts['both_raise'] += 1
        else:
            counts['improved'] += 1
print('phase2-lib-diff: range=[%d, %d] %s' % (RANGE[0], RANGE[-1], ' '.join('%s=%d' % kv for kv in counts.items())))
for m in sorted(NOT_LIBRARY):
    print('  NOT-LIBRARY %s: %d function(s) not called (%s)' % (m, len(skipped[m]), NOT_LIBRARY[m]))
for fn, (n, rca, rcb) in sorted(unexamined.items()):
    print('  UNEXAMINED %s: %d call(s) main never completed (rc main=%d branch=%d)' % (fn, n, rca, rcb))
bad = 0
for fn in sorted(listed):
    tag = 'INT-DOMAIN' if fn in declared else 'UNDECLARED'
    bad += fn not in declared
    print('  %s %s: %d call(s) raise on the branch only; first: %s%s' % (
        tag, fn, len(listed[fn]), listed[fn][0], ' (%s)' % declared[fn] if fn in declared else ''))
for fn in sorted(set(declared) - set(listed)):
    bad += 1
    print('  STALE %s: declared integer-domain, but no call raises on the branch only' % fn)
print('phase2-lib-diff: N4 source_functions=%d exported_functions=%d calls=%d both_ok=%d changed_functions=%d' % (
    len(floor_scope), floor_functions, floor_calls, floor_both_ok, len(floor_changed)))
for fn in sorted(floor_changed):
    tag = 'N4' if fn in floor_declared else 'UNDECLARED-N4'
    bad += fn not in floor_declared
    print('  %s %s: %d successful value change(s); first: %s%s' % (
        tag, fn, len(floor_changed[fn]), floor_changed[fn][0],
        ' (%s)' % floor_declared[fn] if fn in floor_declared else ''))
for fn in sorted(set(floor_declared) - set(floor_changed)):
    bad += 1
    print('  STALE-N4 %s: declared floor-modulo change, but no successful value changes' % fn)
if floor_functions == 0 or floor_both_ok == 0:
    fail('N4 comparison examined no successful exported modulo calls')
if counts['examined'] == 0 or counts['examined'] + counts['unexamined'] != counts['calls']:
    fail('examined=%d unexamined=%d calls=%d' % (counts['examined'], counts['unexamined'], counts['calls']))
print('phase2-lib-diff: listed_functions=%d undeclared=%d stale=%d %s' % (
    len(set(listed) | set(floor_changed)),
    sum(f not in declared for f in listed) + sum(f not in floor_declared for f in floor_changed),
    len(set(declared) - set(listed)) + len(set(floor_declared) - set(floor_changed)),
    'FAIL' if bad else 'PASS'))
shutil.rmtree(work)
sys.exit(1 if bad else 0)
PY
