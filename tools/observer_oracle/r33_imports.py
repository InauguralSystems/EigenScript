#!/usr/bin/env python3
"""Addendum-3 hand imports; sealed separately from all prior fixtures.

All values are written out or follow the logged age/window Cartesian rule.
No population, experimental arm or binary is read during input generation.
The surface emitter/parser supplies typed, complete binary query records.
"""
import argparse
import copy
import json
from pathlib import Path

from gen import HarnessError
import r33_surfaces as S


def cases():
    # This full hand window independently reproduces the critic's since
    # boundary: since=9 is improving at depth10; since=10 is not improving.
    values = [10.0, 9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.5, 3.4, 3.39, 3.389]
    raw = [-1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -0.5, -0.1, -0.01, -0.001]
    customs = []
    for age in (None, 0, 3, 9, 10, 254, 255, 9.0):
        name = 'null' if age is None else ('float9' if type(age) is float else str(age))
        customs.append({'name': 'since-'+name,
                        'data': S.trajectory(values, 10, raw=raw,
                                             relative=[0.0]*10, best=3.389, since=age)})
    customs.append({'name': 'best-ignored-critic',
                    'data': S.trajectory(values, 10, raw=raw,
                                         relative=[0.0]*10, best=-100.0, since=3)})
    # Each imported depth accepted by this experiment is explicit. Keeping
    # eleven inputs also tests suffix reconstruction at depth4 and depth6.
    for depth in (4, 6, 10, 64):
        customs.append({'name': 'window-'+str(depth),
                        'data': S.trajectory(values, depth, raw=raw,
                                             relative=[0.0]*10, best=3.389, since=depth-1)})
    # Empty, singleton and exact imports exercise valid partial-state paths.
    customs.extend([
        {'name': 'empty-value-channel', 'data': S.trajectory([1.0], 4, best=None, since=None)},
        {'name': 'exact-retained-counter',
         'data': {**S.trajectory([2**53+i for i in range(11)], 10,
                                raw=[1.0]*10, relative=[0.0]*10,
                                best=2**53, since=9), 'exact':[True]*10}},
        {'name': 'nonnumeric-flag-value-channel',
         'data': {**S.trajectory(values, 10, raw=raw, relative=[0.0]*10,
                                best=3.389, since=9), 'numeric':False,
                  'dh':[0.1, 0.2], 'entropy':0.2, 'dH':0.1, 'last_entropy':0.2}},
        {'name': 'unobserved-value-channel',
         'data': {**S.trajectory(values, 10, raw=raw, relative=[0.0]*10,
                                best=3.389, since=9), 'observed':False}},
    ])
    for relative in ([0.0]*10, [0.02]+[0.0]*9):
        customs.append({'name':'flat-tail-relative-'+str(len(customs)),
                        'data':S.trajectory([1.0]+[0.5]*10, 10, raw=[0.0]*10,
                                             relative=relative, best=0.5, since=10)})
    retained = S.trajectory(values, 4, raw=['ignored']*6+raw[-4:],
                            relative=['ignored']*6+[0.0]*4, best=3.389, since=9)
    retained['exact'] = ['ignored']*6+[False]*4
    customs.append({'name':'retained-window4-ignored-prefix', 'data':retained})
    customs.append({'name':'exact-suffix-keeps-inexact-bit',
                    'data':{**S.trajectory([1]+[0]*10, 10, raw=[1e-150]*10,
                                           relative=[0.0]*10, best=0, since=10),
                            'exact':[False]+[True]*9}})
    no_window = S.trajectory(values, 10, raw=raw, relative=[0.0]*10,
                             best=3.389, since=10)
    del no_window['window']
    customs.extend([
        {'name':'default-window', 'echo':False, 'data':no_window},
        {'name':'float-window4', 'data':S.trajectory(values, 4.0, raw=raw,
                                                   relative=[0.0]*10, best=3.389, since=3)},
        {'name':'integer-step-channels',
         'data':S.trajectory(values, 10, raw=[0]*10, relative=[0]*10, best=3, since=9)},
        {'name':'integer-entropy-fields',
         'data':{**S.trajectory(values, 10, raw=raw, relative=[0.0]*10, best=3, since=9),
                 'numeric':False, 'dh':[0,1], 'entropy':1, 'dH':1, 'last_entropy':0}},
        {'name':'empty-import', 'data':{'kind':'trajectory','window':4,'values':[],
                 'raw':[],'rel':[],'exact':[],'dh':[],'numeric':False,'observed':True,
                 'best':None,'since':None,'entropy':None,'dH':None,'last_entropy':None,
                 'last_value':None}},
    ])
    accepted = {'id':'addendum3-trajectory-imports' , 'ops':[], 'read_at':[],
                'export_at':[], 'temporal':[], 'trajectories':customs}
    prototype = S.trajectory(values, 10, raw=raw, relative=[0.0]*10,
                             best=3.389, since=9)
    rejected = []
    def bad(name, **changes):
        rejected.append({'name':name, 'data':{**copy.deepcopy(prototype), **changes}})
    empty = {'kind':'trajectory','window':4,'values':[], 'raw':[], 'rel':[],
             'exact':[],'dh':[],'numeric':False,'observed':True,
             'best':None,'since':None,'entropy':None,'dH':None,'last_entropy':None,
             'last_value':None}
    for channel in ('raw','rel'):
        rejected.append({'name':'empty-string-'+channel, 'data':{**empty, channel:''}})
    bad('kind', kind='not-trajectory')
    for window in (3, 65, 4.5, True, '10', {'$float':'inf'}, {'$float':'nan'}):
        bad('window-'+str(len(rejected)), window=window)
    bad('raw-not-list', raw=1)
    bad('rel-not-list', rel=1)
    bad('raw-numeric-string-channel', raw='0000000000')
    bad('rel-numeric-string-channel', rel='0000000000')
    bad('exact-not-list', exact=1)
    bad('values-not-list', values=1)
    bad('raw-short', raw=raw[:-1])
    bad('rel-short', rel=[0.0]*9)
    bad('exact-short', exact=[False]*9)
    bad('values-short', values=values[:-1])
    bad('raw-string', raw=[0.0]*9+['x'])
    bad('rel-string', rel=[0.0]*9+['x'])
    bad('value-string', values=values[:-1]+['x'])
    bad('value-bool', values=values[:-1]+[False])
    bad('exact-number', exact=[False]*9+[0])
    bad('invented-exactness', exact=[True]*10)
    bad('invented-exact-prefix', values=[1.0]+[0.5]*10,
        exact=[True]+[False]*9)
    bad('raw-bool', raw=[False]*10)
    bad('rel-bool', rel=[False]*10)
    bad('dh-bool', dh=[False])
    for best in ('x', '0', True, {'$float':'inf'}, {'$float':'nan'}):
        bad('best-'+str(len(rejected)), best=best)
    for since in (-1, 256, 9.5, True, '9', {'$float':'inf'}, {'$float':'nan'}):
        bad('since-'+str(len(rejected)), since=since)
    bad('dh-not-list', dh=1)
    bad('dh-string', dh=['x'])
    bad('numeric-not-bool', numeric=1)
    bad('observed-not-bool', observed=1)
    for key in ('entropy','dH','last_entropy'):
        bad(key+'-string', **{key:'x'})
        bad(key+'-numeric-string', **{key:'0'})
    stores = {'id':'addendum3-import-store-targets', 'ops':[], 'read_at':[],
              'export_at':[], 'temporal':[], 'trajectories':[
        {'name':'best-store-cannot-change-scale',
         'data':S.trajectory([1.0,1.01,1.02,1.03,1.04,1.05,1.06,1.07,1.08,1.09,1.1],
                              10, raw=[0.0]*10, relative=[0.1]*10, best=1000.0, since=10)},
        {'name':'negative-best-cannot-remove-floor',
         'data':S.trajectory([0.0,1e-8,2e-8,3e-8,4e-8,5e-8,6e-8,7e-8,8e-8,9e-8,1e-7],
                              10, raw=[0.0]*10, relative=[0.1]*10, best=-1000.0, since=10)},
        {'name':'exact-best-cannot-change-scale',
         'data':{**S.trajectory([2**53+i for i in range(11)], 10,
                                raw=[0.0]*10, relative=[0.1]*10,
                                best=2**53, since=10), 'exact':[True]*10}}
    ]}
    return [accepted, {'id':'addendum3-trajectory-refusals', 'ops':[], 'read_at':[],
                       'export_at':[], 'temporal':[], 'refusals':rejected}, stores]


def model(row, slot_type=None):
    if 'refusals' not in row:
        return S.model(row, **({} if slot_type is None else {'slot_type':slot_type}))
    from r33_port import Slot
    cls = Slot if slot_type is None else slot_type
    result = {}
    for i, custom in enumerate(row['refusals']):
        try:
            value = cls.from_trajectory(S.decode_special(custom['data'])).report_value()
        except Exception:
            value = 'REFUSED'
        S.put(result, i, 'refusal.'+custom['name'], value)
    return result


def emit(row):
    if 'refusals' not in row:
        return S.emit(row)
    out = []
    for i, custom in enumerate(row['refusals']):
        out.append('r33_traj is '+S.source_literal(custom['data']))
        out.append('try:')
        out.append('    r33_answer is classify of r33_traj')
        out.append('catch _r33_import_error:')
        out.append('    r33_answer is "REFUSED"')
        S.scalar(out, row, i, 'refusal.'+custom['name'], 'r33_answer')
    out.append('print of '+S.source_literal('SURF_DONE '+row['id']))
    return '\n'.join(out)+'\n' 


def parse(row, lines):
    return S.parse(row, lines)


def write(destination):
    destination = Path(destination)
    (destination/'programs').mkdir(parents=True, exist_ok=True)
    rows = cases()
    (destination/'inputs.json').write_text(S.input_text(rows))
    for row in rows:
        (destination/'programs'/(row['id']+'.eigs')).write_text(emit(row))
    return {'cases':len(rows), 'imports':sum(len(r.get('trajectories',[])) for r in rows),
            'refusals':sum(len(r.get('refusals',[])) for r in rows),
            'programs':len(rows), 'classifier_or_binary_run':False}


def verify(destination):
    destination = Path(destination)
    rows = cases()
    if (destination/'inputs.json').read_text() != S.input_text(rows):
        raise HarnessError('IMPORT MANIFEST: fixed inputs changed')
    if {p.name for p in (destination/'programs').iterdir()} != {r['id']+'.eigs' for r in rows}:
        raise HarnessError('IMPORT MANIFEST: missing or extra programs')
    for row in rows:
        if (destination/'programs'/(row['id']+'.eigs')).read_text() != emit(row):
            raise HarnessError('IMPORT MANIFEST: generated program differs: '+row['id'])
    return rows


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('write','verify'))
    p.add_argument('destination')
    a=p.parse_args()
    print(json.dumps(write(a.destination) if a.action=='write' else {'cases':len(verify(a.destination))}, sort_keys=True))
