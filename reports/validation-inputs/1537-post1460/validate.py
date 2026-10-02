#!/usr/bin/env python3
"""External serial validation driver. Default verifies inputs without running gates."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

PKG = Path(__file__).resolve().parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()

def require(ok, message):
    if not ok:
        raise ValueError(message)

def verify(root, manifest, candidate):
    require(git(root, 'rev-parse', 'HEAD') == manifest['baseline'], 'HEAD differs from frozen base')
    wanted = manifest['candidate_tree'] if candidate else manifest['baseline_tree']
    require(git(root, 'write-tree') == wanted, 'index tree differs from frozen source')
    require(not git(root, 'diff', '--name-only'), 'unstaged tracked source modifications')
    if not candidate:
        require(not git(root, 'diff', '--cached', '--name-only'), 'baseline has staged modifications')
    for f in manifest['files']:
        expected = f['candidate_sha256'] if candidate else f['baseline_sha256']
        p = root / f['path']
        require(sha(p) == expected if expected else not p.exists(), 'file identity: ' + f['path'])

def counters(log, capture, exit_code):
    lines = capture.read_text().splitlines() if capture.exists() else []
    require(len(lines) == 1, 'missing/duplicate final counter capture')
    match = re.fullmatch(r'FINAL_COUNTERS rc=(\d+) PASS=(\d+) TOTAL=(\d+) FAIL=(\d+) SKIPPED=(\d+) LEAKED=(\d+)', lines[0])
    require(match is not None, 'missing/noninteger final counter field')
    rc, passed, total, failed, skipped, leaked = map(int, match.groups())
    require(rc == exit_code == 0, 'suite process/captured exit must both be zero')
    require(total > 0 and passed + failed == total, 'suite accounting does not conserve verdicts')
    require(failed == 0 and leaked == 0, 'failed verdict or positive tolerated leak tally')
    summaries = re.findall(r'^\s*RESULTS: (\d+)/(\d+) passed, (\d+) failed, (\d+) skipped\s*$', log, re.M)
    require(summaries and tuple(map(int, summaries[-1])) == (passed, total, failed, skipped), 'final RESULTS/counter mismatch')
    require(not re.search(r'ERROR: (?:AddressSanitizer|LeakSanitizer)|SUMMARY: (?:AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer)|runtime error:|AddressSanitizer:DEADLYSIGNAL', log), 'sanitizer diagnostic in full suite log')
    return dict(rc=rc, passed=passed, total=total, failed=failed, skipped=skipped, leaked=leaked)

def numerical_inventory(root):
    """Execute only AST-extracted pure constants and group/sample selection."""
    source = ast.parse((root/'tests/native_train_gradcheck.py').read_text())
    selected = []
    sampling = False
    for node in source.body:
        if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id in ('H_FINE','H_COARSE','REL_TOL','CONVERGENCE_TOL','MIN_GRAD','TOKENS') for t in node.targets):
            selected.append(node)
        elif isinstance(node,ast.FunctionDef) and node.name=='get_at':
            selected.append(node)
        elif isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='groups' for t in node.targets):
            sampling=True
            selected.append(node)
        elif sampling:
            if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='trained_path' for t in node.targets):
                break
            selected.append(node)
    fixture={'token_embeddings':[[.125]*4 for _ in range(8)],'output_proj':[[.125]*8 for _ in range(4)],'layers':[]}
    for unused in range(2):
        layer={k:[[.125]*c for _ in range(r)] for k,r,c in [('w_q',4,4),('w_k',4,4),('w_v',4,4),('w_o',4,4),('w_ff1',4,8),('w_ff2',8,4)]}
        layer.update({k:[.125]*4 for k in ('ln1_gamma','ln1_beta','ln2_gamma','ln2_beta')})
        fixture['layers'].append(layer)
    ns={'base':fixture}
    exec(compile(ast.Module(body=selected,type_ignores=[]),'pure-numerical-inventory','exec'),ns)
    def scalars(value):
        return sum(scalars(v) for v in value) if isinstance(value,list) else 1
    counts=(len(ns['groups']),sum(scalars(ns['get_at'](fixture,p)) for _,p in ns['groups']),len(ns['samples']),len(set(tuple(p) for _,p in ns['samples'])),len(ns['TOKENS'])-1)
    require(counts==(22,352,44,43,31),'fixed gradient population changed')
    constants={k:ns[k] for k in ('H_FINE','H_COARSE','REL_TOL','CONVERGENCE_TOL','MIN_GRAD')}
    require(constants==dict(H_FINE=.02,H_COARSE=.04,REL_TOL=.01,CONVERGENCE_TOL=.01,MIN_GRAD=1e-4),'numerical thresholds changed')
    require(any(p==['layers',0,'w_k',1,2] for _,p in ns['samples']),'historically failing coordinate missing')
    return dict(groups=22,scalars=352,nominal_probes=44,unique_positions=43,loss_receipts=31,constants=constants,mode='pure source inventory only; no native execution')

def focused(log):
    rows=re.findall(r'^  PASS: NG01 (\d+) finite-difference gradients across all 22 groups agree within 1% \((\d+) near-zero samples skipped\)$',log,re.M)
    require(len(rows)==1,'missing/duplicate actual 22-group gradient verdict')
    checked,near_zero=map(int,rows[0])
    require(checked>0 and checked+near_zero==44,'nominal gradient population diminished')
    require(len(re.findall(r'^NATIVE_GRADCHECK: 1 passed, 0 failed$',log,re.M))==1,'native gradient wrapper incomplete')
    require(len(re.findall(r'^  PASS: NG03 deliberately 2%-wrong derivatives are rejected$',log,re.M))==1,'named 2% derivative plant not rejected')
    require(not re.search(r'^\s*(?:FAIL:|SKIP:)',log,re.M),'gradient failure/capability skip')
    require(not re.search(r'ERROR: (?:AddressSanitizer|LeakSanitizer)|SUMMARY: (?:AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer)|runtime error:|AddressSanitizer:DEADLYSIGNAL',log),'native sanitizer diagnostic')
    return dict(groups=22,checked=checked,near_zero=near_zero,nominal=44,ng03_expected_red=True)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--candidate',type=Path,required=True)
    ap.add_argument('--evidence',type=Path)
    ap.add_argument('--execute',action='store_true')
    args=ap.parse_args()
    candidate=args.candidate.resolve()
    manifest=json.loads((PKG/'source-manifest.json').read_text())
    population=json.loads((PKG/'gate-populations.json').read_text())
    assets=json.loads((PKG/'calibration-assets.json').read_text())
    require(manifest['finalized'] is True,'provisional inputs cannot run')
    require(sha(PKG/'candidate.patch')==manifest['patch_sha256'],'patch SHA differs')
    require(sha(PKG/'capture-exit.sh')==json.loads((PKG/'capture-compatibility.json').read_text())['wrapper_sha256'],'capture wrapper differs from tested copy')
    verify(candidate,manifest,True)
    for name,receipt in population['source_provenance'].items():
        require(sha(candidate/name)==receipt['sha256'],'source context differs: '+name)
    for name,wanted in assets.items():
        require(sha(PKG/name)==wanted,'frozen calibration asset differs: '+name)
    require((candidate/'.github/requirements-release.txt').read_bytes()==(PKG/'requirements-release.txt').read_bytes(),'dependency lock differs')
    inventory=numerical_inventory(candidate)
    if not args.execute:
        print(json.dumps(dict(status='INPUTS_VERIFIED_ONLY',baseline=manifest['baseline'],candidate_tree=manifest['candidate_tree'],numerical_inventory=inventory)))
        return 0
    require(args.evidence is not None,'execution requires a new external evidence directory')
    evidence=args.evidence.resolve()
    require(not evidence.exists(),'evidence directory exists; preserve every prior attempt')
    require(not evidence.is_relative_to(candidate) and not PKG.is_relative_to(candidate),'inputs/evidence must be outside the source checkout')
    evidence.mkdir(parents=True)
    (evidence/'logs').mkdir()
    env=os.environ.copy()
    removed=sorted(k for k in env if k.startswith(('EIGS_','REPLAY_DIFF_','PRECHECK_','SUITE_LABEL_','MAKE')) or k in ('ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS','CC','CFLAGS','CPPFLAGS','LDFLAGS','LD_PRELOAD'))
    for name in removed:
        env.pop(name,None)
    env.update(SDL_VIDEODRIVER='dummy',SDL_AUDIODRIVER='dummy')
    (evidence/'selection-state.json').write_text(json.dumps({'removed_override_names':removed,'complete_suites':True},indent=2)+'\n')
    names=['dependency-preflight','calibration','http-build','http-current','http-capability','http-focused','full-build','full-current','full-capability','full-focused','full-suite','precheck','asan-http-build','asan-http-current','asan-http-capability','asan-http-focused','asan-http-suite','final-source-identities']
    phases={name:dict(status='NOT_RUN') for name in names}
    def save():
        (evidence/'phase-ledger.json').write_text(json.dumps(phases,indent=2)+'\n')
        accepted=all(row['status']=='PASS' for row in phases.values())
        text='# #1537 validation — '+('ACCEPTED' if accepted else 'NOT ACCEPTED')+'\n\n'
        text+=f'Base `{manifest["baseline"]}`, candidate tree `{manifest["candidate_tree"]}`.\n\n'
        text+='| Phase | Status | Process exit | Evidence |\n|---|---|---:|---|\n'
        for name,row in phases.items():
            text+=f'| {name} | {row["status"]} | {row.get("exit","")} | {row.get("log","")} |\n'
        for name,row in phases.items():
            if row.get('blocker'):
                text+=f'\n{name}: {row["blocker"]}\n'
        text+='\nphase-ledger.json retains exact argv/cwd/exits, suite counters, per-variant binary identities, actual numerical/fault counts and declared precheck populations. Complete raw logs, calibration control logs and setup attempts remain separate. Allowed platform/variant skips stay in raw logs; no skipped gradient capability is acceptable. Mock calibration is not native evidence. No Cloud READY state supplies acceptance.\n'
        (evidence/'REPORT.md').write_text(text)
    save()
    for name in ('source-manifest.json','gate-populations.json','numerical-policy.json','calibration-assets.json'):
        shutil.copyfile(PKG/name,evidence/name)
    (evidence/'numerical-inventory.json').write_text(json.dumps(inventory,indent=2)+'\n')
    def phase(name,argv,seconds=3600,cwd=candidate,additions=None,audit=None):
        log=evidence/'logs'/(name+'.log')
        row=phases[name]
        bounded=['timeout','--kill-after=10',str(seconds),*map(str,argv)]
        row.update(status='RUNNING',argv=bounded,cwd=str(cwd),timeout_seconds=seconds,log=str(log.relative_to(evidence)))
        save()
        try:
            run_env=dict(env)
            run_env.update(additions or {})
            with log.open('wb') as output:
                result=subprocess.run(bounded,cwd=cwd,env=run_env,stdout=output,stderr=subprocess.STDOUT)
            row['exit']=result.returncode
            row['log_sha256']=sha(log)
            output=log.read_text(errors='replace')
            row['raw_summaries']=[line for line in output.splitlines() if re.search(r'RESULTS:|NATIVE_GRADCHECK:|CALIBRATION:|NG0[123]|\b(?:passed|failed|skipped|SKIP|groups|sections)\b',line)][-60:]
            save()
            require(result.returncode==0,'command exited '+str(result.returncode)+' (124/137 are timeout failures)')
            if audit:
                row['receipt']=audit(output,result.returncode)
            row['status']='PASS'
            save()
        except Exception as error:
            row.update(status='BLOCKED_SETUP' if name=='dependency-preflight' else 'FAIL',blocker=str(error))
            save()
            raise
    def variant_receipt(name):
        binary=candidate/'src/eigenscript'
        built=candidate/'build'/name/'eigenscript'
        require(binary.is_file() and not binary.is_symlink() and os.path.samefile(binary,built),'incorrect in-tree variant hard-link alias')
        return {'variant':name,'src_binary_sha256':sha(binary),'variant_binary_sha256':sha(built),'alias_is_same_inode':True,'source_index_tree':git(candidate,'write-tree')}
    def calibration_audit(log,rc):
        require(len(re.findall(r'^CALIBRATION: examined22 passed22 failed0$',log,re.M))==1,'calibration population incomplete')
        rows=json.loads((evidence/'calibration/calibration-summary.json').read_text())
        require(len(rows)==22 and len({r['case'] for r in rows})==22 and all(r['oracle']=='PASS' for r in rows),'calibration controls missing')
        require(all((evidence/'calibration'/(r['case']+'.log')).is_file() for r in rows),'calibration raw control logs missing')
        return {'examined':22,'passed':22,'failed':0,'mode':'mock calibration only; independent of actual native runs'}
    def suite_audit(log,rc,capture):
        receipt=counters(log,capture,rc)
        require('[47c/47] native_train_step finite-difference gradient check' in log and 'PASS: native training gradients match an independent finite-difference oracle' in log,'full suite omitted model gradient section')
        return receipt
    try:
        phase('dependency-preflight',['bash',str(PKG/'dependency-setup.sh'),str(candidate),str(evidence)],seconds=1500)
        env['PATH']=(evidence/'setup/selected-path.txt').read_text().rstrip('\n')
        calibration_inputs=evidence/'calibration-inputs'
        calibration_inputs.mkdir()
        for name in assets:
            shutil.copyfile(PKG/name,calibration_inputs/name)
            require(sha(calibration_inputs/name)==assets[name],'calibration copy identity differs')
        phase('calibration',['python3',str(calibration_inputs/'calibrate_frozen.py'),str(candidate),str(evidence/'calibration')],seconds=600,audit=calibration_audit)
        probe=evidence/'model-capability.eigs'
        probe.write_text('print of (eigen_model_loaded of null)\n')
        def capability_audit(log,rc,name):
            require(log.strip()=='0','MODEL capability missing or diagnostic in capability probe (source returns numeric zero when unloaded)')
            return variant_receipt(name)
        for variant in ('http','full','asan-http'):
            additions={'ASAN_OPTIONS':'detect_leaks=1'} if variant=='asan-http' else {}
            phase(variant+'-build',['make',variant],additions=additions)
            phase(variant+'-current',['make','--no-print-directory','-q','build/'+variant+'/eigenscript'],additions=additions,audit=lambda log,rc,v=variant:variant_receipt(v))
            phase(variant+'-capability',[str(candidate/'src/eigenscript'),str(probe)],seconds=30,additions=additions,audit=lambda log,rc,v=variant:capability_audit(log,rc,v))
            phase(variant+'-focused',['bash',str(candidate/'tests/test_native_train_gradcheck.sh')],seconds=600,cwd=candidate/'src',additions=additions,audit=lambda log,rc:focused(log))
            if variant in ('full','asan-http'):
                capture=evidence/(variant+'-final-counters.txt')
                phase(variant+'-suite',['bash',str(PKG/'capture-exit.sh'),str(candidate/'tests/run_all_tests.sh'),str(capture)],seconds=5400,cwd=candidate/'tests',additions=additions,audit=lambda log,rc,c=capture:suite_audit(log,rc,c))
            if variant=='full':
                def precheck_audit(log,rc):
                    summary=re.findall(r'^precheck: (\d+) passed, (\d+) failed, (\d+) skipped in \d+s$',log,re.M)
                    require(len(summary)==1,'missing/duplicate precheck verdict')
                    passed,failed,skipped=map(int,summary[0])
                    require(passed>0 and failed==0 and passed+failed+skipped==population['precheck_rows'],'precheck population differs')
                    return dict(passed=passed,failed=failed,skipped=skipped,total=passed+failed+skipped)
                phase('precheck',['make','precheck'],additions={'PRECHECK_BASE':manifest['baseline']},audit=precheck_audit)
        verify(candidate,manifest,True)
        phases['final-source-identities']=dict(status='PASS',receipt={'baseline':manifest['baseline'],'candidate_tree':manifest['candidate_tree']})
        save()
        print('ACCEPTED: all required evidence complete; root must independently audit before integration')
        return 0
    except Exception as error:
        try:
            verify(candidate,manifest,True)
            phases['final-source-identities']=dict(status='PASS',receipt={'baseline':manifest['baseline'],'candidate_tree':manifest['candidate_tree']})
        except Exception as identity_error:
            phases['final-source-identities'].update(status='FAIL',blocker=str(identity_error))
        save()
        print('NOT ACCEPTED:',error,file=sys.stderr)
        return 1

if __name__=='__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('BLOCKED_SOURCE:',error,file=sys.stderr)
        sys.exit(2)
