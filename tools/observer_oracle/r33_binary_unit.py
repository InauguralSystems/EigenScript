#!/usr/bin/env python3
"""Handwritten demonstrations of binary subjects and declared-build identity.

No binary, fixture file or population is read. A tiny scorer double exposes
the three ruled cannot-run cases and proves tier diagnostics remove no row.
Real historical-binary hand runs are recorded separately by the builder.
"""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen import HarnessError
import r33_binary as B
import r33_identity as I
import r33_metrics as M
from r33_port import Slot
from schema import PREDS


class HandScorer:
    def __init__(self, *, probe_error=False, missing=False):
        self.probe_error, self.missing = probe_error, missing
        self.calls = []

    def capabilities(self, binary):
        print('HAND probe stdout')
        if self.probe_error:
            raise HarnessError("HAND capability probe printed unparseable output")
        return True, {'ieee':True, 'int64':False}, {'ieee':'inf true', 'int64':'false', 'int64_kind':'float'}

    def measure(self, binary, corpus, caps):
        row = corpus['rows'][0]
        self.calls.append(row['id'])
        print('HAND measure '+row['id'])
        if row['id'] == 'raises':
            raise HarnessError('HAND runtime printed ERROR on this row')
        read = {(tier, form, row['id'], at, p): (p == 'converged')
                for tier, form in (('interp','straight'),('interp','loop'),('jit','loop'),('osr','loop'))
                for at in row['checkpoints'] for p in PREDS}
        # The two runtime tiers disagree and have no native witness. Those
        # diagnostics must not remove the interpreter's straight reading.
        read['jit','loop',row['id'],row['checkpoints'][0],'converged'] = False
        if self.missing:
            del read['interp','straight',row['id'],row['checkpoints'][0],'converged']
        return {'read':read, 'skipped':[], 'wit':{('jit',row['id'],row['checkpoints'][0]):('VACUOUS','HAND no body'),
                                                ('osr',row['id'],row['checkpoints'][0]):('value bail','HAND unwitnessed')},
                'runs':4, 'held':{}}

    @staticmethod
    def findings(result):
        import score
        return score.findings(result)

    @staticmethod
    def check_witnessed(result):
        import score
        return score.check_witnessed(result)


def demonstrations():
    events = []
    rows = [{'id':'ordinary', 'checkpoints':[10]},
            {'id':'typed-unavailable', 'capability':'int64', 'checkpoints':[10,60]},
            {'id':'raises', 'checkpoints':[10]}]
    scorer = HandScorer()
    got = B.read_binary('HAND-BINARY','unused-binary',{'hand':{'rows':rows}},scorer=scorer)
    assert len(got['readings']) == 1 and got['readings'][0]['predicates']['converged'] is True
    assert {row['kind'] for row in got['cannot_run']} == {'capability_skip','measure_raised'}
    assert scorer.calls == ['ordinary','raises']
    assert got['diagnostics']['tier_splits'] and got['diagnostics']['vacuous']
    assert got['diagnostics']['unwitnessed_jit'] == ['jit','osr'] and got['diagnostics']['witness_error']
    events.append(dict(case='binary-one-row-at-a-time', status='MET', result=got))
    failed = B.read_binary('HAND-BINARY','unused-binary',{'hand':{'rows':rows}},scorer=HandScorer(probe_error=True))
    assert not failed['readings'] and len(failed['cannot_run']) == len(rows)
    assert {row['kind'] for row in failed['cannot_run']} == {'capability_probe_raised'}
    events.append(dict(case='binary-probe-raises', status='NOT_READ', result=failed))

    def refusal(case, call, text):
        try:
            call()
        except (HarnessError, M.Incomplete) as exc:
            assert text in str(exc), (case, str(exc))
            events.append(dict(case=case,status='REFUSED',reason=str(exc)))
        else:
            raise AssertionError('plant survived '+case)

    refusal('binary-name-cannot-enter-eleven',
            lambda:B.read_binary('F0','unused',{'hand':{'rows':rows}},scorer=HandScorer()), 'outside the eleven')
    refusal('missing-interpreter-key-is-harness-error',
            lambda:B.read_binary('HAND-BINARY','unused',{'hand':{'rows':[rows[0]]}},scorer=HandScorer(missing=True)),
            'readings missing/extra/malformed')

    slot = Slot(policy='F0')
    values = [0.0, 0.0, 1.0, 0.0, 2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    for value in values:
        slot.record(value)
    fields = (*PREDS,'report','where','where_kind','why','why_kind','how','count')
    reading = slot.reading()
    want = {('hand','zero-detour',10,field):reading[field] for field in fields}
    metadata = dict(name='HAND-F0-BUILD',commit='5'*40,arm='F0',checkpoints=1,manifest_sha256='a'*64)
    proof = I.compare_build_records(want,dict(want),**metadata)
    assert proof['fields_compared'] == 13 and proof['status'] == 'MATCH'
    events.append(dict(case='named-build-thirteen-fields',status='MET',values=values,result=proof))
    missing = dict(want)
    del missing[next(iter(missing))]
    refusal('named-build-missing-reading',lambda:I.compare_build_records(want,missing,**metadata),'MISSING')
    wrong = dict(want)
    wrong['hand','zero-detour',10,'converged'] = not wrong['hand','zero-detour',10,'converged']
    refusal('named-build-one-wrong-reading',lambda:I.compare_build_records(want,wrong,**metadata),'MISMATCH')
    refusal('named-build-empty',lambda:I.compare_build_records({}, {},**metadata),'empty comparison')
    refusal('named-build-missing-field-count',lambda:I.compare_build_records(want,want,**{**metadata,'checkpoints':2}),
            'all 13 queried fields')

    with tempfile.TemporaryDirectory(prefix='r33_hand_build_') as temporary:
        base = Path(temporary)
        binary = base/'build/release/eigenscript'
        binary.parent.mkdir(parents=True)
        binary.write_text('handwritten, inert build bytes; never executed\n')
        commit = '5'*40
        stamp = dict(source_sha=commit, recipe_id=I.sha(I.ROOT/'tools/observer_oracle/build_arm.sh'),
                     binary_sha256=I.sha(binary))
        (base/'arm.json').write_text(json.dumps(stamp))
        manifest = {'subject':{'commit':commit,'recipe_sha256':stamp['recipe_id']}}
        claim = I.build_claim(binary,'HAND-BUILD',commit,'F0',manifest)
        assert claim['name'] == 'HAND-BUILD'
        local_f0 = I.baseline_claim(manifest, binary)
        assert local_f0 == stamp
        events.append(dict(case='local-F0-baseline-recipe-stamp',status='MET',identity=local_f0))
        refusal('local-F0-baseline-wrong-subject',
                lambda:I.baseline_claim({'subject':{**manifest['subject'],'commit':'6'*40}},binary),
                'local F0 baseline differs')
        events.append(dict(case='named-build-declared-stamp',status='MET',commit=commit,arm='F0'))
        refusal('named-build-wrong-commit',lambda:I.build_claim(binary,'HAND-BUILD','6'*40,'F0',manifest),
                'fixed subject')
        refusal('named-build-nonF0-needs-posted-choice',
                lambda:I.build_claim(binary,'HAND-C',commit,'C_1e-2^hist',manifest), 'posted choice file')
        choice = base/'choice.json'
        choice.write_text(json.dumps(dict(arm='C_1e-2^hist',sweep_tables_sha256='a'*64)))
        claimed = I.build_claim(binary,'HAND-C',commit,'C_1e-2^hist',manifest,choice)
        assert claimed['choice_sha256'] == I.sha(choice)
        events.append(dict(case='future-named-build-choice-provenance',status='MET',arm=claimed['arm'],
                           choice_sha256=claimed['choice_sha256']))
        binary.write_text('planted changed bytes')
        refusal('named-build-changed-binary',lambda:I.build_claim(binary,'HAND-BUILD',commit,'F0',manifest),
                'differs from build stamp')
    command = B.old_method_command('HAND-BINARY',root=Path('/HAND-ROOT'),python='python3')
    assert command == ['python3','-I','/HAND-ROOT/tools/observer_oracle/score.py','HAND-BINARY',
                       '--corpus','/HAND-ROOT/tools/observer_oracle/corpus.json']
    events.append(dict(case='old-method-program-command',status='MET',command=command,
                       program_was_run=False))
    return dict(format='r33-binary-hand-demonstrations/1', events=events,
                no_binary_was_run=True,no_population_was_read=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path)
    args=parser.parse_args(argv)
    evidence=demonstrations()
    if args.out:
        args.out.parent.mkdir(parents=True,exist_ok=True)
        args.out.write_text(json.dumps(I.encode(evidence),indent=2,sort_keys=True)+'\n')
    for event in evidence['events']:
        print('BINARY HAND '+event['case']+': '+event['status'])
    print('BINARY HAND: '+str(len(evidence['events']))+' demonstrations; no binary/population run')
    return 0


if __name__=='__main__':
    sys.exit(main())
