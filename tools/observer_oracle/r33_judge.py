#!/usr/bin/env python3
"""Stage R33-1 x1 guard sets and drive the frozen judge as a program.

The current instrument proof uses F0 against F0 once on the two released
sets together. A later confirmation uses H-cal alone for predicates with
both labels and the union for the remaining predicates. This module never
implements, copies, or extracts the judge's nested bootstrap. Its receipt
retains the requested printed differences and printed undefined counts;
the other F0 metric tables printed internally by judge.py are discarded.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import derive
import families
from gen import HarnessError
from schema import PREDS
import score
import r33_metrics

HERE = Path(__file__).resolve().parent
SUBJECT = "54008422b7bb4950131f4dd4d15ead942a2ecb2e"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def choice_hash(path, candidate, f0):
    if path is None:
        if Path(candidate).resolve() != Path(f0).resolve():
            raise HarnessError("CONFIRMATION REFUSED: posted choice file required before a non-F0 arm")
        return None
    path = Path(path)
    if not path.is_file():
        raise HarnessError(f"CONFIRMATION REFUSED: posted choice file missing: {path}")
    # One schema is shared with the point-table confirmation driver: arm
    # and sweep-table sha256 are required, and the actual posted bytes are
    # pinned, including any owner-supplied posting metadata.
    _choice, digest = r33_metrics.choice_file(path)
    return digest


def arms(f0, candidate=None):
    return {"F0": str(Path(f0).resolve()), "ARM": str(Path(candidate or f0).resolve())}


def commands(destination, f0, candidate=None):
    destination = Path(destination).resolve()
    binaries = arms(f0, candidate)
    common = [sys.executable, "-I", str(HERE / "judge.py"),
              "--arm", "F0=" + binaries["F0"], "--arm", "ARM=" + binaries["ARM"],
              "--diff", "ARM,F0", "--seed", "175833", "--resamples", "10000"]
    hcal = common + ["--corpus", str(destination / "hcal")]
    return {"hcal": hcal,
            "union": hcal + ["--corpus", str(destination / "calibration")]}


def stage(destination, f0, candidate=None, choice=None):
    destination = Path(destination).resolve()
    binaries = arms(f0, candidate)
    choice_sha = choice_hash(choice, binaries["ARM"], binaries["F0"])
    baseline = families.arm_record(binaries["F0"])
    if baseline["source_sha"] != SUBJECT or baseline["recipe_id"] != sha(HERE / "build_arm.sh"):
        raise HarnessError("F0 is not the fixed subject's recipe-built binary")
    if baseline["binary_sha256"] != baseline["stamp_binary_sha256"]:
        raise HarnessError("F0 differs from its recipe-built stamp")
    destination.mkdir(parents=True, exist_ok=True)
    receipts = {}
    for name, source in (("calibration", HERE), ("hcal", HERE / "hcal")):
        target = destination / name
        target.mkdir(exist_ok=True)
        for filename in families.SET:
            src, dst = source / filename, target / filename
            if dst.exists() and dst.read_bytes() != src.read_bytes():
                raise HarnessError(f"staged released set changed: {dst}")
            shutil.copyfile(src, dst)
        corpus = derive.load_corpus(str(target / "corpus.json"))
        certs = derive.load_certificates(corpus, str(target / "certificate.json"))
        score.load_labels(corpus, certs, str(target / "labels.json"))
        # Sealing is an unchanged public API; it hashes programs, code and
        # binary/lib identities, without executing any subject program.
        with contextlib.redirect_stdout(io.StringIO()):
            families.write_manifest(str(target), binaries)
        receipts[name] = {"rows": len(corpus["rows"]),
                          "checkpoints": sum(len(row["checkpoints"]) for row in corpus["rows"]),
                          "files": {filename: sha(target / filename)
                                    for filename in (*families.SET, families.MANIFEST)}}
    receipt = {"format": "r33-judge-stage/1", "choice_sha256": choice_sha,
               "subject": SUBJECT, "sets": receipts,
               "commands": commands(destination, f0, candidate),
               "guard_population_note": "released x1 sets as they stand; addendum1 exclusions apply to unit-comparison sets",
               "guard_populations": {p: "union" if p in ("diverging", "equilibrium") else "hcal"
                                     for p in PREDS}}
    (destination / "stage.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def printed_bounds(output):
    """Read emitted data only, with matched-support count justification.

    A binary prediction cannot change whether a resample has both label
    classes. Once both arms read the same complete support, their printed
    undefined sets equal the paired-difference undefined set. No suffix in
    a present BA row means zero, according to judge.py's print statement.
    """
    if "CAPABILITY ABSENT" in output or "FINDING " in output:
        raise HarnessError("INCOMPLETE: judge arms lack complete matched support or split tiers")
    if not re.search(r"^judge exit 0$", output, re.M):
        raise HarnessError("INCOMPLETE: frozen judge's success marker missing")
    population = re.findall(r"^population: (\d+) of (\d+) rows, (\d+) checkpoints, (\d+) scored verdicts", output, re.M)
    if len(population) != 1 or int(population[0][0]) == 0 or population[0][0] != population[0][1]:
        raise HarnessError("INCOMPLETE: judge's declared population was not fully read")
    current = None
    counts = {}
    active = False
    for line in output.splitlines():
        if line.startswith("BALANCED ACCURACY per arm x predicate:"):
            active = True
            continue
        if active and line.startswith("DIFF "):
            active = False
        if not active:
            continue
        if line.strip() in PREDS and line.startswith("  ") and not line.startswith("    "):
            current = line.strip()
            continue
        arm = re.match(r"^    (ARM|F0)\s+.*\braw\s+(\d+)/(\d+)\s+BA\s+", line)
        if arm:
            if current is None or (arm[1], current) in counts:
                raise HarnessError("INCOMPLETE: malformed or duplicate arm BA count row")
            undefined = re.search(r"\((\d+) resamples undefined\)", line)
            counts[(arm[1], current)] = {"undefined": int(undefined[1]) if undefined else 0,
                                         "total": int(arm[3])}
    result = {}
    diffs = re.findall(r"^DIFF BA\(ARM\) - BA\(F0\) (\w+):\s*(\S+) \[\s*(\S+),\s*(\S+)\](.*)$", output, re.M)
    for p, point, lower, upper, note in diffs:
        if p not in PREDS or p in result or note.strip():
            raise HarnessError("INCOMPLETE: unexpected difference roster or unmatched-arm note")
        a, b = counts.get(("ARM", p)), counts.get(("F0", p))
        if a is None or b is None or a != b or a["total"] == 0:
            raise HarnessError(f"INCOMPLETE: {p} has unmatched or empty arm support")
        result[p] = {"printed_point_difference": point, "printed_lower": lower,
                     "printed_upper": upper, "resamples_set_aside": a["undefined"],
                     "scored_verdicts_per_arm": a["total"],
                     "bound_print_precision": 4}
    if set(result) != set(PREDS):
        raise HarnessError("INCOMPLETE: missing predicate difference bound")
    return result


def run(destination, f0, out, population="union", candidate=None, choice=None):
    binaries = arms(f0, candidate)
    choice_sha = choice_hash(choice, binaries["ARM"], binaries["F0"])
    cmd = commands(destination, f0, candidate)[population]
    # Actual confirmation is order-gated above. The fixed-subject proof
    # passes the very same F0 recipe binary in both runtime-arm positions.
    env = {k: v for k, v in os.environ.items() if not k.startswith("EIGS_")}
    process = subprocess.run(cmd, capture_output=True, text=True, env=env)
    receipt = {"format": "r33-judge-proof/1", "choice_sha256": choice_sha,
               "command": cmd, "returncode": process.returncode,
               "population": population, "stdout_sha256": hashlib.sha256(process.stdout.encode()).hexdigest(),
               "stderr_sha256": hashlib.sha256(process.stderr.encode()).hexdigest()}
    if process.returncode:
        raise HarnessError(f"frozen judge exited {process.returncode}: {process.stderr[-1000:]}")
    receipt["bounds"] = printed_bounds(process.stdout)
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("stage", "commands", "run"))
    parser.add_argument("--stage", required=True)
    parser.add_argument("--f0", required=True)
    parser.add_argument("--candidate")
    parser.add_argument("--choice")
    parser.add_argument("--population", choices=("hcal", "union"), default="union")
    parser.add_argument("--out")
    args = parser.parse_args()
    if args.action == "stage":
        result = stage(args.stage, args.f0, args.candidate, args.choice)
    elif args.action == "commands":
        choice_sha = choice_hash(args.choice, args.candidate or args.f0, args.f0)
        result = {"choice_sha256": choice_sha, "commands": commands(args.stage, args.f0, args.candidate)}
    else:
        if args.out is None:
            parser.error("run requires --out")
        result = run(args.stage, args.f0, args.out, args.population, args.candidate, args.choice)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (HarnessError, OSError, ValueError) as error:
        print("R33_JUDGE_REFUSED: " + str(error), file=sys.stderr)
        raise SystemExit(2)
