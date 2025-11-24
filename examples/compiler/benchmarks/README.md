# EigenScript Performance Benchmarks

## Overview

This directory contains performance benchmarks comparing LLVM-compiled EigenScript against the Python interpreter baseline.

## Running Benchmarks

```bash
cd eigenscript-compiler/examples/benchmarks
python3 run_benchmarks.py
```

## Benchmark Results

### Summary
- **Arithmetic-heavy code**: **3-7x speedup** (Factorial: 4-7x, Sum: 3-6x depending on run)
- **Function-heavy code**: **6-7x slowdown** (Fibonacci with deep recursion)
- **Overall average (excluding slowdowns)**: **~5x speedup**

### Detailed Results

Measured across multiple benchmark runs (timing varies ±20% due to system load):

| Benchmark | Description | LLVM Time | Python Time | Result Range |
|-----------|-------------|-----------|-------------|--------------|
| Factorial(10) | Arithmetic + recursion | 10-18ms | 68-78ms | **4-7x faster** |
| Sum(100) | Tail recursion | 17-18ms | 69-97ms | **3-6x faster** |
| Fibonacci(25) | Heavy recursion | 570-590ms | 82-96ms | **6-7x slower** |

## Performance Characteristics

### Where LLVM Excels
- **Arithmetic operations**: Direct hardware instructions vs Python interpreter overhead
- **Simple recursion**: Efficient function calls with LLVM optimization
- **Tight loops**: When implemented (future work)

### Geometric Tracking Overhead
EigenScript's unique feature is **geometric self-awareness** - every computation tracks convergence, curvature, and stability. This adds overhead:

- Each value wrapped in `EigenValue` struct (4 fields: value, gradient, stability, iteration)
- Function calls create/destroy EigenValues for arguments and returns
- ~2x `eigen_create` calls per recursive function call

This overhead is **the price of self-awareness**. Programs gain the ability to interrogate their own execution state (`what is x`, `why is x improving`, `has x converged`), but with runtime cost.

### Optimization Opportunities
Future work can reduce overhead by:
1. **Stack allocation** instead of malloc for EigenValues
2. **Lazy tracking** - only track when interrogated
3. **LLVM optimization passes** - inline, constant folding, dead code elimination
4. **Escape analysis** - eliminate unnecessary allocations

## Benchmark Programs

### fibonacci.eigs
```eigenscript
define fib as:
    if n < 2:
        return n
    else:
        a is fib of (n - 1)
        b is fib of (n - 2)
        return a + b

result is fib of 25
print of result
```

### loops.eigs (Sum)
```eigenscript
define sum_to as:
    if n < 1:
        return 0
    else:
        prev is sum_to of (n - 1)
        return prev + n

result is sum_to of 100
print of result
```

### primes.eigs (Factorial)
```eigenscript
define factorial as:
    if n < 2:
        return 1
    else:
        prev is factorial of (n - 1)
        return n * prev

result is factorial of 10
print of result
```

## Comparison with Python

The Python interpreter is **highly optimized** for recursive Python code, with:
- Bytecode caching
- Stack frame optimization
- Native C implementation

Our LLVM backend generates **unoptimized** code in this alpha release. With LLVM's optimization pipeline enabled, we expect significant improvements.

## Future Work
- Enable LLVM `-O2`/`-O3` optimization passes
- Implement real loops (not just recursion)
- Add memoization for recursive functions
- Reduce EigenValue allocation overhead
- Benchmark against other compiled languages (C, Rust)
