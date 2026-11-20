#!/usr/bin/env python3
"""Prove the embedding strict-call test rejects fourteen single faults."""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
G='''void eigs_state_set_strict_guards(EigsState *st, int enabled) {
    if (st) st->strict_guards = enabled != 0;
}'''
A='''void eigs_state_set_strict_arithmetic(EigsState *st, int enabled) {
    if (st) st->strict_arithmetic = enabled != 0;
}'''
B='''void eigs_state_set_strict(EigsState *st, int enabled) {
    if (st) {
        st->strict_guards = enabled != 0;
        st->strict_arithmetic = enabled != 0;
    }
}'''
variants = [
 ('guards-noop-disable',G,G.replace('if (st) st->strict_guards = enabled != 0;','if (st && enabled) st->strict_guards = 1;'),'guards 1->0 other=0'),
 ('guards-noop-enable',G,G.replace('if (st) st->strict_guards = enabled != 0;','if (st && !enabled) st->strict_guards = 0;'),'guards 0->1 other=0'),
 ('arithmetic-noop-disable',A,A.replace('if (st) st->strict_arithmetic = enabled != 0;','if (st && enabled) st->strict_arithmetic = 1;'),'arithmetic 1->0 other=0'),
 ('arithmetic-noop-enable',A,A.replace('if (st) st->strict_arithmetic = enabled != 0;','if (st && !enabled) st->strict_arithmetic = 0;'),'arithmetic 0->1 other=0'),
 ('guards-writes-arithmetic',G,G.replace('st->strict_guards','st->strict_arithmetic'),'guards 0->1 other=0'),
 ('arithmetic-writes-guards',A,A.replace('st->strict_arithmetic','st->strict_guards'),'arithmetic 0->1 other=0'),
 ('both-leaves-guards',B,B.replace('        st->strict_guards = enabled != 0;\n',''),'both 01->11'),
 ('both-leaves-arithmetic',B,B.replace('        st->strict_arithmetic = enabled != 0;\n',''),'both 10->11'),
 ('guards-resets-arithmetic-default',G,G.replace('if (st) st->strict_guards = enabled != 0;','if (st) { st->strict_guards = enabled != 0; st->strict_arithmetic = 0; }'),'guards 1->0 other=1'),
 ('arithmetic-only-before-init',A,A.replace('if (st) st->strict_arithmetic = enabled != 0;','if (st && !st->threads) st->strict_arithmetic = enabled != 0;'),'arithmetic 0->1 other=0'),
 ('guards-no-null-guard',G,G.replace('if (st) st->strict_guards = enabled != 0;','st->strict_guards = enabled != 0;'),'CRASH null guards'),
 ('arithmetic-no-null-guard',A,A.replace('if (st) st->strict_arithmetic = enabled != 0;','st->strict_arithmetic = enabled != 0;'),'CRASH null arithmetic'),
 ('guards-enables-only-one',G,G.replace('enabled != 0','enabled == 1'),'guards 0->1 other=0'),
 ('arithmetic-enables-only-one',A,A.replace('enabled != 0','enabled == 1'),'arithmetic 0->1 other=0'),
]
def run(cwd, env):
    return subprocess.run([str(cwd/'build/release/test_embed_strict_calls')],cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
def main():
  with tempfile.TemporaryDirectory(prefix='eigs-embed-strict-') as td:
    dst=Path(td)/'tree'
    shutil.copytree(ROOT,dst,ignore=shutil.ignore_patterns('.git','build','node_modules','evidence'))
    subprocess.run(['make','-s','embed-strict-calls-test'],cwd=dst,check=True)
    env={k:v for k,v in os.environ.items() if k!='EIGS_STRICT'}
    clean=run(dst,env)
    if clean.returncode or 'embed-strict-calls: PASS transitions=12 fourth=20 failures=0' not in clean.stdout:
      print('embed-strict-variants: clean control FAIL'); return 1
    print('clean-control: GREEN')
    p=dst/'src/eigs_embed.c'; original=p.read_text(); red=0
    for name,anchor,replacement,want in variants:
      if original.count(anchor)!=1: raise SystemExit(f'{name}: anchor count {original.count(anchor)}, wanted 1')
      p.write_text(original.replace(anchor,replacement,1))
      subprocess.run(['make','-s','embed-strict-calls-test'],cwd=dst,check=True)
      cp=run(dst,env)
      planted = cp.returncode != 0
      attributable = want.startswith('CRASH') or (f'FAIL: {want}' in cp.stdout)
      if planted and attributable: red += 1; print(f'{name}: RED ({want})')
      else: print(f'{name}: WRONG rc={cp.returncode} expected={want}')
      p.write_text(original)
    print(f'embed-strict-variants: examined={len(variants)} red={red}')
    return 0 if red==len(variants) else 1
if __name__=='__main__': sys.exit(main())
