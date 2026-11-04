#!/usr/bin/env python3
"""Round 3's judge (#1758 pre-registration, comments 6430031838 + 6430139845;
RULINGS R30-1..R30-4): every arm scored per predicate by balanced accuracy
with a PAIRED cluster bootstrap over rows, and the six decision rules
evaluated mechanically.

usage: judge.py --selftest                    control (b) on hcal/ against the anchor (tools/selftests.txt)
       judge.py --calibration [options]       corpus.json + hcal/, arms INC = src/eigenscript
                                              and ANCHOR = the build_anchor.sh binary
       judge.py --corpus DIR [--corpus DIR ...] [options]
options: --arm NAME=BINARY      a runtime arm (repeatable)
         --const-false NAME=BINARY   the arm BINARY with every reading rewritten false
                                (plants.py's const_false shim): control (b)
         --subject NAME         evaluate decision rules 1-6 for this arm
         --diff A,B             print BA(A) - BA(B) with its paired CI (repeatable)
         --seed N               run-order and bootstrap seed (default 1758; printed)
         --resamples N          (default 10000)
         --floor-exit RC --declarations FILE   rule 6's inputs (else NOT EVALUATED)

Execution and labels are score.py's (measure, verdicts' label gate,
findings, the tier witness), run one (arm, row) at a time in an order
shuffled from the seed. A runtime arm's reading is its interp/straight
reading; a split between its four execution tiers is a FINDING (exit 1).
The python arms are standard.py's. The population is every row that every
runtime arm ran (a capability skip removes the row from every arm, so the
bootstrap stays paired). Exit 0 when the table printed, 1 on a FINDING, 2 on
a harness error.
"""
import hashlib
import json
import math
import operator
import os
import random
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))     # python3 -I drops the script's directory
import derive
import score
import standard as S
from gen import HarnessError, generate
from schema import PREDS

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
# The instrument is frozen against these files (Deviations D3, D4; docs/PREDICATES.md; the posted generator).
FROZEN = {"corpus.json": "e3f5e94e97bd28972480977a5ff21173221e878ab784abc7f4ed5459bedfefe4",
          "reference.py": "fa74d83f23422f5ddee9b30dc0f133417f98d9d8e7f9806151233d9e18ca1993",
          "families.py": "69914f3fc5d1f116e5d53fff985eac2ab72f277a2733d89c4c166cc4bcea908a",
          "hcal/corpus.json": "87c19486679b1a7664f007504d05a33b56a3e522857f1000f3a8d2966a9986ab"}
ORDER = ("oscillating", "diverging", "improving", "converged", "equilibrium", "stable")   # report's priority
CELL = {(True, True): 0, (False, True): 1, (True, False): 2, (False, False): 3}        # (label, got) -> TP FP FN TN


def load(d):
    corpus = derive.load_corpus(os.path.join(d, "corpus.json"))
    certs = derive.load_certificates(corpus, os.path.join(d, "certificate.json"))
    return corpus, score.load_labels(corpus, certs, os.path.join(d, "labels.json"))


def const_false(real):
    tmp = tempfile.mkdtemp(prefix="judge_cf_")
    shutil.copytree(HERE, os.path.join(tmp, "o"), ignore=shutil.ignore_patterns("__pycache__"))
    import plants
    return plants.shim(os.path.join(tmp, "o"), "const_false", os.path.abspath(real)), tmp


def run_arms(binaries, rows, seed):
    """{arm: {rid: {(at, p): reading}}}, findings, skips, the run order."""
    caps = {a: score.capabilities(b)[1] for a, b in binaries.items()}
    order = [(a, rid) for a in sorted(binaries) for rid in sorted(rows)]
    random.Random(seed).shuffle(order)
    got, split, skipped, wit = {a: {} for a in binaries}, [], set(), {a: {"wit": {}} for a in binaries}
    for a, rid in order:
        cap = rows[rid].get("capability")
        if cap and not caps[a][cap]:            # measure's own skip rule; a 1-row corpus must not run empty
            skipped.add((a, rid, cap))
            continue
        res = score.measure(binaries[a], {"rows": [rows[rid]]}, caps[a])
        wit[a]["wit"].update(res["wit"])
        split += [(a, k, r) for k, r in score.findings(res)]
        got[a][rid] = {(at, p): v for (t, f, _r, at, p), v in res["read"].items() if (t, f) == ("interp", "straight")}
    for a in binaries:
        if got[a]:
            score.check_witnessed(wit[a])
    return got, split, skipped, order


def ba(c):
    return S.balanced(c)


def pct(xs, q):
    s = sorted(xs)
    i = q * (len(s) - 1)
    lo = int(math.floor(i))
    return s[lo] + (s[min(lo + 1, len(s) - 1)] - s[lo]) * (i - lo)


def fmt(x, w=7):
    return f"{'undef':>{w}}" if x is None else f"{x:{w}.4f}"


def main(argv):
    args, opt = argv[1:], {"corpus": [], "arm": [], "diff": [], "const-false": []}
    while args:
        k = args.pop(0)
        if k == "--calibration":
            opt["calibration"] = True
        elif k in ("--corpus", "--arm", "--diff", "--const-false", "--subject", "--seed", "--resamples",
                   "--floor-exit", "--declarations") and args:
            v = args.pop(0)
            (opt[k[2:]].append(v) if isinstance(opt.get(k[2:]), list) else opt.__setitem__(k[2:], v))
        else:
            raise HarnessError(f"usage: {__doc__.split('options:')[0].split('usage:')[1].strip()} (bad argument {k!r})")
    seed, nres = int(opt.get("seed", 1758)), int(opt.get("resamples", 10000))
    binaries = dict(x.split("=", 1) for x in opt["arm"])
    if opt.get("calibration"):
        for name, want in FROZEN.items():
            if score.sha256(os.path.join(HERE, name)) != want:
                raise HarnessError(f"{name} is not the file the instrument is frozen against (sha256 {want[:16]}):"
                                   " a change to it is a Deviation, re-pinned in judge.py and docs/PREDICATES.md")
        c1, th = S.fit(S.calibration_items())
        if (c1, th) != (S.C1_MAJORITY, S.PERSIST_THETA):
            raise HarnessError(f"standard.py's frozen C1/PERSIST {S.C1_MAJORITY} {S.PERSIST_THETA} differ from a refit"
                               f" on the calibration labels {c1} {th}")
        opt["corpus"] = [HERE, os.path.join(HERE, "hcal")] + opt["corpus"]
        binaries.setdefault("INC", os.path.join(ROOT, "src", "eigenscript"))
        if "ANCHOR" not in binaries:
            binaries["ANCHOR"] = score.anchor()["binary"]
    tmps = []
    for x in opt["const-false"]:
        name, real = x.split("=", 1)
        binaries[name], t = const_false(real)
        tmps.append(t)
    if not opt["corpus"]:
        raise HarnessError("no corpus: --calibration or --corpus DIR")
    rows, labels, src = {}, {}, {}
    for d in opt["corpus"]:
        corpus, lab = load(d)
        print(f"corpus {os.path.relpath(os.path.join(d, 'corpus.json'), ROOT)}: {len(corpus['rows'])} rows,"
              f" sha256 {score.sha256(os.path.join(d, 'corpus.json'))}")
        for r in corpus["rows"]:
            if r["id"] in rows:
                raise HarnessError(f"row id {r['id']} in two corpora")
            rows[r["id"]], src[r["id"]] = r, d
        labels.update(lab)
    print(f"python {sys.version.split()[0]}; seed {seed} (run order and bootstrap); {nres} resamples;"
          f" reference.py {score.sha256(os.path.join(HERE, 'reference.py'))[:16]};"
          f" standard.py {score.sha256(os.path.join(HERE, 'standard.py'))[:16]};"
          f" families.py {score.sha256(os.path.join(HERE, 'families.py'))[:16]}")
    for a, b in sorted(binaries.items()):
        print(f"runtime arm {a}: {b}")
    try:
        got, split, skipped, order = run_arms(binaries, rows, seed)
    finally:
        for t in tmps:
            shutil.rmtree(t, ignore_errors=True)
    pop = sorted(rid for rid in rows if all(rid in got[a] for a in binaries))
    for a, rid, cap in sorted(skipped):
        print(f"  SKIPPED {a} {rid}: capability {cap} absent: the row leaves every arm's population")
    if not pop:
        raise HarnessError("the population is empty")
    held = {rid: generate(rows[rid]["gen"], rows[rid]["n"]) for rid in pop}
    keys = [(rid, at, p) for rid in pop for at in rows[rid]["checkpoints"] for p in PREDS
            if labels[f"{rid}@{at}"][p][0] != "REPORTED"]
    V = {a: {k: got[a][k[0]][k[1:]] for k in keys} for a in binaries}
    for arm, preds in S.ARMS.items():
        V[arm] = {k: preds[k[2]](held[k[0]], k[1]) for k in keys if k[2] in preds}
    L = {k: labels[f"{k[0]}@{k[1]}"][k[2]][1] for k in keys}
    arms = sorted(binaries) + list(S.ARMS)
    print(f"population: {len(pop)} of {len(rows)} rows, {sum(len(rows[r]['checkpoints']) for r in pop)} checkpoints,"
          f" {len(keys)} scored verdicts per arm; arms: {', '.join(arms)}")
    print(f"run order: {len(order)} (arm, row) pairs shuffled by random.Random({seed}),"
          f" sha256 {hashlib.sha256(json.dumps(order).encode()).hexdigest()[:16]}")
    for a in arms:              # examined == declared > 0, per arm and predicate
        for p in PREDS:
            n = sum(1 for k in V[a] if k[2] == p)
            if n not in (0, sum(1 for k in keys if k[2] == p)):
                raise HarnessError(f"{a} {p}: {n} verdicts, the population declares {sum(1 for k in keys if k[2] == p)}")
    # per-row cells, then the paired bootstrap: every resample draws the same rows for every arm
    idx = {rid: i for i, rid in enumerate(pop)}
    col = {}
    for a in arms:
        for p in PREDS:
            if not any(k[2] == p for k in V[a]):
                continue
            c = [[0] * len(pop) for _ in range(4)]
            for k, v in V[a].items():
                if k[2] == p:
                    c[CELL[(L[k], v)]][idx[k[0]]] += 1
            col[(a, p)] = c
    point = {ap: ba([sum(x) for x in c]) for ap, c in col.items()}
    rng, boot = random.Random(seed), {ap: [] for ap in col}
    for _ in range(nres):
        w = [0] * len(pop)
        for _j in range(len(pop)):
            w[rng.randrange(len(pop))] += 1
        for ap, c in col.items():
            boot[ap].append(ba([sum(map(operator.mul, w, x)) for x in c]))

    def ci(xs):
        xs = [x for x in xs if x is not None]
        return (pct(xs, 0.025), pct(xs, 0.975), nres - len(xs)) if xs else (None, None, nres)

    def diff(a, b, p):
        if (a, p) not in col or (b, p) not in col or point[(a, p)] is None or point[(b, p)] is None:
            return None, None, None
        lo, hi, und = ci([None if x is None or y is None else x - y for x, y in zip(boot[(a, p)], boot[(b, p)])])
        return point[(a, p)] - point[(b, p)], lo, hi

    cells = {ap: [sum(x) for x in c] for ap, c in col.items()}
    fpr = {ap: (c[1] / (c[1] + c[3]) if c[1] + c[3] else None) for ap, c in cells.items()}
    print(f"\nBALANCED ACCURACY per arm x predicate: TP FP FN TN, raw right/total, BA [95% paired-bootstrap CI], FPR")
    for p in PREDS:
        print(f"  {p}")
        for a in arms:
            if (a, p) in col:
                c, (lo, hi, und) = cells[(a, p)], ci(boot[(a, p)])
                print(f"    {a:8} {c[0]:4} {c[1]:4} {c[2]:4} {c[3]:4}  raw {c[0] + c[3]:4}/{sum(c):<4} BA {fmt(point[(a, p)])}"
                      f" [{fmt(lo)}, {fmt(hi)}] FPR {fmt(fpr[(a, p)])}" + (f"  ({und} resamples undefined)" if und else ""))
    for x in opt["diff"]:
        a, b = x.split(",")
        for p in PREDS:
            d, lo, hi = diff(a, b, p)
            print(f"DIFF BA({a}) - BA({b}) {p}: {fmt(d)} [{fmt(lo)}, {fmt(hi)}]")
    # secondary metrics
    full = [a for a in arms if all((a, p) in col for p in PREDS)]
    rk = [(rid, at) for rid in pop for at in rows[rid]["checkpoints"]
          if all(labels[f"{rid}@{at}"][p][0] != "REPORTED" for p in PREDS)]
    rep = lambda f: next((p for p in ORDER if f(p)), "moving")
    print(f"\nREPORT LABEL accuracy (canonical priority {' > '.join(ORDER)} > moving), {len(rk)} fully scored checkpoints:")
    for a in full:
        print(f"  {a:8} {sum(rep(lambda p: V[a][(r, t, p)]) == rep(lambda p: L[(r, t, p)]) for r, t in rk)}/{len(rk)}")
    far = {}
    for rid in pop:
        try:
            far[rid] = generate(rows[rid]["gen"], rows[rid]["n"] + 40)
        except HarnessError:                     # an int64 row that leaves int64 within 40 steps
            pass
    print("\nFORECAST accuracy (settled verdict at n against |x_{n+k} - x_n| <= tol for k = 1..40; tol = eps for"
          f" converged, band for stable); rows whose generator cannot run 40 steps on: {sorted(set(pop) - set(far)) or 'none'}")
    for p, tol in (("converged", derive.eps), ("stable", derive.band)):
        fk = [k for k in keys if k[2] == p and k[0] in far]
        truth = {k: all(math.isfinite(v) for v in far[k[0]][k[1]:k[1] + 41]) and
                 max(abs(v - far[k[0]][k[1]]) for v in far[k[0]][k[1]:k[1] + 41]) <= tol(far[k[0]][k[1]]) for k in fk}
        print(f"  {p}: " + ", ".join(f"{a} {sum(V[a][k] == truth[k] for k in fk)}/{len(fk)}" for a in arms if (a, p) in col))
    f15 = [rid for rid in pop if rows[rid].get("base") in idx]
    above = {rows[r]["base"] for r in f15 if rows[r]["scale"] < 1 and all(abs(v) >= 1e-2 for v in held[r])}
    pairs = [(r, at, p) for r in f15 if rows[r]["base"] in above for at in rows[r]["checkpoints"] for p in PREDS]
    flips = {a: sum(1 for r, at, p in pairs if (r, at, p) in V[a] and (rows[r]["base"], at, p) in V[a]
                    and V[a][(r, at, p)] != V[a][(rows[r]["base"], at, p)]) for a in arms}
    print(f"\nUNIT FLIPS on family 15: {len(f15)} copies, {len(above)} bases above the floor, {len(pairs)} comparisons: "
          + (", ".join(f"{a} {flips[a]}" for a in arms) if f15 else "no family-15 rows in this population"))
    if opt.get("subject"):
        decide(opt, arms, col, point, fpr, diff, flips, f15, pairs)
    print("\nCONFUSION per arm x predicate x family (TP FP FN TN):")
    fams = sorted({rows[r]["family"] for r in pop})
    for a in arms:
        for p in PREDS:
            if (a, p) in col:
                for fam in fams:
                    c = [0, 0, 0, 0]
                    for k, v in V[a].items():
                        if k[2] == p and rows[k[0]]["family"] == fam:
                            c[CELL[(L[k], v)]] += 1
                    if sum(c):
                        print(f"  {a} {p} [{fam}]: {c[0]} {c[1]} {c[2]} {c[3]}")
    print("\nDISAGREEMENTS (arm row@checkpoint predicate: label, reading):")
    for a in arms:
        for k in keys:
            if k in V[a] and V[a][k] != L[k]:
                print(f"  {a} {k[0]}@{k[1]} {k[2]}: label={str(L[k]).lower()} got={str(V[a][k]).lower()}")
    print("\nRUN ORDER:", " ".join(f"{a}:{r}" for a, r in order))
    print(f"\nFINDINGS (a runtime arm's tiers split): {len(split)}")
    for a, (rid, at, p), r in split:
        print(f"  FINDING {a} {rid}@{at} {p}: " + " ".join(f"{t}={str(b).lower()}" for t, b in r.items()))
    print(f"\njudge exit {1 if split else 0}")
    return 1 if split else 0


def decide(opt, arms, col, point, fpr, diff, flips, f15, pairs):
    s = opt["subject"]
    if s not in arms or "INC" not in arms:
        raise HarnessError(f"decision rules need the subject {s!r} and INC among the arms {arms}")
    r3std = "R3-STD" if "R3-STD" in arms and s != "R3-STD" else None
    decl = None
    if opt.get("declarations"):
        decl = [ln for ln in open(opt["declarations"]) if "#1830" in ln or "R3" in ln.split()]
    print(f"\nDECISION RULES (pre-registration; subject {s}; STD = the primary STD_p; amendment: R3-STD"
          f" {'= ' + r3std if r3std else 'absent'}):")
    for p in PREDS:
        res = []
        def crit(name, ok, text):
            res.append(ok)
            print(f"  {p:12} {name:22} {'NOT EVALUATED' if ok is None else 'PASS' if ok else 'FAIL'}: {text}")
        d, lo, _hi = diff(s, "STD", p)
        crit("1 standard parity", None if lo is None else lo > -0.05, f"lower CI of BA({s}) - BA(STD) = {fmt(lo)} > -0.05")
        for ref in ["INC"] + ([r3std] if r3std and p in ("converged", "stable") else []):
            d, lo, _hi = diff(s, ref, p)
            if p in ("converged", "stable"):
                crit(f"2 vs {ref}", None if d is None else d >= 0.05 and lo > 0,
                     f"BA({s}) - BA({ref}) = {fmt(d)} >= +0.05, lower CI {fmt(lo)} > 0")
            else:
                crit(f"2 vs {ref}", None if lo is None else lo > -0.02, f"lower CI of BA({s}) - BA({ref}) = {fmt(lo)} > -0.02")
        f = {a: fpr.get((a, p)) for a in (s, "INC", "STD")}
        if p in S.SETTLED:
            ok = None if None in f.values() else f[s] <= min(f["INC"], f["STD"] + 0.02)
            crit("3 safety", ok, f"FPR({s}) {fmt(f[s])} <= min(FPR(INC) {fmt(f['INC'])}, FPR(STD) + 0.02)")
        elif p == "diverging":
            crit("3 safety", None if None in (f[s], f["INC"]) else f[s] <= f["INC"], f"FPR({s}) {fmt(f[s])} <= FPR(INC) {fmt(f['INC'])}")
        crit("4 trivial floor", None if point.get((s, p)) is None else point[(s, p)] >= 0.65, f"BA({s}) = {fmt(point.get((s, p)))} >= 0.65")
        crit("5 unit invariance", None if not f15 else flips[s] == 0, f"{flips[s]} flips on {len(pairs)} family-15 comparisons above the floor"
             if f15 else "no family-15 rows in this population")
        rc = opt.get("floor-exit")
        crit("6 existing gates", None if rc is None or decl is None else rc == "0" and not decl,
             f"--floor exit {rc if rc is not None else 'not given'}; #1830/R3 declarations "
             + (str(len(decl)) if decl is not None else "not given"))
        v = "FAIL" if False in res else "PASS" if None not in res else "INCOMPLETE"
        print(f"  {p:12} => {v}")


def selftest():
    """The tools/selftests.txt row, control (b) as the judge's own calibration: the
    anchor with every reading rewritten false must score BA = 0.5 and FAIL the rules; and
    STD and REF, the same `converged` test, must differ by exactly 0 in every resample (pairing)."""
    if subprocess.run(["make", "--no-print-directory", "-C", ROOT, "observer-anchor"], stdin=subprocess.DEVNULL,
                      stdout=subprocess.DEVNULL).returncode:
        raise HarnessError("make observer-anchor failed: no anchor to plant against")
    a = score.anchor()["binary"]
    return main(["judge.py", "--corpus", os.path.join(HERE, "hcal"), "--arm", f"INC={a}", "--const-false", f"CF={a}",
                 "--subject", "CF", "--diff", "STD,REF", "--resamples", "1000",
                 "--floor-exit", "1", "--declarations", os.devnull])


if __name__ == "__main__":
    try:
        sys.exit(selftest() if sys.argv[1:] == ["--selftest"] else main(sys.argv))
    except HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:          # an instrument crash is never a verdict
        print(f"OBSERVER_ORACLE_ERROR: internal {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
