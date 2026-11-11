#!/usr/bin/env python3
"""R33-1 addendum 3: report a named binary without admitting it to the choice.

The frozen scorer owns the capability probes, emission, parsing and tier
witnesses. Its measure is called once per row, just as judge.run_arms does.
Only interp/straight supplies verdicts; other tiers are reported diagnostics.
No source from either frozen program is copied here.
"""
import argparse
import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys

from gen import HarnessError
import r33_metrics as M
import r33_population as P
from r33_port import POLICIES
from schema import PREDS
import score

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SUBJECTS = {
    "INC47": {"commit": "3d8a14b49e88a59a37e1d3501891afe2d430ffcb", "recipe": "tools/observer_oracle/build_arm.sh"},
    "ANCHOR": {"commit": "4a3a5c1941568e9bc562c7c8221cff22dc8ba697",
               "recipe": "tools/observer_oracle/build_anchor.sh"},
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def old_method_command(binary, root=ROOT, python=sys.executable):
    """The scorer as a program on the canonical corpus, without added gates.

    --floor is a floor gate, --expect demands capabilities and --declared
    waives wrong capability verdicts. None is requested for this old-method
    report. The frozen scorer's complete output and exit are retained.
    """
    root = Path(root)
    return [str(python), "-I", str(root / "tools/observer_oracle/score.py"),
            str(binary), "--corpus", str(root / "tools/observer_oracle/corpus.json")]


def run_old_method(name, binary, output, root=ROOT, python=sys.executable):
    """Later-turn program path. Never invoked by the instrument selftest."""
    if name in POLICIES and name != "F0":
        raise M.Incomplete("REFUSED: old-method subjects are F0 or named binary references")
    command = old_method_command(binary, root, python)
    result = score.run_group(command, 3600, env=score.scrubbed({}))
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "stdout.txt").write_text(result.stdout)
    (output / "stderr.txt").write_text(result.stderr)
    receipt = {"format": "r33-old-method/1", "subject": name, "command": command,
               "returncode": result.returncode, "stdout_sha256": digest(output / "stdout.txt"),
               "stderr_sha256": digest(output / "stderr.txt"),
               "status": "REPORTED" if result.returncode == 0 else "REFUSED_BY_FROZEN_SCORER"}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def read_binary(name, binary, sets, scorer=score):
    """Read explicit row dictionaries. No populations are opened by this API.

    cannot_run has only the three cases in addendum 3 ruling 2. Missing
    interpreter keys after a successful measure are a harness error, not a
    fourth exclusion. A probe failure is attached to every declared row.
    """
    if not isinstance(name, str) or not name or name in POLICIES:
        raise M.Incomplete("REFUSED: binary subject name must be outside the eleven policies")
    declared = [(set_name, row) for set_name, corpus in sets.items() for row in corpus["rows"]]
    M.nonempty(declared, "binary subject declared rows")
    records, cannot_run = [], []
    diagnostics = {"capabilities": None, "probes": None, "probe_error": None,
                   "probe_printed": "", "row_printed": [], "tier_splits": [],
                   "vacuous": [], "unwitnessed_jit": [], "witness_error": None,
                   "runs": 0, "rows_read": 0, "rows_declared": len(declared)}
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed), contextlib.redirect_stderr(printed):
            ieee, caps, probes = scorer.capabilities(str(binary))
        diagnostics.update(ieee=ieee, capabilities=caps, probes=probes)
    except Exception as exc:
        reason = f"{type(exc).__name__}: {exc}"
        diagnostics.update(probe_error=reason, probe_printed=printed.getvalue())
        cannot_run = [dict(set=set_name, row=row["id"], kind="capability_probe_raised", reason=reason)
                      for set_name, row in declared]
        return {"format": "r33-binary-readings/1", "subject": name, "readings": records,
                "cannot_run": cannot_run, "diagnostics": diagnostics}
    diagnostics["probe_printed"] = printed.getvalue()
    witness = {"wit": {}}
    for set_name, row in declared:
        cap = row.get("capability")
        if cap and not caps[cap]:
            reason = f"capability probe skips {cap}: " + json.dumps(probes, sort_keys=True)
            cannot_run.append(dict(set=set_name, row=row["id"], kind="capability_skip", reason=reason))
            continue
        printed = io.StringIO()
        try:
            with contextlib.redirect_stdout(printed), contextlib.redirect_stderr(printed):
                result = scorer.measure(str(binary), {"rows": [row]}, caps)
        except Exception as exc:
            reason = f"{type(exc).__name__}: {exc}"
            cannot_run.append(dict(set=set_name, row=row["id"], kind="measure_raised", reason=reason))
            diagnostics["row_printed"].append(dict(set=set_name, row=row["id"], printed=printed.getvalue(),
                                                   error=reason))
            continue
        diagnostics["row_printed"].append(dict(set=set_name, row=row["id"], printed=printed.getvalue()))
        if result["skipped"]:
            # A successful preflight and measure disagreeing about its skip
            # rule is an instrument fault, never another binary exclusion.
            raise M.Incomplete(f"INCOMPLETE: scorer unexpectedly skipped {set_name}/{row['id']}")
        got = {(at, pred): value for (tier, form, _rid, at, pred), value in result["read"].items()
               if (tier, form) == ("interp", "straight")}
        expected = {(at, pred) for at in row["checkpoints"] for pred in PREDS}
        if set(got) != expected or any(type(value) is not bool for value in got.values()):
            raise M.Incomplete(f"INCOMPLETE: binary interpreter readings missing/extra/malformed for {set_name}/{row['id']}")
        for at in row["checkpoints"]:
            records.append(dict(arm=name, set=set_name, row=row["id"], at=at,
                                predicates={pred: got[at, pred] for pred in PREDS}))
        diagnostics["rows_read"] += 1
        diagnostics["runs"] += result["runs"]
        witness["wit"].update({(tier, f"{set_name}/{rid}", at): value
                               for (tier, rid, at), value in result["wit"].items()})
        diagnostics["tier_splits"].extend(dict(set=set_name, key=list(key), readings=values)
                                             for key, values in scorer.findings(result))
    diagnostics["vacuous"] = [dict(key=list(key), status=value[0], detail=value[1])
                               for key, value in witness["wit"].items() if value[0] == "VACUOUS"]
    diagnostics["unwitnessed_jit"] = [tier for tier in ("jit", "osr")
                                      if not any(key[0] == tier and value[0] == "native"
                                                 for key, value in witness["wit"].items())]
    if records:
        try:
            scorer.check_witnessed(witness)
        except Exception as exc:
            diagnostics["witness_error"] = f"{type(exc).__name__}: {exc}"
    return {"format": "r33-binary-readings/1", "subject": name, "readings": records,
            "cannot_run": cannot_run, "diagnostics": diagnostics}


def verify_reference(name, binary):
    """Check that the named reference still is its recipe-built subject."""
    if name not in SUBJECTS:
        raise M.Incomplete("REFUSED: binary reference must be INC47 or ANCHOR")
    binary = Path(binary).resolve()
    specification = SUBJECTS[name]
    stamp_name = "anchor.json" if name == "ANCHOR" else "arm.json"
    stamp = json.loads((binary.parents[2] / stamp_name).read_text())
    commit = stamp.get("commit") if name == "ANCHOR" else stamp.get("source_sha")
    recipe = stamp.get("recipe_sha256") if name == "ANCHOR" else stamp.get("recipe_id")
    if (commit != specification["commit"]
            or recipe != digest(ROOT / specification["recipe"])
            or digest(binary) != stamp.get("binary_sha256")):
        raise M.Incomplete("REFUSED: binary reference differs from its declared recipe/commit/stamp")
    return stamp


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subject", choices=SUBJECTS, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        import r33_identity as I
        I.verify_manifest(args.manifest)
        stamp = verify_reference(args.subject, args.binary)
        if args.data.resolve() != (HERE / "r33_data/populations").resolve():
            raise M.Incomplete("REFUSED: data directory differs from sealed population root")
        sets = {f"cal/{scale}": P.load_set(args.data / "cal" / scale)[0]
                for scale in ("x1", "x1e-3", "x1e3")}
        canonical = P.load_set(HERE)[0]
        counter = next(row for row in canonical["rows"] if row["id"] == "int64_count")
        sets["counter/x1"] = {"rows": [counter]}
        result = read_binary(args.subject, args.binary, sets)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in result.pop("readings")))
        result.update(manifest_sha256=digest(args.manifest), stamp=stamp,
                      readings_sha256=digest(args.out), binary_sha256=digest(args.binary))
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"status": "READINGS_ONLY", "subject": args.subject,
                          "rows_read": result["diagnostics"]["rows_read"],
                          "cannot_run": len(result["cannot_run"]), "receipt": str(args.receipt)}, sort_keys=True))
        return 0
    except (M.Incomplete, HarnessError, OSError, ValueError, KeyError, TypeError) as exc:
        print(json.dumps({"status": "REFUSED", "reason": str(exc)}, sort_keys=True))
        return 2


if __name__ == "__main__":
    sys.exit(main())
