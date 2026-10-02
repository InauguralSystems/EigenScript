#!/usr/bin/env python3
"""Serial off-box validation of frozen #1444; default verifies inputs only."""
import argparse, hashlib, importlib.util, json, os, re, subprocess, sys
from pathlib import Path
PKG = Path(__file__).resolve().parent
OLD = PKG.parent / '1452-post1460'
spec = importlib.util.spec_from_file_location('accepted_validation', OLD / 'validate.py')
accepted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accepted)
sha, require, verify = accepted.sha, accepted.require, accepted.verify

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--evidence', type=Path)
    ap.add_argument('--execute', action='store_true')
    args = ap.parse_args()
    candidate, baseline = args.candidate.resolve(), args.baseline.resolve()
    manifest = json.loads((PKG/'source-manifest.json').read_text())
    pop = json.loads((PKG/'gate-populations.json').read_text())
    reuse = json.loads((PKG/'reused-helpers.json').read_text())
    for name, digest in reuse['sha256'].items():
        require(sha(OLD/name) == digest, 'reused helper identity: '+name)
    require(sha(PKG/'candidate.patch') == manifest['patch_sha256'], 'patch identity')
    require(candidate != baseline, 'separate baseline required')
    verify(candidate, manifest, True)
    verify(baseline, manifest, False)
    for p, row in pop['source_provenance'].items():
        require(sha(candidate/p) == row['sha256'], 'gate source identity: '+p)
    require((candidate/'.github/requirements-release.txt').read_bytes() == (OLD/'requirements-release.txt').read_bytes(), 'dependency lock identity')
    if not args.execute:
        print('INPUTS_VERIFIED_ONLY: '+manifest['candidate_tree'])
        return 0
    require(args.evidence is not None, 'execution requires evidence path')
    evidence = args.evidence.resolve()
    require(not evidence.exists(), 'new evidence directory required; preserve failed attempts')
    for root in (candidate, baseline):
        require(not evidence.is_relative_to(root) and not PKG.is_relative_to(root), 'evidence/carrier outside source trees')
    evidence.mkdir(parents=True)
    (evidence/'logs').mkdir()
    env = os.environ.copy()
    removed = sorted(k for k in env if k.startswith(('EIGS_', 'REPLAY_DIFF_', 'PRECHECK_', 'SUITE_LABEL_', 'MAKE', 'SELFTEST_')) or k in ('ASAN_OPTIONS','LSAN_OPTIONS','UBSAN_OPTIONS','CC','CFLAGS','CPPFLAGS','LDFLAGS','LD_PRELOAD'))
    for k in removed: env.pop(k, None)
    env.update(SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
    (evidence/'selection-state.json').write_text(json.dumps(dict(removed_override_names=removed,full_suites_unfiltered=True),indent=2)+'\n')
    names = ['dependency-preflight','release-build','focused-plan','focused-suite','tape-differential','tape-entry-witness','tape-osr-witness','release-suite','asan-build','asan-suite','restore-release','native-build-plan','native-smoke','jit-differential','replay-differential','baseline-build','strict-differential','selftest-scope','precheck','test-changed','suite-label','final-source-identities']
    phases = {n:dict(status='NOT_RUN') for n in names}
    for name in ['source-manifest.json','gate-populations.json','candidate.patch','source-inventory.json','reused-helpers.json']:
        (evidence/name).write_bytes((PKG/name).read_bytes())
    for p in pop['jit_replay']['ledgers']:
        (evidence/Path(p).name).write_bytes((candidate/p).read_bytes())
    def save():
        (evidence/'phase-ledger.json').write_text(json.dumps(phases,indent=2)+'\n')
        state='COMPLETE' if all(r['status']=='PASS' for r in phases.values()) else 'INCOMPLETE'
        report=f'# #1444 validation: {state}\n\nBase `{manifest["baseline"]}`; candidate tree `{manifest["candidate_tree"]}`.\n\n'
        report+='| Phase | Status | Exit | Evidence |\n|---|---|---:|---|\n'
        for name,row in phases.items(): report+=f'| {name} | {row["status"]} | {row.get("exit", "")} | {row.get("log", "")} |\n'
        for name,row in phases.items():
            if row.get('blocker'): report+=f'\n{name}: {row["blocker"]}\n'
        report+='\nExact counters, argv, cwd, environment additions, process exits, hashes and parser receipts are in phase-ledger.json. Named variant/platform/boundary skips remain in raw logs; no READY status is a verdict.\n'
        (evidence/'REPORT.md').write_text(report)
    def phase(name, argv, cwd=candidate, additions=None, audit=None):
        row=phases[name]; log=evidence/'logs'/(name+'.log')
        row.update(status='RUNNING',argv=list(map(str,argv)),cwd=str(cwd),env_additions=additions or {},log=str(log.relative_to(evidence)))
        save()
        try:
            with log.open('xb') as f:
                p=subprocess.run(argv,cwd=cwd,env={**env,**(additions or {})},stdout=f,stderr=subprocess.STDOUT)
            row.update(exit=p.returncode,log_sha256=sha(log)); save()
            require(p.returncode==0,'process exited '+str(p.returncode))
            if audit: row['receipt']=audit(log.read_text(errors='replace'),p.returncode)
            row['status']='PASS'; save()
        except Exception as error:
            row.update(status='BLOCKED_SETUP' if name=='dependency-preflight' else 'FAIL',blocker=str(error)); save(); raise
    def hardlink(root):
        require(os.path.samefile(root/'src/eigenscript',root/'build/release/eigenscript'),'release binary must remain the in-tree hardlink')
    def suite(name,runner,additions=None):
        capture=evidence/(name+'-final-counters.txt')
        phase(name,['bash',str(OLD/'capture-exit.sh'),str(runner),str(capture)],cwd=candidate/'tests',additions=additions,audit=lambda log,rc:suite_receipt(name,log,capture,rc))
    def suite_receipt(name,log,capture,rc):
        receipt=accepted.counters(log,capture,rc)
        if name=='focused-suite':
            require(receipt['total']==86 and receipt['skipped']==0,'focused plan population differs')
            require(len(re.findall(r'^  PASS: (?:e.line, test_operator_line|header, excerpt, caret and traceback, operator_line)',log,re.M))==15,'operator-line tier population differs')
        return receipt
    def tape(log,rc):
        want=f'jit_tape_diff: OK ({len(pop["tape_programs"])} programs x {{jit, osr}} tapes vs the interpreter)'
        require(log.splitlines().count(want)==1,'tape corpus/verdict differs'); return {'programs':len(pop['tape_programs']),'arms_per_program':2}
    def witness(log,rc,osr=False):
        require(re.search(r'^scoped +[0-9]+ +yes ',log,re.M),'scoped function did not compile')
        require(re.search(r'^\[jit\] scanned=[1-9][0-9]* compiled=[1-9][0-9]* ',log,re.M),'missing native execution statistics')
        if osr: require(re.search(r'^<module> .* +yes +[1-9][0-9]* +[0-9]+ ',log,re.M),'module OSR not witnessed')
        return {'compiled_scoped':True,'module_osr_required':osr}
    def precheck(log,rc):
        rows=re.findall(r'^precheck: (\d+) passed, (\d+) failed, (\d+) skipped in \d+s$',log,re.M)
        require(len(rows)==1,'missing precheck verdict'); p,f,s=map(int,rows[0])
        require(p>0 and f==0 and p+f+s==pop['precheck']['declared_rows'],'precheck population/failure')
        return dict(passed=p,failed=f,skipped=s)
    save()
    result=1
    try:
        phase('dependency-preflight',['bash',str(OLD/'dependency-setup.sh'),str(candidate),str(evidence)])
        env['PATH']=(evidence/'setup/selected-path.txt').read_text().rstrip('\n')
        phase('release-build',['make']); hardlink(candidate)
        plan=evidence/'focused-plan.sh'
        phase('focused-plan',['bash','tools/section_plan.sh','--emit-sections','0 0b 0g 0h',str(plan)])
        suite('focused-suite',plan)
        phase('tape-differential',['bash','tools/jit_tape_diff.sh'],audit=tape)
        for name,extra in [('tape-entry-witness',{}),('tape-osr-witness',{'EIGS_JIT_OSR_THRESHOLD':'1'})]:
            phase(name,[str(candidate/'src/eigenscript'),str(candidate/'tests/jit_tape/binary_scope.eigs')],additions={'EIGS_JIT_STATS':'1','EIGS_JIT_HOT':'1',**extra},audit=lambda log,rc,extra=extra:witness(log,rc,bool(extra)))
        suite('release-suite',candidate/'tests/run_all_tests.sh')
        phase('asan-build',['make','asan'])
        suite('asan-suite',candidate/'tests/run_all_tests.sh',{'ASAN_OPTIONS':'detect_leaks=1'})
        phase('restore-release',['make']); hardlink(candidate)
        phase('native-build-plan',['make','-n','jit-smoke'])
        phase('native-smoke',['make','jit-smoke'],audit=lambda log,rc:accepted.native(log))
        phase('jit-differential',['bash','tools/jit_diff.sh'],audit=lambda log,rc:accepted.jit_audit(log,pop['jit_replay']))
        phase('replay-differential',['bash','tools/replay_diff.sh'],audit=lambda log,rc:accepted.replay_audit(log,pop['jit_replay']))
        phase('baseline-build',['make'],cwd=baseline); hardlink(baseline)
        phase('strict-differential',['bash','tools/strict_differential.sh',str(baseline/'src/eigenscript')],audit=lambda log,rc:accepted.strict(log,pop['strict']))
        # Both HEADs equal the baseline. Only staged candidate paths drive changed checks (#1605).
        phase('selftest-scope',['bash','tools/selftests.sh','--list','--changed',manifest['baseline']])
        phase('precheck',['make','precheck'],additions={'PRECHECK_BASE':manifest['baseline']},audit=precheck)
        phase('test-changed',['make','test-changed','BASE='+manifest['baseline']])
        phase('suite-label',['bash','tools/suite_label_check.sh'])
        result=0
    except Exception as error:
        print('INCOMPLETE:',error,file=sys.stderr)
    finally:
        try:
            verify(candidate,manifest,True); verify(baseline,manifest,False)
            phases['final-source-identities']=dict(status='PASS',receipt={'baseline':manifest['baseline'],'candidate_tree':manifest['candidate_tree']})
        except Exception as error:
            phases['final-source-identities']=dict(status='FAIL',blocker=str(error)); result=1
        save()
        hashes=[f'{sha(p)}  {p.relative_to(evidence)}' for p in sorted(evidence.rglob('*')) if p.is_file() and p.name!='SHA256SUMS' and 'dependency-venv' not in p.parts]
        (evidence/'SHA256SUMS').write_text('\n'.join(hashes)+'\n')
    return result
if __name__=='__main__':
    try: sys.exit(main())
    except Exception as error:
        print('BLOCKED_SOURCE:',error,file=sys.stderr); sys.exit(2)
