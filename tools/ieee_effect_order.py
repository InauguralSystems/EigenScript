#!/usr/bin/env python3
"""#1746 Phase 1, Class A: in every hosted function, every argument refusal
(EIGS_DCAST_RET, EIGS_ARG_FIN, EIGS_OPT_FIN, or a call to a function that
contains one) precedes the first EFFECT, so a refused call leaves no trace:
no replay record taken or written, no lock, no process, no I/O, no SDL call,
no mutation of a container the function did not create.

  python3 tools/ieee_effect_order.py
  -> one VIOLATION row per check that follows an effect, then
     EFFECT_ORDER: examined=<n> builtins, effects=<m>, violations=<v>

EFFECTS (derived, not hand-picked):
  replay   every function and macro of the src/trace.h API whose name says it
           reads or writes the record stream: nondet / replay / record /
           assign (TRACE_NONDET_TAKE, TRACE_NONDET_RECORD, trace_replay_take,
           trace_nondet_value, ...);
  libc     every function declared in /usr/include/unistd.h, sys/socket.h,
           spawn.h, sys/wait.h, plus stdio.h functions taking or returning a
           FILE * (a call whose first argument is stderr/stdout is a diagnostic,
           not an effect), plus <time.h> *sleep, plus stdlib system;
  locks    any name ending in `_lock` (pthread_mutex_lock, ...) called DIRECTLY
           by the function: a callee that locks and unlocks inside itself is
           balanced and is not transitive (the allocator's stats lock,
           handle_lookup's table lock);
  SDL      any called name matching (p_)?SDL_*;
  mutation functions declared in src/eigenscript.h / src/container.h named
           <kind>_<verb>..., kind a ValType name (VAL_LIST -> list, ...) or
           buf/env, verb append/set/insert/remove/truncate/clear/push/pop/
           delete/put/drop, when the container argument is NOT a
           variable this function assigned from an allocator (make_*/
           buf_alloc*/xcalloc/xmalloc) -- a fresh output is not shared state;
  transitive every hosted function whose body calls any of the above, except
           through a FATAL function (one whose body calls abort/exit/_exit at
           its top brace level: x_oom) -- a path that cannot return.
Loops: a check and an effect inside the same loop body violate even if the
check is textually first (the next iteration's check follows the effect).
RESIDUAL (not seen): an effect written as a direct store (`buf->data[i] = x`,
`g_flag = 1`) rather than a call, and calls through function pointers.
WAIVERS: tools/ieee_effect_order_waivers.txt, one `<file>:<function> <check>
reason` row per reviewed (function, check) pair; a waived violation prints as
WAIVED, and a waiver row that matches no violation is a FAIL (stale).
Exit 0 iff examined > 0, effects > 0, violations == 0 and no stale waiver."""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ieee_cscan import hosted_sources, strip, functions, calls, line_of, match_paren

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKS = {'EIGS_DCAST_RET', 'EIGS_ARG_FIN', 'EIGS_OPT_FIN'}
MUT = re.compile(r'_(append|set|insert|remove|truncate|clear|push|pop|delete|put|drop)')
TAPE = re.compile(r'nondet|replay|record|assign', re.I)
ALLOC = re.compile(r'\b([A-Za-z_]\w*)\s*=\s*(make_\w+|buf_alloc\w*|xcalloc\w*|xmalloc\w*|\w+_new)\s*\(')

def decls(path, pred=None):
    names = set()
    try: t = strip(open(path).read())
    except OSError: return names
    for m in re.finditer(r'\b([A-Za-z_]\w*)\s*\(([^;{)]*(?:\([^)]*\)[^;{)]*)*)\)\s*(?:__THROW|__attribute|__wur|__nonnull|;|\n)', t):
        if pred is None or pred(m.group(0)): names.add(m.group(1))
    return names

def base_effects():
    eff = set()
    t = strip(open(os.path.join(ROOT, 'src/trace.h')).read())
    api = set(re.findall(r'\b(trace_\w+|TRACE_\w+|eigs_replay_\w+|eigs_trace_\w+)\s*\(', t))
    api |= set(re.findall(r'#\s*define\s+(\w+)\s*\(', t))
    eff |= {n for n in api if TAPE.search(n)}
    inc = '/usr/include'
    for h in ('unistd.h', 'x86_64-linux-gnu/sys/socket.h', 'spawn.h', 'x86_64-linux-gnu/sys/wait.h'):
        eff |= decls(os.path.join(inc, h))
    eff |= decls(os.path.join(inc, 'stdio.h'), lambda s: 'FILE' in s)
    eff |= {n for n in decls(os.path.join(inc, 'time.h')) if n.endswith('sleep')}
    eff |= {n for n in decls(os.path.join(inc, 'stdlib.h')) if n == 'system'}
    vt = strip(open(os.path.join(ROOT, 'src/eigenscript.h')).read())
    kinds = {k.lower() for k in re.findall(r'\bVAL_([A-Z_]+)\b', vt)} | {'buf', 'env'}
    mutre = re.compile(r'^(' + '|'.join(sorted(kinds)) + r')_' + MUT.pattern.lstrip('_'))
    mut = set()
    for h in ('src/eigenscript.h', 'src/container.h'):
        mut |= {n for n in decls(os.path.join(ROOT, h)) if mutre.match(n)}
    eff -= {'sysconf', 'getpid', 'getppid', 'isatty', 'access'}   # pure queries: reviewed, see header
    return eff, mut

def loops(t, lo, hi):
    spans = []
    for m in re.finditer(r'\b(for|while)\s*\(', t[lo:hi]):
        p = match_paren(t, lo + m.end() - 1)
        k = p + 1
        while k < hi and t[k] in ' \t\n': k += 1
        if k < hi and t[k] == '{':
            d, e = 0, k
            while e < hi:
                if t[e] == '{': d += 1
                elif t[e] == '}':
                    d -= 1
                    if d == 0: break
                e += 1
            spans.append((k, e))
    return spans

def main():
    base, mut = base_effects()
    if not base or not mut: raise SystemExit('FAIL: derived an empty effect list')
    texts, fns = {}, {}
    for f in hosted_sources(ROOT):
        t = strip(open(os.path.join(ROOT, f)).read()); texts[f] = t
        for n, _, lo, hi, _ in functions(t): fns[(f, n)] = (lo, hi)
    names = {}
    for (f, n), sp in fns.items(): names.setdefault(n, []).append((f, sp))
    # FATAL functions end the process unconditionally (an abort/exit/_exit
    # call at the body's top brace level, e.g. x_oom): an effect on a path that
    # cannot return is not one a refusal must precede, so they do not propagate.
    fatal = set()
    for (f, n), (lo, hi) in fns.items():
        t = texts[f]
        for c, a, b in calls(t, lo, hi):
            if c in ('abort', 'exit', '_exit') and t[lo:a].count('{') - t[lo:a].count('}') == 1:
                fatal.add(n)
    # transitive effect / check bearing functions (by name, across files)
    eff_fn, chk_fn = set(), set()
    changed = True
    while changed:
        changed = False
        for (f, n), (lo, hi) in fns.items():
            cs = calls(texts[f], lo, hi)
            own = set(ALLOC_m.group(1) for ALLOC_m in ALLOC.finditer(texts[f], lo, hi))
            if n not in eff_fn and n not in fatal and any(c not in fatal and is_effect(c, a, b, texts[f], base, mut, own, eff_fn, direct=False) for c, a, b in cs):
                eff_fn.add(n); changed = True
            if n not in chk_fn and any(c in CHECKS or c in chk_fn for c, _, _ in cs):
                chk_fn.add(n); changed = True
    examined, violations, effects_seen = 0, [], 0
    for (f, n), (lo, hi) in sorted(fns.items()):
        t = texts[f]; cs = calls(t, lo, hi)
        own = set(m.group(1) for m in ALLOC.finditer(t, lo, hi))
        # an effect happens when its call RUNS: after its arguments, so a check
        # inside the argument list (f(EIGS_DCAST_RET(...))) precedes it
        effs = [b for c, a, b in cs if is_effect(c, a, b, t, base, mut, own, eff_fn)]
        effname = {b: c for c, a, b in cs}
        chks = [(a, c) for c, a, b in cs if (c in CHECKS or c in chk_fn) and c != n]
        if n.startswith('builtin_'): examined += 1
        effects_seen += len(effs)
        if not effs or not chks: continue
        first = min(effs)
        for a, c in chks:
            if a > first:
                violations.append((f'{f}:{n} {c}', f'{f}:{line_of(t, a)} {n}: {c} after the effect {effname[first]} at line {line_of(t, first)}'))
        for lo2, hi2 in loops(t, lo, hi):
            le = [e for e in effs if lo2 < e < hi2]
            lc = [(a, c) for a, c in chks if lo2 < a < hi2 and a < (min(le) if le else 0)]
            for a, c in lc:
                violations.append((f'{f}:{n} {c}', f'{f}:{line_of(t, a)} {n}: {c} inside a loop that also has the effect at line {line_of(t, min(le))}'))
    waivers = {}
    for ln in open(os.path.join(ROOT, 'tools', 'ieee_effect_order_waivers.txt')):
        ln = ln.strip()
        if not ln or ln.startswith('#'): continue
        k1, k2, reason = ln.split(None, 2)
        waivers[f'{k1} {k2}'] = [reason, 0]
    v = w = 0
    for key, text in sorted(set(violations), key=lambda x: x[1]):
        if key in waivers:
            waivers[key][1] += 1; w += 1; print('WAIVED   ', text)
        else:
            v += 1; print('VIOLATION', text)
    stale = [k for k, x in waivers.items() if x[1] == 0]
    for k in stale: print('STALE waiver:', k)
    print(f'EFFECT_ORDER: examined={examined} builtins, effects={effects_seen}, violations={v} waived={w} waivers={len(waivers)} stale={len(stale)}')
    sys.exit(0 if examined > 0 and effects_seen > 0 and v == 0 and not stale else 1)

def is_effect(c, a, b, t, base, mut, own, eff_fn, direct=True):
    arg0 = t[a + 1:b].split(',')[0].strip()
    if arg0 in ('stderr', 'stdout'): return False      # diagnostics, not I/O on data
    if c in base or c in eff_fn or re.match(r'(p_)?SDL_', c):
        return True
    if direct and c.endswith('_lock') and not c.endswith('_unlock'):
        return True
    if c in mut:
        arg0 = t[a + 1:b].split(',')[0].strip().lstrip('&(')
        return arg0 not in own
    return False

main()
