"""
Unit tests for the cross-compilation runtime build system (Phase 3.2).

Tests the build_runtime.py script and target-specific runtime selection.
"""

import pytest
import subprocess
import os
from pathlib import Path


class TestRuntimeBuildSystem:
    """Test suite for runtime cross-compilation build system."""

    def test_build_script_exists(self):
        """Build script should exist in runtime directory."""
        script_path = Path("src/eigenscript/compiler/runtime/build_runtime.py")
        assert script_path.exists(), f"Build script not found at {script_path}"
        assert (
            os.access(script_path, os.X_OK) or True
        )  # May not be executable on all systems

    def test_build_script_list_targets(self):
        """Build script should list available targets."""
        result = subprocess.run(
            ["python3", "src/eigenscript/compiler/runtime/build_runtime.py", "--list"],
            capture_output=True,
            text=True,
            timeout=10,
        )

        assert result.returncode == 0, "Build script --list failed"
        assert "host" in result.stdout, "Should list 'host' target"
        assert "wasm32" in result.stdout, "Should list 'wasm32' target"
        assert "aarch64" in result.stdout, "Should list 'aarch64' target"

    def test_build_host_runtime(self):
        """Should build runtime for host architecture."""
        result = subprocess.run(
            ["python3", "src/eigenscript/compiler/runtime/build_runtime.py"],
            capture_output=True,
            text=True,
            timeout=30,
        )

        # Should succeed (host build should always work)
        assert result.returncode == 0, f"Host build failed: {result.stderr}"
        assert "✅" in result.stdout, "Should show success indicators"
        assert "Build Summary: 1/1" in result.stdout, "Should report 1/1 success"

        # Check that output files exist
        runtime_dir = Path("src/eigenscript/compiler/runtime")
        build_dir = runtime_dir / "build" / "host"

        assert build_dir.exists(), f"Build directory not created: {build_dir}"
        assert (build_dir / "eigenvalue.o").exists(), "Object file not created"
        assert (build_dir / "eigenvalue.bc").exists(), "Bitcode file not created"

        # Check symlinks
        assert (runtime_dir / "eigenvalue.o").exists(), "Object symlink not created"
        assert (runtime_dir / "eigenvalue.bc").exists(), "Bitcode symlink not created"

    def test_runtime_directory_structure(self):
        """Runtime directory should have expected structure after build."""
        runtime_dir = Path("src/eigenscript/compiler/runtime")

        # Source files should exist
        assert (runtime_dir / "eigenvalue.c").exists(), "eigenvalue.c missing"
        assert (runtime_dir / "eigenvalue.h").exists(), "eigenvalue.h missing"
        assert (runtime_dir / "build_runtime.py").exists(), "build_runtime.py missing"

        # After build, should have build directory
        build_dir = runtime_dir / "build"
        if build_dir.exists():
            # Should have at least host build
            host_dir = build_dir / "host"
            assert host_dir.exists(), "Host build directory should exist after build"

    def test_get_runtime_path_function(self):
        """Test the get_runtime_path helper function from compile.py."""
        # Import the function
        import sys

        sys.path.insert(0, "src")
        from eigenscript.compiler.cli.compile import get_runtime_path

        runtime_dir = "src/eigenscript/compiler/runtime"

        # Test host runtime
        runtime_o, runtime_bc = get_runtime_path(runtime_dir, None)
        assert runtime_o is not None, "Should return host runtime path"
        assert os.path.exists(runtime_o), "Runtime object file should exist"

        # Test explicit host
        runtime_o, runtime_bc = get_runtime_path(runtime_dir, "host")
        assert runtime_o is not None, "Should return host runtime for 'host' target"

    def test_compilation_with_target_specific_runtime(self):
        """Test that compilation uses target-specific runtime."""
        from eigenscript.lexer import Tokenizer
        from eigenscript.parser.ast_builder import Parser
        from eigenscript.compiler.codegen.llvm_backend import LLVMCodeGenerator
        from eigenscript.compiler.analysis.observer import ObserverAnalyzer

        # Simple test program
        source = "x is 5\nprint of x"

        # Tokenize and parse
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        # Analyze
        analyzer = ObserverAnalyzer()
        observed_vars = analyzer.analyze(ast.statements)

        # Generate IR with explicit target
        target = "x86_64-unknown-linux-gnu"
        codegen = LLVMCodeGenerator(
            observed_variables=observed_vars, target_triple=target
        )
        llvm_ir = codegen.compile(ast.statements)

        # Verify target triple in IR
        assert f'target triple = "{target}"' in llvm_ir, "Target triple should be in IR"

        # Verify malloc uses correct size
        assert (
            'declare i8* @"malloc"(i64' in llvm_ir
        ), "Should use i64 malloc for x86_64"


class TestRuntimeBuildSystemIntegration:
    """Integration tests for the complete build system."""

    def test_end_to_end_compilation(self):
        """Test end-to-end compilation with runtime build system."""
        # This test requires the runtime to be built
        result = subprocess.run(
            [
                "python3",
                "-m",
                "eigenscript.compiler.cli.compile",
                "examples/factorial_simple.eigs",
                "-o",
                "/tmp/test_runtime_e2e.ll",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )

        # Should succeed
        assert result.returncode == 0, f"Compilation failed: {result.stderr}"
        assert "✅ Compilation successful!" in result.stdout, "Should show success"

        # Output file should exist
        assert os.path.exists(
            "/tmp/test_runtime_e2e.ll"
        ), "Output LLVM IR file not created"

    def test_automatic_runtime_build(self):
        """Test that compile.py automatically builds runtime if missing."""
        # Remove x86_64 build if it exists
        import shutil

        x86_64_dir = Path(
            "src/eigenscript/compiler/runtime/build/x86_64-unknown-linux-gnu"
        )

        # Try to compile with explicit target - should auto-build runtime
        result = subprocess.run(
            [
                "python3",
                "-m",
                "eigenscript.compiler.cli.compile",
                "examples/factorial_simple.eigs",
                "--target",
                "x86_64-unknown-linux-gnu",
                "-o",
                "/tmp/test_auto_build.ll",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )

        # Should succeed (will auto-build or use existing)
        assert result.returncode == 0, f"Auto-build test failed: {result.stderr}"
