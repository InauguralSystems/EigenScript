#!/usr/bin/env python3
"""Round 3's judge (#1758 pre-registration, comments 6430031838 + 6430139845;
RULINGS R30-1..R30-4): every arm scored per predicate by balanced accuracy
with a PAIRED cluster bootstrap over rows, and the six decision rules
evaluated mechanically.

usage: judge.py --selftest                    the rules at their margins, and control (b) on hcal/ (tools/selftests.txt)
       judge.py --write-manifest DIR [--arm NAME=BINARY ...]   seal DIR (after certify/derive) with its arm binaries
       judge.py --calibration [options]       corpus.json + hcal/, arms INC (default src/eigenscript, standing in
                                              for v0.47.0)
                                              and ANCHOR = the build_anchor.sh binary
       judge.py --corpus DIR [--corpus DIR ...] [options]
       --corpus refuses (exit 2) unless DIR/manifest.json pins its set, the code and every arm binary (R30I-2 item 5)
options: --arm NAME=BINARY      a runtime arm (repeatable)
         --manifest-out PATH    (--calibration) write the calibration manifest there
         --tol-converged NAME=K  STD converged with its tolerance x K (control (c2), Deviation D5)
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
The python arms are standard.py's. The population is every row (D9): a
runtime arm without a row's capability has no reading there, and every
difference is taken, paired, on the rows both arms read. Exit 0 when the table printed, 1 on a FINDING, 2 on
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
import families as F
import standard as S
from gen import HarnessError, generate
from schema import PREDS

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
# The instrument is frozen against these files (Deviations D3, D4; docs/PREDICATES.md; the posted generator).
FROZEN = {"corpus.json": "e3f5e94e97bd28972480977a5ff21173221e878ab784abc7f4ed5459bedfefe4",
          "reference.py": "fa74d83f23422f5ddee9b30dc0f133417f98d9d8e7f9806151233d9e18ca1993",
          "families.py": "a53f10374d3592dfcd637153cc482ddbbdc5afd0d80425c0f86ab671888887eb",
          "hcal/corpus.json": "af06b08602ae37050af5e4e0262623559dec1f2532a270d87054573c38a7b7ae"}
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
    args, opt = argv[1:], {"corpus": [], "arm": [], "diff": [], "const-false": [], "tol-converged": []}
    while args:
        k = args.pop(0)
        if k == "--calibration":
            opt["calibration"] = True
        elif k in ("--corpus", "--arm", "--diff", "--const-false", "--tol-converged", "--subject", "--seed", "--resamples",
                   "--floor-exit", "--declarations", "--write-manifest", "--manifest-out") and args:
            v = args.pop(0)
            (opt[k[2:]].append(v) if isinstance(opt.get(k[2:]), list) else opt.__setitem__(k[2:], v))
        else:
            raise HarnessError(f"usage: {__doc__.split('options:')[0].split('usage:')[1].strip()} (bad argument {k!r})")
    seed, nres = int(opt.get("seed", 1758)), int(opt.get("resamples", 10000))
    binaries = dict(x.split("=", 1) for x in opt["arm"])
    real = {**binaries, **dict(x.split("=", 1) for x in opt["const-false"])}     # what each arm runs
    if opt.get("write-manifest"):
        load(opt["write-manifest"])                     # the label gate first: never seal labels derive.py disowns
        m = F.write_manifest(opt["write-manifest"], real)
        print(f"manifest written: {os.path.join(opt['write-manifest'], F.MANIFEST)}: {json.dumps(m, sort_keys=True)}")
        return 0
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
        if "INC" not in binaries:     # RULING R30I-1 item 2: INC is the v0.47.0 tag; main's binary stands in where identical
            binaries["INC"] = os.path.join(ROOT, "src", "eigenscript")
            print("INC: main's binary standing in for the registered v0.47.0 (3d8a14b4); their calibration verdicts were"
                  " identical at R3.0-I round 2. Pass --arm INC=<v0.47.0 binary> for the registered arm")
        if "ANCHOR" not in binaries:
            binaries["ANCHOR"] = score.anchor()["binary"]
        real.update(binaries)
    else:
        for d in opt["corpus"]:                         # the reveal path: a set is scored only as it was sealed
            F.verify_manifest(d, real)
            print(f"manifest {os.path.join(d, F.MANIFEST)}: set, code and {len(real)} arm binaries match")
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
    if opt.get("calibration"):
        cal = {"format": "r3-manifest/1", "corpora": {os.path.relpath(d, ROOT): F.manifest_of(d, {})["set"] for d in opt["corpus"]},
               "code": F.manifest_of(HERE, {})["code"], "arms": {a: F.sha(b) for a, b in sorted(real.items())}}
        text = json.dumps(cal, indent=1, sort_keys=True) + "\n"
        if opt.get("manifest-out"):
            open(opt["manifest-out"], "w").write(text)
        print(f"calibration manifest sha256 {hashlib.sha256(text.encode()).hexdigest()}"
              + (f" written to {opt['manifest-out']}" if opt.get("manifest-out") else "") + f": {json.dumps(cal, sort_keys=True)}")
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
    pop = sorted(rows)                    # D9: capability rows stay; a runtime arm without the capability reads "absent"
    for a, rid, cap in sorted(skipped):
        print(f"  CAPABILITY ABSENT {a} {rid}: {cap}: the row stays in the population; {a} has no reading on it")
    if not pop:
        raise HarnessError("the population is empty")
    held = {rid: generate(rows[rid]["gen"], rows[rid]["n"]) for rid in pop}
    keys = [(rid, at, p) for rid in pop for at in rows[rid]["checkpoints"] for p in PREDS
            if labels[f"{rid}@{at}"][p][0] != "REPORTED"]
    V = {a: {k: got[a][k[0]][k[1:]] for k in keys if k[0] in got[a]} for a in binaries}
    arms_py = dict(S.ARMS)
    for x in opt["tol-converged"]:                # control (c2): STD converged, tolerance x K
        name, k = x.split("=", 1)
        arms_py[name] = {"converged": S.tol_converged(float(k))}
    for arm, preds in arms_py.items():
        V[arm] = {k: preds[k[2]](held[k[0]], k[1]) for k in keys if k[2] in preds}
    L = {k: labels[f"{k[0]}@{k[1]}"][k[2]][1] for k in keys}
    arms = sorted(binaries) + list(arms_py)
    print(f"population: {len(pop)} of {len(rows)} rows, {sum(len(rows[r]['checkpoints']) for r in pop)} checkpoints,"
          f" {len(keys)} scored verdicts per arm; arms: {', '.join(arms)}")
    print(f"run order: {len(order)} (arm, row) pairs shuffled by random.Random({seed}),"
          f" sha256 {hashlib.sha256(json.dumps(order).encode()).hexdigest()[:16]}")
    absent = {}                 # examined + capability-absent == declared > 0, per arm and predicate
    for a in arms:
        for p in PREDS:
            n, want = sum(1 for k in V[a] if k[2] == p), [k for k in keys if k[2] == p]
            absent[(a, p)] = sum(1 for k in want if a in binaries and k[0] not in got[a])
            if n not in (0, len(want) - absent[(a, p)]) or (n and n + absent[(a, p)] != len(want)):
                raise HarnessError(f"{a} {p}: {n} verdicts + {absent[(a, p)]} capability-absent, the population declares {len(want)}")
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
    rows_of = {(a, p): frozenset(idx[k[0]] for k in V[a] if k[2] == p) for a, p in col}
    rng, boot, weights = random.Random(seed), {ap: [] for ap in col}, []
    for _ in range(nres):
        w = [0] * len(pop)
        for _j in range(len(pop)):
            w[rng.randrange(len(pop))] += 1
        weights.append(w)
        for ap, c in col.items():
            boot[ap].append(ba([sum(map(operator.mul, w, x)) for x in c]))

    def ci(xs):
        xs = [x for x in xs if x is not None]
        return (pct(xs, 0.025), pct(xs, 0.975), nres - len(xs)) if xs else (None, None, nres)

    def diff(a, b, p):
        """(point, lo, hi, verdicts left out): BA(a) - BA(b) on the rows BOTH arms read (D9), paired."""
        if (a, p) not in col or (b, p) not in col:
            return None, None, None, 0
        common = rows_of[(a, p)] & rows_of[(b, p)]
        if common == rows_of[(a, p)] == rows_of[(b, p)]:
            pa, pb, ba_, bb = point[(a, p)], point[(b, p)], boot[(a, p)], boot[(b, p)]
        else:
            ca, cb = ([[x if i in common else 0 for i, x in enumerate(r)] for r in col[q]] for q in ((a, p), (b, p)))
            pa, pb = ba([sum(x) for x in ca]), ba([sum(x) for x in cb])
            ba_ = [ba([sum(map(operator.mul, w, x)) for x in ca]) for w in weights]
            bb = [ba([sum(map(operator.mul, w, x)) for x in cb]) for w in weights]
        out = sum(sum(x[i] for x in col[q] for i in rows_of[q] - common) for q in ((a, p), (b, p)))
        if pa is None or pb is None:
            return None, None, None, out
        lo, hi, und = ci([None if x is None or y is None else x - y for x, y in zip(ba_, bb)])
        return pa - pb, lo, hi, out

    cells = {ap: [sum(x) for x in c] for ap, c in col.items()}
    fpr = {ap: (c[1] / (c[1] + c[3]) if c[1] + c[3] else None) for ap, c in cells.items()}
    print(f"\nBALANCED ACCURACY per arm x predicate: TP FP FN TN, raw right/total, BA [95% paired-bootstrap CI], FPR")
    for p in PREDS:
        print(f"  {p}")
        for a in arms:
            if (a, p) in col:
                c, (lo, hi, und) = cells[(a, p)], ci(boot[(a, p)])
                print(f"    {a:8} {c[0]:4} {c[1]:4} {c[2]:4} {c[3]:4}  raw {c[0] + c[3]:4}/{sum(c):<4} BA {fmt(point[(a, p)])}"
                      f" [{fmt(lo)}, {fmt(hi)}] FPR {fmt(fpr[(a, p)])}" + (f"  ({und} resamples undefined)" if und else "")
                      + (f"  (capability-absent {absent[(a, p)]})" if absent[(a, p)] else ""))
    for x in opt["diff"]:
        a, b = x.split(",")
        for p in PREDS:
            d, lo, hi, out = diff(a, b, p)
            print(f"DIFF BA({a}) - BA({b}) {p}: {fmt(d)} [{fmt(lo)}, {fmt(hi)}]"
                  + (f"  ({out} verdicts on rows only one arm reads left out)" if out else ""))
    # secondary metrics
    full = [a for a in arms if all((a, p) in col for p in PREDS)]
    rk = [(rid, at) for rid in pop for at in rows[rid]["checkpoints"]
          if all(labels[f"{rid}@{at}"][p][0] != "REPORTED" for p in PREDS)]
    rep = lambda f: next((p for p in ORDER if f(p)), "moving")
    print(f"\nREPORT LABEL accuracy (canonical priority {' > '.join(ORDER)} > moving), {len(rk)} fully scored checkpoints:")
    for a in full:
        mine = [(r, t) for r, t in rk if all((r, t, p) in V[a] for p in PREDS)]
        print(f"  {a:8} {sum(rep(lambda p: V[a][(r, t, p)]) == rep(lambda p: L[(r, t, p)]) for r, t in mine)}/{len(mine)}")
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
        print(f"  {p}: " + ", ".join(f"{a} {sum(V[a][k] == truth[k] for k in fk if k in V[a])}/{sum(k in V[a] for k in fk)}"
                                     for a in arms if (a, p) in col))
    declared = [r for r in pop if rows[r].get("family", "").startswith("F15 ")]     # D7: every family-15 copy
    above = {rows[r]["base"] for r in declared if rows[r]["scale"] < 1 and rows[r]["base"] in idx
             and F.above_floor(held[r])}
    examined = [r for r in declared if rows[r]["base"] in above]
    pairs = [(r, at, p) for r in examined for at in rows[r]["checkpoints"] for p in PREDS]
    flips = {a: sum(1 for r, at, p in pairs if (r, at, p) in V[a] and (rows[r]["base"], at, p) in V[a]
                    and V[a][(r, at, p)] != V[a][(rows[r]["base"], at, p)]) for a in arms}
    print(f"\nUNIT FLIPS on family 15: examined={len(examined)} declared={len(declared)} copies, {len(above)} bases above"
          f" the floor, {len(pairs)} comparisons: " + ", ".join(f"{a} {flips[a]}" for a in arms))
    if opt.get("subject"):
        decide(opt, arms, point, fpr, diff, flips, len(examined), len(declared), pairs)
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


def rule1(lo):
    return None if lo is None else lo > -0.05


def rule2(p, d, lo):
    if d is None or lo is None:
        return None
    return d >= 0.05 and lo > 0 if p in ("converged", "stable") else lo > -0.02


def rule3(p, fs, finc, fstd):
    if p in S.SETTLED:
        return None if None in (fs, finc, fstd) else fs <= min(finc, fstd + 0.02)
    return None if None in (fs, finc) else fs <= finc          # diverging


def rule4(b):
    return None if b is None else b >= 0.65


def rule5(flips, examined, declared):
    """D7: evaluated only when every declared family-15 copy was compared."""
    return None if declared == 0 or examined != declared else flips == 0


def rule6(rc, decl):
    return None if rc is None or decl is None else rc == "0" and not decl


def decide(opt, arms, point, fpr, diff, flips, examined, declared, pairs):
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
        d, lo, _hi, out = diff(s, "STD", p)
        crit("1 standard parity", rule1(lo), f"lower CI of BA({s}) - BA(STD) = {fmt(lo)} > -0.05"
             + (f" ({out} verdicts on rows {s} cannot read left out)" if out else ""))
        for ref in ["INC"] + ([r3std] if r3std and p in ("converged", "stable") else []):
            d, lo, _hi, out = diff(s, ref, p)
            note = f" (NOT EVALUATED on {out} capability-row verdicts, D9)" if out else ""
            if p in ("converged", "stable"):
                crit(f"2 vs {ref}", rule2(p, d, lo), f"BA({s}) - BA({ref}) = {fmt(d)} >= +0.05, lower CI {fmt(lo)} > 0" + note)
            else:
                crit(f"2 vs {ref}", rule2(p, d, lo), f"lower CI of BA({s}) - BA({ref}) = {fmt(lo)} > -0.02" + note)
        f = {a: fpr.get((a, p)) for a in (s, "INC", "STD")}
        if p in S.SETTLED:
            crit("3 safety", rule3(p, f[s], f["INC"], f["STD"]),
                 f"FPR({s}) {fmt(f[s])} <= min(FPR(INC) {fmt(f['INC'])}, FPR(STD) + 0.02)")
        elif p == "diverging":
            crit("3 safety", rule3(p, f[s], f["INC"], None), f"FPR({s}) {fmt(f[s])} <= FPR(INC) {fmt(f['INC'])}")
        crit("4 trivial floor", rule4(point.get((s, p))), f"BA({s}) = {fmt(point.get((s, p)))} >= 0.65")
        crit("5 unit invariance", rule5(flips[s], examined, declared),
             f"{flips[s]} flips on {len(pairs)} family-15 comparisons, examined={examined} declared={declared}")
        rc = opt.get("floor-exit")
        crit("6 existing gates", rule6(rc, decl), f"--floor exit {rc if rc is not None else 'not given'}; #1830/R3"
             " declarations " + (str(len(decl)) if decl is not None else "not given"))
        v = "FAIL" if False in res else "PASS" if None not in res else "INCOMPLETE"
        print(f"  {p:12} => {v}")


BOUNDARY = [   # (rule, case, call, want): each rule placed exactly at its margin and just past it (RULING R30I-2 item 3)
    ("rule1", "lo=-0.05", lambda: rule1(-0.05), False), ("rule1", "lo=-0.0499", lambda: rule1(-0.0499), True),
    ("rule1", "lo=undef", lambda: rule1(None), None),
    ("rule2cs", "d=0.05,lo=0.001", lambda: rule2("converged", 0.05, 0.001), True),
    ("rule2cs", "d=0.0499,lo=0.001", lambda: rule2("stable", 0.0499, 0.001), False),
    ("rule2cs", "d=0.06,lo=0", lambda: rule2("converged", 0.06, 0.0), False),
    ("rule2o", "lo=-0.02", lambda: rule2("improving", 0.0, -0.02), False),
    ("rule2o", "lo=-0.0199", lambda: rule2("oscillating", 0.0, -0.0199), True),
    ("rule3", "fs=FPR(STD)+0.02", lambda: rule3("converged", 0.25 + 0.02, 0.5, 0.25), True),
    ("rule3", "fs=FPR(STD)+0.0201", lambda: rule3("stable", 0.2701, 0.5, 0.25), False),
    ("rule3", "fs=FPR(INC)", lambda: rule3("equilibrium", 0.1, 0.1, 0.25), True),
    ("rule3", "fs=FPR(INC)+1e-4", lambda: rule3("equilibrium", 0.1001, 0.1, 0.25), False),
    ("rule3", "diverging fs=FPR(INC)", lambda: rule3("diverging", 0.2, 0.2, None), True),
    ("rule3", "diverging fs=FPR(INC)+1e-4", lambda: rule3("diverging", 0.2001, 0.2, None), False),
    ("rule4", "BA=0.65", lambda: rule4(0.65), True), ("rule4", "BA=0.6499", lambda: rule4(0.6499), False),
    ("rule5", "0 flips 20/20", lambda: rule5(0, 20, 20), True), ("rule5", "1 flip 20/20", lambda: rule5(1, 20, 20), False),
    ("rule5", "0 flips 19/20", lambda: rule5(0, 19, 20), None), ("rule5", "0 flips 0/0", lambda: rule5(0, 0, 0), None),
    ("rule6", "floor 0, none declared", lambda: rule6("0", []), True),
    ("rule6", "floor 0, one declared", lambda: rule6("0", ["x #1830"]), False),
    ("rule6", "floor 1, none declared", lambda: rule6("1", []), False), ("rule6", "not given", lambda: rule6(None, []), None)]


def selftest():
    """The tools/selftests.txt row. (1) Every decision rule at its margin, both sides (BOUNDARY). (2) Control (b)
    as the judge's own calibration, on a manifest-sealed copy of hcal/: the anchor with every reading rewritten
    false must score BA = 0.5 and FAIL the rules, and STD and REF, the same `converged` test, must differ by
    exactly 0 in every resample (pairing). (3) A set sealed for another arm binary is refused (exit 2 path)."""
    word = {True: "PASS", False: "FAIL", None: "NOT EVALUATED"}
    for rule, case, call, want in BOUNDARY:
        got = call()
        print(f"BOUNDARY {rule} {case}: {word[got]} (want {word[want]}) {'ok' if got == want else 'MISMATCH'}")
    if subprocess.run(["make", "--no-print-directory", "-C", ROOT, "observer-anchor"], stdin=subprocess.DEVNULL,
                      stdout=subprocess.DEVNULL).returncode:
        raise HarnessError("make observer-anchor failed: no anchor to plant against")
    a = score.anchor()["binary"]
    with tempfile.TemporaryDirectory(prefix="judge_selftest_") as t:
        for f in F.SET:
            shutil.copy(os.path.join(HERE, "hcal", f), t)
        m = F.write_manifest(t, {"INC": a})            # (3) a set sealed for another INC binary must be refused
        m["arms"]["INC"] = "0" * 64
        json.dump(m, open(os.path.join(t, F.MANIFEST), "w"))
        try:
            main(["judge.py", "--corpus", t, "--arm", f"INC={a}", "--resamples", "10"])
            print("MANIFEST a set sealed for another INC binary was SCORED: MISMATCH")
        except HarnessError as e:
            print(f"MANIFEST a set sealed for another INC binary was refused: ok ({str(e).split(': ', 1)[1]})")
        os.remove(os.path.join(t, F.MANIFEST))
        F.write_manifest(t, {"INC": a, "CF": a})
        return main(["judge.py", "--corpus", t, "--arm", f"INC={a}", "--const-false", f"CF={a}",
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
