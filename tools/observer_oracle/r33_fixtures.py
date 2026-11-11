#!/usr/bin/env python3
"""R33-1 item 1: fixed identity inputs, never a labelled experiment arm.

The roster is design (d), seed 0x158033, Python 3.12.3. Nothing is drawn
from families.py. All 512 inputs and all four anchors have 32 readings.
"""
import hashlib
import json
import math
from pathlib import Path
import random
import sys

SEED = 0x158033
PATTERNS = [[0.0, math.inf, math.inf, 1.0],
            [0.0, -math.inf, math.inf, -math.inf],
            [1.0, math.nan, math.nan, 2.0],
            [math.inf, 1.0, 1.0, 1.0]]


def typed(v):
    return {"kind": "int", "value": str(v)} if type(v) is int else {"kind": "float", "value": v.hex()}


def untyped(v):
    return int(v["value"]) if v["kind"] == "int" else float.fromhex(v["value"])


def fixtures():
    if sys.version_info[:3] != (3, 12, 3):
        raise RuntimeError("R33 identity generation requires Python 3.12.3")
    for j in range(1, 9):
        for k in range(64):
            digest = hashlib.sha256(f"R33/identity/{SEED}/{j}/{k}".encode()).digest()
            rng = random.Random(int.from_bytes(digest[:8], "big"))
            if j == 1:
                c = rng.choice([0.0, -0.0, 1.0, -1.0, 1e-160, 1e-6, 1e6, 1e308])
                xs = [(-0.0 if i % 2 else 0.0) if c == 0 and k % 2 else c for i in range(30)]
            elif j == 2:
                c = rng.choice([0.0, 1.0, -1.0, 1e6, 2.0**50])
                d = rng.choice([-2.0, -1.0, -1e-6, 1e-6, 1.0, 2.0])
                xs = [c]
                for _ in range(29):
                    xs.append(xs[-1] + d)
            elif j == 3:
                limit = rng.choice([0.0, 1.0, -5.0])
                error = rng.choice([1.0, -1.0, 1e-6])
                r = rng.choice([0.3, 0.5, 0.9, 0.99, -0.5, -0.9])
                xs = []
                for _ in range(30):
                    xs.append(limit + error)
                    error = error * r
            elif j == 4:
                cycle = rng.choice([[1.0, -1.0], [0.0, 1.0, 0.0, -1.0], [1.0, 1.0, 2.0]])
                offset = rng.randrange(len(cycle))
                xs = [cycle[offset] if k % 2 and 11 <= i <= 20 else cycle[(i + offset) % len(cycle)]
                      for i in range(30)]
            elif j == 5:
                c = rng.choice([2**47-1, 2**47, 2**53, 2**63-33, -2**63+32])
                d = rng.choice([-1, 1])
                xs = [(-2**63 if i % 2 == 0 else 2**63-1) if k % 4 == 0 else c + i*d
                      for i in range(30)]
            elif j == 6:
                c = rng.choice([0, 2**47, 2**53])
                xs = [float(c+i) if i % 11 == k % 11 else c+i for i in range(30)]
            elif j == 7:
                pattern = rng.choice(PATTERNS)
                xs = [pattern[i] if i < 3 else pattern[3] for i in range(30)]
            else:
                e = rng.choice([-1074, -1022, -500, -1, 0, 1, 50, 52, 53, 500, 1023])
                toward = rng.choice([-math.inf, math.inf])
                q = rng.choice([1, 2, 3, 4])
                xs = [math.ldexp(1.0, e)]
                for _ in range(29):
                    x = xs[-1]
                    for _ in range(q):
                        x = math.nextafter(x, toward)
                    xs.append(x)
                if k % 2:
                    xs.reverse()
            prefix = float(1000000 + 64*(j-1) + k)
            yield {"id": f"seeded-{j}-{k:02}", "seed": SEED, "stratum": j, "draw": k,
                   "python": "3.12.3", "values": [typed(v) for v in [prefix, -prefix] + xs],
                   "checkpoints": list(range(32))}
    for k, pattern in enumerate(PATTERNS):
        yield {"id": f"ieee-anchor-{k}", "python": "3.12.3",
               "values": [typed(pattern[i] if i < 3 else pattern[3]) for i in range(32)],
               "checkpoints": list(range(32))}


def literal(v):
    if type(v) is int:
        return "(-9223372036854775807 - 1)" if v == -2**63 else str(v)
    if math.isnan(v):
        return "(0.0 / 0.0)"
    if math.isinf(v):
        return "(1.0 / 0.0)" if v > 0 else "(-1.0 / 0.0)"
    return repr(v)


def emit(row):
    """Direct typed assignments; every index, scalar/kind/count and six bits."""
    preds = ("converged", "stable", "improving", "oscillating", "diverging", "equilibrium")
    out = []
    values = [untyped(value) for value in row["values"]]
    for i, value in enumerate(values):
        out.append(f"x is {literal(value)}")
        bits = " ".join("{" + p + " of x}" for p in preds)
        why_kind = "{num_type of (why is x)}" if i else "null"
        where_sign = "{(atan2 of [(where is x), -1.0]) < 0.0}" if type(value) is float and value == 0.0 else "false"
        raw = None
        if i:
            previous = values[i-1]
            exact = type(value) is int and type(previous) is int and -2**63 <= value-previous < 2**63
            raw = value-previous if exact else float(value)-float(previous)
        why_sign = "{(atan2 of [(why is x), -1.0]) < 0.0}" if type(raw) is float and raw == 0.0 else "false"
        out.append(f'print of f"I {row["id"]} {i} {bits} {{report of x}} '
                   f'{{where is x}} {{num_type of x}} {{why is x}} {why_kind} {{how is x}} {{when is x}} '
                   f'{where_sign} {why_sign}"')
    out.append(f'print of "DONE {row["id"]}"')
    return "\n".join(out) + "\n"


def write(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    rows = list(fixtures())
    assert len(rows) == 516 and len({r["values"][0]["value"] for r in rows[:512]}) == 512
    for name, selected in (("seeded.jsonl", rows[:512]), ("anchors.jsonl", rows[512:])):
        (destination / name).write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in selected))
    programs = destination / "programs"
    programs.mkdir(exist_ok=True)
    for row in rows:
        (programs / (row["id"] + ".eigs")).write_text(emit(row))
    print("IDENTITY INPUTS: seeded=512 anchors=4 observations=16512; no subject run")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: r33_fixtures.py DESTINATION")
    write(sys.argv[1])
