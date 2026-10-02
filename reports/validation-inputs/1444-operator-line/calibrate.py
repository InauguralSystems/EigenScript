#!/usr/bin/env python3
"""Off-box ordinary #1425 fault calibration; never edits the candidate checkout."""
import argparse, hashlib, importlib.util, json, os, re, subprocess, sys
from pathlib import Path
PKG=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('accepted',PKG.parent/'1452-post1460/validate.py')
a=importlib.util.module_from_spec(spec); spec.loader.exec_module(a)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--candidate',type=Path,required=True)
    ap.add_argument('--scratch',type=Path,required=True)
    ap.add_argument('--evidence',type=Path,required=True)
    args=ap.parse_args(); candidate=args.candidate.resolve(); scratch=args.scratch.resolve(); out=args.evidence.resolve()
    m=json.loads((PKG/'source-manifest.json').read_text()); a.verify(candidate,m,True)
    a.require(not scratch.exists() and not out.exists(),'calibration paths must be new')
    a.require(not scratch.is_relative_to(candidate) and not out.is_relative_to(candidate),'isolated paths required')
    out.mkdir(parents=True)
    names=['clone','checkout','apply','clean-build','initial-tape-green','plan','initial-caret-green','trace-fault-build','trace-red','trace-restored-build','trace-restored-green','caret-fault-build','caret-red','caret-restored-build','caret-restored-green','final-source-identities']
    rows={n:dict(status='NOT_RUN') for n in names}
    def save(): (out/'phase-ledger.json').write_text(json.dumps(rows,indent=2)+'\n')
    def run(name,argv,cwd=scratch,expected=0,audit=None,seconds=60):
        log=out/(name+'.log'); row=rows[name]
        bounded=['timeout','--kill-after=10',str(seconds),*map(str,argv)]
        row.update(status='RUNNING',argv=bounded,cwd=str(cwd),expected_exit=expected,log=log.name); save()
        try:
            with log.open('xb') as f: p=subprocess.run(bounded,cwd=cwd,stdout=f,stderr=subprocess.STDOUT)
            row.update(exit=p.returncode,log_sha256=a.sha(log)); save()
            a.require(p.returncode==expected,'unexpected process exit: '+str(p.returncode))
            if audit: row['receipt']=audit(log.read_text(errors='replace'),p.returncode)
            row['status']='PASS'; save()
        except Exception as error:
            row.update(status='FAIL',blocker=str(error)); save(); raise
    def tape(log,rc,red=False):
        marker='jit_tape_diff: FAIL: binary_scope jit tape differs from interpreter' if red else 'jit_tape_diff: OK (2 programs x {jit, osr} tapes vs the interpreter)'
        a.require(marker in log,'ordinary tape oracle did not produce the expected verdict')
        return dict(verdict='RED' if red else 'GREEN',marker=marker)
    def caret(name,red=False):
        capture=out/(name+'.counters')
        def audit(log,rc):
            if not red: return dict(verdict='GREEN',**a.counters(log,capture,rc))
            want='FINAL_COUNTERS rc=1 PASS=13 TOTAL=16 FAIL=3 SKIPPED=0 LEAKED=0'
            a.require(capture.read_text().splitlines()==[want],'caret RED counter population differs')
            failures=re.findall(r'^  FAIL: (.+)$',log,re.M)
            a.require(len(failures)==3 and all(s.startswith('operator_line_compound.eigs ') for s in failures),'unexpected caret RED failure class')
            a.require(all('missing: [       |       ^]' in s for s in failures),'RED must identify the operator caret')
            return dict(verdict='RED',passed=13,total=16,failed=3,skipped=0,leaked=0,failures=failures)
        run(name,['bash',str(PKG.parent/'1452-post1460/capture-exit.sh'),str(out/'caret-plan.sh'),str(capture)],cwd=scratch/'tests',expected=1 if red else 0,audit=audit,seconds=120)
    originals={}; result=1
    try:
        run('clone',['git','clone','--shared','--no-checkout','--separate-git-dir',str(scratch)+'-gitdir',str(candidate),str(scratch)],cwd=scratch.parent)
        run('checkout',['git','checkout','-b','validation-1444-calibration',m['baseline']])
        run('apply',['git','apply','--index',str(PKG/'candidate.patch')]); a.verify(scratch,m,True)
        run('clean-build',['make'],seconds=600)
        run('initial-tape-green',['bash','tools/jit_tape_diff.sh'],audit=tape)
        run('plan',['bash','tools/section_plan.sh','--emit-sections','0h',str(out/'caret-plan.sh')])
        caret('initial-caret-green')
        jit=scratch/'src/jit.c'; parser=scratch/'src/parser.c'
        originals={jit:jit.read_bytes(),parser:parser.read_bytes()}
        start='            /* #1383: a successful scope restores the tape\'s line stream\n'
        end='            patch_rel32(no_tape, w);\n'
        text=originals[jit].decode(); a.require(text.count(start)==1,'trace fault anchor changed')
        i=text.index(start); j=text.index(end,i)+len(end)
        trace_fault=text[:i]+text[j:]
        old='make_node_col(AST_BINOP, assign_tok->line, assign_tok->col)'
        new='make_node_col(AST_BINOP, assign_tok->line, name_tok->col)'
        a.require(originals[parser].decode().count(old)==1,'caret fault anchor changed')
        (out/'fault-manifest.json').write_text(json.dumps(dict(trace=dict(path='src/jit.c',original_sha256=a.sha(jit),fault_sha256=hashlib.sha256(trace_fault.encode()).hexdigest(),change='omit only native BINARY_LINE_END conditional trace_line emission'),caret=dict(path='src/parser.c',original_sha256=a.sha(parser),fault_sha256=hashlib.sha256(originals[parser].decode().replace(old,new).encode()).hexdigest(),change='plain-name compound binop uses name column')),indent=2)+'\n')
        try:
            jit.write_text(trace_fault)
            run('trace-fault-build',['make'],seconds=600)
            run('trace-red',['bash','tools/jit_tape_diff.sh'],expected=1,audit=lambda log,rc:tape(log,rc,True))
        finally: jit.write_bytes(originals[jit])
        a.verify(scratch,m,True)
        run('trace-restored-build',['make'],seconds=600)
        run('trace-restored-green',['bash','tools/jit_tape_diff.sh'],audit=tape)
        try:
            parser.write_text(originals[parser].decode().replace(old,new))
            run('caret-fault-build',['make'],seconds=600)
            caret('caret-red',True)
        finally: parser.write_bytes(originals[parser])
        a.verify(scratch,m,True)
        run('caret-restored-build',['make'],seconds=600)
        caret('caret-restored-green')
        result=0
    except Exception as error:
        print('CALIBRATION INCOMPLETE:',error,file=sys.stderr)
    finally:
        for path,data in originals.items(): path.write_bytes(data)
        try:
            a.verify(candidate,m,True); a.verify(scratch,m,True)
            rows['final-source-identities']=dict(status='PASS',candidate_tree=m['candidate_tree'],scratch_restored_tree=m['candidate_tree'])
        except Exception as error:
            rows['final-source-identities']=dict(status='FAIL',blocker=str(error)); result=1
        save()
        (out/'SHA256SUMS').write_text('\n'.join(f'{a.sha(p)}  {p.name}' for p in sorted(out.iterdir()) if p.is_file() and p.name!='SHA256SUMS')+'\n')
    if result==0: print('CALIBRATION: faults=2 red=2 restored_green=2 initial_green=2 exact_restores=2')
    return result
if __name__=='__main__': sys.exit(main())
