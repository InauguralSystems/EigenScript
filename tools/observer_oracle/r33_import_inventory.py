#!/usr/bin/env python3
"""Extend the F0 mutation census with import and configuration accounting.

Inputs are prior committed mutation evidence and saved recipe-binary readings.
This program never invokes a runtime, population generator, or policy arm.
Every prior killing witness is re-executed, while source proofs cover the
survivors. Rejection comparisons use the same REFUSED semantic marker as the
handwritten classify/catch fixture; no exception-message parity is claimed.
"""
import argparse
import ast
import collections
import copy
import hashlib
import json
from pathlib import Path

import r33_mutants as M
import r33_imports as T
import r33_surfaces as S


def encoded(value):
    if type(value) is float:
        return {'float':value.hex()}
    return value


def decoded(value):
    return float.fromhex(value['float']) if type(value) is dict and set(value)=={'float'} else value


def saved(path):
    value=json.loads(Path(path).read_text())
    return {tuple(row['key']):decoded(row['value']) for row in value['readings']}


def proof_key(spec):
    if spec.get('semantic_anchor'):
        return spec['semantic_anchor']
    # The recorded pre-routing registry is the sole bridge for old rows
    # lacking a semantic anchor. Its source hash is checked by inventory().
    aliases=M.prior_point_aliases()
    matches=[anchor for anchor,ids in aliases.items() if spec['id'] in ids]
    if len(matches)!=1:
        return ('legacy',spec['id'],spec.get('scope'),spec.get('fragment'))
    return matches[0]


def import_proof(spec):
    """Source proofs by semantic AST role, never a mutable walk index.

    Established old proofs are reused only on the same STORE/LOAD-aware
    semantic anchor. A new routing point needs an actual witness or one
    of these local proofs; otherwise finalization refuses it.
    """
    if spec['id']=='from_traj_best_ignored':
        return ('UNREACHABLE',
                'The change discards restored best/best_used only. Finite retained windows already set best_used while rebuilding; nonfinite/empty windows cannot improve. classify reads the value report and disposes the temporary slot. No language or legal tape retains that imported slot for later recording or reads its best.',
                'An imported-slot update API or internal best getter, neither present at commit54008422.')
    if spec['scope']!='Slot.from_trajectory' or spec['kind']=='text':
        return None
    source=M.SOURCE.read_text()
    fn=M.scope(ast.parse(source),'Slot.from_trajectory')
    target=list(ast.walk(fn))[spec['node_index']]
    parents={id(child):parent for parent in ast.walk(fn) for child in ast.iter_child_nodes(parent)}
    ancestors=[]
    current=target
    while id(current) in parents:
        current=parents[id(current)]
        ancestors.append(current)
    if any(isinstance(node,ast.Raise) for node in ancestors):
        return ('EQUIVALENT',
                'Only construction/wording of a rejection exception changes. The mutated raise still raises (a non-exception object causes TypeError); valid inputs bypass it. The comparison contract is verdict versus REFUSED, not Python exception spelling or class.',None)
    if isinstance(target,ast.Constant) and target.value=='S1' and any(
            isinstance(node,ast.Call) and isinstance(node.func,ast.Attribute)
            and node.func.attr=='policy_for' for node in ancestors):
        return ('EQUIVALENT',
                'The S1 tag becomes an unknown site tag. Current and fallback policies are both F0 in every fixed-subject language/tape import, so both mode values are None and the identical supplied relative channel is restored.',None)
    statement=next((node for node in [target]+ancestors if isinstance(node,ast.stmt)),None)
    transport={'dh_capacity','_dh_buffer','numeric','observed','count'}
    essential={'scale','zero','small','window','_values_buffer','_raw_buffer','_rel_buffer',
               '_exact_buffer','best_used','since'}
    if isinstance(statement,ast.Assign):
        original_targets={node.attr for item in statement.targets for node in ast.walk(item)
                          if isinstance(node,ast.Attribute) and isinstance(node.ctx,ast.Store)}
        if original_targets and original_targets <= transport:
            changed=M.mutate_source(spec,source)
            changed_fn=M.scope(ast.parse(changed),'Slot.from_trajectory')
            changed_statement=next((node for node in ast.walk(changed_fn)
                                    if isinstance(node,ast.Assign) and node.lineno==statement.lineno),None)
            if changed_statement is not None:
                changed_targets={node.attr for item in changed_statement.targets for node in ast.walk(item)
                                 if isinstance(node,ast.Attribute) and isinstance(node.ctx,ast.Store)}
                if not changed_targets & essential:
                    return ('EQUIVALENT',
                            'This assignment changes only imported entropy history, routing flags or observation-count transport. Its retained list/float/slice operation remains defined on validated data. Explicit value-channel classify never consumes these fields and makes no subsequent record on the disposable imported slot. Entropy-channel classification is outside this experiment value-route contract.',None)
    return None


def split_prior(spec):
    """Ruling3/4 replaces old fixed-window premises with explicit scope."""
    row=copy.deepcopy(spec)
    if row['id'] in {'ast-Slot.record-call-reference-65-0-fault','ast-Slot.record-constant-142-0-fault'}:
        row.update(status='EQUIVALENT',reason='The record numeric-type refusal can be reached by a malformed imported value such as bool. This mutation changes only its TypeError construction or message; the faulty raise still raises, including TypeError for a non-exception object. Valid numeric input bypasses the branch. The value-route verdict/REFUSED contract is identical; no exception spelling or Python error class is claimed.',missing_capability=None)
        return row
    if row['id']=='ast-Slot.from_trajectory-reference-346-0-fault':
        raise ValueError('INVALID PRIOR PROOF: STORE best mutates scale; this point requires an actual killing reading, never the unused-best waiver')
    equal_parameters={'ast-Slot.magnitude-reference-12-0-fault',
                      'ast-Slot._step-reference-14-0-fault',
                      'ast-Slot.converged-reference-61-0-fault',
                      'ast-Slot.stable-reference-85-0-fault'}
    lattice={'ast-Slot.converged-reference-59-0-fault',
             'ast-Slot.stable-constant-112-0-fault',
             'ast-Slot.stable-reference-114-0-fault'}
    capacity={'ast-Slot.record-reference-89-0-fault',
              'ast-Slot.record-reference-207-0-fault',
              'ast-Slot.record-reference-385-0-fault',
              'ast-Slot.record-reference-451-0-fault'}
    underflow={'ast-Slot.rel_oscillating-comparison-47-0-strictness'}
    if row['id'] in equal_parameters|lattice|capacity|underflow:
        row['status']='OUTSIDE_CONFIGURATION'
        row['premise']=('Default equal scale=dh_zero=0.001.' if row['id'] in equal_parameters else
                        'Default exact tolerances1e-6 and2e-5 are strictly between integer diameters0 and1.' if row['id'] in lattice else
                        'Live depth is never changed after a numeric binding begins.' if row['id'] in capacity else
                        'Default relative amplitude cutoff0.001 prevents underflow of an admitted step product.')
        row['reason']=('Legal tape O cfg can separate scale from dh_zero, cross the exact integer diameter lattice, or lower the relative cutoff enough for an admitted product to underflow; legal O win/O cfg can change live depth. This mutant is equivalent only under the stated experiment premise, not on every legal tape. '+row['reason'])
        row['missing_capability']=None
        return row
    if row['scope']=='Slot.set_window':
        if row['id']=='ast-Slot.set_window-reference-13-0-fault':
            row.update(status='EQUIVALENT', reason='Only the return value of the model window setter changes. Runtime O cfg/O win installs window state and discards any setter result; all slot state updates are unchanged. Fluent host-only chaining is not a language/tape observation.',missing_capability=None)
            return row
        if row['id'] in {'ast-Slot.set_window-call-reference-17-0-fault','ast-Slot.set_window-constant-30-0-fault',
                         'ast-Slot.set_window-reference-39-0-fault','ast-Slot.set_window-constant-40-0-fault'}:
            row.update(status='UNREACHABLE',reason='This mutation changes only rejection wording or admits invalid out-of-range host arguments. Every legal tape O win is0(clear) or4..64, and every O cfg depth is4..64, validated before the fold. On those legal arguments the same window is installed. No program or legal tape reaches the distinguishing invalid setter argument.',missing_capability='A host call bypassing tape validation with an invalid window, or a change to the frozen tape validator.')
            return row
    if row['status']!='UNREACHABLE':
        if row['id']=='ast-Policy.step-constant-12-0-fault':
            row['reason']='The optional zero_guard default changes, but the F0 policy short-circuits the STD/C finite-zero branch. Its strictly positive floor supplies the same denominator and every F0 reader is unchanged.'
        return row
    identifier=row['id']
    exact=(identifier in ('exact_conv_le_to_lt','exact_stable_le_to_lt',
                         'ast-Slot.converged-comparison-19-0-strictness',
                         'ast-Slot.stable-comparison-25-0-strictness'))
    resize=(row['scope']=='Slot.set_window' or identifier=='values_ring_W_not_W+1'
            or identifier=='ast-Slot.record-reference-90-0-fault')
    if exact or resize:
        row['status']='OUTSIDE_CONFIGURATION'
        row['premise']=('Default scale=0.001, dh_zero=0.001, dh_small=0.01; no live configuration changes.'
                        if exact else 'Live bindings keep their default depth10; imported depths4,6,10,64 are constructed once, never resized.')
        row['reason']=(('An exact integer diameter cannot equal the default sub-unit threshold, but legal tape O cfg records can change positive thresholds/scale and make equality reachable. '
                        if exact else 'The changed code concerns active-depth/capacity changes. Legal tape O cfg/O win records can resize a live binding, so this is not a claim of language unreachability. ')
                       +'The fourth-manifest identity claim is only the experiment configuration specified by addendum3 ruling4.')
        row['missing_capability']=None
    elif row['scope']=='exponential':
        row['reason']='The changed expression is only in exponential OverflowError handling. The only observer caller averages at least3 logarithms of telescoping absolute step ratios over a legal window4..64. Every nonzero finite binary64 difference lies between2**-1074 and DBL_MAX. Thus a finite average is at most log(DBL_MAX/(2**-1074))/3 <486, below the exp overflow threshold, even if a legal positive configuration underflows its product tolerance to0. If a ratio or sum instead overflows, exp(+inf)/exp(NaN) returns inf/NaN without raising OverflowError. No legal O cfg/O win reaches the except arm.'
        row['missing_capability']='A direct private exponential helper call or a changed algorithm/window minimum; legal configuration and tape records preserve the bound.'
    elif row['scope']=='divide':
        row['reason']='The changed expression is after divide has established denominator==0. Every F0 caller has a positive denominator: S1 has positive scale, how has positive dh_zero, and equilibrium/reference folds divide by legal positive depths/counts. Legal tape configuration requires positive scale and thresholds and windows4..64 (tape_read.c obs_cfg_rec_ok), so no legal program or tape reaches this branch through an F0 observer query. '+row['reason'].split(' Mutated expression:')[0]
        row['missing_capability']='A direct private-helper query, an illegal zero scale/threshold or depth, or a runtime algorithm/arm change; no legal O cfg/O win supplies these.'
    elif 'no live' in row.get('reason','') or 'no live' in str(row.get('missing_capability','')):
        raise ValueError('unreviewed old live-window premise: '+identifier)
    return row


def check_result(result):
    ids=[row['id'] for row in result['mutants']]
    if len(ids)!=len(set(ids)) or set(ids)!={row['id'] for row in M.definitions()}:
        raise ValueError('INVENTORY INCOMPLETE: missing, duplicate or unknown mutant')
    statuses=('CAUGHT','EQUIVALENT','UNREACHABLE','OUTSIDE_CONFIGURATION')
    for row in result['mutants']:
        if row['status'] not in statuses:
            raise ValueError('INVENTORY UNEXPLAINED: '+row['id'])
        if row['status']=='CAUGHT' and not row.get('witness'):
            raise ValueError('INVENTORY missing killing witness: '+row['id'])
        if row['status']!='CAUGHT' and not row.get('reason'):
            raise ValueError('INVENTORY missing source reason: '+row['id'])
        if row['status']=='OUTSIDE_CONFIGURATION' and not row.get('premise'):
            raise ValueError('INVENTORY missing configuration premise: '+row['id'])
    return True


def inventory(previous, site_binary, surface_binary, imports_binary):
    source=M.SOURCE.read_text()
    prior=json.loads(Path(previous).read_text())
    registry=json.loads((M.HERE/'r33_data/site-coverage/census-before-routing.json').read_text())
    if (prior['source_sha256'] not in {registry['source_sha256'],hashlib.sha256(source.encode()).hexdigest()}
            and not all(row.get('semantic_anchor') for row in prior['mutants'])):
        raise ValueError('INVENTORY: prior source has no matching semantic-point registry')
    previous_by_id={row['id']:row for row in prior['mutants']}
    previous_by_key={proof_key(row):row for row in prior['mutants']}
    data=M.HERE/'r33_data'
    cases=[json.loads(line) for line in (data/'site-coverage/cases.jsonl').read_text().splitlines()]
    immutable=[json.loads(line) for filename in ('anchors.jsonl','seeded.jsonl')
               for line in (data/'identity'/filename).read_text().splitlines()]
    purpose={row['id']:row for row in cases}
    old={row['id']:row for row in immutable}
    surfaces={row['id']:row for row in S.cases()}
    imports={row['id']:row for row in T.cases()}
    actual={'purpose':saved(site_binary),'surface':saved(surface_binary),'import':saved(imports_binary)}
    imports_expected={(row['id'],*key):value for row in imports.values() for key,value in T.model(row).items()}
    if set(imports_expected)!=set(actual['import']) or any(not M.same(value,actual['import'][key]) for key,value in imports_expected.items()):
        raise ValueError('IMPORT IDENTITY: baseline differs from sealed binary output')
    result={'format':'r33-mutation-inventory/2', 'source_sha256':hashlib.sha256(source.encode()).hexdigest(),
            'critic_definition_count':len(M.CRITIC), 'census':M.census(source), 'mutants':[],
            'outside_numeric_census':[row for row in prior.get('outside_numeric_census',[])
                                      if row['function']!='Slot.from_trajectory'],
            'prior_inventory_sha256':hashlib.sha256(Path(previous).read_bytes()).hexdigest(),
            'retired_or_remapped_prior_points':copy.deepcopy(prior.get('retired_or_remapped_prior_points',[])),
            'unqueried':[{'field':'quiet','status':'UNREACHABLE',
                         'reason':'No language or tape query exposes quiet at the fixed commit.'}]}
    definitions=M.definitions(source)
    current_by_key={}
    for row in definitions:
        current_by_key.setdefault(proof_key(row),[]).append(row['id'])
    for oldid,row in previous_by_id.items():
        mapped=current_by_key.get(proof_key(row),[])
        if mapped != [oldid]:
            result['retired_or_remapped_prior_points'].append({'prior_id':oldid,'current_ids':mapped,
                'prior_status':row['status'],'prior_semantic_anchor':proof_key(row),
                'reason':'The empty/nonnumeric import routing now mirrors the fixed C reader. Exact statement/node/field-path anchors map unchanged points; removed/restructured validation points are retired and their replacement code receives a fresh mutation census and actual readings.'})
    for number,spec in enumerate(definitions,1):
        cls=M.mutated_slot(spec,source)
        parent=previous_by_key.get(proof_key(spec))
        witness=None
        # Re-execute the previous actual killing case. Its binary value is
        # protected by the prior manifest and is independently joined later.
        streams=[]
        if parent and parent['status']=='CAUGHT':
            w=parent['witness'];key=tuple(w['key']);kind=w['source'];rowid=key[0]
            mapping=purpose if kind=='purpose' else surfaces if kind=='surface' else old
            row=mapping[rowid]
            answers=actual[kind] if kind in actual else {key:decoded(w['binary'])}
            streams.append((kind,row,answers))
        streams += [('import',row,actual['import']) for row in imports.values()]
        if not parent or parent['status']!='CAUGHT':
            streams += [('surface',row,actual['surface']) for row in surfaces.values()]
        for kind,row,answers in streams:
            expected_keys={key for key in answers if key[0]==row['id']}
            try:
                got=({(row['id'],*key):value for key,value in (T.model(row,cls) if kind=='import' else S.model(row,cls)).items()}
                     if kind in ('surface','import') else M.model_case(row,cls))
                key=next((key for key in sorted(expected_keys) if key not in got or not M.same(got[key],answers[key])),None)
                if key is not None:
                    witness={'source':kind,'key':list(key),'binary':encoded(answers[key]),
                             'mutant':encoded(got.get(key)),'missing':key not in got}
            except Exception as error:
                at=None
                locations=[]
                trace=error.__traceback__
                while trace:
                    frame=trace.tb_frame
                    locations.append({'file':Path(frame.f_code.co_filename).name,
                                      'function':frame.f_code.co_name,'line':trace.tb_lineno})
                    if frame.f_code.co_name in ('model_case','model'):
                        if 'at' in frame.f_locals:
                            at=frame.f_locals['at']
                        elif 'i' in frame.f_locals:
                            at=frame.f_locals['i']
                    trace=trace.tb_next
                key=next((key for key in sorted(expected_keys) if key[1]==at),
                         next(iter(sorted(expected_keys))))
                witness={'source':kind,'key':list(key),'binary':encoded(answers[key]),
                         'error_index':at,'locations':locations,
                         'error':type(error).__name__+': '+str(error),
                         'detector':'A declared reading was unavailable because the faulty port raised an error.'}
            if witness:break
        row={**spec,'anchor':'LIVE','mutated_source_sha256':hashlib.sha256(M.mutate_source(spec,source).encode()).hexdigest()}
        if witness:
            row.update(status='CAUGHT', reason=None, witness=witness,
                       caught_by_error='error' in witness)
        elif parent:
            if parent['status']=='CAUGHT':raise ValueError('prior killing witness survived: '+spec['id'])
            proof=split_prior(parent)
            row.update(status=proof['status'],reason=proof['reason'],witness=None,
                       missing_capability=proof.get('missing_capability'))
            if proof.get('premise'):row['premise']=proof['premise']
        else:
            proof=import_proof(spec)
            if proof is None:
                row.update(status='UNRESOLVED',reason=None,witness=None)
            else:
                row.update(status=proof[0],reason=proof[1],missing_capability=proof[2],witness=None)
        result['mutants'].append(row)
        print(f'{number}/{len(definitions)} {spec["id"]}: {row["status"]}',flush=True)
    result['lists']={name:[row['id'] for row in result['mutants'] if row['status']==status]
                     for name,status in (('caught','CAUGHT'),('equivalent','EQUIVALENT'),
                                         ('not_reachable','UNREACHABLE'),('outside_configuration','OUTSIDE_CONFIGURATION'))}
    result['counts']={name:len(ids) for name,ids in result['lists'].items()}
    result['caught_by_error_count']=sum(row.get('caught_by_error',False) for row in result['mutants'])
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--previous',required=True,type=Path)
    p.add_argument('--site-binary',required=True,type=Path)
    p.add_argument('--surface-binary',required=True,type=Path)
    p.add_argument('--imports-binary',required=True,type=Path)
    p.add_argument('--out',required=True,type=Path)
    a=p.parse_args()
    result=inventory(a.previous,a.site_binary,a.surface_binary,a.imports_binary)
    a.out.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    check_result(result)
    print('COMPLETE MUTATION INVENTORY '+json.dumps(result['counts'],sort_keys=True))
    print('CAUGHT BY ERROR '+str(result['caught_by_error_count']))
