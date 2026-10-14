#!/usr/bin/env python3
"""tools/phase2_check.py -- #1758 Phase 2's row checker (design 9.2). Run it
through tools/phase2_check.sh; `--help` lists the options.

ROWS. tests/phase2/MAP.md maps the #1758 items to rows; a row is
tests/phase2/rows/<id>.eigs (or <id>.sh, run as `bash <id>.sh <binary>`) with
its exact branch stdout in <id>.out and a header (`# ROW:`, `# ITEMS:`,
`# EXPECT-RC:`, `# SHAPE:`, `# WITNESS:`, `# OPS:`, optional `# TIERS:`).
Controls (ctl.*) live in tests/phase2/controls/ and must pass on BOTH
binaries. `--through Rk` selects the rows whose [Rn] has landed by Rk.

TIERS. off (EIGS_JIT_OFF=1), default, osr (EIGS_JIT_OSR_THRESHOLD=1) and
trace (EIGS_TRACE, default JIT: the leaf evaluator is off there, so this
tier is the leaf differential). Every run: 30 s bound, stdin /dev/null, a
fresh scratch cwd, every inherited EIGS_* variable removed.

VERDICTS per row and tier: branch PASS = rc equals EXPECT-RC and stdout
equals the .out; tag FAIL = not that; VACUOUS = the branch passed but the
row's tier witness (design 9.1) does not hold. rc 124 is TIMEOUT and rc >=
128 SIGNAL: a FAIL on the branch, counted apart on the tag.

WITNESSES (read on the branch, from EIGS_JIT_HOT / STATS / STOPS and
EIGS_DUMP_BC; nothing in production changes so a witness can see it):
  leaf F...      JIT-on normal runs (default, osr) count no entry for F, and
                 the trace run counts K >= 1: the leaf computed every call.
                 (With EIGS_JIT_OFF the hot table counts no calls at all, so
                 the off tier cannot witness.)
  leaf-gen F...  the default run and the trace run count the same K >= 1.
  fn F           default and osr runs: `jit yes`, `adv RET`, compiled >= 1.
  fn-stop F OP   default run: `jit yes`, the op at offset `adv` is OP.
  osr C          osr run: `osr yes` and oadv == len (the return sentinel).
  osr-stop C OP  osr run: `osr yes`, oadv != len, the op at oent+oadv is OP.
A -stop whose op is the chunk's compile stop must also be named by
EIGS_JIT_STOPS.

MECHANICAL ROUNDS (R1.1, R1.2, R2.1) have no rows of their own; --through
one of them runs its gates instead: the token gate (every token a landed
round deleted is absent from code), the int-source check (before R1.3 no
runtime code calls slot_from_int or make_int outside the canonicalizing
writers; make_int does not exist), the C slot test, and the corpus
differential against --baseline (the binary from before the round).

Exit 0 iff the population checks pass, every tier has examined == tag_fail
== branch_pass > 0 (or the round is mechanical and every gate passed),
vacuous == 0, and every landed control passes on both binaries.
`--calibrate` runs the design's calibration list (9.2) on fixtures in
tests/phase2/calib/ and prints `calibration: cases=N as-expected=N`.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import phase2_inventory as inv  # noqa: E402  (strip_c: one C-comment grammar)

ROUNDS = ['R1.1', 'R1.2', 'R1.3', 'R1.4', 'R1.5', 'R1.6', 'R1.7', 'R1.8',
          'R2.1', 'R2.2', 'R2.3', 'R2.4', 'R2.5', 'R2.6', 'R3']
MECHANICAL = {
    'R1.1': ('tokens', 'int-source', 'slot-test', 'corpus-diff'),
    'R1.2': ('tokens', 'int-source', 'slot-test', 'corpus-diff'),
    'R2.1': ('tokens', 'slot-test', 'corpus-diff'),
}
ITEMS = ['N%d' % i for i in range(1, 15)] + ['N4b', 'A', 'B', 'T1', 'O1', 'O2', 'O3', 'O4']
# design 2.7: the tokens each round deletes. A later round adds its list here
# in the commit that deletes them (R1.6's bridge, 21 tokens, with R1.6).
DELETED_TOKENS = {
    'R1.1': ['slot_is_num', 'slot_is_numeric', 'SLOT_NUM_RAW', 'slot_from_num', 'slot_as_double'],
    'R1.3': ['eigs_int_unwired'],
    'R2.2': ['num_guard', 'num_guard_named', 'EIGS_NUM_MAX'],
}
# design 2.1: the canonicalizing writers, the only runtime callers of an int
# writer allowed before R1.3 (they convert an existing VAL_INT).
INT_SOURCE_ALLOWED = {'eigs_container_slot', 'eigs_slot_adopt', 'eigs_slot_store_owned',
                      'eigs_slot_store_borrow', 'slot_from_value'}
WITNESS_KINDS = {'none', 'leaf', 'leaf-gen', 'fn', 'fn-stop', 'osr', 'osr-stop'}
TIERS = ['off', 'default', 'osr', 'trace']
HOT_HDR = re.compile(r'^chunk\s+exec\s+jit\s+pct\s+adv\s+len\s+nat%\s+bked\s+osr\s+oadv\s+oent\s+stop$')


def rindex(r):
    return ROUNDS.index(r)


# ---- the MAP ---------------------------------------------------------------
ROW_LINE = re.compile(r'^- `([^`]+)` (?:\[([^\]]+)\]|\((control)\))')
SHAPE_LINE = re.compile(r'^\s+shape:\s*([LFO])\s+witness:\s*(.*?)\s+ops:\s*(.*?)\s*$')


def parse_witness(text):
    text = re.sub(r'\([^)]*\)', ' ', text).split()
    if not text:
        return None
    kind = text[0]
    if kind.endswith('-stop'):
        return {'kind': kind, 'chunks': text[1:-1], 'op': text[-1] if len(text) > 2 else None}
    return {'kind': kind, 'chunks': text[1:], 'op': None}


def parse_map(path):
    rows, bad, item = [], [], None
    lines = open(path, encoding='utf-8').read().split('\n')
    for n, line in enumerate(lines, 1):
        m = re.match(r'^### (\S+)\s*$', line)
        if m:
            item = m.group(1)
            continue
        m = ROW_LINE.match(line)
        if not m:
            continue
        rid, rnd, ctl = m.group(1), m.group(2), m.group(3)
        row = {'id': rid, 'item': item, 'line': n, 'shape': 'S', 'sketch': line[m.end():],
               'witness': {'kind': 'none', 'chunks': [], 'op': None}, 'ops': []}
        if rid.startswith('ctl.') != bool(ctl):
            bad.append('MAP:%d: `%s`: a control must be marked (control), and only a control' % (n, rid))
        row['kind'] = 'control' if ctl else 'gate' if rid.startswith('gate.') else 'row'
        if rnd:
            parts = rnd.split('/')
            if any(p not in ROUNDS for p in parts):
                bad.append('MAP:%d: `%s` names an unknown round [%s]' % (n, rid, rnd))
                continue
            row['round'] = max(parts, key=rindex)
        else:
            row['round'] = None
        for follow in lines[n:n + 4]:
            if follow.startswith('- ') or follow.startswith('#'):
                break
            ms = SHAPE_LINE.match(follow)
            if ms:
                row['shape'] = ms.group(1)
                w = parse_witness(ms.group(2))
                if not w or w['kind'] not in WITNESS_KINDS:
                    bad.append('MAP:%d: `%s` has an unknown witness %r' % (n, rid, ms.group(2)))
                else:
                    row['witness'] = w
                row['ops'] = ms.group(3).split()
        rows.append(row)
    return rows, bad


def header(path):
    h = {}
    for line in open(path, encoding='utf-8'):
        m = re.match(r'^#\s*([A-Z-]+):\s*(.*?)\s*$', line)
        if not m:
            if line.strip() and not line.startswith('#'):
                break
            continue
        h[m.group(1)] = m.group(2)
    return h


def row_file(d, rid):
    for ext in ('.eigs', '.sh'):
        p = os.path.join(d, rid + ext)
        if os.path.exists(p):
            return p
    return None


# ---- running ---------------------------------------------------------------
def run(binary, path, env_extra, scratch):
    env = {k: v for k, v in os.environ.items() if not k.startswith('EIGS_')}
    env.update(env_extra)
    cwd = tempfile.mkdtemp(dir=scratch)
    if 'EIGS_TRACE' in env and env['EIGS_TRACE'] == '@':
        env['EIGS_TRACE'] = os.path.join(cwd, 't.tape')
    cmd = (['bash', path, binary] if path.endswith('.sh') else [binary, path])
    tmo = shutil.which('timeout') or shutil.which('gtimeout')
    if tmo:
        cmd = [tmo, '30'] + cmd
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=60)
        return p.returncode, p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        return 124, '', 'phase2-check: the 60 s backstop fired'
    finally:
        shutil.rmtree(cwd, ignore_errors=True)


TIER_ENV = {'off': {'EIGS_JIT_OFF': '1'}, 'default': {}, 'osr': {'EIGS_JIT_OSR_THRESHOLD': '1'},
            'trace': {'EIGS_TRACE': '@'}}


def hot_rows(err):
    lines = err.split('\n')
    try:
        i = next(k for k, l in enumerate(lines) if HOT_HDR.match(l.strip()))
    except StopIteration:
        return None
    rows = {}
    for l in lines[i + 1:]:
        w = l.split()
        if len(w) != 12 or not w[1].isdigit():
            break
        rows[w[0]] = dict(exec=int(w[1]), jit=w[2], adv=w[4], len=int(w[5]), osr=w[8],
                          oadv=int(w[9]), oent=int(w[10]), stop=w[11])
    return rows


def compiled(err):
    m = re.search(r'\[jit\] scanned=\d+ compiled=(\d+)', err)
    return int(m.group(1)) if m else -1


def bytecode(text, chunk):
    ops, cur = {}, None
    for l in text.split('\n'):
        m = re.match(r'^=== (\S+) \((\S+?), (\d+) bytes', l)
        if m:
            cur = m.group(2)
            continue
        m = re.match(r'^(\d{4}) \[L\d+\] (\S+)', l)
        if m and cur == chunk:
            ops[int(m.group(1))] = m.group(2)
    return ops


def witness(binary, path, w, scratch):
    """(holds, evidence). Instrument failures (no hot table) do not hold."""
    kind, chunks, op = w['kind'], w['chunks'], w['op']
    diag = {'EIGS_JIT_HOT': '1', 'EIGS_JIT_STATS': '1', 'EIGS_JIT_STOPS': '1'}
    ev = []
    if kind in ('leaf', 'leaf-gen'):
        _, _, terr = run(binary, path, dict(diag, EIGS_TRACE='@'), scratch)
        thot = hot_rows(terr)
        if thot is None:
            return False, 'no EIGS_JIT_HOT table in the trace run'
        ok = True
        for tier in ('default', 'osr'):
            _, _, err = run(binary, path, dict(TIER_ENV[tier], **diag), scratch)
            hot = hot_rows(err)
            if hot is None:
                return False, 'no EIGS_JIT_HOT table (%s)' % tier
            for c in chunks:
                kn, kt = hot.get(c, {}).get('exec', 0), thot.get(c, {}).get('exec', 0)
                ev.append('%s %s=%d trace=%d' % (c, tier, kn, kt))
                if kt < 1 or (kind == 'leaf' and kn != 0) or (kind == 'leaf-gen' and kn != kt):
                    ok = False
            if kind == 'leaf-gen':
                break          # the generic path is the same in both JIT tiers
        return ok and bool(chunks), '; '.join(ev)
    tiers = ('default', 'osr') if kind == 'fn' else ('default',) if kind == 'fn-stop' else ('osr',)
    c = chunks[0] if chunks else None
    ok = bool(c)
    for tier in tiers:
        env = dict(TIER_ENV[tier], **diag)
        _, _, err = run(binary, path, env, scratch)
        hot = hot_rows(err)
        r = (hot or {}).get(c)
        if r is None:
            return False, '%s: no EIGS_JIT_HOT row for %s' % (tier, c)
        ev.append('%s %s jit=%s adv=%s len=%d osr=%s oadv=%d oent=%d stop=%s compiled=%d' % (
            tier, c, r['jit'], r['adv'], r['len'], r['osr'], r['oadv'], r['oent'], r['stop'],
            compiled(err)))
        if compiled(err) < 1:
            ok = False
        if kind == 'fn':
            ok = ok and r['jit'] == 'yes' and r['adv'] == 'RET'
        elif kind == 'osr':
            ok = ok and r['osr'] == 'yes' and r['oadv'] == r['len']
        else:
            _, dout, derr = run(binary, path, dict(TIER_ENV[tier], EIGS_DUMP_BC='1'), scratch)
            ops = bytecode(dout + '\n' + derr, c)
            if kind == 'fn-stop':
                at = None if r['adv'] in ('RET', '?') else int(r['adv'])
                ok = ok and r['jit'] == 'yes' and at is not None and ops.get(at) == op
            else:
                at = r['oent'] + r['oadv']
                ok = ok and r['osr'] == 'yes' and r['oadv'] != r['len'] and ops.get(at) == op
            ev.append('op_at_stop=%s' % (ops.get(at) if at is not None else 'RET'))
            if ok and r['stop'] == op and not re.search(r'\b%s\b' % re.escape(op), err.split(
                    '=== Hot chunks')[0]):
                ok = False
                ev.append('compile stop %s not named by EIGS_JIT_STOPS' % op)
    return ok, '; '.join(ev)


# ---- the row check -----------------------------------------------------------
def check(map_rows, rows_dir, ctl_dir, tag, branch, through, scratch, out):
    """Runs the landed rows and controls; returns (ok, counters)."""
    landed = [r for r in map_rows if r['kind'] == 'row' and r['round'] and
              rindex(r['round']) <= rindex(through)]
    controls = [r for r in map_rows if r['kind'] == 'control']
    gates = [r for r in map_rows if r['kind'] == 'gate' and r['round'] and
             rindex(r['round']) <= rindex(through)]
    bad = []
    ids = {r['id'] for r in map_rows}
    files = sorted(f for f in (os.listdir(rows_dir) if os.path.isdir(rows_dir) else [])
                   if f.endswith(('.eigs', '.sh')))
    for f in files:
        stem = f.rsplit('.', 1)[0]
        if stem not in ids:
            bad.append('row file %s has no MAP id' % f)
    # controls land with the first round that has rows of its own (R1.3)
    want_controls = any(rindex(r['round']) <= rindex(through) for r in map_rows
                        if r['kind'] == 'row' and r['round'])
    ctl_files = sorted(f for f in (os.listdir(ctl_dir) if os.path.isdir(ctl_dir) else [])
                       if f.endswith(('.eigs', '.sh')))
    for f in ctl_files:
        if f.rsplit('.', 1)[0] not in ids:
            bad.append('control file %s has no MAP id' % f)
    todo = []
    for r in landed + (controls if want_controls else []):
        d = ctl_dir if r['kind'] == 'control' else rows_dir
        p = row_file(d, r['id'])
        if not p:
            bad.append('MAP id %s [%s] has no file in %s' % (r['id'], r['round'] or 'control', d))
            continue
        h = header(p)
        if h.get('ROW') != r['id']:
            bad.append('%s: header ROW %r is not its id' % (p, h.get('ROW')))
        if h.get('SHAPE', 'S') != r['shape']:
            bad.append('%s: SHAPE %s, the MAP says %s' % (p, h.get('SHAPE'), r['shape']))
        hw = parse_witness(h.get('WITNESS', 'none')) or {}
        if (hw.get('kind'), hw.get('chunks'), hw.get('op')) != (
                r['witness']['kind'], r['witness']['chunks'], r['witness']['op']):
            bad.append('%s: WITNESS %r differs from the MAP' % (p, h.get('WITNESS')))
        if not os.path.exists(p.rsplit('.', 1)[0] + '.out'):
            bad.append('%s: no .out' % p)
            continue
        todo.append((r, p, h))
    for g in gates:
        # a gate names a check the Done-when runs on its own: its file or
        # make target must exist (it is listed, never run or counted here)
        named = [t for t in re.findall(r'`([^`]+)`', g['sketch'])
                 if t.startswith('make ') or ('/' in t and ' ' not in t)]
        for t in named:
            found = (subprocess.run(['make', '-n', '-C', ROOT] + t.split()[1:], capture_output=True
                                    ).returncode == 0 if t.startswith('make ')
                     else os.path.exists(os.path.join(ROOT, t)))
            if not found:
                bad.append('gate %s names %r, which does not exist' % (g['id'], t))
        if not named:
            bad.append('gate %s names no file or make target' % g['id'])
    cnt = {t: dict(examined=0, tag_fail=0, branch_pass=0, vacuous=0, tag_timeout=0, tag_signal=0)
           for t in TIERS}
    ctl_n = ctl_both = witnessed = 0
    for r, p, h in todo:
        want = open(p.rsplit('.', 1)[0] + '.out', encoding='utf-8').read()
        want_rc = int(h.get('EXPECT-RC', '0'))
        tiers = h.get('TIERS', ' '.join(TIERS)).split()
        is_ctl = r['kind'] == 'control'
        passes = {}
        for t in tiers:
            res = {}
            for who, b in (('tag', tag), ('branch', branch)):
                rc, so, se = run(b, p, TIER_ENV[t], scratch)
                res[who] = (rc == want_rc and so == want, rc)
            passes[t] = res
            if is_ctl:
                continue
            c = cnt[t]
            c['examined'] += 1
            ok_tag, rc_tag = res['tag']
            ok_br, rc_br = res['branch']
            if not ok_tag:
                c['tag_fail'] += 1
                c['tag_timeout'] += rc_tag == 124
                c['tag_signal'] += rc_tag >= 128
            if ok_br:
                c['branch_pass'] += 1
            else:
                out('  BRANCH-FAIL %s tier=%s rc=%d%s' % (r['id'], t, rc_br,
                    ' TIMEOUT' if rc_br == 124 else ' SIGNAL' if rc_br >= 128 else ''))
            if ok_tag:
                out('  TAG-PASS %s tier=%s: the row does not fail on the tag' % (r['id'], t))
        if is_ctl:
            ctl_n += 1
            if all(v[0] for res in passes.values() for v in res.values()):
                ctl_both += 1
            else:
                out('  CONTROL-FAIL %s: %s' % (r['id'], passes))
            continue
        if r['witness']['kind'] != 'none' and all(passes[t]['branch'][0] for t in tiers):
            holds, ev = witness(branch, p, r['witness'], scratch)
            if holds:
                witnessed += 1
                out('  WITNESS %s %s holds [%s]' % (r['id'], r['witness']['kind'], ev))
            else:
                for t in tiers:
                    cnt[t]['vacuous'] += 1
                out('  VACUOUS %s %s [%s]' % (r['id'], r['witness']['kind'], ev))
    for b in bad:
        out('  POPULATION: ' + b)
    for t in TIERS:
        c = cnt[t]
        out('tier=%s examined=%d rows tag_fail=%d branch_pass=%d vacuous=%d tag_timeout=%d tag_signal=%d'
            % (t, c['examined'], c['tag_fail'], c['branch_pass'], c['vacuous'], c['tag_timeout'],
               c['tag_signal']))
    out('controls=%d both_pass=%d witnessed=%d mapped=%d gates=%d through=%s' % (
        ctl_n, ctl_both, witnessed, len(landed), len(gates), through))
    rows_ok = all(c['examined'] == c['tag_fail'] == c['branch_pass'] > 0 and c['vacuous'] == 0
                  for c in cnt.values())
    return (not bad, rows_ok, ctl_n == ctl_both, len(landed), cnt, witnessed)


# ---- mechanical gates ----------------------------------------------------------
def code_text(path):
    return inv.strip_c(open(path, encoding='utf-8', errors='replace').read())


def c_files(root, dirs=('src',), recurse_tests=True):
    out = []
    for d in dirs:
        out += [os.path.join(root, d, f) for f in sorted(os.listdir(os.path.join(root, d)))
                if f.endswith(('.c', '.h'))]
    if recurse_tests:
        for base, _, fs in os.walk(os.path.join(root, 'tests')):
            out += [os.path.join(base, f) for f in sorted(fs) if f.endswith(('.c', '.h'))]
    return out


def token_gate(root, through, out):
    toks = [t for r, ts in DELETED_TOKENS.items() if rindex(r) <= rindex(through) for t in ts]
    files = c_files(root)
    hits = []
    for p in files:
        text = code_text(p)
        for t in toks:
            for m in re.finditer(r'\b%s\b' % re.escape(t), text):
                hits.append('%s:%d %s' % (os.path.relpath(p, root), text.count('\n', 0, m.start()) + 1, t))
    for h in hits:
        out('  TOKEN %s (deleted by a landed round, still in code)' % h)
    out('tokens: rounds<=%s tokens=%d files=%d hits=%d' % (through, len(toks), len(files), len(hits)))
    return bool(files) and bool(toks) and not hits


def int_source(src, out):
    """Before R1.3: runtime calls of slot_from_int / make_int only inside the
    canonicalizing writers; make_int is not defined; slot_from_int is defined
    exactly once."""
    files = sorted(os.path.join(src, f) for f in os.listdir(src) if f.endswith(('.c', '.h')))
    defs = {'slot_from_int': 0, 'make_int': 0}
    calls, bad = [], []
    for p in files:
        text = code_text(p)
        scope = inv.scopes_for(text, os.path.basename(p))
        for ln, line in enumerate(text.split('\n'), 1):
            for m in re.finditer(r'\b(slot_from_int|make_int)\s*\(', line):
                fn = scope[ln].split('/')[0]
                name = m.group(1)
                if fn == '<file scope>' or fn == name:
                    defs[name] += 1     # a definition or a prototype
                    continue
                calls.append((os.path.basename(p), ln, fn, name))
                if fn not in INT_SOURCE_ALLOWED:
                    bad.append('%s:%d: %s calls %s' % (os.path.basename(p), ln, fn, name))
    for b in bad:
        out('  INT-SOURCE %s: no int may be produced before R1.3' % b)
    if defs['make_int']:
        out('  INT-SOURCE make_int is defined before R1.3')
    if defs['slot_from_int'] != 1:
        out('  INT-SOURCE slot_from_int is defined %d times, want 1 (did the scan find it?)'
            % defs['slot_from_int'])
    out('int-source: files=%d slot_from_int_defs=%d make_int_defs=%d calls=%d outside_writers=%d' % (
        len(files), defs['slot_from_int'], defs['make_int'], len(calls), len(bad)))
    return bool(files) and not bad and not defs['make_int'] and defs['slot_from_int'] == 1


def tool(cmd, out, tail_re):
    p = subprocess.run(cmd, cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True)
    text = (p.stdout + p.stderr).decode('utf-8', 'replace')
    for l in text.split('\n'):
        if re.match(tail_re, l):
            out('  ' + l)
    return p.returncode == 0, text


def mechanical(through, baseline, branch, out):
    res = {}
    for g in MECHANICAL[through]:
        if g == 'tokens':
            res[g] = token_gate(ROOT, through, out)
        elif g == 'int-source':
            res[g] = int_source(os.path.join(ROOT, 'src'), out)
        elif g == 'slot-test':
            res[g], _ = tool(['bash', 'tests/phase2/slot_layer.sh', 'release'], out,
                             r'^(slot-layer|slot-layer-population|slot-layer-test: (examined|FAIL))')
        elif g == 'corpus-diff':
            if not baseline:
                out('  corpus-diff: a mechanical round needs --baseline <the binary from before it>')
                res[g] = False
            else:
                res[g], _ = tool(['bash', 'tools/phase2_corpus_diff.sh', baseline, branch], out,
                                 r'^(corpus-diff: (baseline|branch|examined|PASS|FAIL)|DIFF|DELETED|NEW|NONDET|BOTH-)')
        out('mechanical %s: %s' % (g, 'PASS' if res[g] else 'FAIL'))
    return all(res.values()) and bool(res)


# ---- the plan-level checks -------------------------------------------------------
def plan_checks(map_rows, bad, out):
    for item in ITEMS:
        if not any(r['item'] == item for r in map_rows if r['kind'] != 'control'):
            bad.append('item %s has no row in the MAP' % item)
    arms, lines, inside = {}, open(os.path.join(ROOT, 'docs/design/phase2-inventory.txt')).read(
        ).split('\n'), False
    for l in lines:
        if l.startswith('## Numeric arms'):
            inside = True
            continue
        if inside and (l.startswith('## ') or not l.strip()):
            break
        if inside:
            w = l.split()
            arms['%s %s' % (w[0], w[1])] = set(w[2:])
    # a leaf arm is exercised by a leaf (L) row, an emitter arm by an F or O row
    shaped = [r for r in map_rows if r['shape'] in ('L', 'F', 'O')]
    ops = {'leaf_exec': {('OP_' + o) for r in shaped if r['shape'] == 'L' for o in r['ops']},
           'jit_emit': {('OP_' + o) for r in shaped if r['shape'] != 'L' for o in r['ops']}}
    covered = [a for a, chain in arms.items() if chain & ops.get(a.split()[0], set())]
    for a in sorted(set(arms) - set(covered)):
        bad.append('numeric arm %s is exercised by no L/F/O row ops' % a)
    rounds = {r['round'] for r in map_rows if r['round']}
    for rd in ROUNDS:
        if rd not in rounds and rd not in MECHANICAL:
            bad.append('round %s has neither rows nor mechanical gates' % rd)
    out('rounds: ' + ' '.join('%s=%d%s' % (rd, sum(r['round'] == rd for r in map_rows if r['kind'] == 'row'),
                                           '+mechanical' if rd in MECHANICAL else
                                           '+gates' if any(r['round'] == rd for r in map_rows
                                                           if r['kind'] == 'gate') else '')
                              for rd in ROUNDS))
    out('plan: items=%d rows=%d shaped=%d arms=%d covered=%d' % (
        len(ITEMS), sum(r['kind'] == 'row' for r in map_rows), len(shaped), len(arms), len(covered)))
    if not arms:
        bad.append('the inventory lists no numeric arm (scan found nothing)')
    return len(arms)


def banner(tag, branch, out):
    for who, b in (('tag', tag), ('branch', branch)):
        v = subprocess.run([b, '--version'], capture_output=True).stdout.decode().strip()
        h = subprocess.run(['sha256sum', b], capture_output=True).stdout.decode().split()[:1]
        out('%s: %s (%s) sha256 %s' % (who, b, v, (h or ['?'])[0][:16]))


def main_check(args, out):
    banner(args.tag, args.branch, out)
    map_rows, bad = parse_map(args.map)
    if not map_rows:
        bad.append('the MAP lists no row')
    plan_checks(map_rows, bad, out)
    for b in bad:
        out('  PLAN: ' + b)
    with tempfile.TemporaryDirectory(prefix='eigs-p2-') as scratch:
        pop_ok, rows_ok, ctl_ok, landed, cnt, _ = check(
            map_rows, args.rows, args.controls, args.tag, args.branch, args.through, scratch, out)
    mech_ok = None
    if args.through in MECHANICAL:
        mech_ok = mechanical(args.through, args.baseline, args.branch, out)
    if landed == 0:
        if mech_ok is None:
            out('  ZERO-ROWS: %s has no landed row and no mechanical gates' % args.through)
        verdict = bool(mech_ok) and pop_ok and not bad and ctl_ok
    else:
        verdict = rows_ok and pop_ok and not bad and ctl_ok and mech_ok is not False
    out('phase2-check: %s' % ('PASS' if verdict else 'FAIL'))
    return 0 if verdict else 1


# ---- calibration (design 9.2, one-time) -------------------------------------------
def calibrate(args, out):
    cal = os.path.join(ROOT, 'tests/phase2/calib')
    map_rows, bad = parse_map(os.path.join(cal, 'MAP.md'))
    results = []

    def case(name, got, want):
        ok = got == want
        results.append(ok)
        out('CAL %-58s want %-28s got %-28s %s' % (name, want, got, 'ok' if ok else 'UNEXPECTED'))

    def quiet(_):
        pass

    def sub(rows, ids, mutate=None, tag=None, branch=None, log=quiet):
        with tempfile.TemporaryDirectory(prefix='eigs-p2cal-') as d:
            rd = os.path.join(d, 'rows')
            os.mkdir(rd)
            for r in rows:
                if r['id'] in ids:
                    for ext in ('.eigs', '.out'):
                        shutil.copy(os.path.join(cal, r['id'] + ext), rd)
            if mutate:
                mutate(rd)
            sel = [r for r in rows if r['id'] in ids]
            lines = []
            res = check(sel, rd, os.path.join(d, 'none'), tag or args.tag, branch or args.branch,
                        'R1.3', os.path.join(d), lambda s: (lines.append(s), log(s)))
            return res, lines

    honest = [r['id'] for r in map_rows if not r['id'].endswith('-plant')]
    out('calibration fixtures: %d rows (%d honest) in %s' % (len(map_rows), len(honest), cal))
    case('fixture MAP parses', not bad and len(map_rows) > 0, True)
    (pop, rows_ok, _, n, cnt, wit), _ = sub(map_rows, honest, log=out)
    case('honest rows: every tier tag_fail == branch_pass == examined', rows_ok, True)
    case('honest rows: every witness holds', wit, sum(r['witness']['kind'] != 'none'
                                                       for r in map_rows if r['id'] in honest))
    (pop, rows_ok, _, n, cnt, _), _ = sub(map_rows, honest, tag=args.branch)
    case('the branch passed as the tag too: branch_pass=0?', cnt['default']['tag_fail'], 0)
    case('... and the check fails', rows_ok, False)
    (pop, rows_ok, _, n, cnt, _), _ = sub(map_rows, honest, branch=args.tag)
    case('the tag passed as the branch: branch_pass', cnt['default']['branch_pass'], 0)
    victim = honest[0]

    def corrupt(rd):
        with open(os.path.join(rd, victim + '.out'), 'a') as f:
            f.write('corrupted\n')
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, honest, mutate=corrupt)
    case('a corrupted .out fails, naming the row', (rows_ok, any(
        ('BRANCH-FAIL %s ' % victim) in l for l in lines)), (False, True))
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, [])
    case('an empty rows directory: examined=0 fails', (rows_ok, cnt['default']['examined']), (False, 0))

    def drop(rd):
        os.remove(os.path.join(rd, victim + '.eigs'))
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, honest, mutate=drop)
    case('a MAP id with no file fails', (pop, any('has no file' in l for l in lines)), (False, True))

    def stray(rd):
        shutil.copy(os.path.join(rd, victim + '.eigs'), os.path.join(rd, 'stray.row.eigs'))
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, honest, mutate=stray)
    case('a file with no MAP id fails', (pop, any('stray.row.eigs has no MAP id' in l for l in lines)),
         (False, True))
    for r in map_rows:
        if r['id'].endswith('-plant'):
            (pop, rows_ok, _, n, cnt, wit), lines = sub(map_rows, [r['id']])
            case('plant %s: vacuous, named' % r['id'], (cnt['default']['vacuous'], any(
                ('VACUOUS %s ' % r['id']) in l for l in lines)), (1, True))
    # the plan-level checks against a mutated copy of the real MAP
    real, rbad = parse_map(os.path.join(ROOT, 'tests/phase2/MAP.md'))
    lines = []
    plan_checks(real, list(rbad), lines.append)
    pb = []
    plan_checks(real, pb, quiet)
    case('plan checks on the real MAP pass', (rbad, pb), ([], []))
    pb = []
    plan_checks([r for r in real if r['item'] != 'N4b'], pb, quiet)
    case('a MAP with no N4b row fails, naming N4b', any('item N4b' in b for b in pb), True)
    pb = []
    n_arms = plan_checks([dict(r, ops=[]) for r in real], pb, quiet)
    case('a MAP whose rows exercise no arm fails per arm (%d arms)' % n_arms,
         sum('numeric arm' in b for b in pb) == n_arms > 0, True)
    pb = []
    plan_checks([r for r in real if r['round'] != 'R2.3'], pb, quiet)
    case('a round with neither rows nor gates fails', any('round R2.3' in b for b in pb), True)
    # the int-source check against a planted production call
    with tempfile.TemporaryDirectory(prefix='eigs-p2cal-') as d:
        shutil.copytree(os.path.join(ROOT, 'src'), os.path.join(d, 'src'))
        p = os.path.join(d, 'src', 'trace.c')
        text = open(p).read()
        anchor = '        *out = slot_from_f64((double)count);'
        n_anchor = text.count(anchor)
        open(p, 'w').write(text.replace(anchor, '        *out = slot_from_int(count);'))
        lines = []
        ok = int_source(os.path.join(d, 'src'), lines.append)
        case('int-source plant (slot_from_int(count) in trace.c) applied once', n_anchor, 1)
        case('int-source plant: the check fails, naming the caller', (ok, any(
            'trace.c' in l and 'calls slot_from_int' in l for l in lines)), (False, True))
    lines = []
    case('int-source on the real tree passes', int_source(os.path.join(ROOT, 'src'), lines.append), True)
    # the token gate against a reintroduced deleted token
    with tempfile.TemporaryDirectory(prefix='eigs-p2cal-') as d:
        os.mkdir(os.path.join(d, 'src'))
        os.mkdir(os.path.join(d, 'tests'))
        for f in os.listdir(os.path.join(ROOT, 'src')):
            if f.endswith(('.c', '.h')):
                shutil.copy(os.path.join(ROOT, 'src', f), os.path.join(d, 'src'))
        with open(os.path.join(d, 'src', 'vm.c'), 'a') as f:
            f.write('\nstatic int stray_reader(EigsSlot s) { return slot_is_num(s); }\n')
        lines = []
        case('token plant (slot_is_num reintroduced): the gate fails',
             (token_gate(d, 'R1.1', lines.append), any('slot_is_num' in l for l in lines)), (False, True))
    if args.build_plants:
        args.planted_leaf_scan, args.planted_leaf_mul = build_leaf_plants(out)
    for label, flag, b in (('leaf-scanner-early-return', '--planted-leaf-scan', args.planted_leaf_scan),
                           ('leaf-mul-plus-one', '--planted-leaf-mul', args.planted_leaf_mul)):
        if not b:
            out('CAL %-58s NOT RUN (no %s binary; --build-plants builds it)' % (label, flag))
            results.append(False)
            continue
        leaf = [r['id'] for r in map_rows if r['witness']['kind'] == 'leaf' and r['id'] in honest]
        (pop, rows_ok, _, n, cnt, wit), lines = sub(map_rows, leaf, branch=b)
        if label == 'leaf-scanner-early-return':
            case('leaf row vs a scratch build whose leaf scanner returns early',
                 (cnt['default']['vacuous'] > 0, rows_ok), (True, False))
        else:
            case('L row vs a scratch build whose leaf MUL adds 1: trace differs',
                 (cnt['trace']['branch_pass'], cnt['default']['branch_pass'] > 0, rows_ok), (len(leaf), False, False))
    n_ok = sum(results)
    out('calibration: cases=%d as-expected=%d unexpected=%d' % (len(results), n_ok, len(results) - n_ok))
    return 0 if results and n_ok == len(results) else 1


LEAF_PLANTS = (
    # (file, original, planted): the two scratch builds of design 9.2
    ('src/chunk.c', '    c->leaf_accessor = 0;\n    if (c->param_count > LEAF_ACCESSOR_MAX_DEPTH) return;',
     '    c->leaf_accessor = 0;\n    return;   /* PLANT: the leaf scanner never admits a chunk */\n'
     '    if (c->param_count > LEAF_ACCESSOR_MAX_DEPTH) return;'),
    ('src/vm.c', '                r = a * b;\n', '                r = a * b + 1;   /* PLANT */\n'),
)
_PLANT_DIR = []


def build_leaf_plants(out):
    """git archive HEAD twice into scratch trees (no .git), apply one plant to
    each (exactly once before, present after), build each with plain make."""
    paths = []
    for f, old, new in LEAF_PLANTS:
        d = tempfile.mkdtemp(prefix='eigs-p2leaf-')
        _PLANT_DIR.append(d)
        subprocess.run('git -C %s archive HEAD | tar -x -C %s' % (ROOT, d), shell=True, check=True)
        p = os.path.join(d, f)
        text = open(p).read()
        if text.count(old) != 1:
            out('  PLANT %s: the original occurs %d times, want 1 (BROKEN)' % (f, text.count(old)))
            paths.append(None)
            continue
        open(p, 'w').write(text.replace(old, new))
        r = subprocess.run(['make'], cwd=d, capture_output=True)
        b = os.path.join(d, 'src', 'eigenscript')
        ok = r.returncode == 0 and os.access(b, os.X_OK)
        out('  PLANT %s built in %s: %s' % (f, d, 'ok' if ok else 'BROKEN (make rc=%d)' % r.returncode))
        paths.append(b if ok else None)
    return paths


def main():
    ap = argparse.ArgumentParser(prog='tools/phase2_check.sh')
    ap.add_argument('tag', help='the v0.46.0 tag binary')
    ap.add_argument('branch', help='the branch binary')
    ap.add_argument('--through', default=ROUNDS[-1], choices=ROUNDS)
    ap.add_argument('--baseline', help='the binary from before a mechanical round (corpus differential)')
    ap.add_argument('--map', default=os.path.join(ROOT, 'tests/phase2/MAP.md'))
    ap.add_argument('--rows', default=os.path.join(ROOT, 'tests/phase2/rows'))
    ap.add_argument('--controls', default=os.path.join(ROOT, 'tests/phase2/controls'))
    ap.add_argument('--calibrate', action='store_true')
    ap.add_argument('--planted-leaf-scan', help='calibration: a build whose leaf scanner returns early')
    ap.add_argument('--planted-leaf-mul', help='calibration: a build whose leaf MUL computes a*b+1')
    ap.add_argument('--build-plants', action='store_true',
                    help='calibration: build both planted binaries from HEAD (two release builds)')
    args = ap.parse_args()
    for b in (args.tag, args.branch, args.baseline, args.planted_leaf_scan, args.planted_leaf_mul):
        if b and not os.access(b, os.X_OK):
            print('phase2-check: FAIL: %s is not an executable' % b)
            return 2
    args.tag, args.branch = os.path.abspath(args.tag), os.path.abspath(args.branch)

    def out(s):
        print(s, flush=True)
    if args.calibrate:
        try:
            return calibrate(args, out)
        finally:
            for d in _PLANT_DIR:
                shutil.rmtree(d, ignore_errors=True)
    return main_check(args, out)


if __name__ == '__main__':
    sys.exit(main())
