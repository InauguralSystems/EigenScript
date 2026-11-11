#!/usr/bin/env python3
"""Hand-written examples only for addendum3's registered procedure steps.

No staged population, saved population reading or fixture file is opened.
The small labelled verdict matrices below are written here in full. Actual
collection is demonstrated on the literal hand window [2.0, 2.0, 2.0].
"""
import argparse
import copy
import contextlib
import io
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import sys
import tempfile

from schema import PREDS
from r33_port import GROUPS
import r33_collect as C
import r33_metrics as M
import r33_procedure as D
import r33_run as R


def hand_context():
    names = ("cal/x1", "cal/x1e-3", "cal/x1e3")
    keys = {(name, row, 10) for name in names for row in ("hand-positive", "hand-negative")}
    k = [("counter/x1", "int64_count", at) for at in (10, 60)]
    labelled = {("cal/x1", row, 10): {p: ["DERIVED", truth] for p in PREDS}
                for row, truth in (("hand-positive", True), ("hand-negative", False))}
    return {"expected": keys | set(k), "labels": labelled,
            "pairs": [(("cal/x1", row, 10), (name, row, 10), True)
                      for row in ("hand-positive", "hand-negative") for name in names[1:]],
            "z": [(name, "hand-positive", 10) for name in names], "k": k}


def hand_readings(context):
    values = {key: {p: key[1] == "hand-positive" for p in PREDS} for key in context["expected"]}
    for key in context["k"]:
        values[key] = {p: p == "diverging" for p in PREDS}
    return values


def hand_confirmation(subject="C_1e-6^hist", *, z=True):
    """Two pairs in (i), three in (ii); H-cal lacks two positive labels."""
    guards, hcal = {}, {}
    for p in PREDS:
        both = p not in {"diverging", "equilibrium"}
        hcal[p] = {"TP": int(both), "FN": 0, "TN": 1, "FP": 0,
                   "BA": M.ratio(1, 1) if both else None}
        guards[p] = {"population": "H-cal x1" if both else "released72 + H-cal x1",
                     "BA": M.ratio(1, 1), "TP": 1, "FN": 0, "TN": 1, "FP": 0}
    return {"subject": subject, "U": {"U_above": M.ratio(0, 5), "U_all": M.ratio(0, 5)},
            "U_parts": {"i": {"U_above": M.ratio(0, 2)}, "ii": {"U_above": M.ratio(0, 3)}},
            "Z": {"Z": M.ratio(int(z), 1)}, "K": {"K": M.ratio(1, 1)},
            "BA_Hcal_point": hcal, "BA_guard_point": guards}


def hand_proof(subject="C_1e-6^hist"):
    return {"format": "r33-build-identity/1", "arm": subject, "commit": "a" * 40,
            "status": "MATCH", "mismatches": 0, "checkpoints": 5, "fields_compared": 65,
            "choice_sha256": "e" * 64, "manifest_sha256": "c" * 64,
            "binary_sha256": hashlib.sha256(subject.encode()).hexdigest(), "recipe_id": "d" * 64,
            "f0": {"source_sha": D.J.SUBJECT, "recipe_id": "d" * 64,
                   "binary_sha256": "f" * 64}}


def hand_judge(lower="-0.0199", subject="C_1e-6^hist"):
    proof = hand_proof(subject)
    identities = {"F0": {**proof["f0"], "stamp_binary_sha256": proof["f0"]["binary_sha256"]},
                  "ARM": {"source_sha": proof["commit"], "binary_sha256": proof["binary_sha256"],
                          "recipe_id": proof["recipe_id"], "stamp_binary_sha256": proof["binary_sha256"]}}
    paths = {"F0": "hand/F0", "ARM": "hand/candidate"}
    command = ["python3", "-I", "tools/observer_oracle/judge.py", "--arm", "F0=" + paths["F0"],
               "--arm", "ARM=" + paths["ARM"], "--diff", "ARM,F0", "--seed", "175833", "--resamples", "10000"]
    return {name: {"format": "r33-judge-proof/1", "population": name, "returncode": 0,
        "arms": identities, "binary_paths": paths, "candidate_policy": subject,
        "choice_sha256": proof["choice_sha256"], "manifest_sha256": proof["manifest_sha256"],
        "judge_sha256": D.J.sha(D.J.HERE / "judge.py"), "command": command,
        "bounds": {p: {"bound_print_precision": 4, "printed_lower": lower,
            "printed_point_difference": "0.0000", "printed_upper": "0.0100",
            "resamples_set_aside": 1 if p == "equilibrium" else 0, "scored_verdicts_per_arm": 2}
            for p in PREDS}} for name in ("hcal", "union")}


def run_hand_tests():
    evidence = {"format": "r33-procedure-hand/1", "population_reads": 0, "checks": []}
    def check(name, test, **detail):
        if not test:
            raise AssertionError(name)
        evidence["checks"].append({"name": name, "verdict": "MET", **detail})
    def refuses(name, function, fragment):
        try:
            function()
        except (M.Incomplete, ValueError, KeyError) as error:
            if fragment not in str(error):
                raise AssertionError(f"{name}: wrong refusal: {error}") from error
            evidence["checks"].append({"name": name, "verdict": "REFUSED", "red_line": str(error)})
        else:
            raise AssertionError(name + ": failed to refuse")
    context = hand_context()
    values = hand_readings(context)
    table = R.subject_tables("F0", values, context)
    check("a one subject uses every declared key, comparison, label and roster", table["U"]["U_above"]["value"] == 0
          and table["support"]["comparisons"] == 4 and table["choice_made"] is False,
          table=table)
    absent = dict(values)
    absent.pop(("cal/x1", "hand-positive", 10))
    refuses("a missing real hand reading", lambda: R.subject_tables("F0", absent, context), "missing=1")
    empty = {**context, "pairs": []}
    refuses("a empty comparison cannot pass", lambda: R.subject_tables("F0", values, empty), "empty unit comparisons")
    binary_absent = dict(values)
    missing_key = ("cal/x1e3", "hand-positive", 10)
    binary_absent.pop(missing_key)
    binary_table = R.subject_tables("HAND_BINARY", binary_absent, context, binary=True,
        not_read=[{"set": missing_key[0], "row": missing_key[1], "reason": "hand capability skip"}])
    check("a binary unavailable scale removes every comparison of its base", binary_table["support"]["comparisons"] == 2
          and binary_table["support"]["comparison_bases_removed"] == ["hand-positive"]
          and binary_table["Z"]["status"].startswith("NOT_READ"), table=binary_table)
    all_missing = [{"set": key[0], "row": key[1], "at": key[2], "reason": "hand probe raised"}
                   for key in context["expected"]]
    not_read = R.subject_tables("HAND_BINARY", {}, context, binary=True, not_read=all_missing)
    check("a all binary readings unavailable prints incomplete/not read", not_read["U"]["U_all"] is None
          and not_read["Z"]["Z"] is None and not_read["K"]["K"] is None, table=not_read)
    refuses("a missing binary reading needs explicit cannot_run reason",
            lambda: R.subject_tables("HAND_BINARY", binary_absent, context, binary=True), "do not partition")
    control_values = copy.deepcopy(values)
    control_values[("cal/x1e3", "hand-negative", 10)]["stable"] = True
    control_table = R.subject_tables("PRE1045", control_values, context)
    good_control = R.positive_control(control_table)
    check("b positive control detects a hand flip", good_control["met"] is True, result=good_control)
    failed_control = R.positive_control(R.subject_tables("PRE1045", values, context))
    check("b failed positive control says experiment stops", failed_control["met"] is False
          and failed_control["status"] == "NOT_MET_EXPERIMENT_STOPS", result=failed_control)
    refuses("b wrong subject cannot serve as control", lambda: R.positive_control(table), "requires PRE1045")
    with tempfile.TemporaryDirectory(prefix="r33-procedure-hand-") as directory:
        temp = Path(directory)
        posted = temp / "posted-first-measurement.txt"
        posted.write_text("HAND ONLY: first measurement posted\n")
        digest = M.first_measurement_file(posted)
        row = {"arm": "C_1e-6^hist", "set": "cal/x1", "row": "hand", "at": 2,
               "predicates": {p: False for p in PREDS}, "groups": list(GROUPS)}
        reading_path = temp / "hand-readings.jsonl"
        reading_path.write_text(json.dumps(row) + "\n")
        refuses("b sweep reader rejects missing posted first measurement digest",
                lambda: R.records([reading_path], expected_first_measurement_sha256=digest), "lacks the posted")
        row["first_measurement_sha256"] = digest
        reading_path.write_text(json.dumps(row) + "\n")
        check("b posted bytes digest accepted in every reading",
              "C_1e-6^hist" in R.records([reading_path], expected_first_measurement_sha256=digest))
        refuses("a single group reading cannot be called the full arm", lambda: R.records(
            [reading_path], expected_first_measurement_sha256=digest, expected_groups=("S1",)),
            "not the complete arm")
        refuses("b collector refuses before touching a hand window without posted file",
                lambda: C.collect("STD-rel", {}), "requires posted first")
        hand_sets = {"hand/x1": {"rows": [{"id": "written-three-twos", "n": 2, "gen": {
            "kind": "cycle", "values": [2.0, 2.0, 2.0]}, "checkpoints": [2]}]}}
        ledger = temp / "actual-order.json"
        rows, raw = C.collect_logged("F0", hand_sets, None, phase="calibration", run_log=ledger)
        rows2, raw2 = C.collect_logged("PRE1045", hand_sets, None, phase="calibration", run_log=ledger)
        actual = json.loads(ledger.read_text())
        check("g running collector logs actual order beside drawn order", actual["actual_started_order"] == ["F0", "PRE1045"]
              and actual["actual_completed_order"] == ["F0", "PRE1045"]
              and actual["drawn_order"] == M.arm_order(), ledger=actual,
              hand_window=[2.0, 2.0, 2.0])
        refuses("g a second execution cannot replace the first", lambda: C.collect_logged("F0", hand_sets, None,
                phase="calibration", run_log=ledger), "already run")
        refuses("g permuting groups cannot bypass run-once", lambda: C.collect_logged("F0", hand_sets,
                tuple(reversed(GROUPS)), phase="calibration", run_log=ledger), "already run")
        refuses("g collector order log rejects missing first measurement for STD-rel", lambda: C.collect_logged(
                "STD-rel", hand_sets, None, phase="calibration", run_log=ledger), "requires posted")
    ctable = hand_confirmation()
    judgment = D.confirmation_judgment(ctable["subject"], ctable, hand_judge(), hand_proof())
    check("c all confirmation criteria met with emitted -0.0199", judgment["met"] is True, result=judgment)
    boundary = D.confirmation_judgment(ctable["subject"], ctable, hand_judge("-0.0200"), hand_proof())
    check("c printed -0.0200 is not above -0.02", boundary["met"] is False
          and all(cell["met"] is False for cell in boundary["BA_bounds"].values()), result=boundary)
    bad_z = hand_confirmation(z=False)
    rejected_port = D.confirmation_judgment(bad_z["subject"], bad_z)
    check("c failed C port waits for its build and judge bounds", rejected_port["met"] is False
          and rejected_port["BA_bound_status"] == "NOT_TAKEN", result=rejected_port)
    failed_c_all = D.confirmation_judgment(bad_z["subject"], bad_z, hand_judge(), hand_proof())
    check("c C failed port still prints every supplied BA criterion", failed_c_all["met"] is False
          and failed_c_all["judgment_complete"] is True
          and all(cell["met"] is True for cell in failed_c_all["BA_bounds"].values()), result=failed_c_all)
    wrong_support = hand_judge()
    wrong_support["union"]["bounds"]["equilibrium"]["scored_verdicts_per_arm"] = 3
    refuses("c bound support must match predicate guard population", lambda: D.confirmation_judgment(
            ctable["subject"], ctable, wrong_support, hand_proof()), "judge support differs")
    std_bad_z = hand_confirmation("STD-rel", z=False)
    rejected_std = D.confirmation_judgment("STD-rel", std_bad_z)
    check("c STD-rel port first and no bound after failed Z", rejected_std["eligible_for_bound"] is False
          and rejected_std["judgment_complete"] is True, result=rejected_std)
    wrong_population = hand_judge()
    wrong_population["hcal"]["population"] = "union"
    refuses("c each bound must use its own predicate population", lambda: D.confirmation_judgment(
            ctable["subject"], ctable, wrong_population, hand_proof()), "needs the frozen judge's hcal")
    refuses("c cannot judge a nonmatching build", lambda: D.confirmation_judgment(ctable["subject"], ctable,
            hand_judge(), {**hand_proof(), "mismatches": 1}), "requires this arm")
    unbound = hand_judge()
    unbound["hcal"]["choice_sha256"] = None
    refuses("c unbound judge execution cannot supply the confirmation bound", lambda: D.confirmation_judgment(
            ctable["subject"], ctable, unbound, hand_proof()), "does not bind")
    wrong_build = hand_judge()
    wrong_build["union"]["arms"] = copy.deepcopy(wrong_build["union"]["arms"])
    wrong_build["union"]["arms"]["ARM"]["source_sha"] = "b" * 40
    refuses("c bound from another candidate build cannot pass identity linkage", lambda: D.confirmation_judgment(
            ctable["subject"], ctable, wrong_build, hand_proof()), "differs from build-port")
    wrong_command = hand_judge()
    wrong_command["hcal"]["command"] = ["other-program"]
    refuses("c arbitrary command cannot name a frozen judge bound", lambda: D.confirmation_judgment(
            ctable["subject"], ctable, wrong_command, hand_proof()), "not the frozen program")
    std_table = hand_confirmation("STD-rel")
    std_port = D.port_confirmation("STD-rel", std_table)
    c_failed = {**judgment, "met": False}
    plan = D.standard_first(c_failed, std_port, ctable, std_table)
    check("d STD second build only after port passes and C fails", plan["second_build_allowed"] is True
          and plan["selected"] is None, result=plan)
    refuses("c STD bound needs standard-first permission", lambda: D.confirmation_judgment("STD-rel", std_table,
            hand_judge(subject="STD-rel"), hand_proof("STD-rel")), "requires standard-first")
    std_full = D.confirmation_judgment("STD-rel", std_table, hand_judge(subject="STD-rel"), hand_proof("STD-rel"), plan)
    standard = D.standard_first(c_failed, std_full, ctable, std_table)
    check("d STD passes and C fails selects STD", standard["selected"] == "STD-rel", result=standard)
    same = D.standard_first(judgment, std_full, ctable, std_table)
    check("d both pass without C advantage selects standard", same["selected"] == "STD-rel", result=same)
    c_edge_table = copy.deepcopy(ctable)
    c_edge_table["U"]["U_all"] = M.ratio(0, 100)
    std_edge_table = copy.deepcopy(std_table)
    std_edge_table["U"]["U_all"] = M.ratio(2, 100)
    edge = D.standard_first(judgment, std_full, c_edge_table, std_edge_table)
    check("d U_all STD-minus-C exact 0.02 selects C", edge["selected"] == ctable["subject"]
          and edge["C_advantage"]["U_all_STD_minus_C"]["exact"] == "1/50", result=edge)
    c_ba_table = copy.deepcopy(ctable)
    std_ba_table = copy.deepcopy(std_table)
    std_ba_table["BA_guard_point"]["stable"]["BA"] = M.ratio(98, 100)
    ba_edge = D.standard_first(judgment, std_full, c_ba_table, std_ba_table)
    check("d some predicate BA exact 0.02 selects C", ba_edge["selected"] == ctable["subject"], result=ba_edge)
    both_fail = D.standard_first(c_failed, rejected_std, ctable, std_bad_z)
    check("d neither passes leaves F0 and reopens Done-when", both_fail["selected"] == "F0"
          and both_fail["reopen_done_when"] is True, result=both_fail)
    no_c = D.standard_first(None, std_full)
    check("d no feasible C still judges STD alone", no_c["selected"] == "STD-rel", result=no_c)
    refuses("d unjudged C cannot be treated as failed", lambda: D.standard_first(
            {**judgment, "judgment_complete": False}, std_full, ctable, std_table), "not judged")
    f0 = copy.deepcopy(table)
    total = copy.deepcopy(control_table)
    total["subject"] = ctable["subject"]
    for p in PREDS:
        f0["BA"][p]["BA"] = M.ratio(1, 2)
        total["BA"][p]["BA"] = M.ratio(4, 5)
    f0["U"]["U_above"] = M.ratio(2, 5)
    total["U"]["U_above"] = M.ratio(1, 10)
    group_tables = {}
    for group in GROUPS:
        value = copy.deepcopy(total)
        value["groups"] = [group]
        value["U"]["U_above"] = M.ratio(3, 10)
        for p in PREDS:
            value["BA"][p]["BA"] = M.ratio(3, 5)
        group_tables[group] = value
    loo = D.leave_one_out(ctable["subject"], f0, total, group_tables)
    residual = loo["residual_total_effect_minus_group_effects"]
    check("f residual uses total effect minus each effect against F0", all(M.fraction(cell) == 0
          for cell in residual.values()), result=loo)
    refuses("f missing group cannot silently lower the residual", lambda: D.leave_one_out(
            ctable["subject"], f0, total, {"S1": group_tables["S1"]}), "each of the three")
    check("f group table must be alone", D.leave_one_out(ctable["subject"], f0, total, group_tables)["groups"]["S1"]
          ["U_above"]["exact"] == "3/10")
    with tempfile.TemporaryDirectory(prefix="r33-procedure-cli-hand-") as directory:
        temp = Path(directory)
        def put(name, value):
            path = temp / name
            path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
            return path
        posted_choice = put("choice.json", {"arm": ctable["subject"], "sweep_tables_sha256": "0" * 64})
        _choice, choice_sha = M.choice_file(posted_choice)
        source_table = put("confirmation.json", {"choice_sha256": choice_sha, "tables": {
            ctable["subject"]: ctable, "STD-rel": std_table}})
        proof_file = put("identity.json", {**hand_proof(), "choice_sha256": choice_sha})
        bounds_files = {name: put(name + ".json", {"format": "r33-judge-proof/1",
            **value, "choice_sha256": choice_sha}) for name, value in hand_judge().items()}
        result_file = temp / "judgment.json"
        command = ["confirmation", "--choice", str(posted_choice), "--subject", ctable["subject"],
            "--table", str(source_table), "--judge-hcal", str(bounds_files["hcal"]),
            "--judge-union", str(bounds_files["union"]), "--identity", str(proof_file), "--out", str(result_file)]
        with contextlib.redirect_stdout(io.StringIO()):
            rc = D.main(command)
        cli_result = json.loads(result_file.read_text())
        check("c confirmation CLI carries posted choice sha into its output", rc == 0
              and cli_result["met"] is True and cli_result["choice_sha256"] == choice_sha)
        with contextlib.redirect_stdout(io.StringIO()):
            rc = D.main(["confirmation", "--subject", ctable["subject"], "--table", "unopened", "--out", str(result_file)])
        check("c confirmation CLI refuses without posted choice before other input opens", rc == 2
              and "requires posted choice" in json.loads(result_file.read_text())["reason"])
        bad_std_file = put("std-port-fails.json", {"choice_sha256": choice_sha, "table": std_bad_z})
        with contextlib.redirect_stdout(io.StringIO()):
            rc = D.main(["confirmation", "--choice", str(posted_choice), "--subject", "STD-rel",
                "--table", str(bad_std_file), "--judge-hcal", "unopened", "--judge-union", "unopened",
                "--identity", "unopened", "--out", str(result_file)])
        check("c STD failed port CLI does not open judge or build files", rc == 0
              and json.loads(result_file.read_text())["BA_bound_status"] == "NOT_TAKEN")
        c_result_file = put("c-result.json", {**judgment, "choice_sha256": choice_sha})
        std_result_file = put("std-result.json", {**std_full, "choice_sha256": choice_sha})
        with contextlib.redirect_stdout(io.StringIO()):
            rc = D.main(["standard-first", "--choice", str(posted_choice), "--c-result", str(c_result_file),
                "--std-result", str(std_result_file), "--c-table", str(source_table),
                "--std-table", str(source_table), "--out", str(result_file)])
        check("d standard-first CLI produces its registered selection", rc == 0
              and json.loads(result_file.read_text())["selected"] == "STD-rel")
        with contextlib.redirect_stdout(io.StringIO()):
            rc = D.main(["standard-first", "--choice", str(posted_choice),
                "--std-result", str(std_result_file), "--out", str(result_file)])
        check("d C choice with omitted C result refuses", rc == 2
              and "requires the posted C choice" in json.loads(result_file.read_text())["reason"])
        unbound_file = put("unbound-hcal.json", {**hand_judge()["hcal"], "choice_sha256": None})
        bad_command = [str(unbound_file) if value == str(bounds_files["hcal"]) else value for value in command]
        with contextlib.redirect_stdout(io.StringIO()):
            rc = D.main(bad_command)
        check("c CLI rejects a judge receipt without exact posted choice sha", rc == 2
              and "judge output does not bind" in json.loads(result_file.read_text())["reason"])
        baseline_file, total_file = put("baseline.json", f0), put("total.json", total)
        group_files = {group: put(group + ".json", table) for group, table in group_tables.items()}
        with contextlib.redirect_stdout(io.StringIO()):
            rc = D.main(["leave-one-out", "--choice", str(posted_choice),
                "--baseline-table", str(baseline_file), "--total-table", str(total_file),
                *[arg for group, path in group_files.items() for arg in ("--" + group.lower() + "-table", str(path))],
                "--out", str(result_file)])
        check("f leave-one-out CLI carries the effects residual", rc == 0
              and json.loads(result_file.read_text())["residual_total_effect_minus_group_effects"]["U_above"]["exact"] == "0")
    for entry in evidence["checks"]:
        print("HAND " + entry["name"] + ": " + entry["verdict"])
    print(f"R33 PROCEDURE HAND: {len(evidence['checks'])} checks; no population read")
    return evidence


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    result = run_hand_tests()
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
