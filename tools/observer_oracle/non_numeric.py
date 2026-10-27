#!/usr/bin/env python3
"""Generate and grade the pre-registered #1992 non-numeric observer corpus."""

import argparse
import json
import random
import subprocess
import tempfile

W = 10
CHECKPOINTS = (W - 1, W, 2 * W, 5 * W)
SEED = 1992


def rotate(v, n):
    n %= len(v)
    return v[n:] + v[:n]


def value(kind, behaviour, variant, i, rng):
    width = 3 + variant
    base = list(range(1, width + 1))
    if behaviour == "unchanged":
        vals = base
    elif behaviour == "rotating":
        vals = rotate(base, i)
    elif behaviour == "swapped":
        vals = base[:]
        if i % 2:
            vals[0], vals[1] = vals[1], vals[0]
    elif behaviour == "growing":
        vals = list(range(1, i + width + 1))
    elif behaviour == "shrinking":
        vals = list(range(1, max(1, 61 - i - variant) + 1))
    elif behaviour == "permuted":
        vals = base[:]
        rng.shuffle(vals)
    elif behaviour == "then_unchanged":
        vals = rotate(base, i) if i < 16 + variant else base
    else:
        raise AssertionError(behaviour)

    if kind == "list":
        return vals
    if kind == "dict":
        return {chr(97 + j): vals[j] for j in range(len(vals))}
    if kind == "string":
        return "".join(chr(64 + n) for n in vals)
    if kind == "nested":
        return [[n, {"v": n}] for n in vals]
    raise AssertionError(kind)


def rows():
    # 4 value shapes x 12 generated trajectories = 48 rows. The asymmetric
    # grow/shrink cases keep n fixed while retaining two variants for every
    # equality/order-sensitive behaviour named in the pre-registration.
    plan = (("unchanged", 0), ("unchanged", 1),
            ("rotating", 0), ("rotating", 1),
            ("swapped", 0), ("swapped", 1),
            ("growing", 0), ("shrinking", 0),
            ("permuted", 0), ("permuted", 1),
            ("then_unchanged", 0), ("then_unchanged", 1))
    out = []
    for kind in ("list", "dict", "string", "nested"):
        for behaviour, variant in plan:
            row_seed = SEED + len(out)
            rng = random.Random(row_seed)
            values = [value(kind, behaviour, variant, i, rng) for i in range(51)]
            out.append({"id": f"{kind}-{behaviour}-{variant}", "kind": kind,
                        "behaviour": behaviour, "variant": variant,
                        "seed": row_seed, "values": values})
    # Aliasing controls: the observed name is deliberately rebound to the
    # same object after an in-place mutation.  A reference-retaining observer
    # mistakes every comparison for equality; a snapshotting observer sees
    # every step change.  These are generated here (rather than as a hand
    # written regression) so they remain part of the scored corpus.
    out.append({"id": "list-in-place-append", "kind": "list",
                "behaviour": "in_place_append", "variant": 0,
                "seed": SEED + len(out), "values": None})
    out.append({"id": "list-in-place-set-at", "kind": "list",
                "behaviour": "in_place_set_at", "variant": 0,
                "seed": SEED + len(out), "values": None})
    return out


def eigs(v):
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "[" + ", ".join(eigs(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{json.dumps(k)}: {eigs(x)}" for k, x in v.items()) + "}"
    return str(v)


def label(values, at):
    return at >= W and all(values[i] == values[i - 1] for i in range(at - W + 1, at + 1))


def program(corpus):
    out = []
    for number, row in enumerate(corpus):
        name = f"row_{number}"
        if row["behaviour"].startswith("in_place_"):
            out += [f"define {name} as:", "    xs is [0]", "    k is 0"]
            for i in range(51):
                if row["behaviour"] == "in_place_append":
                    out.append("    append of [xs, k]")
                else:
                    out.append("    set_at of [xs, 0, k]")
                out += ["    xs is xs", "    k is k + 1"]
                if i in CHECKPOINTS:
                    out.append(
                        f'    print of f"R {row["id"]} {row["seed"]} {i} false '
                        f'{{converged of xs}} {{stable of xs}} false"')
            out += ["    return 0", f"done_{number} is {name} of 0"]
            continue
        out += [f"define {name} as:", f"    x is {eigs(row['values'][0])}",
                "    prev is x", "    same is 0"]
        for i, v in enumerate(row["values"]):
            if i:
                out += [f"    x is {eigs(v)}", "    if x == prev:",
                        "        same is same + 1", "    else:",
                        "        same is 0", "    prev is x"]
            if i in CHECKPOINTS:
                expected = str(label(row["values"], i)).lower()
                out.append(
                    f'    print of f"R {row["id"]} {row["seed"]} {i} {expected} '
                    f'{{converged of x}} {{stable of x}} {{({i} >= {W}) and (same >= {W})}}"')
        out += ["    return 0", f"done_{number} is {name} of 0"]
    return "\n".join(out) + "\n"


def ratio(a, b):
    return a / b if b else 0.0


def score(lines, corpus):
    readings = []
    for line in lines.splitlines():
        fields = line.split()
        if fields and fields[0] == "R" and len(fields) == 8:
            _, rid, seed, at, expected, conv, stable, std = fields
            readings.append((rid, int(seed), int(at), expected == "true",
                             conv == "true", stable == "true", std == "true"))
    wanted = len(corpus) * len(CHECKPOINTS)
    if len(readings) != wanted:
        raise SystemExit(f"instrument error: got {len(readings)} readings, expected {wanted}")

    table = []
    for pred, index in (("converged", 4), ("stable", 5)):
        for arm, arm_index in (("INC", index), ("STD-EQ", 6), ("C0", None)):
            scored = [r for r in readings if r[2] >= W]
            tp = sum(r[3] and (False if arm_index is None else r[arm_index]) for r in scored)
            fn = sum(r[3] and not (False if arm_index is None else r[arm_index]) for r in scored)
            fp = sum(not r[3] and (False if arm_index is None else r[arm_index]) for r in scored)
            tn = sum(not r[3] and not (False if arm_index is None else r[arm_index]) for r in scored)
            tpr, fpr = ratio(tp, tp + fn), ratio(fp, fp + tn)
            table.append((pred, arm, tp, fn, fp, tn, tpr, fpr, (tpr + 1.0 - fpr) / 2.0))
    return readings, table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--emit", help="write the generated .eigs program")
    args = parser.parse_args()
    corpus = rows()
    source = program(corpus)
    if args.emit:
        with open(args.emit, "w") as f:
            f.write(source)
    with tempfile.NamedTemporaryFile("w", suffix=".eigs") as f:
        f.write(source)
        f.flush()
        run = subprocess.run([args.binary, f.name], text=True, capture_output=True, timeout=120)
    if run.returncode:
        raise SystemExit(f"binary exited {run.returncode}:\n{run.stdout}{run.stderr}")
    readings, table = score(run.stdout, corpus)
    print(f"corpus rows={len(corpus)} checkpoints={len(readings)} seed={SEED}")
    print("predicate arm tp fn fp tn tpr fpr ba")
    for p, a, tp, fn, fp, tn, tpr, fpr, ba in table:
        print(f"{p} {a} {tp} {fn} {fp} {tn} {tpr:.3f} {fpr:.3f} {ba:.3f}")
    std = [r for r in table if r[1] == "STD-EQ"]
    if not all(r[6] == 1.0 and r[7] == 0.0 for r in std):
        raise SystemExit("INSTRUMENT INVALID: STD-EQ failed the pre-registered validity rule")
    inc = {r[0]: r for r in table if r[1] == "INC"}
    win = any(inc[r[0]][8] < r[8] for r in std)
    fixed = all(inc[r[0]][8] == r[8] == 1.0 and inc[r[0]][7] == 0.0 for r in std)
    print("verdict=" + ("STD-EQ wins; runtime change required" if win else
                         "INC matches STD-EQ" if fixed else "INC retained"))
    if not (win or fixed):
        raise SystemExit("pre-registered decision unexpectedly retained a weaker incumbent")


if __name__ == "__main__":
    main()
