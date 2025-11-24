"""
Unit tests for the EigenScript Module Resolver.

Tests module resolution logic for imports.
"""

import os
import pytest
from eigenscript.compiler.analysis.resolver import ModuleResolver


def test_resolve_local_module(tmp_path):
    """Test that resolver finds modules in the local directory."""
    # Create a dummy module in a temporary directory
    d = tmp_path / "subdir"
    d.mkdir()
    p = d / "math.eigs"
    p.write_text("# math module")

    # Initialize resolver pointing to that directory
    resolver = ModuleResolver(root_dir=str(d))

    # Should find it
    resolved_path = resolver.resolve("math")
    assert resolved_path == str(p)


def test_resolve_missing_module():
    """Test that resolver raises ImportError for non-existent modules."""
    resolver = ModuleResolver()
    with pytest.raises(ImportError):
        resolver.resolve("non_existent_module")


def test_search_paths_initialization():
    """Test that search paths are initialized correctly."""
    resolver = ModuleResolver()
    # Should have at least the current working directory
    assert len(resolver.search_paths) >= 1
    assert os.getcwd() in resolver.search_paths


def test_search_paths_with_root_dir(tmp_path):
    """Test that root_dir is added to search paths."""
    resolver = ModuleResolver(root_dir=str(tmp_path))
    assert str(tmp_path) in resolver.search_paths


def test_eigen_path_environment_variable(tmp_path, monkeypatch):
    """Test that EIGEN_PATH environment variable is respected."""
    stdlib_path = tmp_path / "stdlib"
    stdlib_path.mkdir()

    # Set EIGEN_PATH environment variable
    monkeypatch.setenv("EIGEN_PATH", str(stdlib_path))

    resolver = ModuleResolver()
    assert str(stdlib_path) in resolver.search_paths


def test_get_output_path():
    """Test that output path generation works correctly."""
    resolver = ModuleResolver()

    # Test native target
    output_path = resolver.get_output_path("/path/to/physics.eigs")
    assert output_path == "/path/to/physics.o"

    # Test WASM target
    output_path = resolver.get_output_path(
        "/path/to/physics.eigs", target_triple="wasm32-unknown-unknown"
    )
    assert output_path == "/path/to/physics.o"


def test_resolve_with_multiple_search_paths(tmp_path):
    """Test that resolver searches multiple paths in order."""
    # Create two directories
    dir1 = tmp_path / "dir1"
    dir2 = tmp_path / "dir2"
    dir1.mkdir()
    dir2.mkdir()

    # Create module in second directory
    module_file = dir2 / "test_module.eigs"
    module_file.write_text("# test module")

    # Create resolver with first directory
    resolver = ModuleResolver(root_dir=str(dir1))

    # Manually add second directory to search paths
    resolver.search_paths.append(str(dir2))

    # Should find it in the second directory
    resolved_path = resolver.resolve("test_module")
    assert resolved_path == str(module_file)


def test_resolve_returns_absolute_path(tmp_path):
    """Test that resolve returns an absolute path."""
    d = tmp_path / "test_dir"
    d.mkdir()
    module_file = d / "absolute_test.eigs"
    module_file.write_text("# absolute test")

    resolver = ModuleResolver(root_dir=str(d))
    resolved_path = resolver.resolve("absolute_test")

    assert os.path.isabs(resolved_path)
    assert resolved_path == str(module_file)
