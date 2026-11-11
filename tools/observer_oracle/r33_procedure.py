#!/usr/bin/env python3
"""R33-1 decisions on supplied tables, printed judge bounds and identity proofs.

This program does not run a classifier, build an arm or resample labels.
It hashes frozen guard inputs to verify the declared judge populations. Hand demonstrations live in r33_procedure_unit.py. File
provenance is carried into every CLI output; a confirmation also requires the
posted choice bytes before its other inputs are opened.
"""
import argparse
from decimal import Decimal, InvalidOperation
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import sys

from schema import PREDS
from r33_port import GROUPS
import r33_metrics as M
import r33_judge as J


def exact(cell, context):
    try:
        value = M.fraction(cell)
    except (KeyError, TypeError, ValueError, ZeroDivisionError) as error:
        raise M.Incomplete(f"INCOMPLETE: undefined {context}") from error
    return value


def printed_guard(bound):
    """Addendum2 3(d): judge the emitted decimal, including its rounding."""
    if not isinstance(bound, dict) or bound.get("bound_print_precision") != 4:
        raise M.Incomplete("INCOMPLETE: guard needs the frozen judge's four-decimal bound")
    text = bound.get("printed_lower")
    try:
        lower = Decimal(text)
    except (InvalidOperation, TypeError, ValueError) as error:
        raise M.Incomplete("INCOMPLETE: invalid printed judge lower bound") from error
    if (not isinstance(text, str) or not lower.is_finite() or
            lower.as_tuple().exponent != -4 or not 0 <= bound.get("resamples_set_aside", -1) < 10000):
        raise M.Incomplete("INCOMPLETE: undefined, unprinted or unsupported judge lower bound")
    return {"criterion": "printed lower 95% BA difference bound > -0.02",
            "printed_lower": text, "met": lower > Decimal("-0.02"),
            "resamples_set_aside": bound["resamples_set_aside"]}


def guard_populations(table):
    """Item12: use H-cal when it has both labels, released72+H-cal otherwise."""
    populations = {}
    for p in PREDS:
        h = table["BA_Hcal_point"][p]
        both = h.get("TP", 0) + h.get("FN", 0) > 0 and h.get("TN", 0) + h.get("FP", 0) > 0
        population = "hcal" if both else "union"
        declared = table["BA_guard_point"][p].get("population")
        expected = "H-cal x1" if both else "released72 + H-cal x1"
        if declared != expected:
            raise M.Incomplete(f"INCOMPLETE: {p} BA guard population differs from item12: {declared!r}")
        exact(table["BA_guard_point"][p]["BA"], f"{p} BA point on {population}")
        populations[p] = population
    return populations


def port_confirmation(subject, table):
    """Check U/Z/K first, especially before any STD-rel second build/bound."""
    if table.get("subject", subject) != subject:
        raise M.Incomplete("REFUSED: confirmation table subject differs from requested subject")
    criteria = {}
    for part in ("i", "ii"):
        unit = table["U_parts"][part]
        criteria["U_above_" + part] = {
            "criterion": "U_above = 0", "value": unit["U_above"],
            "met": exact(unit["U_above"], f"confirmation {part} U_above") == 0}
    # The pooled value must carry exactly the same counted comparisons.
    pooled = table["U"]["U_above"]
    parts = [table["U_parts"][part]["U_above"] for part in ("i", "ii")]
    if (pooled["numerator"] != sum(cell["numerator"] for cell in parts)
            or pooled["denominator"] != sum(cell["denominator"] for cell in parts)):
        raise M.Incomplete("INCOMPLETE: pooled confirmation U_above differs from parts(i)+(ii)")
    for name in ("Z", "K"):
        value = table[name][name]
        criteria[name] = {"criterion": name + " = 1", "value": value,
                          "met": exact(value, "confirmation " + name) == 1}
    met = all(criterion["met"] for criterion in criteria.values())
    return {"format": "r33-confirmation-port/1", "subject": subject,
            "status": "PORT_CRITERIA_MET" if met else "PORT_CRITERIA_NOT_MET",
            "port_met": met, "eligible_for_bound": met, "met": False,
            "criteria": criteria, "BA_bound_status": "NOT_TAKEN", "judgment_complete": not met}


def check_build_identity(proof, subject):
    if (not isinstance(proof, dict) or proof.get("format") != "r33-build-identity/1"
            or proof.get("arm") != subject or proof.get("status") != "MATCH"
            or proof.get("mismatches") != 0 or proof.get("checkpoints", 0) <= 0
            or proof.get("fields_compared", 0) <= 0
            or not isinstance(proof.get("commit"), str) or len(proof["commit"]) != 40
            or not all(isinstance(proof.get(field), str) and len(proof[field]) == 64
                       for field in ("binary_sha256", "recipe_id", "manifest_sha256", "choice_sha256"))
            or not isinstance(proof.get("f0"), dict)
            or proof["f0"].get("source_sha") != J.SUBJECT
            or not all(isinstance(proof["f0"].get(field), str) and len(proof["f0"][field]) == 64
                       for field in ("binary_sha256", "recipe_id"))):
        raise M.Incomplete("REFUSED: confirmation judgment requires this arm's nonempty build-port identity proof")
    return proof


def check_judge_execution(receipt, identity, subject, population):
    """A printed bound belongs to the exact build, F0, manifest and choice."""
    if (not isinstance(receipt, dict) or receipt.get("format") != "r33-judge-proof/1"
            or receipt.get("population") != population or receipt.get("returncode") != 0
            or receipt.get("candidate_policy") != subject
            or not identity.get("choice_sha256")
            or receipt.get("choice_sha256") != identity["choice_sha256"]
            or receipt.get("manifest_sha256") != identity.get("manifest_sha256")
            or receipt.get("judge_sha256") != J.sha(J.HERE / "judge.py")):
        raise M.Incomplete("REFUSED: judge execution does not bind this build's policy, choice, manifest and frozen program")
    source_hashes = J.guard_set_hashes()
    names = ("hcal",) if population == "hcal" else ("hcal", "calibration")
    if receipt.get("guard_set_files") != {name: source_hashes[name] for name in names}:
        raise M.Incomplete("REFUSED: judge guard input files differ from the released item12 populations")
    expected_arms = {"ARM": {"source_sha": identity["commit"],
                             "binary_sha256": identity["binary_sha256"],
                             "recipe_id": identity["recipe_id"]}, "F0": identity["f0"]}
    for name, expected in expected_arms.items():
        actual = receipt.get("arms", {}).get(name, {})
        if (any(actual.get(field) != expected[field] for field in ("source_sha", "binary_sha256", "recipe_id"))
                or actual.get("stamp_binary_sha256") != actual.get("binary_sha256")):
            raise M.Incomplete(f"REFUSED: judge {name} executable differs from build-port identity proof")
    command, paths = receipt.get("command"), receipt.get("binary_paths")
    if (not isinstance(command, list) or len(command) < 3 or command[1] != "-I"
            or Path(command[2]).name != "judge.py" or not isinstance(paths, dict)):
        raise M.Incomplete("REFUSED: judge execution command is not the frozen program invocation")
    def values(flag):
        return [command[n + 1] for n, token in enumerate(command[:-1]) if token == flag]
    if (set(values("--arm")) != {"F0=" + paths.get("F0", ""), "ARM=" + paths.get("ARM", "")}
            or len(values("--arm")) != 2 or values("--diff") != ["ARM,F0"]
            or values("--seed") != ["175833"] or values("--resamples") != ["10000"]):
        raise M.Incomplete("REFUSED: judge command arms or registered resampling parameters differ")
    return receipt


def confirmation_judgment(subject, table, judge_receipts=None, identity=None, standard_plan=None):
    """Item12 step2: every criterion printed separately with its own support.

    A failed STD-rel port criterion needs no bound or second build. C retains
    every supplied bound even if another criterion fails. A matching build
    and frozen-judge population receipts are required to say 'met'.
    """
    result = port_confirmation(subject, table)
    populations = guard_populations(table)
    result["guard_populations"] = populations
    if not result["port_met"] and subject == "STD-rel":
        result["BA_bounds"] = {p: {"met": None, "status": "NOT_TAKEN: port criterion failed",
                                   "population": populations[p]} for p in PREDS}
        return result
    if judge_receipts is None or identity is None:
        result.update(status="AWAITING_BUILD_IDENTITY_AND_JUDGE_BOUNDS", judgment_complete=False)
        result["BA_bounds"] = {p: {"met": None, "status": "NOT_TAKEN: awaiting matching build and judge output",
                                   "population": populations[p]} for p in PREDS}
        return result
    if subject == "STD-rel" and (not isinstance(standard_plan, dict) or
                                  standard_plan.get("second_build_allowed") is not True):
        raise M.Incomplete("REFUSED: STD-rel bound requires standard-first permission after its port criteria")
    check_build_identity(identity, subject)
    bounds = {}
    for p, population in populations.items():
        receipt = judge_receipts.get(population)
        if not isinstance(receipt, dict) or receipt.get("population") != population or "bounds" not in receipt:
            raise M.Incomplete(f"INCOMPLETE: {p} needs the frozen judge's {population} population output")
        check_judge_execution(receipt, identity, subject, population)
        printed = receipt["bounds"].get(p)
        counts = table["BA_guard_point"][p]
        support = sum(counts[name] for name in ("TP", "FP", "FN", "TN"))
        if not isinstance(printed, dict) or printed.get("scored_verdicts_per_arm") != support:
            raise M.Incomplete(f"INCOMPLETE: {p} judge support differs from its {population} guard population")
        bounds[p] = {"population": population, "scored_verdicts_per_arm": support, **printed_guard(printed)}
    result.update(BA_bounds=bounds, BA_bound_status="TAKEN_FROM_FROZEN_JUDGE",
                  build_identity=identity, judgment_complete=True,
                  met=result["port_met"] and all(cell["met"] for cell in bounds.values()))
    result["status"] = "MET" if result["met"] else "NOT_MET"
    return result


def advantage(c_table, std_table):
    """Item17/addendum3: C's BA advantage or STD U_all minus C U_all."""
    c_populations, std_populations = guard_populations(c_table), guard_populations(std_table)
    if c_populations != std_populations:
        raise M.Incomplete("INCOMPLETE: standard-first BA populations differ")
    ba = {p: exact(c_table["BA_guard_point"][p]["BA"], "C " + p)
             - exact(std_table["BA_guard_point"][p]["BA"], "STD-rel " + p) for p in PREDS}
    u = exact(std_table["U"]["U_all"], "STD-rel U_all") - exact(c_table["U"]["U_all"], "C U_all")
    return {"BA_C_minus_STD": {p: M.ratio(value.numerator, value.denominator) for p, value in ba.items()},
            "U_all_STD_minus_C": M.ratio(u.numerator, u.denominator),
            "met": u >= Fraction(1, 50) or any(value >= Fraction(1, 50) for value in ba.values())}


def standard_first(c_result, std_result, c_table=None, std_table=None):
    """Total item17 cases, including the decision to permit the second build."""
    if std_result.get("subject") != "STD-rel":
        raise M.Incomplete("REFUSED: standard-first needs STD-rel's port confirmation result")
    if c_result is not None and not c_result.get("judgment_complete"):
        raise M.Incomplete("INCOMPLETE: provisional C confirmation is not judged")
    c_pass = bool(c_result and c_result.get("met"))
    edge = advantage(c_table, std_table) if c_result is not None and c_pass else None
    if not std_result.get("port_met"):
        return {"status": "DECIDED", "selected": c_result["subject"] if c_pass else "F0",
                "reopen_done_when": not c_pass, "second_build_allowed": False,
                "reason": "STD-rel failed a port criterion", "C_advantage": edge}
    if c_pass and edge["met"]:
        return {"status": "DECIDED", "selected": c_result["subject"],
                "second_build_allowed": False, "reopen_done_when": False,
                "reason": "C passes and has the item17 advantage", "C_advantage": edge}
    if not std_result.get("judgment_complete"):
        return {"status": "AWAITING_STD_REL_BUILD_IDENTITY_AND_BOUND", "selected": None,
                "second_build_allowed": True, "reopen_done_when": False,
                "reason": "STD-rel port criteria met and C fails or lacks the item17 advantage",
                "C_advantage": edge}
    std_pass = bool(std_result.get("met"))
    selected = "STD-rel" if std_pass else c_result["subject"] if c_pass else "F0"
    return {"status": "DECIDED", "selected": selected,
            "second_build_allowed": True, "reopen_done_when": selected == "F0",
            "reason": "STD-rel full confirmation judged", "C_advantage": edge}


def leave_one_out(arm, baseline, total, groups):
    """Item19/addendum3 1(f): effects against F0, then total minus components."""
    if not isinstance(arm, str) or not arm.startswith("C_") or set(groups) != set(GROUPS):
        raise M.Incomplete("REFUSED: leave-one-out needs f* and each of the three groups exactly once")
    if baseline.get("subject") != "F0" or total.get("subject") != arm:
        raise M.Incomplete("REFUSED: leave-one-out baseline/total subject differs")
    for group in GROUPS:
        if groups[group].get("subject") != arm or groups[group].get("groups") != [group]:
            raise M.Incomplete(f"REFUSED: leave-one-out {group} table is not that group alone")
    if total.get("groups") != list(GROUPS):
        raise M.Incomplete("REFUSED: leave-one-out total is not the complete arm")
    def values(table):
        return {"U_above": exact(table["U"]["U_above"], "LOO U_above"),
                **{p: exact(table["BA"][p]["BA"], "LOO BA " + p) for p in PREDS}}
    f0, full = values(baseline), values(total)
    components = {group: values(table) for group, table in groups.items()}
    total_effect = {name: full[name] - f0[name] for name in f0}
    effects = {group: {name: value[name] - f0[name] for name in f0}
               for group, value in components.items()}
    residual = {name: total_effect[name] - sum(effect[name] for effect in effects.values()) for name in f0}
    def pack(mapping):
        return {name: M.ratio(value.numerator, value.denominator) for name, value in mapping.items()}
    return {"format": "r33-leave-one-out/1", "arm": arm,
            "F0": pack(f0), "total": pack(full),
            "groups": {group: pack(value) for group, value in components.items()},
            "total_effect_against_F0": pack(total_effect),
            "group_effects_against_F0": {group: pack(effect) for group, effect in effects.items()},
            "residual_total_effect_minus_group_effects": pack(residual)}


def read_judge(path, population):
    """Read a structured frozen-program receipt for judgment.

    printed_bounds() remains available to inspect raw stdout; text alone
    cannot identify the executable, choice or manifest which produced it.
    """
    raw = Path(path).read_text()
    if raw.lstrip().startswith("{"):
        receipt = json.loads(raw)
        if receipt.get("format") != "r33-judge-proof/1":
            raise M.Incomplete("REFUSED: unknown frozen-judge receipt")
        return receipt
    raise M.Incomplete("REFUSED: judgment requires the structured frozen-judge execution receipt; raw stdout is inspection only")


def table_from(path, subject=None, choice_sha256=None, require_choice=False):
    value = json.loads(Path(path).read_text())
    if choice_sha256 is not None:
        actual = value.get("choice_sha256")
        if (require_choice and actual != choice_sha256) or actual not in {None, choice_sha256}:
            raise M.Incomplete("REFUSED: input tables do not bind the posted choice")
    if "table" in value:
        value = value["table"]
    elif "tables" in value:
        value = value["tables"][subject]
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("step", choices=("confirmation", "standard-first", "leave-one-out"))
    parser.add_argument("--choice", type=Path)
    parser.add_argument("--subject")
    parser.add_argument("--table", type=Path)
    parser.add_argument("--judge-hcal", type=Path)
    parser.add_argument("--judge-union", type=Path)
    parser.add_argument("--identity", type=Path)
    parser.add_argument("--c-result", type=Path)
    parser.add_argument("--std-result", type=Path)
    parser.add_argument("--c-table", type=Path)
    parser.add_argument("--std-table", type=Path)
    parser.add_argument("--baseline-table", type=Path)
    parser.add_argument("--total-table", type=Path)
    for group in GROUPS:
        parser.add_argument("--" + group.lower() + "-table", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    digest = None
    try:
        choice, digest = M.choice_file(args.choice)
        paths = [args.choice]
        if args.step == "confirmation":
            if args.subject not in {choice["arm"], "STD-rel"}:
                raise M.Incomplete("REFUSED: judgment subject differs from posted choice/comparator")
            table = table_from(args.table, args.subject, digest, require_choice=True)
            paths.append(args.table)
            receipts = None
            proof = None
            # Do not even open a judge output if STD-rel's port criteria fail.
            port = port_confirmation(args.subject, table)
            plan = None
            if (args.subject != "STD-rel" or port["port_met"]) and args.judge_hcal and args.judge_union and args.identity:
                if args.subject == "STD-rel":
                    c_result = json.loads(args.c_result.read_text()) if args.c_result else None
                    if choice["arm"] != "STD-rel" and c_result is None:
                        raise M.Incomplete("REFUSED: STD-rel second build requires C's confirmation result")
                    if c_result is not None and c_result.get("choice_sha256") != digest:
                        raise M.Incomplete("REFUSED: C result does not bind posted choice")
                    if c_result is not None and c_result.get("subject") != choice["arm"]:
                        raise M.Incomplete("REFUSED: C result differs from posted choice")
                    c_table = table_from(args.c_table, choice["arm"], digest, require_choice=True) if args.c_table else None
                    plan = standard_first(c_result, port, c_table, table)
                    if not plan.get("second_build_allowed"):
                        raise M.Incomplete("REFUSED: standard-first does not permit STD-rel's second build/bound")
                    paths += [path for path in (args.c_result, args.c_table) if path]
                receipts = {name: read_judge(path, name) for name, path in
                            (("hcal", args.judge_hcal), ("union", args.judge_union))}
                proof = json.loads(args.identity.read_text())
                for receipt in receipts.values():
                    if receipt.get("choice_sha256") != digest:
                        raise M.Incomplete("REFUSED: judge output does not bind the posted choice")
                if proof.get("choice_sha256") != digest:
                    raise M.Incomplete("REFUSED: build identity is not bound to posted choice")
                paths += [args.judge_hcal, args.judge_union, args.identity]
            value = confirmation_judgment(args.subject, table, receipts, proof, plan)
        elif args.step == "standard-first":
            if choice["arm"].startswith("C_") and args.c_result is None:
                raise M.Incomplete("REFUSED: standard-first requires the posted C choice's confirmation result")
            c = json.loads(args.c_result.read_text()) if args.c_result else None
            std = json.loads(args.std_result.read_text())
            for judged in (c, std):
                if judged is not None and judged.get("choice_sha256") != digest:
                    raise M.Incomplete("REFUSED: confirmation result does not bind the posted choice")
            if c is not None and c.get("subject") != choice["arm"]:
                raise M.Incomplete("REFUSED: C result differs from posted choice")
            ct = table_from(args.c_table, choice["arm"], digest, require_choice=True) if args.c_table else None
            st = table_from(args.std_table, "STD-rel", digest, require_choice=True) if args.std_table else None
            paths += [path for path in (args.c_result, args.std_result, args.c_table, args.std_table) if path]
            value = standard_first(c, std, ct, st)
        else:
            group_paths = {group: getattr(args, group.lower() + "_table") for group in GROUPS}
            paths += [args.baseline_table, args.total_table, *group_paths.values()]
            value = leave_one_out(choice["arm"], table_from(args.baseline_table),
                table_from(args.total_table), {group: table_from(path) for group, path in group_paths.items()})
        value["input_sha256"] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        rc = 0
    except (M.Incomplete, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        value, rc = {"status": "REFUSED", "reason": str(error)}, 2
    output = json.dumps(M.envelope(value, digest), indent=2, sort_keys=True, allow_nan=False) + "\n"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(output)
    print(output, end="")
    return rc


if __name__ == "__main__":
    sys.exit(main())
