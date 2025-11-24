"""
Unit tests for the EigenScript CLI and REPL.

Tests command-line interface, file execution, and interactive mode.
"""

import pytest
import sys
import io
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock
from eigenscript.__main__ import run_file, run_repl, main


class TestRunFile:
    """Test suite for file execution."""

    def test_run_simple_file(self, tmp_path):
        """Should execute a simple EigenScript file successfully."""
        # Create a simple test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run the file
        exit_code = run_file(str(test_file))

        # Should succeed
        assert exit_code == 0

    def test_run_file_with_output(self, tmp_path, capsys):
        """Should execute file and capture print output."""
        # Create test file with print statement
        test_file = tmp_path / "test.eigs"
        test_file.write_text('print of "Hello, EigenScript!"\n')

        # Run the file
        exit_code = run_file(str(test_file))

        # Check output and exit code
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Hello, EigenScript!" in captured.out

    def test_run_file_not_found(self, capsys):
        """Should handle missing file gracefully."""
        # Try to run non-existent file
        exit_code = run_file("nonexistent.eigs")

        # Should fail with exit code 1
        assert exit_code == 1

        # Check error message
        captured = capsys.readouterr()
        assert "Error: File not found" in captured.err
        assert "nonexistent.eigs" in captured.err

    def test_run_file_verbose_mode(self, tmp_path, capsys):
        """Should show execution details in verbose mode."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\ny is 10\n")

        # Run with verbose flag
        exit_code = run_file(str(test_file), verbose=True)

        # Check verbose output
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Executing:" in captured.out
        assert "Execution complete" in captured.out
        assert "Framework Strength:" in captured.out

    def test_run_file_show_fs_metrics(self, tmp_path, capsys):
        """Should display Framework Strength metrics when requested."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run with show-fs flag
        exit_code = run_file(str(test_file), show_fs=True)

        # Check metrics output
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Framework Strength Metrics" in captured.out
        assert "Framework Strength:" in captured.out
        assert "Converged:" in captured.out
        assert "Spacetime Signature:" in captured.out

    def test_run_file_syntax_error(self, tmp_path, capsys):
        """Should handle syntax errors gracefully."""
        # Create file with syntax error
        test_file = tmp_path / "bad.eigs"
        test_file.write_text("x iz 5\n")  # 'iz' instead of 'is'

        # Run the file
        exit_code = run_file(str(test_file))

        # Should fail
        assert exit_code == 1

        # Check error message
        captured = capsys.readouterr()
        assert "Error" in captured.err

    def test_run_file_name_error(self, tmp_path, capsys):
        """Should handle undefined variable errors."""
        # Create file with undefined variable
        test_file = tmp_path / "undefined.eigs"
        test_file.write_text("print of undefined_var\n")

        # Run the file
        exit_code = run_file(str(test_file))

        # Should fail
        assert exit_code == 1

        # Check error message
        captured = capsys.readouterr()
        assert "Name Error" in captured.err or "Error" in captured.err

    def test_run_file_with_functions(self, tmp_path):
        """Should execute file with function definitions."""
        # Create file with function - just test that define syntax works
        test_file = tmp_path / "func.eigs"
        test_file.write_text(
            """
define double as:
    result is n * 2
    return result

x is 10
"""
        )

        # Run the file
        exit_code = run_file(str(test_file))

        # Should succeed
        assert exit_code == 0

    def test_run_file_with_loops(self, tmp_path):
        """Should execute file with loops."""
        # Create file with loop
        test_file = tmp_path / "loop.eigs"
        test_file.write_text(
            """
i is 0
loop while i < 5:
    i is i + 1
"""
        )

        # Run the file
        exit_code = run_file(str(test_file))

        # Should succeed
        assert exit_code == 0

    def test_run_file_with_math(self, tmp_path, capsys):
        """Should execute file with math operations."""
        # Create file with math
        test_file = tmp_path / "math.eigs"
        test_file.write_text(
            """
x is 16
y is sqrt of x
print of y
"""
        )

        # Run the file
        exit_code = run_file(str(test_file))

        # Check result
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "4" in captured.out

    def test_run_file_verbose_with_error(self, tmp_path, capsys):
        """Should show traceback in verbose mode on error."""
        # Create file that will error
        test_file = tmp_path / "error.eigs"
        test_file.write_text("x iz 5\n")

        # Run with verbose flag
        exit_code = run_file(str(test_file), verbose=True)

        # Should fail
        assert exit_code == 1

        # Verbose mode may show more details
        captured = capsys.readouterr()
        assert "Error" in captured.err


class TestRunREPL:
    """Test suite for REPL mode."""

    def test_repl_simple_input(self, monkeypatch, capsys):
        """Should evaluate simple expression in REPL."""
        # Simulate user input
        inputs = iter(["x is 5", "exit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run REPL
        exit_code = run_repl()

        # Should exit cleanly
        assert exit_code == 0

        # Check welcome message
        captured = capsys.readouterr()
        assert "EigenScript" in captured.out
        assert "Type 'exit'" in captured.out

    def test_repl_multiple_statements(self, monkeypatch, capsys):
        """Should handle multiple statements in REPL."""
        # Simulate multiple inputs
        inputs = iter(["x is 5", "y is 10", "z is x + y", "exit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run REPL
        exit_code = run_repl()

        # Should exit cleanly
        assert exit_code == 0

    def test_repl_print_output(self, monkeypatch, capsys):
        """Should display print output in REPL."""
        # Simulate input with print
        inputs = iter(['print of "Hello REPL"', "exit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run REPL
        exit_code = run_repl()

        # Check output
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Hello REPL" in captured.out

    def test_repl_quit_command(self, monkeypatch, capsys):
        """Should exit on 'quit' command."""
        # Simulate quit command
        inputs = iter(["quit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run REPL
        exit_code = run_repl()

        # Should exit cleanly
        assert exit_code == 0

        # Check goodbye message
        captured = capsys.readouterr()
        assert "Goodbye" in captured.out

    def test_repl_eof_handling(self, monkeypatch, capsys):
        """Should handle EOF (Ctrl+D) gracefully."""
        # Simulate EOF
        monkeypatch.setattr(
            "builtins.input", lambda _: (_ for _ in ()).throw(EOFError())
        )

        # Run REPL
        exit_code = run_repl()

        # Should exit cleanly
        assert exit_code == 0

        # Check goodbye message
        captured = capsys.readouterr()
        assert "Goodbye" in captured.out

    def test_repl_keyboard_interrupt(self, monkeypatch, capsys):
        """Should handle Ctrl+C gracefully and continue."""
        # Simulate Ctrl+C then exit
        inputs = iter([])
        call_count = [0]

        def mock_input(prompt):
            call_count[0] += 1
            if call_count[0] == 1:
                raise KeyboardInterrupt()
            return "exit"

        monkeypatch.setattr("builtins.input", mock_input)

        # Run REPL
        exit_code = run_repl()

        # Should continue after interrupt and exit cleanly
        assert exit_code == 0

        # Check interrupt message
        captured = capsys.readouterr()
        assert "Interrupted" in captured.out

    def test_repl_syntax_error_recovery(self, monkeypatch, capsys):
        """Should recover from syntax error and continue."""
        # Simulate bad input then good input
        inputs = iter(["x iz 5", "x is 5", "exit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run REPL
        exit_code = run_repl()

        # Should continue after error
        assert exit_code == 0

        # Check error message
        captured = capsys.readouterr()
        assert "Error" in captured.err or "Syntax" in captured.err

    def test_repl_verbose_mode(self, monkeypatch, capsys):
        """Should show FS metrics in verbose mode."""
        # Simulate input with verbose mode
        inputs = iter(["x is 5", "exit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run REPL with verbose
        exit_code = run_repl(verbose=True)

        # Check verbose output
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "FS:" in captured.out or "Framework" in captured.out

    def test_repl_multi_line_function(self, monkeypatch, capsys):
        """Should handle multi-line function definitions."""
        # Simulate multi-line input
        inputs = iter(
            [
                "define double as:",
                "    result is n * 2",
                "    return result",
                "",  # Empty line to complete
                "exit",
            ]
        )
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run REPL
        exit_code = run_repl()

        # Should handle multi-line input
        assert exit_code == 0

    def test_repl_continuation_prompt(self, monkeypatch, capsys):
        """Should show continuation prompt for multi-line blocks."""
        # Track prompts shown
        prompts = []
        call_count = [0]

        def mock_input(prompt):
            prompts.append(prompt)
            call_count[0] += 1
            if call_count[0] == 1:
                return "define test as:"
            elif call_count[0] == 2:
                return ""  # End block
            else:
                return "exit"

        monkeypatch.setattr("builtins.input", mock_input)

        # Run REPL
        exit_code = run_repl()

        # Should show continuation prompt
        assert "... " in prompts
        assert exit_code == 0


class TestMainFunction:
    """Test suite for main() function and argument parsing."""

    def test_main_no_args(self, capsys):
        """Should show help when no arguments provided."""
        with patch.object(sys, "argv", ["eigenscript"]):
            exit_code = main()

        # Should show help
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "usage:" in captured.out.lower() or "eigenscript" in captured.out.lower()

    def test_main_version(self, capsys):
        """Should display version information."""
        with patch.object(sys, "argv", ["eigenscript", "--version"]):
            with pytest.raises(SystemExit) as excinfo:
                main()

        # Version flag causes SystemExit(0)
        assert excinfo.value.code == 0

    def test_main_file_execution(self, tmp_path):
        """Should execute file specified as argument."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run with file argument
        with patch.object(sys, "argv", ["eigenscript", str(test_file)]):
            exit_code = main()

        # Should succeed
        assert exit_code == 0

    def test_main_interactive_flag(self, monkeypatch):
        """Should start REPL with --interactive flag."""
        # Mock REPL to exit immediately
        inputs = iter(["exit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run with interactive flag
        with patch.object(sys, "argv", ["eigenscript", "--interactive"]):
            exit_code = main()

        # Should start REPL
        assert exit_code == 0

    def test_main_interactive_short_flag(self, monkeypatch):
        """Should start REPL with -i flag."""
        # Mock REPL to exit immediately
        inputs = iter(["exit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run with -i flag
        with patch.object(sys, "argv", ["eigenscript", "-i"]):
            exit_code = main()

        # Should start REPL
        assert exit_code == 0

    def test_main_verbose_flag(self, tmp_path, capsys):
        """Should enable verbose output with --verbose flag."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run with verbose flag
        with patch.object(sys, "argv", ["eigenscript", str(test_file), "--verbose"]):
            exit_code = main()

        # Check for verbose output
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Executing:" in captured.out or "Framework Strength:" in captured.out

    def test_main_verbose_short_flag(self, tmp_path, capsys):
        """Should enable verbose output with -v flag."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run with -v flag
        with patch.object(sys, "argv", ["eigenscript", str(test_file), "-v"]):
            exit_code = main()

        # Should succeed with verbose output
        assert exit_code == 0

    def test_main_show_fs_flag(self, tmp_path, capsys):
        """Should show Framework Strength metrics with --show-fs flag."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run with show-fs flag
        with patch.object(sys, "argv", ["eigenscript", str(test_file), "--show-fs"]):
            exit_code = main()

        # Check for FS metrics
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Framework Strength" in captured.out

    def test_main_combined_flags(self, tmp_path, capsys):
        """Should handle multiple flags together."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run with multiple flags
        with patch.object(
            sys, "argv", ["eigenscript", str(test_file), "-v", "--show-fs"]
        ):
            exit_code = main()

        # Check output
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Executing:" in captured.out
        assert "Framework Strength" in captured.out

    def test_main_nonexistent_file(self, capsys):
        """Should handle non-existent file gracefully."""
        # Run with non-existent file
        with patch.object(sys, "argv", ["eigenscript", "nonexistent.eigs"]):
            exit_code = main()

        # Should fail
        assert exit_code == 1

        # Check error message
        captured = capsys.readouterr()
        assert "Error" in captured.err


class TestCLIEdgeCases:
    """Test suite for CLI edge cases and special scenarios."""

    def test_empty_file_execution(self, tmp_path):
        """Should handle empty file gracefully."""
        # Create empty file
        test_file = tmp_path / "empty.eigs"
        test_file.write_text("")

        # Run the file
        exit_code = run_file(str(test_file))

        # Should succeed (empty program is valid)
        assert exit_code == 0

    def test_file_with_only_comments(self, tmp_path):
        """Should handle file with only comments."""
        # Create file with comments
        test_file = tmp_path / "comments.eigs"
        test_file.write_text("# This is a comment\n# Another comment\n")

        # Run the file
        exit_code = run_file(str(test_file))

        # Should succeed
        assert exit_code == 0

    def test_file_with_unicode(self, tmp_path, capsys):
        """Should handle Unicode content correctly."""
        # Create file with Unicode
        test_file = tmp_path / "unicode.eigs"
        test_file.write_text('print of "Hello 世界! 🌍"\n', encoding="utf-8")

        # Run the file
        exit_code = run_file(str(test_file))

        # Should succeed
        assert exit_code == 0

        # Check Unicode output
        captured = capsys.readouterr()
        assert "世界" in captured.out or "Hello" in captured.out

    def test_repl_empty_input_skip(self, monkeypatch):
        """REPL should skip empty lines without error."""
        # Simulate empty inputs then exit
        inputs = iter(["", "", "exit"])
        monkeypatch.setattr("builtins.input", lambda _: next(inputs))

        # Run REPL
        exit_code = run_repl()

        # Should handle empty inputs
        assert exit_code == 0

    def test_large_program_execution(self, tmp_path):
        """Should handle larger programs with multiple features."""
        # Create comprehensive test file
        test_file = tmp_path / "large.eigs"
        test_file.write_text(
            """
# Simple test program
x is 5
y is 10
z is x + y

# List operations
numbers is [1, 2, 3, 4, 5]
first_num is numbers[0]
"""
        )

        # Run the file
        exit_code = run_file(str(test_file))

        # Should succeed
        assert exit_code == 0


class TestBenchmarkFlag:
    """Test suite for benchmark functionality."""

    def test_benchmark_flag_basic(self, tmp_path, capsys):
        """Should display benchmark results with --benchmark flag."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\ny is x + 10\n")

        # Run with benchmark flag
        exit_code = run_file(str(test_file), benchmark=True)

        # Check for benchmark output
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Benchmark Results" in captured.out
        assert "Execution Time:" in captured.out
        assert "Peak Memory:" in captured.out

    def test_benchmark_flag_short_form(self, tmp_path, capsys):
        """Should work with -b short flag."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 10\n")

        # Run with -b flag
        with patch.object(sys, "argv", ["eigenscript", str(test_file), "-b"]):
            exit_code = main()

        # Check for benchmark output
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Benchmark Results" in captured.out

    def test_benchmark_with_verbose(self, tmp_path, capsys):
        """Should combine benchmark with verbose output."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run with both flags
        exit_code = run_file(str(test_file), verbose=True, benchmark=True)

        # Should have both outputs
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Benchmark Results" in captured.out
        assert "Execution Time:" in captured.out

    def test_benchmark_with_show_fs(self, tmp_path, capsys):
        """Should combine benchmark with Framework Strength metrics."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        # Run with both flags
        exit_code = run_file(str(test_file), show_fs=True, benchmark=True)

        # Should have both outputs
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Benchmark Results" in captured.out
        assert "Framework Strength Metrics" in captured.out

    def test_benchmark_with_computation(self, tmp_path, capsys):
        """Should benchmark a program with actual computation."""
        # Create test file with computation
        test_file = tmp_path / "test.eigs"
        test_file.write_text(
            """
define factorial as:
    if n < 2:
        return 1
    else:
        prev is n - 1
        sub_result is factorial of prev
        return n * sub_result

n is 10
result is factorial of n
print of result
"""
        )

        # Run with benchmark
        exit_code = run_file(str(test_file), benchmark=True)

        # Check results
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "3628800" in captured.out  # factorial(10)
        assert "Benchmark Results" in captured.out
        assert "Execution Time:" in captured.out
        assert "Peak Memory:" in captured.out

    def test_benchmark_metadata(self, tmp_path, capsys):
        """Should include metadata in benchmark results."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\ny is 10\n")

        # Run with benchmark
        exit_code = run_file(str(test_file), benchmark=True)

        # Check for metadata
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Additional Metrics:" in captured.out
        assert "source_lines:" in captured.out
        assert "tokens:" in captured.out

    def test_benchmark_with_error(self, tmp_path, capsys):
        """Should handle errors gracefully with benchmark enabled."""
        # Create file with error
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is undefined_var\n")

        # Run with benchmark (should fail)
        exit_code = run_file(str(test_file), benchmark=True)

        # Should fail but not crash
        assert exit_code == 1
        captured = capsys.readouterr()
        assert "Error" in captured.err or "Name Error" in captured.err

    def test_main_benchmark_flag(self, tmp_path, capsys):
        """Should work through main() function."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 42\n")

        # Run through main with --benchmark
        with patch.object(sys, "argv", ["eigenscript", str(test_file), "--benchmark"]):
            exit_code = main()

        # Check results
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Benchmark Results" in captured.out

    def test_benchmark_combined_flags(self, tmp_path, capsys):
        """Should work with multiple flags."""
        # Create test file
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 100\n")

        # Run with multiple flags
        with patch.object(
            sys, "argv", ["eigenscript", str(test_file), "-v", "-b", "--show-fs"]
        ):
            exit_code = main()

        # Should have all outputs
        captured = capsys.readouterr()
        assert exit_code == 0
        assert "Benchmark Results" in captured.out
        assert "Framework Strength" in captured.out
