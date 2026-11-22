#!/usr/bin/env python3
"""Build the frozen answers of #2407 from the Round 3 reveal's raw log.

usage: reveal_restored_table.py [--raw PATH] [--write PATH | --check PATH]

The reveal (#1758, tag phase2-r3-reveal, reveal-r3/result/raw.json) decided by
RULING R30R-2 that `converged` and `stable` keep the incumbent's test and
`improving`, `oscillating`, `diverging` and `equilibrium` ship Round 3's. The
table holds what the branch's build must answer after that decision, by this
rule (#2407, "The frozen answers"):

- improving, oscillating, diverging, equilibrium: the answer of the arm R3;
- converged and stable, on a reading the arm INC has: INC's answer, except
  const_1e308_literal@30, which is true for both (1e308 is a finite number,
  decided in Phase 2 before Round 3);
- converged and stable on the 21 readings INC does not have (it cannot read
  64-bit integers or IEEE values): true at ieee_inf_recover@45 and
  ieee_nan_recover@45, false at the other nineteen, listed in NO_INC below.

Without --raw the log is read from the tag with `git show`. A log whose
sha256 is not RAW_SHA256 is refused. --write writes the table; --check
compares a committed table byte for byte with the one built and exits 1 on
any difference. Exit 2 on an unusable input.
"""
import hashlib
import json
import os
import subprocess
import sys

RAW_SHA256 = "a080bfba8b650418971bbe7926dbca40bc352b0df84e4720c5e042a141196d09"
RAW_AT_TAG = "phase2-r3-reveal:reveal-r3/result/raw.json"
PREDS = ("converged", "stable", "improving", "oscillating", "diverging", "equilibrium")
RESTORED = ("converged", "stable")
POPULATIONS = {"H1": 738, "calibration": 118, "hcal": 96}
NO_INC_TRUE = {("calibration", "ieee_inf_recover@45"), ("calibration", "ieee_nan_recover@45")}
NO_INC = NO_INC_TRUE | {("calibration", k) for k in (
    "geo_growth_1e20@40", "ieee_inf@5", "ieee_inf@30", "ieee_inf_alternating@20", "ieee_inf_alternating@41",
    "ieee_inf_recover@2", "ieee_nan@3", "ieee_nan@30", "ieee_nan_recover@3", "ieee_nan_recover@7",
    "ieee_nan_recover@13", "ieee_neg_inf@5", "ieee_neg_inf@30", "int64_count@10", "int64_count@60",
    "int64_swing@60")} | {("H1", k) for k in ("f14_7@10", "f14_7@60", "f14_7@200")}
FINITE_1E308 = ("calibration", "const_1e308_literal@30")


class Refused(Exception):
    pass


def load_raw(path):
    if path is None:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        p = subprocess.run(["git", "-C", root, "show", RAW_AT_TAG], capture_output=True)
        if p.returncode != 0:
            raise Refused(f"git show {RAW_AT_TAG} failed (is the tag fetched?): {p.stderr.decode().strip()}")
        data = p.stdout
    else:
        with open(path, "rb") as f:
            data = f.read()
    got = hashlib.sha256(data).hexdigest()
    if got != RAW_SHA256:
        raise Refused(f"raw.json sha256 {got} is not the reveal's {RAW_SHA256}")
    return json.loads(data)


def arm_readings(pop, arm):
    """{row@checkpoint: {predicate: answer}} of one arm; a doubled reading is refused."""
    out = {}
    for a, rid, at, p, v in pop["readings"]:
        if a != arm:
            continue
        cell = out.setdefault(f"{rid}@{at}", {})
        if p in cell or p not in PREDS or not isinstance(v, bool):
            raise Refused(f"{arm} {rid}@{at} {p}: a doubled or malformed reading")
        cell[p] = v
    for k, cell in out.items():
        if set(cell) != set(PREDS):
            raise Refused(f"{arm} {k}: has {sorted(cell)}, not the six predicates")
    return out


def build(raw):
    pops = raw.get("populations", {})
    if set(pops) != set(POPULATIONS):
        raise Refused(f"populations {sorted(pops)}, not {sorted(POPULATIONS)}")
    table, absent = {}, set()
    for name, want in POPULATIONS.items():
        r3, inc = arm_readings(pops[name], "R3"), arm_readings(pops[name], "INC")
        if len(r3) != want or not set(inc) <= set(r3):
            raise Refused(f"{name}: R3 has {len(r3)} readings (want {want}); INC's must be among them")
        out = {}
        for k, cell in r3.items():
            row = {p: cell[p] for p in PREDS if p not in RESTORED}
            if k in inc:
                row.update({p: inc[k][p] for p in RESTORED})
                if (name, k) == FINITE_1E308:
                    if any(inc[k][p] for p in RESTORED):
                        raise Refused(f"{k}: INC was expected to refuse 1e308 (false for both)")
                    row.update({p: True for p in RESTORED})
            else:
                absent.add((name, k))
                row.update({p: (name, k) in NO_INC_TRUE for p in RESTORED})
            out[k] = row
        table[name] = out
    if absent != NO_INC:
        raise Refused(f"readings INC lacks: {sorted(absent ^ NO_INC)} differ from the rule's 21")
    return {"format": "reveal-r3-restored-1", "populations": table, "raw_sha256": RAW_SHA256}


def dump(table):
    return (json.dumps(table, sort_keys=True, separators=(",", ":")) + "\n").encode()


def main(argv):
    args = argv[1:]
    opts = {}
    while args:
        flag = args.pop(0)
        if flag not in ("--raw", "--write", "--check") or not args or flag in opts:
            print(__doc__, file=sys.stderr)
            return 2
        opts[flag] = args.pop(0)
    if "--write" in opts and "--check" in opts:
        print("give --write or --check, not both", file=sys.stderr)
        return 2
    try:
        data = dump(build(load_raw(opts.get("--raw"))))
    except (Refused, OSError, ValueError) as e:
        print(f"REVEAL_TABLE_ERROR: {e}", file=sys.stderr)
        return 2
    print(f"table: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
    if "--write" in opts:
        with open(opts["--write"], "wb") as f:
            f.write(data)
        print(f"written: {opts['--write']}")
    if "--check" in opts:
        try:
            with open(opts["--check"], "rb") as f:
                committed = f.read()
        except OSError as e:
            print(f"REVEAL_TABLE_ERROR: {e}", file=sys.stderr)
            return 2
        if committed != data:
            print(f"TABLE DIFFERS: {opts['--check']} ({len(committed)} bytes, sha256"
                  f" {hashlib.sha256(committed).hexdigest()}) is not what the rule builds from raw.json")
            return 1
        print(f"table check: {opts['--check']} equals the table the rule builds")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
