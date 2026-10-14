#!/usr/bin/env python3
"""#1746 Phase 1, Class B: every numeric-argument read in the hosted builtins
is classified, in the ieee build, as exactly one of

  finite      EIGS_ARG_FIN(read, failret): NaN/+-inf raise `value` naming the
              builtin and return before any effect; also any read inside
              EIGS_DCAST_RET (an integer conversion refuses non-finite too);
  propagating EIGS_ARG_PROP(read): math, where NaN/inf in is NaN/inf out.
  (EIGS_OPT_FIN / EIGS_OPT_PROP: the same two classes for the out-parameter
  accessors eigs_opt_num / eigs_slot_opt_num.)

  python3 tools/ieee_accessor_gate.py            check against the reviewed table
  python3 tools/ieee_accessor_gate.py --write    regenerate tools/ieee_accessor_table.txt

POPULATION (derived, not hand-picked):
  accessors  every function declared in src/eigenscript.h or src/container.h
             that yields a double from an argument -- returns double with a
             name ending in `num`/`num_arg` and a non-double first parameter,
             or writes a `double *` out-parameter and takes a `who` --
             (eigs_num_arg, eigs_list_num, eigs_slot_num, buffer_read_num,
             eigs_opt_num, ...). Its key is the NAME/SIGNATURE shape: a new
             accessor spelled otherwise is outside the population (residual);
  functions  every `builtin_*` function in the hosted sources, plus every
             static function reachable from one through same-file calls.
A read whose innermost classifying wrapper is none of the three is
UNCLASSIFIED. Prints one row per read, the table, then
  ACCESSORS: reads=<n> propagating=<p> finite=<f> unclassified=<u> table=<same|DIFFERS>
Exit 0 iff n > 0, unclassified == 0 and the table matches the reviewed file."""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ieee_cscan import hosted_sources, strip, functions, calls, line_of

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(ROOT, 'tools', 'ieee_accessor_table.txt')
WRAP = {'EIGS_ARG_FIN': 'finite', 'EIGS_ARG_PROP': 'propagating', 'EIGS_DCAST_RET': 'finite',
        'EIGS_OPT_FIN': 'finite', 'EIGS_OPT_PROP': 'propagating'}

def accessors():
    acc = set()
    for h in ('src/eigenscript.h', 'src/container.h'):
        t = strip(open(os.path.join(ROOT, h)).read())
        for m in re.finditer(r'\b(double|int)\s+\*?\s*([a-z_0-9]+)\s*\(([^)]*)\)', t):
            ret, name, params = m.groups()
            first = params.split(',')[0].strip()
            if ret == 'double' and re.search(r'num(_arg)?$', name) and not first.startswith('double'):
                acc.add(name)
            elif re.search(r'double\s*\*', params) and re.search(r'\bwho\b', params):
                acc.add(name)
    return acc

def main():
    acc = accessors()
    if not acc: raise SystemExit('FAIL: derived no accessors')
    rows, table = [], {}
    for f in hosted_sources(ROOT):
        t = strip(open(os.path.join(ROOT, f)).read())
        fns = functions(t)
        # Section 186: a read the parser cannot place inside a parsed function
        # (or a #define) is refused, never skipped.
        spans = [(lo, hi) for _, _, lo, hi, _ in fns] + [(h - 1, lo) for _, _, lo, _, h in fns]
        for c, a, b in calls(t, 0, len(t)):
            if c in acc and not any(lo < a < hi for lo, hi in spans):
                ls = t.rfind('\n', 0, a) + 1
                if not t[ls:a].lstrip().startswith('#') and '\\' not in t[a:t.find('\n', a)]:
                    rows.append((f, line_of(t, a), '<unparsed>', c, 'UNCLASSIFIED'))
        byname = {n: (lo, hi) for n, _, lo, hi, _ in fns}
        callees = {n: {c for c, _, _ in calls(t, lo, hi) if c in byname} for n, _, lo, hi, _ in fns}
        live, todo = set(), [n for n in byname if n.startswith('builtin_')]
        while todo:
            n = todo.pop()
            if n in live or n in acc: continue
            live.add(n); todo.extend(callees.get(n, ()))
        for n in sorted(live):
            lo, hi = byname[n]
            cs = calls(t, lo, hi)
            wraps = [(c, a, b) for c, a, b in cs if c in WRAP]
            for c, a, b in cs:
                if c not in acc: continue
                inner = [w for w in wraps if w[1] < a and b <= w[2]]
                quiet = any(q[1] < a and b <= q[2] for q in cs if q[0] == 'EIGS_DCAST_QUIET')
                if inner:
                    w = max(inner, key=lambda w: w[1])
                    cls = WRAP[w[0]]
                else:
                    cls = 'UNCLASSIFIED'
                rows.append((f, line_of(t, a), n, c, cls))
                key = f'{f}:{n}'
                table.setdefault(key, {'finite': 0, 'propagating': 0, 'UNCLASSIFIED': 0})[cls] += 1
    for r in rows: print(f'{r[4]:12s} {r[0]}:{r[1]} {r[2]}: {r[3]}')
    lines = ['# #1746 Phase 1 reviewed accessor classification: <file:function> finite=<n> propagating=<n>',
             '# Regenerate with `python3 tools/ieee_accessor_gate.py --write`; review the diff.']
    for k in sorted(table):
        v = table[k]
        lines.append(f'{k} finite={v["finite"]} propagating={v["propagating"]}')
    text = '\n'.join(lines) + '\n'
    if '--write' in sys.argv:
        open(TABLE, 'w').write(text)
    same = os.path.exists(TABLE) and open(TABLE).read() == text
    n = len(rows); p = sum(r[4] == 'propagating' for r in rows)
    fi = sum(r[4] == 'finite' for r in rows); u = sum(r[4] == 'UNCLASSIFIED' for r in rows)
    print(f'ACCESSORS: reads={n} propagating={p} finite={fi} unclassified={u} table={"same" if same else "DIFFERS"}')
    sys.exit(0 if n > 0 and u == 0 and same else 1)

main()
