#!/usr/bin/env python3
"""Later-turn port readings only; no metrics and no implicit experiment run.

Call explicitly in r33_metrics.arm_order() order after the manifest has been
posted. Confirmation validates the posted choice before opening populations.
This CLI is shipped during instrument construction and is not run then.
"""
import argparse
import json
from pathlib import Path
import sys

from gen import HarnessError
import r33_identity as I
import r33_metrics as M
import r33_population as P
from r33_port import Slot, POLICIES, GROUPS
from schema import PREDS


def collect(policy, sets, groups=None):
    records = []
    for name, corpus in sets.items():
        for row in corpus['rows']:
            slot = Slot(policy=policy, groups=groups)
            for at, value in enumerate(I.model_values(row)):
                slot.record(value)
                if at in row['checkpoints']:
                    reading = slot.reading()
                    records.append(dict(arm=policy,set=name,row=row['id'],at=at,
                                        predicates={p:reading[p] for p in PREDS}))
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--calibration',action='store_true')
    mode.add_argument('--confirmation',action='store_true')
    parser.add_argument('--policy',choices=POLICIES,required=True)
    parser.add_argument('--groups', nargs='*', choices=GROUPS, default=None,
                        help='item 19 site groups; omitted=all, empty=F0 at every site')
    parser.add_argument('--manifest',type=Path,required=True)
    parser.add_argument('--data',type=Path,required=True)
    parser.add_argument('--choice',type=Path)
    parser.add_argument('--out',type=Path,required=True)
    args = parser.parse_args()
    digest = None
    try:
        if args.confirmation:
            choice,digest=M.choice_file(args.choice)
            if args.policy not in {choice['arm'],'F0','STD-rel'}:
                raise M.Incomplete('REFUSED: confirmation policy differs from posted choice/comparators')
        I.verify_manifest(args.manifest)
        if args.data.resolve() != (P.HERE/'r33_data/populations').resolve():
            raise M.Incomplete('REFUSED: data directory differs from the manifest population root')
        sets = {}
        groups = (('cal',('x1','x1e-3','x1e3')), ) if args.calibration else (
            ('confirm-cal',('x1','x1e6')),('confirm-hcal',tuple(P.SCALES)))
        for group,scales in groups:
            for scale in scales:
                sets[f'{group}/{scale}'] = P.load_set(args.data/group/scale)[0]
        released=P.load_set(P.HERE)[0]
        if args.confirmation:
            sets.update({'released/x1':released,'released-hcal/x1':P.load_set(P.HERE/'hcal')[0]})
        counter=next(row for row in released['rows'] if row['id']=='int64_count')
        sets['counter/x1']={'rows':[counter]}
        rows=collect(args.policy,sets,args.groups)
        args.out.parent.mkdir(parents=True,exist_ok=True)
        args.out.write_text(''.join(json.dumps(dict(choice_sha256=digest,groups=list(GROUPS if args.groups is None else args.groups),**row),sort_keys=True)+'\n' for row in rows))
        print(json.dumps(dict(choice_sha256=digest,status='READINGS_ONLY',policy=args.policy,
                              readings=len(rows),output=str(args.out))))
        return 0
    except (M.Incomplete,HarnessError,OSError,ValueError,KeyError,TypeError,StopIteration) as error:
        print(json.dumps(dict(choice_sha256=digest,status='REFUSED',reason=str(error))))
        return 2


if __name__=='__main__':
    sys.exit(main())
