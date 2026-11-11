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
--single makes one subject table without a choice; --positive-control tests
PRE1045 separately. Confirmation judgment is r33_procedure.py, using the frozen
judge printed bounds after real build identity. No bootstrap is reproduced.
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
from r33_port import POLICIES, GROUPS
import r33_metrics as M
import r33_population as P
import r33_identity as I

HERE = Path(__file__).resolve().parent


def records(paths, expected_choice_sha256=None, expected_first_measurement_sha256=None,
            named_subject=None, require_full_groups=False, expected_groups=None):
    """Read explicit verdicts and validate both posted-file order witnesses."""
    arms = {}
    for path in paths:
        with Path(path).open() as source:
            for number, line in enumerate(source, 1):
                try:
                    record = json.loads(line)
                    arm = record["arm"]
                    if arm not in POLICIES and arm != named_subject:
                        raise ValueError("unregistered arm")
                    if arm in POLICIES and arm not in {"F0", "PRE1045"}:
                        if (expected_first_measurement_sha256 is None or
                                record.get("first_measurement_sha256") != expected_first_measurement_sha256):
                            raise M.Incomplete(f"REFUSED: {arm} reading lacks the posted first measurement sha256")
                    if ((require_full_groups or expected_groups is not None) and
                            record.get("groups") != list(GROUPS if expected_groups is None else expected_groups)):
                        raise M.Incomplete(f"REFUSED: {arm} sweep reading is not the complete arm")
                    if expected_choice_sha256 is not None:
                        bound = record.get('choice_sha256')
                        allowed = {None, expected_choice_sha256} if arm == 'F0' else {expected_choice_sha256}
                        if bound not in allowed:
                            raise M.Incomplete(f'REFUSED: {arm} input choice_sha256 does not match posted choice')
                except M.Incomplete:
                    raise
                except (KeyError, TypeError, ValueError) as exc:
                    raise M.Incomplete(f"INCOMPLETE: invalid reading at {path}:{number}") from exc
                arms.setdefault(arm, []).append(record)
    if named_subject is not None and not arms:
        # A named binary can supply no reading when its capability probe
        # raises. Its explicit cannot_run receipt must account for every key.
        return {named_subject: {}}
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


def calibration_context(data):
    """One derivation of the sweep's keys, masks, roster and label support."""
    sets = load(data, "cal", ("x1", "x1e-3", "x1e3"))
    pairs = comparisons(sets, "cal", ("x1e-3", "x1e3"), "x1e-3")
    if len(pairs) != 194 or sum(p[2] for p in pairs) != 50:
        raise M.Incomplete("STOP R33-1 items3/8: calibration comparison counts differ")
    z = [(f"cal/{scale}", row, at) for row, at in roster(sets)
         for scale in ("x1", "x1e-3", "x1e3")]
    k = counter_keys()
    return {"pairs": pairs, "labels": labels(sets, "cal/x1"), "z": z, "k": k,
            "expected": expected(sets) | set(k)}


def subject_tables(subject, got, context, *, binary=False, not_read=(), diagnostics=None, groups=None):
    """Items8-10 for one subject. This path never calls choose().

    Runtime-reference subjects have the addendum3-only missing support rule.
    Every unavailable reading must be named by their cannot_run receipt;
    an unavailable scale removes that base's complete set of U comparisons.
    BA retains each available x1 reading; Z/K state what was not read.
    """
    want = set(M.nonempty(context["expected"], "subject expected readings"))
    omissions = {}
    for entry in not_read:
        if (not isinstance(entry, dict) or not isinstance(entry.get("reason"), str)
                or not entry["reason"] or not isinstance(entry.get("set"), str)
                or not isinstance(entry.get("row"), str)):
            raise M.Incomplete("INCOMPLETE: malformed binary cannot_run receipt")
        keys = {key for key in want if key[0] == entry["set"] and key[1] == entry["row"]
                and ("at" not in entry or key[2] == entry["at"])}
        if not keys or set(omissions) & keys:
            raise M.Incomplete("INCOMPLETE: duplicate or undeclared binary cannot_run row")
        for key in keys:
            omissions[key] = entry["reason"]
    if binary:
        if subject in POLICIES:
            raise M.Incomplete("REFUSED: a binary reference name must be outside the eleven arms")
        if set(got) & set(omissions) or set(got) | set(omissions) != want:
            raise M.Incomplete("INCOMPLETE: binary readings and cannot_run reasons do not partition declared support")
        removed = {key[1] for key in omissions if key[0].startswith("cal/")}
        pairs = [pair for pair in context["pairs"] if pair[0][1] not in removed]
        ba_labels = {key: value for key, value in context["labels"].items() if key in got}
        u = M.unit(got, pairs, allow_empty=True)
        ba = M.balanced(got, ba_labels) if ba_labels else {
            p: {"BA": None, "status": "NOT_READ: no available x1 labels"} for p in PREDS}
        available_z = [key for key in context["z"] if key in got]
        z = M.zeros(got, available_z) if available_z else {"Z": None, "readings": []}
        z["not_read"] = [{"key": list(key), "reason": omissions[key]}
                         for key in context["z"] if key not in got]
        z["status"] = "NOT_READ: incomplete Z support" if z["not_read"] else "COMPLETE"
        missing_k = [key for key in context["k"] if key not in got]
        k = M.counter(got, context["k"]) if not missing_k else {
            "K": None, "status": "NOT_READ: incomplete typed K support",
            "not_read": [{"key": list(key), "reason": omissions[key]} for key in missing_k]}
    else:
        if subject not in POLICIES or omissions:
            raise M.Incomplete("REFUSED: unregistered policy or missing policy reading")
        M.require_keys(got, want, subject)
        removed, pairs, ba_labels = set(), context["pairs"], context["labels"]
        u, ba = M.unit(got, pairs), M.balanced(got, ba_labels)
        z, k = M.zeros(got, context["z"]), M.counter(got, context["k"])
    rows = {(key[0], key[1]) for key in got}
    return {"subject": subject, "groups": list(GROUPS if groups is None else (group for group in GROUPS if group in groups)),
            "U": u, "BA": ba, "Z": z, "K": k,
            "support": {"declared_readings": len(want), "readings": len(got),
                        "rows_at_scales": len(rows), "x1_BA_rows": len({key[1] for key in ba_labels}),
                        "x1_BA_checkpoints": len(ba_labels), "comparisons": len(pairs),
                        "above_comparisons": sum(pair[2] for pair in pairs),
                        "comparison_bases": len({pair[0][1] for pair in pairs}),
                        "comparison_bases_removed": sorted(removed),
                        "not_read": [{"key": list(key), "reason": reason}
                                     for key, reason in sorted(omissions.items())]},
            "binary_diagnostics": diagnostics if binary else None,
            "choice_made": False}


def single(data, subject, readings, binary_receipt=None, groups=None):
    if set(readings) != {subject}:
        raise M.Incomplete("INCOMPLETE: single-subject tables need exactly the named subject")
    receipt = binary_receipt or {}
    table = subject_tables(subject, readings[subject], calibration_context(data),
                           binary=subject not in POLICIES,
                           not_read=receipt.get("cannot_run", receipt.get("not_read", [])),
                           diagnostics=receipt.get("diagnostics"), groups=groups)
    return {"status": "POINT_ESTIMATES", "subject": subject, "table": table,
            "choice_made": False}


def positive_control(table):
    if table.get("subject") != "PRE1045":
        raise M.Incomplete("REFUSED: positive control requires PRE1045's single-subject tables")
    try:
        result = M.require_positive_control({"PRE1045": table})
        return {"status": "MET", "met": True, "U_above": result,
                "criterion": "PRE1045 U_above >= 0.10"}
    except M.ControlFailure as exc:
        return {"status": "NOT_MET_EXPERIMENT_STOPS", "met": False,
                "reason": str(exc), "U_above": table["U"]["U_above"],
                "criterion": "PRE1045 U_above >= 0.10"}


def sweep(data, readings):
    if set(readings) != set(POLICIES):
        raise M.Incomplete("INCOMPLETE: sweep needs every registered arm exactly once")
    context = calibration_context(data)
    tables = {arm: subject_tables(arm, readings[arm], context) for arm in M.arm_order()}
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
        if label is None or label["converged"][0] == "REPORTED":
            raise M.Incomplete(f"INCOMPLETE: Z row {row}@{at} absent or not labelled at x1e6")
        if label["converged"][1] is True:
            z.append(("confirm-cal/x1e6", row, at))
    M.nonempty(z, "confirmation roster rows labelled true at x1e6")
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
        tables[arm] = {"subject": arm, "U": M.unit(got, hpairs + cpairs),
                       "U_parts": {"i": M.unit(got, hpairs), "ii": M.unit(got, cpairs)},
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
    mode.add_argument("--single", action="store_true", help="one subject; no calibration choice")
    mode.add_argument("--positive-control", action="store_true", help="PRE1045 only, before sweep")
    p.add_argument("--subject")
    p.add_argument("--groups", nargs="*", choices=GROUPS, default=None)
    p.add_argument("--not-read", type=Path, help="named binary cannot_run receipt")
    p.add_argument("--first-measurement", type=Path)
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
        if (args.single or args.positive_control) and not args.subject:
            raise M.Incomplete("REFUSED: a one-subject entry point requires --subject")
        measurement_sha = (M.first_measurement_file(args.first_measurement)
                           if args.first_measurement is not None else None)
        got = records(args.readings, digest if args.confirm else None, measurement_sha,
                      args.subject if args.single else None, require_full_groups=args.sweep or args.confirm,
                      expected_groups=(tuple(group for group in GROUPS if group in args.groups) if args.groups is not None else GROUPS)
                      if (args.single or args.positive_control) and args.subject in POLICIES else None)
        if args.single or args.positive_control:
            receipt = json.loads(args.not_read.read_text()) if args.not_read else None
            value = single(args.data, args.subject, got, receipt, args.groups)
            if args.positive_control:
                value["positive_control"] = positive_control(value["table"])
        else:
            value = confirm(args.data, got, choice) if args.confirm else sweep(args.data, got)
        value["first_measurement_sha256"] = measurement_sha
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
