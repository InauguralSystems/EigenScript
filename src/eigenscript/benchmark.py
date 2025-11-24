"""
Benchmarking utilities for EigenScript.

Provides tools to measure and report performance metrics including:
- Execution time
- Memory usage
- Operation count
"""

import time
import tracemalloc
from typing import Dict, Any, Optional, Callable
from dataclasses import dataclass, field


@dataclass
class BenchmarkResult:
    """Container for benchmark results."""

    execution_time: float  # seconds
    peak_memory: int  # bytes
    operations: int = 0
    success: bool = True
    error: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)

    def format_time(self) -> str:
        """Format execution time in appropriate units."""
        if self.execution_time < 0.001:
            return f"{self.execution_time * 1_000_000:.2f} µs"
        elif self.execution_time < 1:
            return f"{self.execution_time * 1000:.2f} ms"
        else:
            return f"{self.execution_time:.4f} s"

    def format_memory(self) -> str:
        """Format memory usage in appropriate units."""
        if self.peak_memory < 1024:
            return f"{self.peak_memory} B"
        elif self.peak_memory < 1024 * 1024:
            return f"{self.peak_memory / 1024:.2f} KB"
        else:
            return f"{self.peak_memory / (1024 * 1024):.2f} MB"

    def __str__(self) -> str:
        """Format benchmark results for display."""
        lines = [
            "=" * 60,
            "Benchmark Results",
            "=" * 60,
            f"Execution Time: {self.format_time()}",
            f"Peak Memory:    {self.format_memory()}",
        ]

        if self.operations > 0:
            lines.append(f"Operations:     {self.operations:,}")

        if not self.success and self.error:
            lines.append(f"\nError: {self.error}")

        if self.metadata:
            lines.append("\nAdditional Metrics:")
            for key, value in self.metadata.items():
                lines.append(f"  {key}: {value}")

        lines.append("=" * 60)
        return "\n".join(lines)


class Benchmark:
    """Benchmarking context manager for measuring performance."""

    def __init__(self, track_memory: bool = True):
        """
        Initialize benchmark.

        Args:
            track_memory: Whether to track memory usage (adds small overhead)
        """
        self.track_memory = track_memory
        self.start_time: float = 0
        self.end_time: float = 0
        self.peak_memory: int = 0
        self.operations: int = 0
        self.metadata: Dict[str, Any] = {}
        self.success: bool = True
        self.error: Optional[str] = None

    def __enter__(self) -> "Benchmark":
        """Start benchmarking."""
        self.start_time = time.perf_counter()
        if self.track_memory:
            tracemalloc.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Stop benchmarking and collect results."""
        self.end_time = time.perf_counter()

        if self.track_memory:
            current, peak = tracemalloc.get_traced_memory()
            tracemalloc.stop()
            self.peak_memory = peak

        if exc_type is not None:
            self.success = False
            self.error = f"{exc_type.__name__}: {exc_val}"

    def get_result(self) -> BenchmarkResult:
        """Get benchmark results."""
        return BenchmarkResult(
            execution_time=self.end_time - self.start_time,
            peak_memory=self.peak_memory,
            operations=self.operations,
            success=self.success,
            error=self.error,
            metadata=self.metadata,
        )

    def add_metadata(self, key: str, value: Any):
        """Add custom metadata to benchmark."""
        self.metadata[key] = value

    def increment_operations(self, count: int = 1):
        """Increment operation counter."""
        self.operations += count


def benchmark_function(
    func: Callable,
    *args,
    iterations: int = 1,
    warmup: int = 0,
    track_memory: bool = True,
    **kwargs,
) -> BenchmarkResult:
    """
    Benchmark a function with multiple iterations.

    Args:
        func: Function to benchmark
        *args: Positional arguments for function
        iterations: Number of times to run the function
        warmup: Number of warmup runs (not measured)
        track_memory: Whether to track memory usage
        **kwargs: Keyword arguments for function

    Returns:
        BenchmarkResult with aggregated metrics
    """
    # Warmup runs
    for _ in range(warmup):
        try:
            func(*args, **kwargs)
        except Exception:
            pass

    # Benchmark runs
    total_time = 0
    max_memory = 0
    all_success = True
    last_error = None

    for _ in range(iterations):
        with Benchmark(track_memory=track_memory) as bench:
            try:
                func(*args, **kwargs)
            except Exception as e:
                all_success = False
                last_error = str(e)

        result = bench.get_result()
        total_time += result.execution_time
        max_memory = max(max_memory, result.peak_memory)

        if not result.success:
            all_success = False
            last_error = result.error

    avg_time = total_time / iterations

    return BenchmarkResult(
        execution_time=avg_time,
        peak_memory=max_memory,
        operations=0,
        success=all_success,
        error=last_error,
        metadata={
            "iterations": iterations,
            "total_time": total_time,
            "warmup_runs": warmup,
        },
    )


def compare_benchmarks(results: Dict[str, BenchmarkResult]) -> str:
    """
    Compare multiple benchmark results.

    Args:
        results: Dictionary mapping names to benchmark results

    Returns:
        Formatted comparison string
    """
    if not results:
        return "No results to compare"

    lines = [
        "=" * 80,
        "Benchmark Comparison",
        "=" * 80,
        f"{'Name':<30} {'Time':<15} {'Memory':<15} {'Status':<10}",
        "-" * 80,
    ]

    # Sort by execution time
    sorted_results = sorted(results.items(), key=lambda x: x[1].execution_time)

    for name, result in sorted_results:
        status = "✓ OK" if result.success else "✗ FAIL"
        lines.append(
            f"{name:<30} {result.format_time():<15} "
            f"{result.format_memory():<15} {status:<10}"
        )

    # Find fastest
    if len(sorted_results) > 1:
        fastest = sorted_results[0]
        lines.append("-" * 80)
        lines.append(f"Fastest: {fastest[0]}")

        # Calculate relative performance
        for name, result in sorted_results[1:]:
            if result.success and fastest[1].success:
                speedup = result.execution_time / fastest[1].execution_time
                lines.append(f"  {name} is {speedup:.2f}x slower")

    lines.append("=" * 80)
    return "\n".join(lines)
