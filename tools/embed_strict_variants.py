#!/usr/bin/env python3
"""Plant arithmetic-setter faults after removal of the guard property (#2502).

Guard-only mutations are retired with the removed API. The remaining setter,
state-lifecycle, environment, null-safety and two-state mutations are retained.
"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
IN_STATE_C={'creation-arithmetic-default-on'}
variants = [('arithmetic-noop-disable',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && enabled) st->strict_arithmetic = 1;\n'
  '}',
  'open arithmetic 1->0 other=0'),
 ('arithmetic-noop-enable',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && !enabled) st->strict_arithmetic = 0;\n'
  '}',
  'new arithmetic 0->1 other=0'),
 ('both-leaves-arithmetic',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n    if (st) {\n    }\n}',
  'open both 10->11'),
 ('arithmetic-only-before-init',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && !st->threads) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'open arithmetic 0->1 other=1'),
 ('arithmetic-no-null-guard',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    st->strict_arithmetic = enabled != 0;\n'
  '}',
  'CRASH null arithmetic'),
 ('arithmetic-enables-only-one',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled == 1;\n'
  '}',
  'new arithmetic 0->1 other=0'),
 ('arithmetic-open-zero',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && st->threads && !enabled) return;\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'open arithmetic 1->0 other=0'),
 ('arithmetic-open-nonzero',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && st->threads && enabled) return;\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'open arithmetic 0->1 other=1'),
 ('arithmetic-new-zero',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && !st->threads && !enabled) return;\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'new arithmetic 1->0 other=1'),
 ('arithmetic-new-nonzero',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && !st->threads && enabled) return;\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'new arithmetic 0->1 other=0'),
 ('both-open-zero',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        if (st->threads && !enabled) return;\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'open both 01->00'),
 ('both-open-nonzero',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        if (st->threads && enabled) return;\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'open both 10->11'),
 ('both-new-zero',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        if (!st->threads && !enabled) return;\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'matrix new strict start=1,1 value=0'),
 ('both-new-nonzero',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        if (!st->threads && enabled) return;\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'matrix new strict start=1,0 value=1'),
 ('arithmetic-open-enables-only-one',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = (st->threads ? enabled == 1 : enabled != 0);\n'
  '}',
  'open arithmetic 0->1 other=1'),
 ('arithmetic-new-enables-only-one',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = (!st->threads ? enabled == 1 : enabled != 0);\n'
  '}',
  'new arithmetic 0->1 other=0'),
 ('both-open-enables-only-one',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = (st->threads ? enabled == 1 : enabled != 0);\n'
  '    }\n'
  '}',
  'open both 10->11'),
 ('both-new-enables-only-one',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = (!st->threads ? enabled == 1 : enabled != 0);\n'
  '    }\n'
  '}',
  'new both 01->11'),
 ('both-open-ignores-zero-from-both-on',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        if (st->threads && !enabled && st->strict_arithmetic) return;\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'matrix open strict start=1,1 value=0'),
 ('arithmetic-writes-attached-state',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && eigs_current && eigs_current->state) st = eigs_current->state;\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'matrix other arithmetic start=1,0 value=1'),
 ('both-writes-attached-state',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st && eigs_current && eigs_current->state) st = eigs_current->state;\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'matrix other strict start=1,0 value=1'),
 ('arithmetic-ignored-between-attach-and-init',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st && st->threads && !st->global_env) return;\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'matrix attached arithmetic start=1,0 value=1'),
 ('both-ignored-between-attach-and-init',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st && st->threads && !st->global_env) return;\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'matrix attached strict start=1,0 value=1'),
 ('both-no-null-guard',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'CRASH null both'),
 ('arithmetic-writes-environment',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) st->strict_arithmetic = enabled != 0;\n'
  '}',
  'void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {\n'
  '    if (st) { st->strict_arithmetic = enabled != 0; setenv("EIGS_STRICT", enabled ? "1" : "0", '
  '1); }\n'
  '}',
  'two states keep their own positions'),
 ('both-writes-environment',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'void eigs_state_set_strict(EigsState *st, int enabled) {\n'
  '    if (st) {\n'
  '        setenv("EIGS_STRICT", enabled ? "1" : "0", 1);\n'
  '        st->strict_arithmetic = enabled != 0;\n'
  '    }\n'
  '}',
  'two states keep their own positions'),
 ('creation-arithmetic-default-on',
  '    st->strict_arithmetic = eigs_env_flag_default("EIGS_STRICT", 0);',
  '    st->strict_arithmetic = eigs_env_flag_default("EIGS_STRICT", 1);',
  'creation want=1,0 seen=1,1')]
def run(cwd, env):
    return subprocess.run([str(cwd/'build/release/test_embed_strict_calls')],cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
def main():
  with tempfile.TemporaryDirectory(prefix='eigs-embed-strict-') as td:
    dst=Path(td)/'tree'
    shutil.copytree(ROOT,dst,symlinks=True,ignore=shutil.ignore_patterns('.git','build','node_modules','evidence'))
    subprocess.run(['make','-j1','-s','embed-strict-calls-test'],cwd=dst,check=True)
    env={k:v for k,v in os.environ.items() if k!='EIGS_STRICT'}
    clean=run(dst,env)
    if (clean.returncode or 'embed-strict-calls: PASS transitions=8 fourth=20 failures=0' not in clean.stdout
            or 'PASS: matrix of 64 cells' not in clean.stdout):
      print('embed-strict-variants: clean control FAIL'); return 1
    print('clean-control: GREEN')
    red=0
    for name,anchor,replacement,want in variants:
      p=dst/('src/state.c' if name in IN_STATE_C else 'src/eigs_embed.c'); original=p.read_text()
      if original.count(anchor)!=1: raise SystemExit(f'{name}: anchor count {original.count(anchor)}, wanted 1')
      p.write_text(original.replace(anchor,replacement,1))
      subprocess.run(['make','-j1','-s','embed-strict-calls-test'],cwd=dst,check=True)
      cp=run(dst,env)
      planted = cp.returncode != 0
      # A CRASH variant must die by a signal, not merely exit nonzero.
      attributable = (cp.returncode < 0) if want.startswith('CRASH') else (f'FAIL: {want}' in cp.stdout)
      if planted and attributable: red += 1; print(f'{name}: RED ({want})')
      else: print(f'{name}: WRONG rc={cp.returncode} expected={want}')
      p.write_text(original)
    print(f'embed-strict-variants: examined={len(variants)} red={red}')
    return 0 if red==len(variants) else 1
if __name__=='__main__': sys.exit(main())
