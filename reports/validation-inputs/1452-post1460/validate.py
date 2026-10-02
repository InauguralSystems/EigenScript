#!/usr/bin/env python3
"""External serial validation driver. Default verifies inputs without running gates."""
import argparse
import decimal
import hashlib
import json
import os
from pathlib import Path
import re
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

def strict(log, pop):
    header = re.search(r'^  probes=(\d+) pins=(\d+) guarded-names=(\d+)$', log, re.M)
    require(header is not None, 'missing strict population')
    probes, pins, guarded = map(int, header.groups())
    skips = re.search(r'^  probes skipped \(builtin not in this build\): (\d+) —(.+)$', log, re.M)
    skipped = int(skips[1]) if skips else 0
    require(probes > 0 and guarded > 0 and probes + skipped == pop['declared_probes'], 'strict probe inventory diminished')
    require(pins == pop['pins'], 'strict pin inventory diminished')
    for pattern, expected in [
        (r'^  identical-when-off: (\d+)   differing: (\d+)$', (probes, 0)),
        (r'^  unset-equals-strict: (\d+) / (\d+)$', (probes, probes)),
        (r'^  raises-under-strict: (\d+)   silent: (\d+)   misattributed: (\d+)$', (probes, 0, 0)),
        (r'^  answer-pins held: (\d+)   broken: (\d+)$', (pins, 0)),
        (r'^  valid-input rows unchanged in all three modes: (\d+) / (\d+)$', (pop['valid_execution_rows'], pop['valid_execution_rows'])),
    ]:
        m = re.search(pattern, log, re.M)
        require(m is not None and tuple(map(int, m.groups())) == expected, 'incomplete strict half: ' + pattern)
    return dict(probes=probes, skipped=skipped, pins=pins, guarded_names=guarded,
                valid_rows=pop['valid_execution_rows'], skip_names=skips[2] if skips else '')

def native(log):
    require(len(re.findall(r'^ok  const_return\(', log, re.M)) == 5, 'native constant case count')
    require(len(re.findall(r'^JIT native_store: rows=16 native=6 helpers=10 assertions=246 status=PASS$', log, re.M)) == 1,
            'fixed native matrix is incomplete')
    require('JIT smoke: all cases passed.' in log and 'FAIL native_store' not in log, 'native assertion failure')
    return dict(constants=5, rows=16, native_stores=6, helpers=10, assertions=246)

def jit_audit(log, pop):
    m = re.search(r'^jit_diff: OK \((\d+) programs x \{jit, osr\} vs the interpreter; suite-env completed=(\d+); OBS examined=(\d+) denied=(\d+); (\d+) arms adjudicated; (\d+) ledgered\)$', log, re.M)
    require(m is not None, 'missing independent JIT verdict')
    values = tuple(map(int, m.groups()))
    require(values[:4] == (pop['programs'], pop['jit_suite_env'], pop['obs_examined'], pop['obs_denied']), 'JIT/OBS population differs from frozen inventory')
    require(values[5] == pop['ledgers']['tests/jit_diff_expected.txt']['rows'], 'JIT expected ledger population differs')
    return dict(programs=values[0], suite_env=values[1], obs_examined=values[2], obs_denied=values[3], adjudicated=values[4], ledgered=values[5])

def replay_audit(log, pop):
    m = re.search(r'^replay_diff: OK \((\d+) programs record\+replay; (\d+) at the documented boundary; (\d+) nondeterministic; (\d+) ledgered\)$', log, re.M)
    require(m is not None, 'missing independent replay verdict')
    values = tuple(map(int, m.groups()))
    require(values[0] == pop['programs'] and values[3] == pop['ledgers']['tests/replay_diff_expected.txt']['rows'], 'replay corpus/ledger differs')
    return dict(programs=values[0], boundary=values[1], nondeterministic=values[2], ledgered=values[3])

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--baseline', type=Path)
    ap.add_argument('--evidence', type=Path)
    ap.add_argument('--execute', action='store_true')
    args = ap.parse_args()
    manifest = json.loads((PKG/'source-manifest.json').read_text())
    pop = json.loads((PKG/'gate-populations.json').read_text())
    candidate = args.candidate.resolve()
    require(manifest['finalized'] is True, 'provisional package may not run')
    require(sha(PKG/'candidate.patch') == manifest['patch_sha256'], 'patch SHA256 differs')
    require(sha(PKG/'capture-exit.sh') == json.loads((PKG/'capture-compatibility.json').read_text())['wrapper_sha256'], 'untested capture wrapper')
    verify(candidate, manifest, True)
    for f, v in pop['source_provenance'].items():
        require(sha(candidate/f) == v['sha256'], 'gate source differs: ' + f)
    require((candidate/'.github/requirements-release.txt').read_bytes() == (PKG/'requirements-release.txt').read_bytes(), 'dependency lock differs')
    require(sorted(p.name for p in (candidate/'bench').glob('*.eigs')) == pop['performance']['gate_workloads'], 'performance workload inventory differs')
    require(set(manifest['bench_workloads']).issubset(pop['performance']['gate_workloads']), 'fixed six-workload bar diminished')
    require(re.search(r'^THRESHOLD_PCT=5$', (candidate/'bench/check_regression.sh').read_text(), re.M), 'performance threshold changed')
    if args.baseline:
        verify(args.baseline.resolve(), manifest, False)
    if not args.execute:
        print(json.dumps(dict(status='INPUTS_VERIFIED_ONLY', baseline=manifest['baseline'], candidate_tree=manifest['candidate_tree'])))
        return 0
    require(args.baseline is not None and args.evidence is not None, 'execution needs separate baseline and evidence paths')
    baseline, evidence = args.baseline.resolve(), args.evidence.resolve()
    require(candidate != baseline, 'baseline must be a separate checkout')
    require(not evidence.exists(), 'evidence directory must be new; preserve all prior runs')
    for source in (candidate, baseline):
        require(not evidence.is_relative_to(source) and not PKG.is_relative_to(source), 'artifacts must be outside source checkouts')
    evidence.mkdir(parents=True)
    (evidence/'logs').mkdir()
    env = os.environ.copy()
    # Explicit neutral state; no environment dump. Standard compiler flags come from the frozen Makefile.
    removed = sorted(k for k in env if k.startswith(('EIGS_', 'REPLAY_DIFF_', 'PRECHECK_', 'SUITE_LABEL_', 'MAKE')) or k in ('ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS', 'CC', 'CFLAGS', 'CPPFLAGS', 'LDFLAGS', 'LD_PRELOAD'))
    for k in removed:
        env.pop(k, None)
    env.update(SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
    (evidence/'selection-state.json').write_text(json.dumps({'removed_override_names':removed,'complete_suites':True}, indent=2)+'\n')
    names = ['dependency-preflight','release-build','release-suite','asan-build','asan-suite','restore-release','native-build-plan','native-smoke','jit-differential','replay-differential','baseline-build','strict-differential','precheck','test-changed','suite-label','performance-gate']
    names += [f'ir-{p}-{w}' for w in pop['performance']['gate_workloads'] for p in ('baseline','candidate')]
    names += ['performance-ratios','final-source-identities']
    phases = {n:dict(status='NOT_RUN') for n in names}
    def save():
        (evidence/'phase-ledger.json').write_text(json.dumps(phases, indent=2)+'\n')
        status = 'COMPLETE' if all(p['status']=='PASS' for p in phases.values()) else 'INCOMPLETE'
        text = f'# #1452 validation: {status}\n\nBase `{manifest["baseline"]}`; candidate tree `{manifest["candidate_tree"]}`.\n\n'
        text += '| Phase | Status | Process exit | Evidence |\n|---|---|---:|---|\n'
        for name, row in phases.items():
            text += f'| {name} | {row["status"]} | {row.get("exit", "")} | {row.get("log", "")} |\n'
        for name, row in phases.items():
            if row.get('blocker'):
                text += f'\n{name}: {row["blocker"]}\n\n'
        text += '\nCounters, exact argv/cwd/exits, native/differential populations and raw Ir ratios are in phase-ledger.json. Every allowed skip remains in its complete raw log. Frozen differential ledgers are copied in evidence. No green verdict is inferred from a Cloud READY state.\n'
        (evidence/'REPORT.md').write_text(text)
    save()
    (evidence/'source-manifest.json').write_bytes((PKG/'source-manifest.json').read_bytes())
    (evidence/'gate-populations.json').write_bytes((PKG/'gate-populations.json').read_bytes())
    for name in pop['jit_replay']['ledgers']:
        (evidence/Path(name).name).write_bytes((candidate/name).read_bytes())
    def phase(name, argv, cwd=candidate, additions=None, audit=None):
        log = evidence/'logs'/f'{name}.log'
        row = phases[name]
        row.update(status='RUNNING', argv=list(map(str,argv)), cwd=str(cwd), log=str(log.relative_to(evidence)))
        save()
        try:
            phase_env = dict(env)
            phase_env.update(additions or {})
            with log.open('wb') as f:
                result = subprocess.run(argv, cwd=cwd, env=phase_env, stdout=f, stderr=subprocess.STDOUT)
            row['exit'] = result.returncode
            output = log.read_text(errors='replace')
            row['raw_summaries'] = [s for s in output.splitlines() if re.search(r'RESULTS:|\b(?:passed|failed|skipped|SKIP|NOT RUN LOCALLY|programs|rows|assertions|sections|labelled echo lines)\b', s)][-60:]
            save()  # Real exit is persisted before semantic parsing.
            require(result.returncode == 0, 'command exited ' + str(result.returncode))
            if audit:
                row['receipt'] = audit(log.read_text(errors='replace'), result.returncode)
            row['status'] = 'PASS'
            save()
        except Exception as error:
            row.update(status='BLOCKED_SETUP' if name=='dependency-preflight' else 'FAIL', blocker=str(error))
            save()
            raise
    try:
        phase('dependency-preflight', ['bash',str(PKG/'dependency-setup.sh'),str(candidate),str(evidence)])
        env['PATH'] = (evidence/'setup/selected-path.txt').read_text().rstrip('\n')
        phase('release-build', ['make'])
        for suite, build, additions in [('release-suite',None,{}), ('asan-suite','asan-build',{'ASAN_OPTIONS':'detect_leaks=1'})]:
            if build:
                phase(build, ['make','asan'])
            capture = evidence/f'{suite}-final-counters.txt'
            phase(suite, ['bash',str(PKG/'capture-exit.sh'),str(candidate/'tests/run_all_tests.sh'),str(capture)],
                  cwd=candidate/'tests', additions=additions,
                  audit=lambda log, rc, capture=capture: counters(log,capture,rc))
        phase('restore-release', ['make'])
        phase('native-build-plan', ['make','-n','jit-smoke'])
        phase('native-smoke', ['make','jit-smoke'], audit=lambda log,rc:native(log))
        phase('jit-differential', ['bash','tools/jit_diff.sh'], audit=lambda log,rc:jit_audit(log,pop['jit_replay']))
        phase('replay-differential', ['bash','tools/replay_diff.sh'], audit=lambda log,rc:replay_audit(log,pop['jit_replay']))
        phase('baseline-build', ['make'], cwd=baseline)
        phase('strict-differential', ['bash','tools/strict_differential.sh',str(baseline/'src/eigenscript')], audit=lambda log,rc:strict(log,pop['strict']))
        def precheck_audit(log, rc):
            summary = re.findall(r'^precheck: (\d+) passed, (\d+) failed, (\d+) skipped in \d+s$',log,re.M)
            require(len(summary)==1, 'missing/duplicate precheck verdict')
            passed, failed, skipped = map(int,summary[0])
            require(failed==0 and passed>0 and passed+failed+skipped==pop['precheck']['declared_rows'], 'precheck row coverage differs')
            return dict(passed=passed,failed=failed,skipped=skipped,total=passed+failed+skipped)
        phase('precheck', ['make','precheck'], additions={'PRECHECK_BASE':manifest['baseline']},audit=precheck_audit)
        phase('test-changed', ['make','test-changed','BASE='+manifest['baseline']])
        phase('suite-label', ['bash','tools/suite_label_check.sh'])
        phase('performance-gate', ['bash','bench/check_regression.sh','--vs',str(baseline/'src/eigenscript')])
        irs = {}
        for workload in pop['performance']['gate_workloads']:
            irs[workload] = {}
            for name, root in [('baseline',baseline),('candidate',candidate)]:
                raw = evidence/f'cachegrind-{name}-{workload}.out'
                def ir_audit(log, rc, raw=raw):
                    data = raw.read_text()
                    events = re.findall(r'^events: (.+)$',data,re.M)
                    summaries = re.findall(r'^summary: (.+)$',data,re.M)
                    require(len(events)==len(summaries)==1, 'missing/duplicate raw Cachegrind events/summary')
                    fields = events[0].split()
                    require(fields.count('Ir')==1, 'missing/duplicate Ir event')
                    values = summaries[0].split()
                    require(len(values)==len(fields), 'Cachegrind summary width')
                    value = int(values[fields.index('Ir')])
                    require(value>0, 'empty/nonpositive instruction measurement')
                    return {'Ir':value,'raw':raw.name}
                phase(f'ir-{name}-{workload}', ['valgrind','--tool=cachegrind','--cachegrind-out-file='+str(raw),str(root/'src/eigenscript'),str(candidate/'bench'/workload)], audit=ir_audit)
                irs[workload][name] = phases[f'ir-{name}-{workload}']['receipt']['Ir']
        ratios = []
        for workload, pair in irs.items():
            percent = (decimal.Decimal(pair['candidate']) / decimal.Decimal(pair['baseline']) - 1)*100
            ratios.append(dict(workload=workload, **pair, percent=str(percent), within_limit=percent<=5))
        phases['performance-ratios'] = dict(status='PASS' if all(r['within_limit'] for r in ratios) else 'FAIL', receipt=ratios)
        (evidence/'instruction-ratios.json').write_text(json.dumps(ratios,indent=2)+'\n')
        save()
        require(phases['performance-ratios']['status']=='PASS', 'direct instruction ratio exceeds unchanged 5% limit')
        verify(candidate,manifest,True)
        verify(baseline,manifest,False)
        phases['final-source-identities'] = dict(status='PASS',receipt={'baseline':manifest['baseline'],'candidate_tree':manifest['candidate_tree']})
        save()
        print('COMPLETE: all required phases accepted; review raw evidence before integration')
        return 0
    except Exception as error:
        try:
            verify(candidate,manifest,True)
            verify(baseline,manifest,False)
            phases['final-source-identities'] = dict(status='PASS',receipt={'baseline':manifest['baseline'],'candidate_tree':manifest['candidate_tree']})
        except Exception as identity_error:
            phases['final-source-identities'].update(status='FAIL',blocker=str(identity_error))
        save()
        print('INCOMPLETE:',error,file=sys.stderr)
        return 1

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('BLOCKED_SOURCE:',error,file=sys.stderr)
        sys.exit(2)
