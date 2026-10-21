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

EVERY MODE runs two gates: the token gate (every token a landed round
deleted is absent from code) and the inventory's own verdict
(tools/phase2_inventory.py --check: every slot classifier has a reviewed
disposition, and the committed docs/design/phase2-inventory.txt is exactly
the generated one, #1804).

MECHANICAL ROUNDS (R1.1, R1.2, R1.6a/e/f/z, R2.1) have no rows of their own; --through
one of them runs its gates instead: the int-source check in two halves --
static: before R1.3 no runtime code calls slot_from_int or make_int outside
the canonicalizing writers, make_int does not exist, and TAG_SMI or an SMI
bit pattern is spelled only at its value_slot.h homes; dynamic (--smi-trap,
R1.1/R1.2): the corpus differential against a `make smi-trap` build, on
which every slot classifier aborts at an SMI -- the C slot test, and the
corpus differential against --baseline (the binary from before the round).
The differential runs each file under its run conditions from the suite's
loader (tests/suite_program_env.sh) and requires every nonzero exit to be
declared (tests/phase2/corpus_nonzero.txt); its header is the reference.
A gate tool that writes to stderr fails, with its words (tool()); the
checker runs under `python3 -W error` (tools/phase2_check.sh).

Exit 0 iff the population checks pass, every tier has examined == tag_fail
== branch_pass > 0 (or the round is mechanical and every gate passed),
vacuous == 0, and every landed control passes on both binaries.
`--calibrate` runs the design's calibration list (9.2) on fixtures in
tests/phase2/calib/ and prints `calibration: cases=N as-expected=N`.
"""
import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import phase2_inventory as inv  # noqa: E402  (strip_c: one C-comment grammar)

# The no-int-source mechanism ended at R1.3. Its static calibration uses
# the exact last no-producer source; current runtime safety is the MAP/ASan gate.
STATIC_INT_SOURCE_REF = '0c43ec88ca8915f9d365e3e63549cb1e322c76d3'
ROUNDS = ['R1.1', 'R1.2', 'R1.3', 'R1.4', 'R1.5',
          'R1.6a', 'R1.6b', 'R1.6c', 'R1.6d', 'R1.6e', 'R1.6f', 'R1.6g', 'R1.6z', 'R1.7', 'R1.8',
          'R2.1', 'R2.2', 'R2.3', 'R2.4', 'R2.5', 'R2.6', 'R3']
# Gates every mode runs: the token gate (a landed round's deleted tokens stay
# deleted) and the inventory's own verdict, which includes the committed
# docs/design/phase2-inventory.txt being exactly the generated one (#1804).
EVERY_MODE = ('tokens', 'inventory')
MECHANICAL = {
    'R1.1': ('int-source', 'slot-test', 'corpus-diff', 'smi-trap'),
    'R1.2': ('int-source', 'slot-test', 'corpus-diff', 'smi-trap'),
    'R1.6a': ('reader-test', 'builtins-table'),
    'R1.6e': ('builtins-table',),
    'R1.6f': ('builtins-table',),
    'R1.6z': ('builtins-table', 'bridge-deletion-compile'),
    'R2.1': ('slot-test', 'corpus-diff'),
}
ITEMS = ['N%d' % i for i in range(1, 15)] + ['N4b', 'A', 'B', 'T1', 'O1', 'O2', 'O3', 'O4']
# design 2.7: the tokens each round deletes. A later round adds its list here
# in the commit that deletes them (R1.6's bridge, 21 tokens, with R1.6z).
DELETED_TOKENS = {
    'R1.1': ['slot_is_num', 'slot_is_numeric', 'SLOT_NUM_RAW', 'slot_from_num', 'slot_as_double'],
    'R1.2': ['VAL_NUM', 'VAL_NUM_RAW', 'VAL_NUM_OFFSET', 'num_'],
    'R1.3': ['eigs_int_unwired'],
    'R1.6z': ['eigs_num_arg', 'eigs_num_arg_slow', 'eigs_list_num', 'eigs_elem_num',
               'eigs_opt_num', 'eigs_slot_num', 'eigs_slot_elem_num', 'eigs_slot_opt_num',
               'buf_num_arg', 'make_num', 'make_num_permanent', 'list_set_num',
               'list_append_num', 'list_rewrite_num', 'dict_value_set_num',
               'dict_value_rewrite_num', 'list_get_num', 'dict_value_get_num',
               'finite_num_to_byte', 'buffer_read_byte', 'buffer_read_num'],
    'R2.2': ['num_guard', 'num_guard_named', 'EIGS_NUM_MAX'],
}
# design 2.1: the canonicalizing writers convert an existing VAL_INT, so they
# are the only runtime callers of an int writer allowed once VAL_INT exists
# (R1.2). In R1.1 no VAL_INT exists, so no runtime code may call one at all.
INT_SOURCE_ALLOWED = {
    'R1.1': set(),
    'R1.2': {'eigs_container_slot', 'eigs_slot_adopt', 'eigs_slot_store_owned',
             'eigs_slot_store_borrow', 'slot_from_value'},
}
# The SMI tag's own definitions, the only code that may name TAG_SMI or spell
# its bits: a producer that writes the bits itself calls no writer, so a scan
# of writer names never sees it (the R1.1 critic's P3 and P5).
SMI_TAG_HOMES = {('value_slot.h', '#define TAG_SMI'), ('value_slot.h', '#define SLOT_SMI_TRAP'),
                 ('value_slot.h', 'slot_is_smi'), ('value_slot.h', 'slot_from_int')}
# TAG_SMI, or a literal whose top 16 bits are the tag: 0xFFFA itself (a tag
# compare) or a 16-digit 0xFFFA............ (the full tag word).
SMI_BITS_RE = re.compile(r'\bTAG_SMI\b|\b0[xX][fF]{3}[aA](?:[0-9a-fA-F]{12})?[uUlL]*\b')
WITNESS_KINDS = {'none', 'leaf', 'leaf-gen', 'fn', 'fn-stop', 'osr', 'osr-stop'}
TIERS = ['off', 'default', 'osr', 'trace']
HOT_HDR = re.compile(r'^chunk\s+exec\s+jit\s+pct\s+adv\s+len\s+nat%\s+bked\s+osr\s+oadv\s+oent\s+stop$')


def rindex(r):
    return ROUNDS.index(r)


def read_text(path, **kw):
    with open(path, encoding='utf-8', **kw) as f:
        return f.read()


def write_text(path, text):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


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
    lines = read_text(path).split('\n')
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
    for line in read_text(path).split('\n'):
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


def builtin_landed(path=None):
    """Use the table checker's declaration parser; one grammar for both gates."""
    module_path = os.path.join(ROOT, 'tests/phase2/builtins/make_table.py')
    spec = importlib.util.spec_from_file_location('phase2_builtin_table', module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.read_landed(path or os.path.join(ROOT, 'tests/phase2/builtins_landed.txt'))


def derive_through(map_rows, rows_dir=None, landed=None):
    """Last complete round before a gap, with diagnostics for partial rounds.

    R1.6b..z need their table declaration as well as every MAP row file.
    R1.6a migrates no builtin and need not be declared; its gates always run
    in CI. An explicit a declaration can select its mechanical round.
    Other rounds retain the existing all-files rule; rowless non-R1.6 rounds
    do not select themselves. This function is also the CI entry point.
    """
    rows_dir = rows_dir or os.path.join(ROOT, 'tests/phase2/rows')
    landed = set(builtin_landed() if landed is None else landed)
    have = {}
    for row in map_rows:
        if row['kind'] == 'row' and row['round']:
            have.setdefault(row['round'], []).append(
                (row['id'], bool(row_file(rows_dir, row['id']))))
    through, complete, diagnostics = None, True, []
    for rnd in ROUNDS:
        entries = have.get(rnd, [])
        if rnd == 'R1.6a' and rnd not in landed:
            continue
        declared_round = rnd.startswith('R1.6')
        if not entries and not declared_round:
            continue
        got = [rid for rid, exists in entries if exists]
        ready = len(got) == len(entries) and (not declared_round or rnd in landed)
        if complete and ready:
            through = rnd
            continue
        complete = False
        if got:
            diagnostics.append('%s has %d of %d row files (%s): not checked until all land%s' % (
                rnd, len(got), len(entries), ' '.join(got),
                '; table round is undeclared' if declared_round and rnd not in landed else ''))
    return through, diagnostics


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


HOT_TITLE = re.compile(r'^=== Hot chunks \(top (\d+) of (\d+)\) ===$')


def hot_rows(err):
    """The EIGS_JIT_HOT table, read against its own shape: the title declares
    N rows; the column header, exactly N twelve-column rows and the
    `native-byte share` line follow. Anything else is an instrument failure
    (None), never a shorter table."""
    lines = [l.strip() for l in err.split('\n')]
    titles = [k for k, l in enumerate(lines) if HOT_TITLE.match(l)]
    if len(titles) != 1:
        return None
    t = titles[0]
    want = int(HOT_TITLE.match(lines[t]).group(1))
    if t + 3 + want >= len(lines) or not lines[t + 1].startswith('total chunk entries:') \
            or not HOT_HDR.match(lines[t + 2]):
        return None
    rows = {}
    for l in lines[t + 3:t + 3 + want]:
        w = l.split()
        if len(w) != 12 or not w[1].isdigit() or w[0] in rows:
            return None
        rows[w[0]] = dict(exec=int(w[1]), jit=w[2], adv=w[4], len=int(w[5]), osr=w[8],
                          oadv=int(w[9]), oent=int(w[10]), stop=w[11])
    if not lines[t + 3 + want].startswith('native-byte share'):
        return None
    return rows


def compiled(err):
    m = re.search(r'\[jit\] scanned=\d+ compiled=(\d+)', err)
    return int(m.group(1)) if m else -1


def bytecode(text, chunk):
    """offset -> opcode for <chunk> from EIGS_DUMP_BC. The chunk's header must
    occur exactly once and its offsets must start at 0 and rise; otherwise {}
    (an instrument failure, which the witness reports)."""
    ops, cur, headers, last = {}, None, 0, -1
    for l in text.split('\n'):
        m = re.match(r'^=== (\S+) \((\S+?), (\d+) bytes', l)
        if m:
            cur = m.group(2)
            headers += cur == chunk
            continue
        m = re.match(r'^(\d{4}) \[L\d+\] (\S+)', l)
        if m and cur == chunk:
            off = int(m.group(1))
            if off <= last or (last < 0 and off != 0):
                return {}
            ops[off] = m.group(2)
            last = off
    return ops if headers == 1 else {}


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
            # EIGS_DUMP_BC writes to stderr; the program's own stdout is
            # never read as a dump line (the R1.1 critic's class)
            _, _, derr = run(binary, path, dict(TIER_ENV[tier], EIGS_DUMP_BC='1'), scratch)
            ops = bytecode(derr, c)
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
    ctl_n = ctl_both = witnessed = ctl_witnessed = ctl_vacuous = 0
    for r, p, h in todo:
        want = read_text(p.rsplit('.', 1)[0] + '.out')
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
            # A control may claim a real tier too. Its preserved stdout is
            # insufficient evidence that a JIT/leaf arm actually ran.
            if r['witness']['kind'] != 'none' and all(passes[t]['branch'][0] for t in tiers):
                holds, ev = witness(branch, p, r['witness'], scratch)
                if holds:
                    ctl_witnessed += 1
                    out('  CONTROL-WITNESS %s %s holds [%s]' % (r['id'], r['witness']['kind'], ev))
                else:
                    ctl_vacuous += 1
                    out('  CONTROL-VACUOUS %s %s [%s]' % (r['id'], r['witness']['kind'], ev))
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
    out('controls_witnessed=%d controls_vacuous=%d' % (ctl_witnessed, ctl_vacuous))
    rows_ok = all(c['examined'] == c['tag_fail'] == c['branch_pass'] > 0 and c['vacuous'] == 0
                  for c in cnt.values())
    return (not bad, rows_ok, ctl_n == ctl_both and ctl_vacuous == 0, len(landed), cnt, witnessed)


# ---- mechanical gates ----------------------------------------------------------
def code_text(path):
    return inv.strip_c(read_text(path, errors='replace'))


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


def int_source(src, out, through='R1.1'):
    """The static half of "no int before R1.3": no runtime call of
    slot_from_int / make_int outside the round's allowed writers; make_int is
    not defined; slot_from_int is defined exactly once; and nothing outside the
    tag's own definitions names TAG_SMI or spells its bits. The dynamic half
    is the smi-trap build (value_slot.h EIGS_SMI_TRAP)."""
    allowed = INT_SOURCE_ALLOWED[through]
    files = inv.source_files(src)   # the tracked sources (a generated header is not one)
    defs = {'slot_from_int': 0, 'make_int': 0}
    calls, bad, tags, homes = [], [], [], set()
    for p in files:
        rel = os.path.basename(p)
        text = code_text(p)
        scope = inv.scopes_for(text, rel)
        for ln, line in enumerate(text.split('\n'), 1):
            for m in re.finditer(r'\b(slot_from_int|make_int)\s*\(', line):
                fn = scope[ln].split('/')[0]
                name = m.group(1)
                if fn == '<file scope>' or fn == name:
                    defs[name] += 1     # a definition or a prototype
                    continue
                calls.append((rel, ln, fn, name))
                if fn not in allowed:
                    bad.append('%s:%d: %s calls %s' % (rel, ln, fn, name))
            for m in SMI_BITS_RE.finditer(line):
                fn = scope[ln].split('/')[0]
                if (rel, fn) in SMI_TAG_HOMES:
                    homes.add((rel, fn))
                    continue
                tags.append('%s:%d: %s spells the SMI tag (%s)' % (rel, ln, fn, m.group(0)))
    for b in bad:
        out('  INT-SOURCE %s: no int may be produced before R1.3' % b)
    for t in tags:
        out('  INT-SOURCE %s outside its definitions: a producer that writes the bits itself' % t)
    if defs['make_int']:
        out('  INT-SOURCE make_int is defined before R1.3')
    if defs['slot_from_int'] != 1:
        out('  INT-SOURCE slot_from_int is defined %d times, want 1 (did the scan find it?)'
            % defs['slot_from_int'])
    if homes != SMI_TAG_HOMES:
        out('  INT-SOURCE the tag definitions found %d of %d homes (%s missing): the scan is blind'
            % (len(homes), len(SMI_TAG_HOMES), sorted(SMI_TAG_HOMES - homes)))
    out('int-source: through=%s files=%d slot_from_int_defs=%d make_int_defs=%d calls=%d '
        'outside_writers=%d tag_homes=%d/%d tag_spellings_outside=%d' % (
            through, len(files), defs['slot_from_int'], defs['make_int'], len(calls), len(bad),
            len(homes), len(SMI_TAG_HOMES), len(tags)))
    return (bool(files) and not bad and not tags and not defs['make_int']
            and defs['slot_from_int'] == 1 and homes == SMI_TAG_HOMES)


def tool(cmd, out, tail_re, env=None):
    """Run a gate tool; echo the lines matching tail_re. Its verdict is its
    exit code, and a tool that writes to stderr fails here with its words:
    its stdout is read beside nothing else (the R1.1 critic's class)."""
    p = subprocess.run(cmd, cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True,
                       env=dict(os.environ, **(env or {})))
    text = p.stdout.decode('utf-8', 'replace')
    err = p.stderr.decode('utf-8', 'replace')
    for l in text.split('\n'):
        if re.match(tail_re, l):
            out('  ' + l)
    who = next((os.path.basename(a) for a in cmd if a.endswith(('.py', '.sh'))), cmd[0])
    for l in err.split('\n'):
        if l:
            out('  STDERR %s: %s' % (who, l))
    return p.returncode == 0 and not err, text


INVENTORY_TAIL = r'^(FAIL: |UNCLASSIFIED: |slot classifiers: |examined=|phase2-inventory: )'


def inventory_gate(out, extra=()):
    """The inventory's own verdict, under -W error, with --check: every slot
    classifier has a reviewed disposition and the committed inventory file is
    exactly the generated one. PASS only for rc 0, no stderr, and a last line
    `phase2-inventory: PASS`."""
    ok, text = tool([sys.executable, '-W', 'error', os.path.join(ROOT, 'tools/phase2_inventory.py'), '--check']
                    + list(extra), out, INVENTORY_TAIL)
    lines = [l for l in text.split('\n') if l]
    return ok and lines[-1:] == ['phase2-inventory: PASS']


DIFF_TAIL = (r'^(corpus-diff: (seed pin|baseline|branch|files|examined|RESTRICTED|PASS|FAIL)|DIFF|DELETED|NEW|NONDET|'
             r'REPLAYED|BOTH-|SAME-NONZERO|UNPINNED|INCOMPLETE|UNDECLARED|STALE|LEDGER|CAPPED)')


def every_mode(through, out):
    res = {'tokens': token_gate(ROOT, through, out), 'inventory': inventory_gate(out)}
    for g in EVERY_MODE:
        out('gate %s: %s' % (g, 'PASS' if res[g] else 'FAIL'))
    return all(res[g] for g in EVERY_MODE)


def mechanical(through, baseline, branch, out, smi_trap=None, tag=None):
    res = {}
    for g in MECHANICAL[through]:
        if g == 'int-source':
            res[g] = int_source(os.path.join(ROOT, 'src'), out, through)
        elif g == 'slot-test':
            res[g], _ = tool(['bash', 'tests/phase2/slot_layer.sh', 'release'], out,
                             r'^(slot-layer|slot-layer-population|slot-layer-test: (examined|FAIL))')
        elif g == 'corpus-diff':
            if not baseline:
                out('  corpus-diff: a mechanical round needs --baseline <the binary from before it>')
                res[g] = False
            else:
                res[g], _ = tool(['bash', 'tools/phase2_corpus_diff.sh', baseline, branch], out, DIFF_TAIL)
        elif g == 'smi-trap':
            # the dynamic half of the int-source check: the corpus on a build
            # where every slot classifier aborts on an SMI (make smi-trap)
            if not baseline or not smi_trap:
                out('  smi-trap: %s needs --baseline and --smi-trap <a `make smi-trap` binary>' % through)
                res[g] = False
            else:
                res[g], _ = tool(['bash', 'tools/phase2_corpus_diff.sh', baseline, smi_trap], out, DIFF_TAIL)
        elif g == 'reader-test':
            res[g], text = tool(['bash', 'tools/phase2_readers.sh', 'release'], out,
                                 r'^phase2-readers: ')
            res[g] = res[g] and len(re.findall(r'^phase2-readers: PASS variant=release checks=[1-9][0-9]*$',
                                               text, re.M)) == 1
        elif g == 'builtins-table':
            if not tag:
                out('  builtins-table: needs the tag binary')
                res[g] = False
            else:
                res[g], text = tool(['bash', 'tools/phase2_builtins.sh', tag, branch], out,
                                     r'^phase2-builtins: ')
                res[g] = res[g] and len(re.findall(
                    r'^phase2-builtins: PASS rows=[1-9][0-9]* landed=\S+ migrated=[0-9]+ unchanged=[0-9]+$',
                    text, re.M)) == 1
        elif g == 'bridge-deletion-compile':
            # token_gate checks the deleted vocabulary in both src and tests;
            # a normal build proves no remaining caller depends on an alias.
            res[g], _ = tool(['make', '--no-print-directory', 'build'], out, r'.*')
        out('mechanical %s: %s' % (g, 'PASS' if res[g] else 'FAIL'))
    return all(res.values()) and bool(res)


# ---- the plan-level checks -------------------------------------------------------
def plan_checks(map_rows, bad, out):
    for item in ITEMS:
        if not any(r['item'] == item for r in map_rows if r['kind'] != 'control'):
            bad.append('item %s has no row in the MAP' % item)
    arms, lines, inside = {}, read_text(os.path.join(ROOT, 'docs/design/phase2-inventory.txt')).split('\n'), False
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
    always_ok = every_mode(args.through, out)
    mech_ok = None
    if args.through in MECHANICAL:
        mech_ok = mechanical(args.through, args.baseline, args.branch, out, args.smi_trap, args.tag)
    if landed == 0:
        if mech_ok is None:
            out('  ZERO-ROWS: %s has no landed row and no mechanical gates' % args.through)
        verdict = bool(mech_ok) and pop_ok and not bad and ctl_ok and always_ok
    else:
        verdict = rows_ok and pop_ok and not bad and ctl_ok and mech_ok is not False and always_ok
    out('phase2-check: %s' % ('PASS' if verdict else 'FAIL'))
    return 0 if verdict else 1


# ---- calibration (design 9.2, one-time) -------------------------------------------
def calibrate(args, out):
    cal = os.path.join(ROOT, 'tests/phase2/calib')
    map_rows, bad = parse_map(os.path.join(cal, 'MAP.md'))
    results = []
    # Keep early-round calibration meaningful after the first int producers
    # exist. Export only tracked src bytes from the pinned R1.2 checkpoint.
    historical = tempfile.mkdtemp(prefix='eigs-p2-int-source-r12-')
    _PLANT_DIR.append(historical)
    try:
        archive = subprocess.run(['git', '-C', ROOT, 'archive', STATIC_INT_SOURCE_REF, 'src'],
                                 capture_output=True, check=True)
        subprocess.run(['tar', '-x', '-C', historical], input=archive.stdout, check=True)
    except subprocess.CalledProcessError as error:
        out('phase2-check: FAIL: historical R1.2 int-source export failed: %s' % error)
        return 2
    historical_src = os.path.join(historical, 'src')
    out('calibration: historical-int-source=%s (static only; dynamic no-SMI mode retired at R1.3)' %
        STATIC_INT_SOURCE_REF)

    def case(name, got, want, detail=None):
        """One calibration case. An UNEXPECTED case prints the gate's own
        output (`detail`, its last 40 lines with the elision counted), so a
        failure on another machine says why (the R1.1 CI lane printed only
        `got False`)."""
        ok = got == want
        results.append(ok)
        out('CAL %-58s want %-28s got %-28s %s' % (name, want, got, 'ok' if ok else 'UNEXPECTED'))
        if not ok:
            shown = [l for l in (detail or []) if l.strip()]
            if len(shown) > 40:
                out('    | ... %d earlier line(s) of the gate\'s output' % (len(shown) - 40))
            for l in shown[-40:]:
                out('    | ' + l)
            if not shown:
                out('    | (this case runs no gate with output of its own)')

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
    case('fixture MAP parses', not bad and len(map_rows) > 0, True, detail=bad)
    (pop, rows_ok, _, n, cnt, wit), lines = sub(map_rows, honest, log=out)
    case('honest rows: every tier tag_fail == branch_pass == examined', rows_ok, True, detail=lines)
    case('honest rows: every witness holds', wit, sum(r['witness']['kind'] != 'none'
                                                       for r in map_rows if r['id'] in honest), detail=lines)
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, honest, tag=args.branch)
    case('the branch passed as the tag too: branch_pass=0?', cnt['default']['tag_fail'], 0, detail=lines)
    case('... and the check fails', rows_ok, False, detail=lines)
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, honest, branch=args.tag)
    case('the tag passed as the branch: branch_pass', cnt['default']['branch_pass'], 0, detail=lines)
    victim = honest[0]

    def corrupt(rd):
        with open(os.path.join(rd, victim + '.out'), 'a') as f:
            f.write('corrupted\n')
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, honest, mutate=corrupt)
    case('a corrupted .out fails, naming the row', (rows_ok, any(
        ('BRANCH-FAIL %s ' % victim) in l for l in lines)), (False, True), detail=lines)
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, [])
    case('an empty rows directory: examined=0 fails', (rows_ok, cnt['default']['examined']), (False, 0), detail=lines)

    def drop(rd):
        os.remove(os.path.join(rd, victim + '.eigs'))
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, honest, mutate=drop)
    case('a MAP id with no file fails', (pop, any('has no file' in l for l in lines)), (False, True), detail=lines)

    def stray(rd):
        shutil.copy(os.path.join(rd, victim + '.eigs'), os.path.join(rd, 'stray.row.eigs'))
    (pop, rows_ok, _, n, cnt, _), lines = sub(map_rows, honest, mutate=stray)
    case('a file with no MAP id fails', (pop, any('stray.row.eigs has no MAP id' in l for l in lines)),
         (False, True), detail=lines)
    for r in map_rows:
        if r['id'].endswith('-plant'):
            (pop, rows_ok, _, n, cnt, wit), lines = sub(map_rows, [r['id']])
            case('plant %s: vacuous, named' % r['id'], (cnt['default']['vacuous'], any(
                ('VACUOUS %s ' % r['id']) in l for l in lines)), (1, True), detail=lines)
    # the plan-level checks against a mutated copy of the real MAP
    real, rbad = parse_map(os.path.join(ROOT, 'tests/phase2/MAP.md'))
    lines = []
    plan_checks(real, list(rbad), lines.append)
    pb = []
    plan_checks(real, pb, quiet)
    case('plan checks on the real MAP pass', (rbad, pb), ([], []), detail=pb)
    pb = []
    plan_checks([r for r in real if r['item'] != 'N4b'], pb, quiet)
    case('a MAP with no N4b row fails, naming N4b', any('item N4b' in b for b in pb), True, detail=pb)
    pb = []
    n_arms = plan_checks([dict(r, ops=[]) for r in real], pb, quiet)
    case('a MAP whose rows exercise no arm fails per arm (%d arms)' % n_arms,
         sum('numeric arm' in b for b in pb) == n_arms > 0, True, detail=pb)
    pb = []
    plan_checks([r for r in real if r['round'] != 'R2.3'], pb, quiet)
    case('a round with neither rows nor gates fails', any('round R2.3' in b for b in pb), True, detail=pb)
    # the int-source check against a planted production call
    with tempfile.TemporaryDirectory(prefix='eigs-p2cal-') as d:
        shutil.copytree(historical_src, os.path.join(d, 'src'), ignore=c_sources_only)
        p = os.path.join(d, 'src', 'trace.c')
        text = read_text(p)
        anchor = '        *out = slot_from_f64((double)count);'
        n_anchor = text.count(anchor)
        write_text(p, text.replace(anchor, '        *out = slot_from_int(count);'))
        lines = []
        ok = int_source(os.path.join(d, 'src'), lines.append)
        case('int-source plant (slot_from_int(count) in trace.c) applied once', n_anchor, 1)
        case('int-source plant: the check fails, naming the caller', (ok, any(
            'trace.c' in l and 'calls slot_from_int' in l for l in lines)), (False, True), detail=lines)
    lines = []
    # at R1.2: from R1.2 the canonicalizing writers may convert a VAL_INT
    # (design 8), and the branch is past R1.1
    case('int-source on pinned R1.2 source passes',
         int_source(historical_src, lines.append, 'R1.2'), True, detail=lines)
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
             (token_gate(d, 'R1.1', lines.append), any('slot_is_num' in l for l in lines)), (False, True), detail=lines)
    # the int-source plants of the R1.1 critic, static half on the historical source
    for name, edits in INTSRC_PLANTS:
        with tempfile.TemporaryDirectory(prefix='eigs-p2cal-') as d:
            shutil.copytree(historical_src, os.path.join(d, 'src'), ignore=c_sources_only)
            counts = []
            for f, old, new in edits:
                p = os.path.join(d, 'src', f)
                text = read_text(p)
                counts.append(text.count(old))
                write_text(p, text.replace(old, new))
            if counts != [1] * len(edits):
                case('%s: every edit applied once' % name, counts, [1] * len(edits))
                continue
            for through in ('R1.1', 'R1.2'):
                lines = []
                ok = int_source(os.path.join(d, 'src'), lines.append, through)
                want = not (name.startswith('P4') and through == 'R1.2')   # R1.2 allows that writer
                case('%s, static half at %s: %s' % (name, through, 'fails, naming it' if want
                                                   else 'passes (the dynamic half owns it)'),
                     (not ok, any('INT-SOURCE' in l for l in lines)) if want else ok,
                     (True, True) if want else True, detail=lines)
    # the corpus differential's plants: A and B are wrapper branches, D a build
    base = args.branch
    files = ['tests/test_dispatch.eigs', 'tests/test_bool.eigs']
    with tempfile.TemporaryDirectory(prefix='eigs-p2cal-') as d:
        a = wrapper_tree(os.path.join(d, 'A'), args.branch, files,
                         'case "$*" in *test_dispatch.eigs*) "$REAL" "$@"; rc=$?; echo "PLANTED A"; exit $rc ;; esac\n'
                         'exec "$REAL" "$@"')
        rc, text, v = diff_restricted(base, a, files)
        case('differential plant A (a deterministic file prints one more line): DIFF, control same',
             (rc, v.get('tests/test_dispatch.eigs'), v.get('tests/test_bool.eigs'), v.get('<stderr>')),
             (3, 'DIFF', 'same', None), detail=text.splitlines())
        for phase in (0, 1):
            bdir = os.path.join(d, 'B%d' % phase)
            bw = wrapper_tree(bdir, args.branch, files,
                              'case "$*" in *test_dispatch.eigs*) if [ $(((N + %d) %% 2)) -eq 0 ]; then\n'
                              '  "$REAL" "$@"; rc=$?; echo "PLANTED B"; exit $rc; fi ;; esac\nexec "$REAL" "$@"' % phase)
            rc, text, v = diff_restricted(base, bw, files)
            case('differential plant B, phase %d (wrong on alternate runs): DIFF, never NONDET' % phase,
                 (rc, v.get('tests/test_dispatch.eigs'), v.get('tests/test_bool.eigs'), v.get('<stderr>')),
                 (3, 'DIFF', 'same', None), detail=text.splitlines())
    # the run conditions and the nonzero ledger (the second R1.1 critic):
    # fake trees that run the real branch binary with one input changed
    with tempfile.TemporaryDirectory(prefix='eigs-p2cal-') as d:
        files = ['tests/test_numeric_guard.eigs', 'tests/test_buffer_nonfinite_read.eigs', 'tests/test_bool.eigs']
        rc, text, v = diff_restricted(base, args.branch, files)
        case('unplanted branch, conditioned files included: all same, nothing undeclared',
             (rc,) + tuple(v.get(f) for f in files) + (v.get('<stderr>'),
             bool(re.search(r' incomplete=0 undeclared=0 stale=0 ledger_refused=0 ', text))),
             (3, 'same', 'same', 'same', None, True), detail=text.splitlines())
        cut = wrapper_tree(os.path.join(d, 'cut'), args.branch, files[:1] + files[2:], 'exec "$REAL" "$@"',
                           {'tests/suite_program_env.txt':
                            lambda t: re.sub(r'(?m)^test_numeric_guard\.eigs .*\n', '', t)})
        rc, text, v = diff_restricted(base, cut, files[:1] + files[2:])
        case('a policy row removed: its file exits early on both, UNDECLARED-NONZERO',
             (rc, 'UNDECLARED-NONZERO tests/test_numeric_guard.eigs rc=1' in text,
              ' undeclared=1 ' in text, v.get('<stderr>')), (3, True, True, None), detail=text.splitlines())
        stale = wrapper_tree(os.path.join(d, 'stale'), args.branch, files[2:], 'exec "$REAL" "$@"',
                             {'tests/phase2/corpus_nonzero.txt':
                              lambda t: t + 'tests/test_bool.eigs 1 planted: test_bool completes\n'})
        rc, text, v = diff_restricted(base, stale, files[2:])
        case('a ledger row for a file that completes: STALE',
             (rc, 'STALE tests/test_bool.eigs:' in text, ' stale=1 ' in text), (3, True, True), detail=text.splitlines())
        inc = wrapper_tree(os.path.join(d, 'inc'), args.branch, ['tests/test_assert_fail.eigs'], 'exec "$REAL" "$@"',
                           {'tests/suite_program_env.txt': lambda t: t + 'test_assert_fail.eigs EIGS_STRICT=0\n',
                            'tests/phase2/corpus_nonzero.txt':
                            lambda t: re.sub(r'(?m)^tests/test_assert_fail\.eigs .*\n', '', t)})
        rc, text, v = diff_restricted(base, inc, ['tests/test_assert_fail.eigs'])
        case('a conditioned file that does not complete: INCOMPLETE, never compared',
             (rc, v.get('tests/test_assert_fail.eigs'), ' incomplete=1 ' in text), (3, 'INCOMPLETE', True), detail=text.splitlines())
    # the inventory gate (#1804): a classifier with no reviewed disposition,
    # and a committed inventory that is not the generated one
    with tempfile.TemporaryDirectory(prefix='eigs-p2cal-') as d:
        shutil.copytree(os.path.join(ROOT, 'src'), os.path.join(d, 'src'), ignore=c_sources_only)
        os.makedirs(os.path.join(d, 'docs/design'))
        for f in ('docs/design/phase2-numbers.md', 'docs/design/phase2-inventory.txt'):
            shutil.copy(os.path.join(ROOT, f), os.path.join(d, f))
        inv_args = ['--src', os.path.join(d, 'src'), '--doc', os.path.join(d, 'docs/design/phase2-numbers.md'),
                    '--out', os.path.join(d, 'docs/design/phase2-inventory.txt')]
        lines = []
        case('inventory gate on an unchanged copy passes', inventory_gate(lines.append, inv_args), True, detail=lines)
        inv_path = os.path.join(d, 'docs/design/phase2-inventory.txt')
        committed = read_text(inv_path)
        write_text(inv_path, committed.replace('dispositions=', 'dispositions=0', 1))
        lines = []
        case('a committed inventory that is not the generated one: the gate fails, saying stale',
             (inventory_gate(lines.append, inv_args), any('is stale' in l for l in lines)), (False, True), detail=lines)
        write_text(inv_path, committed)
        with open(os.path.join(d, 'src', 'vm.c'), 'a') as f:
            f.write('\nint critic_new_reader(Value *v) {\n    EigsSlot s = slot_from_heap(v);\n'
                    '    return slot_is_bool(s) ? 1 : (slot_is_null(s) ? 2 : 0);\n}\n')
        lines = []
        case('an unreviewed slot classifier (critic_new_reader): the gate fails, naming it',
             (inventory_gate(lines.append, inv_args),
              any('`vm.c:critic_new_reader` has no disposition row' in l for l in lines)), (False, True), detail=lines)
    if args.build_plants:
        args.planted_leaf_scan = build_plant('leaf-scan', out)
        args.planted_leaf_mul = build_plant('leaf-mul', out)
        args.planted_random_int = build_plant('random-int', out)
        args.planted_value_eq = build_plant('value-eq-raw', out)
    for label, b, files, want in (
            ('plant C (buffer equality reads raw elements), release build', args.planted_value_eq,
             ['tests/test_numeric_guard.eigs', 'tests/test_bool.eigs'], ('DIFF', 'same')),):
        if not b:
            out('CAL %-58s NOT RUN (no binary; --build-plants builds it)' % label)
            results.append(False)
            continue
        rc, text, v = diff_restricted(base, b, files)
        case('differential %s: DIFF where its conditioned file reaches it' % label,
             (rc,) + tuple(v.get(f) for f in files) + (v.get('<stderr>'),), (3,) + want + (None,), detail=text.splitlines())
    if args.planted_random_int:
        # test_system.eigs asserts random_int's bounds over 300 draws, so it
        # sees the plant whatever the seed; test_optimize.eigs prints a search
        # driven by random_int and is comparable live only because the seed
        # is pinned (unpinned, its baseline disagrees with itself and a tape
        # would serve the baseline's draws): this case calibrates the pin.
        files = ['tests/test_system.eigs', 'tests/test_optimize.eigs', 'tests/test_bool.eigs']
        rc, text, v = diff_restricted(base, args.planted_random_int, files)
        case('differential plant D (random_int answers lo+1..hi+1): both files DIFF live',
             (rc,) + tuple(v.get(f) for f in files) + (v.get('<stderr>'),), (3, 'DIFF', 'DIFF', 'same', None), detail=text.splitlines())
    else:
        out('CAL %-58s NOT RUN (no --planted-random-int binary; --build-plants builds it)' % 'plant D')
        results.append(False)
    # P4/B2's dynamic no-SMI plants are retired: ints are legitimate at
    # R1.3 and the trap mode is intentionally no-op. Their static source
    # plants above still calibrate the historical R1.1/R1.2 mechanism.
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
                 (cnt['default']['vacuous'] > 0, rows_ok), (True, False), detail=lines)
        else:
            case('L row vs a scratch build whose leaf MUL adds 1: trace differs',
                 (cnt['trace']['branch_pass'], cnt['default']['branch_pass'] > 0, rows_ok), (len(leaf), False, False), detail=lines)
    n_ok = sum(results)
    out('calibration: cases=%d as-expected=%d unexpected=%d' % (len(results), n_ok, len(results) - n_ok))
    return 0 if results and n_ok == len(results) else 1


# The calibration's planted builds: (file, original, planted, make target).
# Each is `git archive HEAD` into a scratch tree, one exact-once replacement,
# plain make; the binary is that tree's src/eigenscript.
BUILD_PLANTS = {
    # design 9.2: a leaf scanner that never admits a chunk; a leaf MUL that adds 1
    'leaf-scan': ('src/chunk.c', '    c->leaf_accessor = 0;\n    if (c->param_count > LEAF_ACCESSOR_MAX_DEPTH) return;',
                  '    c->leaf_accessor = 0;\n    return;   /* PLANT: the leaf scanner never admits a chunk */\n'
                  '    if (c->param_count > LEAF_ACCESSOR_MAX_DEPTH) return;', 'build'),
    'leaf-mul': ('src/vm.c', '                r = a * b;\n', '                r = a * b + 1;   /* PLANT */\n', 'build'),
    # the R1.1 critic's plant D: random_int answers lo+1..hi+1
    'random-int': ('src/builtins.c', 'make_num(lo_i + (eigs_random_long() % (int64_t)span))',
                   'make_num(lo_i + 1 + (eigs_random_long() % (int64_t)span))', 'build'),
    # the second R1.1 critic's plant C: equality of two buffers reads raw
    # elements (no read normalisation); the suite's [42c] goes red on it
    'value-eq-raw': ('src/eigenscript.c', '        case VAL_BUFFER: {\n            if (a->data.buffer.count != b->data.buffer.count) return 0;\n            for (int i = 0; i < a->data.buffer.count; i++) {\n                double av = buffer_read_num(a, i);\n                if (g_has_error) return 0;\n                double bv = buffer_read_num(b, i);\n',
                     '        case VAL_BUFFER: {\n            if (a->data.buffer.count != b->data.buffer.count) return 0;\n            for (int i = 0; i < a->data.buffer.count; i++) {\n                double av = a->data.buffer.data[i];   /* CRITIC PLANT C: raw element, no read normalisation */\n                if (g_has_error) return 0;\n                double bv = b->data.buffer.data[i];\n', 'build'),

}
_PLANT_DIR = []


def build_plant(name, out):
    f, old, new, target = BUILD_PLANTS[name]
    d = tempfile.mkdtemp(prefix='eigs-p2plant-')
    _PLANT_DIR.append(d)
    subprocess.run('git -C %s archive HEAD | tar -x -C %s' % (ROOT, d), shell=True, check=True)
    p = os.path.join(d, f)
    text = read_text(p)
    if text.count(old) != 1:
        out('  PLANT %s: the original occurs %d times in %s, want 1 (BROKEN)' % (name, text.count(old), f))
        return None
    write_text(p, text.replace(old, new))
    r = subprocess.run(['make', target], cwd=d, capture_output=True)
    b = os.path.join(d, 'src', 'eigenscript')
    ok = r.returncode == 0 and os.access(b, os.X_OK)
    out('  PLANT %s built in %s (make %s): %s' % (name, d, target,
                                                 'ok' if ok else 'BROKEN (make rc=%d)' % r.returncode))
    return b if ok else None


# The R1.1 critic's int-source plants (/tmp/phase2-r11-critic/intsrc), as
# exact-once replacements in a copy of src/: (name, [(file, old, new), ...]).
_NUM_ONE = '    CASE(NUM_ONE): {\n        vm_push_slot(slot_from_f64(1.0));'
INTSRC_PLANTS = [
    ('P1 a call in builtins.c', [('builtins.c', 'Value* builtin_len(Value *arg) {',
      'static EigsSlot p1_smi(int64_t n) { return slot_from_int(n); }\nValue* builtin_len(Value *arg) {')]),
    ('P2 a header macro that calls the writer', [
        ('value_slot.h', '/* Constructors */', '/* Constructors */\n#define SLOT_SMI_OF(i) slot_from_int(i)'),
        ('vm.c', _NUM_ONE, '    CASE(NUM_ONE): {\n        vm_push_slot(SLOT_SMI_OF(1));')]),
    ('P3 raw TAG_SMI bits in vm.c', [
        ('vm.c', _NUM_ONE, '    CASE(NUM_ONE): {\n        { EigsSlot one; one.u = TAG_SMI | 1u; vm_push_slot(one); }')]),
    ('P4 a producer inside an allowed writer', [
        ('eigenscript.c', '        double n = VAL_F64_RAW(v);\n        val_decref(v);\n        return slot_from_f64(n);',
         '        double n = VAL_F64_RAW(v);\n        val_decref(v);\n        if (n == 1.0) return slot_from_int(1);\n'
         '        return slot_from_f64(n);')]),
    ('P5 a raw-bits header macro', [
        ('value_slot.h', '/* Constructors */', '/* Constructors */\n'
         '#define SLOT_SMI_BITS(i) ((EigsSlot){ .u = TAG_SMI | ((uint64_t)(i) & SLOT_PAYLOAD_MASK) })'),
        ('vm.c', _NUM_ONE, '    CASE(NUM_ONE): {\n        vm_push_slot(SLOT_SMI_BITS(1));')]),
]


def c_sources_only(d, names):
    """copytree ignore: keep directories and C sources (the int-source check
    reads nothing else), skip binaries and objects. In src/ itself, only the
    TRACKED sources (inv.source_files): a copy must look like a fresh clone,
    or a generated header such as src/lsp_stdlib_index.h makes the copy's
    inventory differ from the committed one (the R1.1 CI lane)."""
    keep = None
    if os.path.realpath(d) == os.path.realpath(os.path.join(ROOT, 'src')):
        keep = {os.path.basename(f) for f in inv.source_files(d)}
    return [n for n in names if not os.path.isdir(os.path.join(d, n)) and
            (not n.endswith(('.c', '.h')) or (keep is not None and n not in keep))]


def diff_restricted(base, branch, files):
    """The corpus differential over a restricted list (calibration only):
    (rc, stdout, {file: 'DIFF'|'same'|...}). Anything on its stderr is shown
    and recorded as the verdict '<stderr>' (the tool never writes there)."""
    with tempfile.TemporaryDirectory(prefix='eigs-p2diff-') as d:
        lst = os.path.join(d, 'files')
        write_text(lst, '\n'.join(files) + '\n')
        p = subprocess.run(['bash', os.path.join(ROOT, 'tools/phase2_corpus_diff.sh'), base, branch],
                           cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True,
                           env=dict(os.environ, PHASE2_DIFF_FILES=lst))
    text = p.stdout.decode('utf-8', 'replace')
    err = p.stderr.decode('utf-8', 'replace')
    verdicts = {}
    for l in text.split('\n'):
        m = re.match(r'^\.\. \d+/\d+ (\S+) (\S+) ', l)
        if m:
            verdicts[m.group(1)] = m.group(2)
    if err:
        for l in err.split('\n'):
            print('  STDERR phase2_corpus_diff.sh: ' + l, flush=True)
        verdicts['<stderr>'] = 'present'
    return p.returncode, text, verdicts


RUN_POLICY = ('tests/suite_program_env.sh', 'tests/suite_program_env.txt', 'tests/phase2/corpus_nonzero.txt')


def wrapper_tree(d, real, files, script, edit=None):
    """A fake branch tree: src/eigenscript runs `script` (bash, $REAL is the
    real binary, $N the per-tree invocation count), tests/ holds the files and
    the run-condition loader, its table and the nonzero ledger, each of which
    `edit` ({path: function(text) -> text}) may change."""
    os.makedirs(os.path.join(d, 'src'))
    for f in list(files) + list(RUN_POLICY):
        os.makedirs(os.path.join(d, os.path.dirname(f)), exist_ok=True)
        text = read_text(os.path.join(ROOT, f))
        write_text(os.path.join(d, f), (edit or {}).get(f, lambda t: t)(text))
    w = os.path.join(d, 'src', 'eigenscript')
    write_text(w, '#!/usr/bin/env bash\nREAL=%s\nSTATE=%s\nN=$(cat "$STATE" 2>/dev/null || echo 0)\n'
                  'echo $((N + 1)) > "$STATE"\n%s\n' % (real, os.path.join(d, 'n'), script))
    os.chmod(w, 0o755)
    return w


TAG = 'v0.46.0'


def selftest(out):
    """--selftest, a tools/selftests.txt row: the calibration runs when the
    checker changes (docs/PRINCIPLES.md 5), never on every run. The branch
    binary is this tree's src/eigenscript (the self-test job builds it first);
    the tag binary is $PHASE2_TAG_BIN, else a build of v0.46.0 from `git
    archive`; the planted binaries are built from HEAD. Plain make, one build
    at a time."""
    branch = os.path.join(ROOT, 'src', 'eigenscript')
    if not os.access(branch, os.X_OK):
        out('phase2-check: FAIL: --selftest needs a built %s (run make first)' % branch)
        return 2
    tag = os.environ.get('PHASE2_TAG_BIN')
    if not tag:
        if subprocess.run(['git', '-C', ROOT, 'rev-parse', '-q', '--verify', TAG + '^{commit}'],
                          capture_output=True).returncode != 0:
            out('phase2-check: FAIL: --selftest needs the tag %s in this clone (git fetch --tags)' % TAG)
            return 2
        d = tempfile.mkdtemp(prefix='eigs-p2tag-')
        _PLANT_DIR.append(d)
        subprocess.run('git -C %s archive %s | tar -x -C %s' % (ROOT, TAG, d), shell=True, check=True)
        r = subprocess.run(['make'], cwd=d, capture_output=True)
        tag = os.path.join(d, 'src', 'eigenscript')
        if r.returncode != 0 or not os.access(tag, os.X_OK):
            out('phase2-check: FAIL: the %s build failed (make rc=%d)' % (TAG, r.returncode))
            return 2
        out('  TAG %s built in %s' % (TAG, d))
    args = argparse.Namespace(tag=os.path.abspath(tag), branch=branch, build_plants=True,
                              planted_leaf_scan=None, planted_leaf_mul=None,
                              planted_random_int=None, planted_value_eq=None)
    return calibrate(args, out)


def main():
    if sys.argv[1:] == ['--selftest']:
        try:
            return selftest(lambda s: print(s, flush=True))
        finally:
            for d in _PLANT_DIR:
                shutil.rmtree(d, ignore_errors=True)
    ap = argparse.ArgumentParser(prog='tools/phase2_check.sh')
    ap.add_argument('--selftest', action='store_true',
                    help='the calibration with every plant built (alone: a tools/selftests.txt row)')
    ap.add_argument('tag', help='the v0.46.0 tag binary')
    ap.add_argument('branch', help='the branch binary')
    ap.add_argument('--through', default=ROUNDS[-1], choices=ROUNDS)
    ap.add_argument('--baseline', help='the binary from before a mechanical round (corpus differential)')
    ap.add_argument('--smi-trap', help='R1.1/R1.2: a `make smi-trap` build of the branch (in its own tree)')
    ap.add_argument('--map', default=os.path.join(ROOT, 'tests/phase2/MAP.md'))
    ap.add_argument('--rows', default=os.path.join(ROOT, 'tests/phase2/rows'))
    ap.add_argument('--controls', default=os.path.join(ROOT, 'tests/phase2/controls'))
    ap.add_argument('--calibrate', action='store_true')
    ap.add_argument('--planted-leaf-scan', help='calibration: a build whose leaf scanner returns early')
    ap.add_argument('--planted-leaf-mul', help='calibration: a build whose leaf MUL computes a*b+1')
    ap.add_argument('--planted-random-int', help='calibration: a build whose random_int answers lo+1..hi+1')
    ap.add_argument('--planted-value-eq', help='calibration: a build whose buffer equality reads raw elements (C)')
    ap.add_argument('--build-plants', action='store_true',
                    help='calibration: build the four active planted binaries from HEAD')
    args = ap.parse_args()
    if args.selftest:
        print('phase2-check: FAIL: --selftest takes no other argument')
        return 2
    for b in (args.tag, args.branch, args.baseline, args.smi_trap, args.planted_leaf_scan,
              args.planted_leaf_mul, args.planted_random_int, args.planted_value_eq):
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
