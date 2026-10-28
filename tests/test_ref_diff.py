#!/usr/bin/env python3
"""Fast determinism and planted-output-fault checks for ref_diff."""
from pathlib import Path
import importlib.util
import json
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
    population = hashlib.sha256()
    for seed in range(1, 1001):
        population.update(generator.program(seed).encode())
    expected_population = "36dc6447f428dc47b08b20790c009c69377533eeaab6e0b0eea329c32206421f"
    assert population.hexdigest() == expected_population
    print("PASS: seeds 1..1000 generator sources retain their pre-review sha256")
    vm = ROOT / "src/eigenscript"; ref = ROOT / "spec/lean/.lake/build/bin/eigs-ref"
    if not vm.exists() or not ref.exists():
        print("SKIP: ref-diff planted fault needs built C and Lean executables"); return
    with tempfile.TemporaryDirectory(prefix="ref-diff-selftest-") as raw:
        d = Path(raw); mutant = d / "eigs-ref"
        # Clean control first.
        clean_report = d / "clean.json"
        clean = subprocess.run([ROOT / "tools/ref_diff.sh", "--generated", "1", "--seed-start", "4", "--report", clean_report], capture_output=True, text=True)
        assert clean.returncode == 0, clean.stdout + clean.stderr
        shutil.copy2(ref, d / "eigs-ref.real")
        mutant.write_text("#!/bin/sh\ncase \"${1:-}\" in --classify*) exec \"$0.real\" \"$@\";; esac\nout=$(\"$0.real\" \"$@\"); rc=$?; printf 'X%s' \"$out\"; exit $rc\n")
        mutant.chmod(0o755)
        bad_report = d / "bad.json"
        bad = subprocess.run([ROOT / "tools/ref_diff.sh", "--generated", "1", "--seed-start", "4", "--ref", mutant, "--report", bad_report], capture_output=True, text=True)
        data = json.loads(bad_report.read_text())
        assert bad.returncode == 1 and "generated:4" in bad.stderr
        assert data["summary"]["disagreements"] == 1
        assert any("stdout" in x for x in data["programs"][0]["reasons"])
        print("PASS: one-byte reference-output plant is detected and names generated:4")

        # Clean native control: the shared thunk-exit predicate must witness
        # the JIT arm, and must retain the OSR last-iteration qualification.
        native_report = d / "native.json"
        native = subprocess.run([ROOT / "tools/ref_diff.sh", "--generated", "0", "--hot", "1",
                                 "--report", native_report], capture_output=True, text=True)
        native_data = json.loads(native_report.read_text())
        assert native.returncode == 0, native.stdout + native.stderr
        assert native_data["programs"][0]["tiers"]["jit"]["native"] == "native"
        assert native_data["programs"][0]["tiers"]["osr"]["native"] == "native (last iteration only, #1768)"
        print("PASS: native twin witnesses jit and qualifies the OSR last iteration")

        # The interpreted twin must not turn the hot arm green.
        fake_vm = d / "eigenscript-interpreted"
        fake_vm.write_text(f'#!/bin/sh\nEIGS_JIT_OFF=1; export EIGS_JIT_OFF\nexec "{vm}" "$@"\n')
        fake_vm.chmod(0o755)
        interpreted_report = d / "interpreted.json"
        interpreted = subprocess.run([ROOT / "tools/ref_diff.sh", "--generated", "0", "--hot", "1",
                                      "--vm", fake_vm, "--report", interpreted_report], capture_output=True, text=True)
        interpreted_data = json.loads(interpreted_report.read_text())
        assert interpreted.returncode == 1
        assert all(any("native execution not witnessed" in reason for reason in row["reasons"])
                   for row in interpreted_data["programs"])
        print("PASS: interpreted-native plant is red as actual native execution is not witnessed")

        hanging_vm = d / "eigenscript-hang"
        hanging_vm.write_text("#!/bin/sh\nsleep 5\n")
        hanging_vm.chmod(0o755)
        timeout_report = d / "timeout.json"
        hung = subprocess.run([ROOT / "tools/ref_diff.sh", "--generated", "1", "--seed-start", "4",
                               "--vm", hanging_vm, "--timeout", "0.05", "--report", timeout_report],
                              capture_output=True, text=True)
        timeout_data = json.loads(timeout_report.read_text())
        assert hung.returncode == 1 and timeout_report.exists()
        assert timeout_data["programs"][0]["program"] == "generated:4"
        assert timeout_data["programs"][0]["reasons"] == ["C-record arm timeout after 0.05s"]
        print("PASS: hanging C-record arm is labelled, report is written, and exit is 1")


if __name__ == "__main__": main()
