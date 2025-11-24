"""
End-to-end tests for all example files.

This ensures that all example .eigs files in the examples/ directory
execute successfully without errors.
"""

import subprocess
from pathlib import Path

import pytest


# Get the examples directory relative to this test file
EXAMPLES_DIR = Path(__file__).parent.parent / "examples"

# Known slow examples that need longer timeout
SLOW_EXAMPLES = {"meta_eval_complete.eigs", "fibonacci.eigs"}


def get_all_examples():
    """Get all .eigs files from the examples directory."""
    return sorted(EXAMPLES_DIR.glob("*.eigs"))


@pytest.mark.parametrize("example", get_all_examples())
def test_example_runs(example):
    """Ensure all examples execute without error.

    This test runs each .eigs file in the examples/ directory and verifies
    that it completes successfully (exit code 0).
    """
    # Set timeout based on whether this is a slow example
    timeout = 30 if example.name in SLOW_EXAMPLES else 10

    result = subprocess.run(
        ["python", "-m", "eigenscript", str(example)],
        capture_output=True,
        text=True,
        timeout=timeout,
    )

    assert result.returncode == 0, (
        f"{example.name} failed with exit code {result.returncode}\n"
        f"STDERR: {result.stderr}\n"
        f"STDOUT: {result.stdout}"
    )


def test_examples_directory_exists():
    """Ensure the examples directory exists."""
    assert EXAMPLES_DIR.exists(), f"Examples directory not found at {EXAMPLES_DIR}"
    assert EXAMPLES_DIR.is_dir(), f"{EXAMPLES_DIR} is not a directory"


def test_examples_directory_not_empty():
    """Ensure there are example files to test."""
    examples = list(EXAMPLES_DIR.glob("*.eigs"))
    assert len(examples) > 0, "No .eigs files found in examples directory"
    # Verify we have at least the expected minimum number of examples
    assert len(examples) >= 25, f"Expected at least 25 examples, found {len(examples)}"
