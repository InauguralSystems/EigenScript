#!/usr/bin/env python3
"""C/Lean EigenCore differential comparison driver; see tools/ref_diff.sh."""
from __future__ import annotations

from collections import Counter
from pathlib import Path
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import ref_program_gen as gen  # noqa: E402
import spec_lean_parity as parity  # noqa: E402 -- reuse step 2's projection


def corpus():
    spec = importlib.util.spec_from_file_location("doc_examples", ROOT / "tests/test_doc_examples.py")
    docs = importlib.util.module_from_spec(spec); spec.loader.exec_module(docs)
    for rel in docs.POPULATION:
        for line, info, args, source in docs.blocks(str(ROOT / rel)):
            kind, _, error = docs.parse_tag(args)
            if error:
                raise RuntimeError(f"{rel}:{line}: {error}")
            if info == "eigenscript" and kind in ("", "check"):
                yield f"{rel}:{line}", source
    tracked = subprocess.check_output(["git", "ls-files", ":(glob)tests/**/*.eigs", ":(glob)examples/**/*.eigs"], cwd=ROOT, text=True)
    for rel in tracked.splitlines():
        yield rel, (ROOT / rel).read_text()


def run(cmd, env=None, data=b"", timeout=30):
    try:
        return subprocess.run(cmd, input=data, capture_output=True, env=env, timeout=timeout), None
    except subprocess.TimeoutExpired:
        return None, f"timeout after {timeout:g}s"


def compare_one(label, source, vm, ref, td, oracle_seed, timeout):
    p = td / "program.eigs"; p.write_text(source)
    verdict, timed_out = run([ref, "--classify-runtime", p], timeout=timeout)
    if timed_out:
        return False, [f"classifier arm {timed_out}"], {}
    if verdict.returncode or verdict.stdout.strip() not in (b"in-subset",) and not verdict.stdout.startswith(b"out: "):
        return False, ["classifier protocol"], {}
    if verdict.stdout.strip() != b"in-subset":
        return False, [], {}
    reasons, tier_data = [], {}
    c_tape = td / "c.tape"
    base = {**os.environ, "EIGS_TRACE": str(c_tape), "REF_DIFF_MISSING": ""}
    c, timed_out = run([vm, p], {**base, "EIGS_JIT_OFF": "1"}, timeout=timeout)
    if timed_out: return True, [f"C-record arm {timed_out}"], {}
    if not c_tape.exists():
        return True, ["C record tape missing"], {}
    l_tape = td / "lean-replay.tape"
    l, timed_out = run([ref, "--replay", c_tape, "--strict", "--trace", l_tape, p], timeout=timeout)
    if timed_out: return True, [f"Lean-replay arm {timed_out}"], {}
    if c.stdout != l.stdout: reasons.append("C-record/Lean-replay stdout")
    if parity.cls(c) != parity.cls(l): reasons.append("C-record/Lean-replay exit class")
    if parity.projection(c_tape) != parity.projection(l_tape): reasons.append("C-record/Lean-replay A/N projection")

    own = td / "lean-record.tape"
    lo, timed_out = run([ref, "--seed", str(oracle_seed), "--trace", own, p], timeout=timeout)
    if timed_out: return True, [f"Lean-record arm {timed_out}"], {}
    cr_tape = td / "c-replay.tape"
    cr, timed_out = run([vm, p], {**os.environ, "EIGS_REPLAY": str(own), "EIGS_REPLAY_STRICT": "1", "EIGS_TRACE": str(cr_tape), "REF_DIFF_MISSING": ""}, timeout=timeout)
    if timed_out: return True, [f"C-replay arm {timed_out}"], {}
    if lo.stdout != cr.stdout: reasons.append("Lean-record/C-replay stdout")
    if parity.cls(lo) != parity.cls(cr): reasons.append("Lean-record/C-replay exit class")
    if parity.projection(own) != parity.projection(cr_tape): reasons.append("Lean-record/C-replay A/N projection")

    for tier, extra in (("interpreter", {"EIGS_JIT_OFF": "1"}), ("jit", {"EIGS_DUMP_BC": "1"}),
                        ("osr", {"EIGS_JIT_OSR_THRESHOLD": "1", "EIGS_DUMP_BC": "1"})):
        tape = td / f"{tier}.tape"
        got, timed_out = run([vm, p], {**os.environ, **extra, "EIGS_REPLAY": str(own), "EIGS_REPLAY_STRICT": "1", "EIGS_TRACE": str(tape), "REF_DIFF_MISSING": ""}, timeout=timeout)
        if timed_out:
            reasons.append(f"{tier} arm {timed_out}")
            tier_data[tier] = {"exit": "timeout", "witness": False}
            continue
        tier_data[tier] = {"exit": parity.cls(got), "witness": tier == "interpreter" or b"==" in got.stderr}
        if got.stdout != lo.stdout or parity.cls(got) != parity.cls(lo) or parity.projection(tape) != parity.projection(own):
            reasons.append(f"{tier} tier")
        if tier != "interpreter" and b"==" not in got.stderr:
            reasons.append(f"{tier} EIGS_DUMP_BC witness")
    return True, sorted(set(reasons)), tier_data


def hot_programs(seed):
    """Return independent bounded back-edge and hot-callee probes."""
    loop = f"""# ref-diff hot loop seed: {seed}
value is 0
loop while value < {120 + seed % 7}:
    value is value + 1
print of value
"""
    calls = [f"# ref-diff hot call seed: {seed}", "define hot_call(value) as:",
             "    return value + 1", "value is 0"]
    calls.extend("value is hot_call of value" for _ in range(60 + seed % 7))
    calls.append("print of value")
    return ((f"hot-loop:{seed}", loop), (f"hot-call:{seed}", "\n".join(calls) + "\n"))


def compare_hot(label, source, vm, td, timeout):
    """Compare hot C roads; current VM diagnostics do not count native entries."""
    p = td / "program.eigs"; p.write_text(source)
    reasons, tiers = [], {}
    baseline, timed_out = run([vm, p], {**os.environ, "EIGS_JIT_OFF": "1"}, timeout=timeout)
    if timed_out: return True, [f"interpreter arm {timed_out}"], tiers
    tiers["interpreter"] = {"exit": parity.cls(baseline), "witness": True}
    for tier, extra in (("jit", {}), ("osr", {"EIGS_JIT_OSR_THRESHOLD": "1"})):
        got, timed_out = run([vm, p], {**os.environ, **extra, "EIGS_JIT_HOT": "1", "EIGS_JIT_STATS": "1"}, timeout=timeout)
        if timed_out:
            reasons.append(f"{tier} arm {timed_out}"); tiers[tier] = {"exit": "timeout", "witness": False}; continue
        # EIGS_JIT_STATS counts compilations and EIGS_JIT_HOT estimates native
        # coverage, but neither counts entry into emitted code.  Do not turn a
        # compilation proxy into the execution witness requested by the gate.
        tiers[tier] = {"exit": parity.cls(got), "witness": False}
        if got.stdout != baseline.stdout or parity.cls(got) != parity.cls(baseline):
            reasons.append(f"{tier} tier")
        reasons.append(f"{tier} native execution not witnessed")
    return True, sorted(set(reasons)), tiers


def triage(reasons):
    """Assign every red row to exactly one of #2017's three buckets."""
    # A novel mismatch is not silently waived as an implementation defect.
    # It remains a specification question until minimization assigns a side.
    return {"category": "specification question", "detail": "new mismatch; minimize and decide the owning implementation"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--generated", type=int, default=500)
    ap.add_argument("--corpus", action="store_true")
    ap.add_argument("--seed-start", type=int, default=1)
    ap.add_argument("--hot", type=int, default=0, help="add separately labelled bounded hot programs")
    ap.add_argument("--timeout", type=float, default=30, help="per-program, per-arm timeout in seconds")
    ap.add_argument("--vm", type=Path, default=ROOT / "src/eigenscript")
    ap.add_argument("--ref", type=Path, default=ROOT / "spec/lean/.lake/build/bin/eigs-ref")
    ap.add_argument("--report", type=Path, default=Path("ref-diff-report.json"))
    args = ap.parse_args()
    programs = [(f"generated:{s}", gen.program(s), True) for s in range(args.seed_start, args.seed_start + args.generated)]
    if args.corpus: programs += [(n, s, False) for n, s in corpus()]
    programs += [(label, source, False) for s in range(1, args.hot + 1)
                 for label, source in hot_programs(s)]
    compared = inside = generated = disagreements = 0
    seams, histogram, rows = Counter(), Counter(), []
    with tempfile.TemporaryDirectory(prefix="ref-diff-") as raw:
        root = Path(raw)
        for i, (label, source, made) in enumerate(programs):
            if made: generated += 1
            d = root / str(i); d.mkdir()
            if label.startswith("hot-"):
                in_subset, reasons, tiers = compare_hot(label, source, args.vm, d, args.timeout)
            else:
                in_subset, reasons, tiers = compare_one(label, source, args.vm, args.ref, d, args.seed_start + i, args.timeout)
            if in_subset:
                inside += 1; compared += 1
                for seam in gen.SEAMS:
                    if f"ref-diff: " in source and seam in source: seams[seam] += 1
            if reasons:
                disagreements += 1
                histogram.update(reasons)
                print(f"DISAGREEMENT {label}: {', '.join(reasons)}", file=sys.stderr)
            rows.append({"program": label, "generated": made, "in_subset": in_subset, "reasons": reasons,
                         "triage": triage(reasons) if reasons else None, "tiers": tiers})
    categories = Counter(r["triage"]["category"] for r in rows if r["triage"])
    report = {"summary": {"compared": compared, "in_subset": inside, "generated": generated, "disagreements": disagreements},
              "coverage": dict(sorted(seams.items())), "reason_histogram": dict(sorted(histogram.items())),
              "triage_histogram": dict(sorted(categories.items())), "programs": rows}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"compared/in_subset/generated/disagreements: {compared}/{inside}/{generated}/{disagreements}")
    print("coverage: " + " ".join(f"{s}={seams[s]}" for s in gen.SEAMS))
    print("reason histogram: " + (" ".join(f"{k}={v}" for k, v in sorted(histogram.items())) or "empty"))
    return 1 if disagreements else 0


if __name__ == "__main__":
    try: raise SystemExit(main())
    except RuntimeError as e: raise SystemExit(f"ref_diff: {e}")
