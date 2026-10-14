#!/usr/bin/env python3
"""#1746 Phase 1, Class C: every refusal whose failret RELEASES something
(val_decref / free / chunk_free / *_close) is exercised by a probe, under the
sanitizer build, with zero leaks.

  python3 tools/ieee_failret_coverage.py <asan-ieee binary>
  -> one row per site (EXERCISED / MISSED), then
     FAILRET_COVERAGE: release_failrets=<n> exercised=<m> leaks=<l> probes=<p> stale=<s>

SITES (derived): every EIGS_DCAST_RET / EIGS_ARG_FIN / EIGS_OPT_FIN call in the
hosted sources, as the ieee build sees them (tools/ieee_cscan.py), whose LAST
argument calls a release function. The witness is the build's own trace:
with EIGS_FAILRET_TRACE set, every taken refusal prints `FAILRET <file>:<line>`
(eigenscript.h), so a site counts only if its failure branch RAN.
PROBES: one per enclosing function (PROBES below). A site whose function has no
probe is MISSED; a probe whose function has no release site is STALE.
Leaks: each probe runs with ASAN_OPTIONS=detect_leaks=1; any AddressSanitizer
or LeakSanitizer text is counted. Exit 0 iff n > 0, exercised == n, leaks == 0,
stale == 0."""
import os, re, sys, subprocess, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ieee_cscan import hosted_sources, strip, functions, calls, line_of

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RET = {'EIGS_DCAST_RET', 'EIGS_ARG_FIN', 'EIGS_OPT_FIN'}
RELEASE = re.compile(r'\b(\w*decref|free|chunk_free|\w+_close)\s*\(')

def sites():
    out = []
    for f in hosted_sources(ROOT):
        t = strip(open(os.path.join(ROOT, f)).read())
        for n, _, lo, hi, _ in functions(t):
            for c, a, b in calls(t, lo, hi):
                if c not in RET: continue
                depth, last = 0, a + 1
                for k in range(a + 1, b):
                    ch = t[k]
                    if ch in '([{': depth += 1
                    elif ch in ')]}': depth -= 1
                    elif ch == ',' and depth == 0: last = k + 1
                if RELEASE.search(t[last:b]):
                    out.append((f, line_of(t, a), n))
    return out

def run(binary, prog, cwd, env_extra=None, src=None):
    if src is not None:
        open(os.path.join(cwd, prog), 'w').write(src)
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=1', UBSAN_OPTIONS='halt_on_error=1',
               EIGS_FAILRET_TRACE='1', SDL_AUDIODRIVER='dummy')
    env.pop('EIGS_TRACE', None); env.pop('EIGS_REPLAY', None)
    env.update(env_extra or {})
    p = subprocess.run(['timeout', '120', binary, prog], cwd=cwd, env=env,
                       capture_output=True, text=True)
    return p.stdout + p.stderr

def tape_edit(path, out, record, value):
    lines = open(path).read().split('\n')
    hits = [i for i, l in enumerate(lines) if l.startswith(f'N 0 {record}=')]
    if len(hits) != 1: raise SystemExit(f'FAIL: probe tape has {len(hits)} {record} records')
    lines[hits[0]] = f'N 0 {record}={value}'
    open(out, 'w').write('\n'.join(lines))

TRY = 'try:\n    {}\ncatch e:\n    print of e["message"]\n'
def p_sort_by(b, d):
    return run(b, 'p.eigs', d, src=TRY.format('sort_by of [[1, 2], (x) => 0 / 0]'))
def p_gather(b, d):
    return run(b, 'p.eigs', d, src=TRY.format('gather of [[[1, 2], [3, 4]], [0 / 0, 0]]'))
def p_desc(b, d):
    src = 'q is 0 / 0\n' + TRY.format('sandbox_run of [[1, [68, 1, 0, 0, 0, q], [1]], 1000]') + \
          TRY.format('sandbox_run of [[1, [40], [1], 1, q], 1000]')
    return run(b, 'p.eigs', d, src=src)
def p_read_bytes_buf(b, d):
    open(os.path.join(d, 'ten.bin'), 'w').write('0123456789')
    src = TRY.format('r is read_bytes_buf of ["ten.bin", 4]')
    o = run(b, 'p.eigs', d, {'EIGS_TRACE': 't.tape'}, src)
    tape_edit(os.path.join(d, 't.tape'), os.path.join(d, 't2.tape'), 'read_bytes_buf', 'nan')
    return o + run(b, 'p.eigs', d, {'EIGS_REPLAY': 't2.tape'})
def p_tensor_load(b, d):
    src = 'tensor_save of [[1, 2, 3], "t.bin"]\n' + TRY.format('r is tensor_load of "t.bin"')
    o = run(b, 'p.eigs', d, {'EIGS_TRACE': 't.tape'}, src)
    for i, v in enumerate(('[nan, 1]', '[1, nan]')):
        tape_edit(os.path.join(d, 't.tape'), os.path.join(d, f't{i}.tape'), 'tensor_load', v)
        o += run(b, 'p.eigs', d, {'EIGS_REPLAY': f't{i}.tape'})
    return o
def p_audio(b, d):
    src = 'audio_open of [44100, 1]\n' + TRY.format('audio_play of ([0 / 0])') + \
          TRY.format('audio_play of (buf_from_list of ([0 / 0, 0]))') + 'audio_close of null\n'
    return run(b, 'p.eigs', d, {'DISPLAY': ':99'}, src)
def p_store_catalog(b, d):
    run(b, 'mk.eigs', d, src='s is store_open of "c.db"\nstore_put of [s, "coll", {"v": 1}]\nstore_close of s\n')
    db = bytearray(open(os.path.join(d, 'c.db'), 'rb').read())
    c = db.index(b'{"coll"'); old, new = b'"root":1,', b'"root":1e999,'
    if db[c - 6] != 31: raise SystemExit('FAIL: store catalog layout changed (probe cannot patch it)')
    i = db.index(old); j = i + len(old); k = db.index(b'\x00', j); ext = len(new) - len(old)
    db2 = db[:i] + new + db[j:k] + db[k + ext:]; db2[c - 6] = 31 + ext
    open(os.path.join(d, 'c2.db'), 'wb').write(bytes(db2))
    return run(b, 'op.eigs', d, src=TRY.format('s is store_open of "c2.db"'))

PROBES = {'builtin_sort_by': p_sort_by, 'builtin_tensor_gather': p_gather,
          'vm_build_chunk_desc_body': p_desc, 'builtin_read_bytes_buf': p_read_bytes_buf,
          'builtin_tensor_load': p_tensor_load, 'audio_convert_samples': p_audio,
          'store_load_catalog': p_store_catalog}

def main():
    if len(sys.argv) != 2: raise SystemExit('usage: ieee_failret_coverage.py <asan-ieee binary>')
    binary = os.path.abspath(sys.argv[1])
    nm = subprocess.run(['nm', binary], capture_output=True, text=True).stdout
    if '__asan_init' not in nm:
        raise SystemExit(f'FAIL: {binary} is not an ASan build: leaks would be unmeasured')
    ss = sites()
    if not ss: raise SystemExit('FAIL: derived no release-failret sites')
    fns = sorted({n for _, _, n in ss})
    stale = sorted(set(PROBES) - set(fns))
    out, leaks = '', 0
    for n in sorted(PROBES):   # a stale probe still runs: its leak must still show
        d = tempfile.mkdtemp(prefix='ieee_failret.')
        o = PROBES[n](binary, d)
        out += o
        lk = len(re.findall(r'ERROR: (AddressSanitizer|LeakSanitizer)|runtime error:', o))
        leaks += lk
        if lk: print(f'LEAK/SANITIZER in probe {n}:\n' + '\n'.join(l for l in o.split('\n') if 'Sanitizer' in l or 'runtime error' in l or '#' in l[:6])[:3000])
    hit = set(re.findall(r'^FAILRET (\S+):(\d+)$', out, re.M))
    ex = 0
    for f, l, n in ss:
        ok = (f, str(l)) in hit
        ex += ok
        print(f'{"EXERCISED" if ok else "MISSED   "} {f}:{l} {n}')
    for s in stale: print(f'STALE probe: {s}')
    print(f'FAILRET_COVERAGE: release_failrets={len(ss)} exercised={ex} leaks={leaks} probes={len(PROBES)} stale={len(stale)}')
    sys.exit(0 if ex == len(ss) and leaks == 0 and not stale else 1)

main()
