#!/usr/bin/env python3
"""Later-turn port readings only; no metrics and no implicit experiment run.

Call explicitly in r33_metrics.arm_order() order after the manifest has been
posted. Confirmation validates the posted choice before opening populations.
This CLI is shipped during instrument construction and is not run then.
"""
import argparse
import hashlib
import os
import json
from pathlib import Path
import sys

from gen import HarnessError
import r33_identity as I
import r33_metrics as M
import r33_population as P
from r33_port import Slot, POLICIES, GROUPS
from schema import PREDS


def normalized_groups(groups):
    enabled = tuple(GROUPS if groups is None else groups)
    if len(set(enabled)) != len(enabled) or not set(enabled) <= set(GROUPS):
        raise M.Incomplete("REFUSED: invalid collection site groups")
    return tuple(group for group in GROUPS if group in enabled)


def collect(policy, sets, groups=None, first_measurement_sha256=None, choice_sha256=None):
    if policy not in POLICIES:
        raise M.Incomplete("REFUSED: collector policy is outside the registered eleven")
    if policy not in {"F0", "PRE1045"} and not valid_sha(first_measurement_sha256):
        raise M.Incomplete("REFUSED: this arm requires posted first measurement file")
    groups = normalized_groups(groups)
    records = []
    for name, corpus in sets.items():
        for row in corpus['rows']:
            slot = Slot(policy=policy, groups=groups)
            for at, value in enumerate(I.model_values(row)):
                slot.record(value)
                if at in row['checkpoints']:
                    reading = slot.reading()
                    records.append(dict(arm=policy,set=name,row=row['id'],at=at,
                                        predicates={p:reading[p] for p in PREDS},
                                        first_measurement_sha256=first_measurement_sha256,
                                        choice_sha256=choice_sha256,
                                        groups=list(GROUPS if groups is None else groups)))
    return records


def valid_sha(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def collection_order(log_path, policy, phase, groups, action, *, first_measurement_sha256=None,
                     choice_sha256=None, output_sha256=None, reason=None):
    """Write what the collecting process actually starts/completes, beside the draw.

    A calibration arm with every group enabled has one execution, including
    an execution which fails. Confirmation and group-only runs have distinct
    slots; no failed slot can be silently restarted under the same ledger.
    """
    if policy not in POLICIES or phase not in {"calibration", "confirmation"}:
        raise M.Incomplete("REFUSED: invalid collection order entry")
    enabled = list(normalized_groups(groups))
    path = Path(log_path)
    ledger = json.loads(path.read_text()) if path.exists() else {
        "format": "r33-arm-order/1", "seed": 1580,
        "drawn_order": M.arm_order(), "events": []}
    if (ledger.get("format") != "r33-arm-order/1" or ledger.get("seed") != 1580
            or ledger.get("drawn_order") != M.arm_order() or not isinstance(ledger.get("events"), list)):
        raise M.Incomplete("REFUSED: collection ledger is not the seed1580 order ledger")
    key = phase, policy, tuple(enabled)
    events = [event for event in ledger["events"]
              if (event["phase"], event["arm"], tuple(event["groups"])) == key]
    if action == "started":
        if events:
            raise M.Incomplete("REFUSED: this arm/phase/group setting has already run; no retry")
        if policy not in {"F0", "PRE1045"} and not valid_sha(first_measurement_sha256):
            raise M.Incomplete("REFUSED: this arm requires posted first measurement file")
    elif action in {"completed", "failed"}:
        if len(events) != 1 or events[0]["event"] != "started":
            raise M.Incomplete("REFUSED: collection completion has no unique unfinished start")
        if events[0]["first_measurement_sha256"] != first_measurement_sha256 or events[0]["choice_sha256"] != choice_sha256:
            raise M.Incomplete("REFUSED: collection completion changed posted-file provenance")
    else:
        raise M.Incomplete("REFUSED: unknown collection event")
    ledger["events"].append({"sequence": len(ledger["events"]), "arm": policy,
        "phase": phase, "groups": enabled, "event": action,
        "first_measurement_sha256": first_measurement_sha256,
        "choice_sha256": choice_sha256, "output_sha256": output_sha256, "reason": reason})
    ledger["actual_started_order"] = [event["arm"] for event in ledger["events"] if event["event"] == "started"]
    ledger["actual_completed_order"] = [event["arm"] for event in ledger["events"] if event["event"] == "completed"]
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)
    return ledger


def collect_logged(policy, sets, groups, *, phase, run_log,
                   first_measurement_sha256=None, choice_sha256=None):
    """The actual runner owns both the started and the terminal event."""
    collection_order(run_log, policy, phase, groups, "started",
                     first_measurement_sha256=first_measurement_sha256, choice_sha256=choice_sha256)
    try:
        rows = collect(policy, sets, groups, first_measurement_sha256, choice_sha256)
        raw = "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows)
        collection_order(run_log, policy, phase, groups, "completed",
                         first_measurement_sha256=first_measurement_sha256,
                         choice_sha256=choice_sha256,
                         output_sha256=hashlib.sha256(raw.encode()).hexdigest())
        return rows, raw
    except BaseException as error:
        collection_order(run_log, policy, phase, groups, "failed",
                         first_measurement_sha256=first_measurement_sha256,
                         choice_sha256=choice_sha256, reason=f"{type(error).__name__}: {error}")
        raise


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
    parser.add_argument('--first-measurement',type=Path)
    parser.add_argument('--run-log',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args = parser.parse_args()
    digest = None
    try:
        first_sha = (M.first_measurement_file(args.first_measurement)
                     if args.first_measurement is not None or args.policy not in {'F0','PRE1045'} else None)
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
        rows,raw=collect_logged(args.policy,sets,args.groups,
            phase='calibration' if args.calibration else 'confirmation',run_log=args.run_log,
            first_measurement_sha256=first_sha,choice_sha256=digest)
        args.out.parent.mkdir(parents=True,exist_ok=True)
        args.out.write_text(raw)
        print(json.dumps(dict(choice_sha256=digest,first_measurement_sha256=first_sha,
                              run_log=str(args.run_log),status='READINGS_ONLY',policy=args.policy,
                              readings=len(rows),output=str(args.out))))
        return 0
    except (M.Incomplete,HarnessError,OSError,ValueError,KeyError,TypeError,StopIteration) as error:
        print(json.dumps(dict(choice_sha256=digest,status='REFUSED',reason=str(error))))
        return 2


if __name__=='__main__':
    sys.exit(main())
