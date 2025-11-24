"""
Tests for benchmark module.
"""

import pytest
import time
from eigenscript.benchmark import (
    Benchmark,
    BenchmarkResult,
    benchmark_function,
    compare_benchmarks,
)


class TestBenchmarkResult:
    """Test BenchmarkResult class."""

    def test_format_time_microseconds(self):
        """Test time formatting for microseconds."""
        result = BenchmarkResult(execution_time=0.0001, peak_memory=1024)
        assert "µs" in result.format_time()
        assert "100.00" in result.format_time()

    def test_format_time_milliseconds(self):
        """Test time formatting for milliseconds."""
        result = BenchmarkResult(execution_time=0.1, peak_memory=1024)
        assert "ms" in result.format_time()
        assert "100.00" in result.format_time()

    def test_format_time_seconds(self):
        """Test time formatting for seconds."""
        result = BenchmarkResult(execution_time=1.5, peak_memory=1024)
        assert "s" in result.format_time()
        assert "1.5" in result.format_time()

    def test_format_memory_bytes(self):
        """Test memory formatting for bytes."""
        result = BenchmarkResult(execution_time=0.1, peak_memory=512)
        assert "512 B" == result.format_memory()

    def test_format_memory_kilobytes(self):
        """Test memory formatting for kilobytes."""
        result = BenchmarkResult(execution_time=0.1, peak_memory=2048)
        assert "KB" in result.format_memory()

    def test_format_memory_megabytes(self):
        """Test memory formatting for megabytes."""
        result = BenchmarkResult(execution_time=0.1, peak_memory=2 * 1024 * 1024)
        assert "MB" in result.format_memory()

    def test_str_success(self):
        """Test string representation for successful benchmark."""
        result = BenchmarkResult(
            execution_time=0.5,
            peak_memory=1024 * 1024,
            operations=100,
            success=True,
        )
        output = str(result)
        assert "Benchmark Results" in output
        assert "Execution Time:" in output
        assert "Peak Memory:" in output
        assert "Operations:" in output
        assert "100" in output

    def test_str_error(self):
        """Test string representation for failed benchmark."""
        result = BenchmarkResult(
            execution_time=0.5,
            peak_memory=1024,
            success=False,
            error="Test error",
        )
        output = str(result)
        assert "Error: Test error" in output

    def test_str_with_metadata(self):
        """Test string representation with metadata."""
        result = BenchmarkResult(
            execution_time=0.5,
            peak_memory=1024,
            metadata={"iterations": 10, "warmup": 2},
        )
        output = str(result)
        assert "Additional Metrics:" in output
        assert "iterations: 10" in output
        assert "warmup: 2" in output


class TestBenchmark:
    """Test Benchmark context manager."""

    def test_basic_timing(self):
        """Test basic timing functionality."""
        with Benchmark(track_memory=False) as bench:
            time.sleep(0.01)  # Sleep for 10ms

        result = bench.get_result()
        assert result.execution_time >= 0.01
        assert result.execution_time < 0.1
        assert result.success

    def test_memory_tracking(self):
        """Test memory tracking."""
        with Benchmark(track_memory=True) as bench:
            # Allocate some memory
            data = [0] * 10000

        result = bench.get_result()
        assert result.peak_memory > 0

    def test_no_memory_tracking(self):
        """Test with memory tracking disabled."""
        with Benchmark(track_memory=False) as bench:
            data = [0] * 10000

        result = bench.get_result()
        assert result.peak_memory == 0

    def test_operations_counter(self):
        """Test operation counter."""
        with Benchmark(track_memory=False) as bench:
            for i in range(10):
                bench.increment_operations()

        result = bench.get_result()
        assert result.operations == 10

    def test_operations_counter_with_count(self):
        """Test operation counter with custom count."""
        with Benchmark(track_memory=False) as bench:
            bench.increment_operations(5)
            bench.increment_operations(3)

        result = bench.get_result()
        assert result.operations == 8

    def test_metadata(self):
        """Test metadata addition."""
        with Benchmark(track_memory=False) as bench:
            bench.add_metadata("test_key", "test_value")
            bench.add_metadata("count", 42)

        result = bench.get_result()
        assert result.metadata["test_key"] == "test_value"
        assert result.metadata["count"] == 42

    def test_exception_handling(self):
        """Test exception handling."""
        with pytest.raises(ValueError):
            with Benchmark(track_memory=False) as bench:
                raise ValueError("Test error")

        result = bench.get_result()
        assert not result.success
        assert "ValueError" in result.error


class TestBenchmarkFunction:
    """Test benchmark_function utility."""

    def dummy_function(self, x):
        """Dummy function for testing."""
        return x * 2

    def slow_function(self):
        """Slow function for testing."""
        time.sleep(0.01)
        return 42

    def failing_function(self):
        """Function that raises an error."""
        raise RuntimeError("Test failure")

    def test_single_iteration(self):
        """Test benchmarking with single iteration."""
        result = benchmark_function(
            self.dummy_function, 5, iterations=1, track_memory=False
        )
        assert result.success
        assert result.execution_time > 0
        assert result.metadata["iterations"] == 1

    def test_multiple_iterations(self):
        """Test benchmarking with multiple iterations."""
        result = benchmark_function(
            self.dummy_function, 10, iterations=5, track_memory=False
        )
        assert result.success
        assert result.metadata["iterations"] == 5
        assert result.metadata["total_time"] > 0

    def test_with_warmup(self):
        """Test benchmarking with warmup runs."""
        result = benchmark_function(
            self.slow_function,
            iterations=2,
            warmup=1,
            track_memory=False,
        )
        assert result.success
        assert result.metadata["warmup_runs"] == 1

    def test_failing_function(self):
        """Test benchmarking a function that fails."""
        result = benchmark_function(
            self.failing_function, iterations=1, track_memory=False
        )
        assert not result.success
        assert "Test failure" in result.error

    def test_memory_tracking(self):
        """Test memory tracking in benchmark_function."""
        result = benchmark_function(
            self.dummy_function, 100, iterations=1, track_memory=True
        )
        assert result.peak_memory >= 0


class TestCompareBenchmarks:
    """Test benchmark comparison utility."""

    def test_empty_results(self):
        """Test comparison with empty results."""
        output = compare_benchmarks({})
        assert "No results to compare" in output

    def test_single_result(self):
        """Test comparison with single result."""
        results = {"test1": BenchmarkResult(execution_time=0.5, peak_memory=1024)}
        output = compare_benchmarks(results)
        assert "Benchmark Comparison" in output
        assert "test1" in output
        assert "✓ OK" in output

    def test_multiple_results(self):
        """Test comparison with multiple results."""
        results = {
            "fast": BenchmarkResult(execution_time=0.1, peak_memory=1024),
            "slow": BenchmarkResult(execution_time=0.5, peak_memory=2048),
            "medium": BenchmarkResult(execution_time=0.3, peak_memory=1536),
        }
        output = compare_benchmarks(results)
        assert "Benchmark Comparison" in output
        assert "fast" in output
        assert "slow" in output
        assert "medium" in output
        assert "Fastest: fast" in output

    def test_failed_result(self):
        """Test comparison with failed result."""
        results = {
            "success": BenchmarkResult(
                execution_time=0.1, peak_memory=1024, success=True
            ),
            "failure": BenchmarkResult(
                execution_time=0.1,
                peak_memory=1024,
                success=False,
                error="Test error",
            ),
        }
        output = compare_benchmarks(results)
        assert "✓ OK" in output
        assert "✗ FAIL" in output

    def test_relative_performance(self):
        """Test relative performance calculation."""
        results = {
            "fast": BenchmarkResult(execution_time=0.1, peak_memory=1024),
            "slow": BenchmarkResult(execution_time=0.5, peak_memory=1024),
        }
        output = compare_benchmarks(results)
        assert "5.00x slower" in output or "slower" in output

    def test_sorting_by_time(self):
        """Test that results are sorted by execution time."""
        results = {
            "c": BenchmarkResult(execution_time=0.3, peak_memory=1024),
            "a": BenchmarkResult(execution_time=0.1, peak_memory=1024),
            "b": BenchmarkResult(execution_time=0.2, peak_memory=1024),
        }
        output = compare_benchmarks(results)
        lines = output.split("\n")
        # Find the data lines (skip headers)
        data_lines = [
            l
            for l in lines
            if l
            and not l.startswith("=")
            and not l.startswith("-")
            and "Name" not in l
            and "Benchmark" not in l
            and "Fastest" not in l
        ]
        # First result should be 'a' (fastest)
        assert "a" in data_lines[0]
