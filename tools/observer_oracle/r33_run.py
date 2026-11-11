#!/usr/bin/env python3
"""Later-use R33-1 point tables from explicitly supplied verdict JSONL.

This program NEVER runs a classifier or binary. Each input record is
{arm,set,row,at,predicates:{six booleans}}, with set cal/<scale> for calibration,
confirm-cal/{x1,x1e6} and confirm-hcal/<scale> for confirmation comparisons,
released/x1 for all72 original calibration rows, released-hcal/x1 for the
original32 H-cal rows in BA guards, or counter/x1 for the separate typed K.
It validates declared keys against frozen-tool-validated staged populations.

--sweep consumes all eleven arms' already collected calibration readings;
--confirm requires the posted choice before reading any input/population.
Confirmation output contains point estimates only, not a passing judgment:
the frozen judge program supplies BA bounds and the real build must first
match the port on every confirmation checkpoint. No bootstrap is reproduced.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

import derive
from gen import HarnessError, generate
from schema import PREDS
from r33_port import POLICIES
import r33_metrics as M
import r33_population as P
import r33_identity as I

HERE = Path(__file__).resolve().parent


def records(paths, expected_choice_sha256=None):
    arms = {}
    for path in paths:
        with Path(path).open() as source:
            for number, line in enumerate(source, 1):
                try:
                    record = json.loads(line)
                    arm = record["arm"]
                    if arm not in POLICIES:
                        raise ValueError("unregistered arm")
                    if expected_choice_sha256 is not None:
                        bound = record.get('choice_sha256')
                        # F0 may have been read before posting the choice.
                        allowed = {None,expected_choice_sha256} if arm=='F0' else {expected_choice_sha256}
                        if bound not in allowed:
                            raise M.Incomplete(f'REFUSED: {arm} input choice_sha256 does not match posted choice')
                except M.Incomplete:
                    raise
                except (KeyError, TypeError, ValueError) as exc:
                    raise M.Incomplete(f"INCOMPLETE: invalid reading at {path}:{number}") from exc
                arms.setdefault(arm, []).append(record)
    return {a: M.index(rs) for a, rs in M.nonempty(arms, "arm reading files").items()}


def load(data, population, scales):
    result = {}
    for scale in scales:
        result[f"{population}/{scale}"] = P.load_set(data / population / scale)
    return result


def expected(sets):
    return {(name, row["id"], at) for name, (corpus, _) in sets.items()
            for row in corpus["rows"] for at in row["checkpoints"]}


def labels(sets, name):
    corpus, lab = sets[name]
    return {(name, row["id"], at): lab[f"{row['id']}@{at}"]
            for row in corpus["rows"] for at in row["checkpoints"]}


def comparisons(sets, population, scales, mask_scale):
    base = f"{population}/x1"
    corpus, _ = sets[base]
    mask_corpus, _ = sets[f"{population}/{mask_scale}"]
    mask_rows = {r["id"]: r for r in mask_corpus["rows"]}
    result = []
    for row in corpus["rows"]:
        if row["id"] not in mask_rows:
            raise M.Incomplete(f"INCOMPLETE: mask row missing {row['id']}")
        xs = generate(mask_rows[row["id"]]["gen"], max(row["checkpoints"]))
        for at in row["checkpoints"]:
            window = xs[max(0, at - 10):at + 1]
            above = all(math.isfinite(v) and abs(v) >= 1e-2 for v in window)
            for scale in scales:
                result.append(((base, row["id"], at), (f"{population}/{scale}", row["id"], at), above))
    return result


def roster(sets):
    rows, _ = sets["cal/x1"]
    result = []
    for row in rows["rows"]:
        if row["props"]["limit"] != 0:
            continue
        at = max(row["checkpoints"])
        if all(sets[f"cal/{scale}"][1][f"{row['id']}@{at}"]["converged"][1]
               for scale in ("x1", "x1e-3", "x1e3")):
            result.append((row["id"], at))
    if {r for r, _ in result} != P.Z_EXPECTED:
        raise M.Incomplete("STOP R33-1 item9: Z roster differs from the six named rows")
    return result


def counter_keys():
    corpus = derive.load_corpus(str(HERE / "corpus.json"))
    row = next(r for r in corpus["rows"] if r["id"] == "int64_count")
    if not row["gen"].get("int") or set(row["checkpoints"]) != {10, 60}:
        raise M.Incomplete("INCOMPLETE: K's canonical exact row changed")
    return [("counter/x1", row["id"], at) for at in row["checkpoints"]]


def sweep(data, readings):
    if set(readings) != set(POLICIES):
        raise M.Incomplete("INCOMPLETE: sweep needs every registered arm exactly once")
    sets = load(data, "cal", ("x1", "x1e-3", "x1e3"))
    pairs = comparisons(sets, "cal", ("x1e-3", "x1e3"), "x1e-3")
    if len(pairs) != 194 or sum(p[2] for p in pairs) != 50:
        raise M.Incomplete("STOP R33-1 items3/8: calibration comparison counts differ")
    z = [(f"cal/{scale}", row, at) for row, at in roster(sets) for scale in ("x1", "x1e-3", "x1e3")]
    k = counter_keys()
    want = expected(sets) | set(k)
    tables = {}
    for arm in M.arm_order():
        got = readings[arm]
        M.require_keys(got, want, arm)
        tables[arm] = {"U": M.unit(got, pairs), "BA": M.balanced(got, labels(sets, "cal/x1")),
                       "Z": M.zeros(got, z), "K": M.counter(got, k)}
    # choose() itself guards the registered control, so no caller can obtain
    # a choice from these tables when PRE1045 fails its 0.10 threshold.
    choice = M.choose(tables)
    return {"status": "POINT_ESTIMATES", "arm_order_seed": 1580,
            "registered_arm_order": M.arm_order(), "tables": tables,
            "calibration_choice": choice, "positive_control_meets_0.10": True}


def check_confirmation_counts(sets, population, pairs, receipt):
    """Read the pre-binary count receipt; never retain the superseded42/80."""
    corpus, _ = sets[f"{population}/x1"]
    above_keys = {(left[1], left[2]) for left, _, above in pairs if above}
    trajectories = sorted({row for row, _ in above_keys})
    actual = {"rows": len(corpus["rows"]),
              "checkpoints": sum(len(row["checkpoints"]) for row in corpus["rows"]),
              "all_comparisons": len(pairs), "above_comparisons": sum(above for _, _, above in pairs)}
    M.nonempty(actual["above_comparisons"], f"confirmation {population} above-floor comparisons")
    for name, value in actual.items():
        if receipt.get(name) != value:
            raise M.Incomplete(f"INCOMPLETE: confirmation {population} {name}: derived={value}, manifest={receipt.get(name)!r}")
    declared_keys = {(row["id"], row["checkpoint"]) for row in receipt["above_checkpoints"]}
    if above_keys != declared_keys or trajectories != receipt["above_trajectories"]:
        raise M.Incomplete(f"INCOMPLETE: confirmation {population} above-floor roster differs from pre-binary receipt")
    return {**actual, "above_trajectories": trajectories}


def confirm(data, readings, choice):
    if choice["arm"] not in readings or "F0" not in readings:
        raise M.Incomplete("INCOMPLETE: confirmation needs provisional choice and F0 readings")
    if not set(readings) <= {choice["arm"], "F0", "STD-rel"}:
        raise M.Incomplete("INCOMPLETE: unrelated arm in confirmation readings")
    # The calibration labels at all three study scales derive Z by rule;
    # the actual confirmation arm readings use only x1 and x1e6 there.
    cal = load(data, "cal", ("x1", "x1e-3", "x1e3"))
    ccal = load(data, "confirm-cal", ("x1", "x1e6"))
    hcal = load(data, "confirm-hcal", ("x1", "x1e-3", "x1e3", "x1e6"))
    # Addendum1 changes comparison membership, not item12's BA guard:
    # retain the released original32 and72 for that separate purpose.
    sets = {**ccal, **hcal, "released/x1": P.load_set(data / "judge" / "calibration"),
            "released-hcal/x1": P.load_set(data / "judge" / "hcal")}
    hpairs = comparisons(hcal, "confirm-hcal", ("x1e-3", "x1e3", "x1e6"), "x1e-3")
    cpairs = comparisons(ccal, "confirm-cal", ("x1e6",), "x1")
    receipt_path = data / "confirmation-counts.json"
    receipt = json.loads(receipt_path.read_text())
    if receipt.get("format") != "r33-confirmation-counts/1":
        raise M.Incomplete("INCOMPLETE: unknown confirmation-count receipt format")
    count_i = check_confirmation_counts(hcal, "confirm-hcal", hpairs, receipt["comparison_sets"]["i"])
    count_ii = check_confirmation_counts(ccal, "confirm-cal", cpairs, receipt["comparison_sets"]["ii"])
    z = []
    for row, at in roster(cal):
        label = ccal["confirm-cal/x1e6"][1].get(f"{row}@{at}")
        if label is None or label["converged"][0] == "REPORTED" or label["converged"][1] is not True:
            raise M.Incomplete(f"INCOMPLETE: mandatory Z row {row}@{at} absent or not labelled true at x1e6")
        z.append(("confirm-cal/x1e6", row, at))
    if len(z) != 6:
        raise M.Incomplete("INCOMPLETE: confirmation needs all six Z readings at x1e6")
    k = counter_keys()
    want = expected(sets) | set(k)
    tables = {}
    hlabels = labels(sets, "released-hcal/x1")
    union_labels = {**labels(sets, "released/x1"), **hlabels}
    for arm, got in readings.items():
        M.require_keys(got, want, arm)
        hpoints, upoints = M.balanced(got, hlabels), M.balanced(got, union_labels)
        guards = {p: {"population": "H-cal x1" if hpoints[p]["BA"] is not None else "released72 + H-cal x1",
                      **(hpoints[p] if hpoints[p]["BA"] is not None else upoints[p])} for p in PREDS}
        tables[arm] = {"U": M.unit(got, hpairs + cpairs),
                       "BA_Hcal_point": hpoints, "BA_guard_point": guards,
                       "Z": M.zeros(got, z), "K": M.counter(got, k)}
    return {"status": "POINT_ESTIMATES_ONLY_NOT_JUDGED", "choice": choice, "tables": tables,
            "confirmation_counts": {"i": count_i, "ii": count_ii},
            "confirmation_exclusions": receipt["exclusions"],
            "confirmation_counts_sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
            "required_before_judgment": ["chosen real build matches port at every confirmation checkpoint",
                "frozen judge program BA bounds with seed175833,10000 paired resamples",
                "H-cal guard for predicates with both labels; released72+Hcal guard otherwise"]}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--sweep", action="store_true")
    mode.add_argument("--confirm", action="store_true")
    p.add_argument("--data", type=Path, required=True)
    p.add_argument("--readings", action="append", type=Path, required=True)
    p.add_argument("--choice", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--manifest",type=Path,default=HERE/'r33_data/MANIFEST.json')
    args = p.parse_args(argv)
    digest = None
    try:
        choice = None
        if args.confirm:
            # This precedes all input/population opens and propagates even
            # into refusal output after a valid choice was supplied.
            choice, digest = M.choice_file(args.choice)
        I.verify_manifest(args.manifest)
        if args.data.resolve() != (HERE/'r33_data/populations').resolve():
            raise M.Incomplete('REFUSED: data directory differs from the manifest population root')
        got = records(args.readings, digest if args.confirm else None)
        value = confirm(args.data, got, choice) if args.confirm else sweep(args.data, got)
        value.update(input_sha256={str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in args.readings})
        rc = 0
    except M.ControlFailure as exc:
        value, rc = {"status": "VOID", "reason": str(exc)}, 2
    except (M.Incomplete, HarnessError, OSError, ValueError, KeyError, TypeError, StopIteration) as exc:
        value, rc = {"status": "REFUSED", "reason": str(exc)}, 2
    result = M.envelope(value, digest)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    output = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"
    args.out.write_text(output)
    print(output, end="")
    return rc


if __name__ == "__main__":
    sys.exit(main())
