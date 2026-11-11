#!/usr/bin/env python3
"""R33-1 point metrics on explicit readings; no classifier execution or bootstrap.

Readings use keys (set, row, checkpoint), with six boolean predicate values.
Set names distinguish population and scale, e.g. cal/x1 and hcal/x1e6.
Expected keys and comparison masks are supplied from the pinned populations,
never inferred from whichever readings happened to arrive.
"""
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import random
import re

from schema import PREDS
from r33_port import POLICIES


class Incomplete(ValueError):
    pass


class ControlFailure(Incomplete):
    pass


def nonempty(items, context):
    if not items:
        raise Incomplete(f"INCOMPLETE: empty {context}")
    return items


def vector(reading):
    if any(p not in reading or type(reading[p]) is not bool for p in PREDS):
        raise Incomplete("INCOMPLETE: reading needs all six boolean predicates")
    return tuple(reading[p] for p in PREDS)


def require_keys(got, expected, context):
    expected = set(nonempty(expected, f"declared keys for {context}"))
    actual = set(got)
    missing, extra = expected - actual, actual - expected
    if missing or extra:
        raise Incomplete(f"INCOMPLETE: {context}: missing={len(missing)} extra={len(extra)}; "
                         f"first_missing={min(missing) if missing else None!r}; "
                         f"first_extra={min(extra) if extra else None!r}")


def index(records):
    """Reject duplicate/malformed readings, including non-boolean predicates."""
    result = {}
    for row in records:
        if (not isinstance(row, dict) or not isinstance(row.get("set"), str)
                or not isinstance(row.get("row"), str) or type(row.get("at")) is not int
                or row["at"] < 0 or not isinstance(row.get("predicates"), dict)):
            raise Incomplete("INCOMPLETE: malformed reading record")
        key = row["set"], row["row"], row["at"]
        if key in result:
            raise Incomplete(f"INCOMPLETE: duplicate reading {key!r}")
        vector(row["predicates"])
        result[key] = row["predicates"]
    return nonempty(result, "reading population")


def ratio(numerator, denominator):
    if denominator <= 0:
        raise Incomplete("INCOMPLETE: empty comparison denominator")
    f = Fraction(numerator, denominator)
    return {"numerator": numerator, "denominator": denominator,
            "exact": str(f), "value": float(f)}


def fraction(result):
    return Fraction(result["numerator"], result["denominator"])


def unit(readings, comparisons, allow_empty=False):
    """One flip per unequal vector; each comparison is (left_key,right_key,above).

    A mask applies to the entire declared comparison, not to individual
    predicate bits. Keep each vector for every unequal comparison.
    """
    if not allow_empty:
        nonempty(comparisons, "unit comparisons")
    seen, details = set(), []
    per_row, per_scale = {}, {}
    total = above_total = flips = above_flips = 0
    per_predicate = {p: 0 for p in PREDS}
    for left, right, above in comparisons:
        if type(above) is not bool:
            raise Incomplete("INCOMPLETE: comparison mask must be boolean")
        if (left, right) in seen:
            raise Incomplete(f"INCOMPLETE: duplicate unit comparison {(left, right)!r}")
        seen.add((left, right))
        if left not in readings or right not in readings:
            raise Incomplete(f"INCOMPLETE: missing comparison reading {left!r} or {right!r}")
        a, b = vector(readings[left]), vector(readings[right])
        changed = a != b
        total += 1
        flips += changed
        above_total += above
        above_flips += changed and above
        for groups, name in ((per_row, left[0].split("/")[0] + "/" + left[1]),
                             (per_scale, right[0])):
            cell = groups.setdefault(name, {"comparisons": 0, "flips": 0,
                                           "above_comparisons": 0, "above_flips": 0})
            cell["comparisons"] += 1
            cell["flips"] += changed
            cell["above_comparisons"] += above
            cell["above_flips"] += changed and above
        for p, x, y in zip(PREDS, a, b):
            per_predicate[p] += x != y
        details.append({"left": list(left), "right": list(right), "above": above,
                        "flip": changed, **({"left_vector": a, "right_vector": b} if changed else {})})
    if not allow_empty:
        nonempty(above_total, "above-floor unit comparisons")
    for groups in (per_row, per_scale):
        for cell in groups.values():
            cell["U_all"] = ratio(cell["flips"], cell["comparisons"])
            cell["U_above"] = (ratio(cell["above_flips"], cell["above_comparisons"])
                                 if cell["above_comparisons"] else None)
            cell["above_status"] = "COMPLETE" if cell["above_comparisons"] else "INCOMPLETE: no above-floor comparisons"
    return {"status": "COMPLETE" if total and above_total else "INCOMPLETE: empty unit comparison denominator",
            "U_all": ratio(flips, total) if total else None,
            "U_above": ratio(above_flips, above_total) if above_total else None,
            "per_predicate_flips": per_predicate, "per_row": per_row,
            "per_scale": per_scale, "comparisons": details}


def balanced(readings, labelled):
    """Exact BA points only. labelled maps reading keys to frozen label objects."""
    nonempty(labelled, "BA labels")
    result = {}
    for p in PREDS:
        tp = fp = fn = tn = reported = 0
        for key, label in labelled.items():
            if key not in readings:
                raise Incomplete(f"INCOMPLETE: missing BA reading {key!r}")
            vector(readings[key])
            if label[p][0] == "REPORTED":
                reported += 1
                continue
            truth, got = label[p][1], readings[key][p]
            if type(truth) is not bool:
                raise Incomplete(f"INCOMPLETE: non-boolean BA label {key!r} {p}")
            tp += truth and got
            fp += not truth and got
            fn += truth and not got
            tn += not truth and not got
        ba = None if tp + fn == 0 or tn + fp == 0 else (Fraction(tp, tp + fn) + Fraction(tn, tn + fp)) / 2
        result[p] = {"TP": tp, "FP": fp, "FN": fn, "TN": tn, "reported": reported,
                     "BA": None if ba is None else ratio(ba.numerator, ba.denominator),
                     "raw": None if tp + fp + fn + tn == 0 else ratio(tp + tn, tp + fp + fn + tn),
                     "FPR": None if fp + tn == 0 else ratio(fp, fp + tn)}
    return result


def zeros(readings, keys):
    nonempty(keys, "Z readings")
    if len(set(keys)) != len(keys):
        raise Incomplete("INCOMPLETE: duplicate Z key")
    hits = []
    for key in keys:
        if key not in readings:
            raise Incomplete(f"INCOMPLETE: missing Z reading {key!r}")
        vector(readings[key])
        hits.append({"key": list(key), "converged": readings[key]["converged"]})
    return {"Z": ratio(sum(r["converged"] for r in hits), len(hits)), "readings": hits}


def counter(readings, keys):
    """K's three bits, on the two keys of the canonical typed int64_count."""
    if (len(keys) != 2 or {k[1] for k in keys} != {"int64_count"}
            or {k[2] for k in keys} != {10, 60}):
        raise Incomplete("INCOMPLETE: K needs typed int64_count checkpoints 10 and 60")
    hits = []
    for key in keys:
        if key not in readings:
            raise Incomplete(f"INCOMPLETE: missing K reading {key!r}")
        vector(readings[key])
        for p, expected in (("converged", False), ("stable", False), ("diverging", True)):
            got = readings[key][p]
            hits.append({"key": list(key), "predicate": p, "expected": expected, "got": got, "correct": got == expected})
    return {"K": ratio(sum(r["correct"] for r in hits), 6), "readings": hits,
            "role": "untouched exact-path check; identical rule for every policy"}


def choose(tables):
    """Calibration step 1: BA >= F0-.01, Z=1, min U_above/f/win-before-hist."""
    if "F0" not in tables:
        raise Incomplete("INCOMPLETE: calibration choice lacks F0")
    require_positive_control(tables)
    candidates = []
    for arm, table in tables.items():
        if not arm.startswith("C_"):
            continue
        feasible = fraction(table["Z"]["Z"]) == 1
        for p in PREDS:
            ours, baseline = table["BA"][p]["BA"], tables["F0"]["BA"][p]["BA"]
            if ours is None or baseline is None:
                raise Incomplete(f"INCOMPLETE: undefined required calibration BA for {arm}/{p}")
            feasible &= fraction(ours) >= fraction(baseline) - Fraction(1, 100)
        if feasible:
            f, mode = arm[2:].split("^")
            candidates.append((fraction(table["U"]["U_above"]), Fraction(f), mode != "win", arm))
    return min(candidates)[-1] if candidates else None


def require_positive_control(tables):
    """A failed registered positive control yields no calibration choice."""
    try:
        result = tables["PRE1045"]["U"]["U_above"]
        effect = fraction(result)
    except (KeyError, TypeError, ZeroDivisionError) as exc:
        raise Incomplete("INCOMPLETE: positive control PRE1045 U_above is missing or undefined") from exc
    if effect < Fraction(1, 10):
        raise ControlFailure(f"VOID: PRE1045 U_above={effect} is below 0.10; no calibration choice")
    return result


def arm_order():
    arms = list(POLICIES)
    random.Random(1580).shuffle(arms)
    return arms


def first_measurement_file(path):
    """Pin the bytes supplied as the posted first measurement; posting is human.

    No table or verdict is inferred here: this is the item14-style order
    witness required by addendum3 1(b), not a replacement control test.
    """
    if path is None:
        raise Incomplete("REFUSED: this arm requires posted first measurement file")
    raw = Path(path).read_bytes()
    if not raw:
        raise Incomplete("REFUSED: posted first measurement file is empty")
    return hashlib.sha256(raw).hexdigest()


def choice_file(path):
    """Bind confirmation to the bytes of the posted choice, without claiming
    to prove that a person posted them. Extra posting metadata is retained.
    """
    if path is None:
        raise Incomplete("REFUSED: confirmation requires posted choice file")
    raw = Path(path).read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    try:
        choice = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise Incomplete("REFUSED: invalid posted choice JSON") from exc
    if (not isinstance(choice, dict) or choice.get("arm") not in POLICIES
            or not (choice["arm"].startswith("C_") or choice["arm"] == "STD-rel")
            or not isinstance(choice.get("sweep_tables_sha256"), str)
            or re.fullmatch(r"[0-9a-f]{64}", choice["sweep_tables_sha256"]) is None):
        raise Incomplete("REFUSED: posted choice needs provisional C/STD-rel arm and sweep_tables_sha256")
    return choice, digest


def envelope(value, choice_sha256=None):
    return {"choice_sha256": choice_sha256, **value}
