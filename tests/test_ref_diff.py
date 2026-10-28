#!/usr/bin/env python3
"""Fast determinism and planted-output-fault checks for ref_diff."""
from pathlib import Path
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("generator", ROOT / "tools/ref_program_gen.py")
generator = importlib.util.module_from_spec(spec); spec.loader.exec_module(generator)


def main():
    expected = "4dba6d6257dd08f0b579119c2e0fbb9267e770b2803b46192e549f0cc2e44a91"
    import hashlib
    got = hashlib.sha256(generator.program(2018).encode()).hexdigest()
    assert got == expected, (got, expected)
    print("PASS: seed 2018 generator output is byte-pinned")
    vm = ROOT / "src/eigenscript"; ref = ROOT / "spec/lean/.lake/build/bin/eigs-ref"
    if not vm.exists() or not ref.exists():
        print("SKIP: ref-diff planted fault needs built C and Lean executables"); return
    with tempfile.TemporaryDirectory(prefix="ref-diff-selftest-") as raw:
        d = Path(raw); mutant = d / "eigs-ref"
        # Clean control first.
        clean_report = d / "clean.json"
        clean = subprocess.run([ROOT / "tools/ref_diff.sh", "--generated", "1", "--seed-start", "4", "--report", clean_report], capture_output=True, text=True)
        assert clean.returncode == 0, clean.stdout + clean.stderr
        real = shutil.copy2(ref, d / "eigs-ref.real")
        mutant.write_text("#!/bin/sh\ncase \"${1:-}\" in --classify*) exec \"$0.real\" \"$@\";; esac\nout=$(\"$0.real\" \"$@\"); rc=$?; printf 'X%s' \"$out\"; exit $rc\n")
        mutant.chmod(0o755)
        bad_report = d / "bad.json"
        bad = subprocess.run([ROOT / "tools/ref_diff.sh", "--generated", "1", "--seed-start", "4", "--ref", mutant, "--report", bad_report], capture_output=True, text=True)
        data = json.loads(bad_report.read_text())
        assert bad.returncode == 1 and "generated:4" in bad.stderr
        assert data["summary"]["disagreements"] == 1
        assert any("stdout" in x for x in data["programs"][0]["reasons"])
    print("PASS: one-byte reference-output plant is detected and names generated:4")


if __name__ == "__main__": main()
