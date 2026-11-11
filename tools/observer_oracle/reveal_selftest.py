"""Bounded fixtures for reveal.py. No runtime builds, live draws or scores.

Expected values are fixed from the registration/R30R-2, not computed by the
implementation under test. Sweep runner imports run() against each mutant.
"""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import urllib.error
from unittest.mock import patch
from fractions import Fraction as Q


def verdict(v='PASS', failures=(), missing=()):
    names = ('1 standard parity', '2 vs INC', '2 vs R3-STD', '3 safety', '4 trivial floor', '5 unit invariance', '6 existing gates')
    return {'verdict': v, 'rules': [[n, 'FAIL' if n in failures else 'NOT EVALUATED' if n in missing else 'PASS', 'fixture'] for n in names]}



# R30R-5 fixture evidence uses the frozen judge's registered name domains.
# These literals are independent of R.registered_rules/validate_decisions.
FIXTURE_PREDS = ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')
FIXTURE_RUNTIME = ('R3', 'R3-STD', 'INC', 'ANCHOR', 'CF', 'W4')
FIXTURE_ROSTER = {a: FIXTURE_PREDS for a in ('R3', 'R3-STD', 'INC', 'ANCHOR', 'CF', 'W4', 'STD', "STD'", 'REF', 'C0', 'C1')}
FIXTURE_ROSTER.update({"STD''": ('equilibrium',), 'D2': ('improving',),
                       'PERSIST': ('converged', 'stable', 'equilibrium'), 'T001': ('converged',)})


def registered_verdict(predicate, subject='R3', failures=(), missing=()):
    names = ['1 standard parity', '2 vs INC']
    if predicate in ('converged', 'stable') and subject != 'R3-STD':
        names += ['2 vs R3-STD']
    if predicate in ('converged', 'stable', 'equilibrium', 'diverging'):
        names += ['3 safety']
    names += ['4 trivial floor', '5 unit invariance', '6 existing gates']
    rules = [[n, 'FAIL' if n in failures else 'NOT EVALUATED' if n in missing else 'PASS', 'fixture'] for n in names]
    result = 'FAIL' if any(r[1] == 'FAIL' for r in rules) else 'INCOMPLETE' if any(r[1] == 'NOT EVALUATED' for r in rules) else 'PASS'
    return {'verdict': result, 'rules': rules}


def fixture_decisions():
    return {a: {p: registered_verdict(p, a, ('2 vs INC',) if a in ('CF', 'W4') else ())
                for p in FIXTURE_PREDS} for a in ('R3', 'R3-STD', 'CF', 'W4')}


def complete_raw(status='COMPLETE', dry=True, primary='H1'):
    decisions = fixture_decisions()
    controls = {'a': True, 'b': True, 'c1': True, 'c2': True}
    rc = 0
    if status == 'VOID':
        controls['a'] = False
    elif status == 'INCOMPLETE':
        rc = 2
    elif status == 'FINDING':
        rc = 1
    population = {
        'judge_rc': rc, 'findings': [], 'decisions': decisions,
        'rows': {'fixture': {'id': 'fixture', 'family': 'F15 fixture', 'checkpoints': [1]}},
        'labels': {'fixture@1': {p: ['MATH', False, 'fixture'] for p in FIXTURE_PREDS}},
        'readings': [[a, 'fixture', 1, p, False] for a, ps in FIXTURE_ROSTER.items() for p in ps],
        'points': [['CF', p, '1/2'] for p in FIXTURE_PREDS],
        'diffs': [['STD', 'T001', 'converged', '1/20', '0.001', '0.1', '0']]}
    return {'status': status, 'dry': dry, 'seed': 1758, 'resamples': 1000,
            'primary': primary, 'controls': controls,
            'preflight': {a: {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}}
                          for a in ('R3', 'R3-STD')},
            'populations': {primary: population}}


def refusal_result(R, call):
    try:
        call()
    except R.Refusal:
        return 'REFUSED'
    return 'accepted'

def cases(R):
    """Yield named (call, exact expectation) fixtures, including old STOP witnesses."""
    p = verdict()
    f = verdict('FAIL', ('2 vs INC',))
    yield 'ship-R3-first-match', lambda p=p: R.outcome(p, p), {'ship':'R3','silent_wrong':False,'STD_p_on_H2':False}
    yield 'ship-R3-STD', lambda p=p: R.outcome(f, p), {'ship':'R3-STD','silent_wrong':False,'STD_p_on_H2':False}
    yield 'retain-INC', lambda: R.outcome(f, f), {'ship':'INC','silent_wrong':False,'STD_p_on_H2':False}
    for fallback, other in [('R3-STD', p), ('INC', f)]:
        yield 'silent-wrong-'+fallback, lambda other=other: R.outcome(verdict('FAIL', ('4 trivial floor',)), other), {'ship':fallback,'silent_wrong':True,'STD_p_on_H2':False}
        yield 'H2-'+fallback, lambda other=other: R.outcome(verdict('FAIL', ('1 standard parity',)), other), {'ship':fallback,'silent_wrong':False,'STD_p_on_H2':True}
    yield 'STOP-1-overlap', lambda: R.outcome(verdict('FAIL', ('2 vs INC','3 safety','4 trivial floor')), f), {'ship':'INC','silent_wrong':True,'STD_p_on_H2':False}
    yield 'STOP-1-shipping-conflict', lambda p=p: R.outcome(verdict('FAIL', ('2 vs R3-STD','3 safety')), p), {'ship':'R3-STD','silent_wrong':False,'STD_p_on_H2':False}
    yield 'STOP-3-only-rule6', lambda p=p: R.outcome(verdict('FAIL', ('6 existing gates',)), p), {'ship':'R3-STD','silent_wrong':False,'STD_p_on_H2':False}
    for name in ['2 vs INC','2 vs R3-STD','3 safety','4 trivial floor','5 unit invariance']:
        for state in ['FAIL','NOT EVALUATED']:
            x = verdict('FAIL', ('1 standard parity',))
            next(r for r in x['rules'] if r[0] == name)[1] = state
            yield 'H2-veto-'+name+'-'+state, lambda x=x: R.outcome(x, f)['STD_p_on_H2'], False
    yield 'silent-duty-no-rule1', lambda: R.outcome(verdict('FAIL', ('3 safety',)), f)['silent_wrong'], False
    good = {'floor_exit':0,'declarations':[],'capabilities':{'ieee':True,'int64':True}}
    yield 'preflight-green', lambda: R.preflight_ok(good), True
    for key, val in [('floor_exit',1),('floor_exit',2),('declarations',['R3 declared']),('capabilities',{'ieee':False,'int64':True}),('capabilities',{'ieee':True,'int64':False})]:
        bad = good | {key:val}
        yield 'preflight-refusal-'+str(val), lambda bad=bad: R.preflight_ok(bad), False
    for dry, cal, subjects, want in [(True,False,['inc','anc'],None),(True,True,['phase2','phase2'],None),(False,False,['phase2','phase2'],None),(True,False,['phase2','inc'],'REFUSED'),(True,False,['inc','phase2'],'REFUSED')]:
        def call(dry=dry,cal=cal,subjects=subjects):
            try: return R.dry_guard(dry,cal,subjects,['inc','anc'])
            except R.Refusal: return 'REFUSED'
        yield 'dry-'+str((dry,cal,subjects)), call, want
    complete = {'a':True,'b':True,'c1':True,'c2':True}
    ds = {a:{pr:verdict() for pr in R.J.PREDS} for a in ('R3','R3-STD','CF','W4')}
    yield 'status-green', lambda: R.status_for(0,ds,complete), 'COMPLETE'
    for key in complete:
        yield 'VOID-'+key, lambda key=key: R.status_for(0,ds,complete | {key:False}), 'VOID'
    for rc, want in [(1,'FINDING'),(2,'INCOMPLETE'),(3,'INCOMPLETE'),(-9,'INCOMPLETE')]:
        yield 'judge-exit-'+str(rc), lambda rc=rc: R.status_for(rc,ds,complete), want
    yield 'judge-INCOMPLETE-verdict', lambda: R.status_for(0,{'R3':{'converged':verdict('INCOMPLETE')}},complete), 'INCOMPLETE'
    pts = {p:Q(1,2) for p in R.J.PREDS}
    ctlv = {a:{p:verdict('FAIL', ('2 vs INC',)) for p in R.J.PREDS} for a in ('CF','W4')}
    yield 'controls-green', lambda: R.controls_ok(True,pts,ctlv,(Q(1,20),0.000000001)), complete
    yield 'plant-a', lambda: R.controls_ok(False,pts,ctlv,(Q(1,20),0.01))['a'], False
    for p in R.J.PREDS:
        for delta in [-Q(1,100000),Q(1,100000)]:
            yield 'CF-BA-'+p+str(delta), lambda p=p,delta=delta: R.controls_ok(True,pts | {p:Q(1,2)+delta},ctlv,(Q(1,20),0.01))['b'], False
        for arm, control in [('CF','b'),('W4','c1')]:
            bad = copy.deepcopy(ctlv);bad[arm][p] = verdict('PASS')
            yield arm+'-must-fail-'+p, lambda bad=bad,control=control: R.controls_ok(True,pts,bad,(Q(1,20),0.01))[control], (arm == 'W4' and p != 'converged')
    for d,lo,want in [(Q(1,20),0,False),(Q(1,20)-Q(1,100000),0.01,False),(Q(1,20),None,False),(None,0.01,False)]:
        yield 'c2-margin-'+str((d,lo)), lambda d=d,lo=lo: R.controls_ok(True,pts,ctlv,(d,lo))['c2'], want
    # Independent roster literal, so removing an arm in the driver turns red.
    runtime = ('R3','R3-STD','INC','ANCHOR','CF','W4')
    domains = {a:tuple(R.J.PREDS) for a in ['R3','R3-STD','INC','ANCHOR','CF','W4','STD',"STD'",'REF','C0','C1']}
    domains.update({"STD''":('equilibrium',),'D2':('improving',),'PERSIST':('converged','stable','equilibrium'),'T001':('converged',)})
    yield 'roster-runtime-definition', lambda: R.RUNTIME, runtime
    yield 'roster-comparator-definition', lambda: R.ROSTER, domains
    def roster(records,scored,sealed):
        try:return R.check_roster(records,scored,sealed)
        except R.Refusal:return 'INCOMPLETE'
    yield 'roster-green', lambda: roster(runtime,domains,runtime), None
    for a in runtime:
        others=tuple(b for b in runtime if b!=a)
        yield 'roster-missing-'+a, lambda others=others:roster(others,domains,runtime), 'INCOMPLETE'
        yield 'roster-unsealed-'+a, lambda others=others:roster(runtime,domains,others), 'INCOMPLETE'
    for a in domains:
        fewer={b:ps for b,ps in domains.items() if b!=a}
        yield 'roster-unscored-'+a, lambda fewer=fewer:roster(runtime,fewer,runtime), 'INCOMPLETE'
        for p in domains[a]:
            wrong=domains | {a:tuple(x for x in domains[a] if x!=p)}
            yield 'roster-domain-'+a+'-'+p, lambda wrong=wrong:roster(runtime,wrong,runtime), 'INCOMPLETE'
    for status in ['VOID','INCOMPLETE','REFUSED','FINDING']:
        raw=complete_raw(status)
        def no_outcome(raw=raw):
            try:
                table=R.extract(raw)
            except R.Refusal:
                return 'REFUSED'
            return table['status'], 'predicates' not in table
        yield 'no-outcome-'+status, no_outcome, 'REFUSED' if status=='REFUSED' else (status,True)
    def extract():
        return R.extract(complete_raw())
    yield 'extract-all-predicates', lambda: sorted(extract()['predicates']), sorted(R.J.PREDS)
    yield 'extract-priority', lambda: extract()['predicates']['converged']['ship'], 'R3'
    def manual():
        row=R.J.F.f8(0,0,R.J.F.rng(1,8,0),1)
        record=json.loads(R.manual_review.DEFAULT.read_text())
        for entry in record['templates']:entry['verdict']=''
        try: R.manual_review.check_manual_reviews({'rows':[row]},record)
        except ValueError as e:return row['id'] in str(e)
        return False
    yield 'unreviewed-manual-names-row', manual, True
    def retry(code=425, repeats=1):
        good={'round':1,'randomness':'ab'*32,'signature':'ignored'}
        failures=[urllib.error.HTTPError('https://api.drand.sh',code,'fixture',None,None)]*repeats
        with patch.object(R.seal,'fetch',side_effect=failures+[good]) as fetch,patch.object(R.seal,'checked',return_value=(1,'ab'*32)),patch.object(R.J.F,'build',return_value={}),patch.object(R.J.F,'write'),patch.object(R.J.F,'write_manifest'),patch.object(R.time,'sleep') as sleep:
            try:
                R.sealed_set(1,Path('unused'),retries=2,delay=0)
                return (fetch.call_count,sleep.call_count,'ok')
            except R.Refusal:return(fetch.call_count,sleep.call_count,'REFUSED')
    yield '425-retry-green', retry, (2,1,'ok')
    yield '425-bound-refusal', lambda:retry(425,2), (2,1,'REFUSED')
    yield 'non425-no-retry', lambda:retry(404,2), (1,0,'REFUSED')


def contract_scope(R):
    """The old STOP-2 witness uses the REAL frozen decide(), not a copy."""
    arms=['R3','R3-STD','INC','STD']; calls=[]
    point={(a,p):Q(7,10) if a=='INC' else Q(4,5) for a in arms for p in R.J.PREDS}
    fpr={ap:Q(1,10) for ap in point}
    def diff(a,b,p):
        calls.append((a,b,p));d=point[a,p]-point[b,p];return d,float(d-Q(1,100)),float(d+Q(1,100)),0
    caps={'R3':{'ieee':True,'int64':True}}
    flips={('R3',p):0 for p in R.J.PREDS};compared={k:20 for k in flips}
    with tempfile.TemporaryDirectory() as d:
        decl=Path(d)/'decl';decl.write_text('')
        with contextlib.redirect_stdout(io.StringIO()):
            R.J.decide({'floor-exit':'0','declarations':str(decl)},'R3',arms,point,fpr,diff,flips,compared,20,caps)
    return sorted(p for a,b,p in calls if b=='R3-STD')


def run(R, plant=None, quiet=False, prefer=()):
    from itertools import chain
    def declarations():
        if plant!='empty':
            yield from cases(R)
            yield ('STOP-2-amendment-scope',lambda:contract_scope(R),['converged','stable'])
    def ordered():
        source=iter(declarations())
        pending=[]
        if prefer:
            for fixture in source:
                if fixture[0]==prefer[0]:
                    yield fixture
                    break
                pending.append(fixture)
        yield from chain(pending,source)
    failed=[]
    examined=0
    for name,call,want in ordered():
        examined+=1
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):got=call()
            if plant==name:got='planted wrong answer'
            ok=got==want
            detail=repr(got)
        except (Exception, SystemExit) as e:ok=False;detail=type(e).__name__+': '+str(e)
        if not ok:
            failed.append(name)
            if quiet:return failed
        if not quiet:print(f"CHECK {'ok' if ok else 'FAIL'}: {name}" + ('' if ok else ' got '+detail))
        if not ok and name.startswith('R6-'):
            return failed if quiet else 1
    if not examined:
        if not quiet:print('CHECK FAIL: nonempty-fixture-table')
        return 1
    if quiet:return failed
    print(f'reveal checks: {examined} examined, {examined-len(failed)} ok, {len(failed)} failed')
    return int(bool(failed))


def main_case(R, mode='calibration', bad=None, detail=False, commitment=None, beacon_hook=None):
    """Execute production orchestration with IO boundaries mocked, no scoring."""
    from types import SimpleNamespace
    with tempfile.TemporaryDirectory() as tmp:
        out=Path(tmp)/'run'
        def resolve(sha):
            return {'3d8a14b4':'inc','3eed5caf':'std',R.ANCHOR:'anc'}.get(sha,sha)
        def build(name,sha,out):return {'binary':'fixture-'+name}
        def floor(binary,out,name):
            return {'floor_exit':1 if bad=='floor' and name=='R3' else 0,'declarations':[], 'capabilities':{'int64':True,'ieee':True}}
        def manifest(path,bins):
            m={'arms':dict(bins),'code':{'judge.py':'fixture'}}
            (Path(path)/'manifest.json').write_text(json.dumps(m));return m
        def population(paths,bins,facts,seed,resamples,out,name):
            if bad=='harness':raise R.J.HarnessError('planted manifest mismatch')
            ds=fixture_decisions()
            rows={'fixture':{'id':'fixture','family':'fixture','checkpoints':[1]}}
            labels={'fixture@1':{p:['MATH',False,'fixture'] for p in R.J.PREDS}}
            return {'decisions':ds,'judge_rc':1 if bad=='finding' else 2 if bad=='incomplete' else 0,'points':[['CF',p,'1/2'] for p in R.J.PREDS], 'diffs':[['STD','T001','converged','1/20','0.001','0.1','0']], 'rows':rows,'labels':labels,'readings':[[a,'fixture',1,p,False] for a,ps in R.ROSTER.items() for p in ps]}
        with patch.object(R,'install_instrument',return_value={'score_sha256':R.SCORE_SHA256}),patch.object(R.J.score,'capabilities',return_value=(None,{'int64':True,'ieee':True})),patch.object(R,'resolve',side_effect=resolve),patch.object(R,'build',side_effect=build),patch.object(R,'floor',side_effect=floor),patch.object(R.J.F,'write_manifest',side_effect=manifest),patch.object(R,'judge_population',side_effect=population),patch.object(R,'command',return_value=SimpleNamespace(returncode=0,stdout='RED  floor-each rc=1\nplants: 1 examined, 1 red (controls included: green is their red)\n')),patch.object(R,'verify_commitment',return_value=None,side_effect=commitment),patch.object(R,'sealed_set',return_value={'round':1},side_effect=beacon_hook) as beacon,patch.object(R,'prepare_set',return_value={'manifest':{'arms':dict.fromkeys(R.RUNTIME)},'sha256':'fixture'}):
            argv=['--out',str(out),'--r3','inc' if mode=='seal' else 'std','--r3-std','inc' if mode=='seal' else 'std','--dry','--resamples','1000']
            argv+=['--round','1'] if mode=='seal' else ['--calibration']
            try:rc=R.main(argv)
            except R.Refusal:
                return (2,'REFUSED',[],0,beacon.call_count)
            raw=json.loads((out/'raw.json').read_text());table=json.loads((out/'decision.json').read_text()) if (out/'decision.json').exists() else {}
            return raw if detail else (rc,raw['status'],sorted(raw['populations']),len(table.get('predicates',{})),beacon.call_count)


_old_cases=cases

def cases(R):
    yield from _old_cases(R)
    yield 'orchestration-calibration', lambda:main_case(R), (0,'COMPLETE',['calibration','hcal'],6,0)
    yield 'orchestration-seal', lambda:main_case(R,'seal'), (0,'COMPLETE',['H1','calibration','hcal'],6,1)
    yield 'preflight-before-beacon', lambda:main_case(R,'calibration','floor'), (2,'REFUSED',[],0,0)
    yield 'FINDING-no-outcomes', lambda:main_case(R,'calibration','finding'), (2,'FINDING',['calibration','hcal'],0,0)
    yield 'INCOMPLETE-no-outcomes', lambda:main_case(R,'calibration','incomplete'), (2,'INCOMPLETE',['calibration','hcal'],0,0)
    yield 'preflight-no-caps', lambda:R.preflight_ok({'floor_exit':0,'declarations':[],'capabilities':{}}),False

_extra_cases=cases
def cases(R):
    yield from _extra_cases(R)
    yield 'harness-exception-raw-INCOMPLETE', lambda:main_case(R,'calibration','harness'), (2,'INCOMPLETE',[],0,0)


def observed_population(R):
    """Real recording wrapper + real decide, tiny mocked measurement boundary."""
    row={'id':'r','family':'fixture','gen':{'kind':'cycle','values':[1.0]},'n':1,'checkpoints':[1]}
    labels={'r@1':{p:['MATH',True,'fixture'] for p in R.J.PREDS}}
    bins={'R3':'same','R3-STD':'same','INC':'same','ANCHOR':'anchor','CF':'cf','W4':'w4'}
    read={(t,f,'r',1,p):True for t,f in [('interp','straight'),('jit','straight'),('interp','loop'),('jit','loop')] for p in R.J.PREDS}
    def fake_run(bs,rows,seed):
        order=[(a,'r') for a in reversed(bs)]
        got={a:{} for a in bs}
        for a,r in order:
            result=R.J.score.measure(bs[a],{'rows':[row]}, {})
            got[a][r]={(1,p):True for p in R.J.PREDS}
        return got,[],set(),order,{a:{'ieee':True,'int64':True} for a in bs}
    def fake_main(argv):
        assert argv[argv.index('--tol-converged')+1]=='T001=0.01'
        assert argv[argv.index('--const-false')+1]=='CF=cf'
        assert [argv[i+1] for i,x in enumerate(argv) if x=='--subject']==['R3','R3-STD','CF','W4']
        R.J.run_arms(bins,{'r':row},1758)
        arms=list(bins)+list(R.J.S.ARMS)+['T001']
        pts={(a,p):Q(9,10) if a=='R3' else Q(8,10) if a=='R3-STD' else Q(7,10) for a in arms for p in R.J.PREDS}
        fpr={k:Q(1,10) for k in pts}
        def diff(a,b,p):
            d=pts[a,p]-pts[b,p];return d,float(d-Q(1,100)),float(d+Q(1,100)),0
        flips={(a,p):0 for a in bins for p in R.J.PREDS}; compared={k:2 for k in flips}
        caps={a:{'ieee':True,'int64':True} for a in bins}
        for a in ['R3','R3-STD','CF','W4']:
            R.J.decide({},a,arms,pts,fpr,diff,flips,compared,2,caps)
        return 0
    with tempfile.TemporaryDirectory() as tmp,patch.object(R.J,'load',return_value=({'rows':[row]},labels)),patch.object(R.J,'run_arms',side_effect=fake_run),patch.object(R.J.score,'measure',return_value={'read':read}),patch.object(R.J,'main',side_effect=fake_main),patch.object(R.J,'generate',return_value=[1.0,1.0]):
        facts={a:{'floor_exit':0,'declarations':[]} for a in ['R3','R3-STD']}
        return R.judge_population([Path(tmp)],bins,facts,1758,1000,Path(tmp),'fixture')


def population_fixture(R):
    labels={'r@1':{'converged':['MATH',True]},'r@2':{'converged':['MATH',False]}}
    # Restrict domain only at this pure extractor boundary for an auditable matrix.
    with patch.object(R,'ROSTER',{'A':('converged',),'B':('converged',)}):
        return R.whole_population({'rows':{'r':{'family':'fixture','checkpoints':[1,2]}},'labels':labels,
            'readings':[['A','r',1,'converged',True],['A','r',2,'converged',True],['B','r',1,'converged',False]]})


_more_cases=cases

def cases(R):
    yield from _more_cases(R)
    yield 'c2-float-round-trip',lambda:R.control_diff(['STD','T001','converged','1/20','5e-10','0','0']),(Q(1,20),5e-10)
    yield 'c2-positive-half-boundary',lambda:R.J.rule2('converged',R.control_diff(['STD','T001','converged','1/20','5e-10','0','0'])[0],R.J.ci_bound(R.control_diff(['STD','T001','converged','1/20','5e-10','0','0'])[1])),True
    yield 'whole-population-literal',lambda:population_fixture(R),{'confusion':{'["A", "converged", "fixture"]':[1,1,0,0],'["B", "converged", "fixture"]':[0,0,1,0]},'disagreements':[['A','r',2,'converged',False,True],['B','r',1,'converged',True,False]],'absent':[['B','r',2,'converged']]}
    yield 'captured-runtime-tiers',lambda:len(observed_population(R)['tiers']),144
    yield 'captured-tier-arm-identity',lambda:sorted({r[0] for r in observed_population(R)['tiers']}),['ANCHOR','CF','INC','R3','R3-STD','W4']
    yield 'captured-runtime-readings',lambda:sum(1 for row in observed_population(R)['readings'] if row[0]=='R3'),6
    yield 'captured-rule-statuses',lambda:[r[1] for r in observed_population(R)['decisions']['R3']['converged']['rules']],['PASS']*7
    yield 'captured-rule-count',lambda:len(observed_population(R)['decisions']['R3-STD']['converged']['rules']),6
    yield 'captured-verdict',lambda:observed_population(R)['decisions']['R3']['stable']['verdict'],'PASS'
    yield 'captured-order',lambda:observed_population(R)['order'],[('W4','r'),('CF','r'),('ANCHOR','r'),('INC','r'),('R3-STD','r'),('R3','r')]

_final_cases=cases

def cases(R):
    yield from _final_cases(R)
    def disk():
        raw=complete_raw()
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'first';out.mkdir();R.write_outputs(raw,out)
            other=Path(d)/'second'
            R.main(['--extract',str(out/'raw.json'),'--out',str(other)])
            return (out/'decision.json').read_bytes()==(other/'decision.json').read_bytes()
    yield 'raw-disk-extraction-byte-equality',disk,True


def recipe_fixture(R,name='R3',bad=False):
    from types import SimpleNamespace
    stamp={'binary':'fixture','binary_sha256':'bytes'}
    rec={'source_sha':'commit','recipe_id':'pin','binary_sha256':'wrong' if bad else 'bytes'}
    with tempfile.TemporaryDirectory() as d,patch.object(R,'command',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(stamp))) as cmd,patch.object(R.J.F,'arm_record',return_value=rec),patch.object(R.J.F,'sha',return_value='pin'):
        try:
            got=R.build(name,'commit',Path(d))
            return (got, [str(x) for x in cmd.call_args.args[0]])
        except R.Refusal:return 'REFUSED'


def floor_fixture(R,present=True):
    from types import SimpleNamespace
    with tempfile.TemporaryDirectory() as d:
        root=Path(d);p=root/'tests/phase2/oracle_expect.txt';p.parent.mkdir(parents=True)
        if present:p.write_text('other declaration\nfoo #1830\nbar R3 reason\n')
        with patch.object(R.J.F,'arm_root',return_value=d),patch.object(R.J.F,'sha',return_value='pin'),patch.object(R.J.score,'capabilities',return_value=(None,{'int64':True,'ieee':True})),patch.object(R,'command',return_value=SimpleNamespace(returncode=0)):
            return R.floor('fixture',root,'R3')


def prepare_fixture(R):
    from types import SimpleNamespace
    with tempfile.TemporaryDirectory() as d:
        root=Path(d);corpus={'rows':[]};(root/'corpus.json').write_text(json.dumps(corpus))
        manifest={'arms':{'INC':'binary'},'code':{'judge':'pin'}}
        def command(argv,log):
            if '--write-manifest' in argv:(root/'manifest.json').write_text(json.dumps(manifest))
            return SimpleNamespace(returncode=0)
        with patch.object(R.manual_review,'check_manual_reviews',return_value=[]),patch.object(R,'command',side_effect=command) as cmd,patch.object(R.J.F,'sha',return_value='pin'):
            result=R.prepare_set(root,{'INC':'binary'},root)
            return result,[[str(x) for x in call.args[0]][2:] for call in cmd.call_args_list]


_policy_cases=cases

def cases(R):
    yield from _policy_cases(R)
    yield 'rational-None',lambda:R.rational(None),None
    yield 'rational-exact',lambda:R.rational(Q(3,5)),'3/5'
    for name,script,extra in [('R3','build_arm.sh',['commit']),('ANCHOR','build_anchor.sh',[]),('W4','build_w4.sh',[])]:
        yield 'recipe-'+name,lambda name=name:recipe_fixture(R,name),({'binary':'fixture','binary_sha256':'bytes'},['bash',str(R.HERE/script),*extra])
    yield 'recipe-stamp-mismatch',lambda:recipe_fixture(R,bad=True),'REFUSED'
    yield 'floor-declarations',lambda:floor_fixture(R),{'floor_exit':0,'declarations':['other declaration','foo #1830','bar R3 reason'],'capabilities':{'int64':True,'ieee':True},'declaration_sha256':'pin'}
    yield 'floor-missing-declarations',lambda:floor_fixture(R,False),{'floor_exit':0,'declarations':['missing declaration file'],'capabilities':{'int64':True,'ieee':True},'declaration_sha256':None}
    yield 'prepare-seal-metadata',lambda:prepare_fixture(R)[0],{'sha256':'pin','manifest':{'arms':{'INC':'binary'},'code':{'judge':'pin'}}}
    yield 'prepare-stage-options',lambda:[next(v for v in x if v.startswith('--')) for x in prepare_fixture(R)[1]],['--corpus','--corpus','--write-manifest']
    def bad_beacon():
        with tempfile.TemporaryDirectory() as d,patch.object(R.seal,'fetch',return_value={'round':2}),patch.object(R.J.F,'build') as draw:
            try:R.sealed_set(1,Path(d));return 'accepted'
            except R.Refusal:return (draw.call_count,(Path(d)/'corpus.json').exists())
    yield 'bad-beacon-refused-before-draw',bad_beacon,(0,False)
    yield 'build-env',lambda:R.build_env(),{'HOME':R.os.environ['HOME'],'PATH':'/usr/bin:/bin','LANG':'C','XDG_CACHE_HOME':str(R.ROOT/'build/observer-reveal/cache')}
    ds={a:{p:verdict() for p in R.J.PREDS} for a in ('R3','R3-STD','CF','W4')}
    controls={'a':True,'b':True,'c1':True,'c2':True}
    for a in ds:
        yield 'status-missing-subject-'+a,lambda a=a:R.status_for(0,{b:v for b,v in ds.items() if b!=a},controls),'INCOMPLETE'
        for p in R.J.PREDS:
            missing=copy.deepcopy(ds);del missing[a][p]
            yield 'status-missing-predicate-'+a+'-'+p,lambda missing=missing:R.status_for(0,missing,controls),'INCOMPLETE'
    for c in controls:
        yield 'status-missing-control-'+c,lambda c=c:R.status_for(0,ds,{k:v for k,v in controls.items() if k!=c}),'VOID'

_previous_cases = cases
def cases(R):
    yield from _previous_cases(R)
    yield 'D13-dry-INC-stand-in', lambda:R.stand_in(True, 'inc', ('inc','anchor')), True
    yield 'D13-dry-ANCHOR-stand-in', lambda:R.stand_in(True, 'anchor', ('inc','anchor')), True
    yield 'D13-real-INC-no-exemption', lambda:R.stand_in(False, 'inc', ('inc','anchor')), False
    yield 'D13-real-ANCHOR-no-exemption', lambda:R.stand_in(False, 'anchor', ('inc','anchor')), False
    yield 'D13-phase2-no-exemption', lambda:R.stand_in(True, 'phase2', ('inc','anchor')), False
    yield 'D13-full-declaration-data-refused',lambda:R.preflight_ok({'floor_exit':0,'declarations':['unrelated declaration'], 'capabilities':{'int64':True,'ieee':True}}),False


def diagnostic_fixture():
    """Independent minimal example of R30R-4/5 H-cal diagnostic, no live data."""
    raw=complete_raw('INCOMPLETE', primary='hcal')
    pop=raw['populations']['hcal']
    pop['judge_rc']=0
    pop['rows']['fixture']['family']='F6 sinusoid'
    # Keep the old diagnostic row id so its positive-label plants stay exact.
    pop['rows']={'r':pop['rows']['fixture']}
    pop['rows']['r']['id']='r'
    pop['labels']={'r@1':{p:['MATH',False,'fixture'] for p in FIXTURE_PREDS}}
    pop['readings']=[[a,'r',1,p,False] for a,ps in FIXTURE_ROSTER.items() for p in ps]
    for arm in ('R3','R3-STD'):
        for pred in FIXTURE_PREDS:
            missing=['5 unit invariance']
            if pred in ('diverging','equilibrium'):
                missing+=['1 standard parity','2 vs INC','4 trivial floor']
            pop['decisions'][arm][pred]=registered_verdict(pred,arm,missing=missing)
    pop['points']=[['CF',p,None if p in ('diverging','equilibrium') else '1/2'] for p in FIXTURE_PREDS]
    raw['populations']['calibration']=copy.deepcopy(pop)
    raw['controls']={'a':True,'b':'undefined','b_undefined':['diverging','equilibrium'],'c1':True,'c2':True}
    raw['reasons']=['no-family-15','undefined-BA:diverging,equilibrium']
    return raw


_ruling4_cases=cases

def cases(R):
    yield from _ruling4_cases(R)
    def bound(family,phi,burn):
        row={'id':'named-row','family':family,'gen':{'kind':'ar1','phi':phi,'burn':burn}}
        try:return R.check_d14({'rows':[row]})
        except R.Refusal as e:return 'named-row' in str(e) and str(e).startswith('INCOMPLETE:')
    for family in ('F9 AR1','F15 unit-scaled copies','F15b base for unit-scaled copies, from F9 AR1'):
        for phi,burn,want in [(0.9,200,['named-row']),(-0.9,200,['named-row']),(0.92,200,True),(0.9,100,True),(0.5,26,True),(0.5,27,['named-row']),(0,200,['named-row']),(0,0,True),(0.9,-1,True),(0.9,200.0,True)]:
            yield 'D14-'+family+'-'+str((phi,burn)),lambda family=family,phi=phi,burn=burn:bound(family,phi,burn),want
    yield 'D14-non-AR1',lambda:R.check_d14({'rows':[{'id':'iid','gen':{'kind':'iid'}}]}),[]
    pts={p:Q(1,2) for p in R.J.PREDS}
    for failed,want in [(('6 existing gates',),False),(('2 vs INC','6 existing gates'),True),(('3 safety',),True),(('1 standard parity',),True),(('5 unit invariance',),True),(('4 trivial floor',),True)]:
        ds={a:{p:verdict('FAIL',failed if a=='W4' else ('2 vs INC',)) for p in R.J.PREDS} for a in ('CF','W4')}
        yield 'c1-reading-rule-'+str(failed),lambda ds=ds:R.controls_ok(True,pts,ds,(Q(1,20),0.01))['c1'],want
    yield 'Dry-A-diagnostic-green',lambda:R.dry_a_ok(diagnostic_fixture()),True
    yield 'Dry-A-reasons-exact',lambda:R.incomplete_reasons(diagnostic_fixture()),['no-family-15','undefined-BA:diverging,equilibrium']
    for status in ('REFUSED','VOID','FINDING','COMPLETE'):
        yield 'Dry-A-reject-'+status,lambda status=status:R.dry_a_ok(diagnostic_fixture()|{'status':status}),False
    for key,val in [('dry',False),('primary','H1'),('error','new failure'),('reasons',['no-family-15']),('reasons',['no-family-15','undefined-BA:diverging,equilibrium','other'])]:
        yield 'Dry-A-reject-'+key+str(val),lambda key=key,val=val:R.dry_a_ok(diagnostic_fixture()|{key:val}),False
    for field in ['finding','judge','control-a','control-c1','control-c2','floor','positive','unknown-rule','F15','extra-population']:
        bad=diagnostic_fixture()
        if field=='finding':bad['populations']['calibration']['findings']=['split']
        elif field=='judge':bad['populations']['calibration']['judge_rc']=2
        elif field.startswith('control-'):bad['controls'][field[8:]]=False
        elif field=='floor':bad['preflight']['R3-STD']['floor_exit']=1
        elif field=='positive':bad['populations']['hcal']['labels']['r@1']['diverging'][1]=True
        elif field=='unknown-rule':bad['populations']['hcal']['decisions']['R3']['converged']['rules'][0][1]='NOT EVALUATED'
        elif field=='F15':bad['populations']['hcal']['rows']['r']['family']='F15 unit-scaled copies'
        elif field=='extra-population':bad['populations']['H1']={}
        yield 'Dry-A-reject-'+field,lambda bad=bad:R.dry_a_ok(bad),False
    yield 'pinned-scorer-identity',lambda:R.SCORE_SHA256,'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'
    yield 'pinned-INC',lambda:R.INC,'3d8a14b4'
    yield 'pinned-ANCHOR',lambda:R.ANCHOR,'4a3a5c1941568e9bc562c7c8221cff22dc8ba697'
    yield 'pinned-R3-STD',lambda:R.R3STD,'3eed5caf'

_last_cases=cases

def cases(R):
    yield from _last_cases(R)
    def bound(phi,burn):
        try:R.check_d14({'rows':[{'id':'bound','gen':{'kind':'ar1','phi':phi,'burn':burn}}]});return True
        except R.Refusal:return False
    yield 'D14-resolution-inside',lambda:bound('3/4',64),True
    yield 'D14-resolution-outside',lambda:bound('3/4',63),False
    yield 'c1-rule6-recorded-separately',lambda:main_case(R,detail=True)['control_c1_rule6'],[['6 existing gates','PASS','fixture']]
    yield 'dry-standin-preflight-record',lambda:[main_case(R,'seal',detail=True)['preflight'][a]['rule6'] for a in ('R3','R3-STD')],['NOT APPLICABLE (stand-in)']*2
    def unknown():
        raw=diagnostic_fixture();raw['populations']['hcal']['decisions']['R3']['converged']['rules'][0][1]='NOT EVALUATED'
        return R.incomplete_reasons(raw)
    yield 'Dry-A-unknown-rule-named',unknown,['no-family-15','undefined-BA:diverging,equilibrium','unevaluated:R3:converged:1 standard parity']
    def control():
        raw=diagnostic_fixture();raw['controls']['a']=False
        return R.incomplete_reasons(raw)
    yield 'Dry-A-failed-control-named',control,['control:a','no-family-15','undefined-BA:diverging,equilibrium']

_boundary_cases=cases

def cases(R):
    yield from _boundary_cases(R)
    def wrong_scorer():
        with patch.object(R.J.F,'arm_root',return_value='/unused'),patch.object(R.J.F,'sha',return_value='wrong'),patch.object(R.shutil,'copytree') as cp:
            try:R.install_instrument({'binary':'fixture'},Path('/unused'));return 'accepted'
            except R.Refusal:return cp.call_count
    yield 'scorer-refused-before-stage',wrong_scorer,0
    def bad_recipe(field):
        from types import SimpleNamespace
        record={'source_sha':'commit','recipe_id':'pin','binary_sha256':'bytes'};record[field]='wrong'
        with tempfile.TemporaryDirectory() as d,patch.object(R,'command',return_value=SimpleNamespace(returncode=0,stdout=json.dumps({'binary':'fixture','binary_sha256':'bytes'}))),patch.object(R.J.F,'arm_record',return_value=record),patch.object(R.J.F,'sha',return_value='pin'):
            try:R.build('R3','commit',Path(d));return False
            except R.Refusal:return True
    for field in ['source_sha','recipe_id','binary_sha256']:
        yield 'recipe-reject-'+field,lambda field=field:bad_recipe(field),True
    def floor_args():
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);decl=root/'tests/phase2/oracle_expect.txt';decl.parent.mkdir(parents=True);decl.write_text('#empty\n')
            with patch.object(R.J.F,'arm_root',return_value=d),patch.object(R.J.F,'sha',return_value='hash'),patch.object(R.J.score,'capabilities',return_value=(None,{'int64':True,'ieee':True})),patch.object(R,'command',return_value=SimpleNamespace(returncode=7)) as cmd:
                got=R.floor('binary',root,'R3');args=[str(x) for x in cmd.call_args.args[0]]
                return (got['floor_exit'],got['declarations'],args[2:],str(cmd.call_args.args[1].relative_to(root))) == (7,[],['binary','--floor',str(root/'tools/observer_oracle/floor.json'),'--declared',str(decl)],'floor-R3.log')
    yield 'floor-real-CLI-inputs',floor_args,True
    def prepare_fail(index):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'corpus.json').write_text('{"rows":[]}')
            with patch.object(R.manual_review,'check_manual_reviews'),patch.object(R,'command',side_effect=[SimpleNamespace(returncode=0)]*index+[SimpleNamespace(returncode=1)]) as cmd:
                try:R.prepare_set(root,{'INC':'binary'},root);return False
                except R.Refusal:return cmd.call_count==index+1
    for index in range(3):yield 'prepare-failure-'+str(index),lambda index=index:prepare_fail(index),True
    def d14_before_commands():
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'corpus.json').write_text(json.dumps({'rows':[{'id':'bad-burn','gen':{'kind':'ar1','phi':0.92,'burn':200}}]}))
            with patch.object(R.manual_review,'check_manual_reviews') as review,patch.object(R,'command') as cmd:
                try:R.prepare_set(root,{'INC':'binary'},root);return False
                except R.Refusal:return (review.call_count,cmd.call_count)
    yield 'D14-before-certify-or-arms',d14_before_commands,(0,0)

_schema_cases=cases

def cases(R):
    yield from _schema_cases(R)
    def schema():
        raw=main_case(R,detail=True)
        expected_keys={'format','dry','seed','resamples','populations','manifests','instrument','stamps','preflight','driver','primary','controls','control_c1_rule6','status','reasons'}
        return (set(raw)==expected_keys,raw['format'],raw['dry'],raw['seed'],raw['resamples'],raw['primary'],sorted(raw['driver']),raw['instrument'],raw['stamps'],raw['reasons'])
    yield 'raw-orchestration-schema',schema,(True,'r3-reveal/1',True,1758,1000,'hcal',['build_w4.sh','manual_review.json','manual_review.py','reveal.py','seal.py','verified_sources.json'],{'score_sha256':'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'},{a:{'binary':'fixture-'+('INC' if a=='CF' else a)} for a in ['R3','R3-STD','INC','ANCHOR','W4','CF']},[])
    def complete_extract():
        raw=complete_raw()
        return R.extract(raw)['predicates']['converged']
    yield 'canonical-subject-rules',complete_extract,{'ship':'R3','silent_wrong':False,'STD_p_on_H2':False,'subjects':{a:{'verdict':'PASS','rules':[[r[0],'PASS'] for r in registered_verdict('converged',a)['rules']]} for a in ('R3','R3-STD')}}
    def printed(dry,status):
        raw=complete_raw(status,dry)
        with tempfile.TemporaryDirectory() as d:
            buf=io.StringIO()
            with contextlib.redirect_stdout(buf):R.write_outputs(raw,Path(d))
            return buf.getvalue().splitlines()
    for dry in (True,False):
        yield 'printed-outcomes-'+str(dry),lambda dry=dry:printed(dry,'COMPLETE'),[('DRY ' if dry else '')+'OUTCOME '+p+': R3; silent-wrong=False; STD_p/H2=False' for p in ('converged','stable','improving','oscillating','diverging','equilibrium')]+['COMPLETE']
    yield 'printed-VOID-repeats-step1',lambda:printed(True,'VOID'),['VOID','failed controls: a; step 1 is repeated']
    def dumped():
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'object.json';R.dump(path,{'b':2,'a':1});return path.read_text()
    yield 'canonical-JSON-format',dumped,'{\n "a": 1,\n "b": 2\n}\n'


def resolve_fixture(R, sha='abcdef12', missing=False, fetch_failure=False):
    """Drive the real resolver with a controlled git boundary, never the network."""
    from types import SimpleNamespace
    complete='abcdef1234567890abcdef1234567890abcdef12'
    replies=[SimpleNamespace(returncode=1 if missing else 0,stdout=complete+'\n')]
    if missing:
        replies.extend([R.subprocess.CalledProcessError(23,['git','fetch']) if fetch_failure else SimpleNamespace(returncode=0),SimpleNamespace(returncode=0,stdout=complete+'\n')])
    with patch.object(R.subprocess,'run',side_effect=replies) as run:
        try:result=R.resolve(sha)
        except R.Refusal:result='REFUSED'
        except R.subprocess.CalledProcessError:result='GIT FAILED'
        calls=[(c.args,c.kwargs) for c in run.call_args_list]
        return result,calls


def cli_fixture(R, options, execute_result=17):
    """Real argparse and driver refusals; only execution is replaced."""
    with tempfile.TemporaryDirectory() as tmp:
        out=Path(tmp)/'result'
        with patch.object(R,'execute',return_value=execute_result) as execute:
            try:rc=R.main([*options,'--out',str(out)])
            except R.Refusal as error:rc=('REFUSED',str(error))
            except SystemExit as error:rc=error.code
            return rc,execute.call_count,out.exists(),(out/'raw.json').exists()


_sweep_boundary_cases=cases

def cases(R):
    yield from _sweep_boundary_cases(R)
    sha='abcdef1234567890abcdef1234567890abcdef12'
    for short in ['abcdef12',sha]:
        expected=[(([ 'git','rev-parse','--verify',short+'^{commit}'],),{'cwd':R.ROOT,'capture_output':True,'text':True})]
        yield 'resolve-present-'+str(len(short)),lambda short=short:resolve_fixture(R,short),(sha,expected)
    expected=[((['git','rev-parse','--verify','abcdef12^{commit}'],),{'cwd':R.ROOT,'capture_output':True,'text':True}),((['git','fetch','--no-tags','origin','abcdef12'],),{'cwd':R.ROOT,'check':True}),((['git','rev-parse','--verify','abcdef12^{commit}'],),{'cwd':R.ROOT,'capture_output':True,'text':True,'check':True})]
    yield 'resolve-fetch-by-SHA',lambda:resolve_fixture(R,missing=True),(sha,expected)
    yield 'resolve-fetch-failure',lambda:resolve_fixture(R,missing=True,fetch_failure=True)[0],'GIT FAILED'
    for invalid in ('not-sha','abcdef1','f'*41,'A'*40,'g'*40,'a'*40+'\n','a'*8+';echo'):
        yield 'resolve-invalid-'+repr(invalid),lambda invalid=invalid:resolve_fixture(R,invalid),('REFUSED',[])
    yield 'CLI-missing-subject',lambda:cli_fixture(R,['--dry','--calibration']),(2,0,True,False)
    yield 'CLI-missing-round',lambda:cli_fixture(R,['--dry','--r3','abcdef12']),(2,0,True,False)
    yield 'CLI-calibration-real-refused',lambda:cli_fixture(R,['--calibration','--r3','abcdef12']),(('REFUSED','calibration mode is DRY only'),0,True,False)
    for count in ('0','-1'):
        yield 'CLI-resamples-positive-'+count,lambda count=count:cli_fixture(R,['--dry','--calibration','--r3','abcdef12','--resamples',count]),(('REFUSED','registered reveal requires 10000 resamples; reduced resamples are DRY only'),0,True,False)
    for count in ('9999','10001'):
        yield 'CLI-real-registered-resamples-'+count,lambda count=count:cli_fixture(R,['--r3','abcdef12','--round','1','--resamples',count]),(('REFUSED','registered reveal requires 10000 resamples; reduced resamples are DRY only'),0,True,False)
    for options in (['--r3','abcdef12','--round','1'],['--dry','--calibration','--r3','abcdef12','--resamples','1000'],['--dry','--r3','abcdef12','--round','1','--resamples','1']):
        yield 'CLI-execution-accepted-'+repr(options),lambda options=options:cli_fixture(R,options),(17,1,True,False)
    def missing_out():
        try:R.main(['--dry','--calibration','--r3','abcdef12']);return False
        except SystemExit as error:return error.code
    yield 'CLI-output-required',missing_out,2
    def diagnostic_cli(accepted):
        raw=diagnostic_fixture()
        if not accepted:raw['status']='VOID'
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'raw.json';path.write_text(json.dumps(raw));buf=io.StringIO()
            with contextlib.redirect_stdout(buf):rc=R.main(['--check-dry-a',str(path)])
            return rc,buf.getvalue()
    yield 'CLI-dry-diagnostic-accepts',lambda:diagnostic_cli(True),(0,'Dry A diagnostic accepted\n')
    yield 'CLI-dry-diagnostic-rejects',lambda:diagnostic_cli(False),(1,'Dry A diagnostic REJECTED\n')
    def selftest_cli():
        import reveal_selftest
        with patch.object(reveal_selftest,'run',return_value=73) as run:
            rc=R.main(['--selftest'])
            return rc,run.call_count,run.call_args.args==(R,)
    yield 'CLI-selftest-real-entrypoint',selftest_cli,(73,1,True)
    def command():
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            log=Path(tmp)/'command.log';reply=SimpleNamespace(returncode=13,stdout='controlled stdout\n')
            with patch.object(R.subprocess,'run',return_value=reply) as run:
                got=R.command(['tool',Path('input'),7],log)
                return got is reply,log.read_text(),run.call_args.args,run.call_args.kwargs
    yield 'command-real-subprocess-contract',command,(True,'controlled stdout\n',(['tool','input','7'],),{'cwd':R.ROOT,'env':{'HOME':R.os.environ['HOME'],'PATH':'/usr/bin:/bin','LANG':'C','XDG_CACHE_HOME':str(R.ROOT/'build/observer-reveal/cache')},'stdout':R.subprocess.PIPE,'stderr':R.subprocess.STDOUT,'text':True,'timeout':3600})


def installed_instrument_fixture(R):
    """Stage controlled files through the real installer, with imports/git isolated."""
    from types import SimpleNamespace
    with tempfile.TemporaryDirectory() as tmp:
        root=Path(tmp)/'source';(root/'tools/observer_oracle').mkdir(parents=True)
        (root/'tools/observer_oracle/plants.py').write_text('# unchanged plants\n')
        (root/'Makefile').write_text('observer-anchor:\n\t@true\n')
        std=Path(tmp)/'std';(std/'tools/observer_oracle').mkdir(parents=True)
        (std/'tools/observer_oracle/score.py').write_text('# pinned scorer fixture\n')
        out=Path(tmp)/'run';out.mkdir();stage=out/'instrument'
        old=SimpleNamespace(F=SimpleNamespace(arm_root=lambda _:str(std),sha=lambda _: 'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'))
        new=SimpleNamespace(F=SimpleNamespace(sha=lambda _: 'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'),score=SimpleNamespace(__file__=str(stage/'tools/observer_oracle/score.py')))
        clone_calls=[]
        def clone(argv,**kwargs):
            clone_calls.append((argv,kwargs));(stage/'repository/.git').mkdir(parents=True)
        with patch.object(R,'ROOT',root),patch.object(R,'J',old),patch.object(R,'seal'),patch.object(R.sys,'path',list(R.sys.path)),patch.object(R.subprocess,'run',side_effect=clone),patch.object(R.importlib,'import_module',side_effect=[new,SimpleNamespace()]) as imported,patch.object(R,'resolve',return_value='registered-standard') as resolve:
            result=R.install_instrument({'binary':'std-binary'},out)
            return (result,(stage/'Makefile').read_bytes()==(root/'Makefile').read_bytes(),
                    (stage/'tools/observer_oracle/plants.py').read_text(),
                    (stage/'tools/observer_oracle/score.py').read_text(),
                    (stage/'.git').read_text()==('gitdir: '+str(stage/'repository/.git')+'\n'),
                    [c.args for c in imported.call_args_list],resolve.call_args.args,
                    clone_calls==[(['git','clone','--shared','--no-checkout',str(root),str(stage/'repository')],{'check':True,'stdout':R.subprocess.DEVNULL,'stderr':R.subprocess.PIPE})])


_install_cases=cases

def cases(R):
    yield from _install_cases(R)
    yield 'staged-instrument-build-context',lambda:installed_instrument_fixture(R),({'source_sha':'registered-standard','score_sha256':'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'},True,'# unchanged plants\n','# pinned scorer fixture\n',True,[('judge',),('seal',)],('3eed5caf',),True)


_uncached_run=run

def run(R, plant=None, quiet=False, prefer=()):
    """Share identical hermetic observations within this invocation only.

    Several independent named assertions inspect the same captured observation.
    Their inputs are identical; cache only these fixture helpers, discard before
    the next selftest/mutant, and continue evaluating every named assertion.
    Returned observations are read-only to the assertions.
    """
    from functools import lru_cache
    cached_population=lru_cache(maxsize=None)(observed_population)
    cached_main=lru_cache(maxsize=None)(main_case)
    with patch(__name__+'.observed_population',cached_population),patch(__name__+'.main_case',cached_main):
        return _uncached_run(R,plant=plant,quiet=quiet,prefer=prefer)


_retry_default_cases=cases

def cases(R):
    yield from _retry_default_cases(R)
    def retry_defaults(failures):
        good={'round':1,'randomness':'ab'*32,'signature':'fixture'}
        errors=[urllib.error.HTTPError('https://api.drand.sh',425,'not yet',None,None)]*failures
        with patch.object(R.seal,'fetch',side_effect=errors+[good]) as fetch,patch.object(R.seal,'checked',return_value=(1,'ab'*32)),patch.object(R.J.F,'build',return_value={}),patch.object(R.J.F,'write'),patch.object(R.J.F,'write_manifest'),patch.object(R.time,'sleep') as sleep:
            try:R.sealed_set(1,Path('unused'));result='ok'
            except R.Refusal:result='REFUSED'
            return result,fetch.call_count,[c.args for c in sleep.call_args_list]
    yield '425-default-last-retry-success',lambda:retry_defaults(5),('ok',6,[(30,)]*5)
    yield '425-default-budget-exhausted',lambda:retry_defaults(6),('REFUSED',6,[(30,)]*5)


_location_cases=cases

def cases(R):
    yield from _location_cases(R)
    yield 'driver-own-tool-directory',lambda:R.HERE,Path(__file__).resolve().parent
    yield 'driver-own-repository-root',lambda:R.ROOT,Path(__file__).resolve().parents[2]


_unicode_cases=cases

def cases(R):
    yield from _unicode_cases(R)
    def unicode_json():
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'unicode.json';R.dump(path,{'glyph':'μ'});return path.read_bytes()
    yield 'canonical-JSON-UTF8-unescaped',unicode_json,'{\n "glyph": "μ"\n}\n'.encode('utf-8')


# Append-only closure cases; the preceding fixture source is preserved.
_round4_root_prior_cases = cases


def cases(R):
    yield from _round4_root_prior_cases(R)

    def d14_failure(phi, burn):
        row = {'id': 'D14-owned-row', 'gen': {'kind': 'ar1', 'phi': phi, 'burn': burn}}
        try:
            R.check_d14({'rows': [row]})
        except R.Refusal as error:
            return str(error)
        return 'ACCEPTED'

    d14_message = 'INCOMPLETE: D14-owned-row: D14 |phi|^(2*burn) must be < 2^-53'
    yield 'D14-exact-owned-row-reason', lambda: d14_failure(0.92, 200), d14_message
    yield 'D14-negative-one-burn-huge-phi', lambda: d14_failure(10000000000.0, -1), d14_message

    def dry_reason():
        try:
            R.dry_guard(True, False, ['phase2', 'inc'], ['inc', 'anc'])
        except R.Refusal as error:
            return str(error)
        return 'ACCEPTED'

    yield 'dry-H1-refusal-exact-reason', dry_reason, 'DRY: Phase 2 subjects cannot read H1 families before the reveal; use INC/ANCHOR stand-ins or calibration/H-cal'

    runtime = ('R3', 'R3-STD', 'INC', 'ANCHOR', 'CF', 'W4')
    domains = {a: tuple(R.J.PREDS) for a in ['R3', 'R3-STD', 'INC', 'ANCHOR', 'CF', 'W4', 'STD', "STD'", 'REF', 'C0', 'C1']}
    domains.update({"STD''": ('equilibrium',), 'D2': ('improving',), 'PERSIST': ('converged', 'stable', 'equilibrium'), 'T001': ('converged',)})

    def roster_reason(records, scored):
        try:
            R.check_roster(records, scored, runtime)
        except R.Refusal as error:
            return str(error)
        return 'ACCEPTED'

    yield 'roster-runtime-exact-INCOMPLETE-reason', lambda: roster_reason((), domains), 'INCOMPLETE: runtime roster missing or unsealed'
    yield 'roster-comparator-exact-INCOMPLETE-reason', lambda: roster_reason(runtime, {}), 'INCOMPLETE: scored comparator roster or predicate domain missing'

    def prepare_unreviewed():
        row = R.J.F.f8(0, 0, R.J.F.rng(1, 8, 0), 1)
        record = json.loads(R.manual_review.DEFAULT.read_text())
        for entry in record['templates']:
            entry['verdict'] = ''
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'corpus.json').write_text(json.dumps({'rows': [row]}))
            pending = root / 'pending.json'
            pending.write_text(json.dumps(record))
            with patch.object(R.manual_review, 'DEFAULT', pending), patch.object(R, 'command') as command:
                try:
                    R.prepare_set(root, {'INC': 'fixture-binary'}, root)
                except ValueError as error:
                    return row['id'] in str(error), 'APPROVED verdict' in str(error), command.call_count
        return False, False, -1

    yield 'prepare-unreviewed-before-certify', prepare_unreviewed, (True, True, 0)


_round4_diagnostic_prior_cases = cases


def cases(R):
    yield from _round4_diagnostic_prior_cases(R)

    def unavailable(points, missing, failed=(), with15=True):
        names = ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')
        decisions = {a: {p: verdict() for p in names} for a in ('R3', 'R3-STD')}
        for arm, pred, rule in missing:
            next(row for row in decisions[arm][pred]['rules'] if row[0] == rule)[1] = 'NOT EVALUATED'
        pop = {'rows': {'owned': {'family': 'F15 unit-scaled copies' if with15 else 'F6 sinusoid'}},
               'points': points, 'decisions': decisions}
        raw = {'primary': 'hcal', 'populations': {'hcal': pop},
               'controls': {control: control not in failed for control in ('a', 'b', 'c1', 'c2')}}
        return R.incomplete_reasons(raw)

    yield 'reasons-nonCF-null-is-not-undefined', lambda: unavailable(
        [('R3', 'converged', None)], [('R3', 'converged', '2 vs INC')]), ['unevaluated:R3:converged:2 vs INC']
    yield 'reasons-defined-CF-is-not-undefined', lambda: unavailable(
        [('CF', 'converged', '1/2')], [('R3', 'converged', '2 vs INC')]), ['unevaluated:R3:converged:2 vs INC']
    yield 'reasons-R3STD-only-missing-rule', lambda: unavailable(
        [], [('R3-STD', 'stable', '3 safety')]), ['unevaluated:R3-STD:stable:3 safety']
    for rule in ('3 safety', '5 unit invariance', '6 existing gates'):
        yield 'reasons-undefined-keeps-rule-' + rule[0], lambda rule=rule: unavailable(
            [('CF', 'converged', None)], [('R3', 'converged', rule)]), ['unevaluated:R3:converged:' + rule]
    yield 'reasons-defined-failed-control-b', lambda: unavailable([], [], ('b',)), ['control:b']
    yield 'reasons-defined-failed-b-with-other-gap', lambda: unavailable(
        [], [('R3', 'converged', '5 unit invariance')], ('b',), False), ['control:b', 'no-family-15']

    def actual_refusal_classification(kind):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / 'result'
            def operation(args, raw):
                if kind == 'build-failure':
                    with patch.object(R, 'command', return_value=SimpleNamespace(returncode=7)):
                        return R.build('R3', 'commit', root)
                if kind == 'build-stamp':
                    stamp = {'binary': 'fixture', 'binary_sha256': 'bytes'}
                    record = {'source_sha': 'wrong', 'recipe_id': 'pin', 'binary_sha256': 'bytes'}
                    with patch.object(R, 'command', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(stamp))), patch.object(R.J.F, 'arm_record', return_value=record), patch.object(R.J.F, 'sha', return_value='pin'):
                        return R.build('R3', 'commit', root)
                if kind.startswith('prepare-'):
                    index = int(kind[-1])
                    (root / 'corpus.json').write_text('{"rows":[]}')
                    replies = [SimpleNamespace(returncode=0)] * index + [SimpleNamespace(returncode=7)]
                    with patch.object(R.manual_review, 'check_manual_reviews'), patch.object(R, 'command', side_effect=replies):
                        return R.prepare_set(root, {'INC': 'fixture'}, root)
                assert kind == 'measurement-order'
                def run_arms(bs, rows, seed):
                    return {}, [], set(), [('CF', 'owned')], {}
                def judge_main(argv):
                    R.J.run_arms({'CF': 'fixture'}, {}, 1758)
                    return 0
                with patch.object(R.J, 'load', return_value=({'rows': []}, {})), patch.object(R.J, 'run_arms', side_effect=run_arms), patch.object(R.J, 'main', side_effect=judge_main):
                    return R.judge_population([root], {'CF': 'fixture'}, {}, 1758, 1000, root, 'owned')
            with patch.object(R, 'execute', side_effect=operation), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                rc = R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--out', str(out)])
            raw = json.loads((out / 'raw.json').read_text())
            return rc, raw['status'], raw['error'], (out / 'decision.json').exists()

    for kind, reason in (
        ('build-failure', 'INCOMPLETE: R3 recipe failed; see build-R3.log'),
        ('build-stamp', 'INCOMPLETE: R3 recipe stamp mismatch'),
        ('prepare-0', 'INCOMPLETE: certify.py exit 7'),
        ('prepare-1', 'INCOMPLETE: derive.py exit 7'),
        ('prepare-2', 'INCOMPLETE: manifest writer failed'),
        ('measurement-order', 'INCOMPLETE: measurement/order accounting differs'),
    ):
        yield 'actual-refusal-classification-' + kind, lambda kind=kind: actual_refusal_classification(kind), (2, 'INCOMPLETE', reason, False)


_round4_float_prior_cases = cases


def cases(R):
    yield from _round4_float_prior_cases(R)

    def decimal_phi(phi, burn):
        row = {'id': 'decimal-phi', 'gen': {'kind': 'ar1', 'phi': phi, 'burn': burn}}
        try:
            return R.check_d14({'rows': [row]})
        except R.Refusal:
            return 'REFUSED'

    # Exact rational arithmetic on str(phi), independently of binary-float
    # conversion, places these two floats on opposite sides of their boundary.
    yield 'D14-decimal-float-inside', lambda: decimal_phi(0.3803140539874118, 19), ['decimal-phi']
    yield 'D14-decimal-float-outside', lambda: decimal_phi(0.5731440541563866, 33), 'REFUSED'

    def malformed_phi():
        row = {'id': 'malformed-phi', 'gen': {'kind': 'ar1', 'phi': None, 'burn': 1}}
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'result'
            def execute(args, raw):
                return R.check_d14({'rows': [row]})
            with patch.object(R, 'execute', side_effect=execute), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                rc = R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--out', str(out)])
            raw = json.loads((out / 'raw.json').read_text())
            return rc, raw['status'], (out / 'decision.json').exists()

    yield 'D14-malformed-phi-refused-by-main', malformed_phi, (2, 'REFUSED', False)


_round4_protocol_type_prior_cases = cases


def cases(R):
    yield from _round4_protocol_type_prior_cases(R)

    def outcome_boolean_types():
        answers = []
        for subject in (verdict(), verdict('FAIL', ('4 trivial floor',)), verdict('FAIL', ('1 standard parity',))):
            got = R.outcome(subject, verdict('FAIL', ('2 vs INC',)))
            answers.append((type(got['silent_wrong']) is bool, type(got['STD_p_on_H2']) is bool))
        return answers

    yield 'outcome-duty-protocol-boolean-types', outcome_boolean_types, [(True, True)] * 3

    def control_boolean_types():
        points = {p: Q(1, 2) for p in ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')}
        decisions = {arm: {p: verdict('FAIL', ('2 vs INC',)) for p in points} for arm in ('CF', 'W4')}
        got = R.controls_ok(True, points, decisions, (Q(1, 20), 0.01))
        return [type(got[key]) is bool for key in ('a', 'b', 'c1', 'c2')]

    yield 'control-protocol-boolean-types', control_boolean_types, [True] * 4

# Historical round4 appended fixture group, retained with named R30R-5 adaptations.
# Expected values are registration/frozen-CELL literals, not calls to R.
_round4_prefix66251_prior_cases = cases


def cases(R):
    yield from _round4_prefix66251_prior_cases(R)

    yield 'control-diff-null-point-defined-CI', lambda: R.control_diff(
        ['STD', 'T001', 'converged', None, '0.007', '2', '0']), (None, 0.007)
    yield 'control-diff-defined-point-null-CI', lambda: R.control_diff(
        ['STD', 'T001', 'converged', '3/7', None, '2', '0']), (Q(3, 7), None)

    predicates = ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')

    def malformed_decision(kind):
        decisions = {arm: {pred: verdict() for pred in predicates} for arm in ('R3', 'R3-STD', 'CF', 'W4')}
        target = decisions['R3-STD']['stable']
        if kind == 'verdict':
            target['verdict'] = 'INCOMPLETE'
        elif kind == 'empty-rules':
            target['rules'] = []
        else:
            assert kind == 'missing-rules'
            del target['rules']
        return R.status_for(0, decisions, {'a': True, 'b': True, 'c1': True, 'c2': True})

    yield 'status-invalid-verdict-complete-roster', lambda: malformed_decision('verdict'), 'INCOMPLETE'
    yield 'status-empty-rules-complete-roster', lambda: malformed_decision('empty-rules'), 'INCOMPLETE'
    yield 'status-missing-rules-complete-roster', lambda: malformed_decision('missing-rules'), 'INCOMPLETE'

    def dry_gap(kind):
        raw = diagnostic_fixture()
        if kind == 'R3-floor':
            raw['preflight']['R3']['floor_exit'] = 1
        elif kind == 'equilibrium-positive':
            raw['populations']['hcal']['labels']['r@1']['equilibrium'][1] = True
        else:
            assert kind == 'mixed-diverging-labels'
            raw['populations']['hcal']['labels']['r@1']['diverging'][1] = True
            raw['populations']['hcal']['labels']['s@1'] = {
                'diverging': ['MATH', False], 'equilibrium': ['MATH', False]}
        return R.dry_a_ok(raw)

    yield 'Dry-A-reject-R3-only-floor', lambda: dry_gap('R3-floor'), False
    yield 'Dry-A-reject-equilibrium-positive', lambda: dry_gap('equilibrium-positive'), False
    yield 'Dry-A-reject-mixed-diverging-labels', lambda: dry_gap('mixed-diverging-labels'), False

    def small_population():
        return {'rows': {'owned': {'family': 'fixture', 'checkpoints': [1]}},
                'labels': {'owned@1': {'converged': ['MATH', True]}},
                'readings': [['A', 'owned', 1, 'converged', False]]}

    small_expected = {'confusion': {'["A", "converged", "fixture"]': [0, 0, 1, 0]},
                      'disagreements': [['A', 'owned', 1, 'converged', True, False]], 'absent': []}

    def extracted_population():
        raw = complete_raw('INCOMPLETE')
        raw['populations']['H1']['labels']['fixture@1']['converged'][0]='REPORTED'
        raw['populations']['owned-population']=copy.deepcopy(raw['populations']['H1'])
        raw['populations']['owned-population'].update(small_population())
        with patch.object(R, 'ROSTER', {'A': ('converged',)}):
            return R.extract(raw)

    yield 'extract-exact-nonempty-population-tables', extracted_population, {
        'status': 'INCOMPLETE', 'dry': True, 'seed': 1758, 'resamples': 1000,
        'population_tables': {'H1': {'confusion':{},'disagreements':[],'absent':[]}, 'owned-population': small_expected}}

    def asymmetric_raw():
        raw=complete_raw()
        decisions=raw['populations']['H1']['decisions']
        for pred in predicates:
            decisions['R3-STD'][pred]=registered_verdict(pred,'R3-STD',('2 vs INC',))
        decisions['R3']['converged']=registered_verdict('converged','R3',('4 trivial floor',))
        decisions['R3-STD']['converged']=registered_verdict('converged','R3-STD')
        decisions['R3']['stable']=registered_verdict('stable','R3',('1 standard parity',))
        raw['reasons']=[]
        return raw

    def asymmetric_extraction():
        result = R.extract(asymmetric_raw())['predicates']
        return [(pred, result[pred]['ship'], result[pred]['silent_wrong'], result[pred]['STD_p_on_H2'],
                 result[pred]['subjects']['R3']['verdict'], result[pred]['subjects']['R3-STD']['verdict'])
                for pred in predicates]

    yield 'extract-asymmetric-subject-outcomes', asymmetric_extraction, [
        ('converged', 'R3-STD', True, False, 'FAIL', 'PASS'),
        ('stable', 'INC', False, True, 'FAIL', 'FAIL'),
        ('improving', 'R3', False, False, 'PASS', 'FAIL'),
        ('oscillating', 'R3', False, False, 'PASS', 'FAIL'),
        ('diverging', 'R3', False, False, 'PASS', 'FAIL'),
        ('equilibrium', 'R3', False, False, 'PASS', 'FAIL')]

    def reported_population():
        pop = small_population()
        pop['labels']['owned@1']['converged'][0] = 'REPORTED'
        with patch.object(R, 'ROSTER', {'A': ('converged',)}):
            return R.whole_population(pop)

    yield 'whole-population-REPORTED-excluded', reported_population, {
        'confusion': {}, 'disagreements': [], 'absent': []}

    def ordered_unicode_population():
        pop = {'rows': {rid: {'family': 'fixture-μ', 'checkpoints': [1]} for rid in ('b', 'a')},
               'labels': {rid + '@1': {'converged': ['MATH', False]} for rid in ('b', 'a')},
               'readings': [['A', rid, 1, 'converged', False] for rid in ('b', 'a')]}
        with patch.object(R, 'ROSTER', {'A': ('converged',), 'B': ('converged',)}):
            return R.whole_population(pop)

    yield 'whole-population-order-Unicode-false-label', ordered_unicode_population, {
        'confusion': {'["A", "converged", "fixture-μ"]': [0, 0, 0, 2],
                      '["B", "converged", "fixture-μ"]': [0, 0, 0, 0]},
        'disagreements': [], 'absent': [['B', 'a', 1, 'converged'], ['B', 'b', 1, 'converged']]}

    def written_population():
        raw = complete_raw('INCOMPLETE')
        raw['populations']['H1']['labels']['fixture@1']['converged'][0]='REPORTED'
        raw['populations']['owned-population']=copy.deepcopy(raw['populations']['H1'])
        raw['populations']['owned-population'].update(small_population())
        raw['reasons']=[]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            with patch.object(R, 'ROSTER', {'A': ('converged',)}), contextlib.redirect_stdout(io.StringIO()):
                R.write_outputs(raw, out)
            return (sorted(path.name for path in out.iterdir()),
                    json.loads((out / 'owned-population-population.json').read_text()),
                    json.loads((out / 'decision.json').read_text())['population_tables'])

    yield 'write-population-name-and-content', written_population, (
        ['H1-population.json', 'decision.json', 'owned-population-population.json', 'raw.json'],
        small_expected, {'H1':{'confusion':{},'disagreements':[],'absent':[]}, 'owned-population': small_expected})

    def written_outcome():
        with tempfile.TemporaryDirectory() as tmp:
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                R.write_outputs(asymmetric_raw(), Path(tmp))
            return captured.getvalue().splitlines()

    yield 'write-asymmetric-outcome-duty-lines', written_outcome, [
        'DRY OUTCOME converged: R3-STD; silent-wrong=True; STD_p/H2=False',
        'DRY OUTCOME stable: INC; silent-wrong=False; STD_p/H2=True',
        'DRY OUTCOME improving: R3; silent-wrong=False; STD_p/H2=False',
        'DRY OUTCOME oscillating: R3; silent-wrong=False; STD_p/H2=False',
        'DRY OUTCOME diverging: R3; silent-wrong=False; STD_p/H2=False',
        'DRY OUTCOME equilibrium: R3; silent-wrong=False; STD_p/H2=False', 'COMPLETE']

# Historical round4 appended fixture group, retained with named R30R-5 adaptations.
# Append after the separately pinned prefix66251 fourteen-case fragment.
_round4_prefix73251_prior_cases = cases


def cases(R):
    yield from _round4_prefix73251_prior_cases(R)

    def written_reasons_and_controls():
        raw=complete_raw('VOID',False)
        raw['reasons']=['first missing','second gap']
        raw['controls']['c1']=False
        with tempfile.TemporaryDirectory() as tmp:
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                R.write_outputs(raw, Path(tmp))
            return captured.getvalue().splitlines()

    yield 'write-reasons-and-multiple-failed-controls', written_reasons_and_controls, [
        'VOID', 'reason: first missing', 'reason: second gap',
        'failed controls: a, c1; step 1 is repeated']

    def command_none_argument():
        from types import SimpleNamespace
        reply = SimpleNamespace(returncode=0, stdout='controlled output\n')
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'command.log'
            with patch.object(R.subprocess, 'run', return_value=reply) as command:
                result = R.command(['tool', None], log)
            return command.call_args.args, log.read_text(), result is reply

    yield 'command-stringifies-None-argument', command_none_argument, (
        (['tool', 'None'],), 'controlled output\n', True)


# Round4 aggregate28 restored for round5; R30R-5 adaptations are recorded externally.
_round4_prefix188501_prior_cases = cases


def cases(R):
    yield from _round4_prefix188501_prior_cases(R)

    def fetch_replaces_failed_stdout():
        from types import SimpleNamespace
        replies = [SimpleNamespace(returncode=1, stdout=''),
                   SimpleNamespace(returncode=0, stdout='fetch output\n'),
                   SimpleNamespace(returncode=0, stdout='0123456789abcdef0123456789abcdef01234567\n')]
        with patch.object(R.subprocess, 'run', side_effect=replies):
            return R.resolve('01234567')

    yield 'resolve-fetch-replaces-failed-stdout', fetch_replaces_failed_stdout, '0123456789abcdef0123456789abcdef01234567'

    def build_boundary_arguments():
        from types import SimpleNamespace
        stamp = {'binary': 'fixture-binary', 'binary_sha256': 'fixture-bytes'}
        record = {'source_sha': 'commit', 'recipe_id': 'fixture-recipe-pin', 'binary_sha256': 'fixture-bytes'}
        expected_recipe = Path(__file__).resolve().parent / 'build_arm.sh'
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            with patch.object(R, 'command', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(stamp))) as command, patch.object(R.J.F, 'arm_record', return_value=record) as arm_record, patch.object(R.J.F, 'sha', return_value='fixture-recipe-pin') as recipe_pin:
                result = R.build('R3', 'commit', out)
                return {'stamp': result,
                        'command_calls': command.call_count,
                        'argv_matches': command.call_args.args[0] == ['bash', expected_recipe, 'commit'],
                        'log_matches': command.call_args.args[1] == out / 'build-R3.log',
                        'record_args': arm_record.call_args.args,
                        'recipe_pin_path_matches': recipe_pin.call_args.args == (expected_recipe,)}

    yield 'build-command-log-stamp-arguments', build_boundary_arguments, {
        'stamp': {'binary': 'fixture-binary', 'binary_sha256': 'fixture-bytes'},
        'command_calls': 1, 'argv_matches': True, 'log_matches': True,
        'record_args': ('fixture-binary',), 'recipe_pin_path_matches': True}

    def scorer_refusal_reason():
        with patch.object(R.J.F, 'arm_root', return_value='/unused'), patch.object(R.J.F, 'sha', return_value='wrong'), patch.object(R.shutil, 'copytree') as copied:
            try:
                R.install_instrument({'binary': 'fixture'}, Path('/unused'))
            except R.Refusal as error:
                return str(error), copied.call_count
            return 'accepted', copied.call_count

    yield 'scorer-refusal-reason-exact', scorer_refusal_reason, ('pinned score.py sha256 mismatch (R30R-3)', 0)

    def instrument_source_and_cache_contract():
        from types import SimpleNamespace
        pin = 'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'source'
            (root / 'tools/observer_oracle').mkdir(parents=True)
            (root / 'tools/__pycache__').mkdir()
            (root / 'tools/__pycache__/ignored.pyc').write_bytes(b'ignored cache')
            (root / 'tools/observer_oracle/plants.py').write_text('# unchanged plants\n')
            (root / 'Makefile').write_text('observer-anchor:\n\t@true\n')
            std = Path(tmp) / 'std'
            std_score = std / 'tools/observer_oracle/score.py'
            std_score.parent.mkdir(parents=True)
            std_score.write_text('# pinned scorer fixture\n')
            out = Path(tmp) / 'run'
            out.mkdir()
            stage = out / 'instrument'
            staged_score = stage / 'tools/observer_oracle/score.py'
            arm_inputs, old_hash_inputs, new_hash_inputs, clone_calls = [], [], [], []

            def arm_root(binary):
                arm_inputs.append((type(binary) is str, binary == 'std-binary'))
                return str(std)

            def old_sha(path):
                old_hash_inputs.append(path == std_score)
                return pin

            def new_sha(path):
                new_hash_inputs.append(path == str(staged_score))
                return pin

            old_judge = SimpleNamespace(F=SimpleNamespace(arm_root=arm_root, sha=old_sha))
            new_judge = SimpleNamespace(F=SimpleNamespace(sha=new_sha), score=SimpleNamespace(__file__=str(staged_score)))
            modules = {'fixture_inside_tools': SimpleNamespace(__file__=str(root / 'tools/pkg/inside.py')),
                       'fixture_outside_tools': SimpleNamespace(__file__=str(root / 'outside.py')),
                       'fixture_without_file': SimpleNamespace(),
                       'reveal': SimpleNamespace(__file__=str(root / 'tools/reveal.py')),
                       'reveal_selftest': SimpleNamespace(__file__=str(root / 'tools/reveal_selftest.py')),
                       'manual_review': SimpleNamespace(__file__=str(root / 'tools/manual_review.py'))}
            modules[R.__name__] = SimpleNamespace(__file__=str(root / 'tools/current-driver.py'))
            virtual_sys = SimpleNamespace(modules=modules, path=['first-entry', 'second-entry'])
            new_seal = SimpleNamespace(role='staged-seal')

            def clone(argv, **kwargs):
                clone_calls.append((argv, kwargs))
                (stage / 'repository/.git').mkdir(parents=True)

            with patch.object(R, 'ROOT', root), patch.object(R, 'J', old_judge), patch.object(R, 'seal', SimpleNamespace()), patch.object(R, 'sys', virtual_sys), patch.object(R.subprocess, 'run', side_effect=clone), patch.object(R.importlib, 'import_module', side_effect=[new_judge, new_seal]) as imported, patch.object(R, 'resolve', return_value='registered-standard') as resolve:
                result = R.install_instrument({'binary': 'std-binary'}, out)
                return {'result': result, 'judge_rebound': R.J is new_judge, 'seal_rebound': R.seal is new_seal, 'arm_inputs': arm_inputs,
                        'scorer_hash_inputs': old_hash_inputs, 'installed_hash_inputs': new_hash_inputs,
                        'plants': (stage / 'tools/observer_oracle/plants.py').read_text(),
                        'score': staged_score.read_text(), 'makefile': (stage / 'Makefile').read_text(),
                        'ignored_cache_absent': not (stage / 'tools/__pycache__').exists(),
                        'gitdir_matches': (stage / '.git').read_text() == 'gitdir: ' + str(stage / 'repository/.git') + '\n',
                        'clone_calls_match': clone_calls == [(['git', 'clone', '--shared', '--no-checkout', str(root), str(stage / 'repository')], {'check': True, 'stdout': R.subprocess.DEVNULL, 'stderr': R.subprocess.PIPE})],
                        'imports': [call.args for call in imported.call_args_list],
                        'resolve_args': resolve.call_args.args,
                        'cache_membership': {name: name in modules for name in ('fixture_inside_tools', 'fixture_outside_tools', 'fixture_without_file', 'reveal', 'reveal_selftest', 'manual_review')},
                        'driver_cache_retained': R.__name__ in modules,
                        'path_matches': virtual_sys.path == [str(stage / 'tools/observer_oracle'), 'first-entry', 'second-entry']}

    yield 'instrument-stage-source-and-cache-contract', instrument_source_and_cache_contract, {
        'result': {'source_sha': 'registered-standard', 'score_sha256': 'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'},
        'judge_rebound': True, 'seal_rebound': True, 'arm_inputs': [(True, True)], 'scorer_hash_inputs': [True], 'installed_hash_inputs': [True],
        'plants': '# unchanged plants\n', 'score': '# pinned scorer fixture\n',
        'makefile': 'observer-anchor:\n\t@true\n', 'ignored_cache_absent': True,
        'gitdir_matches': True, 'clone_calls_match': True, 'imports': [('judge',), ('seal',)],
        'resolve_args': ('3eed5caf',),
        'cache_membership': {'fixture_inside_tools': False, 'fixture_outside_tools': True,
                             'fixture_without_file': True, 'reveal': True,
                             'reveal_selftest': True, 'manual_review': True},
        'driver_cache_retained': True, 'path_matches': True}

    def floor_boundary_arguments():
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            arm = Path(tmp) / 'arm'
            decl = arm / 'tests/phase2/oracle_expect.txt'
            decl.parent.mkdir(parents=True)
            decl.write_text('\n \t\n# comment\n \t# indented comment\ndata #1830\n  preserved row  \n')
            out = Path(tmp) / 'output'
            out.mkdir()
            with patch.object(R, 'sys', SimpleNamespace(executable='fixture-python')), patch.object(R.J.score, '__file__', 'registered-score.py'), patch.object(R.J.F, 'arm_root', return_value=str(arm)) as arm_root, patch.object(R.J.F, 'sha', return_value='declaration-pin') as declaration_pin, patch.object(R.J.score, 'capabilities', return_value=(None, {'int64': True, 'ieee': False})) as capabilities, patch.object(R, 'command', return_value=SimpleNamespace(returncode=17)) as command:
                result = R.floor('floor-binary', out, 'R3')
                return {'result': result, 'arm_root_args': arm_root.call_args.args,
                        'capability_args': capabilities.call_args.args,
                        'argv_matches': command.call_args.args[0] == ['fixture-python', 'registered-score.py', 'floor-binary', '--floor', arm / 'tools/observer_oracle/floor.json', '--declared', decl],
                        'log_matches': command.call_args.args[1] == out / 'floor-R3.log',
                        'declaration_pin_matches': declaration_pin.call_args.args == (decl,)}

    yield 'floor-distinct-root-output-and-all-arguments', floor_boundary_arguments, {
        'result': {'floor_exit': 17, 'declarations': ['data #1830', '  preserved row  '],
                   'capabilities': {'int64': True, 'ieee': False}, 'declaration_sha256': 'declaration-pin'},
        'arm_root_args': ('floor-binary',), 'capability_args': ('floor-binary',),
        'argv_matches': True, 'log_matches': True, 'declaration_pin_matches': True}

    def beacon_boundary_arguments():
        beacon = {'round': 42, 'randomness': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'signature': ''}
        drawn = {'rows': ['fixture']}
        checked = R.seal.checked
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'H1'
            with patch.object(R.seal, 'fetch', return_value=beacon) as fetch, patch.object(R.seal, 'checked', wraps=checked) as check, patch.object(R.J.F, 'build', return_value=drawn) as build, patch.object(R.J.F, 'write') as write, patch.object(R.J.F, 'write_manifest') as manifest:
                result = R.sealed_set(42, out)
                return {'result': result, 'fetch_args': fetch.call_args.args,
                        'checked_beacon_identity': check.call_args.args[0] is beacon,
                        'checked_round': check.call_args.args[1],
                        'build_args': build.call_args.args,
                        'write_matches': write.call_args.args == (drawn, str(out)),
                        'manifest_matches': manifest.call_args.args == (str(out), {})}

    yield 'beacon-round-seed-and-write-arguments', beacon_boundary_arguments, {
        'result': {'round': 42, 'randomness': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                   'beacon': {'round': 42, 'randomness': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'signature': ''}},
        'fetch_args': ('42',), 'checked_beacon_identity': True, 'checked_round': 42,
        'build_args': ([2, 3, 4, 7, 8, 9, 10, 12, 13, 16, 14, 15], 0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855),
        'write_matches': True, 'manifest_matches': True}

    def beacon_refusal_reason():
        beacon = {'round': 43, 'randomness': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'signature': ''}
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'H1'
            with patch.object(R.seal, 'fetch', return_value=beacon), patch.object(R.J.F, 'build') as draw:
                try:
                    R.sealed_set(42, out)
                except R.Refusal as error:
                    return str(error), draw.call_count, (out / 'corpus.json').exists()
                return 'accepted', draw.call_count, (out / 'corpus.json').exists()

    yield 'beacon-invalid-round-exact-refusal', beacon_refusal_reason, ('seal: the response names round 43, not 42', 0, False)

    def beacon_retry_diagnostic():
        good = {'round': 42, 'randomness': 'ab' * 32, 'signature': 'fixture'}
        error = urllib.error.HTTPError('https://fixture.invalid', 425, 'fixture', None, None)
        stdout = io.StringIO()
        with patch.object(R.seal, 'fetch', side_effect=[error, good]), patch.object(R.seal, 'checked', return_value=(42, 'ab' * 32)), patch.object(R.J.F, 'build', return_value={}), patch.object(R.J.F, 'write'), patch.object(R.J.F, 'write_manifest'), patch.object(R.time, 'sleep') as sleep, patch.object(R, 'print', wraps=print, create=True) as printed, contextlib.redirect_stdout(stdout):
            result = R.sealed_set(42, Path('retry-output'), retries=3, delay=7)
            return {'result': result, 'stdout': stdout.getvalue(),
                    'print_args': [call.args for call in printed.call_args_list],
                    'print_kwargs': [call.kwargs for call in printed.call_args_list],
                    'sleep_args': [call.args for call in sleep.call_args_list]}

    yield 'beacon-retry-full-diagnostic-and-flush', beacon_retry_diagnostic, {
        'result': {'round': 42, 'randomness': 'ab' * 32, 'beacon': {'round': 42, 'randomness': 'ab' * 32, 'signature': 'fixture'}},
        'stdout': 'beacon HTTP 425; retry 1/3\n', 'print_args': [('beacon HTTP 425; retry 1/3',)],
        'print_kwargs': [{'flush': True}], 'sleep_args': [(7,)]}

    def beacon_http_refusal_diagnostic():
        error = urllib.error.HTTPError('https://fixture.invalid', 404, 'fixture', None, None)
        with patch.object(R.seal, 'fetch', side_effect=error), patch.object(R.time, 'sleep') as sleep:
            try:
                R.sealed_set(42, Path('retry-output'), retries=3, delay=7)
            except R.Refusal as refused:
                return str(refused), sleep.call_count
            return 'accepted', sleep.call_count

    yield 'beacon-http-refusal-full-diagnostic', beacon_http_refusal_diagnostic, ('beacon unavailable: HTTP 404; retry bound 3', 0)

    def beacon_zero_budget_refusal():
        with patch.object(R.seal, 'fetch') as fetch:
            try:
                R.sealed_set(42, Path('retry-output'), retries=0)
            except R.Refusal as error:
                return str(error), fetch.call_count
            return 'accepted', fetch.call_count

    yield 'beacon-zero-budget-exact-refusal', beacon_zero_budget_refusal, ('beacon retry bound exhausted', 0)

    def preparation_all_arguments_and_output():
        from types import SimpleNamespace
        corpus = {'rows': []}
        manifest = {'code': {'judge': 'j-pin', 'derive': 'd-pin', 'score': 's-pin'}, 'arms': {'INC': 'inc-bin', 'R3': 'r3-bin'}}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'H1'
            root.mkdir()
            (root / 'corpus.json').write_text(json.dumps(corpus))
            (root / 'manifest.json').write_text(json.dumps(manifest))
            out = Path(tmp) / 'separate-logs'
            out.mkdir()
            commands, hash_inputs = [], []

            def command(argv, log):
                commands.append((argv, log))
                return SimpleNamespace(returncode=0)

            def digest(path):
                hash_inputs.append(path == root / 'manifest.json')
                return 'manifest-pin'

            stdout = io.StringIO()
            with patch.object(R, 'sys', SimpleNamespace(executable='fixture-python')), patch.object(R.J, 'HERE', 'fixture-instrument'), patch.object(R, 'check_d14') as d14, patch.object(R.manual_review, 'check_manual_reviews') as manual, patch.object(R, 'command', new=command), patch.object(R.J.F, 'sha', new=digest), contextlib.redirect_stdout(stdout):
                result = R.prepare_set(root, {'INC': 'inc-bin', 'R3': 'r3-bin'}, out)
                return {'result': result, 'stdout': stdout.getvalue(),
                        'commands_match': commands == [
                            (['fixture-python', Path('fixture-instrument/certify.py'), '--corpus', root / 'corpus.json'], out / 'H1-certify.py.log'),
                            (['fixture-python', Path('fixture-instrument/derive.py'), '--corpus', root / 'corpus.json', '--write'], out / 'H1-derive.py.log'),
                            (['fixture-python', '-I', Path('fixture-instrument/judge.py'), '--write-manifest', root, '--arm', 'INC=inc-bin', '--arm', 'R3=r3-bin'], out / 'H1-seal.log')],
                        'd14_args': [call.args for call in d14.call_args_list],
                        'manual_args': [call.args for call in manual.call_args_list],
                        'hash_inputs': hash_inputs}

    yield 'prepare-all-command-path-log-and-output-contract', preparation_all_arguments_and_output, {
        'result': {'sha256': 'manifest-pin', 'manifest': {'code': {'judge': 'j-pin', 'derive': 'd-pin', 'score': 's-pin'}, 'arms': {'INC': 'inc-bin', 'R3': 'r3-bin'}}},
        'stdout': 'manifest H1: sha256 manifest-pin; derived files 3\n', 'commands_match': True,
        'd14_args': [({'rows': []},)], 'manual_args': [({'rows': []},)], 'hash_inputs': [True, True]}

    def population_forwarding_and_skips():
        first = {'id': 'r1', 'family': 'family-A', 'capability': 'ieee', 'gen': {'kind': 'cycle', 'values': [1]}, 'n': 3, 'checkpoints': [1]}
        second = {'id': 'r2', 'family': 'family-B', 'capability': 'int64', 'gen': {'kind': 'cycle', 'values': [2]}, 'n': 4, 'checkpoints': [2]}
        labels1, labels2 = {'r1@1': {'converged': ['MATH', True]}}, {'r2@2': {'stable': ['MATH', False]}}
        binaries = {'R3': 'r3-binary', 'CF': 'cf-original'}
        runtime_binaries = {'R3': 'r3-binary', 'CF': 'cf-transformed'}
        runtime_rows = {'r1': first, 'r2': second}
        caps = {'R3': {'ieee': True, 'int64': False}, 'CF': {'ieee': False, 'int64': True}}
        measurements = [
            {'read': {('jit', 'straight', 'r1', 1, 'converged'): True, ('interp', 'loop', 'r1', 1, 'stable'): False}},
            {'read': {('interp', 'straight', 'r2', 2, 'stable'): False}}]
        order = [('R3', 'r1'), ('CF', 'r1'), ('R3', 'r2'), ('CF', 'r2')]
        skipped = {('CF', 'r1', 'ieee'), ('R3', 'r2', 'int64')}
        original_result = ({'R3': {'r1': {(1, 'converged'): True}}, 'CF': {'r2': {(2, 'stable'): False}}}, [], skipped, order, caps)
        load_inputs, measure_inputs, run_inputs, forwarding, main_inputs, generate_inputs, tolerance_inputs, tol_calls = [], [], [], [], [], [], [], []

        def load(path):
            load_inputs.append(Path(path).name)
            return ({'rows': [first]}, labels1) if Path(path).name == 'first' else ({'rows': [second]}, labels2)

        def measure(binary, corpus, capability):
            measure_inputs.append((binary, corpus, capability))
            return measurements[len(measure_inputs) - 1]

        def run_arms(bs, rows, seed):
            run_inputs.append((bs is runtime_binaries, rows is runtime_rows, seed))
            for i, (arm, rid) in enumerate([('R3', 'r1'), ('CF', 'r2')]):
                returned = R.J.score.measure(bs[arm], {'rows': [rows[rid]]}, caps[arm])
                forwarding.append(returned is measurements[i])
            return original_result

        def generate(gen, n):
            generate_inputs.append((gen, n))
            return [1, 1, 1] if n == 3 else [2, 2, 2, 2]

        def tolerance(k):
            tolerance_inputs.append(k)
            def predicate(xs, checkpoint):
                tol_calls.append((xs, checkpoint))
                return checkpoint == 1
            return predicate

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            paths = [root / 'first', root / 'second']

            def judge_main(argv):
                main_inputs.append(argv == ['judge.py', '--corpus', str(paths[0]), '--corpus', str(paths[1]), '--arm', 'R3=r3-binary', '--const-false', 'CF=cf-original', '--tol-converged', 'T001=0.01', '--subject', 'R3', '--subject', 'R3-STD', '--subject', 'CF', '--subject', 'W4', '--resamples', '17', '--seed', '13'])
                returned = R.J.run_arms(runtime_binaries, runtime_rows, 13)
                forwarding.extend([returned is original_result, R.J.score.measure is measure])
                print('fixture judge text')
                return 2

            with patch.object(R.J, 'load', new=load), patch.object(R.J.score, 'measure', new=measure), patch.object(R.J, 'run_arms', new=run_arms), patch.object(R.J, 'main', new=judge_main), patch.object(R.J, 'generate', new=generate), patch.object(R.J.S, 'ARMS', {}), patch.object(R.J.S, 'tol_converged', new=tolerance):
                original_decide = R.J.decide
                pop = R.judge_population(paths, binaries, {}, 13, 17, root, 'population')
                restored = (R.J.run_arms is run_arms, R.J.score.measure is measure, R.J.decide is original_decide)
                return {'pop': pop, 'loads': load_inputs, 'run_inputs': run_inputs,
                        'measure_inputs': measure_inputs, 'forwarding': forwarding,
                        'main_inputs': main_inputs, 'generate_inputs': generate_inputs,
                        'tolerance_inputs': tolerance_inputs, 'tol_calls': tol_calls,
                        'restored': restored, 'log': (root / 'population-judge.log').read_text()}

    yield 'population-measurement-arguments-skips-and-restoration', population_forwarding_and_skips, {
        'pop': {
            'rows': {
                'r1': {'id': 'r1', 'family': 'family-A', 'capability': 'ieee', 'gen': {'kind': 'cycle', 'values': [1]}, 'n': 3, 'checkpoints': [1]},
                'r2': {'id': 'r2', 'family': 'family-B', 'capability': 'int64', 'gen': {'kind': 'cycle', 'values': [2]}, 'n': 4, 'checkpoints': [2]}},
            'labels': {'r1@1': {'converged': ['MATH', True]}, 'r2@2': {'stable': ['MATH', False]}},
            'tiers': [['R3', 'interp', 'loop', 'r1', 1, 'stable', False], ['R3', 'jit', 'straight', 'r1', 1, 'converged', True], ['CF', 'interp', 'straight', 'r2', 2, 'stable', False]],
            'decisions': {}, 'diffs': [], 'points': [], 'findings': [],
            'skipped': [('CF', 'r1', 'ieee'), ('R3', 'r2', 'int64')],
            'order': [('R3', 'r1'), ('CF', 'r1'), ('R3', 'r2'), ('CF', 'r2')],
            'capabilities': {'R3': {'ieee': True, 'int64': False}, 'CF': {'ieee': False, 'int64': True}},
            'readings': [['R3', 'r1', 1, 'converged', True], ['CF', 'r2', 2, 'stable', False], ['T001', 'r1', 1, 'converged', True], ['T001', 'r2', 2, 'converged', False]],
            'judge_rc': 2, 'judge_text': 'fixture judge text\n'},
        'loads': ['first', 'second'], 'run_inputs': [(True, True, 13)],
        'measure_inputs': [('r3-binary', {'rows': [{'id': 'r1', 'family': 'family-A', 'capability': 'ieee', 'gen': {'kind': 'cycle', 'values': [1]}, 'n': 3, 'checkpoints': [1]}]}, {'ieee': True, 'int64': False}), ('cf-transformed', {'rows': [{'id': 'r2', 'family': 'family-B', 'capability': 'int64', 'gen': {'kind': 'cycle', 'values': [2]}, 'n': 4, 'checkpoints': [2]}]}, {'ieee': False, 'int64': True})],
        'forwarding': [True, True, True, True], 'main_inputs': [True],
        'generate_inputs': [({'kind': 'cycle', 'values': [1]}, 3), ({'kind': 'cycle', 'values': [2]}, 4)],
        'tolerance_inputs': [0.01], 'tol_calls': [([1, 1, 1], 1), ([2, 2, 2, 2], 2)],
        'restored': (True, True, True), 'log': 'fixture judge text\n'}

    def population_accounting_both_directions():
        def one(measure_calls, order_count):
            def measure(binary, corpus, caps):
                return {'read': {}}
            def run_arms(bs, rows, seed):
                for unused in range(measure_calls):
                    R.J.score.measure('fixture', {'rows': []}, {})
                return {'R3': {}, 'CF': {}}, [], set(), [('R3', 'first'), ('CF', 'second')][:order_count], {'R3': {}, 'CF': {}}
            def main(argv):
                R.J.run_arms({'R3': 'fixture', 'CF': 'fixture'}, {}, 13)
                return 0
            with tempfile.TemporaryDirectory() as tmp, patch.object(R.J, 'load', return_value=({'rows': []}, {})), patch.object(R.J.score, 'measure', new=measure), patch.object(R.J, 'run_arms', new=run_arms), patch.object(R.J, 'main', new=main):
                try:
                    R.judge_population([Path(tmp)], {'R3': 'fixture', 'CF': 'fixture'}, {}, 13, 17, Path(tmp), 'accounting')
                except (R.Refusal, OSError, ValueError) as error:
                    return str(error)
                return 'accepted'
        return one(2, 1), one(1, 2)

    yield 'population-accounting-mismatch-both-directions', population_accounting_both_directions, (
        'INCOMPLETE: measurement/order accounting differs', 'INCOMPLETE: measurement/order accounting differs')

    def decision_wrapper_all_boundaries():
        facts = {'R3': {'floor_exit': 0, 'declarations': []},
                 'R3-STD': {'floor_exit': 17, 'declarations': ['R3-STD diagnostic', '#1830 standard violation']}}
        original_opt = {'fixture': 'kept', 'floor-exit': 'stale', 'declarations': 'stale'}
        arms = ['R3', 'R3-STD', 'INC', 'STD']
        point = {('R3', 'stable'): None, ('CF', 'stable'): Q(3, 4), ('CF', 'converged'): Q(1, 2)}
        fpr = {('R3', 'stable'): Q(1, 10)}
        rest = ({('R3', 'stable'): 0}, {('R3', 'stable'): 2}, 2, {'R3': {'ieee': True, 'int64': True}})
        calls, diff_calls = [], []
        transcripts = {
            'R3': 'header R3\n  converged 1 standard parity PASS: primary reason\n  converged 6 existing gates FAIL: fixture rule failure\n  converged => FAIL\n  stable 2 vs INC NOT EVALUATED: missing interval\n  stable => INCOMPLETE\n',
            'R3-STD': 'header R3-STD\n  converged 1 standard parity PASS: standard reason\n  converged => PASS\n  stable 6 existing gates FAIL: standard declarations\n  stable => FAIL\n',
            'CF': 'header CF\n  converged => FAIL\n  stable => PASS\n',
            'W4': 'header W4\n  converged => PASS\n  stable => INCOMPLETE\n'}

        def diff(a, b, p):
            diff_calls.append((a, b, p))
            return Q(1, 20), None, Q(1, 10), 0

        def run_arms(bs, rows, seed):
            return {}, [], set(), [], {}

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / 'separate-output'
            out.mkdir()
            corpus_path = root / 'corpus-root'
            stdout = io.StringIO()

            def decide(opt, subject, actual_arms, actual_point, actual_fpr, actual_diff, *actual_rest):
                calls.append({'subject': subject, 'fixture': opt['fixture'], 'floor': opt['floor-exit'],
                              'declaration_path_matches': opt['declarations'] == str(out / (subject + '-declarations.txt')),
                              'declarations': Path(opt['declarations']).read_text(), 'rest_count': len(actual_rest),
                              'forwarded': [actual_arms is arms, actual_point is point, actual_fpr is fpr, actual_diff is diff,
                                            *[a is b for a, b in zip(actual_rest[:-1], rest[:-1])], actual_rest[-1] == rest[-1]]})
                print(transcripts[subject], end='')

            def main(argv):
                R.J.run_arms({}, {}, 13)
                for subject in ('R3', 'R3-STD', 'CF', 'W4'):
                    R.J.decide(original_opt, subject, arms, point, fpr, diff, *rest)
                return 0

            with patch.object(R.J, 'PREDS', ('converged', 'stable')), patch.object(R.J, 'load', return_value=({'rows': []}, {})), patch.object(R.J, 'run_arms', new=run_arms), patch.object(R.J, 'decide', new=decide), patch.object(R.J, 'main', new=main), contextlib.redirect_stdout(stdout):
                pop = R.judge_population([corpus_path], {'R3': 'r3', 'R3-STD': 'std', 'CF': 'cf'}, facts, 13, 17, out, 'decision')
                return {'calls': calls, 'original_opt': original_opt,
                        'declaration_names': sorted(path.name for path in out.glob('*-declarations.txt')),
                        'decisions': pop['decisions'], 'points': pop['points'], 'diffs': pop['diffs'],
                        'diff_calls': diff_calls, 'stdout': stdout.getvalue(),
                        'log': (out / 'decision-judge.log').read_text(),
                        'restored': (R.J.run_arms is run_arms, R.J.decide is decide)}

    yield 'decision-wrapper-facts-files-forwarding-and-text', decision_wrapper_all_boundaries, {
        'calls': [
            {'subject': 'R3', 'fixture': 'kept', 'floor': '0', 'declaration_path_matches': True, 'declarations': '', 'rest_count': 4, 'forwarded': [True] * 8},
            {'subject': 'R3-STD', 'fixture': 'kept', 'floor': '17', 'declaration_path_matches': True, 'declarations': 'R3-STD diagnostic\n#1830 standard violation', 'rest_count': 4, 'forwarded': [True] * 7 + [False]},
            {'subject': 'CF', 'fixture': 'kept', 'floor': '0', 'declaration_path_matches': True, 'declarations': '', 'rest_count': 4, 'forwarded': [True] * 7 + [False]},
            {'subject': 'W4', 'fixture': 'kept', 'floor': '0', 'declaration_path_matches': True, 'declarations': '', 'rest_count': 4, 'forwarded': [True] * 7 + [False]}],
        'original_opt': {'fixture': 'kept', 'floor-exit': 'stale', 'declarations': 'stale'},
        'declaration_names': ['CF-declarations.txt', 'R3-STD-declarations.txt', 'R3-declarations.txt', 'W4-declarations.txt'],
        'decisions': {
            'R3': {'converged': {'rules': [['1 standard parity', 'PASS', 'primary reason'], ['6 existing gates', 'FAIL', 'fixture rule failure']], 'verdict': 'FAIL'}, 'stable': {'rules': [['2 vs INC', 'NOT EVALUATED', 'missing interval']], 'verdict': 'INCOMPLETE'}},
            'R3-STD': {'converged': {'rules': [['1 standard parity', 'PASS', 'standard reason']], 'verdict': 'PASS'}, 'stable': {'rules': [['6 existing gates', 'FAIL', 'standard declarations']], 'verdict': 'FAIL'}},
            'CF': {'converged': {'rules': [], 'verdict': 'FAIL'}, 'stable': {'rules': [], 'verdict': 'PASS'}},
            'W4': {'converged': {'rules': [], 'verdict': 'PASS'}, 'stable': {'rules': [], 'verdict': 'INCOMPLETE'}}},
        'points': [['CF', 'converged', '1/2'], ['CF', 'stable', '3/4'], ['R3', 'stable', None]],
        'diffs': [['STD', 'T001', 'converged', '1/20', None, '1/10', '0']],
        'diff_calls': [('STD', 'T001', 'converged')],
        'stdout': '',
        'log': 'header R3\n  converged 1 standard parity PASS: primary reason\n  converged 6 existing gates FAIL: fixture rule failure\n  converged => FAIL\n  stable 2 vs INC NOT EVALUATED: missing interval\n  stable => INCOMPLETE\nheader R3-STD\n  converged 1 standard parity PASS: standard reason\n  converged => PASS\n  stable 6 existing gates FAIL: standard declarations\n  stable => FAIL\nheader CF\n  converged => FAIL\n  stable => PASS\nheader W4\n  converged => PASS\n  stable => INCOMPLETE\n',
        'restored': (True, True)}

    def cli_default_bootstrap():
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / 'missing-parent' / 'result'
            calls, stdout, stderr = [], io.StringIO(), io.StringIO()
            def execute(args, raw):
                calls.append({'r3': args.r3, 'r3_std': args.r3_std, 'round': args.round,
                              'seed': args.seed, 'resamples': args.resamples,
                              'types': [type(args.round).__name__, type(args.seed).__name__, type(args.resamples).__name__],
                              'dry': args.dry, 'calibration': args.calibration, 'selftest': args.selftest,
                              'extract': args.extract, 'check_dry_a': args.check_dry_a,
                              'output_matches': args.out == out, 'output_is_path': isinstance(args.out, Path),
                              'output_exists_at_entry': out.is_dir(), 'raw': copy.deepcopy(raw)})
                return 73
            with patch.object(R, 'execute', new=execute), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                rc = R.main(['--r3', 'abcdef12', '--round', '7', '--out', str(out)])
            return {'rc': rc, 'calls': calls, 'nested_parent_created': out.parent.is_dir(),
                    'files': sorted(p.name for p in out.iterdir()), 'stdout': stdout.getvalue(), 'stderr': stderr.getvalue()}

    yield 'CLI-default-bootstrap-arguments-and-initial-raw', cli_default_bootstrap, {
        'rc': 73, 'calls': [{'r3': 'abcdef12', 'r3_std': '3eed5caf', 'round': 7, 'seed': 1758, 'resamples': 10000,
            'types': ['int', 'int', 'int'], 'dry': False, 'calibration': False, 'selftest': False,
            'extract': None, 'check_dry_a': None, 'output_matches': True, 'output_is_path': True,
            'output_exists_at_entry': True, 'raw': {'format': 'r3-reveal/1', 'dry': False, 'seed': 1758,
                'resamples': 10000, 'populations': {}, 'manifests': {}}}],
        'nested_parent_created': True, 'files': [], 'stdout': '', 'stderr': ''}

    def cli_explicit_bootstrap_refusal():
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'nested-parent' / 'refused'
            calls, stdout, stderr = [], io.StringIO(), io.StringIO()
            def execute(args, raw):
                calls.append({'r3_std': args.r3_std, 'round': args.round, 'seed': args.seed, 'resamples': args.resamples,
                              'types': [type(args.round).__name__, type(args.seed).__name__, type(args.resamples).__name__],
                              'dry': args.dry, 'calibration': args.calibration, 'raw_before': copy.deepcopy(raw)})
                raise R.Refusal('bootstrap stopped')
            with patch.object(R, 'execute', new=execute), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                rc = R.main(['--dry', '--r3', 'abcdef12', '--r3-std', 'ffeeddcc', '--round', '41',
                             '--seed', '-23', '--resamples', '31', '--out', str(out)])
            return {'rc': rc, 'calls': calls, 'raw': json.loads((out / 'raw.json').read_text()),
                    'decision': json.loads((out / 'decision.json').read_text()) if (out / 'decision.json').exists() else None,
                    'files': sorted(p.name for p in out.iterdir()), 'stdout': stdout.getvalue(), 'stderr': stderr.getvalue()}

    yield 'CLI-explicit-integers-and-early-refusal-raw', cli_explicit_bootstrap_refusal, {
        'rc': 2, 'calls': [{'r3_std': 'ffeeddcc', 'round': 41, 'seed': -23, 'resamples': 31,
            'types': ['int', 'int', 'int'], 'dry': True, 'calibration': False,
            'raw_before': {'format': 'r3-reveal/1', 'dry': True, 'seed': -23, 'resamples': 31, 'populations': {}, 'manifests': {}}}],
        'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': -23, 'resamples': 31,
                'populations': {}, 'manifests': {}, 'status': 'REFUSED', 'error': 'bootstrap stopped'},
        'decision': None,
        'files': ['raw.json'], 'stdout': 'REFUSED\n', 'stderr': 'REFUSED: bootstrap stopped\n'}

    def cli_integer_grammar():
        observed = []
        for flag in ('--round', '--seed'):
            for token in ('7/2', 'not-an-integer', '0.5'):
                with tempfile.TemporaryDirectory() as tmp:
                    out = Path(tmp) / 'result'
                    calls, stdout, stderr = [], io.StringIO(), io.StringIO()
                    def execute(args, raw):
                        calls.append(1)
                        return 73
                    options = ['--dry', '--r3', 'abcdef12']
                    if flag == '--seed':
                        options += ['--round', '7']
                    options += [flag, token, '--out', str(out)]
                    with patch.object(R, 'execute', new=execute), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                        try:
                            rc = R.main(options)
                        except SystemExit as error:
                            rc = error.code
                    observed.append((flag, token, rc, len(calls), out.exists(), stdout.getvalue(),
                                     'usage:' in stderr.getvalue() and flag in stderr.getvalue() and 'invalid' in stderr.getvalue()))
        return observed

    yield 'CLI-round-and-seed-integer-token-grammar', cli_integer_grammar, [
        ('--round', '7/2', 2, 0, False, '', True),
        ('--round', 'not-an-integer', 2, 0, False, '', True),
        ('--round', '0.5', 2, 0, False, '', True),
        ('--seed', '7/2', 2, 0, False, '', True),
        ('--seed', 'not-an-integer', 2, 0, False, '', True),
        ('--seed', '0.5', 2, 0, False, '', True)]

    def cli_help_description():
        import os
        import re
        import sys
        # Frozen literal is copied from the registered description, never R.__doc__.
        description = 'Round 3 reveal driver (#2330, #1758; RULING R30R-2).\n\nFirst matching row, independently for each predicate, using the frozen judge:\n R3 verdict PASS     -> R3:     "All six criteria pass: R3\'s band ships."\n R3-STD verdict PASS -> R3-STD: "Otherwise R3-STD ships for that predicate."\n otherwise           -> INC:    "INC\'s band stays for p, R3\'s change to p is\n                                reverted, and the table is posted."\nAdditive duties from R3: rule 4 FAIL -> silent-wrong issue + measured BA in\nPREDICATES.md; rules 2..5 PASS and rule 1 FAIL -> STD_p replacement on fresh H2.\nRule 2 against R3-STD stays exactly where the frozen judge puts it.\nNo outcome on REFUSED, INCOMPLETE, FINDING or VOID. VOID repeats step 1.\n\nRaw format r3-reveal/1: raw.json is a JSON object, sorted keys, UTF-8, newline.\n metadata: dry, seed (run order AND bootstrap), resamples, runtime arm stamps,\n           manifests (sha256 + full instrument manifest), driver file hashes.\n preflight: per subject floor exit, relevant declaration lines and capabilities.\n populations: calibration and H1 (or hcal in dry calibration mode). Each holds\n  rows: id -> full corpus row; labels: row@checkpoint -> derive label objects;\n  order: ordered [runtime arm, row] pairs; capabilities; skipped; findings;\n  readings: [arm,row,checkpoint,predicate,boolean] for interp/straight and Python\n            arms; absence is explicit in skipped, partial Python arm domains\n            are ROSTER below. tiers: [arm,tier,form,row,checkpoint,predicate,bool].\n  decisions: subject -> predicate -> {verdict,rules}; rules is an ordered list\n             [rule-name,PASS|FAIL|NOT EVALUATED,judge\'s explanation].\n  points: [arm,predicate,BA rational or null]; diffs: [A,B,p,d,lo,hi,left_out]\n          d is exact rational; CI endpoints are floats as printed by judge.\n  judge_rc; judge_text is an informational transcript, NOT extraction input.\n controls: a,c1,c2 booleans; b is true, false or "undefined". When b is\n  undefined, b_undefined lists the predicates without BA. False takes priority\n  over undefined if a defined predicate fails. status is rechecked on extraction.\n\nCanonical decision.json is derived ONLY from raw.json: status, dry, seed,\nresamples, exact family confusion tables / disagreements / absences and (if COMPLETE) for each predicate both subjects\' ordered rule names\nand statuses, verdicts, ship and additive duties. No paths, binary hashes,\nhostname, Python version, timestamps or rounded explanatory text enter it.\nRecompute via --extract RAW --out DIR. To replicate statistics independently,\nuse labels + readings to form TP FP FN TN; use rows as bootstrap clusters,\nrandom.Random(seed), 10000 shared draws as judge.py specifies (D9 shared-row\nsubsets have their own stream). Whole-population JSON files are also extracted\nonly from raw, with explicit null readings and every disagreement.\n\nCLI: --r3 SHA --r3-std SHA --round N --out DIR [--dry] [--calibration]\n     --calibration is allowed only with --dry (calibration + H-cal, no beacon).\nRuntime paths are never CLI inputs. Recipes build serially into build/ beneath\nthis checkout. --resamples defaults to registered 10000; lower is DRY only.\nManual review verdicts must be recorded by the orchestrator before H1 scoring.\nBefore unsealing, reveal_commitment.json must match the accepted hashes of this\ndriver, reveal_selftest.py and reveal_fixtures.json (the named fixture inventory).\n'
        calls, stdout, stderr = [], io.StringIO(), io.StringIO()
        def execute(args, raw):
            calls.append(1)
            return 73
        with patch.object(sys, 'argv', ['fixture-reveal']), patch.dict(os.environ, {'COLUMNS': '80'}), patch.object(R, 'execute', new=execute), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                rc = R.main(['--help'])
            except SystemExit as error:
                rc = error.code
        return {'rc': rc, 'execute_calls': len(calls), 'program': stdout.getvalue().startswith('usage: fixture-reveal '),
                # argparse may line-wrap an existing hyphenated word at its hyphen.
                # Rejoin only that formatting break; preserve every word/token.
                'frozen_description': ' '.join(re.sub(r'-\s*\n\s*', '-', description).split()) in ' '.join(re.sub(r'-\s*\n\s*', '-', stdout.getvalue()).split()),
                'stderr': stderr.getvalue()}

    yield 'CLI-help-frozen-description', cli_help_description, {
        'rc': 0, 'execute_calls': 0, 'program': True, 'frozen_description': True, 'stderr': ''}

    def cli_existing_output_refusal():
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'existing'
            out.mkdir()
            marker = out / 'sentinel'
            marker.write_bytes(b'keep\n')
            calls, stdout, stderr = [], io.StringIO(), io.StringIO()
            def execute(args, raw):
                calls.append(1)
                return 73
            error = None
            with patch.object(R, 'execute', new=execute), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                try:
                    R.main(['--r3', 'abcdef12', '--round', '7', '--out', str(out)])
                except FileExistsError as caught:
                    error = ('FileExistsError', caught.filename == str(out))
            return error, len(calls), marker.read_bytes(), sorted(p.name for p in out.iterdir()), stdout.getvalue(), stderr.getvalue()

    yield 'CLI-existing-output-directory-refused', cli_existing_output_refusal, (
        ('FileExistsError', True), 0, b'keep\n', ['sentinel'], '', '')

    def cli_extract_contract():
        raw={'format':'r3-reveal/1','status':'INCOMPLETE','dry':True,'seed':31,
             'resamples':17,'populations':{},'manifests':{},'error':'fixture'}
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'source.json';source.write_text(json.dumps(raw))
            out=Path(tmp)/'extracted'
            calls,stdout,stderr=[],io.StringIO(),io.StringIO()
            def execute(args,payload):
                calls.append(1)
                return 73
            with patch.object(R,'execute',new=execute),contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
                try:rc=R.main(['--extract',str(source),'--out',str(out)])
                except R.Refusal:rc=2
            return (rc,len(calls),(out/'decision.json').exists(),
                    any(line.startswith(('OUTCOME ','DRY OUTCOME ')) for line in stdout.getvalue().splitlines()))

    yield 'CLI-extract-return-code-and-output-contract',cli_extract_contract,(2,0,False,False)

    def cli_exception_protocol():
        faults = [('refusal', R.Refusal('ordinary refusal')),
                  ('prefix-no-space', R.Refusal('INCOMPLETE:reason')),
                  ('prefix-lookalike', R.Refusal('INCOMPLETE-but-not-protocol')),
                  ('value-prefix', ValueError('INCOMPLETE:reason')),
                  ('os-error', OSError('disk failure')),
                  ('harness-error', R.J.HarnessError('harness failure')),
                  ('subprocess-error', R.subprocess.SubprocessError('command failure'))]
        observed = []
        for label, fault in faults:
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / 'result'
                calls, stdout, stderr = [], io.StringIO(), io.StringIO()
                def execute(args, raw, fault=fault):
                    calls.append(1)
                    raise fault
                with patch.object(R, 'execute', new=execute), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    rc = R.main(['--dry', '--r3', 'abcdef12', '--round', '7', '--out', str(out)])
                stored = json.loads((out / 'raw.json').read_text())
                observed.append((label, rc, stored['status'], stored['error'], stdout.getvalue(),
                                 stderr.getvalue(), len(calls), sorted(p.name for p in out.iterdir())))
        return observed

    yield 'CLI-exception-status-prefix-and-stderr-protocol', cli_exception_protocol, [
        ('refusal', 2, 'REFUSED', 'ordinary refusal', 'REFUSED\n', 'REFUSED: ordinary refusal\n', 1, ['raw.json']),
        ('prefix-no-space', 2, 'INCOMPLETE', 'INCOMPLETE:reason', 'INCOMPLETE\n', 'INCOMPLETE: INCOMPLETE:reason\n', 1, ['raw.json']),
        ('prefix-lookalike', 2, 'REFUSED', 'INCOMPLETE-but-not-protocol', 'REFUSED\n', 'REFUSED: INCOMPLETE-but-not-protocol\n', 1, ['raw.json']),
        ('value-prefix', 2, 'INCOMPLETE', 'INCOMPLETE:reason', 'INCOMPLETE\n', 'INCOMPLETE: INCOMPLETE:reason\n', 1, ['raw.json']),
        ('os-error', 2, 'INCOMPLETE', 'disk failure', 'INCOMPLETE\n', 'INCOMPLETE: disk failure\n', 1, ['raw.json']),
        ('harness-error', 2, 'INCOMPLETE', 'harness failure', 'INCOMPLETE\n', 'INCOMPLETE: harness failure\n', 1, ['raw.json']),
        ('subprocess-error', 2, 'INCOMPLETE', 'command failure', 'INCOMPLETE\n', 'INCOMPLETE: command failure\n', 1, ['raw.json'])]

    def execute_registered_bootstrap(mode):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'result'
            trace, produced, stdout, stderr = [], [], io.StringIO(), io.StringIO()
            lookup = {'a' * 40: 'a' * 40, 'b' * 40: 'b' * 40, 'c' * 40: 'c' * 40, 'e' * 40: 'e' * 40,
                      '3eed5caf': 'b' * 40, '3d8a14b4': 'c' * 40,
                      '4a3a5c1941568e9bc562c7c8221cff22dc8ba697': 'd' * 40}
            original_guard = R.dry_guard
            def resolve(token):
                trace.append(('resolve', token))
                return lookup[token]
            def dry_guard(dry, calibration, subjects, allowed):
                trace.append(('dry_guard', dry, calibration, subjects, allowed))
                return original_guard(dry, calibration, subjects, allowed)
            def build(name, sha, destination):
                trace.append(('build', name, sha, destination == out))
                stamp = {'binary': 'fixture-binary-' + name, 'source_sha': sha}
                produced.append(stamp)
                return stamp
            def install(stamp, destination):
                trace.append(('install', bool(produced) and stamp is produced[0], destination == out))
                return {'score_sha256': 'fixture-instrument'}
            def floor(binary, destination, name):
                trace.append(('floor', binary, destination == out, name))
                raise R.Refusal('INCOMPLETE: stopped after stamp capture')
            def forbidden(label):
                def call(*args, **kwargs):
                    trace.append(('unexpected', label, len(args), sorted(kwargs)))
                    raise R.Refusal('unexpected ' + label)
                return call
            with patch.object(R, 'resolve', new=resolve), patch.object(R, 'dry_guard', new=dry_guard), patch.object(R, 'build', new=build), patch.object(R, 'install_instrument', new=install), patch.object(R, 'floor', new=floor), patch.object(R, 'command', new=forbidden('command')), patch.object(R, 'prepare_set', new=forbidden('prepare_set')), patch.object(R, 'sealed_set', new=forbidden('sealed_set')), patch.object(R.J.score, 'capabilities', new=forbidden('capabilities')), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                options = ['--r3', ('c' if mode == 'dry-standard' else 'a') * 40,
                           '--r3-std', ('e' if mode == 'wrong-real' else 'c' if mode == 'dry-r3' else 'b') * 40,
                           '--round', '7', '--seed', '29', '--out', str(out)]
                if mode.startswith('dry-'):
                    options.append('--dry')
                rc = R.main(options)
            return {'rc': rc, 'trace': trace, 'raw': json.loads((out / 'raw.json').read_text()),
                    'decision': json.loads((out / 'decision.json').read_text()) if (out / 'decision.json').exists() else None,
                    'files': sorted(p.name for p in out.iterdir()), 'stdout': stdout.getvalue(), 'stderr': stderr.getvalue()}

    _r4_bootstrap_trace_prefix = [('resolve', 'a' * 40), ('resolve', 'b' * 40),
        ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'),
        ('dry_guard', False, False, ['a' * 40, 'b' * 40], ['c' * 40, 'd' * 40]), ('resolve', '3eed5caf')]
    yield 'execute-registered-bootstrap-build-arguments', lambda: execute_registered_bootstrap('valid-real'), {'rc': 2, 'trace': _r4_bootstrap_trace_prefix + [('resolve', '3eed5caf'), ('build', 'R3-STD', 'b' * 40, True), ('install', True, True), ('build', 'R3', 'a' * 40, True), ('build', 'R3-STD', 'b' * 40, True), ('build', 'INC', 'c' * 40, True), ('build', 'ANCHOR', 'd' * 40, True), ('build', 'W4', 'c' * 40, True), ('floor', 'fixture-binary-R3', True, 'R3')], 'raw': {'format': 'r3-reveal/1', 'dry': False, 'seed': 29, 'resamples': 10000, 'populations': {}, 'manifests': {}, 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: stopped after stamp capture'}, 'decision': None, 'files': ['raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: stopped after stamp capture\n'}

    yield 'execute-real-standard-guard-before-build', lambda: execute_registered_bootstrap('wrong-real'), {'rc': 2, 'trace': [('resolve', 'a' * 40), ('resolve', 'e' * 40), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', False, False, ['a' * 40, 'e' * 40], ['c' * 40, 'd' * 40]), ('resolve', '3eed5caf')], 'raw': {'format': 'r3-reveal/1', 'dry': False, 'seed': 29, 'resamples': 10000, 'populations': {}, 'manifests': {}, 'status': 'REFUSED', 'error': 'R3-STD must be the registered 3eed5caf commit'}, 'decision': None, 'files': ['raw.json'], 'stdout': 'REFUSED\n', 'stderr': 'REFUSED: R3-STD must be the registered 3eed5caf commit\n'}

    yield 'execute-dry-subject-guard-before-build', lambda: (
        execute_registered_bootstrap('dry-r3'), execute_registered_bootstrap('dry-standard')), ({'rc': 2, 'trace': [('resolve', 'a' * 40), ('resolve', 'c' * 40), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, False, ['a' * 40, 'c' * 40], ['c' * 40, 'd' * 40])], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 10000, 'populations': {}, 'manifests': {}, 'status': 'REFUSED', 'error': 'DRY: Phase 2 subjects cannot read H1 families before the reveal; use INC/ANCHOR stand-ins or calibration/H-cal'}, 'decision': None, 'files': ['raw.json'], 'stdout': 'REFUSED\n', 'stderr': 'REFUSED: DRY: Phase 2 subjects cannot read H1 families before the reveal; use INC/ANCHOR stand-ins or calibration/H-cal\n'}, {'rc': 2, 'trace': [('resolve', 'c' * 40), ('resolve', 'b' * 40), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, False, ['c' * 40, 'b' * 40], ['c' * 40, 'd' * 40])], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 10000, 'populations': {}, 'manifests': {}, 'status': 'REFUSED', 'error': 'DRY: Phase 2 subjects cannot read H1 families before the reveal; use INC/ANCHOR stand-ins or calibration/H-cal'}, 'decision': None, 'files': ['raw.json'], 'stdout': 'REFUSED\n', 'stderr': 'REFUSED: DRY: Phase 2 subjects cannot read H1 families before the reveal; use INC/ANCHOR stand-ins or calibration/H-cal\n'})

    def execute_metadata_preflight(mode):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'result'
            tools = Path(__file__).resolve().parent
            trace, produced, stdout, stderr = [], [], io.StringIO(), io.StringIO()
            lookup = {'a' * 40: 'a' * 40, 'b' * 40: 'b' * 40, 'c' * 40: 'c' * 40, 'd' * 40: 'd' * 40,
                      '3eed5caf': 'b' * 40, '3d8a14b4': 'c' * 40,
                      '4a3a5c1941568e9bc562c7c8221cff22dc8ba697': 'd' * 40}
            original_guard = R.dry_guard
            def resolve(token):
                trace.append(('resolve', token))
                return lookup[token]
            def dry_guard(dry, calibration, subjects, allowed):
                trace.append(('dry_guard', dry, calibration, subjects, allowed))
                return original_guard(dry, calibration, subjects, allowed)
            def build(name, sha, destination):
                trace.append(('build', name, sha, destination == out))
                stamp = {'binary': 'fixture-binary-' + sha, 'source_sha': sha}
                produced.append(stamp)
                return stamp
            def install(stamp, destination):
                trace.append(('install', bool(produced) and stamp is produced[0], destination == out))
                return {'source_sha': 'b' * 40, 'score_sha256': 'fixture-instrument'}
            def capabilities(binary):
                trace.append(('capabilities', binary))
                if binary == 'fixture-binary-' + 'c' * 40:
                    bits = {'ieee': True, 'int64': False}
                elif binary == 'fixture-binary-' + 'd' * 40:
                    bits = {'ieee': False, 'int64': True}
                else:
                    raise R.Refusal('unexpected capability binary')
                return {'probe': 'ignored'}, bits
            def floor(binary, destination, name):
                trace.append(('floor', binary, destination == out, name))
                if mode != 'mixed-calibration':
                    raise R.Refusal('unexpected floor on stand-in')
                return {'floor_exit': 7, 'declarations': ['phase2 finding'],
                        'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}
            def sha(path):
                path = Path(path)
                trace.append(('sha', path.name, path.parent == tools))
                return 'pin-' + path.name
            def copy_boundary(source, destination):
                source, destination = Path(source), Path(destination)
                trace.append(('copy-stop', source.name, source.parent == tools, destination.parent == out / 'calibration'))
                raise R.Refusal('INCOMPLETE: stopped before manifest copying')
            def forbidden(label):
                def call(*args, **kwargs):
                    trace.append(('unexpected', label, len(args), sorted(kwargs)))
                    raise R.Refusal('unexpected ' + label)
                return call
            with patch.object(R, 'resolve', new=resolve), patch.object(R, 'dry_guard', new=dry_guard), patch.object(R, 'build', new=build), patch.object(R, 'install_instrument', new=install), patch.object(R, 'floor', new=floor), patch.object(R.J.score, 'capabilities', new=capabilities), patch.object(R.J.F, 'sha', new=sha), patch.object(R.J.F, 'write_manifest', new=forbidden('write_manifest')), patch.object(R.shutil, 'copyfile', new=copy_boundary), patch.object(R, 'command', new=forbidden('command')), patch.object(R, 'prepare_set', new=forbidden('prepare_set')), patch.object(R, 'sealed_set', new=forbidden('sealed_set')), patch.object(R, 'judge_population', new=forbidden('judge_population')), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                primary = 'a' if mode == 'mixed-calibration' else 'd' if mode == 'anchor-primary' else 'c'
                standard = 'd' if mode == 'inc-primary' else 'c'
                options = ['--dry', '--r3', primary * 40, '--r3-std', standard * 40,
                           '--round', '7', '--seed', '29', '--resamples', '31', '--out', str(out)]
                if mode == 'mixed-calibration':
                    options.append('--calibration')
                rc = R.main(options)
            return {'rc': rc, 'trace': trace, 'raw': json.loads((out / 'raw.json').read_text()),
                    'decision': json.loads((out / 'decision.json').read_text()) if (out / 'decision.json').exists() else None,
                    'files': sorted(p.name for p in out.iterdir()), 'stdout': stdout.getvalue(), 'stderr': stderr.getvalue()}

    yield 'execute-allowed-standin-facts-and-metadata', lambda: (
        execute_metadata_preflight('inc-primary'), execute_metadata_preflight('anchor-primary')), ({'rc': 2, 'trace': [('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', 'dddddddddddddddddddddddddddddddddddddddd'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, False, ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'R3-STD', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('capabilities', 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd'), ('sha', 'reveal.py', True), ('sha', 'manual_review.py', True), ('sha', 'manual_review.json', True), ('sha', 'verified_sources.json', True), ('sha', 'seal.py', True), ('sha', 'build_w4.sh', True), ('copy-stop', 'corpus.json', True, True)], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {}, 'manifests': {}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'R3-STD': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'pin-reveal.py', 'manual_review.py': 'pin-manual_review.py', 'manual_review.json': 'pin-manual_review.json', 'verified_sources.json': 'pin-verified_sources.json', 'seal.py': 'pin-seal.py', 'build_w4.sh': 'pin-build_w4.sh'}, 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: stopped before manifest copying'}, 'decision': None, 'files': ['calibration', 'raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: stopped before manifest copying\n'}, {'rc': 2, 'trace': [('resolve', 'dddddddddddddddddddddddddddddddddddddddd'), ('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, False, ['dddddddddddddddddddddddddddddddddddddddd', 'cccccccccccccccccccccccccccccccccccccccc'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'R3-STD', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('capabilities', 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd'), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('sha', 'reveal.py', True), ('sha', 'manual_review.py', True), ('sha', 'manual_review.json', True), ('sha', 'verified_sources.json', True), ('sha', 'seal.py', True), ('sha', 'build_w4.sh', True), ('copy-stop', 'corpus.json', True, True)], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {}, 'manifests': {}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'R3-STD': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'pin-reveal.py', 'manual_review.py': 'pin-manual_review.py', 'manual_review.json': 'pin-manual_review.json', 'verified_sources.json': 'pin-verified_sources.json', 'seal.py': 'pin-seal.py', 'build_w4.sh': 'pin-build_w4.sh'}, 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: stopped before manifest copying'}, 'decision': None, 'files': ['calibration', 'raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: stopped before manifest copying\n'})

    yield 'execute-mixed-calibration-preflight-refusal', lambda: execute_metadata_preflight('mixed-calibration'), {'rc': 2, 'trace': [('resolve', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), ('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, True, ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'cccccccccccccccccccccccccccccccccccccccc'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', True), ('build', 'R3-STD', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('floor', 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', True, 'R3'), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('sha', 'reveal.py', True), ('sha', 'manual_review.py', True), ('sha', 'manual_review.json', True), ('sha', 'verified_sources.json', True), ('sha', 'seal.py', True), ('sha', 'build_w4.sh', True)], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {}, 'manifests': {}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'source_sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}, 'R3-STD': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 7, 'declarations': ['phase2 finding'], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'pin-reveal.py', 'manual_review.py': 'pin-manual_review.py', 'manual_review.json': 'pin-manual_review.json', 'verified_sources.json': 'pin-verified_sources.json', 'seal.py': 'pin-seal.py', 'build_w4.sh': 'pin-build_w4.sh'}, 'status': 'REFUSED', 'error': 'rule 6 preflight failed; no beacon read, SHA is not final'}, 'decision': None, 'files': ['raw.json'], 'stdout': 'REFUSED\n', 'stderr': 'REFUSED: rule 6 preflight failed; no beacon read, SHA is not final\n'}

    def execute_primary_routing(mode):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'result'
            tools = Path(__file__).resolve().parent
            trace, produced, stdout, stderr = [], [], io.StringIO(), io.StringIO()
            lookup = {'a' * 40: 'a' * 40, 'b' * 40: 'b' * 40, 'c' * 40: 'c' * 40, 'd' * 40: 'd' * 40,
                      '3eed5caf': 'b' * 40, '3d8a14b4': 'c' * 40,
                      '4a3a5c1941568e9bc562c7c8221cff22dc8ba697': 'd' * 40}
            original_guard = R.dry_guard
            def resolve(token):
                trace.append(('resolve', token))
                return lookup[token]
            def dry_guard(dry, calibration, subjects, allowed):
                trace.append(('dry_guard', dry, calibration, subjects, allowed))
                return original_guard(dry, calibration, subjects, allowed)
            def build(name, sha, destination):
                trace.append(('build', name, sha, destination == out))
                stamp = {'binary': 'fixture-binary-' + sha, 'source_sha': sha}
                produced.append(stamp)
                return stamp
            def install(stamp, destination):
                trace.append(('install', bool(produced) and stamp is produced[0], destination == out))
                return {'source_sha': 'b' * 40, 'score_sha256': 'fixture-instrument'}
            def capabilities(binary):
                trace.append(('capabilities', binary))
                if binary == 'fixture-binary-' + 'c' * 40:
                    return {'probe': 'ignored'}, {'ieee': True, 'int64': False}
                if binary == 'fixture-binary-' + 'd' * 40:
                    return {'probe': 'ignored'}, {'ieee': False, 'int64': True}
                raise R.Refusal('unexpected capability binary')
            def floor(binary, destination, name):
                trace.append(('floor', binary, destination == out, name))
                if mode != 'calibration' or binary != 'fixture-binary-' + 'a' * 40 or destination != out or name != 'R3':
                    raise R.Refusal('unexpected floor arguments')
                return {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True},
                        'declaration_sha256': 'floor-pin'}
            def relative(path):
                path = Path(path)
                if not path.is_relative_to(out):
                    raise R.Refusal('unexpected path outside output')
                return path.relative_to(out).as_posix()
            def sha(path):
                path = Path(path)
                if path.parent == tools:
                    trace.append(('sha-driver', path.name))
                    return 'driver:' + path.name
                label = relative(path)
                trace.append(('sha-manifest', label))
                return 'manifest:' + label
            def copy_file(source, destination):
                source, destination = Path(source), Path(destination)
                label = relative(destination)
                folder, name = destination.parent.name, destination.name
                if destination.parent.parent != out or folder not in ('calibration', 'hcal') or name not in ('corpus.json', 'labels.json', 'certificate.json'):
                    raise R.Refusal('unexpected copy destination')
                expected_source = tools / name if folder == 'calibration' else tools / 'hcal' / name
                if source != expected_source:
                    raise R.Refusal('unexpected copy source')
                source_label = source.relative_to(tools).as_posix()
                trace.append(('copy', source_label, label))
                destination.write_text(json.dumps({'copied_from': source_label}))
            def manifest(directory, binaries):
                directory = Path(directory)
                label = relative(directory)
                if directory.parent != out or label not in ('calibration', 'hcal'):
                    raise R.Refusal('unexpected manifest directory')
                trace.append(('manifest', label, copy.deepcopy(binaries)))
                value = {'fixture_set': label, 'arms': dict(binaries), 'code': {'judge.py': 'fixture-code'}}
                (directory / 'manifest.json').write_text(json.dumps(value))
                return value
            def sealed(round_number, destination):
                destination = Path(destination)
                trace.append(('sealed', round_number, relative(destination)))
                if destination != out / 'H1':
                    raise R.Refusal('unexpected H1 destination')
                destination.mkdir(exist_ok=True)
                (destination / 'corpus.json').write_text(json.dumps({'fixture': 'sealed-corpus'}))
                return {'round': 7, 'randomness': 'ab' * 32, 'beacon': {'fixture': 'beacon-body'}}
            def prepare(path, binaries, work):
                path = Path(path)
                trace.append(('prepare', relative(path), copy.deepcopy(binaries), work == out))
                if path != out / 'H1' or work != out:
                    raise R.Refusal('unexpected prepare arguments')
                (path / 'labels.json').write_text(json.dumps({'fixture': 'labels'}))
                (path / 'certificate.json').write_text(json.dumps({'fixture': 'certificates'}))
                value = {'fixture_set': 'H1', 'arms': dict(binaries), 'code': {'judge.py': 'fixture-code'}}
                (path / 'manifest.json').write_text(json.dumps(value))
                return {'sha256': 'manifest:H1/manifest.json', 'manifest': value}
            def population(paths, binaries, facts, seed, resamples, destination, name):
                trace.append(('population', [relative(path) for path in paths], copy.deepcopy(binaries),
                              copy.deepcopy(facts), seed, resamples, destination == out, name))
                raise R.Refusal('INCOMPLETE: stopped at primary population')
            def forbidden(*args, **kwargs):
                raise R.Refusal('unexpected native command')
            with patch.object(R, 'resolve', new=resolve), patch.object(R, 'dry_guard', new=dry_guard), patch.object(R, 'build', new=build), patch.object(R, 'install_instrument', new=install), patch.object(R, 'floor', new=floor), patch.object(R.J.score, 'capabilities', new=capabilities), patch.object(R.J.F, 'sha', new=sha), patch.object(R.J.F, 'write_manifest', new=manifest), patch.object(R.shutil, 'copyfile', new=copy_file), patch.object(R, 'command', new=forbidden), patch.object(R, 'prepare_set', new=prepare), patch.object(R,'verify_commitment',return_value=None),patch.object(R, 'sealed_set', new=sealed), patch.object(R, 'judge_population', new=population), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                primary, standard = ('a', 'c') if mode == 'calibration' else ('c', 'd')
                options = ['--dry', '--r3', primary * 40, '--r3-std', standard * 40,
                           '--round', '7', '--seed', '29', '--resamples', '31', '--out', str(out)]
                if mode == 'calibration':
                    options.append('--calibration')
                rc = R.main(options)
            return {'rc': rc, 'trace': trace, 'raw': json.loads((out / 'raw.json').read_text()),
                    'decision': json.loads((out / 'decision.json').read_text()) if (out / 'decision.json').exists() else None,
                    'files': sorted(p.relative_to(out).as_posix() for p in out.rglob('*') if p.is_file()),
                    'stdout': stdout.getvalue(), 'stderr': stderr.getvalue()}

    yield 'execute-primary-population-routing-and-manifests', lambda: (
        execute_primary_routing('sealed'), execute_primary_routing('calibration')), ({'rc': 2, 'trace': [('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', 'dddddddddddddddddddddddddddddddddddddddd'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, False, ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'R3-STD', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('capabilities', 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd'), ('sha-driver', 'reveal.py'), ('sha-driver', 'manual_review.py'), ('sha-driver', 'manual_review.json'), ('sha-driver', 'verified_sources.json'), ('sha-driver', 'seal.py'), ('sha-driver', 'build_w4.sh'), ('copy', 'corpus.json', 'calibration/corpus.json'), ('copy', 'labels.json', 'calibration/labels.json'), ('copy', 'certificate.json', 'calibration/certificate.json'), ('manifest', 'calibration', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'calibration/manifest.json'), ('copy', 'hcal/corpus.json', 'hcal/corpus.json'), ('copy', 'hcal/labels.json', 'hcal/labels.json'), ('copy', 'hcal/certificate.json', 'hcal/certificate.json'), ('manifest', 'hcal', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'hcal/manifest.json'), ('sealed', 7, 'H1'), ('prepare', 'H1', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, True), ('population', ['H1'], {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'H1')], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {}, 'manifests': {'calibration': {'sha256': 'manifest:calibration/manifest.json', 'manifest': {'fixture_set': 'calibration', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'hcal': {'sha256': 'manifest:hcal/manifest.json', 'manifest': {'fixture_set': 'hcal', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'H1': {'sha256': 'manifest:H1/manifest.json', 'manifest': {'fixture_set': 'H1', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'R3-STD': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'driver:reveal.py', 'manual_review.py': 'driver:manual_review.py', 'manual_review.json': 'driver:manual_review.json', 'verified_sources.json': 'driver:verified_sources.json', 'seal.py': 'driver:seal.py', 'build_w4.sh': 'driver:build_w4.sh'}, 'primary': 'H1', 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: stopped at primary population', 'beacon': {'round': 7, 'randomness': 'abababababababababababababababababababababababababababababababab', 'beacon': {'fixture': 'beacon-body'}}}, 'decision': None, 'files': ['H1/certificate.json', 'H1/corpus.json', 'H1/labels.json', 'H1/manifest.json', 'calibration/certificate.json', 'calibration/corpus.json', 'calibration/labels.json', 'calibration/manifest.json', 'hcal/certificate.json', 'hcal/corpus.json', 'hcal/labels.json', 'hcal/manifest.json', 'raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: stopped at primary population\n'}, {'rc': 2, 'trace': [('resolve', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), ('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, True, ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'cccccccccccccccccccccccccccccccccccccccc'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', True), ('build', 'R3-STD', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('floor', 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', True, 'R3'), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('sha-driver', 'reveal.py'), ('sha-driver', 'manual_review.py'), ('sha-driver', 'manual_review.json'), ('sha-driver', 'verified_sources.json'), ('sha-driver', 'seal.py'), ('sha-driver', 'build_w4.sh'), ('copy', 'corpus.json', 'calibration/corpus.json'), ('copy', 'labels.json', 'calibration/labels.json'), ('copy', 'certificate.json', 'calibration/certificate.json'), ('manifest', 'calibration', {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'calibration/manifest.json'), ('copy', 'hcal/corpus.json', 'hcal/corpus.json'), ('copy', 'hcal/labels.json', 'hcal/labels.json'), ('copy', 'hcal/certificate.json', 'hcal/certificate.json'), ('manifest', 'hcal', {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'hcal/manifest.json'), ('population', ['hcal'], {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'hcal')], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {}, 'manifests': {'calibration': {'sha256': 'manifest:calibration/manifest.json', 'manifest': {'fixture_set': 'calibration', 'arms': {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'hcal': {'sha256': 'manifest:hcal/manifest.json', 'manifest': {'fixture_set': 'hcal', 'arms': {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'source_sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}, 'R3-STD': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'driver:reveal.py', 'manual_review.py': 'driver:manual_review.py', 'manual_review.json': 'driver:manual_review.json', 'verified_sources.json': 'driver:verified_sources.json', 'seal.py': 'driver:seal.py', 'build_w4.sh': 'driver:build_w4.sh'}, 'primary': 'hcal', 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: stopped at primary population'}, 'decision': None, 'files': ['calibration/certificate.json', 'calibration/corpus.json', 'calibration/labels.json', 'calibration/manifest.json', 'hcal/certificate.json', 'hcal/corpus.json', 'hcal/labels.json', 'hcal/manifest.json', 'raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: stopped at primary population\n'})


    def execute_secondary_routing(mode, missing):
        import sys
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'result'
            tools = Path(__file__).resolve().parent
            trace, produced, stdout, stderr = [], [], io.StringIO(), io.StringIO()
            population_calls = []
            lookup = {'a' * 40: 'a' * 40, 'b' * 40: 'b' * 40, 'c' * 40: 'c' * 40, 'd' * 40: 'd' * 40,
                      '3eed5caf': 'b' * 40, '3d8a14b4': 'c' * 40,
                      '4a3a5c1941568e9bc562c7c8221cff22dc8ba697': 'd' * 40}
            original_guard = R.dry_guard
            def resolve(token):
                trace.append(('resolve', token))
                return lookup[token]
            def dry_guard(dry, calibration, subjects, allowed):
                trace.append(('dry_guard', dry, calibration, subjects, allowed))
                return original_guard(dry, calibration, subjects, allowed)
            def build(name, sha, destination):
                trace.append(('build', name, sha, destination == out))
                stamp = {'binary': 'fixture-binary-' + sha, 'source_sha': sha}
                produced.append(stamp)
                return stamp
            def install(stamp, destination):
                trace.append(('install', bool(produced) and stamp is produced[0], destination == out))
                return {'source_sha': 'b' * 40, 'score_sha256': 'fixture-instrument'}
            def capabilities(binary):
                trace.append(('capabilities', binary))
                if binary == 'fixture-binary-' + 'c' * 40:
                    return {'probe': 'ignored'}, {'ieee': True, 'int64': False}
                if binary == 'fixture-binary-' + 'd' * 40:
                    return {'probe': 'ignored'}, {'ieee': False, 'int64': True}
                raise R.Refusal('unexpected capability binary')
            def floor(binary, destination, name):
                trace.append(('floor', binary, destination == out, name))
                if mode != 'calibration' or binary != 'fixture-binary-' + 'a' * 40 or destination != out or name != 'R3':
                    raise R.Refusal('unexpected floor arguments')
                return {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True},
                        'declaration_sha256': 'floor-pin'}
            def relative(path):
                path = Path(path)
                if not path.is_relative_to(out):
                    raise R.Refusal('unexpected path outside output')
                return path.relative_to(out).as_posix()
            def sha(path):
                path = Path(path)
                if path.parent == tools:
                    trace.append(('sha-driver', path.name))
                    return 'driver:' + path.name
                label = relative(path)
                trace.append(('sha-manifest', label))
                return 'manifest:' + label
            def copy_file(source, destination):
                source, destination = Path(source), Path(destination)
                label = relative(destination)
                folder, name = destination.parent.name, destination.name
                if destination.parent.parent != out or folder not in ('calibration', 'hcal') or name not in ('corpus.json', 'labels.json', 'certificate.json'):
                    raise R.Refusal('unexpected copy destination')
                expected_source = tools / name if folder == 'calibration' else tools / 'hcal' / name
                if source != expected_source:
                    raise R.Refusal('unexpected copy source')
                source_label = source.relative_to(tools).as_posix()
                trace.append(('copy', source_label, label))
                destination.write_text(json.dumps({'copied_from': source_label}))
            def manifest(directory, binaries):
                directory = Path(directory)
                label = relative(directory)
                if directory.parent != out or label not in ('calibration', 'hcal'):
                    raise R.Refusal('unexpected manifest directory')
                trace.append(('manifest', label, copy.deepcopy(binaries)))
                value = {'fixture_set': label, 'arms': dict(binaries), 'code': {'judge.py': 'fixture-code'}}
                (directory / 'manifest.json').write_text(json.dumps(value))
                return value
            def sealed(round_number, destination):
                destination = Path(destination)
                trace.append(('sealed', round_number, relative(destination)))
                if destination != out / 'H1':
                    raise R.Refusal('unexpected H1 destination')
                destination.mkdir(exist_ok=True)
                (destination / 'corpus.json').write_text(json.dumps({'fixture': 'sealed-corpus'}))
                return {'round': 7, 'randomness': 'ab' * 32, 'beacon': {'fixture': 'beacon-body'}}
            def prepare(path, binaries, work):
                path = Path(path)
                trace.append(('prepare', relative(path), copy.deepcopy(binaries), work == out))
                if path != out / 'H1' or work != out:
                    raise R.Refusal('unexpected prepare arguments')
                (path / 'labels.json').write_text(json.dumps({'fixture': 'labels'}))
                (path / 'certificate.json').write_text(json.dumps({'fixture': 'certificates'}))
                value = {'fixture_set': 'H1', 'arms': dict(binaries), 'code': {'judge.py': 'fixture-code'}}
                (path / 'manifest.json').write_text(json.dumps(value))
                return {'sha256': 'manifest:H1/manifest.json', 'manifest': value}
            def population(paths, binaries, facts, seed, resamples, destination, name):
                trace.append(('population', [relative(path) for path in paths], copy.deepcopy(binaries),
                              copy.deepcopy(facts), seed, resamples, destination == out, name))
                population_calls.append(name)
                reading_domains = [('R3', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('R3-STD', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('INC', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('ANCHOR', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('STD', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ("STD'", ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ("STD''", ('equilibrium',)), ('D2', ('improving',)), ('REF', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('C0', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('C1', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('PERSIST', ('converged', 'stable', 'equilibrium')), ('CF', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('W4', ('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium')), ('T001', ('converged',))]
                readings = [[arm, 'fixture', 7, predicate, False] for arm, domain in reading_domains for predicate in domain]
                readings.append(list(readings[0]))
                if missing and len(population_calls) == 1:
                    readings = [row for row in readings if not (row[0] == 'CF' and row[3] == 'converged')]
                return {'fixture_population': name, 'rows': {}, 'labels': {}, 'readings': readings}
            def command(argv, log):
                trace.append(('command', argv[0] == sys.executable, Path(argv[1]).relative_to(tools).as_posix(), list(argv[2:]), relative(log)))
                raise R.Refusal('INCOMPLETE: stopped before plants process')
            with patch.object(R, 'resolve', new=resolve), patch.object(R, 'dry_guard', new=dry_guard), patch.object(R, 'build', new=build), patch.object(R, 'install_instrument', new=install), patch.object(R, 'floor', new=floor), patch.object(R.J.score, 'capabilities', new=capabilities), patch.object(R.J.F, 'sha', new=sha), patch.object(R.J.F, 'write_manifest', new=manifest), patch.object(R.shutil, 'copyfile', new=copy_file), patch.object(R, 'command', new=command), patch.object(R, 'prepare_set', new=prepare), patch.object(R,'verify_commitment',return_value=None),patch.object(R, 'sealed_set', new=sealed), patch.object(R, 'judge_population', new=population), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                primary, standard = ('a', 'c') if mode == 'calibration' else ('c', 'd')
                options = ['--dry', '--r3', primary * 40, '--r3-std', standard * 40,
                           '--round', '7', '--seed', '29', '--resamples', '31', '--out', str(out)]
                if mode == 'calibration':
                    options.append('--calibration')
                rc = R.main(options)
            return {'rc': rc, 'trace': trace, 'raw': json.loads((out / 'raw.json').read_text()),
                    'decision': json.loads((out / 'decision.json').read_text()) if (out / 'decision.json').exists() else None,
                    'files': sorted(p.relative_to(out).as_posix() for p in out.rglob('*') if p.is_file()),
                    'stdout': stdout.getvalue(), 'stderr': stderr.getvalue()}

    yield 'execute-secondary-populations-roster-and-plants-command', lambda: (
        execute_secondary_routing('sealed', False), execute_secondary_routing('sealed', True),
        execute_secondary_routing('calibration', False), execute_secondary_routing('calibration', True)), ({'rc': 2, 'trace': [('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', 'dddddddddddddddddddddddddddddddddddddddd'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, False, ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'R3-STD', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('capabilities', 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd'), ('sha-driver', 'reveal.py'), ('sha-driver', 'manual_review.py'), ('sha-driver', 'manual_review.json'), ('sha-driver', 'verified_sources.json'), ('sha-driver', 'seal.py'), ('sha-driver', 'build_w4.sh'), ('copy', 'corpus.json', 'calibration/corpus.json'), ('copy', 'labels.json', 'calibration/labels.json'), ('copy', 'certificate.json', 'calibration/certificate.json'), ('manifest', 'calibration', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'calibration/manifest.json'), ('copy', 'hcal/corpus.json', 'hcal/corpus.json'), ('copy', 'hcal/labels.json', 'hcal/labels.json'), ('copy', 'hcal/certificate.json', 'hcal/certificate.json'), ('manifest', 'hcal', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'hcal/manifest.json'), ('sealed', 7, 'H1'), ('prepare', 'H1', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, True), ('population', ['H1'], {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'H1'), ('population', ['calibration'], {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'calibration'), ('population', ['hcal'], {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'hcal'), ('command', True, 'plants.py', ['--selftest'], 'plants.log')], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {'H1': {'fixture_population': 'H1', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'converged', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}, 'calibration': {'fixture_population': 'calibration', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'converged', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}, 'hcal': {'fixture_population': 'hcal', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'converged', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}}, 'manifests': {'calibration': {'sha256': 'manifest:calibration/manifest.json', 'manifest': {'fixture_set': 'calibration', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'hcal': {'sha256': 'manifest:hcal/manifest.json', 'manifest': {'fixture_set': 'hcal', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'H1': {'sha256': 'manifest:H1/manifest.json', 'manifest': {'fixture_set': 'H1', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'R3-STD': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'driver:reveal.py', 'manual_review.py': 'driver:manual_review.py', 'manual_review.json': 'driver:manual_review.json', 'verified_sources.json': 'driver:verified_sources.json', 'seal.py': 'driver:seal.py', 'build_w4.sh': 'driver:build_w4.sh'}, 'primary': 'H1', 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: stopped before plants process', 'beacon': {'round': 7, 'randomness': 'abababababababababababababababababababababababababababababababab', 'beacon': {'fixture': 'beacon-body'}}}, 'decision': None, 'files': ['H1/certificate.json', 'H1/corpus.json', 'H1/labels.json', 'H1/manifest.json', 'calibration/certificate.json', 'calibration/corpus.json', 'calibration/labels.json', 'calibration/manifest.json', 'hcal/certificate.json', 'hcal/corpus.json', 'hcal/labels.json', 'hcal/manifest.json', 'raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: stopped before plants process\n'}, {'rc': 2, 'trace': [('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', 'dddddddddddddddddddddddddddddddddddddddd'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, False, ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'R3-STD', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('capabilities', 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd'), ('sha-driver', 'reveal.py'), ('sha-driver', 'manual_review.py'), ('sha-driver', 'manual_review.json'), ('sha-driver', 'verified_sources.json'), ('sha-driver', 'seal.py'), ('sha-driver', 'build_w4.sh'), ('copy', 'corpus.json', 'calibration/corpus.json'), ('copy', 'labels.json', 'calibration/labels.json'), ('copy', 'certificate.json', 'calibration/certificate.json'), ('manifest', 'calibration', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'calibration/manifest.json'), ('copy', 'hcal/corpus.json', 'hcal/corpus.json'), ('copy', 'hcal/labels.json', 'hcal/labels.json'), ('copy', 'hcal/certificate.json', 'hcal/certificate.json'), ('manifest', 'hcal', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'hcal/manifest.json'), ('sealed', 7, 'H1'), ('prepare', 'H1', {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, True), ('population', ['H1'], {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'H1'), ('population', ['calibration'], {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'calibration'), ('population', ['hcal'], {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'hcal')], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {'H1': {'fixture_population': 'H1', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}, 'calibration': {'fixture_population': 'calibration', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'converged', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}, 'hcal': {'fixture_population': 'hcal', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'converged', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}}, 'manifests': {'calibration': {'sha256': 'manifest:calibration/manifest.json', 'manifest': {'fixture_set': 'calibration', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'hcal': {'sha256': 'manifest:hcal/manifest.json', 'manifest': {'fixture_set': 'hcal', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'H1': {'sha256': 'manifest:H1/manifest.json', 'manifest': {'fixture_set': 'H1', 'arms': {'R3': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'R3-STD': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'R3-STD': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': False, 'int64': True}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'driver:reveal.py', 'manual_review.py': 'driver:manual_review.py', 'manual_review.json': 'driver:manual_review.json', 'verified_sources.json': 'driver:verified_sources.json', 'seal.py': 'driver:seal.py', 'build_w4.sh': 'driver:build_w4.sh'}, 'primary': 'H1', 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: scored comparator roster or predicate domain missing', 'beacon': {'round': 7, 'randomness': 'abababababababababababababababababababababababababababababababab', 'beacon': {'fixture': 'beacon-body'}}}, 'decision': None, 'files': ['H1/certificate.json', 'H1/corpus.json', 'H1/labels.json', 'H1/manifest.json', 'calibration/certificate.json', 'calibration/corpus.json', 'calibration/labels.json', 'calibration/manifest.json', 'hcal/certificate.json', 'hcal/corpus.json', 'hcal/labels.json', 'hcal/manifest.json', 'raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: scored comparator roster or predicate domain missing\n'}, {'rc': 2, 'trace': [('resolve', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), ('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, True, ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'cccccccccccccccccccccccccccccccccccccccc'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', True), ('build', 'R3-STD', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('floor', 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', True, 'R3'), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('sha-driver', 'reveal.py'), ('sha-driver', 'manual_review.py'), ('sha-driver', 'manual_review.json'), ('sha-driver', 'verified_sources.json'), ('sha-driver', 'seal.py'), ('sha-driver', 'build_w4.sh'), ('copy', 'corpus.json', 'calibration/corpus.json'), ('copy', 'labels.json', 'calibration/labels.json'), ('copy', 'certificate.json', 'calibration/certificate.json'), ('manifest', 'calibration', {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'calibration/manifest.json'), ('copy', 'hcal/corpus.json', 'hcal/corpus.json'), ('copy', 'hcal/labels.json', 'hcal/labels.json'), ('copy', 'hcal/certificate.json', 'hcal/certificate.json'), ('manifest', 'hcal', {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'hcal/manifest.json'), ('population', ['hcal'], {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'hcal'), ('population', ['calibration'], {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'calibration'), ('command', True, 'plants.py', ['--selftest'], 'plants.log')], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {'hcal': {'fixture_population': 'hcal', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'converged', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}, 'calibration': {'fixture_population': 'calibration', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'converged', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}}, 'manifests': {'calibration': {'sha256': 'manifest:calibration/manifest.json', 'manifest': {'fixture_set': 'calibration', 'arms': {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'hcal': {'sha256': 'manifest:hcal/manifest.json', 'manifest': {'fixture_set': 'hcal', 'arms': {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'source_sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}, 'R3-STD': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'driver:reveal.py', 'manual_review.py': 'driver:manual_review.py', 'manual_review.json': 'driver:manual_review.json', 'verified_sources.json': 'driver:verified_sources.json', 'seal.py': 'driver:seal.py', 'build_w4.sh': 'driver:build_w4.sh'}, 'primary': 'hcal', 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: stopped before plants process'}, 'decision': None, 'files': ['calibration/certificate.json', 'calibration/corpus.json', 'calibration/labels.json', 'calibration/manifest.json', 'hcal/certificate.json', 'hcal/corpus.json', 'hcal/labels.json', 'hcal/manifest.json', 'raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: stopped before plants process\n'}, {'rc': 2, 'trace': [('resolve', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), ('resolve', 'cccccccccccccccccccccccccccccccccccccccc'), ('resolve', '3d8a14b4'), ('resolve', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('resolve', '3d8a14b4'), ('dry_guard', True, True, ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'cccccccccccccccccccccccccccccccccccccccc'], ['cccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddd']), ('resolve', '3eed5caf'), ('build', 'R3-STD', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', True), ('install', True, True), ('build', 'R3', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', True), ('build', 'R3-STD', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'INC', 'cccccccccccccccccccccccccccccccccccccccc', True), ('build', 'ANCHOR', 'dddddddddddddddddddddddddddddddddddddddd', True), ('build', 'W4', 'cccccccccccccccccccccccccccccccccccccccc', True), ('floor', 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', True, 'R3'), ('capabilities', 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'), ('sha-driver', 'reveal.py'), ('sha-driver', 'manual_review.py'), ('sha-driver', 'manual_review.json'), ('sha-driver', 'verified_sources.json'), ('sha-driver', 'seal.py'), ('sha-driver', 'build_w4.sh'), ('copy', 'corpus.json', 'calibration/corpus.json'), ('copy', 'labels.json', 'calibration/labels.json'), ('copy', 'certificate.json', 'calibration/certificate.json'), ('manifest', 'calibration', {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'calibration/manifest.json'), ('copy', 'hcal/corpus.json', 'hcal/corpus.json'), ('copy', 'hcal/labels.json', 'hcal/labels.json'), ('copy', 'hcal/certificate.json', 'hcal/certificate.json'), ('manifest', 'hcal', {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}), ('sha-manifest', 'hcal/manifest.json'), ('population', ['hcal'], {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'hcal'), ('population', ['calibration'], {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 29, 31, True, 'calibration')], 'raw': {'format': 'r3-reveal/1', 'dry': True, 'seed': 29, 'resamples': 31, 'populations': {'hcal': {'fixture_population': 'hcal', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}, 'calibration': {'fixture_population': 'calibration', 'rows': {}, 'labels': {}, 'readings': [['R3', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'stable', False], ['R3', 'fixture', 7, 'improving', False], ['R3', 'fixture', 7, 'oscillating', False], ['R3', 'fixture', 7, 'diverging', False], ['R3', 'fixture', 7, 'equilibrium', False], ['R3-STD', 'fixture', 7, 'converged', False], ['R3-STD', 'fixture', 7, 'stable', False], ['R3-STD', 'fixture', 7, 'improving', False], ['R3-STD', 'fixture', 7, 'oscillating', False], ['R3-STD', 'fixture', 7, 'diverging', False], ['R3-STD', 'fixture', 7, 'equilibrium', False], ['INC', 'fixture', 7, 'converged', False], ['INC', 'fixture', 7, 'stable', False], ['INC', 'fixture', 7, 'improving', False], ['INC', 'fixture', 7, 'oscillating', False], ['INC', 'fixture', 7, 'diverging', False], ['INC', 'fixture', 7, 'equilibrium', False], ['ANCHOR', 'fixture', 7, 'converged', False], ['ANCHOR', 'fixture', 7, 'stable', False], ['ANCHOR', 'fixture', 7, 'improving', False], ['ANCHOR', 'fixture', 7, 'oscillating', False], ['ANCHOR', 'fixture', 7, 'diverging', False], ['ANCHOR', 'fixture', 7, 'equilibrium', False], ['STD', 'fixture', 7, 'converged', False], ['STD', 'fixture', 7, 'stable', False], ['STD', 'fixture', 7, 'improving', False], ['STD', 'fixture', 7, 'oscillating', False], ['STD', 'fixture', 7, 'diverging', False], ['STD', 'fixture', 7, 'equilibrium', False], ["STD'", 'fixture', 7, 'converged', False], ["STD'", 'fixture', 7, 'stable', False], ["STD'", 'fixture', 7, 'improving', False], ["STD'", 'fixture', 7, 'oscillating', False], ["STD'", 'fixture', 7, 'diverging', False], ["STD'", 'fixture', 7, 'equilibrium', False], ["STD''", 'fixture', 7, 'equilibrium', False], ['D2', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'converged', False], ['REF', 'fixture', 7, 'stable', False], ['REF', 'fixture', 7, 'improving', False], ['REF', 'fixture', 7, 'oscillating', False], ['REF', 'fixture', 7, 'diverging', False], ['REF', 'fixture', 7, 'equilibrium', False], ['C0', 'fixture', 7, 'converged', False], ['C0', 'fixture', 7, 'stable', False], ['C0', 'fixture', 7, 'improving', False], ['C0', 'fixture', 7, 'oscillating', False], ['C0', 'fixture', 7, 'diverging', False], ['C0', 'fixture', 7, 'equilibrium', False], ['C1', 'fixture', 7, 'converged', False], ['C1', 'fixture', 7, 'stable', False], ['C1', 'fixture', 7, 'improving', False], ['C1', 'fixture', 7, 'oscillating', False], ['C1', 'fixture', 7, 'diverging', False], ['C1', 'fixture', 7, 'equilibrium', False], ['PERSIST', 'fixture', 7, 'converged', False], ['PERSIST', 'fixture', 7, 'stable', False], ['PERSIST', 'fixture', 7, 'equilibrium', False], ['CF', 'fixture', 7, 'converged', False], ['CF', 'fixture', 7, 'stable', False], ['CF', 'fixture', 7, 'improving', False], ['CF', 'fixture', 7, 'oscillating', False], ['CF', 'fixture', 7, 'diverging', False], ['CF', 'fixture', 7, 'equilibrium', False], ['W4', 'fixture', 7, 'converged', False], ['W4', 'fixture', 7, 'stable', False], ['W4', 'fixture', 7, 'improving', False], ['W4', 'fixture', 7, 'oscillating', False], ['W4', 'fixture', 7, 'diverging', False], ['W4', 'fixture', 7, 'equilibrium', False], ['T001', 'fixture', 7, 'converged', False], ['R3', 'fixture', 7, 'converged', False]]}}, 'manifests': {'calibration': {'sha256': 'manifest:calibration/manifest.json', 'manifest': {'fixture_set': 'calibration', 'arms': {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}, 'hcal': {'sha256': 'manifest:hcal/manifest.json', 'manifest': {'fixture_set': 'hcal', 'arms': {'R3': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'R3-STD': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'INC': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'ANCHOR': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'W4': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'CF': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc'}, 'code': {'judge.py': 'fixture-code'}}}}, 'instrument': {'source_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'score_sha256': 'fixture-instrument'}, 'stamps': {'R3': {'binary': 'fixture-binary-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'source_sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}, 'R3-STD': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'INC': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'ANCHOR': {'binary': 'fixture-binary-dddddddddddddddddddddddddddddddddddddddd', 'source_sha': 'dddddddddddddddddddddddddddddddddddddddd'}, 'W4': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}, 'CF': {'binary': 'fixture-binary-cccccccccccccccccccccccccccccccccccccccc', 'source_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}, 'preflight': {'R3': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': True}, 'declaration_sha256': 'floor-pin'}, 'R3-STD': {'floor_exit': 0, 'declarations': [], 'capabilities': {'ieee': True, 'int64': False}, 'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}}, 'driver': {'reveal.py': 'driver:reveal.py', 'manual_review.py': 'driver:manual_review.py', 'manual_review.json': 'driver:manual_review.json', 'verified_sources.json': 'driver:verified_sources.json', 'seal.py': 'driver:seal.py', 'build_w4.sh': 'driver:build_w4.sh'}, 'primary': 'hcal', 'status': 'INCOMPLETE', 'error': 'INCOMPLETE: scored comparator roster or predicate domain missing'}, 'decision': None, 'files': ['calibration/certificate.json', 'calibration/corpus.json', 'calibration/labels.json', 'calibration/manifest.json', 'hcal/certificate.json', 'hcal/corpus.json', 'hcal/labels.json', 'hcal/manifest.json', 'raw.json'], 'stdout': 'INCOMPLETE\n', 'stderr': 'INCOMPLETE: INCOMPLETE: scored comparator roster or predicate domain missing\n'})



# R30R-A1 exact positive effect fixtures; final proof execution is external.
# A1 item 2: exact synthetic wins from confusion counts, both sides of +0.05.
_round5_rule2_win_prior_cases = cases


def cases(R):
    yield from _round5_rule2_win_prior_cases(R)

    def known_size_rule2_win(predicate, counts):
        incumbent = R.J.exact_ba([500000, 0, 500000, 10])
        subject = R.J.exact_ba(counts)
        difference = subject - incumbent
        return incumbent, subject, difference, R.J.rule2(predicate, difference, R.J.ci_bound(0.001))

    for predicate in ('converged', 'stable'):
        for tag, counts, subject, difference, passed in (
            ('inside', [600002, 0, 399998, 10], Q(800001, 1000000), Q(50001, 1000000), True),
            ('at', [600000, 0, 400000, 10], Q(4, 5), Q(1, 20), True),
            ('outside', [599998, 0, 400002, 10], Q(799999, 1000000), Q(49999, 1000000), False),
        ):
            yield ('synthetic-rule2-known-win-' + predicate + '-' + tag,
                   lambda predicate=predicate, counts=counts: known_size_rule2_win(predicate, counts),
                   (Q(3, 4), subject, difference, passed))



# R30R-5/A1: evidence refusal, tri-state controls, typed capabilities and crash.
_round5_ruling5_prior_cases = cases


def wrapper_decide_fixture(R, capabilities, record_floor=False):
    """Real frozen decide reached through the production recording wrapper."""
    arms=['R3','R3-STD','INC','STD','T001']
    point={(a,p):Q(9,10) if a=='R3' else Q(4,5) if a=='R3-STD' else Q(7,10)
           for a in arms for p in FIXTURE_PREDS}
    fpr={k:Q(1,10) for k in point}
    flips={('R3',p):0 for p in FIXTURE_PREDS}
    compared={k:2 for k in flips}
    def diff(a,b,p):
        d=point[a,p]-point[b,p]
        return d,float(d-Q(1,100)),float(d+Q(1,100)),0
    def main(argv):
        R.J.run_arms({}, {}, 1758)
        R.J.decide({},'R3',arms,point,fpr,diff,flips,compared,2,capabilities)
        return 0
    floor_calls=[]
    original_rule6=R.J.rule6
    def rule6(rc,declarations):
        floor_calls.append((type(rc).__name__,rc,list(declarations)))
        return original_rule6(rc,declarations)
    with tempfile.TemporaryDirectory() as tmp:
        root=Path(tmp)
        with patch.object(R.J,'load',return_value=({'rows':[]},{})),patch.object(R.J,'run_arms',return_value=({},[],set(),[],capabilities)),patch.object(R.J,'main',new=main),patch.object(R.J,'rule6',new=rule6):
            pop=R.judge_population([root],{'R3':'r3','CF':'cf'},
                                   {'R3':{'floor_exit':0,'declarations':[]}},1758,3,root,'typed-decide')
    if record_floor:
        return floor_calls
    return [(p,pop['decisions']['R3'][p]['verdict'],
             [(name,status) for name,status,note in pop['decisions']['R3'][p]['rules']
              if name[0] in '1346']) for p in FIXTURE_PREDS]


def cases(R):
    yield from _round5_ruling5_prior_cases(R)

    # Every registered name and domain is an independent literal fixture.
    for subject in ('R3','R3-STD','CF','W4'):
        for predicate in FIXTURE_PREDS:
            yield 'registered-rule-domain-'+subject+'-'+predicate, lambda subject=subject,predicate=predicate: R.registered_rules(subject,predicate), [row[0] for row in registered_verdict(predicate,subject)['rules']]

    def bad_raw(kind):
        raw=complete_raw()
        target=raw['populations']['H1']['decisions']['R3']['converged']
        if kind=='truncated-rules':
            target['rules']=target['rules'][:2]
        elif kind=='empty-rules':
            target['rules']=[]
        elif kind=='no-controls':
            del raw['controls']
        elif kind=='failed-control-b':
            raw['controls']['b']=False
        elif kind=='zero-H1':
            raw['populations']['H1']['rows']={}
            raw['populations']['H1']['labels']={}
            raw['populations']['H1']['readings']=[]
        elif kind=='no-preflight':
            del raw['preflight']
        elif kind=='lying-verdict':
            target['rules'][0][1]='FAIL'
        elif kind=='wrong-primary':
            raw['dry']=False
            raw['populations']['calibration']=copy.deepcopy(raw['populations']['H1'])
            raw['primary']='calibration'
        elif kind=='calibration-primary-H1-empty':
            raw['populations']['calibration']=copy.deepcopy(raw['populations']['H1'])
            raw['populations']['H1']['rows']={}
            raw['populations']['H1']['labels']={}
            raw['populations']['H1']['readings']=[]
            raw['primary']='calibration'
        else:
            raise AssertionError(kind)
        return raw

    for kind in ('truncated-rules','empty-rules','no-controls','failed-control-b','zero-H1','no-preflight','lying-verdict','wrong-primary','calibration-primary-H1-empty'):
        yield 'F2-extract-'+kind+'-refused', lambda kind=kind: refusal_result(R,lambda:R.extract(bad_raw(kind))), 'REFUSED'

    def refused_writer(kind):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);stdout=io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result=refusal_result(R,lambda:R.write_outputs(bad_raw(kind),root))
            return result,(root/'decision.json').exists(),any(line.startswith(('OUTCOME ','DRY OUTCOME ')) for line in stdout.getvalue().splitlines())
    yield 'F2-write-truncated-rules-no-artifact-or-outcomes',lambda:refused_writer('truncated-rules'),('REFUSED',False,False)
    for kind in ('empty-rules','no-controls','failed-control-b','zero-H1','no-preflight'):
        yield 'F2-write-'+kind+'-no-artifact-or-outcomes',lambda kind=kind:refused_writer(kind),('REFUSED',False,False)

    def control_b_state(undefined=(),bad=None):
        points={p:None if p in undefined else Q(1,2) for p in FIXTURE_PREDS}
        if bad is not None:
            points[bad]=Q(3,5)
        return R.controls_ok(True,points,fixture_decisions(),(Q(1,20),0.001))
    yield 'F1-control-b-defined-true',lambda:control_b_state(),{'a':True,'b':True,'c1':True,'c2':True}
    yield 'F1-control-b-undefined-tristate',lambda:control_b_state(('diverging','equilibrium')),{'a':True,'b':'undefined','b_undefined':['diverging','equilibrium'],'c1':True,'c2':True}
    for predicate in ('converged','stable','improving','oscillating'):
        yield 'F1-defined-failure-beats-undefined-'+predicate,lambda predicate=predicate:control_b_state(('diverging','equilibrium'),predicate),{'a':True,'b':False,'b_undefined':['diverging','equilibrium'],'c1':True,'c2':True}

    def bad_dry_b(predicate,change):
        raw=diagnostic_fixture()
        pop=raw['populations']['hcal']
        if change=='point':
            next(row for row in pop['points'] if row[1]==predicate)[2]='3/5'
        elif change=='verdict':
            pop['decisions']['CF'][predicate]=registered_verdict(predicate,'CF')
        else:
            raise AssertionError(change)
        points={p:None if v is None else Q(v) for a,p,v in pop['points'] if a=='CF'}
        raw['controls']=R.controls_ok(True,points,pop['decisions'],(Q(1,20),0.001))
        raw['reasons']=R.incomplete_reasons(raw)
        return raw['controls']['b'],R.dry_a_ok(raw)
    for predicate in ('converged','stable','improving','oscillating'):
        for change in ('point','verdict'):
            yield 'F1-Dry-A-failed-'+change+'-'+predicate,lambda predicate=predicate,change=change:bad_dry_b(predicate,change),(False,False)
    yield 'F1-Dry-A-undefined-exactly-two-accepted',lambda:R.dry_a_ok(diagnostic_fixture()),True
    for predicate in ('converged','stable','improving','oscillating'):
        def extra_undefined(predicate=predicate):
            raw=diagnostic_fixture()
            next(row for row in raw['populations']['hcal']['points'] if row[1]==predicate)[2]=None
            raw['controls']['b_undefined']=sorted(['diverging','equilibrium',predicate])
            return R.dry_a_ok(raw)
        yield 'F1-Dry-A-extra-undefined-'+predicate,extra_undefined,False
    for state in (False,True):
        yield 'F1-Dry-A-b-not-undefined-'+str(state),lambda state=state:R.dry_a_ok(diagnostic_fixture()|{'controls':{'a':True,'b':state,'c1':True,'c2':True}}),False
    yield 'F1-H1-undefined-is-INCOMPLETE',lambda:R.status_for(0,fixture_decisions(),control_b_state(('diverging',))),'INCOMPLETE'
    yield 'F1-H1-false-is-VOID',lambda:R.status_for(0,fixture_decisions(),control_b_state(('diverging',),'stable')),'VOID'

    for key in ('ieee','int64'):
        for value in ('absent',1,0,None,[],{}):
            fact={'floor_exit':0,'declarations':[],'capabilities':{'ieee':True,'int64':True}}
            fact['capabilities'][key]=value
            yield 'PF5-preflight-'+key+'-'+repr(value),lambda fact=fact:R.preflight_ok(fact),False
    expected_absent=[(p,'FAIL',[(n,'FAIL' if n[0]=='6' else 'NOT EVALUATED') for n in
                       (['1 standard parity']+(['3 safety'] if p in ('converged','stable','equilibrium','diverging') else [])+['4 trivial floor','6 existing gates'])]) for p in FIXTURE_PREDS]
    yield 'D11-absent-capabilities-at-real-decide',lambda:wrapper_decide_fixture(R,{}),expected_absent
    yield 'R6-floor-exit-string-at-real-rule-call',lambda:wrapper_decide_fixture(R,{'R3':{'ieee':True,'int64':True}},True),[('str','0',[])]*6

    def d14_wrapper(kind,good=True):
        generator={'kind':'ar1','phi':'0.9','burn':200 if good else 174}
        row={'id':'named-wrapper','family':'F15 unit-scaled copies','gen':{'kind':'scaled','base':generator}}
        rows=[row]
        if kind=='nested':
            row['gen']['base']={'kind':'scaled','base':generator}
        elif kind=='row-object':
            row['gen']['base']={'id':'inline-base','family':'F9 AR1','gen':generator}
        elif kind=='string':
            row['gen']['base']='referenced-base'
            rows.append({'id':'referenced-base','family':'F9 AR1','gen':generator})
        elif kind=='missing-string':
            row['gen']['base']='missing-base'
        elif kind=='malformed':
            row['gen']['base']=42
        elif kind=='gen-cycle':
            row['gen']['base']=row['gen']
        elif kind=='top-cycle':
            row['gen']={'kind':'affine','start':0,'step':0};row['base']='cycle-base'
            rows.append({'id':'cycle-base','family':'F15 unit-scaled copies','base':'named-wrapper','gen':{'kind':'affine','start':0,'step':0}})
        elif kind=='F15b-unknown':
            row['family']='F15b base for unit-scaled copies'
            row['gen']={'kind':'affine','start':0,'step':0}
        elif kind=='unknown-kind':
            row['gen']={'kind':'wrapper','base':generator}
        elif kind!='dict':
            raise AssertionError(kind)
        try:
            return R.check_d14({'rows':rows})
        except R.Refusal as error:
            return str(error).startswith('INCOMPLETE: named-wrapper: D14')
    for kind in ('dict','nested','row-object','string'):
        yield 'D14-wrapper-'+kind+'-valid',lambda kind=kind:d14_wrapper(kind),['named-wrapper','referenced-base'] if kind=='string' else ['named-wrapper']
        yield 'D14-wrapper-'+kind+'-bad-bound-names-row',lambda kind=kind:d14_wrapper(kind,False),True
    for kind in ('missing-string','malformed','gen-cycle','top-cycle','F15b-unknown','unknown-kind'):
        yield 'D14-wrapper-'+kind+'-unresolved-refused',lambda kind=kind:d14_wrapper(kind),True


def killed_h1_fixture(R):
    """Actual owned child SIGKILL in real main/execute/judge_population.

    Build/network/manifest IO is fixture data. The frozen judge reaches the
    run_arms measurement boundary on H1, reports ready, then parent kills it.
    No binary, live drand request or recipe build runs in this unit fixture.
    The separate actual dry-H1 kill receipt validates the live seam as well.
    """
    import gc
    import os
    import select
    import signal
    import time
    from types import SimpleNamespace
    fork,kill,waitpid,write,read,close,child_exit=os.fork,os.kill,os.waitpid,os.write,os.read,os.close,os._exit
    with tempfile.TemporaryDirectory() as tmp:
        root=Path(tmp);out=root/'killed';log=root/'child-output.txt'
        ready_r,ready_w=os.pipe()
        child=fork()
        if child==0:
            # The alarm bounds an orphan even if the outer census watchdog
            # kills this fixture's parent before its finally clause runs.
            signal.signal(signal.SIGALRM,signal.SIG_DFL)
            signal.alarm(2)
            gc.disable()
            handle=log.open('wb')
            os.dup2(handle.fileno(),1);os.dup2(handle.fileno(),2)
            for token in os.listdir('/proc/self/fd'):
                fd=int(token)
                if fd not in (0,1,2,ready_w):
                    try:close(fd)
                    except OSError:pass
            class Capture:
                def write(self,value):
                    data=str(value).encode('utf-8');write(1,data);return len(value)
                def flush(self):pass
            output=Capture()
            def resolve(sha):
                return {'3d8a14b4':'c'*40,'3eed5caf':'b'*40,R.ANCHOR:'d'*40}.get(sha,sha)
            def build(name,sha,destination):return {'binary':'fixture-'+name}
            def manifest(path,binaries):
                path=Path(path);path.mkdir(parents=True,exist_ok=True)
                value={'arms':dict(binaries),'code':{'judge.py':'fixture'}}
                (path/'manifest.json').write_text(json.dumps(value));return value
            def copy_file(source,destination):
                Path(destination).write_text('{}')
            def sealed(round_number,destination):
                destination.mkdir();return {'round':round_number,'randomness':'ab'*32}
            def prepare(path,binaries,destination):
                return {'sha256':'fixture','manifest':manifest(path,binaries)}
            row={'id':'h1-kill-row','family':'F9 AR1','gen':{'kind':'ar1','phi':0.9,'burn':200},'n':1,'checkpoints':[1]}
            labels={'h1-kill-row@1':{p:['MATH',False,'fixture'] for p in FIXTURE_PREDS}}
            def load(path):
                if Path(path).name!='H1':raise AssertionError('not H1 at kill boundary')
                return {'rows':[row]},labels
            def stop_in_real_score(binaries,rows,seed):
                if set(rows)!= {'h1-kill-row'}:raise AssertionError('wrong H1 population')
                write(ready_w,b'H1-SCORING\n')
                select.select([],[],[],1)
                child_exit(83)
            try:
                with patch.object(R,'resolve',new=resolve),patch.object(R,'build',new=build),patch.object(R,'install_instrument',return_value={'score_sha256':'fixture'}),patch.object(R.J.score,'capabilities',return_value=(None,{'ieee':True,'int64':True})),patch.object(R.J.F,'write_manifest',new=manifest),patch.object(R.shutil,'copyfile',new=copy_file),patch.object(R,'verify_commitment',return_value=None),patch.object(R,'sealed_set',new=sealed),patch.object(R,'prepare_set',new=prepare),patch.object(R.J,'load',new=load),patch.object(R.J.F,'verify_manifest',return_value=None),patch.object(R.J.score,'sha256',return_value='fixture'),patch.object(R.J,'const_false',return_value=('fixture-CF',str(root/'cf-work'))),patch.object(R.J,'run_arms',new=stop_in_real_score),contextlib.redirect_stdout(output),contextlib.redirect_stderr(output):
                    R.main(['--dry','--r3','3d8a14b4','--r3-std','3d8a14b4','--round','6619272','--resamples','3','--out',str(out)])
            except BaseException as error:
                try:write(ready_w,('ERROR:'+type(error).__name__+':'+str(error)).encode('utf-8')[:240])
                except OSError:pass
                child_exit(84)
            child_exit(85)
        close(ready_w)
        status=None;ready=b''
        try:
            if select.select([ready_r],[],[],1)[0]:ready=read(ready_r,64)
        finally:
            close(ready_r)
            try:kill(child,signal.SIGKILL)
            except ProcessLookupError:pass
            _,status=waitpid(child,0)
        killed=os.WIFSIGNALED(status) and os.WTERMSIG(status)==signal.SIGKILL
        text=log.read_text() if log.exists() else ''
        no_outcome=not any(line.startswith(('OUTCOME ','DRY OUTCOME ')) for line in text.splitlines())
        repeat_stdout=io.StringIO()
        with contextlib.redirect_stdout(repeat_stdout),contextlib.redirect_stderr(io.StringIO()):
            try:
                R.main(['--dry','--r3','3d8a14b4','--r3-std','3d8a14b4','--round','6619272','--resamples','3','--out',str(out)])
                repeat_refused=False
            except (FileExistsError,R.Refusal):repeat_refused=True
        truncated=root/'truncated.json'
        payload=json.dumps(complete_raw()).encode('utf-8');truncated.write_bytes(payload[:len(payload)//2])
        extract_out=root/'extract-truncated';extract_stdout=io.StringIO()
        with contextlib.redirect_stdout(extract_stdout),contextlib.redirect_stderr(io.StringIO()):
            try:
                extract_rc=R.main(['--extract',str(truncated),'--out',str(extract_out)])
            except (R.Refusal,ValueError,OSError):extract_rc=2
        return (True if ready==b'H1-SCORING\n' else ready.decode('utf-8',errors='replace'),killed,(out/'decision.json').exists(),no_outcome,
                repeat_refused,not any('OUTCOME ' in line for line in repeat_stdout.getvalue().splitlines()),
                extract_rc,(extract_out/'decision.json').exists(),not any('OUTCOME ' in line for line in extract_stdout.getvalue().splitlines()))


_round5_crash_prior_cases=cases


def cases(R):
    yield from _round5_crash_prior_cases(R)
    yield 'A1-kill-during-H1-scoring-fails-closed',lambda:killed_h1_fixture(R),(True,True,False,True,True,True,2,False,True)


_round5_terminal_base_prior_cases=cases


def cases(R):
    yield from _round5_terminal_base_prior_cases(R)
    def unresolved_terminal(family):
        rows=[{'id':'named-top-copy','family':'F15 unit-scaled copies','base':'terminal-base',
               'gen':{'kind':'affine','start':0,'step':0}},
              {'id':'terminal-base','family':family,'gen':{'kind':'affine','start':0,'step':0}}]
        try:
            R.check_d14({'rows':rows})
        except R.Refusal as error:
            return str(error)
        return 'accepted'
    for family in ('','unknown','F19 unknown','F15 unit-scaled copies','F15b base from F19 unknown'):
        yield 'D14-top-copy-unresolved-terminal-'+repr(family),lambda family=family:unresolved_terminal(family),'INCOMPLETE: named-top-copy: D14 unresolved base'
    for capability in ('ieee','int64'):
        yield 'D11-nonboolean-capability-at-decide-'+capability,lambda capability=capability:refusal_result(R,lambda:wrapper_decide_fixture(R,{'R3':{'ieee':True,'int64':True}|{capability:'absent'}})),'REFUSED'


_round5_commitment_prior_cases=cases


def cases(R):
    yield from _round5_commitment_prior_cases(R)
    def commitment_fixture(mode):
        import hashlib
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            payloads={'reveal.py':b'driver\n','reveal_selftest.py':b'selftest\n','reveal_fixtures.json':b'fixtures\n'}
            for name,data in payloads.items():(root/name).write_bytes(data)
            commitment={'format':'r3-reveal-commitment/1','sha256':{name:hashlib.sha256(data).hexdigest() for name,data in payloads.items()}}
            if mode in payloads:
                (root/mode).write_bytes(payloads[mode]+b'changed\n')
            elif mode=='format':
                commitment['format']='r3-reveal-commitment/2'
            elif mode=='missing-member':
                del commitment['sha256']['reveal_selftest.py']
            elif mode=='extra-member':
                commitment['sha256']['extra.py']='0'*64
            elif mode=='missing-file':
                (root/'reveal_fixtures.json').unlink()
            (root/'reveal_commitment.json').write_text(json.dumps(commitment))
            if mode=='missing-commitment':(root/'reveal_commitment.json').unlink()
            elif mode=='invalid-json':(root/'reveal_commitment.json').write_text('{')
            with patch.object(R,'__file__',str(root/'reveal.py')):
                try:
                    R.verify_commitment()
                except (R.Refusal,OSError,ValueError,KeyError,TypeError):
                    return 'REFUSED'
            return 'accepted'
    yield 'A1-commitment-three-files-green',lambda:commitment_fixture('green'),'accepted'
    for mode in ('reveal.py','reveal_selftest.py','reveal_fixtures.json','format','missing-member','extra-member','missing-file','missing-commitment','invalid-json'):
        yield 'A1-commitment-'+mode+'-refused',lambda mode=mode:commitment_fixture(mode),'REFUSED'

    def commitment_order(fail=False):
        trace=[]
        def commitment():
            trace.append('commitment')
            if fail:raise R.Refusal('fixture commitment mismatch')
        def beacon(*args):
            trace.append('beacon')
            return {'round':1}
        result=main_case(R,'seal',commitment=commitment,beacon_hook=beacon)
        return trace,result
    yield 'A1-commitment-before-beacon',lambda:commitment_order(),(['commitment','beacon'],(0,'COMPLETE',['H1','calibration','hcal'],6,1))
    yield 'A1-commitment-refusal-no-beacon',lambda:commitment_order(True),(['commitment'],(2,'REFUSED',[],0,0))

# UNAPPLIED POST-CENSUS ALTERNATIVE to lazy-root-prelude.fragment.py.
# Keep old553 unchanged; never append both ROOT proposals.
_round5_root_preflight_prior_cases = cases
_round5_root_preflight_prior_run = run
_ROUND5_ROOT_PREFLIGHT_EXPECTED = Path(__file__).resolve().parents[2]


def _round5_root_preflight_case(R):
    # One real declaration shared by ordinary delivery and the quiet preflight.
    return ('driver-root-before-fixture-expectations',
            lambda: getattr(R, 'ROOT', None), _ROUND5_ROOT_PREFLIGHT_EXPECTED)


def cases(R):
    yield _round5_root_preflight_case(R)
    yield from _round5_root_preflight_prior_cases(R)


def run(R, plant=None, quiet=False, prefer=()):
    # The native mutation API is quiet. Check ROOT before old ordered() can
    # scan declarations for a late preferred pin and raise during construction.
    # Nonquiet delivery and the empty-table control use the real old runner.
    if quiet and plant != 'empty':
        name, call, want = _round5_root_preflight_case(R)
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                got = call()
            if plant == name:
                got = 'planted wrong answer'
            # bool is part of this actual assertion evaluation; do not accept
            # an equality object without evaluating its truth value.
            ok = bool(got == want)
        except (Exception, SystemExit):
            # Same caught classes as a frozen ordinary fixture. Deliberately
            # do not turn KeyboardInterrupt/GeneratorExit into a named red.
            return [name]
        if not ok:
            return [name]
    # No prefer rewrite, table-count synthesis, cache creation or old thunk call
    # happened above. The old runner still owns ordinary output and all caches.
    return _round5_root_preflight_prior_run(R, plant=plant, quiet=quiet, prefer=prefer)


# NEW NORMALIZED TOP PROPOSAL; original source retained.
_round5_combined_top_prior_cases = cases

def cases(R):
    yield from _round5_combined_top_prior_cases(R)

    def protocol(rows, requested):
        stdout, stderr = (io.StringIO(), io.StringIO())
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 resolution/arithmetic must precede native arm operations')

        def execute(args, raw):
            R.check_d14({'rows': rows})
            return 77
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'd14-protocol'
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'execute', new=execute))
                stack.enter_context(patch.object(R, 'command', new=forbidden_native))
                stack.enter_context(patch.object(R, 'sealed_set', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'run', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=forbidden_native))
                stack.enter_context(patch.object(R, 'open', new=forbidden_native, create=True))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                try:
                    rc = R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--out', str(out)])
                except Exception:
                    rc = 'UNHANDLED'
            payload = json.loads((out / 'raw.json').read_text()) if (out / 'raw.json').exists() else {}
            text = payload.get('error', '')
            named = isinstance(text, str) and requested in text
            lines = stdout.getvalue().splitlines() + stderr.getvalue().splitlines()
            outcome = any((line.startswith(('OUTCOME ', 'DRY OUTCOME ')) for line in lines))
            return (rc, payload.get('status'), named, (out / 'decision.json').exists(), outcome, not native_calls)

    def valid_without_native(rows):
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 arithmetic must precede native arm operations')
        with patch.object(R, 'command', new=forbidden_native), patch.object(R, 'sealed_set', new=forbidden_native), patch.object(R.subprocess, 'run', new=forbidden_native), patch.object(R.subprocess, 'Popen', new=forbidden_native), patch.object(R, 'open', new=forbidden_native, create=True):
            try:
                result = R.check_d14({'rows': rows})
            except Exception:
                result = 'UNHANDLED'
        return (result, not native_calls)

    def _round5_checked(rows):
        observed, clear = valid_without_native(rows)
        if not clear:
            raise AssertionError('pure D14 helper attempted a native operation')
        return observed

    def _critic_d14_ar1_row(rid, family, mu=100.0, sigma=1.0, burn=200):
        return {'id': rid, 'family': family, 'n': 300, 'checkpoints': [50, 150, 300], 'gen': {'kind': 'ar1', 'mu': mu, 'phi': 0.9, 'sigma': sigma, 'burn': burn, 'seed': 1758}}

    def _critic_d14_flat_rows(copy_first=False):
        base = _critic_d14_ar1_row('f15b_0', 'F15b base for unit-scaled copies, from F9 AR(1), uniform innovations')
        scaled = _critic_d14_ar1_row('f15_f15b_0_x0.001', 'F15 unit-scaled copies', mu=0.1, sigma=0.001)
        scaled.update(base='f15b_0', scale=0.001)
        return [scaled, base] if copy_first else [base, scaled]

    def _critic_d14_multihop_rows(burn=200):
        head = _critic_d14_ar1_row('head-copy', 'F15 unit-scaled copies', burn=burn)
        head.update(base='middle-copy', scale=1000.0)
        middle = _critic_d14_ar1_row('middle-copy', 'F15 unit-scaled copies', mu=0.1, sigma=0.001, burn=burn)
        middle.update(base='terminal-f09', scale=0.001)
        leaf = _critic_d14_ar1_row('terminal-f09', 'F9 AR(1), uniform innovations', burn=burn)
        return [head, middle, leaf]

    def _critic_d14_bad_family_bridge(missing_family=False):
        head, bridge, leaf = _critic_d14_multihop_rows()
        bridge['family'] = 'unknown source family'
        if missing_family:
            del bridge['family']
        return [head, bridge, leaf]

    def _critic_d14_refusal(R, rows, requested):
        return protocol(rows, requested)
    yield ('D14-frozen-flat-link-base-first-valid', lambda: _round5_checked(_critic_d14_flat_rows()), ['f15b_0', 'f15_f15b_0_x0.001'])
    yield ('D14-frozen-flat-link-copy-first-valid', lambda: _round5_checked(_critic_d14_flat_rows(True)), ['f15_f15b_0_x0.001', 'f15b_0'])
    yield ('D14-multihop-F9-valid', lambda: _round5_checked(_critic_d14_multihop_rows()), ['head-copy', 'middle-copy', 'terminal-f09'])
    yield ('D14-multihop-F9-bad-bound-names-head', lambda: _critic_d14_refusal(R, _critic_d14_multihop_rows(174), 'head-copy'), (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-multihop-unknown-family-bridge-refused', lambda: _critic_d14_refusal(R, _critic_d14_bad_family_bridge(), 'head-copy'), (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-multihop-missing-family-bridge-refused', lambda: _critic_d14_refusal(R, _critic_d14_bad_family_bridge(True), 'head-copy'), (2, 'INCOMPLETE', True, False, False, True))

    def malformed_top_base(value):
        rows = _critic_d14_flat_rows(True)[:1]
        rows[0]['base'] = value
        return _critic_d14_refusal(R, rows, 'f15_f15b_0_x0.001')
    yield ('D14-top-copy-unhashable-base-id-refused-by-name', lambda: malformed_top_base([]), (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-top-copy-missing-base-id-refused-by-name', lambda: malformed_top_base('absent-f15b'), (2, 'INCOMPLETE', True, False, False, True))

    def missing_middle_link():
        head, middle, leaf = _critic_d14_multihop_rows()
        middle['base'] = 'absent-f15b'
        return _critic_d14_refusal(R, [head, middle], 'head-copy')
    yield ('D14-multihop-missing-link-names-requested-head', missing_middle_link, (2, 'INCOMPLETE', True, False, False, True))


# NEW NORMALIZED MIXED PROPOSAL; original source retained.
_round5_combined_mixed_prior_cases = cases

def cases(R):
    yield from _round5_combined_mixed_prior_cases(R)

    def protocol(rows, requested):
        stdout, stderr = (io.StringIO(), io.StringIO())
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 resolution/arithmetic must precede native arm operations')

        def execute(args, raw):
            R.check_d14({'rows': rows})
            return 77
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'd14-protocol'
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'execute', new=execute))
                stack.enter_context(patch.object(R, 'command', new=forbidden_native))
                stack.enter_context(patch.object(R, 'sealed_set', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'run', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=forbidden_native))
                stack.enter_context(patch.object(R, 'open', new=forbidden_native, create=True))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                try:
                    rc = R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--out', str(out)])
                except Exception:
                    rc = 'UNHANDLED'
            payload = json.loads((out / 'raw.json').read_text()) if (out / 'raw.json').exists() else {}
            text = payload.get('error', '')
            named = isinstance(text, str) and requested in text
            lines = stdout.getvalue().splitlines() + stderr.getvalue().splitlines()
            outcome = any((line.startswith(('OUTCOME ', 'DRY OUTCOME ')) for line in lines))
            return (rc, payload.get('status'), named, (out / 'decision.json').exists(), outcome, not native_calls)

    def valid_without_native(rows):
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 arithmetic must precede native arm operations')
        with patch.object(R, 'command', new=forbidden_native), patch.object(R, 'sealed_set', new=forbidden_native), patch.object(R.subprocess, 'run', new=forbidden_native), patch.object(R.subprocess, 'Popen', new=forbidden_native), patch.object(R, 'open', new=forbidden_native, create=True):
            try:
                result = R.check_d14({'rows': rows})
            except Exception:
                result = 'UNHANDLED'
        return (result, not native_calls)

    def _round5_checked(rows):
        observed, clear = valid_without_native(rows)
        if not clear:
            raise AssertionError('pure D14 helper attempted a native operation')
        return observed

    def mixed_rows():
        head = {'id': 'mixed-copy', 'family': 'F15 unit-scaled copies', 'base': 'f15b_0', 'scale': 0.001, 'gen': {'kind': 'scaled', 'base': 'f15b_0', 'scale': 0.001}}
        base = {'id': 'f15b_0', 'family': 'F15b base for unit-scaled copies, from F9 AR(1), uniform innovations', 'gen': {'kind': 'ar1', 'mu': 100.0, 'phi': 0.9, 'sigma': 1.0, 'burn': 200, 'seed': 1758}}
        return [head, base]
    yield ('D14-synthetic-top-link-and-wrapper-shared-base-valid', lambda: _round5_checked(mixed_rows()), ['mixed-copy', 'f15b_0'])


# NEW NORMALIZED HISTORY PROPOSAL; original source retained.
_round5_combined_history_prior_cases = cases

def cases(R):
    yield from _round5_combined_history_prior_cases(R)

    def protocol(rows, requested):
        stdout, stderr = (io.StringIO(), io.StringIO())
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 resolution/arithmetic must precede native arm operations')

        def execute(args, raw):
            R.check_d14({'rows': rows})
            return 77
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'd14-protocol'
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'execute', new=execute))
                stack.enter_context(patch.object(R, 'command', new=forbidden_native))
                stack.enter_context(patch.object(R, 'sealed_set', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'run', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=forbidden_native))
                stack.enter_context(patch.object(R, 'open', new=forbidden_native, create=True))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                try:
                    rc = R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--out', str(out)])
                except Exception:
                    rc = 'UNHANDLED'
            payload = json.loads((out / 'raw.json').read_text()) if (out / 'raw.json').exists() else {}
            text = payload.get('error', '')
            named = isinstance(text, str) and requested in text
            lines = stdout.getvalue().splitlines() + stderr.getvalue().splitlines()
            outcome = any((line.startswith(('OUTCOME ', 'DRY OUTCOME ')) for line in lines))
            return (rc, payload.get('status'), named, (out / 'decision.json').exists(), outcome, not native_calls)

    def valid_without_native(rows):
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 arithmetic must precede native arm operations')
        with patch.object(R, 'command', new=forbidden_native), patch.object(R, 'sealed_set', new=forbidden_native), patch.object(R.subprocess, 'run', new=forbidden_native), patch.object(R.subprocess, 'Popen', new=forbidden_native), patch.object(R, 'open', new=forbidden_native, create=True):
            try:
                result = R.check_d14({'rows': rows})
            except Exception:
                result = 'UNHANDLED'
        return (result, not native_calls)

    def _round5_checked(rows):
        observed, clear = valid_without_native(rows)
        if not clear:
            raise AssertionError('pure D14 helper attempted a native operation')
        return observed

    def chain(middle_id, leaf_id):
        root = {'id': 'wrapper-root', 'family': 'F15 unit-scaled copies', 'gen': {'kind': 'scaled', 'base': middle_id}}
        middle = {'id': middle_id, 'family': 'F9 AR(1), uniform innovations', 'gen': {'kind': 'scaled', 'base': leaf_id}}
        leaf = {'id': leaf_id, 'family': 'F9 AR(1), uniform innovations', 'gen': {'kind': 'ar1', 'mu': 100.0, 'phi': 0.9, 'sigma': 1.0, 'burn': 200, 'seed': 1758}}
        return [root, middle, leaf]
    opaque_ids = [('INC', '3d8a14b4'), ('ANCHOR', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'), ('R3STD', '3eed5caf'), ('SCORE', 'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'), ('source-file', str(Path(__file__).resolve().with_name('reveal.py'))), ('CLI-module', '__main__'), ('import-module', 'reveal'), ('native-module', 'reveal_mutant'), ('source-family', 'F15 unit-scaled copies')]

    def collision_matrix(position):
        result = []
        for label, rid in opaque_ids:
            middle_id, leaf_id = (rid, 'wrapper-leaf') if position == 'previous' else ('wrapper-middle', rid)
            result.append((label, _round5_checked(chain(middle_id, leaf_id))))
        return result
    yield ('D14-string-wrapper-opaque-previous-ID-collisions-valid', lambda: collision_matrix('previous'), [(label, ['wrapper-root', rid, 'wrapper-leaf']) for label, rid in opaque_ids])
    yield ('D14-string-wrapper-opaque-next-ID-collisions-valid', lambda: collision_matrix('next'), [(label, ['wrapper-root', 'wrapper-middle', rid]) for label, rid in opaque_ids])
    container_keys = ['R3', 'gen', 'rows', 'kind']

    def key_collision_matrix():
        return [(rid, _round5_checked(chain(rid, 'wrapper-leaf'))) for rid in container_keys]
    yield ('D14-string-wrapper-container-key-collisions-valid', key_collision_matrix, [(rid, ['wrapper-root', rid, 'wrapper-leaf']) for rid in container_keys])

    def base_before_wrapper():
        root, middle, leaf = chain('wrapper-middle', 'wrapper-leaf')
        return _round5_checked([leaf, middle, root])
    yield ('D14-string-wrapper-base-before-copy-valid', base_before_wrapper, ['wrapper-leaf', 'wrapper-middle', 'wrapper-root'])

    def mixed_refusal(bad_base):
        head = {'id': 'mixed-invalid-copy', 'family': 'F15 unit-scaled copies', 'base': 'valid-metadata-source', 'gen': {'kind': 'scaled', 'base': bad_base}}
        base = {'id': 'valid-metadata-source', 'family': 'F15b base for unit-scaled copies, from F9 AR(1), uniform innovations', 'gen': {'kind': 'ar1', 'mu': 100.0, 'phi': 0.9, 'sigma': 1.0, 'burn': 200, 'seed': 1758}}
        return protocol([head, base], 'mixed-invalid-copy')
    yield ('D14-mixed-valid-metadata-missing-wrapper-names-copy', lambda: mixed_refusal('absent-wrapper-base'), (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-mixed-valid-metadata-nondict-wrapper-names-copy', lambda: mixed_refusal(42), (2, 'INCOMPLETE', True, False, False, True))


# NEW OUTPUT-ONLY, UNEXECUTED POST-CENSUS PROPOSAL. Do not apply during census.
# R4 D14 / R5 D14.14: actual main's named INCOMPLETE refusal protocol.
# v3 is an ALTERNATIVE to v1/v2, never an additional overlapping append.
# Original strict/full-message and v1 proposals are preserved historical artifacts.
_critic_d14_protocol_v3_prior_cases = cases


def cases(R):
    yield from _critic_d14_protocol_v3_prior_cases(R)

    def ar1(burn=200):
        return {'kind': 'ar1', 'mu': 100.0, 'phi': 0.9,
                'sigma': 1.0, 'burn': burn, 'seed': 1758}

    def valid_source():
        return {'id': 'f15b_0',
                'family': 'F15b base for unit-scaled copies, from F9 AR(1), uniform innovations',
                'gen': ar1()}

    def protocol(rows, requested):
        # Observe REAL main. Do not reproduce its exception-to-status formula.
        # Literal wants below come from R4/R5, never R.Refusal or a driver result.
        stdout, stderr = io.StringIO(), io.StringIO()
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 resolution/arithmetic must precede native arm operations')

        def execute(args, raw):
            R.check_d14({'rows': rows})
            return 77  # A wrongly accepted invalid row cannot look like refusal.

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'd14-protocol'
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'execute', new=execute))
                stack.enter_context(patch.object(R, 'command', new=forbidden_native))
                stack.enter_context(patch.object(R, 'sealed_set', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'run', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=forbidden_native))
                stack.enter_context(patch.object(R, 'open', new=forbidden_native, create=True))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                try:
                    rc = R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--out', str(out)])
                except Exception:
                    # A KeyError/NameError/TypeError is failure to deliver the
                    # specified protocol, rather than a valid named refusal.
                    rc = 'UNHANDLED'
            payload = json.loads((out / 'raw.json').read_text()) if (out / 'raw.json').exists() else {}
            text = payload.get('error', '')
            named = isinstance(text, str) and requested in text
            lines = stdout.getvalue().splitlines() + stderr.getvalue().splitlines()
            outcome = any(line.startswith(('OUTCOME ', 'DRY OUTCOME ')) for line in lines)
            return (rc, payload.get('status'), named,
                    (out / 'decision.json').exists(), outcome, not native_calls)

    def valid_without_native(rows):
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 arithmetic must precede native arm operations')

        with patch.object(R, 'command', new=forbidden_native), \
                patch.object(R, 'sealed_set', new=forbidden_native), \
                patch.object(R.subprocess, 'run', new=forbidden_native), \
                patch.object(R.subprocess, 'Popen', new=forbidden_native), \
                patch.object(R, 'open', new=forbidden_native, create=True):
            try:
                result = R.check_d14({'rows': rows})
            except Exception:
                result = 'UNHANDLED'
        return result, not native_calls

    def initial_nondict(mixed=False):
        head = {'id': 'malformed-initial-gen',
                'family': 'F15 unit-scaled copies', 'gen': 42}
        if mixed:
            head.update({'base': 'f15b_0', 'scale': 0.001})
        return [head, valid_source()] if mixed else [head]

    def identity_metadata_source():
        return {'id': 'identity-metadata-source',
                'family': 'F15b base for unit-scaled copies, from F9 AR(1), uniform innovations',
                'gen': ar1()}

    def identity_head(generator):
        return {'id': 'identity-copy', 'family': 'F15 unit-scaled copies',
                'base': 'identity-metadata-source', 'scale': 0.001, 'gen': generator}

    def mixed_generator_cycle():
        # Builder-origin finite JSON witness, reviewed after independent freeze.
        # String back-reference revisits an inline generator before an ID repeats.
        generator = {'kind': 'scaled',
                     'base': {'kind': 'scaled', 'base': 'identity-copy'}}
        return [identity_head(generator), identity_metadata_source()]

    def base_identity_is_not_current_generator_identity():
        # Builder-origin positive witness: second reference returns root, then
        # its gen field unwraps to terminal AR1. No Python object cycle exists.
        root = {'kind': 'scaled', 'base': 'identity-bridge', 'gen': ar1()}
        bridge = {'id': 'identity-bridge',
                  'family': 'F15b base for unit-scaled copies, from F9 AR(1), uniform innovations',
                  'gen': {'kind': 'scaled', 'base': 'identity-copy'}}
        return valid_without_native([identity_head(root), bridge, identity_metadata_source()])

    def gen_only_container():
        # A generator wrapper container can expose gen without pretending to
        # be a full corpus row. R5 says resolve through the wrapper.
        return [{'id': 'gen-only-copy', 'family': 'F15 unit-scaled copies',
                 'gen': {'kind': 'scaled', 'scale': 0.001, 'base': {'gen': ar1()}}}]

    def ordinary_base_unknown_copy():
        return [{'id': 'unknown-kind-copy', 'family': 'F15 unit-scaled copies',
                 'base': 'terminal-f01', 'scale': 1000.0, 'gen': {'kind': 'unknown-kind'}},
                {'id': 'terminal-f01', 'family': 'F1 geometric decay to a nonzero limit',
                 'gen': {'kind': 'affine', 'x0': 110.0, 'a': 0.5, 'b': 50.0}}]

    def arithmetic_purity():
        good = [{'id': 'pure-f9', 'family': 'F9 AR(1), uniform innovations', 'gen': ar1(200)}]
        bad = [{'id': 'bad-burn-f9', 'family': 'F9 AR(1), uniform innovations', 'gen': ar1(174)}]
        return valid_without_native(good), protocol(bad, 'bad-burn-f9')

    # No raw.error prefix/suffix API, R.Refusal catch or driver-computed want.
    yield ('D14-initial-nondict-generator-protocol',
           lambda: protocol(initial_nondict(), 'malformed-initial-gen'),
           (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-valid-metadata-nondict-initial-names-copy-protocol',
           lambda: protocol(initial_nondict(True), 'malformed-initial-gen'),
           (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-mixed-generator-object-cycle-protocol',
           lambda: protocol(mixed_generator_cycle(), 'identity-copy'),
           (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-base-object-mark-not-current-generator-valid',
           base_identity_is_not_current_generator_identity,
           (['identity-copy', 'identity-bridge', 'identity-metadata-source'], True))
    yield ('D14-scaled-gen-only-container-valid',
           lambda: valid_without_native(gen_only_container()),
           (['gen-only-copy'], True))
    yield ('D14-linked-nonF9-source-unknown-copy-kind-protocol',
           lambda: protocol(ordinary_base_unknown_copy(), 'unknown-kind-copy'),
           (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-exact-bound-before-native-purity', arithmetic_purity,
           ((['pure-f9'], True), (2, 'INCOMPLETE', True, False, False, True)))


# UNAPPLIED F9 follow-up proposal.
_round5_combined_f9_followup_prior_cases = cases

def cases(R):
    yield from _round5_combined_f9_followup_prior_cases(R)

    def protocol(rows, requested):
        stdout, stderr = (io.StringIO(), io.StringIO())
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 resolution/arithmetic must precede native arm operations')

        def execute(args, raw):
            R.check_d14({'rows': rows})
            return 77
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'd14-protocol'
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'execute', new=execute))
                stack.enter_context(patch.object(R, 'command', new=forbidden_native))
                stack.enter_context(patch.object(R, 'sealed_set', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'run', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=forbidden_native))
                stack.enter_context(patch.object(R, 'open', new=forbidden_native, create=True))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                try:
                    rc = R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--out', str(out)])
                except Exception:
                    rc = 'UNHANDLED'
            payload = json.loads((out / 'raw.json').read_text()) if (out / 'raw.json').exists() else {}
            text = payload.get('error', '')
            named = isinstance(text, str) and requested in text
            lines = stdout.getvalue().splitlines() + stderr.getvalue().splitlines()
            outcome = any((line.startswith(('OUTCOME ', 'DRY OUTCOME ')) for line in lines))
            return (rc, payload.get('status'), named, (out / 'decision.json').exists(), outcome, not native_calls)

    def valid_without_native(rows):
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 arithmetic must precede native arm operations')
        with patch.object(R, 'command', new=forbidden_native), patch.object(R, 'sealed_set', new=forbidden_native), patch.object(R.subprocess, 'run', new=forbidden_native), patch.object(R.subprocess, 'Popen', new=forbidden_native), patch.object(R, 'open', new=forbidden_native, create=True):
            try:
                result = R.check_d14({'rows': rows})
            except Exception:
                result = 'UNHANDLED'
        return (result, not native_calls)

    def nonar1_copy():
        return [{'id': 'nonar1-f9-copy', 'family': 'F15 unit-scaled copies', 'base': 'valid-f9-source', 'scale': 0.001, 'gen': {'kind': 'affine', 'x0': 0.11, 'a': 0.5, 'b': 0.05}}, {'id': 'valid-f9-source', 'family': 'F15b base for unit-scaled copies, from F9 AR(1), uniform innovations', 'gen': {'kind': 'ar1', 'mu': 100.0, 'phi': 0.9, 'sigma': 1.0, 'burn': 200, 'seed': 1758}}]

    def own_bad_bound():
        return [{'id': 'own-bad-bound-copy', 'family': 'F15 unit-scaled copies', 'base': 'valid-bound-source', 'scale': 0.001, 'gen': {'kind': 'ar1', 'mu': 0.1, 'phi': 0.9, 'sigma': 0.001, 'burn': 174, 'seed': 1758}}, {'id': 'valid-bound-source', 'family': 'F15b base for unit-scaled copies, from F9 AR(1), uniform innovations', 'gen': {'kind': 'ar1', 'mu': 100.0, 'phi': 0.9, 'sigma': 1.0, 'burn': 200, 'seed': 1758}}]
    yield ('D14-valid-F9-metadata-nonAR1-copy-protocol', lambda: protocol(nonar1_copy(), 'nonar1-f9-copy'), (2, 'INCOMPLETE', True, False, False, True))
    yield ('D14-valid-metadata-own-bad-bound-names-copy-protocol', lambda: protocol(own_bad_bound(), 'own-bad-bound-copy'), (2, 'INCOMPLETE', True, False, False, True))


# UNAPPLIED OLD-PIN SAFETY WRAPPER; no old thunk/want/body is edited.
_round5_combined_safety_prior_cases = cases


def _round5_normalized_dump_destination(value):
    # Reject custom fspath/str protocols BEFORE coercion or product constructor.
    # Exact built-in str and the fixture's native concrete Path are sufficient
    # for the source-reviewed orchestration-calibration private destinations.
    import os as fixture_os
    if type(value) is str:
        raw = value
    elif type(value) is type(Path()):
        raw = str(value)
    else:
        raise AssertionError('dump destination is not a plain str or native Path')
    return fixture_os.path.normcase(fixture_os.path.abspath(raw))


def _round5_with_dump_destination_guard(R, call):
    actual_dump = R.dump

    def guarded_dump(destination, obj):
        # This caller parameter is trusted only for the reviewed old fixture's
        # internal dump-path mutants. This is not arbitrary caller-path custody.
        trusted = _round5_normalized_dump_destination(destination)
        actual_path = R.Path
        rejected = []

        def checked_path(candidate, *parts, **options):
            if parts or options:
                rejected.append(True)
                raise AssertionError('dump Path constructor gained extra arguments')
            try:
                observed = _round5_normalized_dump_destination(candidate)
            except (Exception, SystemExit):
                rejected.append(True)
                raise
            if observed != trusted:
                rejected.append(True)
                raise AssertionError('dump changed its trusted destination')
            # Execute the actual captured product constructor only after the
            # safe-type/normalized-destination comparison. Return real objects.
            return actual_path(candidate)

        with patch.object(R, 'Path', new=checked_path):
            result = actual_dump(destination, obj)
        if rejected:
            raise AssertionError('dump swallowed a forbidden destination attempt')
        return result

    with patch.object(R, 'dump', new=guarded_dump):
        return call()


def _round5_with_pure_D14_seams(R, call):
    attempted = []

    def forbidden(*args, **kwargs):
        attempted.append(True)
        raise AssertionError('pure D14 helper attempted a command or beacon')

    with patch.object(R, 'command', new=forbidden), patch.object(R, 'sealed_set', new=forbidden), patch.object(R, 'open', new=forbidden, create=True):
        observed = call()
    if attempted:
        raise AssertionError('pure D14 helper swallowed a native attempt')
    return observed


def cases(R):
    pure = ('D14-wrapper-top-cycle-unresolved-refused',
            'D14-F9 AR1-(0.9, 200)',
            'D14-wrapper-dict-valid',
            'D14-wrapper-malformed-unresolved-refused')
    for name, call, want in _round5_combined_safety_prior_cases(R):
        if name == 'orchestration-calibration':
            yield name, lambda _call=call: _round5_with_dump_destination_guard(R, _call), want
        elif name in pure:
            yield name, lambda _call=call: _round5_with_pure_D14_seams(R, _call), want
        else:
            yield name, call, want


# SOURCE-ONLY global-open primitive refinement; no old body/name/want changed.
# Existing-FD open is forbidden only inside these explicit pure D14 thunks.
_round5_D14_global_open_prior_cases = cases


def _round5_with_D14_global_open(R, call):
    attempted = []

    def forbidden_open(*args, **kwargs):
        attempted.append(True)
        raise AssertionError('pure D14 helper attempted global open')

    with patch.object(R, 'open', new=forbidden_open, create=True):
        observed = call()
    if attempted:
        raise AssertionError('pure D14 helper swallowed a global-open attempt')
    return observed


def cases(R):
    pure_names = ('D14-F9 AR1-(0.9, 200)', 'D14-F9 AR1-(-0.9, 200)', 'D14-F9 AR1-(0.92, 200)', 'D14-F9 AR1-(0.9, 100)', 'D14-F9 AR1-(0.5, 26)', 'D14-F9 AR1-(0.5, 27)', 'D14-F9 AR1-(0, 200)', 'D14-F9 AR1-(0, 0)', 'D14-F9 AR1-(0.9, -1)', 'D14-F9 AR1-(0.9, 200.0)', 'D14-F15 unit-scaled copies-(0.9, 200)', 'D14-F15 unit-scaled copies-(-0.9, 200)', 'D14-F15 unit-scaled copies-(0.92, 200)', 'D14-F15 unit-scaled copies-(0.9, 100)', 'D14-F15 unit-scaled copies-(0.5, 26)', 'D14-F15 unit-scaled copies-(0.5, 27)', 'D14-F15 unit-scaled copies-(0, 200)', 'D14-F15 unit-scaled copies-(0, 0)', 'D14-F15 unit-scaled copies-(0.9, -1)', 'D14-F15 unit-scaled copies-(0.9, 200.0)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0.9, 200)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(-0.9, 200)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0.92, 200)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0.9, 100)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0.5, 26)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0.5, 27)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0, 200)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0, 0)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0.9, -1)', 'D14-F15b base for unit-scaled copies, from F9 AR1-(0.9, 200.0)', 'D14-non-AR1', 'D14-resolution-inside', 'D14-resolution-outside', 'D14-before-certify-or-arms', 'D14-exact-owned-row-reason', 'D14-negative-one-burn-huge-phi', 'D14-decimal-float-inside', 'D14-decimal-float-outside', 'D14-malformed-phi-refused-by-main', 'D14-wrapper-dict-valid', 'D14-wrapper-dict-bad-bound-names-row', 'D14-wrapper-nested-valid', 'D14-wrapper-nested-bad-bound-names-row', 'D14-wrapper-row-object-valid', 'D14-wrapper-row-object-bad-bound-names-row', 'D14-wrapper-string-valid', 'D14-wrapper-string-bad-bound-names-row', 'D14-wrapper-missing-string-unresolved-refused', 'D14-wrapper-malformed-unresolved-refused', 'D14-wrapper-gen-cycle-unresolved-refused', 'D14-wrapper-top-cycle-unresolved-refused', 'D14-wrapper-F15b-unknown-unresolved-refused', 'D14-wrapper-unknown-kind-unresolved-refused', "D14-top-copy-unresolved-terminal-''", "D14-top-copy-unresolved-terminal-'unknown'", "D14-top-copy-unresolved-terminal-'F19 unknown'", "D14-top-copy-unresolved-terminal-'F15 unit-scaled copies'", "D14-top-copy-unresolved-terminal-'F15b base from F19 unknown'")
    for name, call, want in _round5_D14_global_open_prior_cases(R):
        if name in pure_names:
            yield name, lambda _call=call: _round5_with_D14_global_open(R, _call), want
        else:
            yield name, call, want


_round5_terminal_refinement_prior_cases = cases

def cases(R):
    yield from _round5_terminal_refinement_prior_cases(R)

    def protocol(rows, requested):
        stdout, stderr = (io.StringIO(), io.StringIO())
        native_calls = []

        def forbidden_native(*args, **kwargs):
            native_calls.append(True)
            raise AssertionError('D14 resolution/arithmetic must precede native arm operations')

        def execute(args, raw):
            R.check_d14({'rows': rows})
            return 77
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'd14-protocol'
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'execute', new=execute))
                stack.enter_context(patch.object(R, 'command', new=forbidden_native))
                stack.enter_context(patch.object(R, 'sealed_set', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'run', new=forbidden_native))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=forbidden_native))
                stack.enter_context(patch.object(R, 'open', new=forbidden_native, create=True))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                try:
                    rc = R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--out', str(out)])
                except Exception:
                    rc = 'UNHANDLED'
            payload = json.loads((out / 'raw.json').read_text()) if (out / 'raw.json').exists() else {}
            text = payload.get('error', '')
            named = isinstance(text, str) and requested in text
            lines = stdout.getvalue().splitlines() + stderr.getvalue().splitlines()
            outcome = any((line.startswith(('OUTCOME ', 'DRY OUTCOME ')) for line in lines))
            return (rc, payload.get('status'), named, (out / 'decision.json').exists(), outcome, not native_calls)
    _terminal_literals = ('', '\n', ' disagrees with evidence ', ' exit ', ' recipe failed; see build-', ' recipe stamp mismatch', '#', ', ', '-', '--arm', '--calibration', '--const-false', '--corpus', '--declared', '--dry', '--floor', '--no-checkout', '--no-tags', '--resamples', '--seed', '--selftest', '--shared', '--subject', '--tol-converged', '--verify', '--write', '--write-manifest', '-I', '-seal.log', '.log', '/usr/bin:/bin', '1 ', '1 standard parity', '12345', '124', '2 vs INC', '2 vs R3-STD', '2345', '3 safety', '3d8a14b4', '3eed5caf', '4 ', '4 trivial floor', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697', '5 unit invariance', '6 ', '6 existing gates', ': ', ': D14 unresolved base', ': D14 |phi|^(2*burn) must be < 2^-53', ': sha256 ', '; STD_p/H2=', '; derived files ', '; silent-wrong=', '; step 1 is repeated', '=', '@', 'ANCHOR', 'C', 'C0', 'C1', 'CF', 'CF=', 'COMPLETE', 'D2', 'DRY ', 'F15 ', 'F15b ', 'FAIL', 'H1', 'HOME', 'INC', 'INCOMPLETE', 'INCOMPLETE:', 'INCOMPLETE: ', 'LANG', 'NOT APPLICABLE (stand-in)', 'NOT EVALUATED', 'OUTCOME ', 'PASS', 'PATH', 'PERSIST', 'R3', 'R3-STD', 'REF', 'REFUSED', 'REPORTED', 'STD', "STD'", "STD''", 'STD_p_on_H2', 'T001', 'T001=0.01', 'VOID', 'W4', 'XDG_CACHE_HOME', '^F(\\d+) ', '^RED  floor-each ', '^{commit}', '__main__', 'a', 'absent', 'arms', 'b', 'b_undefined', 'base', 'bash', 'beacon', 'binary', 'binary_sha256', 'build-', 'build/observer-reveal/cache', 'build_anchor.sh', 'build_arm.sh', 'build_w4.sh', 'burn', 'c1', 'c2', 'calibration', 'capabilities', 'capability_check', 'certify.py', 'checkpoints', 'clone', 'code', 'confusion', 'control_c1_rule6', 'controls', 'converged', 'corpus.json', 'decisions', 'declaration_sha256', 'declarations', 'derive.py', 'diffs', 'disagreements', 'diverging', 'driver', 'dry', 'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4', 'equilibrium', 'error', 'failed controls: ', 'family', 'fetch', 'findings', 'floor-', 'floor-exit', 'floor_exit', 'format', 'from F(\\d+) ', 'gen', 'git', 'hcal', 'id', 'improving', 'instrument', 'judge.py', 'judge_rc', 'kind', 'labels', 'manifest', 'manifest ', 'manifest.json', 'manifests', 'manual_review', 'manual_review.json', 'manual_review.py', 'missing declaration file', 'n', 'no-family-15', 'origin', 'oscillating', 'phi', 'plants.log', 'plants.py', 'plants: 1 examined, 1 red ', 'points', 'population_tables', 'populations', 'predicates', 'preflight', 'primary', 'r3-reveal-commitment/1', 'r3-reveal/1', 'randomness', 'read', 'readings', 'reasons', 'recipe_id', 'recorded status ', 'repository', 'resamples', 'rev-parse', 'reveal', 'reveal.py', 'reveal_fixtures.json', 'reveal_selftest', 'reveal_selftest.py', 'round', 'rows', 'rule6', 'rules', 'score_sha256', 'seal.py', 'seed', 'sha256', 'ship', 'silent_wrong', 'source_sha', 'stable', 'stamps', 'status', 'store_true', 'subjects', 'tiers', 'tools', 'tools/observer_oracle/floor.json', 'tools/observer_oracle/score.py', 'undefined', 'undefined-BA:diverging,equilibrium', 'verdict', 'verified_sources.json')
    _eligible_specs = {'pieces': {'family': 'F13 settle, kick, resettle', 'base_generator': {'kind': 'pieces', 'pieces': [{'x0': 100.0, 'a': 0.5, 'b': 25.0, 'steps': 30}, {'x0': 100.0, 'a': 0.5, 'b': 25.0}]}, 'copy_generator': {'kind': 'pieces', 'pieces': [{'x0': 0.1, 'a': 0.5, 'b': 0.025, 'steps': 30}, {'x0': 0.1, 'a': 0.5, 'b': 0.025}]}, 'scale': 0.001, 'n': 51, 'checkpoints': [41, 42, 51]}, 'cycle': {'family': 'F7 period-k cycles', 'base_generator': {'kind': 'cycle', 'values': [40.0, 50.0, 60.0]}, 'copy_generator': {'kind': 'cycle', 'values': [0.04, 0.05, 0.06]}, 'scale': 0.001, 'n': 38, 'checkpoints': [13, 19, 38]}, 'noise': {'family': 'F8 iid uniform noise', 'base_generator': {'kind': 'noise', 'center': 50.0, 'amp': 0.05, 'seed': 1758}, 'copy_generator': {'kind': 'noise', 'center': 0.05, 'amp': 5e-05, 'seed': 1758}, 'scale': 0.001, 'n': 300, 'checkpoints': [50, 150, 300]}, 'uwalk': {'family': 'F10 random walk, uniform steps', 'base_generator': {'kind': 'uwalk', 'x0': 50.0, 'step': 0.1, 'seed': 1758}, 'copy_generator': {'kind': 'uwalk', 'x0': 0.05, 'step': 0.0001, 'seed': 1758}, 'scale': 0.001, 'n': 300, 'checkpoints': [50, 150, 300]}, 'ar1': {'family': 'F9 AR(1), uniform innovations', 'base_generator': {'kind': 'ar1', 'mu': 50.0, 'phi': 0.5, 'sigma': 0.1, 'burn': 200, 'seed': 1758}, 'copy_generator': {'kind': 'ar1', 'mu': 0.05, 'phi': 0.5, 'sigma': 0.0001, 'burn': 200, 'seed': 1758}, 'scale': 0.001, 'n': 300, 'checkpoints': [50, 150, 300]}}

    def positive_accepted_without_native(rows):
        attempted = []

        def forbidden(*args, **kwargs):
            attempted.append(True)
            raise AssertionError('D14 acceptance must precede native operations')
        with patch.object(R, 'command', new=forbidden), patch.object(R, 'sealed_set', new=forbidden), patch.object(R.subprocess, 'run', new=forbidden), patch.object(R.subprocess, 'Popen', new=forbidden), patch.object(R, 'open', new=forbidden, create=True):
            try:
                R.check_d14({'rows': rows})
            except Exception:
                accepted = False
            else:
                accepted = True
        return (accepted, not attempted)

    def unsupported_rows(value, index, mode):
        requested = 'unsupported-' + mode + '-' + str(index)
        family = 'F15b base for unit-scaled copies, from F13 settle, kick, resettle'
        if mode == 'copy':
            return ([{'id': requested, 'family': 'F15 unit-scaled copies', 'base': 'literal-pieces-source', 'scale': 0.001, 'gen': {'kind': value}}, {'id': 'literal-pieces-source', 'family': family, 'gen': copy.deepcopy(_eligible_specs['pieces']['base_generator'])}], requested)
        if mode == 'base':
            return ([{'id': requested, 'family': family, 'gen': {'kind': value}}], requested)
        raise AssertionError('unknown fixed fixture mode')

    def unsupported_matrix():
        observed_calls = 0
        violations = []
        for index, value in enumerate(_terminal_literals):
            for mode in ('copy', 'base'):
                rows, requested = unsupported_rows(value, index, mode)
                observed = protocol(rows, requested)
                observed_calls += 1
                if observed != (2, 'INCOMPLETE', True, False, False, True):
                    violations.append((mode, index))
                    return (observed_calls, violations)
        return (observed_calls, violations)

    def eligible_rows(kind):
        spec = _eligible_specs[kind]
        base_id = 'eligible-base-' + kind
        return [{'id': 'eligible-copy-' + kind, 'family': 'F15 unit-scaled copies', 'base': base_id, 'scale': spec['scale'], 'n': spec['n'], 'checkpoints': list(spec['checkpoints']), 'gen': copy.deepcopy(spec['copy_generator'])}, {'id': base_id, 'family': 'F15b base for unit-scaled copies, from ' + spec['family'], 'n': spec['n'], 'checkpoints': list(spec['checkpoints']), 'gen': copy.deepcopy(spec['base_generator'])}]
    yield ('D14-unsupported-terminal-literals-named-protocol', unsupported_matrix, (446, []))
    yield ('D14-eligible-pieces-copy-accepted-no-native', lambda: positive_accepted_without_native(eligible_rows('pieces')), (True, True))
    yield ('D14-eligible-cycle-copy-accepted-no-native', lambda: positive_accepted_without_native(eligible_rows('cycle')), (True, True))
    yield ('D14-eligible-noise-copy-accepted-no-native', lambda: positive_accepted_without_native(eligible_rows('noise')), (True, True))
    yield ('D14-eligible-uwalk-copy-accepted-no-native', lambda: positive_accepted_without_native(eligible_rows('uwalk')), (True, True))
    yield ('D14-eligible-ar1-copy-accepted-no-native', lambda: positive_accepted_without_native(eligible_rows('ar1')), (True, True))

# SOURCE-ONLY v2 proposal. Preserve v1. Apply only after base custody seal.
# FX85-PURITY-1: counted global open shadow precedes existing-FD side effects.
# R30R-4 Dry A, R30R-5 F1/F2: recorded declarations cannot replace their facts.
_round5_prefix85001_evidence_prior_cases = cases


def cases(R):
    yield from _round5_prefix85001_evidence_prior_cases(R)

    def diagnostic_fact(predicate, field):
        raw = diagnostic_fixture()
        population = raw['populations']['hcal']
        if field == 'point':
            next(row for row in population['points']
                 if row[0] == 'CF' and row[1] == predicate)[2] = '3/5'
        elif field == 'verdict':
            population['decisions']['CF'][predicate] = registered_verdict(predicate, 'CF')
        elif field == 'defined-undefined-predicate':
            next(row for row in population['points']
                 if row[0] == 'CF' and row[1] == predicate)[2] = '1/2'
        else:
            raise AssertionError(field)
        # Deliberately retain the registered recorded controls/reasons. Recomputing
        # them through controls_ok would mask the independent consistency gate.
        return raw

    def diagnostic_cli(raw):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'diagnostic.json'
            source.write_text(json.dumps(raw))
            stdout, stderr, native = io.StringIO(), io.StringIO(), []

            def no_native(*args, **kwargs):
                native.append(1)
                raise AssertionError('diagnostic attempted a native side effect')

            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'command', new=no_native))
                stack.enter_context(patch.object(R, 'sealed_set', new=no_native))
                stack.enter_context(patch.object(R.subprocess, 'run', new=no_native))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=no_native))
                stack.enter_context(patch.object(R, 'open', new=no_native, create=True))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                rc = R.main(['--check-dry-a', str(source)])
            return rc, stdout.getvalue(), stderr.getvalue(), len(native)

    yield ('Dry-A-independent-facts-green-control',
           lambda: diagnostic_cli(diagnostic_fixture()),
           (0, 'Dry A diagnostic accepted\n', '', 0))
    for predicate in ('converged', 'stable', 'improving', 'oscillating'):
        for field in ('point', 'verdict'):
            yield ('Dry-A-independent-' + field + '-' + predicate,
                   lambda predicate=predicate, field=field:
                       diagnostic_cli(diagnostic_fact(predicate, field)),
                   (1, 'Dry A diagnostic REJECTED\n', '', 0))
    for predicate in ('diverging', 'equilibrium'):
        yield ('Dry-A-independent-undefined-set-' + predicate,
               lambda predicate=predicate:
                   diagnostic_cli(diagnostic_fact(predicate, 'defined-undefined-predicate')),
               (1, 'Dry A diagnostic REJECTED\n', '', 0))

    def failed_control_with_unavailable_rule(control):
        decisions = fixture_decisions()
        decisions['R3']['stable'] = registered_verdict(
            'stable', 'R3', missing=('5 unit invariance',))
        controls = {'a': True, 'b': True, 'c1': True, 'c2': True}
        controls[control] = False
        return R.status_for(0, decisions, controls)

    for control in ('a', 'b', 'c1', 'c2'):
        yield ('failed-control-before-unavailable-rule-' + control,
               lambda control=control: failed_control_with_unavailable_rule(control),
               'VOID')

    def extraction_cli(raw):
        # Exercise the actual production __main__ try/except, with the mutant's
        # main/extract/status_for still installed. The enumeration excludes this
        # unchanged module entry guard. Do not duplicate its exception formula.
        import ast
        tree = ast.parse(Path(R.__file__).read_bytes())
        guards = [node for node in tree.body
                  if isinstance(node, ast.If)
                  and ast.dump(node.test, include_attributes=False) ==
                  ast.dump(ast.parse("__name__ == '__main__'", mode='eval').body,
                           include_attributes=False)]
        if len(guards) != 1:
            raise AssertionError('production CLI entry guard missing or ambiguous')
        entry = compile(ast.fix_missing_locations(ast.Module(
            body=guards[0].body, type_ignores=[])), R.__file__, 'exec')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'raw.json'
            source.write_text(json.dumps(raw))
            out = root / 'extracted'
            stdout, stderr, native = io.StringIO(), io.StringIO(), []

            def no_native(*args, **kwargs):
                native.append(1)
                raise AssertionError('extraction attempted a native side effect')

            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'open', new=no_native, create=True))
                stack.enter_context(patch.object(R.sys, 'argv',
                    [R.__file__, '--extract', str(source), '--out', str(out)]))
                stack.enter_context(patch.object(R, 'command', new=no_native))
                stack.enter_context(patch.object(R, 'sealed_set', new=no_native))
                stack.enter_context(patch.object(R.subprocess, 'run', new=no_native))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=no_native))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                try:
                    exec(entry, R.__dict__)
                except SystemExit as stopped:
                    rc = stopped.code
                else:
                    raise AssertionError('production CLI entry guard did not exit')
            return (rc, (out / 'decision.json').exists(),
                    any(line.startswith(('OUTCOME ', 'DRY OUTCOME '))
                        for line in stdout.getvalue().splitlines()),
                    stderr.getvalue().startswith('REFUSED:'), len(native))

    def malformed_controls(control):
        raw = complete_raw()
        if control == 'scalar':
            raw['controls'] = 2
            raw['status'] = 'INCOMPLETE'
        else:
            raw['controls'][control] = 1
        return raw

    yield ('extraction-production-entry-green-control',
           lambda: extraction_cli(complete_raw()), (0, True, True, False, 0))
    for control in ('scalar', 'a', 'b', 'c1', 'c2'):
        yield ('extraction-production-entry-malformed-control-' + control,
               lambda control=control: extraction_cli(malformed_controls(control)),
               (2, False, False, True, 0))

# SOURCE-ONLY v2 public extraction evidence proposal. Preserve v1; BASE seal first.
# Actual production guard/main/extract/status_for/write_outputs; literal wants.
# This new suffix follows ROOT21v2 exactly once. No old553 body is edited.
import ast as _r30x_ast
import struct as _r30x_struct

_r30x_data = json.loads('{"cases":[{"covered_ids":[90286,90288,90291,90293,90294,90308,90309,90312,90317,90318,90326,90332,90333],"literal_raw_sha256":"ceaa2a62732cee355c2fc9f0d4e81a1fca57822d0363a5e6fb5eec7a15476a1a","mode":"REFUSED","name":"Extract-evidence-01-omitted-subject-roster","patches":[],"template":"OMITTED_SUBJECT_ROSTER"},{"covered_ids":[90706,90727,90738],"literal_raw_sha256":"21bf846ec1ebac521430dff8361626bf38a1e9acc5955200367e5f36474c1f72","mode":"REFUSED","name":"Extract-evidence-02-incomplete-one-ne-raw","patches":[{"operation":"remove-last-rule","path":"/populations/H1/decisions/R3-STD/stable/rules"}],"template":"INCOMPLETE_ONE_NE_RAW"},{"covered_ids":[90958,90959,90970],"literal_raw_sha256":"656ac6e99e3e74263d7644d8a86354cb1eceee8a85b850bd0059c00e89812866","mode":"REFUSED","name":"Extract-evidence-03-incomplete-one-ne-raw","patches":[{"operation":"remove-last-rule","path":"/populations/H1/decisions/CF/stable/rules"}],"template":"INCOMPLETE_ONE_NE_RAW"},{"covered_ids":[91170,91191,91192],"literal_raw_sha256":"23e4575321b0f42a3b9a676d996ab7a81d804ca159b971e9148511c2af4dc3a9","mode":"REFUSED","name":"Extract-evidence-04-incomplete-one-ne-raw","patches":[{"operation":"remove-last-rule","path":"/populations/H1/decisions/W4/stable/rules"}],"template":"INCOMPLETE_ONE_NE_RAW"},{"covered_ids":[91748,91750,91753,91755,91756,91770,91771,91774,91779,91780,91795],"literal_raw_sha256":"841f98a59660504ef095ca7e43d6cd7abc88ae79c992934b10fdc29a0c0282dc","mode":"REFUSED","name":"Extract-evidence-05-omitted-pred-roster","patches":[],"template":"OMITTED_PRED_ROSTER"},{"covered_ids":[92490,93028,93031],"literal_raw_sha256":"26ea5e8e1001deed56d822715c916b8d3923219f4206701f7ae71e178a48674f","mode":"REFUSED","name":"Extract-evidence-06-complete-raw-base","patches":[{"path":"/populations/H1/decisions/R3/converged/rules/0/1","value":"UNREGISTERED-STATE"}],"template":"COMPLETE_RAW_BASE"},{"covered_ids":[93029],"literal_raw_sha256":"05918756798e410ceb1716d9bdfa6d4bbdf448f006b991add14d484ca1158793","mode":"REFUSED","name":"Extract-evidence-07-complete-raw-base","patches":[{"from":"/populations/H1","operation":"add-secondary-population-copy","path":"/populations/calibration"},{"index":2,"operation":"remove-field-index","path":"/populations/calibration/decisions/R3/converged/rules/0"}],"template":"COMPLETE_RAW_BASE"},{"covered_ids":[93731,93732,93733,93734,93735,93736,93737,93738,93739,93740,93741,93742,93743,93744,93745,93746,93747,93748,93749,93750,93751,93752,93753,93754,93755,93756,93757,93758,93759,93760,93761,93762,93763,93764,93765,93766,93767,93768,93769,93770,93771,93772,93773,93774,93775,93776,93777,93778,93779,93780,93781,93782,93783,93784,93785,93786,93787,93788,93789,93790,93791,93792,93793,93794,93795,93796,93797,93798,93799,93800,93801,93802,93803,93804,93805,93806,93807,93808,93809,93810,93811,93812,93813,93814,93815,93816,93817,93818,93819,93820,93821,93822,93823,93824,93825,93826,93827,93828,93829,93830,93831,93832,93833,93834,93835,93836,93837,93838,93839,93840,93841,93842,93843,93844,93845,93846,93847,93848,93849,93850,93851,93852,93853,93854,93855,93856,93857,93858,93859,93860,93861,93862,93863,93864,93865,93866,93867,93868,93869,93870,93871,93872,93873,93874,93875,93876,93877,93878,93879,93880,93881,93882,93883,93884,93885,93886,93887,93888,93889,93890,93891,93892,93893,93894,93895,93896,93897,93898,93899,93900,93901,93902,93903,93904,93905,93906,93907,93908,93909,93910,93911,93912,93913,93914,93915,93916,93917,93918,93919,93920,93921,93922,93923,93924,93925,93926,93927,93928,93929,93930,93931,93932,93933,93934,93935,93936,93937,93938,93939,93940,93941,93942,93943,93944,93945,93946,93947,93948,93949,93950,93951,93952,93953,93954,93955,93956,93957,93958,93959,93960,93961,93962,95270,95271,95272,95273,95274,95275,95276,95277,95278,95279,95280,95281,95282,95283,95284,95285,95286,95287,95288,95289,95290,95291,95292,95293,95294,95295,95296,95297,95298,95299,95300,95301,95302,95303,95304,95305,95306,95307,95308,95309,95310,95311,95312,95313,95314,95315,95316,95317,95318,95319,95320,95321,95322,95323,95324,95325,95326,95327,95328,95329,95330,95331,95332,95333,95334,95335,95336,95337,95338,95339,95340,95341,95342,95343,95344,95345,95346,95347,95348,95349,95350,95351,95352,95353,95354,95355,95356,95357,95358,95359,95360,95361,95362,95363,95364,95365,95366,95367,95368,95369,95370,95371,95372,95373,95374,95375,95376,95377,95378,95379,95380,95381,95382,95383,95384,95385,95386,95387,95388,95389,95390,95391,95392,95393,95394,95395,95396,95397,95398,95399,95400,95401,95402,95403,95404,95405,95406,95407,95408,95409,95410,95411,95412,95413,95414,95415,95416,95417,95418,95419,95420,95421,95422,95423,95424,95425,95426,95427,95428,95429,95430,95431,95432,95433,95434,95435,95436,95437,95438,95439,95440,95441,95442,95443,95444,95445,95446,95447,95448,95449,95450,95451,95452,95453,95454,95455,95456,95457,95458,95459,95460,95461,95462,95463,95464,95465,95466,95467,95468,95469,95470,95471,95472,95473,95474,95475,95476,95477,95478,95479,95480,95481,95482,95483,95484,95485,95486,95487,95488,95489,95490,95491,95492,95493,95494,95495,95496,95497,95498,95499,95500,95501,95504,95507,95508,95509,95510,95511,95512,95513,95514,95515,95516,95517,95518,95519,95520,95521,95522,95523,95524,95525,95526,95527,95528,95529,95530,95531,95532,95533,95534,95535,95536,95537,95538,95539,95540,95541,95542,95543,95544,95545,95546,95547,95548,95549,95550,95551,95552,95553,95554,95555,95556,95557,95558,95559,95560,95561,95562,95563,95564,95565,95566,95567,95568,95569,95570,95571,95572,95573,95574,95575,95576,95577,95578,95579,95580,95581,95582,95583,95584,95586,95587,95588,95589,95590,95591,95592,95593,95594,95595,95596,95597,95598,95599,95600,95601,95602,95603,95604,95605,95606,95607,95608,95609,95610,95611,95612,95613,95614,95615,95616,95617,95618,95619,95620,95621,95622,95623,95624,95625,95626,95627,95628,95629,95630,95631,95632,95633,95634,95635,95636,95637,95638,95639,95640,95641,95642,95643,95644,95645,95646,95647,95648,95649,95650,95651,95652,95653,95654,95655,95656,95657,95658,95659,95660,95661,95662,95663,95664,95665,95666,95667,95668,95669,95670,95671,95672,95673,95674,95675,95676,95677,95678,95679,95680,95681,95682,95683,95684,95685,95686,95687,95688,95689,95690,95691,95692,95693,95694,95695,95696,95697,95698,95699,95700,95701,95702,95703,95704,95705,95706,95707,95708,95709,95710,95711,95712,95713,95714,95715,95716,95717,95718,95719,95720,95721,95722,95723,95724,95725,95726,95727,95728,95729,95730,95731,95732,95733,95734,95735,95736,95737,95738,95739,95742,95746,95748,95749,95751,95753,95754,95765,95766,95787,95796,95804],"literal_raw_sha256":"86ac0aab46e11b92332159bab7f642d1a4db733534d5a7de81fb7d1ef6ba60a8","mode":"INCOMPLETE","name":"Extract-evidence-08-incomplete-one-ne-raw","patches":[],"template":"INCOMPLETE_ONE_NE_RAW"},{"covered_ids":[96803,96805,96811,96813,96814,97075,97077,97078,97079,97080,97081,97083,97084,97085,97086,97087,97088,97089,97091,97092,97093,97094,97095,97096,97097,97098,97099,97101,97102,97103,97104,97105,97106,97107,97108,97109,97110,97111,97112,97113,97114,97115,97116,97118,97119,97120,97121,97122,97123,97124,97125,97126,97127,97129,97130,97131,97132,97133,97134,97135,97136,97137,97138,97139,97141,97142,97143,97144,97145,97146,97147,97148,97149,97150,97151,97152,97153,97154,97155,97156,97157,97158,97159,97160,97161,97162,97163,97164,97165,97166,97167,97168,97169,97170,97171,97172,97173,97174,97175,97176,97177,97178,97179,97180,97181,97182,97183,97184,97185,97186,97187,97188,97189,97190,97191,97192,97193,97195,97196,97197,97198,97199,97200,97201,97202,97203,97204,97205,97206,97207,97208,97209,97210,97211,97212,97282,97283,97284,97285,97287,97290,97291,97292,97293,97294,97296,97299,97300,97301,97302,97303,97304,97305,97306,97307,97308,97309,97310,97311,97312,97313,97314,97315,97316,97317,97318,97319,97320,97321,97322,97323,97324,97325,97326,97327,97328,97329,97330,97331,97332,97333,97334,97335,97336,97337,97338,97339,97340,97341,97342,97343,97344,97345,97346,97347,97348,97349,97350],"literal_raw_sha256":"17f5ff6ca7de3b65cb6ec1b55b0f28d51918e712c28f19288713088435b0d1b3","mode":"REFUSED","name":"Extract-evidence-09-malformed-key-error","patches":[],"template":"MALFORMED_KEY_ERROR"},{"covered_ids":[96872,96874,96875,96881,96883],"literal_raw_sha256":"485930423008302e2a4426721288e3b9606d2aa3381b09f7460d0aaf1397ec08","mode":"REFUSED","name":"Extract-evidence-10-malformed-type-error","patches":[],"template":"MALFORMED_TYPE_ERROR"},{"covered_ids":[96942,96943,96949,96951,96952],"literal_raw_sha256":"ecbdb65bfcf2ce1f75f3706a2ab33afd440ac1ec5e008f2e3bd9e5d35bedf37c","mode":"REFUSED","name":"Extract-evidence-11-malformed-index-error","patches":[],"template":"MALFORMED_INDEX_ERROR"},{"covered_ids":[97351,97354],"literal_raw_sha256":"b737fdbeb2e52e29d3381b2743bf13489fb0a87616a64d8f1f821b636c719cdf","mode":"REFUSED","name":"Extract-evidence-12-complete-raw-base","patches":[{"path":"/preflight","value":{}}],"template":"COMPLETE_RAW_BASE"},{"covered_ids":[97352,97627,97629,97630,97641,97655,97662],"literal_raw_sha256":"142fdcd8fbac6a55ab62e20edff09d88adf9928efe792ad269ae1d243e34f4cf","mode":"REFUSED","name":"Extract-evidence-13-complete-raw-base","patches":[{"path":"/controls","value":{}},{"path":"/status","value":"VOID"}],"template":"COMPLETE_RAW_BASE"},{"covered_ids":[99187,99190],"literal_raw_sha256":"acc6276c5fe6ac24e1901df93f12e38f20edfca25cd14137df07a6e3d07e7bb7","mode":"REFUSED","name":"Extract-evidence-14-complete-raw-base","patches":[{"path":"/dry","value":true},{"path":"/primary","value":"calibration"},{"from":"H1","operation":"rename-population","to":"calibration"}],"template":"COMPLETE_RAW_BASE"},{"covered_ids":[99188],"literal_raw_sha256":"725abd078f711dedd41c731474d6866bde7b578f41a49a70c916040eca2e18d5","mode":"REFUSED","name":"Extract-evidence-15-complete-raw-base","patches":[{"path":"/dry","value":false},{"path":"/primary","value":"hcal"},{"from":"H1","operation":"rename-population","to":"hcal"}],"template":"COMPLETE_RAW_BASE"},{"covered_ids":[100156,100157,100158,100159,100160,100161,100162,100163,100164,100165,100166,100167,100168,100169,100170,100171,100172,100173,100174,100175,100176,100177,100178,100179,100180,100181,100182,100183,100184,100185,100186,100187,100188,100189,100190,100191,100192,100193,100194,100195,100196,100197,100198,100199,100200,100201,100202,100203,100204,100205,100206,100207,100208,100209,100210,100211,100212,100213,100214,100215,100216,100217,100218,100219,100220,100221,100222,100223,100224,100225,100226,100227,100228,100229,100230,100231,100232,100233,100234,100235,100236,100237,100238,100239,100240,100241,100242,100243,100244,100245,100246,100247,100248,100249,100250],"literal_raw_sha256":"ad987ff84777ba21a5064fdcb1083cefdb23777252feec7833f810552d7096e5","mode":"REFUSED","name":"Extract-evidence-16-complete-raw-base","patches":[{"from":"/populations/H1","operation":"add-secondary-population-copy","path":"/populations/hcal"},{"path":"/primary","value":"hcal"},{"path":"/populations/H1/rows","value":{}},{"path":"/populations/H1/labels","value":{}},{"path":"/populations/H1/readings","value":[]}],"template":"COMPLETE_RAW_BASE"}],"control_status_tokens":[[85250,""],[85251,"\\n"],[85252," disagrees with evidence "],[85253," exit "],[85254," recipe failed; see build-"],[85255," recipe stamp mismatch"],[85256,"#"],[85257,", "],[85258,"-"],[85259,"--arm"],[85260,"--calibration"],[85261,"--const-false"],[85262,"--corpus"],[85263,"--declared"],[85264,"--dry"],[85265,"--floor"],[85266,"--no-checkout"],[85267,"--no-tags"],[85268,"--resamples"],[85269,"--seed"],[85270,"--selftest"],[85271,"--shared"],[85272,"--subject"],[85273,"--tol-converged"],[85274,"--verify"],[85275,"--write"],[85276,"--write-manifest"],[85277,"-I"],[85278,"-seal.log"],[85279,".log"],[85280,"/usr/bin:/bin"],[85281,"1 "],[85282,"1 standard parity"],[85283,"12345"],[85284,"124"],[85285,"2 vs INC"],[85286,"2 vs R3-STD"],[85287,"2345"],[85288,"3 safety"],[85289,"3d8a14b4"],[85292,"4 trivial floor"],[85293,"4a3a5c1941568e9bc562c7c8221cff22dc8ba697"],[85294,"5 unit invariance"],[85295,"6 "],[85296,"6 existing gates"],[85297,": "],[85298,": D14 unresolved base"],[85299,": D14 |phi|^(2*burn) must be < 2^-53"],[85300,": sha256 "],[85301,"; STD_p/H2="],[85302,"; derived files "],[85303,"; silent-wrong="],[85304,"; step 1 is repeated"],[85305,"="],[85306,"@"],[85307,"ANCHOR"],[85308,"C"],[85309,"C0"],[85310,"C1"],[85311,"CF"],[85312,"CF="],[85313,"COMPLETE"],[85314,"D2"],[85315,"DRY "],[85316,"F15 "],[85317,"F15b "],[85318,"FAIL"],[85319,"H1"],[85320,"HOME"],[85321,"INC"],[85322,"INCOMPLETE"],[85323,"INCOMPLETE:"],[85324,"INCOMPLETE: "],[85325,"LANG"],[85326,"NOT APPLICABLE (stand-in)"],[85327,"NOT EVALUATED"],[85328,"OUTCOME "],[85329,"PASS"],[85330,"PATH"],[85331,"PERSIST"],[85332,"R3"],[85333,"R3-STD"],[85334,"REF"],[85335,"REFUSED"],[85336,"REPORTED"],[85337,"STD"],[85338,"STD\'"],[85339,"STD\'\'"],[85340,"STD_p_on_H2"],[85341,"T001"],[85342,"T001=0.01"],[85343,"W4"],[85344,"XDG_CACHE_HOME"],[85345,"^F(\\\\d+) "],[85346,"^RED  floor-each "],[85347,"^{commit}"],[85348,"__main__"],[85349,"a"],[85350,"absent"],[85351,"affine"],[85352,"ar1"],[85353,"arms"],[85354,"b"],[85355,"b_undefined"],[85356,"base"],[85357,"bash"],[85358,"beacon"],[85359,"binary"],[85360,"binary_sha256"],[85361,"build-"],[85362,"build/observer-reveal/cache"],[85363,"build_anchor.sh"],[85364,"build_arm.sh"],[85365,"build_w4.sh"],[85366,"burn"],[85367,"c1"],[85368,"c2"],[85369,"calibration"],[85370,"capabilities"],[85371,"capability_check"],[85372,"certify.py"],[85373,"checkpoints"],[85374,"clone"],[85375,"closed"],[85376,"code"],[85377,"confusion"],[85378,"control_c1_rule6"],[85379,"controls"],[85380,"converged"],[85381,"corpus.json"],[85382,"cycle"],[85383,"decisions"],[85384,"declaration_sha256"],[85385,"declarations"],[85386,"derive.py"],[85387,"diffs"],[85388,"disagreements"],[85389,"diverging"],[85390,"driver"],[85391,"dry"],[85392,"e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4"],[85393,"equilibrium"],[85394,"error"],[85395,"failed controls: "],[85396,"family"],[85397,"fetch"],[85398,"findings"],[85399,"floor-"],[85400,"floor-exit"],[85401,"floor_exit"],[85402,"format"],[85403,"from F(\\\\d+) "],[85404,"gen"],[85405,"git"],[85406,"hcal"],[85407,"id"],[85408,"improving"],[85409,"instrument"],[85410,"judge.py"],[85411,"judge_rc"],[85412,"kind"],[85413,"labels"],[85414,"manifest"],[85415,"manifest "],[85416,"manifest.json"],[85417,"manifests"],[85418,"manual_review"],[85419,"manual_review.json"],[85420,"manual_review.py"],[85421,"missing declaration file"],[85422,"n"],[85423,"no-family-15"],[85424,"noise"],[85425,"origin"],[85426,"oscillating"],[85427,"phi"],[85428,"pieces"],[85429,"plants.log"],[85430,"plants.py"],[85431,"plants: 1 examined, 1 red "],[85432,"points"],[85433,"population_tables"],[85434,"populations"],[85435,"predicates"],[85436,"preflight"],[85437,"primary"],[85438,"r3-reveal-commitment/1"],[85439,"r3-reveal/1"],[85440,"randomness"],[85441,"read"],[85442,"readings"],[85443,"reasons"],[85444,"recipe_id"],[85445,"recorded status "],[85446,"recur"],[85447,"repository"],[85448,"resamples"],[85449,"rev-parse"],[85450,"reveal"],[85451,"reveal.py"],[85452,"reveal_fixtures.json"],[85453,"reveal_selftest"],[85454,"reveal_selftest.py"],[85455,"round"],[85456,"rows"],[85457,"rule6"],[85458,"rules"],[85459,"scaled"],[85460,"score_sha256"],[85461,"seal.py"],[85462,"seed"],[85463,"sha256"],[85464,"ship"],[85465,"silent_wrong"],[85466,"source_sha"],[85467,"stable"],[85468,"stamps"],[85469,"status"],[85470,"store_true"],[85471,"subjects"],[85472,"tiers"],[85473,"tools"],[85474,"tools/observer_oracle/floor.json"],[85475,"tools/observer_oracle/score.py"],[85476,"undefined"],[85477,"undefined-BA:diverging,equilibrium"],[85478,"uwalk"],[85479,"verdict"],[85480,"verified_sources.json"],[85481,"walk"]],"existing_builder_literal_authority":{"bytes":427494,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/builder-prefix100251-literal-fixtures.initial.json","sha256":"6bbcbc0b2a090e8a1439383f16b893e325e3352886d0dcaa7e1c3e5f3073f763"},"expected_complete_outcomes":["DRY OUTCOME converged: R3","DRY OUTCOME stable: R3","DRY OUTCOME improving: R3","DRY OUTCOME oscillating: R3","DRY OUTCOME diverging: R3","DRY OUTCOME equilibrium: R3"],"expected_status_matrix_size":230,"expected_tables":{"COMPLETE":{"dry":true,"population_tables":{"H1":{"absent":[],"confusion":{"[\\"ANCHOR\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"D2\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"PERSIST\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"PERSIST\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"PERSIST\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\'\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"T001\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1]},"disagreements":[]}},"predicates":{"converged":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["2 vs R3-STD","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"diverging":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"equilibrium":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"improving":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"oscillating":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"stable":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["2 vs R3-STD","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}}},"resamples":1000,"seed":1758,"status":"COMPLETE"},"INCOMPLETE":{"dry":true,"population_tables":{"H1":{"absent":[],"confusion":{"[\\"ANCHOR\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"ANCHOR\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C0\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"C1\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"D2\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"INC\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"PERSIST\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"PERSIST\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"PERSIST\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"STD\'\'\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"T001\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"converged\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"diverging\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"equilibrium\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"improving\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"oscillating\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"stable\\", \\"F1 synthetic schema fixture\\"]":[0,0,0,1]},"disagreements":[]}},"resamples":1000,"seed":1758,"status":"INCOMPLETE"}},"independent_input_authority":{"bytes":4617715,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/independent-prefix100251-initial-partition.v2.json","sha256":"3a49447ff024deff85c888387c882ea595f42be4a8468446d2c9423764613012"},"root_gap_authority":{"bytes":15198706,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/prefix100251-adjudicated-survivor-gap-records.json","sha256":"fc41b9c21681d51fea964c1980238107d188f42d9c081c9be2d1503a2e1ab099"},"status":"SOURCE_ONLY_NOT_A1_NOT_FINAL","templates":{"COMPLETE_RAW_BASE":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"synthetic-protocol-row@1":{"converged":["MATH",false,"synthetic protocol label, not a draw"],"diverging":["MATH",false,"synthetic protocol label, not a draw"],"equilibrium":["MATH",false,"synthetic protocol label, not a draw"],"improving":["MATH",false,"synthetic protocol label, not a draw"],"oscillating":["MATH",false,"synthetic protocol label, not a draw"],"stable":["MATH",false,"synthetic protocol label, not a draw"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","synthetic-protocol-row",1,"converged",false],["R3","synthetic-protocol-row",1,"stable",false],["R3","synthetic-protocol-row",1,"improving",false],["R3","synthetic-protocol-row",1,"oscillating",false],["R3","synthetic-protocol-row",1,"diverging",false],["R3","synthetic-protocol-row",1,"equilibrium",false],["R3-STD","synthetic-protocol-row",1,"converged",false],["R3-STD","synthetic-protocol-row",1,"stable",false],["R3-STD","synthetic-protocol-row",1,"improving",false],["R3-STD","synthetic-protocol-row",1,"oscillating",false],["R3-STD","synthetic-protocol-row",1,"diverging",false],["R3-STD","synthetic-protocol-row",1,"equilibrium",false],["INC","synthetic-protocol-row",1,"converged",false],["INC","synthetic-protocol-row",1,"stable",false],["INC","synthetic-protocol-row",1,"improving",false],["INC","synthetic-protocol-row",1,"oscillating",false],["INC","synthetic-protocol-row",1,"diverging",false],["INC","synthetic-protocol-row",1,"equilibrium",false],["ANCHOR","synthetic-protocol-row",1,"converged",false],["ANCHOR","synthetic-protocol-row",1,"stable",false],["ANCHOR","synthetic-protocol-row",1,"improving",false],["ANCHOR","synthetic-protocol-row",1,"oscillating",false],["ANCHOR","synthetic-protocol-row",1,"diverging",false],["ANCHOR","synthetic-protocol-row",1,"equilibrium",false],["STD","synthetic-protocol-row",1,"converged",false],["STD","synthetic-protocol-row",1,"stable",false],["STD","synthetic-protocol-row",1,"improving",false],["STD","synthetic-protocol-row",1,"oscillating",false],["STD","synthetic-protocol-row",1,"diverging",false],["STD","synthetic-protocol-row",1,"equilibrium",false],["STD\'","synthetic-protocol-row",1,"converged",false],["STD\'","synthetic-protocol-row",1,"stable",false],["STD\'","synthetic-protocol-row",1,"improving",false],["STD\'","synthetic-protocol-row",1,"oscillating",false],["STD\'","synthetic-protocol-row",1,"diverging",false],["STD\'","synthetic-protocol-row",1,"equilibrium",false],["REF","synthetic-protocol-row",1,"converged",false],["REF","synthetic-protocol-row",1,"stable",false],["REF","synthetic-protocol-row",1,"improving",false],["REF","synthetic-protocol-row",1,"oscillating",false],["REF","synthetic-protocol-row",1,"diverging",false],["REF","synthetic-protocol-row",1,"equilibrium",false],["C0","synthetic-protocol-row",1,"converged",false],["C0","synthetic-protocol-row",1,"stable",false],["C0","synthetic-protocol-row",1,"improving",false],["C0","synthetic-protocol-row",1,"oscillating",false],["C0","synthetic-protocol-row",1,"diverging",false],["C0","synthetic-protocol-row",1,"equilibrium",false],["C1","synthetic-protocol-row",1,"converged",false],["C1","synthetic-protocol-row",1,"stable",false],["C1","synthetic-protocol-row",1,"improving",false],["C1","synthetic-protocol-row",1,"oscillating",false],["C1","synthetic-protocol-row",1,"diverging",false],["C1","synthetic-protocol-row",1,"equilibrium",false],["CF","synthetic-protocol-row",1,"converged",false],["CF","synthetic-protocol-row",1,"stable",false],["CF","synthetic-protocol-row",1,"improving",false],["CF","synthetic-protocol-row",1,"oscillating",false],["CF","synthetic-protocol-row",1,"diverging",false],["CF","synthetic-protocol-row",1,"equilibrium",false],["W4","synthetic-protocol-row",1,"converged",false],["W4","synthetic-protocol-row",1,"stable",false],["W4","synthetic-protocol-row",1,"improving",false],["W4","synthetic-protocol-row",1,"oscillating",false],["W4","synthetic-protocol-row",1,"diverging",false],["W4","synthetic-protocol-row",1,"equilibrium",false],["STD\'\'","synthetic-protocol-row",1,"equilibrium",false],["D2","synthetic-protocol-row",1,"improving",false],["PERSIST","synthetic-protocol-row",1,"converged",false],["PERSIST","synthetic-protocol-row",1,"stable",false],["PERSIST","synthetic-protocol-row",1,"equilibrium",false],["T001","synthetic-protocol-row",1,"converged",false]],"rows":{"synthetic-protocol-row":{"checkpoints":[1],"family":"F1 synthetic schema fixture","id":"synthetic-protocol-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"COMPLETE"},"INCOMPLETE_ONE_NE_RAW":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","NOT EVALUATED","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"INCOMPLETE"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"synthetic-protocol-row@1":{"converged":["MATH",false,"synthetic protocol label, not a draw"],"diverging":["MATH",false,"synthetic protocol label, not a draw"],"equilibrium":["MATH",false,"synthetic protocol label, not a draw"],"improving":["MATH",false,"synthetic protocol label, not a draw"],"oscillating":["MATH",false,"synthetic protocol label, not a draw"],"stable":["MATH",false,"synthetic protocol label, not a draw"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","synthetic-protocol-row",1,"converged",false],["R3","synthetic-protocol-row",1,"stable",false],["R3","synthetic-protocol-row",1,"improving",false],["R3","synthetic-protocol-row",1,"oscillating",false],["R3","synthetic-protocol-row",1,"diverging",false],["R3","synthetic-protocol-row",1,"equilibrium",false],["R3-STD","synthetic-protocol-row",1,"converged",false],["R3-STD","synthetic-protocol-row",1,"stable",false],["R3-STD","synthetic-protocol-row",1,"improving",false],["R3-STD","synthetic-protocol-row",1,"oscillating",false],["R3-STD","synthetic-protocol-row",1,"diverging",false],["R3-STD","synthetic-protocol-row",1,"equilibrium",false],["INC","synthetic-protocol-row",1,"converged",false],["INC","synthetic-protocol-row",1,"stable",false],["INC","synthetic-protocol-row",1,"improving",false],["INC","synthetic-protocol-row",1,"oscillating",false],["INC","synthetic-protocol-row",1,"diverging",false],["INC","synthetic-protocol-row",1,"equilibrium",false],["ANCHOR","synthetic-protocol-row",1,"converged",false],["ANCHOR","synthetic-protocol-row",1,"stable",false],["ANCHOR","synthetic-protocol-row",1,"improving",false],["ANCHOR","synthetic-protocol-row",1,"oscillating",false],["ANCHOR","synthetic-protocol-row",1,"diverging",false],["ANCHOR","synthetic-protocol-row",1,"equilibrium",false],["STD","synthetic-protocol-row",1,"converged",false],["STD","synthetic-protocol-row",1,"stable",false],["STD","synthetic-protocol-row",1,"improving",false],["STD","synthetic-protocol-row",1,"oscillating",false],["STD","synthetic-protocol-row",1,"diverging",false],["STD","synthetic-protocol-row",1,"equilibrium",false],["STD\'","synthetic-protocol-row",1,"converged",false],["STD\'","synthetic-protocol-row",1,"stable",false],["STD\'","synthetic-protocol-row",1,"improving",false],["STD\'","synthetic-protocol-row",1,"oscillating",false],["STD\'","synthetic-protocol-row",1,"diverging",false],["STD\'","synthetic-protocol-row",1,"equilibrium",false],["REF","synthetic-protocol-row",1,"converged",false],["REF","synthetic-protocol-row",1,"stable",false],["REF","synthetic-protocol-row",1,"improving",false],["REF","synthetic-protocol-row",1,"oscillating",false],["REF","synthetic-protocol-row",1,"diverging",false],["REF","synthetic-protocol-row",1,"equilibrium",false],["C0","synthetic-protocol-row",1,"converged",false],["C0","synthetic-protocol-row",1,"stable",false],["C0","synthetic-protocol-row",1,"improving",false],["C0","synthetic-protocol-row",1,"oscillating",false],["C0","synthetic-protocol-row",1,"diverging",false],["C0","synthetic-protocol-row",1,"equilibrium",false],["C1","synthetic-protocol-row",1,"converged",false],["C1","synthetic-protocol-row",1,"stable",false],["C1","synthetic-protocol-row",1,"improving",false],["C1","synthetic-protocol-row",1,"oscillating",false],["C1","synthetic-protocol-row",1,"diverging",false],["C1","synthetic-protocol-row",1,"equilibrium",false],["CF","synthetic-protocol-row",1,"converged",false],["CF","synthetic-protocol-row",1,"stable",false],["CF","synthetic-protocol-row",1,"improving",false],["CF","synthetic-protocol-row",1,"oscillating",false],["CF","synthetic-protocol-row",1,"diverging",false],["CF","synthetic-protocol-row",1,"equilibrium",false],["W4","synthetic-protocol-row",1,"converged",false],["W4","synthetic-protocol-row",1,"stable",false],["W4","synthetic-protocol-row",1,"improving",false],["W4","synthetic-protocol-row",1,"oscillating",false],["W4","synthetic-protocol-row",1,"diverging",false],["W4","synthetic-protocol-row",1,"equilibrium",false],["STD\'\'","synthetic-protocol-row",1,"equilibrium",false],["D2","synthetic-protocol-row",1,"improving",false],["PERSIST","synthetic-protocol-row",1,"converged",false],["PERSIST","synthetic-protocol-row",1,"stable",false],["PERSIST","synthetic-protocol-row",1,"equilibrium",false],["T001","synthetic-protocol-row",1,"converged",false]],"rows":{"synthetic-protocol-row":{"checkpoints":[1],"family":"F1 synthetic schema fixture","id":"synthetic-protocol-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"INCOMPLETE"},"MALFORMED_INDEX_ERROR":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[[],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"synthetic-protocol-row@1":{"converged":["MATH",false,"synthetic protocol label, not a draw"],"diverging":["MATH",false,"synthetic protocol label, not a draw"],"equilibrium":["MATH",false,"synthetic protocol label, not a draw"],"improving":["MATH",false,"synthetic protocol label, not a draw"],"oscillating":["MATH",false,"synthetic protocol label, not a draw"],"stable":["MATH",false,"synthetic protocol label, not a draw"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","synthetic-protocol-row",1,"converged",false],["R3","synthetic-protocol-row",1,"stable",false],["R3","synthetic-protocol-row",1,"improving",false],["R3","synthetic-protocol-row",1,"oscillating",false],["R3","synthetic-protocol-row",1,"diverging",false],["R3","synthetic-protocol-row",1,"equilibrium",false],["R3-STD","synthetic-protocol-row",1,"converged",false],["R3-STD","synthetic-protocol-row",1,"stable",false],["R3-STD","synthetic-protocol-row",1,"improving",false],["R3-STD","synthetic-protocol-row",1,"oscillating",false],["R3-STD","synthetic-protocol-row",1,"diverging",false],["R3-STD","synthetic-protocol-row",1,"equilibrium",false],["INC","synthetic-protocol-row",1,"converged",false],["INC","synthetic-protocol-row",1,"stable",false],["INC","synthetic-protocol-row",1,"improving",false],["INC","synthetic-protocol-row",1,"oscillating",false],["INC","synthetic-protocol-row",1,"diverging",false],["INC","synthetic-protocol-row",1,"equilibrium",false],["ANCHOR","synthetic-protocol-row",1,"converged",false],["ANCHOR","synthetic-protocol-row",1,"stable",false],["ANCHOR","synthetic-protocol-row",1,"improving",false],["ANCHOR","synthetic-protocol-row",1,"oscillating",false],["ANCHOR","synthetic-protocol-row",1,"diverging",false],["ANCHOR","synthetic-protocol-row",1,"equilibrium",false],["STD","synthetic-protocol-row",1,"converged",false],["STD","synthetic-protocol-row",1,"stable",false],["STD","synthetic-protocol-row",1,"improving",false],["STD","synthetic-protocol-row",1,"oscillating",false],["STD","synthetic-protocol-row",1,"diverging",false],["STD","synthetic-protocol-row",1,"equilibrium",false],["STD\'","synthetic-protocol-row",1,"converged",false],["STD\'","synthetic-protocol-row",1,"stable",false],["STD\'","synthetic-protocol-row",1,"improving",false],["STD\'","synthetic-protocol-row",1,"oscillating",false],["STD\'","synthetic-protocol-row",1,"diverging",false],["STD\'","synthetic-protocol-row",1,"equilibrium",false],["REF","synthetic-protocol-row",1,"converged",false],["REF","synthetic-protocol-row",1,"stable",false],["REF","synthetic-protocol-row",1,"improving",false],["REF","synthetic-protocol-row",1,"oscillating",false],["REF","synthetic-protocol-row",1,"diverging",false],["REF","synthetic-protocol-row",1,"equilibrium",false],["C0","synthetic-protocol-row",1,"converged",false],["C0","synthetic-protocol-row",1,"stable",false],["C0","synthetic-protocol-row",1,"improving",false],["C0","synthetic-protocol-row",1,"oscillating",false],["C0","synthetic-protocol-row",1,"diverging",false],["C0","synthetic-protocol-row",1,"equilibrium",false],["C1","synthetic-protocol-row",1,"converged",false],["C1","synthetic-protocol-row",1,"stable",false],["C1","synthetic-protocol-row",1,"improving",false],["C1","synthetic-protocol-row",1,"oscillating",false],["C1","synthetic-protocol-row",1,"diverging",false],["C1","synthetic-protocol-row",1,"equilibrium",false],["CF","synthetic-protocol-row",1,"converged",false],["CF","synthetic-protocol-row",1,"stable",false],["CF","synthetic-protocol-row",1,"improving",false],["CF","synthetic-protocol-row",1,"oscillating",false],["CF","synthetic-protocol-row",1,"diverging",false],["CF","synthetic-protocol-row",1,"equilibrium",false],["W4","synthetic-protocol-row",1,"converged",false],["W4","synthetic-protocol-row",1,"stable",false],["W4","synthetic-protocol-row",1,"improving",false],["W4","synthetic-protocol-row",1,"oscillating",false],["W4","synthetic-protocol-row",1,"diverging",false],["W4","synthetic-protocol-row",1,"equilibrium",false],["STD\'\'","synthetic-protocol-row",1,"equilibrium",false],["D2","synthetic-protocol-row",1,"improving",false],["PERSIST","synthetic-protocol-row",1,"converged",false],["PERSIST","synthetic-protocol-row",1,"stable",false],["PERSIST","synthetic-protocol-row",1,"equilibrium",false],["T001","synthetic-protocol-row",1,"converged",false]],"rows":{"synthetic-protocol-row":{"checkpoints":[1],"family":"F1 synthetic schema fixture","id":"synthetic-protocol-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"COMPLETE"},"MALFORMED_KEY_ERROR":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"synthetic-protocol-row@1":{"converged":["MATH",false,"synthetic protocol label, not a draw"],"diverging":["MATH",false,"synthetic protocol label, not a draw"],"equilibrium":["MATH",false,"synthetic protocol label, not a draw"],"improving":["MATH",false,"synthetic protocol label, not a draw"],"oscillating":["MATH",false,"synthetic protocol label, not a draw"],"stable":["MATH",false,"synthetic protocol label, not a draw"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","synthetic-protocol-row",1,"converged",false],["R3","synthetic-protocol-row",1,"stable",false],["R3","synthetic-protocol-row",1,"improving",false],["R3","synthetic-protocol-row",1,"oscillating",false],["R3","synthetic-protocol-row",1,"diverging",false],["R3","synthetic-protocol-row",1,"equilibrium",false],["R3-STD","synthetic-protocol-row",1,"converged",false],["R3-STD","synthetic-protocol-row",1,"stable",false],["R3-STD","synthetic-protocol-row",1,"improving",false],["R3-STD","synthetic-protocol-row",1,"oscillating",false],["R3-STD","synthetic-protocol-row",1,"diverging",false],["R3-STD","synthetic-protocol-row",1,"equilibrium",false],["INC","synthetic-protocol-row",1,"converged",false],["INC","synthetic-protocol-row",1,"stable",false],["INC","synthetic-protocol-row",1,"improving",false],["INC","synthetic-protocol-row",1,"oscillating",false],["INC","synthetic-protocol-row",1,"diverging",false],["INC","synthetic-protocol-row",1,"equilibrium",false],["ANCHOR","synthetic-protocol-row",1,"converged",false],["ANCHOR","synthetic-protocol-row",1,"stable",false],["ANCHOR","synthetic-protocol-row",1,"improving",false],["ANCHOR","synthetic-protocol-row",1,"oscillating",false],["ANCHOR","synthetic-protocol-row",1,"diverging",false],["ANCHOR","synthetic-protocol-row",1,"equilibrium",false],["STD","synthetic-protocol-row",1,"converged",false],["STD","synthetic-protocol-row",1,"stable",false],["STD","synthetic-protocol-row",1,"improving",false],["STD","synthetic-protocol-row",1,"oscillating",false],["STD","synthetic-protocol-row",1,"diverging",false],["STD","synthetic-protocol-row",1,"equilibrium",false],["STD\'","synthetic-protocol-row",1,"converged",false],["STD\'","synthetic-protocol-row",1,"stable",false],["STD\'","synthetic-protocol-row",1,"improving",false],["STD\'","synthetic-protocol-row",1,"oscillating",false],["STD\'","synthetic-protocol-row",1,"diverging",false],["STD\'","synthetic-protocol-row",1,"equilibrium",false],["REF","synthetic-protocol-row",1,"converged",false],["REF","synthetic-protocol-row",1,"stable",false],["REF","synthetic-protocol-row",1,"improving",false],["REF","synthetic-protocol-row",1,"oscillating",false],["REF","synthetic-protocol-row",1,"diverging",false],["REF","synthetic-protocol-row",1,"equilibrium",false],["C0","synthetic-protocol-row",1,"converged",false],["C0","synthetic-protocol-row",1,"stable",false],["C0","synthetic-protocol-row",1,"improving",false],["C0","synthetic-protocol-row",1,"oscillating",false],["C0","synthetic-protocol-row",1,"diverging",false],["C0","synthetic-protocol-row",1,"equilibrium",false],["C1","synthetic-protocol-row",1,"converged",false],["C1","synthetic-protocol-row",1,"stable",false],["C1","synthetic-protocol-row",1,"improving",false],["C1","synthetic-protocol-row",1,"oscillating",false],["C1","synthetic-protocol-row",1,"diverging",false],["C1","synthetic-protocol-row",1,"equilibrium",false],["CF","synthetic-protocol-row",1,"converged",false],["CF","synthetic-protocol-row",1,"stable",false],["CF","synthetic-protocol-row",1,"improving",false],["CF","synthetic-protocol-row",1,"oscillating",false],["CF","synthetic-protocol-row",1,"diverging",false],["CF","synthetic-protocol-row",1,"equilibrium",false],["W4","synthetic-protocol-row",1,"converged",false],["W4","synthetic-protocol-row",1,"stable",false],["W4","synthetic-protocol-row",1,"improving",false],["W4","synthetic-protocol-row",1,"oscillating",false],["W4","synthetic-protocol-row",1,"diverging",false],["W4","synthetic-protocol-row",1,"equilibrium",false],["STD\'\'","synthetic-protocol-row",1,"equilibrium",false],["D2","synthetic-protocol-row",1,"improving",false],["PERSIST","synthetic-protocol-row",1,"converged",false],["PERSIST","synthetic-protocol-row",1,"stable",false],["PERSIST","synthetic-protocol-row",1,"equilibrium",false],["T001","synthetic-protocol-row",1,"converged",false]],"rows":{"synthetic-protocol-row":{"checkpoints":[1],"family":"F1 synthetic schema fixture","id":"synthetic-protocol-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"COMPLETE"},"MALFORMED_TYPE_ERROR":{"controls":1,"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"synthetic-protocol-row@1":{"converged":["MATH",false,"synthetic protocol label, not a draw"],"diverging":["MATH",false,"synthetic protocol label, not a draw"],"equilibrium":["MATH",false,"synthetic protocol label, not a draw"],"improving":["MATH",false,"synthetic protocol label, not a draw"],"oscillating":["MATH",false,"synthetic protocol label, not a draw"],"stable":["MATH",false,"synthetic protocol label, not a draw"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","synthetic-protocol-row",1,"converged",false],["R3","synthetic-protocol-row",1,"stable",false],["R3","synthetic-protocol-row",1,"improving",false],["R3","synthetic-protocol-row",1,"oscillating",false],["R3","synthetic-protocol-row",1,"diverging",false],["R3","synthetic-protocol-row",1,"equilibrium",false],["R3-STD","synthetic-protocol-row",1,"converged",false],["R3-STD","synthetic-protocol-row",1,"stable",false],["R3-STD","synthetic-protocol-row",1,"improving",false],["R3-STD","synthetic-protocol-row",1,"oscillating",false],["R3-STD","synthetic-protocol-row",1,"diverging",false],["R3-STD","synthetic-protocol-row",1,"equilibrium",false],["INC","synthetic-protocol-row",1,"converged",false],["INC","synthetic-protocol-row",1,"stable",false],["INC","synthetic-protocol-row",1,"improving",false],["INC","synthetic-protocol-row",1,"oscillating",false],["INC","synthetic-protocol-row",1,"diverging",false],["INC","synthetic-protocol-row",1,"equilibrium",false],["ANCHOR","synthetic-protocol-row",1,"converged",false],["ANCHOR","synthetic-protocol-row",1,"stable",false],["ANCHOR","synthetic-protocol-row",1,"improving",false],["ANCHOR","synthetic-protocol-row",1,"oscillating",false],["ANCHOR","synthetic-protocol-row",1,"diverging",false],["ANCHOR","synthetic-protocol-row",1,"equilibrium",false],["STD","synthetic-protocol-row",1,"converged",false],["STD","synthetic-protocol-row",1,"stable",false],["STD","synthetic-protocol-row",1,"improving",false],["STD","synthetic-protocol-row",1,"oscillating",false],["STD","synthetic-protocol-row",1,"diverging",false],["STD","synthetic-protocol-row",1,"equilibrium",false],["STD\'","synthetic-protocol-row",1,"converged",false],["STD\'","synthetic-protocol-row",1,"stable",false],["STD\'","synthetic-protocol-row",1,"improving",false],["STD\'","synthetic-protocol-row",1,"oscillating",false],["STD\'","synthetic-protocol-row",1,"diverging",false],["STD\'","synthetic-protocol-row",1,"equilibrium",false],["REF","synthetic-protocol-row",1,"converged",false],["REF","synthetic-protocol-row",1,"stable",false],["REF","synthetic-protocol-row",1,"improving",false],["REF","synthetic-protocol-row",1,"oscillating",false],["REF","synthetic-protocol-row",1,"diverging",false],["REF","synthetic-protocol-row",1,"equilibrium",false],["C0","synthetic-protocol-row",1,"converged",false],["C0","synthetic-protocol-row",1,"stable",false],["C0","synthetic-protocol-row",1,"improving",false],["C0","synthetic-protocol-row",1,"oscillating",false],["C0","synthetic-protocol-row",1,"diverging",false],["C0","synthetic-protocol-row",1,"equilibrium",false],["C1","synthetic-protocol-row",1,"converged",false],["C1","synthetic-protocol-row",1,"stable",false],["C1","synthetic-protocol-row",1,"improving",false],["C1","synthetic-protocol-row",1,"oscillating",false],["C1","synthetic-protocol-row",1,"diverging",false],["C1","synthetic-protocol-row",1,"equilibrium",false],["CF","synthetic-protocol-row",1,"converged",false],["CF","synthetic-protocol-row",1,"stable",false],["CF","synthetic-protocol-row",1,"improving",false],["CF","synthetic-protocol-row",1,"oscillating",false],["CF","synthetic-protocol-row",1,"diverging",false],["CF","synthetic-protocol-row",1,"equilibrium",false],["W4","synthetic-protocol-row",1,"converged",false],["W4","synthetic-protocol-row",1,"stable",false],["W4","synthetic-protocol-row",1,"improving",false],["W4","synthetic-protocol-row",1,"oscillating",false],["W4","synthetic-protocol-row",1,"diverging",false],["W4","synthetic-protocol-row",1,"equilibrium",false],["STD\'\'","synthetic-protocol-row",1,"equilibrium",false],["D2","synthetic-protocol-row",1,"improving",false],["PERSIST","synthetic-protocol-row",1,"converged",false],["PERSIST","synthetic-protocol-row",1,"stable",false],["PERSIST","synthetic-protocol-row",1,"equilibrium",false],["T001","synthetic-protocol-row",1,"converged",false]],"rows":{"synthetic-protocol-row":{"checkpoints":[1],"family":"F1 synthetic schema fixture","id":"synthetic-protocol-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"COMPLETE"},"OMITTED_PRED_ROSTER":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}},"R3":{"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"synthetic-protocol-row@1":{"converged":["MATH",false,"synthetic protocol label, not a draw"],"diverging":["MATH",false,"synthetic protocol label, not a draw"],"equilibrium":["MATH",false,"synthetic protocol label, not a draw"],"improving":["MATH",false,"synthetic protocol label, not a draw"],"oscillating":["MATH",false,"synthetic protocol label, not a draw"],"stable":["MATH",false,"synthetic protocol label, not a draw"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","synthetic-protocol-row",1,"converged",false],["R3","synthetic-protocol-row",1,"stable",false],["R3","synthetic-protocol-row",1,"improving",false],["R3","synthetic-protocol-row",1,"oscillating",false],["R3","synthetic-protocol-row",1,"diverging",false],["R3","synthetic-protocol-row",1,"equilibrium",false],["R3-STD","synthetic-protocol-row",1,"converged",false],["R3-STD","synthetic-protocol-row",1,"stable",false],["R3-STD","synthetic-protocol-row",1,"improving",false],["R3-STD","synthetic-protocol-row",1,"oscillating",false],["R3-STD","synthetic-protocol-row",1,"diverging",false],["R3-STD","synthetic-protocol-row",1,"equilibrium",false],["INC","synthetic-protocol-row",1,"converged",false],["INC","synthetic-protocol-row",1,"stable",false],["INC","synthetic-protocol-row",1,"improving",false],["INC","synthetic-protocol-row",1,"oscillating",false],["INC","synthetic-protocol-row",1,"diverging",false],["INC","synthetic-protocol-row",1,"equilibrium",false],["ANCHOR","synthetic-protocol-row",1,"converged",false],["ANCHOR","synthetic-protocol-row",1,"stable",false],["ANCHOR","synthetic-protocol-row",1,"improving",false],["ANCHOR","synthetic-protocol-row",1,"oscillating",false],["ANCHOR","synthetic-protocol-row",1,"diverging",false],["ANCHOR","synthetic-protocol-row",1,"equilibrium",false],["STD","synthetic-protocol-row",1,"converged",false],["STD","synthetic-protocol-row",1,"stable",false],["STD","synthetic-protocol-row",1,"improving",false],["STD","synthetic-protocol-row",1,"oscillating",false],["STD","synthetic-protocol-row",1,"diverging",false],["STD","synthetic-protocol-row",1,"equilibrium",false],["STD\'","synthetic-protocol-row",1,"converged",false],["STD\'","synthetic-protocol-row",1,"stable",false],["STD\'","synthetic-protocol-row",1,"improving",false],["STD\'","synthetic-protocol-row",1,"oscillating",false],["STD\'","synthetic-protocol-row",1,"diverging",false],["STD\'","synthetic-protocol-row",1,"equilibrium",false],["REF","synthetic-protocol-row",1,"converged",false],["REF","synthetic-protocol-row",1,"stable",false],["REF","synthetic-protocol-row",1,"improving",false],["REF","synthetic-protocol-row",1,"oscillating",false],["REF","synthetic-protocol-row",1,"diverging",false],["REF","synthetic-protocol-row",1,"equilibrium",false],["C0","synthetic-protocol-row",1,"converged",false],["C0","synthetic-protocol-row",1,"stable",false],["C0","synthetic-protocol-row",1,"improving",false],["C0","synthetic-protocol-row",1,"oscillating",false],["C0","synthetic-protocol-row",1,"diverging",false],["C0","synthetic-protocol-row",1,"equilibrium",false],["C1","synthetic-protocol-row",1,"converged",false],["C1","synthetic-protocol-row",1,"stable",false],["C1","synthetic-protocol-row",1,"improving",false],["C1","synthetic-protocol-row",1,"oscillating",false],["C1","synthetic-protocol-row",1,"diverging",false],["C1","synthetic-protocol-row",1,"equilibrium",false],["CF","synthetic-protocol-row",1,"converged",false],["CF","synthetic-protocol-row",1,"stable",false],["CF","synthetic-protocol-row",1,"improving",false],["CF","synthetic-protocol-row",1,"oscillating",false],["CF","synthetic-protocol-row",1,"diverging",false],["CF","synthetic-protocol-row",1,"equilibrium",false],["W4","synthetic-protocol-row",1,"converged",false],["W4","synthetic-protocol-row",1,"stable",false],["W4","synthetic-protocol-row",1,"improving",false],["W4","synthetic-protocol-row",1,"oscillating",false],["W4","synthetic-protocol-row",1,"diverging",false],["W4","synthetic-protocol-row",1,"equilibrium",false],["STD\'\'","synthetic-protocol-row",1,"equilibrium",false],["D2","synthetic-protocol-row",1,"improving",false],["PERSIST","synthetic-protocol-row",1,"converged",false],["PERSIST","synthetic-protocol-row",1,"stable",false],["PERSIST","synthetic-protocol-row",1,"equilibrium",false],["T001","synthetic-protocol-row",1,"converged",false]],"rows":{"synthetic-protocol-row":{"checkpoints":[1],"family":"F1 synthetic schema fixture","id":"synthetic-protocol-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"COMPLETE"},"OMITTED_SUBJECT_ROSTER":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","FAIL","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["2 vs R3-STD","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","synthetic protocol explanation"],["2 vs INC","PASS","synthetic protocol explanation"],["3 safety","PASS","synthetic protocol explanation"],["4 trivial floor","PASS","synthetic protocol explanation"],["5 unit invariance","PASS","synthetic protocol explanation"],["6 existing gates","PASS","synthetic protocol explanation"]],"verdict":"PASS"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"synthetic-protocol-row@1":{"converged":["MATH",false,"synthetic protocol label, not a draw"],"diverging":["MATH",false,"synthetic protocol label, not a draw"],"equilibrium":["MATH",false,"synthetic protocol label, not a draw"],"improving":["MATH",false,"synthetic protocol label, not a draw"],"oscillating":["MATH",false,"synthetic protocol label, not a draw"],"stable":["MATH",false,"synthetic protocol label, not a draw"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","synthetic-protocol-row",1,"converged",false],["R3","synthetic-protocol-row",1,"stable",false],["R3","synthetic-protocol-row",1,"improving",false],["R3","synthetic-protocol-row",1,"oscillating",false],["R3","synthetic-protocol-row",1,"diverging",false],["R3","synthetic-protocol-row",1,"equilibrium",false],["R3-STD","synthetic-protocol-row",1,"converged",false],["R3-STD","synthetic-protocol-row",1,"stable",false],["R3-STD","synthetic-protocol-row",1,"improving",false],["R3-STD","synthetic-protocol-row",1,"oscillating",false],["R3-STD","synthetic-protocol-row",1,"diverging",false],["R3-STD","synthetic-protocol-row",1,"equilibrium",false],["INC","synthetic-protocol-row",1,"converged",false],["INC","synthetic-protocol-row",1,"stable",false],["INC","synthetic-protocol-row",1,"improving",false],["INC","synthetic-protocol-row",1,"oscillating",false],["INC","synthetic-protocol-row",1,"diverging",false],["INC","synthetic-protocol-row",1,"equilibrium",false],["ANCHOR","synthetic-protocol-row",1,"converged",false],["ANCHOR","synthetic-protocol-row",1,"stable",false],["ANCHOR","synthetic-protocol-row",1,"improving",false],["ANCHOR","synthetic-protocol-row",1,"oscillating",false],["ANCHOR","synthetic-protocol-row",1,"diverging",false],["ANCHOR","synthetic-protocol-row",1,"equilibrium",false],["STD","synthetic-protocol-row",1,"converged",false],["STD","synthetic-protocol-row",1,"stable",false],["STD","synthetic-protocol-row",1,"improving",false],["STD","synthetic-protocol-row",1,"oscillating",false],["STD","synthetic-protocol-row",1,"diverging",false],["STD","synthetic-protocol-row",1,"equilibrium",false],["STD\'","synthetic-protocol-row",1,"converged",false],["STD\'","synthetic-protocol-row",1,"stable",false],["STD\'","synthetic-protocol-row",1,"improving",false],["STD\'","synthetic-protocol-row",1,"oscillating",false],["STD\'","synthetic-protocol-row",1,"diverging",false],["STD\'","synthetic-protocol-row",1,"equilibrium",false],["REF","synthetic-protocol-row",1,"converged",false],["REF","synthetic-protocol-row",1,"stable",false],["REF","synthetic-protocol-row",1,"improving",false],["REF","synthetic-protocol-row",1,"oscillating",false],["REF","synthetic-protocol-row",1,"diverging",false],["REF","synthetic-protocol-row",1,"equilibrium",false],["C0","synthetic-protocol-row",1,"converged",false],["C0","synthetic-protocol-row",1,"stable",false],["C0","synthetic-protocol-row",1,"improving",false],["C0","synthetic-protocol-row",1,"oscillating",false],["C0","synthetic-protocol-row",1,"diverging",false],["C0","synthetic-protocol-row",1,"equilibrium",false],["C1","synthetic-protocol-row",1,"converged",false],["C1","synthetic-protocol-row",1,"stable",false],["C1","synthetic-protocol-row",1,"improving",false],["C1","synthetic-protocol-row",1,"oscillating",false],["C1","synthetic-protocol-row",1,"diverging",false],["C1","synthetic-protocol-row",1,"equilibrium",false],["CF","synthetic-protocol-row",1,"converged",false],["CF","synthetic-protocol-row",1,"stable",false],["CF","synthetic-protocol-row",1,"improving",false],["CF","synthetic-protocol-row",1,"oscillating",false],["CF","synthetic-protocol-row",1,"diverging",false],["CF","synthetic-protocol-row",1,"equilibrium",false],["W4","synthetic-protocol-row",1,"converged",false],["W4","synthetic-protocol-row",1,"stable",false],["W4","synthetic-protocol-row",1,"improving",false],["W4","synthetic-protocol-row",1,"oscillating",false],["W4","synthetic-protocol-row",1,"diverging",false],["W4","synthetic-protocol-row",1,"equilibrium",false],["STD\'\'","synthetic-protocol-row",1,"equilibrium",false],["D2","synthetic-protocol-row",1,"improving",false],["PERSIST","synthetic-protocol-row",1,"converged",false],["PERSIST","synthetic-protocol-row",1,"stable",false],["PERSIST","synthetic-protocol-row",1,"equilibrium",false],["T001","synthetic-protocol-row",1,"converged",false]],"rows":{"synthetic-protocol-row":{"checkpoints":[1],"family":"F1 synthetic schema fixture","id":"synthetic-protocol-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"COMPLETE"}}}')
_r30x_entry_cache = {}


def _r30x_entry_code(R):
    # The enumeration never edits this module footer. Read its actual bytes,
    # compile the exact whole If/try/except once, and run it in each mutant's
    # globals with the CLI's real __name__. Never reproduce its catch formula.
    text = Path(R.__file__).read_text()
    marker = "\nif __name__ == '__main__':\n"
    if text.count(marker) != 1:
        raise AssertionError('unique production CLI footer required')
    footer = marker[1:] + text.split(marker, 1)[1]
    if footer not in _r30x_entry_cache:
        tree = _r30x_ast.parse(footer, filename=R.__file__)
        if len(tree.body) != 1 or not isinstance(tree.body[0], _r30x_ast.If):
            raise AssertionError('production CLI footer shape changed')
        want_test = _r30x_ast.parse("__name__ == '__main__'", mode='eval').body
        if _r30x_ast.dump(tree.body[0].test) != _r30x_ast.dump(want_test):
            raise AssertionError('production CLI entry condition changed')
        _r30x_entry_cache[footer] = compile(tree, R.__file__, 'exec')
    return _r30x_entry_cache[footer]


def _r30x_pointer(raw, path):
    node = raw
    for key in path.strip('/').split('/'):
        node = node[int(key)] if isinstance(node, list) else node[key]
    return node


def _r30x_parent(raw, path):
    parts = path.strip('/').split('/')
    node = raw
    for key in parts[:-1]:
        node = node[int(key)] if isinstance(node, list) else node[key]
    return node, int(parts[-1]) if isinstance(node, list) else parts[-1]


def _r30x_raw(spec):
    # Input-only JSON patching; no verdict/status/control value is read from R.
    raw = copy.deepcopy(_r30x_data['templates'][spec['template']])
    for item in spec['patches']:
        operation = item.get('operation', 'set')
        if operation == 'set':
            target, key = _r30x_parent(raw, item['path'])
            target[key] = copy.deepcopy(item['value'])
        elif operation == 'add-secondary-population-copy':
            target, key = _r30x_parent(raw, item['path'])
            target[key] = copy.deepcopy(_r30x_pointer(raw, item['from']))
        elif operation == 'remove-last-rule':
            _r30x_pointer(raw, item['path']).pop()
        elif operation == 'remove-field-index':
            _r30x_pointer(raw, item['path']).pop(item['index'])
        elif operation == 'rename-population':
            raw['populations'][item['to']] = raw['populations'].pop(item['from'])
        else:
            raise AssertionError('unknown independent literal input operation')
    return raw



def _r30x_process_status(code, stderr):
    # CPython3.12 _Py_HandleSystemExit uses None->0, PyLong_AsLong for
    # integer codes, otherwise raw stderr text and1. On this POSIX driver,
    # process observation retains the low8bits of the C exit status. A long
    # overflow produces -1 (observed POSIX255), not an invented refusal2.
    # struct queries native C long width; no library/process is launched here.
    if code is None:
        return 0
    if isinstance(code, int):
        value = int.__int__(code)
        bits = 8 * _r30x_struct.calcsize('l')
        if value < -(1 << (bits - 1)) or value >= (1 << (bits - 1)):
            return 255
        return value & 255
    print(code, file=stderr)
    return 1


def _r30x_cli(R, raw, expected_table, root, serial):
    entry = _r30x_entry_code(R)
    source = root / ('input-' + str(serial) + '.json')
    source.write_text(json.dumps(raw, sort_keys=True))
    out = root / ('output-' + str(serial))
    stdout, stderr, attempted = io.StringIO(), io.StringIO(), []

    def unexpected(label):
        def refuse_before_effect(*args, **kwargs):
            attempted.append(label)
            raise AssertionError('pure raw extraction attempted ' + label)
        return refuse_before_effect

    # Only IO primitives the actual edited expressions can dispatch. Global
    # open is shadowed before an existing-FD/file open, while legitimate private
    # Path.read_text/write_text and dump output remain real and are checked.
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(R, 'command', new=unexpected('command')))
        stack.enter_context(patch.object(R, 'sealed_set', new=unexpected('sealed_set')))
        stack.enter_context(patch.object(R.subprocess, 'run', new=unexpected('subprocess.run')))
        stack.enter_context(patch.object(R.subprocess, 'Popen', new=unexpected('subprocess.Popen')))
        stack.enter_context(patch.object(R, 'open', new=unexpected('global.open'), create=True))
        stack.enter_context(patch.object(R, '__name__', '__main__'))
        stack.enter_context(patch.dict(R.sys.modules, {'__main__': R}))
        stack.enter_context(patch.object(R.sys, 'argv',
            [R.__file__, '--extract', str(source), '--out', str(out)]))
        stack.enter_context(contextlib.redirect_stdout(stdout))
        stack.enter_context(contextlib.redirect_stderr(stderr))
        try:
            exec(entry, R.__dict__)
        except SystemExit as stopped:
            rc = _r30x_process_status(stopped.code, stderr)
        else:
            raise AssertionError('actual production entry guard did not exit')
        # No Exception/Refusal catch: an unhandled product error reaches run()'s
        # ordinary named-red boundary. It is never relabeled as refusal2 here.
    raw_path, decision_path = out / 'raw.json', out / 'decision.json'
    raw_matches = raw_path.exists() and json.loads(raw_path.read_text()) == raw
    decision_exists = decision_path.exists()
    decision = json.loads(decision_path.read_text()) if decision_exists else None
    whole = {p.name: json.loads(p.read_text()) for p in out.iterdir()
             if p.name.endswith('-population.json')}
    wanted_whole = ({name + '-population.json': value for name, value in
                     expected_table['population_tables'].items()}
                    if expected_table is not None else {})
    # Match actual machine outcome records, not arbitrary diagnostic wording.
    # Additive duty values are checked in the full literal decision table.
    def machine_lines(stream):
        return tuple(line.split(';', 1)[0] for line in stream.getvalue().splitlines()
                     if line.startswith(('OUTCOME ', 'DRY OUTCOME ')))
    return (rc, bool(raw_matches), decision_exists, decision == expected_table,
            whole == wanted_whole, machine_lines(stdout), machine_lines(stderr),
            tuple(attempted))


def _r30x_single(R, spec):
    expected = (_r30x_data['expected_tables']['INCOMPLETE']
                if spec['mode'] == 'INCOMPLETE' else None)
    with tempfile.TemporaryDirectory() as tmp:
        return _r30x_cli(R, _r30x_raw(spec), expected, Path(tmp), 0)


def _r30x_positive(R, mode):
    template = 'COMPLETE_RAW_BASE' if mode == 'COMPLETE' else 'INCOMPLETE_ONE_NE_RAW'
    with tempfile.TemporaryDirectory() as tmp:
        return _r30x_cli(R, copy.deepcopy(_r30x_data['templates'][template]),
                        _r30x_data['expected_tables'][mode], Path(tmp), 0)


def _r30x_status_matrix(R):
    rows = _r30x_data['control_status_tokens']
    if len(rows) != 230 or not rows or len({row[0] for row in rows}) != 230:
        raise AssertionError('exact nonempty230 literal status matrix required')
    template = _r30x_data['templates']['COMPLETE_RAW_BASE']
    template_before = json.dumps(template, sort_keys=True)
    examined, failures = 0, []
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for identity, token in rows:
                raw = dict(template)
                raw['controls'] = dict(template['controls'])
                raw['controls']['a'] = 1
                raw['status'] = token
                observed = _r30x_cli(R, raw, None, root, identity)
                examined += 1
                if observed != (2, True, False, True, True, (), (), ()):
                    failures.append((identity, observed))
                    return examined, failures
    finally:
        if json.dumps(template, sort_keys=True) != template_before:
            raise AssertionError('status matrix changed its shared literal template')
    return examined, failures


_round5_prefix100251_public_evidence_prior_cases = cases


def cases(R):
    yield from _round5_prefix100251_public_evidence_prior_cases(R)
    yield ('Extract-evidence-complete-public-CLI-green',
           lambda: _r30x_positive(R, 'COMPLETE'),
           (0, True, True, True, True,
            tuple(_r30x_data['expected_complete_outcomes']), (), ()))
    yield ('Extract-evidence-legitimate-not-evaluated-INCOMPLETE',
           lambda: _r30x_positive(R, 'INCOMPLETE'),
           (0, True, True, True, True, (), (), ()))
    if not _r30x_data['cases']:
        raise AssertionError('public evidence fixture table cannot be empty')
    for spec in _r30x_data['cases']:
        want = ((0, True, True, True, True, (), (), ())
                if spec['mode'] == 'INCOMPLETE' else
                (2, True, False, True, True, (), (), ()))
        yield spec['name'], lambda spec=spec: _r30x_single(R, spec), want
    yield ('Extract-evidence-nonboolean-control-status-token-matrix',
           lambda: _r30x_status_matrix(R), (230, []))

# SOURCE-ONLY v4 D11-corrected normative R5 suffix; current diagnostic_line source.
#866-era13inputs/437mapping are preserved externally as HISTORY, not newresults.
# No private diagnostic suffix, cross-record rejudging or old437kill assertion.
_r31v4_data = json.loads('{"cases":[{"actual_future_input_bytes_sha256":"f317304662def25645a93ab705bbdf695815cb5ce0cc1b8f6549a690e0ba2654","canonical_data_sha256":"abe074374dee408b25ef95c0e289dbd6df307d50b9757d641fe8722d84bbb62e","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"entry":"F-empty-H1-secondary","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":2,"decision_json_exists":false,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":0,"refusal_phase_prefix_required":true,"stdout_empty_on_refusal":true,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{}},"calibration":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"hcal","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-empty-H1-secondary","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"baf88fb04bc5963762bb89ffedb53e0ef7299322a9b609418f28a6117fc2b8e2","canonical_data_sha256":"bde4e86a982b2315bfec86c5dee9a3eec364f5cd40ebb8d2b1804c8f5fbad76b","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"entry":"F-empty-primary","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":2,"decision_json_exists":false,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":0,"refusal_phase_prefix_required":true,"stdout_empty_on_refusal":true,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"calibration":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"hcal","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-empty-primary","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"d46bb9ffab0fe80bb59eff8e3afb832726e8bbd0b0a2cd3898c408329728d4cd","canonical_data_sha256":"536f8947f9639a3db00a7391444edbb933142897123f7fba6c63daaaadf3e0f7","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"entry":"F-nonbool-capability","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":2,"decision_json_exists":false,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":0,"refusal_phase_prefix_required":true,"stdout_empty_on_refusal":true,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"calibration":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":0,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"hcal","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-nonbool-capability","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"efbb6f30d10b67dba69f2c255e76acd2f261b849ecc89a2aa775702bd250af61","canonical_data_sha256":"baf89a13b8aa935c050f59aeab9ff238f8775d53969ecbd171a57387c96e660b","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"entry":"F-missing-floor_exit","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":2,"decision_json_exists":false,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":0,"refusal_phase_prefix_required":true,"stdout_empty_on_refusal":true,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"calibration":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[]},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"hcal","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-missing-floor_exit","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"0a6d3a3334fee8ffeaa127cb7902876ff93417bdcec78da04a20d8e5a9e92333","canonical_data_sha256":"86b1a4e0799ed8a545ae6b0b8ff3dad9cf411e13ad6303f0069b352debf0fc67","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"entry":"F-missing-declarations","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":2,"decision_json_exists":false,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":0,"refusal_phase_prefix_required":true,"stdout_empty_on_refusal":true,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"calibration":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"hcal","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-missing-declarations","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"9f22d1fe0948c145709d8517f32c843e8546319adae9ca53ad7ddce9772c8783","canonical_data_sha256":"f503986396c34ab01cbe6eb14eba7c69d6380684e84ac61c2108c02ccf23aeb7","expected_public":{"decision_json_exists":true,"population_files_match":true,"process_exit":0,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":["DRY OUTCOME converged: R3-STD","DRY OUTCOME stable: R3-STD","DRY OUTCOME improving: R3-STD","DRY OUTCOME oscillating: R3-STD","DRY OUTCOME diverging: R3-STD","DRY OUTCOME equilibrium: R3-STD"]},"expected_table":{"dry":true,"population_tables":{"calibration":{"absent":[["INC","literal-row",1,"converged"],["INC","literal-row",1,"stable"],["INC","literal-row",1,"improving"],["INC","literal-row",1,"oscillating"],["INC","literal-row",1,"diverging"],["INC","literal-row",1,"equilibrium"],["ANCHOR","literal-row",1,"converged"],["ANCHOR","literal-row",1,"stable"],["ANCHOR","literal-row",1,"improving"],["ANCHOR","literal-row",1,"oscillating"],["ANCHOR","literal-row",1,"diverging"],["ANCHOR","literal-row",1,"equilibrium"],["STD","literal-row",1,"converged"],["STD","literal-row",1,"stable"],["STD","literal-row",1,"improving"],["STD","literal-row",1,"oscillating"],["STD","literal-row",1,"diverging"],["STD","literal-row",1,"equilibrium"],["STD\'","literal-row",1,"converged"],["STD\'","literal-row",1,"stable"],["STD\'","literal-row",1,"improving"],["STD\'","literal-row",1,"oscillating"],["STD\'","literal-row",1,"diverging"],["STD\'","literal-row",1,"equilibrium"],["STD\'\'","literal-row",1,"equilibrium"],["D2","literal-row",1,"improving"],["REF","literal-row",1,"converged"],["REF","literal-row",1,"stable"],["REF","literal-row",1,"improving"],["REF","literal-row",1,"oscillating"],["REF","literal-row",1,"diverging"],["REF","literal-row",1,"equilibrium"],["C0","literal-row",1,"converged"],["C0","literal-row",1,"stable"],["C0","literal-row",1,"improving"],["C0","literal-row",1,"oscillating"],["C0","literal-row",1,"diverging"],["C0","literal-row",1,"equilibrium"],["C1","literal-row",1,"converged"],["C1","literal-row",1,"stable"],["C1","literal-row",1,"improving"],["C1","literal-row",1,"oscillating"],["C1","literal-row",1,"diverging"],["C1","literal-row",1,"equilibrium"],["PERSIST","literal-row",1,"converged"],["PERSIST","literal-row",1,"stable"],["PERSIST","literal-row",1,"equilibrium"],["T001","literal-row",1,"converged"]],"confusion":{"[\\"ANCHOR\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"CF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"D2\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"R3\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"T001\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"W4\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1]},"disagreements":[]},"hcal":{"absent":[["INC","literal-row",1,"converged"],["INC","literal-row",1,"stable"],["INC","literal-row",1,"improving"],["INC","literal-row",1,"oscillating"],["INC","literal-row",1,"diverging"],["INC","literal-row",1,"equilibrium"],["ANCHOR","literal-row",1,"converged"],["ANCHOR","literal-row",1,"stable"],["ANCHOR","literal-row",1,"improving"],["ANCHOR","literal-row",1,"oscillating"],["ANCHOR","literal-row",1,"diverging"],["ANCHOR","literal-row",1,"equilibrium"],["STD","literal-row",1,"converged"],["STD","literal-row",1,"stable"],["STD","literal-row",1,"improving"],["STD","literal-row",1,"oscillating"],["STD","literal-row",1,"diverging"],["STD","literal-row",1,"equilibrium"],["STD\'","literal-row",1,"converged"],["STD\'","literal-row",1,"stable"],["STD\'","literal-row",1,"improving"],["STD\'","literal-row",1,"oscillating"],["STD\'","literal-row",1,"diverging"],["STD\'","literal-row",1,"equilibrium"],["STD\'\'","literal-row",1,"equilibrium"],["D2","literal-row",1,"improving"],["REF","literal-row",1,"converged"],["REF","literal-row",1,"stable"],["REF","literal-row",1,"improving"],["REF","literal-row",1,"oscillating"],["REF","literal-row",1,"diverging"],["REF","literal-row",1,"equilibrium"],["C0","literal-row",1,"converged"],["C0","literal-row",1,"stable"],["C0","literal-row",1,"improving"],["C0","literal-row",1,"oscillating"],["C0","literal-row",1,"diverging"],["C0","literal-row",1,"equilibrium"],["C1","literal-row",1,"converged"],["C1","literal-row",1,"stable"],["C1","literal-row",1,"improving"],["C1","literal-row",1,"oscillating"],["C1","literal-row",1,"diverging"],["C1","literal-row",1,"equilibrium"],["PERSIST","literal-row",1,"converged"],["PERSIST","literal-row",1,"stable"],["PERSIST","literal-row",1,"equilibrium"],["T001","literal-row",1,"converged"]],"confusion":{"[\\"ANCHOR\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"CF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"D2\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"R3\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"T001\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"W4\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1]},"disagreements":[]}},"predicates":{"converged":{"STD_p_on_H2":false,"ship":"R3-STD","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","NOT EVALUATED"],["2 vs INC","PASS"],["2 vs R3-STD","PASS"],["3 safety","NOT EVALUATED"],["4 trivial floor","NOT EVALUATED"],["5 unit invariance","PASS"],["6 existing gates","FAIL"]],"verdict":"FAIL"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"diverging":{"STD_p_on_H2":false,"ship":"R3-STD","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","NOT EVALUATED"],["2 vs INC","PASS"],["3 safety","NOT EVALUATED"],["4 trivial floor","NOT EVALUATED"],["5 unit invariance","PASS"],["6 existing gates","FAIL"]],"verdict":"FAIL"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"equilibrium":{"STD_p_on_H2":false,"ship":"R3-STD","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","NOT EVALUATED"],["2 vs INC","PASS"],["3 safety","NOT EVALUATED"],["4 trivial floor","NOT EVALUATED"],["5 unit invariance","PASS"],["6 existing gates","FAIL"]],"verdict":"FAIL"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"improving":{"STD_p_on_H2":false,"ship":"R3-STD","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","NOT EVALUATED"],["2 vs INC","PASS"],["4 trivial floor","NOT EVALUATED"],["5 unit invariance","PASS"],["6 existing gates","FAIL"]],"verdict":"FAIL"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"oscillating":{"STD_p_on_H2":false,"ship":"R3-STD","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","NOT EVALUATED"],["2 vs INC","PASS"],["4 trivial floor","NOT EVALUATED"],["5 unit invariance","PASS"],["6 existing gates","FAIL"]],"verdict":"FAIL"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"stable":{"STD_p_on_H2":false,"ship":"R3-STD","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","NOT EVALUATED"],["2 vs INC","PASS"],["2 vs R3-STD","PASS"],["3 safety","NOT EVALUATED"],["4 trivial floor","NOT EVALUATED"],["5 unit invariance","PASS"],["6 existing gates","FAIL"]],"verdict":"FAIL"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}}},"resamples":1000,"seed":1758,"status":"COMPLETE"},"input_authority":{"entry":"F-empty-capability-map","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":0,"decision_json_exists":true,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":6,"refusal_phase_prefix_required":false,"stdout_empty_on_refusal":false,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"calibration":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","NOT EVALUATED","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","NOT EVALUATED","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","NOT EVALUATED","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","NOT EVALUATED","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","NOT EVALUATED","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","NOT EVALUATED","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","NOT EVALUATED","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","NOT EVALUATED","literal independent registered rule"],["4 trivial floor","NOT EVALUATED","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","FAIL","literal independent registered rule"]],"verdict":"FAIL"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}}},"preflight":{"R3":{"capabilities":{},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"hcal","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-missing-R3-capabilities-rule6-FAIL-fallback","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"projection_scope":"Missing capability unit projection: recorded R3 rule6 and overall verdictFAIL, standard subjectPASS, exact R30R-2 fallback. Does not require rerunning preflight/control judging in extraction. Original emptycaps+rule6PASS input remains archived and unendorsed.","source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"40788ca0fe48f2c5604fe97ae3607a50d0ed1cce924dea99778dd70ad9e764cc","canonical_data_sha256":"ea09e2a2497ed3eb9a3d42d4bcb23cd8a97e5fd96a988ac19399dab92972e7da","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"entry":"F-invalid-secondary-decisions","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":2,"decision_json_exists":false,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":0,"refusal_phase_prefix_required":true,"stdout_empty_on_refusal":true,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"calibration":{"decisions":{},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"hcal","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-invalid-secondary-decisions","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"d8c78ff6b73c1e40c91e813749c6bbb8f322245d6ba8926b44d6f4e5b709b5ba","canonical_data_sha256":"a09a2b3feed0f4b75e8cefd7773e1f170aae98044c0404052c28e42883b2118d","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"entry":"F-secondary-judge-rc","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":2,"decision_json_exists":false,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":0,"refusal_phase_prefix_required":true,"stdout_empty_on_refusal":true,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"calibration":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":1,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"hcal","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-secondary-judge-rc","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"3aa311a663a9d5fb0d71b2a02d77b4877cf2fc50ab3d34fc6769c20e951516d8","canonical_data_sha256":"5d5ced9048be6f049467184142816b36afc5415ac32a1db7945c95f50afe1071","expected_public":{"decision_json_exists":true,"population_files_match":true,"process_exit":0,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":["OUTCOME converged: R3","OUTCOME stable: R3","OUTCOME improving: R3","OUTCOME oscillating: R3","OUTCOME diverging: R3","OUTCOME equilibrium: R3"]},"expected_table":{"dry":false,"population_tables":{"H1":{"absent":[["INC","literal-row",1,"converged"],["INC","literal-row",1,"stable"],["INC","literal-row",1,"improving"],["INC","literal-row",1,"oscillating"],["INC","literal-row",1,"diverging"],["INC","literal-row",1,"equilibrium"],["ANCHOR","literal-row",1,"converged"],["ANCHOR","literal-row",1,"stable"],["ANCHOR","literal-row",1,"improving"],["ANCHOR","literal-row",1,"oscillating"],["ANCHOR","literal-row",1,"diverging"],["ANCHOR","literal-row",1,"equilibrium"],["STD","literal-row",1,"converged"],["STD","literal-row",1,"stable"],["STD","literal-row",1,"improving"],["STD","literal-row",1,"oscillating"],["STD","literal-row",1,"diverging"],["STD","literal-row",1,"equilibrium"],["STD\'","literal-row",1,"converged"],["STD\'","literal-row",1,"stable"],["STD\'","literal-row",1,"improving"],["STD\'","literal-row",1,"oscillating"],["STD\'","literal-row",1,"diverging"],["STD\'","literal-row",1,"equilibrium"],["STD\'\'","literal-row",1,"equilibrium"],["D2","literal-row",1,"improving"],["REF","literal-row",1,"converged"],["REF","literal-row",1,"stable"],["REF","literal-row",1,"improving"],["REF","literal-row",1,"oscillating"],["REF","literal-row",1,"diverging"],["REF","literal-row",1,"equilibrium"],["C0","literal-row",1,"converged"],["C0","literal-row",1,"stable"],["C0","literal-row",1,"improving"],["C0","literal-row",1,"oscillating"],["C0","literal-row",1,"diverging"],["C0","literal-row",1,"equilibrium"],["C1","literal-row",1,"converged"],["C1","literal-row",1,"stable"],["C1","literal-row",1,"improving"],["C1","literal-row",1,"oscillating"],["C1","literal-row",1,"diverging"],["C1","literal-row",1,"equilibrium"],["PERSIST","literal-row",1,"converged"],["PERSIST","literal-row",1,"stable"],["PERSIST","literal-row",1,"equilibrium"],["T001","literal-row",1,"converged"]],"confusion":{"[\\"ANCHOR\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"CF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"D2\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"R3\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"T001\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"W4\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1]},"disagreements":[]},"calibration":{"absent":[["INC","literal-row",1,"converged"],["INC","literal-row",1,"stable"],["INC","literal-row",1,"improving"],["INC","literal-row",1,"oscillating"],["INC","literal-row",1,"diverging"],["INC","literal-row",1,"equilibrium"],["ANCHOR","literal-row",1,"converged"],["ANCHOR","literal-row",1,"stable"],["ANCHOR","literal-row",1,"improving"],["ANCHOR","literal-row",1,"oscillating"],["ANCHOR","literal-row",1,"diverging"],["ANCHOR","literal-row",1,"equilibrium"],["STD","literal-row",1,"converged"],["STD","literal-row",1,"stable"],["STD","literal-row",1,"improving"],["STD","literal-row",1,"oscillating"],["STD","literal-row",1,"diverging"],["STD","literal-row",1,"equilibrium"],["STD\'","literal-row",1,"converged"],["STD\'","literal-row",1,"stable"],["STD\'","literal-row",1,"improving"],["STD\'","literal-row",1,"oscillating"],["STD\'","literal-row",1,"diverging"],["STD\'","literal-row",1,"equilibrium"],["STD\'\'","literal-row",1,"equilibrium"],["D2","literal-row",1,"improving"],["REF","literal-row",1,"converged"],["REF","literal-row",1,"stable"],["REF","literal-row",1,"improving"],["REF","literal-row",1,"oscillating"],["REF","literal-row",1,"diverging"],["REF","literal-row",1,"equilibrium"],["C0","literal-row",1,"converged"],["C0","literal-row",1,"stable"],["C0","literal-row",1,"improving"],["C0","literal-row",1,"oscillating"],["C0","literal-row",1,"diverging"],["C0","literal-row",1,"equilibrium"],["C1","literal-row",1,"converged"],["C1","literal-row",1,"stable"],["C1","literal-row",1,"improving"],["C1","literal-row",1,"oscillating"],["C1","literal-row",1,"diverging"],["C1","literal-row",1,"equilibrium"],["PERSIST","literal-row",1,"converged"],["PERSIST","literal-row",1,"stable"],["PERSIST","literal-row",1,"equilibrium"],["T001","literal-row",1,"converged"]],"confusion":{"[\\"ANCHOR\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"CF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"D2\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"R3\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"T001\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"W4\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1]},"disagreements":[]},"hcal":{"absent":[["INC","literal-row",1,"converged"],["INC","literal-row",1,"stable"],["INC","literal-row",1,"improving"],["INC","literal-row",1,"oscillating"],["INC","literal-row",1,"diverging"],["INC","literal-row",1,"equilibrium"],["ANCHOR","literal-row",1,"converged"],["ANCHOR","literal-row",1,"stable"],["ANCHOR","literal-row",1,"improving"],["ANCHOR","literal-row",1,"oscillating"],["ANCHOR","literal-row",1,"diverging"],["ANCHOR","literal-row",1,"equilibrium"],["STD","literal-row",1,"converged"],["STD","literal-row",1,"stable"],["STD","literal-row",1,"improving"],["STD","literal-row",1,"oscillating"],["STD","literal-row",1,"diverging"],["STD","literal-row",1,"equilibrium"],["STD\'","literal-row",1,"converged"],["STD\'","literal-row",1,"stable"],["STD\'","literal-row",1,"improving"],["STD\'","literal-row",1,"oscillating"],["STD\'","literal-row",1,"diverging"],["STD\'","literal-row",1,"equilibrium"],["STD\'\'","literal-row",1,"equilibrium"],["D2","literal-row",1,"improving"],["REF","literal-row",1,"converged"],["REF","literal-row",1,"stable"],["REF","literal-row",1,"improving"],["REF","literal-row",1,"oscillating"],["REF","literal-row",1,"diverging"],["REF","literal-row",1,"equilibrium"],["C0","literal-row",1,"converged"],["C0","literal-row",1,"stable"],["C0","literal-row",1,"improving"],["C0","literal-row",1,"oscillating"],["C0","literal-row",1,"diverging"],["C0","literal-row",1,"equilibrium"],["C1","literal-row",1,"converged"],["C1","literal-row",1,"stable"],["C1","literal-row",1,"improving"],["C1","literal-row",1,"oscillating"],["C1","literal-row",1,"diverging"],["C1","literal-row",1,"equilibrium"],["PERSIST","literal-row",1,"converged"],["PERSIST","literal-row",1,"stable"],["PERSIST","literal-row",1,"equilibrium"],["T001","literal-row",1,"converged"]],"confusion":{"[\\"ANCHOR\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"ANCHOR\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C0\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"C1\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"CF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"CF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"D2\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"INC\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"PERSIST\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"R3\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"R3-STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"REF\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"REF\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"STD\'\'\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"T001\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,0],"[\\"W4\\", \\"converged\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"diverging\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"equilibrium\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"improving\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"oscillating\\", \\"F15 literal fixture\\"]":[0,0,0,1],"[\\"W4\\", \\"stable\\", \\"F15 literal fixture\\"]":[0,0,0,1]},"disagreements":[]}},"predicates":{"converged":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["2 vs R3-STD","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"diverging":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"equilibrium":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"improving":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"oscillating":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}},"stable":{"STD_p_on_H2":false,"ship":"R3","silent_wrong":false,"subjects":{"R3":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["2 vs R3-STD","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"},"R3-STD":{"rules":[["1 standard parity","PASS"],["2 vs INC","PASS"],["3 safety","PASS"],["4 trivial floor","PASS"],["5 unit invariance","PASS"],["6 existing gates","PASS"]],"verdict":"PASS"}}}},"resamples":1000,"seed":1758,"status":"COMPLETE"},"input_authority":{"entry":"F-primary-versus-last-decisions","fixture_plan":{"bytes":559337,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-literal-CLI-fixture-plans.json","sha256":"6af2c4b1a7b250c7ca83f11aa8c87dd5f6bbf7333249cc7f19a15167043629b0"},"original_oracle":{"actual_exit":0,"decision_json_exists":true,"exact_private_exception_class_or_message_suffix":false,"outcome_lines":6,"refusal_phase_prefix_required":false,"stdout_empty_on_refusal":false,"traceback_allowed":false}},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":false,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"calibration":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}},"hcal":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","NOT EVALUATED","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"INCOMPLETE"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal independent registered rule"],["2 vs INC","FAIL","literal independent registered rule"],["2 vs R3-STD","PASS","literal independent registered rule"],["3 safety","PASS","literal independent registered rule"],["4 trivial floor","PASS","literal independent registered rule"],["5 unit invariance","PASS","literal independent registered rule"],["6 existing gates","PASS","literal independent registered rule"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal-row@1":{"converged":["MATH",false,"literal"],"diverging":["MATH",false,"literal"],"equilibrium":["MATH",false,"literal"],"improving":["MATH",false,"literal"],"oscillating":["MATH",false,"literal"],"stable":["MATH",false,"literal"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal-row",1,"converged",false],["R3","literal-row",1,"stable",false],["R3","literal-row",1,"improving",false],["R3","literal-row",1,"oscillating",false],["R3","literal-row",1,"diverging",false],["R3","literal-row",1,"equilibrium",false],["R3-STD","literal-row",1,"converged",false],["R3-STD","literal-row",1,"stable",false],["R3-STD","literal-row",1,"improving",false],["R3-STD","literal-row",1,"oscillating",false],["R3-STD","literal-row",1,"diverging",false],["R3-STD","literal-row",1,"equilibrium",false],["CF","literal-row",1,"converged",false],["CF","literal-row",1,"stable",false],["CF","literal-row",1,"improving",false],["CF","literal-row",1,"oscillating",false],["CF","literal-row",1,"diverging",false],["CF","literal-row",1,"equilibrium",false],["W4","literal-row",1,"converged",false],["W4","literal-row",1,"stable",false],["W4","literal-row",1,"improving",false],["W4","literal-row",1,"oscillating",false],["W4","literal-row",1,"diverging",false],["W4","literal-row",1,"equilibrium",false]],"rows":{"literal-row":{"checkpoints":[1],"family":"F15 literal fixture","id":"literal-row"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"COMPLETE"},"name":"Extract-R5-primary-versus-last-decisions","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"2e3cd8a29531be587aa1291e0223e362ed2db79013f6d760e62010fc973dfc25","canonical_data_sha256":"44b14fda9b5888daf11f4069f6ddde35fc472b38c2dbc8b26930bc5dc962f632","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"ID":107617,"counterexamples":{"bytes":370118,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-comparison-counterexamples.json","sha256":"f997aae9da92248c3e2fe131e47d3807135df2b88653ca477482574e3a694217"},"entry":"additional_variable_print_control"},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal@1":{"converged":["MATH",false,"literal fixture"],"diverging":["MATH",false,"literal fixture"],"equilibrium":["MATH",false,"literal fixture"],"improving":["MATH",false,"literal fixture"],"oscillating":["MATH",false,"literal fixture"],"stable":["MATH",false,"literal fixture"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal",1,"converged",false],["R3","literal",1,"stable",false],["R3","literal",1,"improving",false],["R3","literal",1,"oscillating",false],["R3","literal",1,"diverging",false],["R3","literal",1,"equilibrium",false],["R3-STD","literal",1,"converged",false],["R3-STD","literal",1,"stable",false],["R3-STD","literal",1,"improving",false],["R3-STD","literal",1,"oscillating",false],["R3-STD","literal",1,"diverging",false],["R3-STD","literal",1,"equilibrium",false],["INC","literal",1,"converged",false],["INC","literal",1,"stable",false],["INC","literal",1,"improving",false],["INC","literal",1,"oscillating",false],["INC","literal",1,"diverging",false],["INC","literal",1,"equilibrium",false],["ANCHOR","literal",1,"converged",false],["ANCHOR","literal",1,"stable",false],["ANCHOR","literal",1,"improving",false],["ANCHOR","literal",1,"oscillating",false],["ANCHOR","literal",1,"diverging",false],["ANCHOR","literal",1,"equilibrium",false],["CF","literal",1,"converged",false],["CF","literal",1,"stable",false],["CF","literal",1,"improving",false],["CF","literal",1,"oscillating",false],["CF","literal",1,"diverging",false],["CF","literal",1,"equilibrium",false],["W4","literal",1,"converged",false],["W4","literal",1,"stable",false],["W4","literal",1,"improving",false],["W4","literal",1,"oscillating",false],["W4","literal",1,"diverging",false],["W4","literal",1,"equilibrium",false],["STD","literal",1,"converged",false],["STD","literal",1,"stable",false],["STD","literal",1,"improving",false],["STD","literal",1,"oscillating",false],["STD","literal",1,"diverging",false],["STD","literal",1,"equilibrium",false],["STD\'","literal",1,"converged",false],["STD\'","literal",1,"stable",false],["STD\'","literal",1,"improving",false],["STD\'","literal",1,"oscillating",false],["STD\'","literal",1,"diverging",false],["STD\'","literal",1,"equilibrium",false],["REF","literal",1,"converged",false],["REF","literal",1,"stable",false],["REF","literal",1,"improving",false],["REF","literal",1,"oscillating",false],["REF","literal",1,"diverging",false],["REF","literal",1,"equilibrium",false],["C0","literal",1,"converged",false],["C0","literal",1,"stable",false],["C0","literal",1,"improving",false],["C0","literal",1,"oscillating",false],["C0","literal",1,"diverging",false],["C0","literal",1,"equilibrium",false],["C1","literal",1,"converged",false],["C1","literal",1,"stable",false],["C1","literal",1,"improving",false],["C1","literal",1,"oscillating",false],["C1","literal",1,"diverging",false],["C1","literal",1,"equilibrium",false],["STD\'\'","literal",1,"equilibrium",false],["D2","literal",1,"improving",false],["PERSIST","literal",1,"converged",false],["PERSIST","literal",1,"stable",false],["PERSIST","literal",1,"equilibrium",false],["T001","literal",1,"converged",false]],"rows":{"literal":{"checkpoints":[1],"family":"F15 literal","id":"literal"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"\\nOUTCOME converged: R3\\n"},"name":"Extract-R5-refused-selected-status-cannot-emit-outcome","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"projection_scope":"Strict R5 refusal regression: selected raw.status carries actual newline/OUTCOME but both streams must have no anchoredOUTCOME under new ASCII refusal rendering. No old stderr echo API is retained.","source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}},{"actual_future_input_bytes_sha256":"abaa444db5abefa1e9ab988b6f63b0accf80e62026cb15caa94716d2f3088f4f","canonical_data_sha256":"476856a6002c5386a87914f965a5d421f419902f048a645c0fff1954dd37c3ec","expected_public":{"decision_json_exists":false,"population_files_match":true,"process_exit":2,"raw_copy_matches":true,"stderr_machine_outcomes":[],"stdout_machine_outcomes":[]},"expected_table":null,"input_authority":{"counterexamples":{"bytes":370118,"path":"/home/jon/src/wt/briefs/out/r3-0r/round5-analysis/protocol-fresh-prefix110001-comparison-counterexamples.json","sha256":"f997aae9da92248c3e2fe131e47d3807135df2b88653ca477482574e3a694217"},"entry":"reviewed_literal_bases/MISMATCHED-STATUS"},"is_union_payload_case":false,"literal_raw":{"controls":{"a":true,"b":true,"c1":true,"c2":true},"dry":true,"populations":{"H1":{"decisions":{"CF":{"converged":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"}},"R3":{"converged":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"}},"R3-STD":{"converged":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"diverging":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"equilibrium":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"improving":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"oscillating":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"},"stable":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"PASS"}},"W4":{"converged":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"diverging":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"equilibrium":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"improving":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"oscillating":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"},"stable":{"rules":[["1 standard parity","PASS","literal fixture"],["2 vs INC","FAIL","literal fixture"],["2 vs R3-STD","PASS","literal fixture"],["3 safety","PASS","literal fixture"],["4 trivial floor","PASS","literal fixture"],["5 unit invariance","PASS","literal fixture"],["6 existing gates","PASS","literal fixture"]],"verdict":"FAIL"}}},"diffs":[["STD","T001","converged","1/20","0.001","0.1","0"]],"findings":[],"judge_rc":0,"labels":{"literal@1":{"converged":["MATH",false,"literal fixture"],"diverging":["MATH",false,"literal fixture"],"equilibrium":["MATH",false,"literal fixture"],"improving":["MATH",false,"literal fixture"],"oscillating":["MATH",false,"literal fixture"],"stable":["MATH",false,"literal fixture"]}},"points":[["CF","converged","1/2"],["CF","stable","1/2"],["CF","improving","1/2"],["CF","oscillating","1/2"],["CF","diverging","1/2"],["CF","equilibrium","1/2"]],"readings":[["R3","literal",1,"converged",false],["R3","literal",1,"stable",false],["R3","literal",1,"improving",false],["R3","literal",1,"oscillating",false],["R3","literal",1,"diverging",false],["R3","literal",1,"equilibrium",false],["R3-STD","literal",1,"converged",false],["R3-STD","literal",1,"stable",false],["R3-STD","literal",1,"improving",false],["R3-STD","literal",1,"oscillating",false],["R3-STD","literal",1,"diverging",false],["R3-STD","literal",1,"equilibrium",false],["INC","literal",1,"converged",false],["INC","literal",1,"stable",false],["INC","literal",1,"improving",false],["INC","literal",1,"oscillating",false],["INC","literal",1,"diverging",false],["INC","literal",1,"equilibrium",false],["ANCHOR","literal",1,"converged",false],["ANCHOR","literal",1,"stable",false],["ANCHOR","literal",1,"improving",false],["ANCHOR","literal",1,"oscillating",false],["ANCHOR","literal",1,"diverging",false],["ANCHOR","literal",1,"equilibrium",false],["CF","literal",1,"converged",false],["CF","literal",1,"stable",false],["CF","literal",1,"improving",false],["CF","literal",1,"oscillating",false],["CF","literal",1,"diverging",false],["CF","literal",1,"equilibrium",false],["W4","literal",1,"converged",false],["W4","literal",1,"stable",false],["W4","literal",1,"improving",false],["W4","literal",1,"oscillating",false],["W4","literal",1,"diverging",false],["W4","literal",1,"equilibrium",false],["STD","literal",1,"converged",false],["STD","literal",1,"stable",false],["STD","literal",1,"improving",false],["STD","literal",1,"oscillating",false],["STD","literal",1,"diverging",false],["STD","literal",1,"equilibrium",false],["STD\'","literal",1,"converged",false],["STD\'","literal",1,"stable",false],["STD\'","literal",1,"improving",false],["STD\'","literal",1,"oscillating",false],["STD\'","literal",1,"diverging",false],["STD\'","literal",1,"equilibrium",false],["REF","literal",1,"converged",false],["REF","literal",1,"stable",false],["REF","literal",1,"improving",false],["REF","literal",1,"oscillating",false],["REF","literal",1,"diverging",false],["REF","literal",1,"equilibrium",false],["C0","literal",1,"converged",false],["C0","literal",1,"stable",false],["C0","literal",1,"improving",false],["C0","literal",1,"oscillating",false],["C0","literal",1,"diverging",false],["C0","literal",1,"equilibrium",false],["C1","literal",1,"converged",false],["C1","literal",1,"stable",false],["C1","literal",1,"improving",false],["C1","literal",1,"oscillating",false],["C1","literal",1,"diverging",false],["C1","literal",1,"equilibrium",false],["STD\'\'","literal",1,"equilibrium",false],["D2","literal",1,"improving",false],["PERSIST","literal",1,"converged",false],["PERSIST","literal",1,"stable",false],["PERSIST","literal",1,"equilibrium",false],["T001","literal",1,"converged",false]],"rows":{"literal":{"checkpoints":[1],"family":"F15 literal","id":"literal"}}}},"preflight":{"R3":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0},"R3-STD":{"capabilities":{"ieee":true,"int64":true},"declarations":[],"floor_exit":0}},"primary":"H1","resamples":1000,"seed":1758,"status":"WRONG"},"name":"Extract-R5-status-mismatch-safe-channel-control","normative_source":{"bytes":36863,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"3d0426213095cc6e779bf5f9b84a1a38949798457edb31bb4b66334701cfb294"},"source_before_revision":{"bytes":36662,"path":"/home/jon/src/wt/es-r30r/tools/observer_oracle/reveal.py","sha256":"866ec6e349ad703fa9b54fe76532026581c4aa2846f8e04c9a46c046eea7c80f"}}]}')


def _r31v4_literal_cli(R, spec):
    with tempfile.TemporaryDirectory() as tmp:
        return _r30x_cli(R, copy.deepcopy(spec['literal_raw']),
                        spec['expected_table'], Path(tmp), 0)


_round5_prefix110001_v4_normative_prior_cases = cases


def cases(R):
    yield from _round5_prefix110001_v4_normative_prior_cases(R)
    rows = _r31v4_data['cases']
    if len(rows) != 11 or not rows or len({spec['name'] for spec in rows}) != 11:
        raise AssertionError('exact nonempty11 normative R5 projection fixtures required')
    for spec in rows:
        expected = spec['expected_public']
        want = (expected['process_exit'], True, expected['decision_json_exists'],
                True, True, tuple(expected['stdout_machine_outcomes']),
                tuple(expected['stderr_machine_outcomes']), ())
        yield spec['name'], lambda spec=spec: _r31v4_literal_cli(R, spec), want

# SOURCE-ONLY. The actual flagged IDs92746/92754/92783 reached this old
# pure extraction witness before any appended fixture. Preserve the real call.
_round5_pure_extract_old_witness_prior_cases = cases


def cases(R):
    seen = 0
    for name, call, want in _round5_pure_extract_old_witness_prior_cases(R):
        if name != 'no-outcome-VOID':
            yield name, call, want
            continue
        seen += 1

        def pure_extract_call(call=call):
            attempts = []

            def forbidden(*args, **kwargs):
                attempts.append(1)
                raise AssertionError('pure extraction attempted a native or write operation')

            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(R, 'command', new=forbidden))
                stack.enter_context(patch.object(R, 'sealed_set', new=forbidden))
                stack.enter_context(patch.object(R, 'dump', new=forbidden))
                stack.enter_context(patch.object(R.subprocess, 'run', new=forbidden))
                stack.enter_context(patch.object(R.subprocess, 'Popen', new=forbidden))
                stack.enter_context(patch.object(R, 'open', new=forbidden, create=True))
                observed = call()
                # This assertion is INSIDE the real named callback. If a product
                # path swallows the denial, it still becomes that callback's
                # failure; no pin is fabricated at run/constructor level.
                if attempts:
                    raise AssertionError('pure extraction swallowed an unexpected operation')
                return observed

        yield name, pure_extract_call, want
    if seen != 1:
        raise AssertionError('expected exactly one retained no-outcome-VOID witness')

# UNAPPLIED v5 IO boundary; exact frozen calibration/H-cal leaves only.
# Append once before the selected outer global-open run boundary. No production
# method or old fixture body/name/want is changed by this fragment.
_round5_prefix135_write_prior_cases = cases


def _round5_prefix135_pure_extract(R, call):
    attempts = []

    def forbidden(*args, **kwargs):
        attempts.append(True)
        raise AssertionError('pure extraction attempted external or write IO')

    with contextlib.ExitStack() as stack:
        for name in ('command', 'sealed_set', 'dump', 'open'):
            stack.enter_context(patch.object(R, name, new=forbidden, create=name == 'open'))
        stack.enter_context(patch.object(R.subprocess, 'run', new=forbidden))
        stack.enter_context(patch.object(R.subprocess, 'Popen', new=forbidden))
        observed = call()
        if attempts:
            raise AssertionError('pure extraction swallowed an unexpected IO attempt')
        return observed


def _round5_prefix135_private_writes(R, call, allow_visible_sources=False):
    # This scope is only for four reviewed callbacks which create their own
    # TemporaryDirectory and use no symlinks. Track actual mkdtemp returns;
    # preserve TemporaryDirectory's real type/lifetime and all Path types.
    import os as fixture_os
    actual_mkdtemp = tempfile.mkdtemp
    actual_write_text = Path.write_text
    actual_dump = R.dump
    actual_copyfile = R.shutil.copyfile
    actual_copytree = R.shutil.copytree
    roots = []
    rejected = []
    native_path_type = type(Path())

    def normalized(value):
        # No custom fspath/str/repr protocol is entered by this check.
        if type(value) is str:
            text = value
        elif type(value) is native_path_type:
            text = str(value)
        elif type(value) is fixture_os.DirEntry and type(value.path) is str:
            # Real stdlib copytree/copy2 recurse with native DirEntry objects.
            # Its cached native path is checked; the ORIGINAL object still
            # reaches the captured real copy function, preserving its API.
            text = value.path
        else:
            rejected.append(True)
            raise AssertionError('fixture destination has an unexpected type')
        return fixture_os.path.normcase(fixture_os.path.abspath(text))

    def private_destination(value):
        destination = normalized(value)
        if not any(destination != root and fixture_os.path.commonpath((root, destination)) == root
                   for root in roots):
            rejected.append(True)
            raise AssertionError('fixture write left its actual temporary directory')
        return destination

    def tracked_mkdtemp(*args, **kwargs):
        directory = actual_mkdtemp(*args, **kwargs)
        roots.append(normalized(directory))
        return directory

    def guarded_write_text(path, *args, **kwargs):
        private_destination(path)
        # The exact captured real method and its original args run after the
        # pre-effect boundary. Private actual files, serialization and reads
        # remain the old callback's substantive witness.
        return actual_write_text(path, *args, **kwargs)

    def guarded_dump(destination, obj):
        private_destination(destination)
        return actual_dump(destination, obj)

    def guarded_copyfile(source, destination, *args, **kwargs):
        observed_source = normalized(source)
        # Frozen families.SET is exactly these three leaf files. Calibration
        # lives directly beside this canonical selftest; H-cal lives in hcal/.
        # Only the calibration orchestration fixture may read these exact six
        # committed inputs; this is not a general repository read allowance.
        oracle = Path(__file__).resolve().parent
        visible_sources = ({normalized(directory / leaf)
                            for directory in (oracle, oracle / 'hcal')
                            for leaf in ('corpus.json', 'labels.json', 'certificate.json')}
                           if allow_visible_sources else set())
        private_source = any(observed_source != root and
                             fixture_os.path.commonpath((root, observed_source)) == root
                             for root in roots)
        if not private_source and observed_source not in visible_sources:
            rejected.append(True)
            raise AssertionError('fixture copy source left its private or committed visible corpus')
        private_destination(destination)
        return actual_copyfile(source, destination, *args, **kwargs)

    def guarded_copytree(source, destination, *args, **kwargs):
        private_destination(source)
        private_destination(destination)
        return actual_copytree(source, destination, *args, **kwargs)

    def unexpected(*args, **kwargs):
        rejected.append(True)
        raise AssertionError('private writer attempted a beacon or module-global open')

    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(tempfile, 'mkdtemp', new=tracked_mkdtemp))
        stack.enter_context(patch.object(Path, 'write_text', new=guarded_write_text))
        stack.enter_context(patch.object(R, 'dump', new=guarded_dump))
        stack.enter_context(patch.object(R.shutil, 'copyfile', new=guarded_copyfile))
        stack.enter_context(patch.object(R.shutil, 'copytree', new=guarded_copytree))
        stack.enter_context(patch.object(R, 'sealed_set', new=unexpected))
        stack.enter_context(patch.object(R, 'open', new=unexpected, create=True))
        observed = call()
        # This assertion runs INSIDE the actual named retained callback. A
        # swallowed denial is a real failure of that callback, not a forged pin.
        if rejected:
            raise AssertionError('private writer swallowed an unexpected IO attempt')
        return observed


def cases(R):
    expected = {'extract-all-predicates', 'orchestration-calibration',
                'write-population-name-and-content', 'command-real-subprocess-contract',
                'staged-instrument-build-context'}
    found = set()
    for name, call, want in _round5_prefix135_write_prior_cases(R):
        if name in expected:
            if name in found:
                raise AssertionError('duplicate retained135251 witness')
            found.add(name)
            if name == 'extract-all-predicates':
                yield name, lambda call=call: _round5_prefix135_pure_extract(R, call), want
            else:
                yield name, lambda call=call, visible=(name == 'orchestration-calibration'): _round5_prefix135_private_writes(R, call, allow_visible_sources=visible), want
        else:
            yield name, call, want
    if found != expected:
        raise AssertionError('missing retained135251 witness')

# SOURCE-ONLY one-fixture append, immediately after IO5 and before human/global LAST.
# Real committed copies remain effects inside existing IO5 private scope.
_round5_visible_copy_data = json.loads(r'''{
  "expected_DRY_machine_lines": [
    "DRY OUTCOME converged: R3",
    "DRY OUTCOME stable: R3",
    "DRY OUTCOME improving: R3",
    "DRY OUTCOME oscillating: R3",
    "DRY OUTCOME diverging: R3",
    "DRY OUTCOME equilibrium: R3"
  ],
  "expected_uncached_main_result": [
    0,
    "COMPLETE",
    [
      "calibration",
      "hcal"
    ],
    6,
    0
  ],
  "format": "r30r-visible-cal-hcal-copy-provenance-literals/1",
  "frozen_SET3": [
    "corpus.json",
    "labels.json",
    "certificate.json"
  ],
  "not_runtime_observation": true,
  "populations": [
    "calibration",
    "hcal"
  ],
  "references": [
    {
      "bytes": 58365,
      "committed_git_blob_sha1": "3258f5a1177fd843f927b7a672e7ca32febbe507",
      "leaf": "corpus.json",
      "population": "calibration",
      "sha256": "e3f5e94e97bd28972480977a5ff21173221e878ab784abc7f4ed5459bedfefe4"
    },
    {
      "bytes": 149936,
      "committed_git_blob_sha1": "24e897f114f6882a16276560759eeaba910de265",
      "leaf": "labels.json",
      "population": "calibration",
      "sha256": "de4d61390cde512f5bfec01d51cceb28c3cf17db8758fbac38b72cd8891cd5cb"
    },
    {
      "bytes": 18679,
      "committed_git_blob_sha1": "50c14acd40d283c55c77305c0943e680a4f79641",
      "leaf": "certificate.json",
      "population": "calibration",
      "sha256": "5a3840c0a1d7a3078ff808614c4199ad9d768dedba84d6110bf4ffc0c56cd7a5"
    },
    {
      "bytes": 38734,
      "committed_git_blob_sha1": "c2f727d9416b9dc60053dbaad0ade7b4ff77c13d",
      "leaf": "corpus.json",
      "population": "hcal",
      "sha256": "47f9fedd37bf4cd56d86f781aa8995a9791fe404f56351dba712727825f06b0d"
    },
    {
      "bytes": 116749,
      "committed_git_blob_sha1": "9b14cdb77cd6da9ebd2a29925df473d5e4aa5b25",
      "leaf": "labels.json",
      "population": "hcal",
      "sha256": "323b0e9501e350ed61b9862e8b6f2d0c1fce662baf27cd200d40eaa6e0db86d6"
    },
    {
      "bytes": 13606,
      "committed_git_blob_sha1": "58b6dc69900b7ce9bdfdf8a8d6505da00b9c0a23",
      "leaf": "certificate.json",
      "population": "hcal",
      "sha256": "3a73e7fda9787d4627137b7abb1dc01830cbfc1b652932dcb4232dc80f588de6"
    }
  ]
}
''')

def _round5_visible_copy_stream_hash(path):
    import hashlib as fixture_hashlib
    digest, size = fixture_hashlib.sha256(), 0
    with path.open('rb') as stream:
        while True:
            block = stream.read(65536)
            if not block:
                break
            digest.update(block)
            size += len(block)
    return size, digest.hexdigest()


def _round5_visible_copy_provenance(R):
    def callback():
        import os as fixture_os
        # These are already the installed IO5 wrappers. Retain their original
        # arguments/return objects, including native Path and DirEntry types.
        guarded_copyfile = R.shutil.copyfile
        tracked_mkdtemp = tempfile.mkdtemp
        native_path_type = type(Path())
        own_roots, copied_rows, attempts = [], [], []
        oracle = Path(__file__).resolve().parent  # canonical T, never R.HERE
        populations = ('calibration', 'hcal')
        leaves = ('corpus.json', 'labels.json', 'certificate.json')

        def native_text(value):
            if type(value) is str:
                return value
            if type(value) is native_path_type:
                return str(value)
            if type(value) is fixture_os.DirEntry and type(value.path) is str:
                return value.path
            raise AssertionError('copy observation has nonnative path type')

        def normalized_native(value):
            return fixture_os.path.normcase(fixture_os.path.abspath(native_text(value)))

        # Reference bytes/hash come ONLY from the independent committed six
        # files adjacent to canonical T. Nothing emitted by R is the oracle.
        source_logical, reference_hashes = {}, {}
        for reference in _round5_visible_copy_data['references']:
            population, leaf = reference['population'], reference['leaf']
            canonical = (oracle if population == 'calibration' else oracle / 'hcal') / leaf
            actual = _round5_visible_copy_stream_hash(canonical)
            if actual != (reference['bytes'], reference['sha256']):
                raise AssertionError('committed visible reference changed')
            source_logical[normalized_native(canonical)] = (population, leaf)
            reference_hashes[(population, leaf)] = actual

        def observe_mkdtemp(*args, **kwargs):
            directory = tracked_mkdtemp(*args, **kwargs)  # IO5 captures REAL root first.
            own_roots.append(directory)
            return directory

        def observe_copyfile(source, destination, *args, **kwargs):
            try:
                copied = guarded_copyfile(source, destination, *args, **kwargs)
            finally:
                # Count even a denial/error swallowed by a mutated caller.
                # No coercion or physical destination read precedes delegation.
                attempts.append(True)
            observed_source = source_logical.get(normalized_native(source), ('unexpected-source', 'unexpected-leaf'))
            observed_destination = normalized_native(destination)
            destinations = {normalized_native(Path(root) / 'run' / pop / leaf): (pop, leaf)
                            for root in own_roots for pop in populations for leaf in leaves}
            logical_destination = destinations.get(observed_destination, ('unexpected-destination', 'unexpected-leaf'))
            # Read ONLY a recognized exact destination owned by THIS callback.
            # IO5 already authorized its real write; never follow arbitrary caller paths.
            matches = (logical_destination in reference_hashes and
                       _round5_visible_copy_stream_hash(Path(observed_destination)) == reference_hashes[logical_destination])
            copied_rows.append((observed_source, logical_destination, matches))
            return copied  # Preserve captured real copyfile return/API.

        actual_main_case = main_case
        seen = set()
        while hasattr(actual_main_case, '__wrapped__'):
            if id(actual_main_case) in seen or len(seen) >= 8:
                raise AssertionError('unexpected main_case wrapper cycle')
            seen.add(id(actual_main_case))
            actual_main_case = actual_main_case.__wrapped__
        output, error = io.StringIO(), io.StringIO()
        with patch.object(tempfile, 'mkdtemp', new=observe_mkdtemp), \
             patch.object(R.shutil, 'copyfile', new=observe_copyfile), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            # All existing arm/build/floor/judge/beacon mocks remain in the
            # ORIGINAL uncached main_case. Actual R.main/copy/Path IO execute.
            main_result = actual_main_case(R)
        if len(own_roots) != 1 or len(attempts) != 6 or len(copied_rows) != 6:
            raise AssertionError('missing/extra/swallowed visible corpus copy')
        def machine_lines(stream):
            return tuple(line.split(';', 1)[0] for line in stream.getvalue().splitlines()
                         if line.startswith(('OUTCOME ', 'DRY OUTCOME ')))
        return (main_result, tuple(copied_rows), len(attempts), len(own_roots),
                machine_lines(output), machine_lines(error))
    return _round5_prefix135_private_writes(R, callback, allow_visible_sources=True)


_round5_visible_copy_prior_cases = cases


def cases(R):
    yield from _round5_visible_copy_prior_cases(R)
    yield ('orchestration-visible-calibration-Hcal-copy-provenance',
           lambda: _round5_visible_copy_provenance(R),
           ((0, 'COMPLETE', ['calibration', 'hcal'], 6, 0),
            ((('calibration', 'corpus.json'), ('calibration', 'corpus.json'), True),
             (('calibration', 'labels.json'), ('calibration', 'labels.json'), True),
             (('calibration', 'certificate.json'), ('calibration', 'certificate.json'), True),
             (('hcal', 'corpus.json'), ('hcal', 'corpus.json'), True),
             (('hcal', 'labels.json'), ('hcal', 'labels.json'), True),
             (('hcal', 'certificate.json'), ('hcal', 'certificate.json'), True)),
            6, 1,
            ('DRY OUTCOME converged: R3', 'DRY OUTCOME stable: R3',
             'DRY OUTCOME improving: R3', 'DRY OUTCOME oscillating: R3',
             'DRY OUTCOME diverging: R3', 'DRY OUTCOME equilibrium: R3'), ()))

# SOURCE-ONLY append fragment: all four public human-output line boundaries.
# Dependencies: unchanged _r30x_entry_code/_r30x_process_status (38eab021...).
# Do not append the superseded initial catch-only fragment as well.
_r30l2_data = json.loads(r'''{
  "SYNTHETIC": true,
  "expected_main_raw_base": {
    "dry": true,
    "format": "r3-reveal/1",
    "manifests": {},
    "populations": {},
    "resamples": 1000,
    "seed": 1758
  },
  "extract_base_raw": {
    "controls": {
      "a": true,
      "b": true,
      "c1": true,
      "c2": true
    },
    "dry": true,
    "format": "r3-reveal/1",
    "populations": {
      "hcal": {
        "decisions": {
          "CF": {
            "converged": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs R3-STD",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "diverging": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "equilibrium": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "improving": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "oscillating": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "stable": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs R3-STD",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            }
          },
          "R3": {
            "converged": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs R3-STD",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "diverging": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "equilibrium": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "improving": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "oscillating": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "stable": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs R3-STD",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            }
          },
          "R3-STD": {
            "converged": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "diverging": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "equilibrium": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "improving": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "oscillating": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            },
            "stable": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "PASS"
            }
          },
          "W4": {
            "converged": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs R3-STD",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "diverging": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "equilibrium": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "improving": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "oscillating": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            },
            "stable": {
              "rules": [
                [
                  "1 standard parity",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs INC",
                  "FAIL",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "2 vs R3-STD",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "3 safety",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "4 trivial floor",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "5 unit invariance",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ],
                [
                  "6 existing gates",
                  "PASS",
                  "SYNTHETIC refusal-line projection"
                ]
              ],
              "verdict": "FAIL"
            }
          }
        },
        "diffs": [
          [
            "STD",
            "T001",
            "converged",
            "1/2",
            "0.1",
            "0.9",
            "0"
          ]
        ],
        "findings": [],
        "judge_rc": 0,
        "labels": {
          "line-negative@1": {
            "converged": [
              "MATH",
              false,
              "SYNTHETIC literal label"
            ],
            "diverging": [
              "MATH",
              false,
              "SYNTHETIC literal label"
            ],
            "equilibrium": [
              "MATH",
              false,
              "SYNTHETIC literal label"
            ],
            "improving": [
              "MATH",
              false,
              "SYNTHETIC literal label"
            ],
            "oscillating": [
              "MATH",
              false,
              "SYNTHETIC literal label"
            ],
            "stable": [
              "MATH",
              false,
              "SYNTHETIC literal label"
            ]
          },
          "line-positive@1": {
            "converged": [
              "MATH",
              true,
              "SYNTHETIC literal label"
            ],
            "diverging": [
              "MATH",
              true,
              "SYNTHETIC literal label"
            ],
            "equilibrium": [
              "MATH",
              true,
              "SYNTHETIC literal label"
            ],
            "improving": [
              "MATH",
              true,
              "SYNTHETIC literal label"
            ],
            "oscillating": [
              "MATH",
              true,
              "SYNTHETIC literal label"
            ],
            "stable": [
              "MATH",
              true,
              "SYNTHETIC literal label"
            ]
          }
        },
        "points": [
          [
            "CF",
            "converged",
            "1/2"
          ],
          [
            "CF",
            "stable",
            "1/2"
          ],
          [
            "CF",
            "improving",
            "1/2"
          ],
          [
            "CF",
            "oscillating",
            "1/2"
          ],
          [
            "CF",
            "diverging",
            "1/2"
          ],
          [
            "CF",
            "equilibrium",
            "1/2"
          ]
        ],
        "readings": [
          [
            "R3",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "R3",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "R3",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "R3",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "R3",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "R3",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "R3",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "R3",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "R3",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "R3",
            "line-positive",
            1,
            "oscillating",
            true
          ],
          [
            "R3",
            "line-positive",
            1,
            "diverging",
            true
          ],
          [
            "R3",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "R3-STD",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "R3-STD",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "R3-STD",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "R3-STD",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "R3-STD",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "R3-STD",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "R3-STD",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "R3-STD",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "R3-STD",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "R3-STD",
            "line-positive",
            1,
            "oscillating",
            true
          ],
          [
            "R3-STD",
            "line-positive",
            1,
            "diverging",
            true
          ],
          [
            "R3-STD",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "INC",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "INC",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "INC",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "INC",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "INC",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "INC",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "INC",
            "line-positive",
            1,
            "converged",
            false
          ],
          [
            "INC",
            "line-positive",
            1,
            "stable",
            false
          ],
          [
            "INC",
            "line-positive",
            1,
            "improving",
            false
          ],
          [
            "INC",
            "line-positive",
            1,
            "oscillating",
            false
          ],
          [
            "INC",
            "line-positive",
            1,
            "diverging",
            false
          ],
          [
            "INC",
            "line-positive",
            1,
            "equilibrium",
            false
          ],
          [
            "ANCHOR",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "ANCHOR",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "ANCHOR",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "ANCHOR",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "ANCHOR",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "ANCHOR",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "ANCHOR",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "ANCHOR",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "ANCHOR",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "ANCHOR",
            "line-positive",
            1,
            "oscillating",
            true
          ],
          [
            "ANCHOR",
            "line-positive",
            1,
            "diverging",
            true
          ],
          [
            "ANCHOR",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "CF",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "CF",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "CF",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "CF",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "CF",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "CF",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "CF",
            "line-positive",
            1,
            "converged",
            false
          ],
          [
            "CF",
            "line-positive",
            1,
            "stable",
            false
          ],
          [
            "CF",
            "line-positive",
            1,
            "improving",
            false
          ],
          [
            "CF",
            "line-positive",
            1,
            "oscillating",
            false
          ],
          [
            "CF",
            "line-positive",
            1,
            "diverging",
            false
          ],
          [
            "CF",
            "line-positive",
            1,
            "equilibrium",
            false
          ],
          [
            "W4",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "W4",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "W4",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "W4",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "W4",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "W4",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "W4",
            "line-positive",
            1,
            "converged",
            false
          ],
          [
            "W4",
            "line-positive",
            1,
            "stable",
            false
          ],
          [
            "W4",
            "line-positive",
            1,
            "improving",
            false
          ],
          [
            "W4",
            "line-positive",
            1,
            "oscillating",
            false
          ],
          [
            "W4",
            "line-positive",
            1,
            "diverging",
            false
          ],
          [
            "W4",
            "line-positive",
            1,
            "equilibrium",
            false
          ],
          [
            "STD",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "STD",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "STD",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "STD",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "STD",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "STD",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "STD",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "STD",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "STD",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "STD",
            "line-positive",
            1,
            "oscillating",
            true
          ],
          [
            "STD",
            "line-positive",
            1,
            "diverging",
            true
          ],
          [
            "STD",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "STD'",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "STD'",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "STD'",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "STD'",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "STD'",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "STD'",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "STD'",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "STD'",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "STD'",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "STD'",
            "line-positive",
            1,
            "oscillating",
            true
          ],
          [
            "STD'",
            "line-positive",
            1,
            "diverging",
            true
          ],
          [
            "STD'",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "REF",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "REF",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "REF",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "REF",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "REF",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "REF",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "REF",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "REF",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "REF",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "REF",
            "line-positive",
            1,
            "oscillating",
            true
          ],
          [
            "REF",
            "line-positive",
            1,
            "diverging",
            true
          ],
          [
            "REF",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "C0",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "C0",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "C0",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "C0",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "C0",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "C0",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "C0",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "C0",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "C0",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "C0",
            "line-positive",
            1,
            "oscillating",
            true
          ],
          [
            "C0",
            "line-positive",
            1,
            "diverging",
            true
          ],
          [
            "C0",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "C1",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "C1",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "C1",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "C1",
            "line-negative",
            1,
            "oscillating",
            false
          ],
          [
            "C1",
            "line-negative",
            1,
            "diverging",
            false
          ],
          [
            "C1",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "C1",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "C1",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "C1",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "C1",
            "line-positive",
            1,
            "oscillating",
            true
          ],
          [
            "C1",
            "line-positive",
            1,
            "diverging",
            true
          ],
          [
            "C1",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "STD''",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "STD''",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "D2",
            "line-negative",
            1,
            "improving",
            false
          ],
          [
            "D2",
            "line-positive",
            1,
            "improving",
            true
          ],
          [
            "PERSIST",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "PERSIST",
            "line-negative",
            1,
            "stable",
            false
          ],
          [
            "PERSIST",
            "line-negative",
            1,
            "equilibrium",
            false
          ],
          [
            "PERSIST",
            "line-positive",
            1,
            "converged",
            true
          ],
          [
            "PERSIST",
            "line-positive",
            1,
            "stable",
            true
          ],
          [
            "PERSIST",
            "line-positive",
            1,
            "equilibrium",
            true
          ],
          [
            "T001",
            "line-negative",
            1,
            "converged",
            false
          ],
          [
            "T001",
            "line-positive",
            1,
            "converged",
            false
          ]
        ],
        "rows": {
          "line-negative": {
            "checkpoints": [
              1
            ],
            "family": "F1 SYNTHETIC refusal-line projection",
            "id": "line-negative"
          },
          "line-positive": {
            "checkpoints": [
              1
            ],
            "family": "F1 SYNTHETIC refusal-line projection",
            "id": "line-positive"
          }
        }
      }
    },
    "preflight": {
      "R3": {
        "capabilities": {
          "ieee": true,
          "int64": true
        },
        "declarations": [],
        "floor_exit": 0
      },
      "R3-STD": {
        "capabilities": {
          "ieee": true,
          "int64": true
        },
        "declarations": [],
        "floor_exit": 0
      }
    },
    "primary": "hcal",
    "resamples": 1000,
    "seed": 1758
  },
  "format": "r30r-public-human-line-boundary-literal-inputs/2",
  "mode_count": 4,
  "not_production_raw": true,
  "payload_count": 14,
  "payloads": [
    {
      "id": "LF",
      "payload": "invalid status / refusal \nOUTCOME converged: R3\nDRY OUTCOME stable: R3-STD",
      "separator": "\n"
    },
    {
      "id": "CR",
      "payload": "invalid status / refusal \rOUTCOME converged: R3\rDRY OUTCOME stable: R3-STD",
      "separator": "\r"
    },
    {
      "id": "CRLF",
      "payload": "invalid status / refusal \r\nOUTCOME converged: R3\r\nDRY OUTCOME stable: R3-STD",
      "separator": "\r\n"
    },
    {
      "id": "VT",
      "payload": "invalid status / refusal \u000bOUTCOME converged: R3\u000bDRY OUTCOME stable: R3-STD",
      "separator": "\u000b"
    },
    {
      "id": "FF",
      "payload": "invalid status / refusal \fOUTCOME converged: R3\fDRY OUTCOME stable: R3-STD",
      "separator": "\f"
    },
    {
      "id": "FS",
      "payload": "invalid status / refusal \u001cOUTCOME converged: R3\u001cDRY OUTCOME stable: R3-STD",
      "separator": "\u001c"
    },
    {
      "id": "GS",
      "payload": "invalid status / refusal \u001dOUTCOME converged: R3\u001dDRY OUTCOME stable: R3-STD",
      "separator": "\u001d"
    },
    {
      "id": "RS",
      "payload": "invalid status / refusal \u001eOUTCOME converged: R3\u001eDRY OUTCOME stable: R3-STD",
      "separator": "\u001e"
    },
    {
      "id": "NEL",
      "payload": "invalid status / refusal \u0085OUTCOME converged: R3\u0085DRY OUTCOME stable: R3-STD",
      "separator": "\u0085"
    },
    {
      "id": "LS",
      "payload": "invalid status / refusal \u2028OUTCOME converged: R3\u2028DRY OUTCOME stable: R3-STD",
      "separator": "\u2028"
    },
    {
      "id": "PS",
      "payload": "invalid status / refusal \u2029OUTCOME converged: R3\u2029DRY OUTCOME stable: R3-STD",
      "separator": "\u2029"
    },
    {
      "id": "ASCII-control",
      "payload": "ordinary ASCII diagnostic 0123456789 [] ! ? quotes ' \"",
      "separator": null
    },
    {
      "id": "backslash-control",
      "payload": "ordinary literal \\n \\r \\x85 \\u2028 path C:\\fixture\\raw.json",
      "separator": null
    },
    {
      "id": "Unicode-control",
      "payload": "ordinary Unicode caf\u00e9 \u96ea \u03bb \ud83d\ude00",
      "separator": null
    }
  ],
  "separator_names": [
    "LF",
    "CR",
    "CRLF",
    "VT",
    "FF",
    "FS",
    "GS",
    "RS",
    "NEL",
    "LS",
    "PS"
  ]
}
''')

def _r30l2_observe_cli(R, mode, payload, root, serial):
    entry = _r30x_entry_code(R)
    out = root / ('human-line-output-' + str(serial))
    stdout, stderr, attempted, executed = io.StringIO(), io.StringIO(), [], []
    if mode in ('extract-refusal', 'extract-reason', 'extract-void-key'):
        expected_raw = copy.deepcopy(_r30l2_data['extract_base_raw'])
        if mode == 'extract-refusal':
            expected_raw['status'] = payload
        elif mode == 'extract-reason':
            expected_raw['status'] = 'INCOMPLETE'
            expected_raw['populations']['hcal']['judge_rc'] = 2
            expected_raw['reasons'] = [payload]
        else:
            expected_raw['status'] = 'VOID'
            expected_raw['controls']['a'] = False
            expected_raw['controls'][payload] = False
        source = root / ('human-line-input-' + str(serial) + '.json')
        source.write_text(json.dumps(expected_raw, sort_keys=True))
        argv = [R.__file__, '--extract', str(source), '--out', str(out)]
    elif mode == 'main-catch':
        expected_raw = copy.deepcopy(_r30l2_data['expected_main_raw_base'])
        expected_raw.update(status='REFUSED', error=payload)
        argv = [R.__file__, '--dry', '--calibration', '--r3',
                'SYNTHETIC-HUMAN-LINE', '--out', str(out),
                '--seed', '1758', '--resamples', '1000']
    else:
        raise AssertionError('unknown public human-line mode')

    def blocked(label):
        def refuse_before_effect(*args, **kwargs):
            attempted.append(label)
            raise AssertionError('public human-line fixture attempted ' + label)
        return refuse_before_effect

    def refuse_execute(args, raw):
        executed.append((args.dry, args.calibration, args.seed, args.resamples,
                         args.out == out))
        raise R.Refusal(payload)

    before_name = R.__name__
    before_argv, argv_values = R.sys.argv, tuple(R.sys.argv)
    had_main = '__main__' in R.sys.modules
    before_main = R.sys.modules.get('__main__')
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(R, 'command', new=blocked('command')))
        stack.enter_context(patch.object(R, 'sealed_set', new=blocked('sealed_set')))
        stack.enter_context(patch.object(R.subprocess, 'run', new=blocked('subprocess.run')))
        stack.enter_context(patch.object(R.subprocess, 'Popen', new=blocked('subprocess.Popen')))
        stack.enter_context(patch.object(R, 'open', new=blocked('global.open'), create=True))
        if mode == 'main-catch':
            stack.enter_context(patch.object(R, 'execute', new=refuse_execute))
        stack.enter_context(patch.object(R, '__name__', '__main__'))
        stack.enter_context(patch.dict(R.sys.modules, {'__main__': R}))
        stack.enter_context(patch.object(R.sys, 'argv', argv))
        stack.enter_context(contextlib.redirect_stdout(stdout))
        stack.enter_context(contextlib.redirect_stderr(stderr))
        try:
            exec(entry, R.__dict__)
        except SystemExit as stopped:
            rc = _r30x_process_status(stopped.code, stderr)
        else:
            raise AssertionError('actual production CLI footer did not exit')
        # No production catch/status formula is reproduced. Unexpected product
        # exceptions remain ordinary named-red failures in the outer selftest.
    scopes_restored = (R.__name__ == before_name and R.sys.argv is before_argv
        and tuple(R.sys.argv) == argv_values
        and ('__main__' in R.sys.modules) is had_main
        and R.sys.modules.get('__main__') is before_main)
    raw_path, decision_path = out / 'raw.json', out / 'decision.json'
    actual_raw = json.loads(raw_path.read_text()) if raw_path.is_file() else None
    decision = json.loads(decision_path.read_text()) if decision_path.is_file() else None
    table_public = ((decision.get('status'), 'predicates' in decision)
                    if isinstance(decision, dict) else 'ABSENT')
    files = tuple(sorted(p.name for p in out.iterdir())) if out.is_dir() else ()
    def machine_lines(stream):
        return tuple(line for line in stream.getvalue().splitlines()
                     if line.startswith(('OUTCOME ', 'DRY OUTCOME ')))
    expected_execute = [(True, True, 1758, 1000, True)] if mode == 'main-catch' else []
    error_unchanged = (isinstance(actual_raw, dict) and actual_raw.get('error') == payload
                       and actual_raw.get('status') == 'REFUSED') if mode == 'main-catch' else None
    output_lines = stdout.getvalue().splitlines()
    error_lines = stderr.getvalue().splitlines()
    human_line = (error_lines[0] if len(error_lines) == 1 else '') if mode in ('extract-refusal', 'main-catch') else (output_lines[1] if len(output_lines) == 2 else '')
    return (rc, actual_raw == expected_raw, files, table_public, error_unchanged,
            machine_lines(stdout), machine_lines(stderr),
            len(stderr.getvalue().splitlines()),
            output_lines[0] if output_lines else None, len(output_lines),
            executed == expected_execute, tuple(attempted), scopes_restored, bool(human_line.strip()))


def _r30l2_public_matrix(R, mode):
    rows = _r30l2_data['payloads']
    names = ('LF', 'CR', 'CRLF', 'VT', 'FF', 'FS', 'GS', 'RS', 'NEL', 'LS', 'PS',
             'ASCII-control', 'backslash-control', 'Unicode-control')
    if len(rows) != 14 or tuple(row['id'] for row in rows) != names:
        raise AssertionError('exact nonempty fourteen public human-line inputs required')
    if mode == 'extract-refusal':
        want = (2, True, ('raw.json',), 'ABSENT', None, (), (), 1,
                None, 0, True, (), True, True)
    elif mode == 'main-catch':
        want = (2, True, ('raw.json',), 'ABSENT', True, (), (), 1,
                'REFUSED', 1, True, (), True, True)
    elif mode == 'extract-reason':
        want = (0, True, ('decision.json', 'hcal-population.json', 'raw.json'),
                ('INCOMPLETE', False), None, (), (), 0, 'INCOMPLETE', 2,
                True, (), True, True)
    elif mode == 'extract-void-key':
        want = (0, True, ('decision.json', 'hcal-population.json', 'raw.json'),
                ('VOID', False), None, (), (), 0, 'VOID', 2,
                True, (), True, True)
    else:
        raise AssertionError('unknown public human-line aggregate mode')
    examined, failed = 0, []
    with tempfile.TemporaryDirectory() as tmp:
        for serial, row in enumerate(rows):
            got = _r30l2_observe_cli(R, mode, row['payload'], Path(tmp), serial)
            examined += 1
            if got != want:
                failed.append((row['id'], got))
    return examined, failed


_r30l2_prior_cases = cases


def cases(R):
    yield from _r30l2_prior_cases(R)
    yield ('Extract-R5-refusal-all-splitlines-public-CLI',
           lambda: _r30l2_public_matrix(R, 'extract-refusal'), (14, []))
    yield ('Main-R5-refusal-all-splitlines-real-catch-public-CLI',
           lambda: _r30l2_public_matrix(R, 'main-catch'), (14, []))
    yield ('Extract-R5-INCOMPLETE-reason-all-splitlines-public-CLI',
           lambda: _r30l2_public_matrix(R, 'extract-reason'), (14, []))
    yield ('Extract-R5-VOID-failed-key-all-splitlines-public-CLI',
           lambda: _r30l2_public_matrix(R, 'extract-void-key'), (14, []))

# UNAPPLIED structural module-local open boundary, not a production IO policy.
# Append ONCE, LAST, after the selected prior cases/run wrappers. This source
# proposal's concrete reference composition is ONLY old4ad + this fragment.
# Preserve all original fixture bytes, cache wrappers and ROOT behavior.
import threading as _round5_global_open_threading

_round5_global_open_prior_cases = cases
_round5_global_open_prior_run = run
_round5_global_open_frames = []
_round5_global_open_stack_lock = _round5_global_open_threading.Lock()


class _Round5ModuleOpenDenied(AssertionError):
    pass


@contextlib.contextmanager
def _round5_global_open_scope(R):
    # This is explicit method instrumentation, not invisible namespace state.
    # Concurrent invocations are refused, never silently serialized or shared.
    # Same-thread reentry is stack-safe, including a different R module.
    owner = _round5_global_open_threading.get_ident()
    namespace = R.__dict__
    frame = None
    try:
        with _round5_global_open_stack_lock:
            if _round5_global_open_frames and _round5_global_open_frames[-1]['owner'] != owner:
                raise RuntimeError('concurrent global-open selftest boundary is unsupported')
            had_open = 'open' in namespace
            previous_open = namespace.get('open')
            ancestors = tuple(item for item in _round5_global_open_frames if item['R'] is R)
            frame = {'R': R, 'owner': owner, 'attempts': 0, 'denier': None,
                     'assertion_calls': 0, 'last_assertion_attempts': None,
                     'parent_same_module_frames': ancestors}

            def deny_module_open(*args, **kwargs):
                # Do not inspect/coerce/repr/log arguments or touch a file/FD.
                # Increment before raising, including every same-module ancestor.
                frame['attempts'] += 1
                for ancestor in ancestors:
                    ancestor['attempts'] += 1
                raise _Round5ModuleOpenDenied('reveal module-global open denied before physical IO')

            frame['denier'] = deny_module_open
            # The cleanup try is already active before registration/install.
            _round5_global_open_frames.append(frame)
            namespace['open'] = deny_module_open
        yield frame
    finally:
        if frame is not None:
            with _round5_global_open_stack_lock:
                # Membership, rather than an after-append boolean, owns the
                # transaction even if entry is interrupted after append.
                positions = [index for index, item in enumerate(_round5_global_open_frames) if item is frame]
                if positions:
                    # Restore exact membership and object identity on exits
                    # from the delegated body, including all BaseException.
                    if had_open:
                        namespace['open'] = previous_open
                    else:
                        namespace.pop('open', None)
                    ordered = len(positions) == 1 and positions[0] == len(_round5_global_open_frames) - 1
                    for index in reversed(positions):
                        del _round5_global_open_frames[index]
                    if not ordered:
                        raise RuntimeError('global-open boundary stack order was changed')


def _round5_global_open_assertion(R):
    with _round5_global_open_stack_lock:
        frame = next((item for item in reversed(_round5_global_open_frames) if item['R'] is R), None)
        if frame is None:
            raise AssertionError('global-open safety fixture requires the actual run boundary')
        frame['assertion_calls'] += 1
        frame['last_assertion_attempts'] = frame['attempts']
        if R.__dict__.get('open') is not frame['denier']:
            raise AssertionError('module-global open shadow is not the active boundary')
        if frame['attempts']:
            raise AssertionError(('module-global open attempts were observed', frame['attempts']))
    return 0


def _round5_global_open_case(R):
    # REAL declaration + literal want. Direct cases enumeration is lazy and does
    # not access an active frame or run any assertion. The same assertion is
    # used by the ordinary fixture and the honestly classified postflight.
    return ('safety-reveal-module-global-open-not-called',
            lambda: _round5_global_open_assertion(R), 0)


def cases(R):
    yield from _round5_global_open_prior_cases(R)
    yield _round5_global_open_case(R)


def run(R, plant=None, quiet=False, prefer=()):
    with _round5_global_open_scope(R) as frame:
        result = _round5_global_open_prior_run(R, plant=plant, quiet=quiet, prefer=prefer)
        if frame['attempts']:
            # Preserve an ACTUAL prior named failure/nonquiet failure. A denied
            # call inside an old thunk can legitimately produce that failure;
            # it does not preserve the old substantive witness automatically.
            already_failed = ((quiet and isinstance(result, list) and bool(result))
                              or (not quiet and type(result) is int and result != 0))
            if not already_failed:
                # Attempts swallowed before the ordinary safety fixture give
                # its REAL named red. If it was preferred too early, or an
                # attempt happened in the later separately appended STOP-2
                # fixture, this actual assertion is OUTSIDE old run's fixture
                # catch: it propagates as honest entrypoint NR, NEVER a forged
                # named pin or fabricated CHECK/summary/count. Constructor
                # aborts never reach here and also remain honest NR.
                _round5_global_open_assertion(R)
        return result


# Round 6: driver-owned messages and CLI dispatch are observable contracts.
# These fixtures run before cyclic inputs; a failed R6 check ends the run.
_r6_prior_cases = cases


def _r6_refusal(call):
    try:
        return ('returned', call())
    except BaseException as error:
        return (type(error).__name__, error.args)


def _r6_owned_refusals(R):
    answers = []
    for row in (
        {'id': 'nondict', 'gen': 42},
        {'id': 'f9', 'family': 'F9 AR(1)', 'gen': {'kind': 'noise'}},
    ):
        answers.append(_r6_refusal(lambda row=row: R.check_d14({'rows': [row]})))
    for malformed in ('roster', 'predicates', 'rules', 'rules-tail', 'verdict'):
        ds = fixture_decisions()
        if malformed == 'roster':
            del ds['CF']
        elif malformed == 'predicates':
            del ds['R3']['stable']
        elif malformed == 'rules':
            ds['R3']['converged']['rules'] = []
        elif malformed == 'rules-tail':
            ds['R3']['converged']['rules'][2].append('extra field')
        else:
            ds['R3']['converged']['verdict'] = 'FAIL'
        answers.append(_r6_refusal(lambda ds=ds: R.validate_decisions(ds)))
    # ValueError's string argument is supplied by this fixture. No Python-built
    # exception sentence or repr is an expected output.
    with patch.object(R, 'extract_checked', side_effect=ValueError('sentinel μ')):
        answers.append(_r6_refusal(lambda: R.extract({})))
    for malformed in ('controls', 'primary', 'H1-empty', 'primary-empty', 'preflight', 'preflight-missing', 'controls-and-primary', 'primary-and-empty', 'status'):
        raw = complete_raw()
        if malformed == 'controls':
            del raw['controls']
        elif malformed == 'primary':
            raw['primary'] = 'wrong'
        elif malformed == 'H1-empty':
            raw['populations']['H1']['rows'] = {}
        elif malformed == 'primary-empty':
            raw['primary'] = 'hcal'
            raw['populations'] = {'hcal': raw['populations']['H1']}
            raw['populations']['hcal']['rows'] = {}
        elif malformed == 'preflight':
            raw['preflight']['R3']['capabilities']['int64'] = 1
        elif malformed == 'preflight-missing':
            del raw['preflight']['R3']['capabilities']
        elif malformed == 'controls-and-primary':
            del raw['controls']
            raw['primary'] = 'wrong'
        elif malformed == 'primary-and-empty':
            raw['primary'] = 'wrong'
            raw['populations']['H1']['rows'] = {}
        else:
            raw['status'] = 'WRONG'
        answers.append(_r6_refusal(lambda raw=raw: R.extract(raw)))
    from types import SimpleNamespace
    with tempfile.TemporaryDirectory() as directory:
        with patch.object(R, 'command', return_value=SimpleNamespace(returncode=7)):
            answers.append(_r6_refusal(lambda: R.build('R3', 'abcdef12', Path(directory))))
    with patch.object(R.seal, 'fetch', return_value={}), patch.object(R.seal, 'checked', side_effect=SystemExit('seal sentinel μ')):
        answers.append(_r6_refusal(lambda: R.sealed_set(42, Path('unused'))))
    answers.append(_r6_refusal(lambda: R.check_roster([], {}, [])))
    answers.append(_r6_refusal(lambda: R.check_roster([], {}, 0)))
    answers.append(_r6_refusal(lambda: R.resolve('invalid SHA')))
    answers.append(_r6_refusal(lambda: wrapper_decide_fixture(R, {'R3': {'ieee': 'wrong', 'int64': True}})))
    answers.append(_r6_refusal(lambda: _r6_accounting_refusal(R)))
    return answers


def _r6_cli_dispatch(R):
    import reveal_selftest
    with tempfile.TemporaryDirectory() as directory:
        raw = Path(directory) / 'raw.json'
        raw.write_text('{}')
        with patch.object(reveal_selftest, 'run', return_value=73), patch.object(R, 'dry_a_ok', return_value=True):
            with contextlib.redirect_stdout(io.StringIO()):
                return (R.main(['--check-dry-a', str(raw)]),
                        R.main(['--selftest', '--check-dry-a', str(raw)]))


def _r6_commitment_refusals(R):
    # All three files here are synthetic fixture data, including the leaf named
    # reveal.py. The production driver's text is neither opened nor compared.
    import hashlib
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name in ('reveal.py', 'reveal_selftest.py', 'reveal_fixtures.json'):
            (root / name).write_text('synthetic ' + name)
        hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                  for name in ('reveal.py', 'reveal_selftest.py', 'reveal_fixtures.json')}
        record = {'format': 'r3-reveal-commitment/1', 'sha256': hashes}
        commitment = root / 'reveal_commitment.json'
        answers = []
        with patch.object(R, '__file__', str(root / 'reveal.py')):
            answers.append(_r6_refusal(R.verify_commitment))
            commitment.write_text(json.dumps(record | {'format': 'wrong'}))
            answers.append(_r6_refusal(R.verify_commitment))
            commitment.write_text(json.dumps(record | {'sha256': list(hashes)}))
            answers.append(_r6_refusal(R.verify_commitment))
            commitment.write_text(json.dumps(record | {'sha256': hashes | {'reveal_selftest.py': 'wrong'}}))
            answers.append(_r6_refusal(R.verify_commitment))
            commitment.write_text(json.dumps(record))
            (root / 'reveal_selftest.py').unlink()
            answers.append(_r6_refusal(R.verify_commitment))
            with patch.object(Path, 'read_text', side_effect=PermissionError('fixture read denied')):
                answers.append(_r6_refusal(R.verify_commitment))
        return answers


def _r6_entrypoint_diagnostic(R):
    observations = []
    for error_type in (R.Refusal, ValueError, R.J.HarnessError, OSError, R.subprocess.SubprocessError, TypeError):
        output = io.StringIO()
        with patch.object(R, 'main', side_effect=error_type('entry sentinel μ')), contextlib.redirect_stderr(output):
            result = _r6_refusal(R.cli_entrypoint)
        observations.append((result, output.getvalue()))
    return observations


def cases(R):
    yield ('R6-CLI-dispatch-priority', lambda: _r6_cli_dispatch(R), (0, 73))
    yield ('R6-owned-refusal-types-and-arguments', lambda: _r6_owned_refusals(R), [
        ('Refusal', ('INCOMPLETE: nondict: D14 unresolved base',)),
        ('Refusal', ('INCOMPLETE: f9: D14 unresolved base',)),
        ('Refusal', ('recorded subject roster incomplete',)),
        ('Refusal', ('recorded subject/predicate roster incomplete',)),
        ('Refusal', ('recorded rules incomplete: R3 converged',)),
        ('Refusal', ('recorded rules incomplete: R3 converged',)),
        ('Refusal', ('recorded verdict disagrees with rules: R3 converged',)),
        ('Refusal', ('malformed raw evidence: sentinel μ',)),
        ('Refusal', ('raw requires controls and subject preflight records',)),
        ('Refusal', ('decisions require H1 (or H-cal in DRY calibration mode)',)),
        ('Refusal', ('raw requires nonempty H1 rows',)),
        ('Refusal', ('raw requires nonempty primary population',)),
        ('Refusal', ('raw requires typed preflight evidence',)),
        ('Refusal', ('raw requires typed preflight evidence',)),
        ('Refusal', ('raw requires controls and subject preflight records',)),
        ('Refusal', ('decisions require H1 (or H-cal in DRY calibration mode)',)),
        ('Refusal', ('recorded status WRONG disagrees with evidence COMPLETE',)),
        ('Refusal', ('INCOMPLETE: R3 recipe failed; see build-R3.log',)),
        ('Refusal', ('seal sentinel μ',)),
        ('Refusal', ('INCOMPLETE: runtime roster missing or unsealed',)),
        ('Refusal', ('INCOMPLETE: runtime roster missing or unsealed',)),
        ('Refusal', ('arm identity must be a hexadecimal commit SHA',)),
        ('Refusal', ('capability values must be boolean',)),
        ('Refusal', ('INCOMPLETE: measurement/order accounting differs',)),
    ])
    yield ('R6-commitment-refusal-types-and-arguments', lambda: _r6_commitment_refusals(R), [
        ('Refusal', ('accepted reveal commitment unavailable or malformed',)),
        ('Refusal', ('accepted reveal commitment is malformed',)),
        ('Refusal', ('accepted reveal commitment is malformed',)),
        ('Refusal', ('accepted reveal commitment mismatch: reveal_selftest.py',)),
        ('Refusal', ('accepted reveal commitment mismatch: reveal_selftest.py',)),
        ('Refusal', ('accepted reveal commitment unavailable or malformed',)),
    ])
    yield ('R6-entrypoint-exact-diagnostic', lambda: _r6_entrypoint_diagnostic(R),
           [(('SystemExit', (2,)), 'REFUSED: entry sentinel \\u03bc\n')] * 5 + [(('TypeError', ('entry sentinel μ',)), '')])
    yield from _r6_prior_cases(R)

_r6_message_cases = cases


def _r6_boolean_boundaries(R):
    answers = []
    ds = fixture_decisions()
    answers.append(R.status_for(0, ds, {'a': True, 'b': True, 'c1': True, 'c2': True, 'extra': True}))
    points = {p: Q(1, 2) for p in FIXTURE_PREDS}
    points.update(stable=None, improving=None)
    answers.append(R.controls_ok(True, points, ds, (Q(1, 20), 0.01))['b_undefined'])
    raw = diagnostic_fixture()
    for fact in raw['preflight'].values():
        fact['floor_exit'] = '0'
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    raw['preflight']['R3']['floor_exit'] = 1
    del raw['preflight']['R3-STD']
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    raw['populations']['hcal']['labels'] = {}
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    pop = raw['populations']['hcal']
    pop['points'][0][2] = '3/5'
    del pop['decisions']['CF']['stable']
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    labels = raw['populations']['hcal']['labels']
    labels['r@1']['diverging'][1] = True
    labels['s@1'] = {'equilibrium': ['MATH', False]}
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    pop = raw['populations']['hcal']
    pop['labels']['s@1'] = {p: ['MATH', p == 'diverging'] for p in FIXTURE_PREDS}
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    raw['status'], raw['populations'] = 'VOID', 0
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    raw['populations']['calibration']['judge_rc'] = 2
    del raw['controls']
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    raw['controls'] = {}
    del raw['preflight']
    answers.append(R.dry_a_ok(raw))
    raw = diagnostic_fixture()
    raw['populations']['hcal']['points'] += [['INC', p, '3/5'] for p in FIXTURE_PREDS]
    answers.append(R.dry_a_ok(raw))
    answers.append(R.status_for(0, {}, {'a': False, 'b': True, 'c1': True, 'c2': True}))
    return answers


def _r6_missing_family15(R):
    raw = diagnostic_fixture()
    pop = raw['populations']['hcal']
    pop['rows'] = {'plain': {'family': 'F1 fixture'}, 'scaled': {'family': 'F15 fixture'}}
    mixed = 'no-family-15' in R.incomplete_reasons(raw)
    pop['rows'] = {}
    empty = R.incomplete_reasons(raw)
    pop['rows'] = {'scaled': {'family': 'F15 fixture'}, 'malformed': {}}
    short = 'no-family-15' in R.incomplete_reasons(raw)
    controls = []
    for name in ('c1', 'c2'):
        value = complete_raw()
        value['controls'][name] = False
        controls.append(R.incomplete_reasons(value))
    canonical = []
    for undefined, expected in _R6B_UNDEFINED_CASES:
        value = complete_raw('INCOMPLETE')
        pop = value['populations']['H1']
        pop['points'] = [['CF', p, None] for p in undefined]
        pop['decisions']['R3'][undefined[0]] = registered_verdict(undefined[0], missing=('1 standard parity',))
        canonical.append(R.incomplete_reasons(value))
    return mixed, empty, short, controls, canonical


def _r6_terminal_kinds(R):
    answers = []
    for kind in ('affine', 'pieces', 'closed', 'recur', 'cycle', 'noise', 'walk', 'uwalk'):
        row = {'id': kind, 'family': 'F15b base from F1 fixture', 'gen': {'kind': kind}}
        answers.append(R.check_d14({'rows': [row]}))
    return answers


def _r6_exception_shapes(R):
    # Pin exception types only where CPython supplies the sentence.
    answers = []
    raw = complete_raw()
    raw['populations']['H1']['readings'] = [['short']]
    try:
        R.extract(raw)
        answers.append('accepted')
    except BaseException as error:
        answers.append(type(error).__name__)
    with patch.object(R, 'extract_checked', side_effect=RuntimeError('seam failure')):
        try:
            R.extract({})
            answers.append('accepted')
        except BaseException as error:
            answers.append(type(error).__name__)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        commitment = root / 'reveal_commitment.json'
        with patch.object(R, '__file__', str(root / 'synthetic-driver')):
            for text in ('{', '{}', '[]'):
                commitment.write_text(text)
                try:
                    R.verify_commitment()
                    answers.append('accepted')
                except BaseException as error:
                    answers.append(type(error).__name__)
            with patch.object(Path, 'read_text', side_effect=RuntimeError('read boundary')):
                try:
                    R.verify_commitment()
                    answers.append('accepted')
                except BaseException as error:
                    answers.append(type(error).__name__)
    raw = diagnostic_fixture()
    del raw['populations']['hcal']['decisions']['CF']['converged']
    raw['populations']['hcal']['points'][1][2] = None
    try:
        answers.append(R.dry_a_ok(raw))
    except BaseException as error:
        answers.append(type(error).__name__)
    raw = complete_raw('FINDING')
    secondary = copy.deepcopy(raw['populations']['H1'])
    raw['populations']['H1']['judge_rc'] = 0
    raw['populations']['calibration'] = secondary
    try:
        answers.append(R.extract(raw)['status'])
    except BaseException as error:
        answers.append(type(error).__name__)
    return answers


def _r6_population_row_order(R):
    pop = complete_raw()['populations']['H1']
    pop['rows'] = {rid: {'id': rid, 'family': 'F1 fixture', 'checkpoints': [1]} for rid in ('z', 'a', 'm')}
    pop['labels'] = {rid + '@1': {p: ['MATH', False] for p in FIXTURE_PREDS} for rid in ('z', 'a', 'm')}
    pop['readings'] = []
    tiny = copy.deepcopy(pop)
    del tiny['rows']['m']
    with patch.object(R, 'ROSTER', {'R3': ('converged',)}):
        confusion = R.whole_population(tiny)['confusion']
    # The key is composed by the driver; the expected JSON text is literal.
    expected = {'["R3", "converged", "F1 fixture"]': [0, 0, 0, 0]}
    if confusion != expected:
        return confusion, []
    return confusion, R.whole_population(pop)['absent'][:8]


def _r6_parser_contract(R):
    answers = []
    with tempfile.TemporaryDirectory() as directory:
        def parser_error(parser, message):
            answers.append(message)
            raise SystemExit(2)
        with patch.object(R.argparse.ArgumentParser, 'error', new=parser_error):
            for options in ([], ['--out', str(Path(directory) / 'out')], ['--calibration', '--out', str(Path(directory) / 'calibration')]):
                try:
                    R.main(options)
                except SystemExit:
                    pass
        with patch.object(R, 'execute', return_value=77):
            try:
                R.main(['--dry', '--calibration', '--r3', 'abcdef12', '--resamples', '1+1', '--out', str(Path(directory) / 'expression')])
            except SystemExit as error:
                answers.append(error.code)
            else:
                answers.append('accepted expression')
        answers.append(_r6_refusal(lambda: R.main(['--calibration', '--r3', 'abcdef12', '--resamples', '0', '--out', str(Path(directory) / 'zero')])))
    return answers


def cases(R):
    yield ('R6-CLI-dispatch-priority', lambda: _r6_cli_dispatch(R), (0, 73))
    yield ('R6-boolean-short-circuit-and-status-boundaries', lambda: _r6_boolean_boundaries(R),
           ['VOID', ['improving', 'stable'], True, False, True, False, False, False, False, False, False, True, 'INCOMPLETE'])
    yield ('R6-no-family15-mixed-and-empty', lambda: _r6_missing_family15(R),
           (False, ['no-family-15', 'undefined-BA:diverging,equilibrium'], False, [['control:c1'], ['control:c2']], [[expected] for _, expected in _R6B_UNDEFINED_CASES]))
    yield ('R6-D14-all-terminal-kinds', lambda: _r6_terminal_kinds(R), [[]] * 8)
    yield ('R6-exception-types-on-malformed-JSON-evidence', lambda: _r6_exception_shapes(R),
           ['Refusal', 'RuntimeError', 'Refusal', 'Refusal', 'Refusal', 'RuntimeError', 'KeyError', 'FINDING'])
    yield ('R6-whole-population-canonical-row-order', lambda: _r6_population_row_order(R),
           ({'["R3", "converged", "F1 fixture"]': [0, 0, 0, 0]},
            [['R3', 'a', 1, p] for p in FIXTURE_PREDS] + [['R3', 'm', 1, 'converged'], ['R3', 'm', 1, 'stable']]))
    yield ('R6-CLI-parser-error-arguments-and-integer-converter', lambda: _r6_parser_contract(R),
           ['--out required', '--r3 and --round required (or --dry --calibration)', '--r3 and --round required (or --dry --calibration)', 2, ('Refusal', ('calibration mode is DRY only',))])
    for fixture in _r6_message_cases(R):
        if fixture[0] != 'R6-CLI-dispatch-priority':
            yield fixture

# Ruling R30R-6 permits exception-type pins on built-in-malformed rows.
_r6_before_continuation_cases = cases


def _r6_d14_acyclic_metadata(R):
    ids = ('R3', 'id', 'rows', 'kind', 'reveal.py', '__main__', 'Round 3',
           '3d8a14b4', '3eed5caf', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697',
           'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4')
    observed = []
    for base_id in ids:
        gen = {'kind': 'ar1', 'phi': '0.9', 'burn': 200}
        source = {'id': base_id, 'family': 'F9 AR1', 'gen': dict(gen)}
        head = {'id': 'acyclic-copy', 'family': 'F15 unit-scaled copies',
                'base': base_id, 'gen': dict(gen)}
        observed.append(R.check_d14({'rows': [source, head]}))
    chain_ids = ('3d8a14b4', '3eed5caf', '4a3a5c1941568e9bc562c7c8221cff22dc8ba697',
                 'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4',
                 '__main__', str(R.__file__), _R6_MULTILINE_METADATA_ID)
    chain_ok = True
    for opaque_id in chain_ids:
        for middle_id, leaf_id in ((opaque_id, 'history-leaf'), ('history-middle', opaque_id)):
            gen = {'kind': 'ar1', 'phi': '0.9', 'burn': 200}
            head = {'id': 'history-head', 'family': 'F15 unit-scaled copies', 'base': middle_id, 'gen': dict(gen)}
            middle = {'id': middle_id, 'family': 'F15 unit-scaled copies', 'base': leaf_id, 'gen': dict(gen)}
            leaf = {'id': leaf_id, 'family': 'F9 AR1', 'gen': dict(gen)}
            chain_ok = chain_ok and R.check_d14({'rows': [head, middle, leaf]}) == ['history-head', middle_id, leaf_id]
    return observed, chain_ok


def _r6_d14_family_conversion(R):
    observed = []
    for family in ('F6 sinusoid', 'F06 sinusoid', 'F' + '9' * 5000 + ' unknown'):
        source = {'id': 'base', 'family': family, 'gen': {'kind': 'affine'}}
        head = {'id': 'copy', 'family': 'F15 unit-scaled copies', 'base': 'base', 'gen': {'kind': 'affine'}}
        try:
            observed.append(R.check_d14({'rows': [head, source]}))
        except BaseException as error:
            observed.append(type(error).__name__)
    return observed


def _r6_execute_evidence(R, mode):
    """Actual main/execute/extract/write path, controlled external IO inputs."""
    from types import SimpleNamespace
    plants = 'RED  floor-each rc=1\nplants: 1 examined, 1 red (controls included)\n'
    if mode == 'plants-prefixed':
        reply = SimpleNamespace(returncode=0, stdout='instrument preamble\n' + plants)
    elif mode == 'plants-exit':
        reply = SimpleNamespace(returncode=1, stdout=plants)
    elif mode == 'plants-missing-row':
        reply = SimpleNamespace(returncode=0, stdout='controls -= floor-\nplants: 1 examined, 1 red \n')
    elif mode == 'plants-missing-summary':
        reply = SimpleNamespace(returncode=0, stdout='RED  floor-each rc=1\ncontrols: n, 1 \n')
    else:
        reply = SimpleNamespace(returncode=0, stdout=plants)
    with tempfile.TemporaryDirectory() as directory:
        out = Path(directory) / 'run'
        shas = {'3d8a14b4': 'a' * 40, '3eed5caf': 'b' * 40,
                '4a3a5c1941568e9bc562c7c8221cff22dc8ba697': 'c' * 40, 'candidate': 'd' * 40}
        inc_resolutions = []
        def resolve(sha):
            if mode == 'dry-distinct-W4' and sha == '3d8a14b4':
                inc_resolutions.append(sha)
                return ('a' if len(inc_resolutions) == 1 else 'e') * 40
            return shas.get(sha, sha)
        def build(name, sha, output):
            if mode == 'malformed-build':
                return []
            return {'binary': 'fixture-' + name, 'source_sha': sha}
        def floor(binary, output, name):
            caps = {'int64': True, 'ieee': True}
            if name == 'R3' and mode in ('typed-first', 'typed-last'):
                caps = {'int64': 'wrong', 'ieee': True} if mode == 'typed-first' else {'int64': True, 'ieee': 'wrong'}
            if name == 'R3' and mode == 'caps-empty':
                caps = {}
            return {'floor_exit': 1 if name == 'R3' and mode == 'real-inc-floor' else 0,
                    'declarations': [], 'capabilities': caps}
        def copy_file(source, destination):
            Path(destination).write_text('synthetic visible input')
        def current_manifest(path, binaries):
            return {'set': {'corpus.json': 'fixture-set'}, 'programs': [],
                    'code': {'fixture': 'fixture-code'},
                    'arms': {a: {'lib': 'fixture-lib', 'recipe_id': None, 'binary_sha256': binary}
                             for a, binary in binaries.items()}}
        def manifest(path, binaries):
            value = current_manifest(path, binaries)
            if mode == 'manifest-gap' and Path(path).name == 'hcal':
                value['arms'] = {}
            (Path(path) / 'manifest.json').write_text(json.dumps(value))
            return value
        def prepare(path, binaries, output):
            Path(path).mkdir(exist_ok=True)
            return {'manifest': manifest(path, binaries), 'sha256': 'fixture'}
        real_read_text = Path.read_text
        cached_gap_read = []
        def read_text(path, *args, **kwargs):
            text = real_read_text(path, *args, **kwargs)
            if (mode == 'cached-manifest-gap' and path.name == 'manifest.json'
                    and path.parent.name == 'calibration' and not cached_gap_read):
                # Model evidence read before a later, complete physical manifest.
                # The real validator below still reads the complete private file.
                cached_gap_read.append(True)
                record = json.loads(text)
                record['arms'] = {}
                return json.dumps(record)
            return text
        def population(paths, binaries, facts, seed, resamples, output, name):
            for path in paths:
                R.J.F.verify_manifest(str(path), binaries)
            pop = complete_raw()['populations']['H1']
            pop['judge_rc'] = 1 if mode == 'secondary-finding' and name == 'calibration' else 0
            # Real points contain other arms as well as CF. Only CF may decide b.
            pop['points'] += [['INC', p, '3/5'] for p in FIXTURE_PREDS]
            if mode == 'CF-undefined':
                pop['points'][0][2] = None
            for arm in ('R3', 'R3-STD', 'CF', 'W4'):
                for pred in FIXTURE_PREDS:
                    for rule in pop['decisions'][arm][pred]['rules']:
                        if rule[0] == '6 existing gates':
                            rule[1:] = ['FAIL' if (arm == 'W4' or arm == 'CF' and mode != 'CF-capable' or mode == 'dry-distinct-W4') else 'PASS', 'floor/caps fixture']
                            if mode == 'dry-distinct-W4':
                                pop['decisions'][arm][pred]['verdict'] = 'FAIL'
            return pop
        command_calls = []
        def command(argv, log):
            command_calls.append((argv, log))
            return reply
        observed_raw = {}
        def record_outputs(raw, destination):
            observed_raw.update(copy.deepcopy(raw))
            real_outputs(raw, destination)
        real_outputs = R.write_outputs
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            for name, replacement in (
                ('resolve', resolve), ('build', build), ('floor', floor),
                ('install_instrument', lambda *args: {'score_sha256': 'fixture-scorer'}),
                ('judge_population', population), ('command', command),
                ('verify_commitment', lambda: None), ('write_outputs', record_outputs),
                ('sealed_set', lambda *args: {'round': 42}),
                ('prepare_set', prepare),
            ):
                stack.enter_context(patch.object(R, name, new=replacement))
            stack.enter_context(patch.object(R.shutil, 'copyfile', new=copy_file))
            stack.enter_context(patch.object(R.J.F, 'write_manifest', new=manifest))
            stack.enter_context(patch.object(R.J.F, 'manifest_of', new=current_manifest))
            stack.enter_context(patch.object(Path, 'read_text', new=read_text))
            # Values are synthetic and never read driver bytes. The self-hash
            # field is intentionally excluded from the assertion below.
            stack.enter_context(patch.object(R.J, 'HERE', str(Path(directory) / 'instrument/tools/observer_oracle')))
            stack.enter_context(patch.object(R.J.F, 'sha', return_value='synthetic'))
            stack.enter_context(patch.object(R.J.score, 'capabilities', return_value=(None, {'int64': mode != 'dry-distinct-W4', 'ieee': mode != 'dry-distinct-W4'})))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            argv = ['--r3', '3d8a14b4' if mode == 'real-inc-floor' else 'candidate',
                    '--round', '42', '--out', str(out)]
            if mode == 'dry-distinct-W4':
                argv = ['--dry', '--r3', 'a' * 40, '--r3-std', 'c' * 40, '--round', '42', '--out', str(out)]
            elif mode != 'real-inc-floor':
                argv += ['--dry', '--calibration']
            try:
                entry = R.main
                with patch.object(R, 'main', side_effect=RuntimeError('unexpected nested CLI dispatch')), \
                        patch.object(R, 'cli_entrypoint', side_effect=RuntimeError('unexpected nested CLI entrypoint')):
                    rc = entry(argv)
                uncaught = None
            except BaseException as error:
                rc, uncaught = 'uncaught', type(error).__name__
        raw = json.loads((out / 'raw.json').read_text()) if (out / 'raw.json').exists() else observed_raw
        error = raw.get('error') is not None if mode == 'manifest-gap' else raw.get('error')
        result = (rc, uncaught, raw.get('status'), error, raw.get('controls'),
                raw.get('control_c1_rule6'),
                sum(line.startswith(('OUTCOME ', 'DRY OUTCOME ')) for line in stdout.getvalue().splitlines()),
                (out / 'decision.json').exists())
        if mode == 'dry-distinct-W4':
            result += (raw.get('preflight', {}).get('R3', {}).get('rule6'),)
        if mode == 'command-contract':
            import sys
            result += (command_calls == [([sys.executable, Path(directory) / 'instrument/tools/observer_oracle/plants.py', '--selftest'], out / 'plants.log')],)
        return result


def _r6_execute_controls(R):
    return [_r6_execute_evidence(R, mode) for mode in
            ('green', 'plants-exit', 'plants-missing-row', 'plants-missing-summary', 'CF-undefined', 'secondary-finding', 'plants-prefixed', 'dry-distinct-W4', 'malformed-build', 'manifest-gap', 'CF-capable', 'command-contract', 'cached-manifest-gap')]


def _r6_execute_preflight(R):
    return [_r6_execute_evidence(R, mode) for mode in ('typed-first', 'typed-last', 'real-inc-floor', 'caps-empty')]


def _r6_seal_builtin_type(R):
    import hashlib
    with patch.object(R.seal, 'fetch', return_value={'round': 42, 'randomness': None}):
        try:
            R.sealed_set(42, Path('unused'))
        except BaseException as error:
            malformed = type(error).__name__
        else:
            malformed = 'accepted'
    signature = 'ab' * 32
    beacon = {'round': True, 'signature': signature,
              'randomness': hashlib.sha256(bytes.fromhex(signature)).hexdigest()}
    with patch.object(R.seal, 'fetch', return_value=beacon), patch.object(R.J.F, 'build', return_value={}), patch.object(R.J.F, 'write'), patch.object(R.J.F, 'write_manifest'):
        record = R.sealed_set(1, Path('unused'))
    return malformed, type(record['round']).__name__, record['round']


def cases(R):
    # Keep the recursion-dispatch witness before every fixture calling main.
    yield ('R6-CLI-dispatch-priority', lambda: _r6_cli_dispatch(R), (0, 73))
    yield ('R6-D14-acyclic-opaque-metadata', lambda: _r6_d14_acyclic_metadata(R), ([
        ['R3', 'acyclic-copy'], ['id', 'acyclic-copy'], ['rows', 'acyclic-copy'],
        ['kind', 'acyclic-copy'], ['reveal.py', 'acyclic-copy'], ['__main__', 'acyclic-copy'],
        ['Round 3', 'acyclic-copy'], ['3d8a14b4', 'acyclic-copy'], ['3eed5caf', 'acyclic-copy'],
        ['4a3a5c1941568e9bc562c7c8221cff22dc8ba697', 'acyclic-copy'],
        ['e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4', 'acyclic-copy']], True))
    yield ('R6-D14-family-conversion-and-malformed-type', lambda: _r6_d14_family_conversion(R), [[], [], 'ValueError'])
    yield ('R6-execute-controls-and-recorded-evidence', lambda: _r6_execute_controls(R), [
        (0, None, 'COMPLETE', None, {'a': True, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 6, True),
        (2, None, 'VOID', None, {'a': False, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 0, True),
        (2, None, 'VOID', None, {'a': False, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 0, True),
        (2, None, 'VOID', None, {'a': False, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 0, True),
        (2, None, 'INCOMPLETE', None, {'a': True, 'b': 'undefined', 'b_undefined': ['converged'], 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 0, True),
        (2, None, 'FINDING', None, {'a': True, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 0, True),
        (0, None, 'COMPLETE', None, {'a': True, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 6, True),
        (0, None, 'COMPLETE', None, {'a': True, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 6, True, 'NOT APPLICABLE (stand-in)'),
        ('uncaught', 'TypeError', None, None, None, None, 0, False),
        (2, None, 'INCOMPLETE', True, None, None, 0, False),
        (0, None, 'COMPLETE', None, {'a': True, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 6, True),
        (0, None, 'COMPLETE', None, {'a': True, 'b': True, 'c1': True, 'c2': True}, [['6 existing gates', 'FAIL', 'floor/caps fixture']], 6, True, True),
        (2, None, 'INCOMPLETE', 'INCOMPLETE: runtime roster missing or unsealed', None, None, 0, False),
    ])
    yield ('R6-execute-typed-preflight-and-real-floor', lambda: _r6_execute_preflight(R), [
        (2, None, 'REFUSED', 'capability values must be boolean in preflight', None, None, 0, False),
        (2, None, 'REFUSED', 'capability values must be boolean in preflight', None, None, 0, False),
        (2, None, 'REFUSED', 'rule 6 preflight failed; no beacon read, SHA is not final', None, None, 0, False),
        (2, None, 'REFUSED', 'rule 6 preflight failed; no beacon read, SHA is not final', None, None, 0, False),
    ])
    yield ('R6-seal-malformed-response-exception-type', lambda: _r6_seal_builtin_type(R), ('TypeError', 'bool', True))
    for fixture in _r6_before_continuation_cases(R):
        if fixture[0] != 'R6-CLI-dispatch-priority':
            yield fixture


def _r6_accounting_refusal(R):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        def main(argv):
            R.J.run_arms({}, {}, 1758)
            return 0
        with patch.object(R.J, 'load', return_value=({'rows': []}, {})), \
                patch.object(R.J, 'run_arms', return_value=({}, [], set(), [('R3', 'r')], {})), \
                patch.object(R.J, 'main', new=main):
            return R.judge_population([root], {'R3': 'r3', 'CF': 'cf'}, {}, 1758, 3, root, 'accounting')


def _r6_capabilities_after_population(R):
    results = []
    capabilities = (None, {'int64': False, 'ieee': True})
    def main(argv):
        results.append(R.J.score.capabilities('fixture'))
        R.J.run_arms({}, {}, 1758)
        return 0
    def measure(binary, corpus, caps):
        return {'read': {}}
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        with patch.object(R.J, 'load', return_value=({'rows': []}, {})), \
                patch.object(R.J, 'run_arms', return_value=({}, [], set(), [], {})), \
                patch.object(R.J.score, 'measure', new=measure), \
                patch.object(R.J.score, 'capabilities', return_value=capabilities), \
                patch.object(R.J, 'main', new=main):
            R.judge_population([root], {'R3': 'r3', 'CF': 'cf'}, {}, 1758, 3, root, 'first')
            results.append(R.J.score.capabilities('fixture'))
    return results


def _r6_written_boundary(R):
    observations = []
    real_dump = R.dump
    with tempfile.TemporaryDirectory() as directory:
        for index, status in enumerate(('COMPLETE', 'VOID')):
            out = Path(directory) / str(index)
            out.mkdir()
            raw = complete_raw(status, dry=True)
            def write_with_input_change(path, value):
                real_dump(path, value)
                if Path(path).name == 'raw.json':
                    reread = copy.deepcopy(value)
                    if status == 'COMPLETE':
                        reread['dry'] = False
                    else:
                        reread['status'] = 'INCOMPLETE'
                        for pop in reread['populations'].values():
                            pop['judge_rc'] = 2
                    real_dump(path, reread)
            stdout = io.StringIO()
            with patch.object(R, 'dump', new=write_with_input_change), contextlib.redirect_stdout(stdout):
                R.write_outputs(raw, out)
            observations.append(stdout.getvalue())
    return observations


_r6_enriched_cases = cases


def cases(R):
    yield ('R6-CLI-dispatch-priority', lambda: _r6_cli_dispatch(R), (0, 73))
    yield ('R6-capabilities-available-after-population-recording', lambda: _r6_capabilities_after_population(R),
           [(None, {'int64': False, 'ieee': True})] * 2)
    yield ('R6-written-status-and-dry-use-recorded-input', lambda: _r6_written_boundary(R), [
        'DRY OUTCOME converged: R3; silent-wrong=False; STD_p/H2=False\n'
        'DRY OUTCOME stable: R3; silent-wrong=False; STD_p/H2=False\n'
        'DRY OUTCOME improving: R3; silent-wrong=False; STD_p/H2=False\n'
        'DRY OUTCOME oscillating: R3; silent-wrong=False; STD_p/H2=False\n'
        'DRY OUTCOME diverging: R3; silent-wrong=False; STD_p/H2=False\n'
        'DRY OUTCOME equilibrium: R3; silent-wrong=False; STD_p/H2=False\nCOMPLETE\n',
        'VOID\nfailed controls: a; step 1 is repeated\n',
    ])
    for fixture in _r6_enriched_cases(R):
        if fixture[0] != 'R6-CLI-dispatch-priority':
            yield fixture

_R6_MULTILINE_METADATA_ID = 'Round 3 reveal driver (#2330, #1758; RULING R30R-2).\n\nFirst matching row, independently for each predicate, using the frozen judge:\n R3 verdict PASS     -> R3:     "All six criteria pass: R3\'s band ships."\n R3-STD verdict PASS -> R3-STD: "Otherwise R3-STD ships for that predicate."\n otherwise           -> INC:    "INC\'s band stays for p, R3\'s change to p is\n                                reverted, and the table is posted."\nAdditive duties from R3: rule 4 FAIL -> silent-wrong issue + measured BA in\nPREDICATES.md; rules 2..5 PASS and rule 1 FAIL -> STD_p replacement on fresh H2.\nRule 2 against R3-STD stays exactly where the frozen judge puts it.\nNo outcome on REFUSED, INCOMPLETE, FINDING or VOID. VOID repeats step 1.\n\nRaw format r3-reveal/1: raw.json is a JSON object, sorted keys, UTF-8, newline.\n metadata: dry, seed (run order AND bootstrap), resamples, runtime arm stamps,\n           manifests (sha256 + full instrument manifest), driver file hashes.\n preflight: per subject floor exit, relevant declaration lines and capabilities.\n populations: calibration and H1 (or hcal in dry calibration mode). Each holds\n  rows: id -> full corpus row; labels: row@checkpoint -> derive label objects;\n  order: ordered [runtime arm, row] pairs; capabilities; skipped; findings;\n  readings: [arm,row,checkpoint,predicate,boolean] for interp/straight and Python\n            arms; absence is explicit in skipped, partial Python arm domains\n            are ROSTER below. tiers: [arm,tier,form,row,checkpoint,predicate,bool].\n  decisions: subject -> predicate -> {verdict,rules}; rules is an ordered list\n             [rule-name,PASS|FAIL|NOT EVALUATED,judge\'s explanation].\n  points: [arm,predicate,BA rational or null]; diffs: [A,B,p,d,lo,hi,left_out]\n          d is exact rational; CI endpoints are floats as printed by judge.\n  judge_rc; judge_text is an informational transcript, NOT extraction input.\n controls: a,c1,c2 booleans; b is true, false or "undefined". When b is\n  undefined, b_undefined lists the predicates without BA. False takes priority\n  over undefined if a defined predicate fails. status is rechecked on extraction.\n\nCanonical decision.json is derived ONLY from raw.json: status, dry, seed,\nresamples, exact family confusion tables / disagreements / absences and (if COMPLETE) for each predicate both subjects\' ordered rule names\nand statuses, verdicts, ship and additive duties. No paths, binary hashes,\nhostname, Python version, timestamps or rounded explanatory text enter it.\nRecompute via --extract RAW --out DIR. To replicate statistics independently,\nuse labels + readings to form TP FP FN TN; use rows as bootstrap clusters,\nrandom.Random(seed), 10000 shared draws as judge.py specifies (D9 shared-row\nsubsets have their own stream). Whole-population JSON files are also extracted\nonly from raw, with explicit null readings and every disagreement.\n\nCLI: --r3 SHA --r3-std SHA --round N --out DIR [--dry] [--calibration]\n     --calibration is allowed only with --dry (calibration + H-cal, no beacon).\nRuntime paths are never CLI inputs. Recipes build serially into build/ beneath\nthis checkout. --resamples defaults to registered 10000; lower is DRY only.\nManual review verdicts must be recorded by the orchestrator before H1 scoring.\nBefore unsealing, reveal_commitment.json must match the accepted hashes of this\ndriver, reveal_selftest.py and reveal_fixtures.json (the named fixture inventory).\n'



def _r6_generator_multiline_metadata(R):
    results = []
    captured = io.StringIO()
    for middle_id, leaf_id in ((_R6_MULTILINE_METADATA_ID, 'leaf'), ('middle', _R6_MULTILINE_METADATA_ID)):
        leaf = {'id': leaf_id, 'family': 'F9 AR1', 'gen': {'kind': 'ar1', 'phi': '0.9', 'burn': 200}}
        middle = {'id': middle_id, 'family': 'F9 AR1', 'gen': {'kind': 'scaled', 'base': leaf_id}}
        head = {'id': 'head', 'family': 'F15 unit-scaled copies', 'gen': {'kind': 'scaled', 'base': middle_id}}
        with contextlib.redirect_stdout(captured):
            results.append(R.check_d14({'rows': [head, middle, leaf]}))
    return results, captured.getvalue()


_r6_before_multiline_cases = cases


def cases(R):
    yield ('R6-CLI-dispatch-priority', lambda: _r6_cli_dispatch(R), (0, 73))
    yield ('R6-D14-multiline-opaque-generator-metadata', lambda: _r6_generator_multiline_metadata(R),
           ([['head', _R6_MULTILINE_METADATA_ID, 'leaf'], ['head', 'middle', _R6_MULTILINE_METADATA_ID]], ''))
    for fixture in _r6_before_multiline_cases(R):
        if fixture[0] != 'R6-CLI-dispatch-priority':
            yield fixture


def _r6_tiers_skip_and_order(R):
    # A skipped first arm must not label the measured second arm's tier data.
    row = {'id': 'r', 'family': 'F1 fixture', 'gen': {'kind': 'cycle', 'values': [1]}, 'n': 32, 'checkpoints': list(range(1, 33))}
    readings = {('interp', 'straight', 'r', t, 'converged'): False for t in list(range(2, 33)) + [1]}
    result = ({'R3': {}, 'CF': {'r': {(1, 'converged'): False}}}, [], [('W4', 'r', 'ieee'), ('R3', 'r', 'ieee')], [('R3', 'r'), ('W4', 'r'), ('CF', 'r')], {})
    def run_arms(bs, rows, seed):
        R.J.score.measure('cf', {'rows': [row]}, {})
        return result
    def main(argv):
        R.J.run_arms({}, {}, 1758)
        return 0
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        with patch.object(R.J, 'load', return_value=({'rows': [row]}, {})), \
                patch.object(R.J.score, 'measure', return_value={'read': readings}), \
                patch.object(R.J, 'run_arms', new=run_arms), patch.object(R.J, 'main', new=main), \
                patch.object(R.J.S, 'ARMS', {}), patch.object(R.J.S, 'tol_converged', return_value=lambda xs, t: False):
            pop = R.judge_population([root], {'R3': 'r3', 'CF': 'cf'}, {}, 1758, 3, root, 'tiers')
    expected = [['CF', 'interp', 'straight', 'r', t, 'converged', False] for t in range(1, 33)]
    return pop['tiers'] == expected and pop['skipped'] == [('R3', 'r', 'ieee'), ('W4', 'r', 'ieee')]


def _r6_point_capture_order(R):
    point = {('CF', 'stable'): Q(1, 2), ('R3', 'stable'): Q(4, 5), ('CF', 'converged'): Q(1, 2)}
    def original_decide(*args):
        print('fixture statistics')
    def diff(*args):
        return Q(1, 20), 0.001, 0.1, 0
    caps = {a: {'int64': True, 'ieee': True} for a in ('R3', 'R3-STD', 'CF', 'W4')}
    def main(argv):
        R.J.run_arms({}, {}, 1758)
        for subject in ('R3', 'R3-STD', 'CF', 'W4'):
            R.J.decide({}, subject, [], point, {}, diff, {}, {}, 1, caps)
        return 0
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        with patch.object(R.J, 'load', return_value=({'rows': []}, {})), \
                patch.object(R.J, 'run_arms', return_value=({}, [], set(), [], caps)), \
                patch.object(R.J, 'decide', new=original_decide), patch.object(R.J, 'main', new=main):
            pop = R.judge_population([root], {'R3': 'r3', 'CF': 'cf'}, {'R3': {'floor_exit': 0, 'declarations': []}}, 1758, 3, root, 'points')
    return pop['points']


_r6_before_recording_cases = cases


def cases(R):
    yield ('R6-CLI-dispatch-priority', lambda: _r6_cli_dispatch(R), (0, 73))
    yield ('R6-runtime-tier-order-and-skip-association', lambda: _r6_tiers_skip_and_order(R), True)
    yield ('R6-captured-point-canonical-order', lambda: _r6_point_capture_order(R),
           [['CF', 'converged', '1/2'], ['CF', 'stable', '1/2'], ['R3', 'stable', '4/5']])
    for fixture in _r6_before_recording_cases(R):
        if fixture[0] != 'R6-CLI-dispatch-priority':
            yield fixture


# Checkpoint 6b: keep ROOT first and fail bounded helper-call faults before any
# older cyclic or large-population fixture. These are API calls, not source reads.
def _r6b_helper_boundaries(R):
    from types import SimpleNamespace
    reply = SimpleNamespace(returncode=7, stdout='fixture child stdout\n')
    with tempfile.TemporaryDirectory() as directory:
        log = Path(directory) / 'child.log'
        with patch.object(R, 'main', side_effect=RuntimeError('unexpected nested CLI dispatch')), \
                patch.object(R, 'cli_entrypoint', side_effect=RuntimeError('unexpected nested CLI entrypoint')), \
                patch.object(R, 'build_env', return_value={'fixture': 'env'}), \
                patch.object(R.subprocess, 'run', return_value=reply) as child:
            preflight = R.preflight_ok({'floor_exit': 0, 'declarations': [], 'capabilities': {'int64': True, 'ieee': True}})
            d14 = R.check_d14({'rows': [{'id': 'safe', 'family': 'F9 AR1', 'gen': {'kind': 'ar1', 'phi': '0.9', 'burn': 200}}]})
            reasons = R.incomplete_reasons(complete_raw())
            process = R.command(['tool', Path('input'), 7], log)
            return preflight, d14, reasons, process.returncode, log.read_text(), child.call_args.args[0]

_r6b_before_root_order_cases = cases


def cases(R):
    yield _round5_root_preflight_case(R)
    source = iter(_r6b_before_root_order_cases(R))
    pending = []
    for fixture in source:
        if fixture[0] == 'R6-whole-population-canonical-row-order':
            key_fixture = fixture
            break
        pending.append(fixture)
    # Dispatch still precedes every fixture that can re-enter the selftest.
    dispatch = next(f for f in pending if f[0] == 'R6-CLI-dispatch-priority')
    yield dispatch
    yield key_fixture
    yield ('R6-helper-calls-do-not-reenter-cli', lambda: _r6b_helper_boundaries(R),
           (True, ['safe'], [], 7, 'fixture child stdout\n', ['tool', 'input', '7']))
    for fixture in pending:
        if fixture[0] not in ('driver-root-before-fixture-expectations', 'R6-CLI-dispatch-priority'):
            yield fixture
    for fixture in source:
        if fixture[0] != 'driver-root-before-fixture-expectations':
            yield fixture


# Every nonempty subset of the six registered predicates; diagnostic values
# are fixture literals, independent of the resolver and Python set order.
_R6B_UNDEFINED_CASES = ((('converged',), 'undefined-BA:converged'),
 (('stable',), 'undefined-BA:stable'),
 (('improving',), 'undefined-BA:improving'),
 (('oscillating',), 'undefined-BA:oscillating'),
 (('diverging',), 'undefined-BA:diverging'),
 (('equilibrium',), 'undefined-BA:equilibrium'),
 (('converged', 'stable'), 'undefined-BA:converged,stable'),
 (('converged', 'improving'), 'undefined-BA:converged,improving'),
 (('converged', 'oscillating'), 'undefined-BA:converged,oscillating'),
 (('converged', 'diverging'), 'undefined-BA:converged,diverging'),
 (('converged', 'equilibrium'), 'undefined-BA:converged,equilibrium'),
 (('stable', 'improving'), 'undefined-BA:improving,stable'),
 (('stable', 'oscillating'), 'undefined-BA:oscillating,stable'),
 (('stable', 'diverging'), 'undefined-BA:diverging,stable'),
 (('stable', 'equilibrium'), 'undefined-BA:equilibrium,stable'),
 (('improving', 'oscillating'), 'undefined-BA:improving,oscillating'),
 (('improving', 'diverging'), 'undefined-BA:diverging,improving'),
 (('improving', 'equilibrium'), 'undefined-BA:equilibrium,improving'),
 (('oscillating', 'diverging'), 'undefined-BA:diverging,oscillating'),
 (('oscillating', 'equilibrium'), 'undefined-BA:equilibrium,oscillating'),
 (('diverging', 'equilibrium'), 'undefined-BA:diverging,equilibrium'),
 (('converged', 'stable', 'improving'), 'undefined-BA:converged,improving,stable'),
 (('converged', 'stable', 'oscillating'), 'undefined-BA:converged,oscillating,stable'),
 (('converged', 'stable', 'diverging'), 'undefined-BA:converged,diverging,stable'),
 (('converged', 'stable', 'equilibrium'), 'undefined-BA:converged,equilibrium,stable'),
 (('converged', 'improving', 'oscillating'), 'undefined-BA:converged,improving,oscillating'),
 (('converged', 'improving', 'diverging'), 'undefined-BA:converged,diverging,improving'),
 (('converged', 'improving', 'equilibrium'), 'undefined-BA:converged,equilibrium,improving'),
 (('converged', 'oscillating', 'diverging'), 'undefined-BA:converged,diverging,oscillating'),
 (('converged', 'oscillating', 'equilibrium'), 'undefined-BA:converged,equilibrium,oscillating'),
 (('converged', 'diverging', 'equilibrium'), 'undefined-BA:converged,diverging,equilibrium'),
 (('stable', 'improving', 'oscillating'), 'undefined-BA:improving,oscillating,stable'),
 (('stable', 'improving', 'diverging'), 'undefined-BA:diverging,improving,stable'),
 (('stable', 'improving', 'equilibrium'), 'undefined-BA:equilibrium,improving,stable'),
 (('stable', 'oscillating', 'diverging'), 'undefined-BA:diverging,oscillating,stable'),
 (('stable', 'oscillating', 'equilibrium'), 'undefined-BA:equilibrium,oscillating,stable'),
 (('stable', 'diverging', 'equilibrium'), 'undefined-BA:diverging,equilibrium,stable'),
 (('improving', 'oscillating', 'diverging'), 'undefined-BA:diverging,improving,oscillating'),
 (('improving', 'oscillating', 'equilibrium'), 'undefined-BA:equilibrium,improving,oscillating'),
 (('improving', 'diverging', 'equilibrium'), 'undefined-BA:diverging,equilibrium,improving'),
 (('oscillating', 'diverging', 'equilibrium'), 'undefined-BA:diverging,equilibrium,oscillating'),
 (('converged', 'stable', 'improving', 'oscillating'), 'undefined-BA:converged,improving,oscillating,stable'),
 (('converged', 'stable', 'improving', 'diverging'), 'undefined-BA:converged,diverging,improving,stable'),
 (('converged', 'stable', 'improving', 'equilibrium'), 'undefined-BA:converged,equilibrium,improving,stable'),
 (('converged', 'stable', 'oscillating', 'diverging'), 'undefined-BA:converged,diverging,oscillating,stable'),
 (('converged', 'stable', 'oscillating', 'equilibrium'),
  'undefined-BA:converged,equilibrium,oscillating,stable'),
 (('converged', 'stable', 'diverging', 'equilibrium'), 'undefined-BA:converged,diverging,equilibrium,stable'),
 (('converged', 'improving', 'oscillating', 'diverging'),
  'undefined-BA:converged,diverging,improving,oscillating'),
 (('converged', 'improving', 'oscillating', 'equilibrium'),
  'undefined-BA:converged,equilibrium,improving,oscillating'),
 (('converged', 'improving', 'diverging', 'equilibrium'),
  'undefined-BA:converged,diverging,equilibrium,improving'),
 (('converged', 'oscillating', 'diverging', 'equilibrium'),
  'undefined-BA:converged,diverging,equilibrium,oscillating'),
 (('stable', 'improving', 'oscillating', 'diverging'), 'undefined-BA:diverging,improving,oscillating,stable'),
 (('stable', 'improving', 'oscillating', 'equilibrium'),
  'undefined-BA:equilibrium,improving,oscillating,stable'),
 (('stable', 'improving', 'diverging', 'equilibrium'), 'undefined-BA:diverging,equilibrium,improving,stable'),
 (('stable', 'oscillating', 'diverging', 'equilibrium'),
  'undefined-BA:diverging,equilibrium,oscillating,stable'),
 (('improving', 'oscillating', 'diverging', 'equilibrium'),
  'undefined-BA:diverging,equilibrium,improving,oscillating'),
 (('converged', 'stable', 'improving', 'oscillating', 'diverging'),
  'undefined-BA:converged,diverging,improving,oscillating,stable'),
 (('converged', 'stable', 'improving', 'oscillating', 'equilibrium'),
  'undefined-BA:converged,equilibrium,improving,oscillating,stable'),
 (('converged', 'stable', 'improving', 'diverging', 'equilibrium'),
  'undefined-BA:converged,diverging,equilibrium,improving,stable'),
 (('converged', 'stable', 'oscillating', 'diverging', 'equilibrium'),
  'undefined-BA:converged,diverging,equilibrium,oscillating,stable'),
 (('converged', 'improving', 'oscillating', 'diverging', 'equilibrium'),
  'undefined-BA:converged,diverging,equilibrium,improving,oscillating'),
 (('stable', 'improving', 'oscillating', 'diverging', 'equilibrium'),
  'undefined-BA:diverging,equilibrium,improving,oscillating,stable'),
 (('converged', 'stable', 'improving', 'oscillating', 'diverging', 'equilibrium'),
  'undefined-BA:converged,diverging,equilibrium,improving,oscillating,stable'))
