#!/usr/bin/env python3
"""Prove the embedding strict-call test rejects embedding strict-call faults."""
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
 ('guards-noop-disable',G,G.replace('if (st) st->strict_guards = enabled != 0;','if (st && enabled) st->strict_guards = 1;'),'open guards 1->0 other=0'),
 ('guards-noop-enable',G,G.replace('if (st) st->strict_guards = enabled != 0;','if (st && !enabled) st->strict_guards = 0;'),'new guards 0->1 other=0'),
 ('arithmetic-noop-disable',A,A.replace('if (st) st->strict_arithmetic = enabled != 0;','if (st && enabled) st->strict_arithmetic = 1;'),'open arithmetic 1->0 other=0'),
 ('arithmetic-noop-enable',A,A.replace('if (st) st->strict_arithmetic = enabled != 0;','if (st && !enabled) st->strict_arithmetic = 0;'),'new arithmetic 0->1 other=0'),
 ('guards-writes-arithmetic',G,G.replace('st->strict_guards','st->strict_arithmetic'),'new guards 0->1 other=0'),
 ('arithmetic-writes-guards',A,A.replace('st->strict_arithmetic','st->strict_guards'),'new arithmetic 0->1 other=0'),
 ('both-leaves-guards',B,B.replace('        st->strict_guards = enabled != 0;\n',''),'new both 01->11'),
 ('both-leaves-arithmetic',B,B.replace('        st->strict_arithmetic = enabled != 0;\n',''),'open both 10->11'),
 ('guards-resets-arithmetic-default',G,G.replace('if (st) st->strict_guards = enabled != 0;','if (st) { st->strict_guards = enabled != 0; st->strict_arithmetic = 0; }'),'new guards 1->0 other=1'),
 ('arithmetic-only-before-init',A,A.replace('if (st) st->strict_arithmetic = enabled != 0;','if (st && !st->threads) st->strict_arithmetic = enabled != 0;'),'open arithmetic 0->1 other=1'),
 ('guards-no-null-guard',G,G.replace('if (st) st->strict_guards = enabled != 0;','st->strict_guards = enabled != 0;'),'CRASH null guards'),
 ('arithmetic-no-null-guard',A,A.replace('if (st) st->strict_arithmetic = enabled != 0;','st->strict_arithmetic = enabled != 0;'),'CRASH null arithmetic'),
 ('guards-enables-only-one',G,G.replace('enabled != 0','enabled == 1'),'new guards 0->1 other=0'),
 ('arithmetic-enables-only-one',A,A.replace('enabled != 0','enabled == 1'),'new arithmetic 0->1 other=0'),
]

# A call returning without writing for one state kind and one direction.
# None duplicates the fourteen broader or orthogonal edits above: in particular,
# arithmetic-only-before-init suppresses both directions on an open state.
def one_place(name, source, field, opened, enabled, want):
    condition = ("st->threads" if opened else "!st->threads") + (" && enabled" if enabled else " && !enabled")
    assignment = f"if (st) st->{field} = enabled != 0;"
    if source == B:
        replacement = source.replace("    if (st) {", f"    if (st) {{\n        if ({condition}) return;", 1)
    else:
        replacement = source.replace(assignment, f"if (st && {condition}) return;\n    {assignment}", 1)
    return (name, source, replacement, want)

variants += [
 one_place('guards-open-zero', G, 'strict_guards', True, False, 'open guards 1->0 other=0'),
 one_place('guards-open-nonzero', G, 'strict_guards', True, True, 'open guards 0->1 other=1'),
 one_place('guards-new-zero', G, 'strict_guards', False, False, 'new guards 1->0 other=1'),
 one_place('guards-new-nonzero', G, 'strict_guards', False, True, 'new guards 0->1 other=0'),
 one_place('arithmetic-open-zero', A, 'strict_arithmetic', True, False, 'open arithmetic 1->0 other=0'),
 one_place('arithmetic-open-nonzero', A, 'strict_arithmetic', True, True, 'open arithmetic 0->1 other=1'),
 one_place('arithmetic-new-zero', A, 'strict_arithmetic', False, False, 'new arithmetic 1->0 other=1'),
 one_place('arithmetic-new-nonzero', A, 'strict_arithmetic', False, True, 'new arithmetic 0->1 other=0'),
 one_place('both-open-zero', B, '', True, False, 'open both 01->00'),
 one_place('both-open-nonzero', B, '', True, True, 'open both 10->11'),
 one_place('both-new-zero', B, '', False, False, 'new both 10->00'),
 one_place('both-new-nonzero', B, '', False, True, 'new both 01->11'),
]
# A call that enables only for the value 1 on one kind of state (an
# independent review's D4 and D5, and the four others of their class).
def only_one(name, source, opened, want):
    kind = "st->threads" if opened else "!st->threads"
    return (name, source, source.replace("enabled != 0", f"({kind} ? enabled == 1 : enabled != 0)"), want)

variants += [
 only_one('guards-open-enables-only-one', G, True, 'open guards 0->1 other=1'),
 only_one('guards-new-enables-only-one', G, False, 'new guards 0->1 other=0'),
 only_one('arithmetic-open-enables-only-one', A, True, 'open arithmetic 0->1 other=1'),
 only_one('arithmetic-new-enables-only-one', A, False, 'new arithmetic 0->1 other=0'),
 only_one('both-open-enables-only-one', B, True, 'open both 10->11'),
 only_one('both-new-enables-only-one', B, False, 'new both 01->11'),
]

# Two faults in one cell each, which none of the twelve named transitions
# reaches: only the matrix of every cell names them.
variants += [
 ('guards-new-ignores-two-when-arithmetic-off', G,
  G.replace('if (st) st->strict_guards = enabled != 0;',
            'if (st && !st->threads && enabled == 2 && !st->strict_arithmetic) return;\n    if (st) st->strict_guards = enabled != 0;'),
  'matrix new guards start=0,0 value=2'),
 ('both-open-ignores-zero-from-both-on', B,
  B.replace('    if (st) {', '    if (st) {\n        if (st->threads && !enabled && st->strict_guards && st->strict_arithmetic) return;', 1),
  'matrix open both start=1,1 value=0'),
]
# A call made on one state while another is attached on the calling thread
# writes the attached state (an independent review's E3, for each call): red
# by a cell of the matrix's kind `other`.
def writes_attached(name, source, want):
    return (name, source,
            source.replace("if (st)", "if (st && eigs_current && eigs_current->state) st = eigs_current->state;\n    if (st)", 1),
            want)

variants += [
 writes_attached('guards-writes-attached-state', G, 'matrix other guards start=0,0 value=1'),
 writes_attached('arithmetic-writes-attached-state', A, 'matrix other arithmetic start=0,0 value=1'),
 writes_attached('both-writes-attached-state', B, 'matrix other both start=0,0 value=1'),
]
# A call ignored on a state that is attached and not yet initialised (the
# review's E4, for each call): red by a cell of the kind `attached`.
def ignored_before_init(name, source, want):
    return (name, source,
            source.replace("if (st)", "if (st && st->threads && !st->global_env) return;\n    if (st)", 1),
            want)

variants += [
 ignored_before_init('guards-ignored-between-attach-and-init', G, 'matrix attached guards start=0,0 value=1'),
 ignored_before_init('arithmetic-ignored-between-attach-and-init', A, 'matrix attached arithmetic start=0,0 value=1'),
 ignored_before_init('both-ignored-between-attach-and-init', B, 'matrix attached both start=0,0 value=1'),
]
# The existing call without its null guard, and each call writing the
# process environment.
variants += [
 ('both-no-null-guard', B, B.replace('    if (st) {', '    {', 1), 'CRASH null both'),
 ('guards-writes-environment', G,
  G.replace('if (st) st->strict_guards = enabled != 0;',
            'if (st) { st->strict_guards = enabled != 0; setenv("EIGS_STRICT", enabled ? "1" : "0", 1); }'),
  'two states keep their own positions'),
 ('arithmetic-writes-environment', A,
  A.replace('if (st) st->strict_arithmetic = enabled != 0;',
            'if (st) { st->strict_arithmetic = enabled != 0; setenv("EIGS_STRICT", enabled ? "1" : "0", 1); }'),
  'two states keep their own positions'),
 ('both-writes-environment', B,
  B.replace('    if (st) {', '    if (st) {\n        setenv("EIGS_STRICT", enabled ? "1" : "0", 1);', 1),
  'two states keep their own positions'),
]
# Two variants of an independent review of the closed list: the guards call
# crashing on a null state for the value 0 only, and writing the environment
# only on a state that is attached.
variants += [
 ('guards-null-crash-on-zero', G,
  G.replace('if (st) st->strict_guards = enabled != 0;',
            'if (!enabled) st->strict_guards = 0; else if (st) st->strict_guards = 1;'),
  'CRASH null guards with 0'),
 ('guards-writes-environment-when-attached', G,
  G.replace('if (st) st->strict_guards = enabled != 0;',
            'if (st) { st->strict_guards = enabled != 0; if (st->threads) setenv("EIGS_STRICT", enabled ? "1" : "0", 1); }'),
  'matrix open guards start=0,0 value=0'),
]
# What a state reads when it is created (src/state.c): each default the
# other way, red by the creation check (the tool runs with the variable unset).
STATE_G = '    st->strict_guards = eigs_env_flag_default("EIGS_STRICT", 1);'
STATE_A = '    st->strict_arithmetic = eigs_env_flag_default("EIGS_STRICT", 0);'
IN_STATE_C = {'creation-guards-default-off', 'creation-arithmetic-default-on'}
variants += [
 ('creation-guards-default-off', STATE_G, STATE_G.replace('", 1)', '", 0)'), 'creation want=1,0 seen=0,0'),
 ('creation-arithmetic-default-on', STATE_A, STATE_A.replace('", 0)', '", 1)'), 'creation want=1,0 seen=1,1'),
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
    if (clean.returncode or 'embed-strict-calls: PASS transitions=12 fourth=20 failures=0' not in clean.stdout
            or 'PASS: matrix of 192 cells' not in clean.stdout):
      print('embed-strict-variants: clean control FAIL'); return 1
    print('clean-control: GREEN')
    red=0
    for name,anchor,replacement,want in variants:
      p=dst/('src/state.c' if name in IN_STATE_C else 'src/eigs_embed.c'); original=p.read_text()
      if original.count(anchor)!=1: raise SystemExit(f'{name}: anchor count {original.count(anchor)}, wanted 1')
      p.write_text(original.replace(anchor,replacement,1))
      subprocess.run(['make','-s','embed-strict-calls-test'],cwd=dst,check=True)
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
