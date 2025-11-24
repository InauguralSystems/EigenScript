#!/usr/bin/env python3
"""
EigenScript Performance Benchmark Suite
Compares LLVM-compiled EigenScript vs Python interpreter
"""

import subprocess
import time
import sys
import os

BENCHMARKS = [
    ("fibonacci", "Fibonacci(25) - Heavy recursion"),
    ("loops", "Sum(100) - Tail recursion"),
    ("primes", "Factorial(10) - Arithmetic"),
]


def compile_eigenscript(source_file):
    """Compile .eigs to executable using LLVM backend"""
    compiler = os.path.join(os.path.dirname(__file__), "../../cli/compile.py")
    result = subprocess.run(
        ["python3", compiler, source_file, "--exec"], capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"Compilation failed: {result.stderr}")
        return None

    base = os.path.splitext(source_file)[0]
    return f"{base}.exe"


def benchmark_program(cmd, runs=3):
    """Run program multiple times and return average execution time"""
    times = []

    for _ in range(runs):
        start = time.perf_counter()
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        end = time.perf_counter()

        if result.returncode != 0:
            print(f"  ✗ Execution failed: {result.stderr}")
            return None

        times.append(end - start)

    return sum(times) / len(times)


def main():
    print("=" * 70)
    print("EigenScript Performance Benchmarks")
    print("LLVM-Compiled vs Python Interpreter")
    print("=" * 70)
    print()

    results = []

    for bench_name, description in BENCHMARKS:
        print(f"📊 {description}")
        print(f"   Benchmark: {bench_name}")
        print()

        eigs_file = f"{bench_name}.eigs"
        py_file = f"{bench_name}.py"

        if not os.path.exists(eigs_file):
            print(f"  ⚠ Skipping: {eigs_file} not found")
            continue

        if not os.path.exists(py_file):
            print(f"  ⚠ Skipping: {py_file} not found")
            continue

        print(f"  → Compiling {eigs_file}...")
        exe_file = compile_eigenscript(eigs_file)
        if not exe_file:
            print(f"  ✗ Compilation failed")
            continue

        print(f"  → Running LLVM-compiled version...")
        llvm_time = benchmark_program([f"./{exe_file}"])

        print(f"  → Running Python interpreter...")
        python_time = benchmark_program(["python3", py_file])

        if llvm_time and python_time:
            speedup = python_time / llvm_time
            results.append(
                {
                    "name": bench_name,
                    "desc": description,
                    "llvm": llvm_time,
                    "python": python_time,
                    "speedup": speedup,
                }
            )

            print(f"\n  ✅ Results:")
            print(f"     LLVM:   {llvm_time*1000:.2f} ms")
            print(f"     Python: {python_time*1000:.2f} ms")
            if speedup >= 1.0:
                print(f"     Speedup: {speedup:.1f}x faster")
            else:
                slowdown = 1.0 / speedup
                print(f"     Slowdown: {slowdown:.1f}x slower")

        print()
        print("-" * 70)
        print()

    if results:
        print("=" * 70)
        print("SUMMARY")
        print("=" * 70)
        print()
        for r in results:
            print(f"  {r['desc']}")
            if r["speedup"] >= 1.0:
                print(
                    f"    {r['speedup']:.1f}x speedup (LLVM: {r['llvm']*1000:.1f}ms, Python: {r['python']*1000:.1f}ms)"
                )
            else:
                slowdown = 1.0 / r["speedup"]
                print(
                    f"    {slowdown:.1f}x slower (LLVM: {r['llvm']*1000:.1f}ms, Python: {r['python']*1000:.1f}ms)"
                )

        fast_results = [r for r in results if r["speedup"] >= 1.0]
        if fast_results:
            avg_speedup = sum(r["speedup"] for r in fast_results) / len(fast_results)
            print()
            print(
                f"  Average speedup (excluding slower cases): {avg_speedup:.1f}x faster"
            )
        print()


if __name__ == "__main__":
    main()
