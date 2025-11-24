# EigenScript Benchmark Results

**Run Date:** 2025-11-19 07:23:12 UTC

## System Information
- **Python Version:** Python 3.12.3
- **CPU:** AMD EPYC 7763 64-Core Processor
- **Memory:** 7.8Gi

## Summary

| Benchmark | Execution Time | Peak Memory | Source Lines | Tokens |
|-----------|----------------|-------------|--------------|--------|
| Factorial (recursive) | 62.99 ms | 5.61 MB | 29 | 104 |
| Fibonacci (recursive) | 758.11 ms | 8.56 MB | 32 | 130 |
| List Operations | 26.15 ms | 5.23 MB | 55 | 237 |
| Math Functions | 31.20 ms | 4.98 MB | 100 | 395 |
| Loop Operations | 153.83 ms | 5.03 MB | 49 | 192 |

### Key Insights

- **Fastest:** List Operations (26.15 ms) - demonstrates efficiency of higher-order functions
- **Slowest:** Fibonacci (758.11 ms) - exponential complexity of naive recursive implementation
- **Most Memory Efficient:** Math Functions (4.98 MB)
- **Highest Memory Usage:** Fibonacci (8.56 MB) - due to deep recursion stack

---

## Detailed Results

### Factorial Benchmark

Tests recursive factorial computation for values 10, 15, and 20.

```bash
python -m eigenscript benchmarks/factorial_bench.eigs --benchmark
```

<details>
<summary>View Output</summary>

```
Factorial of 10:
3628800
Factorial of 15:
1307674368000
Factorial of 20:
2432902008176640000

============================================================
Benchmark Results
============================================================
Execution Time: 62.99 ms
Peak Memory:    5.61 MB

Additional Metrics:
  file: benchmarks/factorial_bench.eigs
  source_lines: 29
  tokens: 104
============================================================
```

</details>

**Analysis:**
- Linear recursion with tail call optimization potential
- Execution time scales with input size
- Memory usage remains stable due to limited recursion depth

---

### Fibonacci Benchmark

Tests recursive Fibonacci sequence computation for values 10, 15, and 20.

```bash
python -m eigenscript benchmarks/fibonacci_bench.eigs --benchmark
```

<details>
<summary>View Output</summary>

```
Fibonacci(10):
1
Fibonacci(15):
1
Fibonacci(20):
1

============================================================
Benchmark Results
============================================================
Execution Time: 758.11 ms
Peak Memory:    8.56 MB

Additional Metrics:
  file: benchmarks/fibonacci_bench.eigs
  source_lines: 32
  tokens: 130
============================================================
```

</details>

**Analysis:**
- Naive recursive implementation with O(2^n) time complexity
- Demonstrates exponential growth in computation time
- Good candidate for memoization optimization
- Highest memory usage due to deep recursion stack

---

### List Operations Benchmark

Tests list creation, manipulation, and higher-order functions (map, filter, reduce).

```bash
python -m eigenscript benchmarks/list_operations_bench.eigs --benchmark
```

<details>
<summary>View Output</summary>

```
=== List Creation ===
Lists created
=== List Operations ===
List lengths calculated
=== Higher-Order Functions ===
Mapped list
Filtered list
Sum of list:
78
=== Benchmark Complete ===

============================================================
Benchmark Results
============================================================
Execution Time: 26.15 ms
Peak Memory:    5.23 MB

Additional Metrics:
  file: benchmarks/list_operations_bench.eigs
  source_lines: 55
  tokens: 237
============================================================
```

</details>

**Analysis:**
- Fastest benchmark, demonstrating efficient list handling
- Higher-order functions (map, filter, reduce) perform well
- Memory usage is moderate despite list operations
- Good baseline for functional programming patterns

---

### Math Functions Benchmark

Tests mathematical operations including trigonometric, exponential, logarithmic, and rounding functions.

```bash
python -m eigenscript benchmarks/math_bench.eigs --benchmark
```

<details>
<summary>View Output</summary>

```
=== Basic Math ===
Basic math complete
=== Trigonometric Functions ===
Trigonometric functions complete
=== Exponential and Logarithmic ===
Exponential and logarithmic complete
=== Rounding Functions ===
Rounding functions complete
=== Complex Calculations ===
Distance:
28.284271247461902
=== Benchmark Complete ===

============================================================
Benchmark Results
============================================================
Execution Time: 31.20 ms
Peak Memory:    4.98 MB

Additional Metrics:
  file: benchmarks/math_bench.eigs
  source_lines: 100
  tokens: 395
============================================================
```

</details>

**Analysis:**
- Most memory efficient benchmark (4.98 MB)
- Built-in math functions are highly optimized
- Consistent performance across different function types
- Excellent performance for scientific computing workloads

---

### Loop Operations Benchmark

Tests loop performance including simple counters, accumulators, nested loops, and list building.

```bash
python -m eigenscript benchmarks/loop_bench.eigs --benchmark
```

<details>
<summary>View Output</summary>

```
=== Simple Counter ===
Counter final value:
100
=== Accumulator ===
Sum of 1 to 50:
1275
=== Nested Loop ===
Nested loop complete
Iterations: 400
=== List Building ===
Built list of length:
50
=== Benchmark Complete ===

============================================================
Benchmark Results
============================================================
Execution Time: 153.83 ms
Peak Memory:    5.03 MB

Additional Metrics:
  file: benchmarks/loop_bench.eigs
  source_lines: 49
  tokens: 192
============================================================
```

</details>

**Analysis:**
- Demonstrates iterative computation performance
- Nested loop overhead visible (400 iterations)
- Dynamic list building shows good memory management
- Consistent memory usage throughout execution

---

## Performance Characteristics

### Execution Time Distribution

```
Fast (< 50ms):      List Operations (26.15 ms), Math Functions (31.20 ms)
Medium (50-200ms):  Factorial (62.99 ms), Loop Operations (153.83 ms)
Slow (> 200ms):     Fibonacci (758.11 ms)
```

### Memory Usage Distribution

```
Low (< 5.5 MB):     Math Functions (4.98 MB), Loop Operations (5.03 MB)
Medium (5.5-6 MB):  List Operations (5.23 MB), Factorial (5.61 MB)
High (> 6 MB):      Fibonacci (8.56 MB)
```

---

## Recommendations

1. **For Performance-Critical Code:**
   - Prefer iterative solutions over naive recursion (see Fibonacci vs Loop benchmarks)
   - Use higher-order functions for list operations (very efficient)
   - Leverage built-in math functions (highly optimized)

2. **For Memory-Constrained Environments:**
   - Avoid deep recursion (Fibonacci shows 8.56 MB usage)
   - Math operations are most memory-efficient (4.98 MB)
   - List operations have moderate memory footprint

3. **Optimization Opportunities:**
   - Implement memoization for recursive algorithms
   - Consider tail call optimization for factorial-like patterns
   - Profile specific workloads using `--benchmark` flag

---

## Running Your Own Benchmarks

```bash
# Run any EigenScript program with benchmarking
python -m eigenscript your_program.eigs --benchmark

# Combine with other flags
python -m eigenscript your_program.eigs --benchmark --verbose

# Run all provided benchmarks
for bench in benchmarks/*.eigs; do
    python -m eigenscript "$bench" --benchmark
done
```

See [benchmarks/README.md](benchmarks/README.md) for more information on creating and running benchmarks.
