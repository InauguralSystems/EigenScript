#!/usr/bin/env python3
"""Does a build answer the reveal's frozen table? (#2407)

usage: reveal_restored_check.py BINARY [--table PATH]

The Round 3 reveal (#1758, RULING R30R-2) decided which tests ship; the
answers a build must give after that decision are frozen in
tests/phase2/reveal_restored_expected.json (built from the reveal's raw log by
tools/reveal_restored_table.py). This takes every reading of the three sets
(tools/observer_oracle/corpus.json, tools/observer_oracle/hcal/corpus.json,
tests/phase2/reveal_h1/corpus.json, whose sha256 is checked before it is read)
with score.py's `measure` in its four execution tiers (interp/straight,
interp/loop, jit/loop, osr/loop) and compares each with the table.

It prints, for each population and predicate, how many readings it compared
and how many differ, then each differing key. Exit 0 only when the keys of
each population are exactly the table's (a missing, an extra or a doubled key
fails), the four tiers agree on every reading, and no answer differs; exit 1
otherwise; exit 2 on a harness error (score.py's, a VACUOUS JIT run among
them, or an unusable table or corpus).
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import derive                                   # noqa: E402
import score                                    # noqa: E402
from gen import HarnessError                    # noqa: E402
from schema import PREDS                        # noqa: E402

TABLE = os.path.join(ROOT, "tests", "phase2", "reveal_restored_expected.json")
CORPORA = (("calibration", os.path.join(HERE, "corpus.json"), None),
           ("hcal", os.path.join(HERE, "hcal", "corpus.json"), None),
           ("H1", os.path.join(ROOT, "tests", "phase2", "reveal_h1", "corpus.json"),
            "85be07d96390ad23f583d640be4fe46fa7a1d4affde37e82bf7125535e016cff"))
TIERS = tuple(f"{t}/{f}" for t, f in score.ARMS)


def _no_doubles(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise HarnessError(f"the table holds the key {k!r} twice")
        out[k] = v
    return out


def load_table(path):
    try:
        with open(path) as f:
            t = json.load(f, object_pairs_hook=_no_doubles)
    except (OSError, ValueError) as e:
        raise HarnessError(f"cannot load the table {path}: {e}")
    pops = t.get("populations") if isinstance(t, dict) else None
    if t.get("format") != "reveal-r3-restored-1" or not isinstance(pops, dict) \
            or set(pops) != {name for name, _, _ in CORPORA}:
        raise HarnessError(f"{path}: not a reveal-r3-restored-1 table of {[n for n, _, _ in CORPORA]}")
    for name, cells in pops.items():
        for k, cell in cells.items():
            if set(cell) != set(PREDS) or not all(isinstance(v, bool) for v in cell.values()):
                raise HarnessError(f"{path}: {name} {k} does not hold the six predicates as true or false")
    return pops


def load(path, sha):
    if sha is not None:
        with open(path, "rb") as f:
            got = hashlib.sha256(f.read()).hexdigest()
        if got != sha:
            raise HarnessError(f"{path}: sha256 {got} is not {sha} (the set as the reveal's tag has it)")
    return derive.load_corpus(path)


def readings(res):
    """{row@checkpoint: {predicate: {tier: answer}}} from one measure()."""
    out = {}
    for (tier, form, rid, at, p), got in res["read"].items():
        out.setdefault(f"{rid}@{at}", {}).setdefault(p, {})[f"{tier}/{form}"] = got
    return out


def main(argv):
    args = argv[1:]
    table_path = TABLE
    if "--table" in args:
        i = args.index("--table")
        if i + 1 >= len(args):
            raise HarnessError("--table needs a path")
        table_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        raise HarnessError("usage: reveal_restored_check.py BINARY [--table PATH]")
    binary = os.path.abspath(args[0])
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise HarnessError(f"binary not found or not executable: {binary}")
    table = load_table(table_path)
    _, caps, _ = score.capabilities(binary)
    print(f"reveal restored check: {binary}, table {table_path}, capabilities"
          f" {','.join(c for c in sorted(caps) if caps[c]) or 'none'}")
    fail, lines = 0, []
    for name, path, sha in CORPORA:
        corpus = load(path, sha)
        res = score.measure(binary, corpus, caps)
        score.check_witnessed(res)
        got, want = readings(res), table[name]
        missing, extra = sorted(set(want) - set(got)), sorted(set(got) - set(want))
        print(f"population {name}: {len(got)} readings measured, the table holds {len(want)};"
              f" missing {len(missing)}, extra {len(extra)}; {res['runs']} runs, skipped"
              f" {[f'{r} ({c})' for r, c in res['skipped']] or 'none'}")
        for k in missing:
            lines.append(f"  MISSING {name} {k}")
        for k in extra:
            lines.append(f"  EXTRA {name} {k}")
        fail |= bool(missing or extra)
        for p in PREDS:
            compared = differ = 0
            for k in sorted(set(want) & set(got)):
                tiers = got[k].get(p, {})
                if set(tiers) != set(TIERS):
                    lines.append(f"  TIERS MISSING {name} {k} {p}: read in {sorted(tiers)}")
                    fail = 1
                    continue
                answers = set(tiers.values())
                if len(answers) != 1:
                    lines.append(f"  TIERS DISAGREE {name} {k} {p}: "
                                 + " ".join(f"{t}={str(tiers[t]).lower()}" for t in TIERS))
                    fail = 1
                    continue
                compared += 1
                if answers != {want[k][p]}:
                    differ += 1
                    lines.append(f"  DIFFERS {name} {k} {p}: table={str(want[k][p]).lower()}"
                                 f" build={str(answers.pop()).lower()}")
            fail |= bool(differ)
            print(f"  {name} {p}: compared {compared}, differ {differ}")
    for line in lines:
        print(line)
    print(f"reveal restored check exit {fail}: " + ("FAIL" if fail else "the build answers the table"))
    return fail


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except HarnessError as e:
        print(f"REVEAL_RESTORED_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:          # an instrument crash is never a verdict
        print(f"REVEAL_RESTORED_ERROR: internal {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
