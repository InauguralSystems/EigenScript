# EigenScript Benchmarks

This directory contains benchmark scripts for measuring EigenScript performance.

📊 **See [BENCHMARK_RESULTS.md](../BENCHMARK_RESULTS.md) for detailed benchmark results and analysis.**

## Running Benchmarks

To run a benchmark, use the `--benchmark` or `-b` flag:

```bash
python -m eigenscript benchmarks/factorial_bench.eigs --benchmark
```

## Available Benchmarks

| Benchmark | Description | Execution Time | Peak Memory |
|-----------|-------------|----------------|-------------|
| `factorial_bench.eigs` | Recursive factorial computation | 62.99 ms | 5.61 MB |
| `fibonacci_bench.eigs` | Recursive Fibonacci sequence | 758.11 ms | 8.56 MB |
| `list_operations_bench.eigs` | List manipulation and higher-order functions | 26.15 ms | 5.23 MB |
| `math_bench.eigs` | Mathematical functions performance | 31.20 ms | 4.98 MB |
| `loop_bench.eigs` | Loop and iteration performance | 153.83 ms | 5.03 MB |

*Results from Python 3.12.3 on AMD EPYC 7763 64-Core Processor. See [BENCHMARK_RESULTS.md](../BENCHMARK_RESULTS.md) for details.*

## Benchmark Output

The benchmark flag provides:
- **Execution Time**: Total time to run the program
- **Peak Memory**: Maximum memory used during execution
- **Source Lines**: Number of lines in the source file
- **Tokens**: Number of tokens parsed

## Tips

1. Run multiple times to account for variance
2. Use larger inputs for more stable timing measurements
3. Compare similar algorithms to evaluate performance trade-offs
4. Consider using `--verbose` for additional execution details
