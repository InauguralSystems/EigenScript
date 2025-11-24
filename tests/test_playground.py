"""
Tests for the EigenSpace Interactive Playground (Phase 5)
"""

import os
import sys
from pathlib import Path
import pytest


# Path to the playground
PLAYGROUND_DIR = Path(__file__).parent.parent / "examples" / "playground"


def test_playground_directory_exists():
    """Test that the playground directory exists."""
    assert PLAYGROUND_DIR.exists(), "examples/playground directory should exist"
    assert PLAYGROUND_DIR.is_dir(), "examples/playground should be a directory"


def test_server_file_exists():
    """Test that server.py exists and is executable."""
    server_file = PLAYGROUND_DIR / "server.py"
    assert server_file.exists(), "server.py should exist"
    assert os.access(server_file, os.X_OK), "server.py should be executable"


def test_index_html_exists():
    """Test that index.html exists."""
    index_file = PLAYGROUND_DIR / "index.html"
    assert index_file.exists(), "index.html should exist"


def test_readme_exists():
    """Test that README.md exists."""
    readme_file = PLAYGROUND_DIR / "README.md"
    assert readme_file.exists(), "README.md should exist"


def test_quickstart_exists():
    """Test that QUICKSTART.md exists."""
    quickstart_file = PLAYGROUND_DIR / "QUICKSTART.md"
    assert quickstart_file.exists(), "QUICKSTART.md should exist"


def test_server_imports():
    """Test that server.py has valid Python syntax and imports."""
    server_file = PLAYGROUND_DIR / "server.py"
    with open(server_file) as f:
        code = f.read()

    # Try to compile the code to check syntax
    try:
        compile(code, str(server_file), "exec")
    except SyntaxError as e:
        pytest.fail(f"server.py has syntax errors: {e}")


def test_server_constants():
    """Test that server.py defines expected constants."""
    server_file = PLAYGROUND_DIR / "server.py"
    with open(server_file) as f:
        content = f.read()

    assert "PORT = 8080" in content, "Server should define PORT = 8080"
    assert "PROJECT_ROOT" in content, "Server should define PROJECT_ROOT"
    assert "COMPILER_MODULE" in content, "Server should define COMPILER_MODULE"


def test_index_html_structure():
    """Test that index.html has expected structure."""
    index_file = PLAYGROUND_DIR / "index.html"
    with open(index_file) as f:
        content = f.read()

    # Check for key elements
    assert "<!DOCTYPE html>" in content, "Should have DOCTYPE"
    assert "EigenSpace" in content, "Should mention EigenSpace"
    assert "<canvas" in content, "Should have canvas element"
    assert "compileAndRun" in content, "Should have compileAndRun function"
    assert "/compile" in content, "Should reference /compile endpoint"
    assert "WebAssembly" in content, "Should reference WebAssembly"


def test_readme_has_quickstart():
    """Test that README.md has quick start instructions."""
    readme_file = PLAYGROUND_DIR / "README.md"
    with open(readme_file) as f:
        content = f.read()

    assert "Quick Start" in content, "README should have Quick Start section"
    assert "build_runtime.py" in content, "README should mention building runtime"
    assert "server.py" in content, "README should mention starting server"
    assert "localhost:8080" in content, "README should mention the URL"


def test_quickstart_three_steps():
    """Test that QUICKSTART.md has the three main steps."""
    quickstart_file = PLAYGROUND_DIR / "QUICKSTART.md"
    with open(quickstart_file) as f:
        content = f.read()

    assert "Step 1" in content or "Build Runtime" in content, "Should have build step"
    assert "Step 2" in content or "Start Server" in content, "Should have server step"
    assert "Step 3" in content or "Visit" in content, "Should have visit step"
    assert (
        "python3 src/eigenscript/compiler/runtime/build_runtime.py --target wasm32"
        in content
    )
    assert "python3 examples/playground/server.py" in content
    assert "http://localhost:8080" in content


def test_example_code_in_html():
    """Test that index.html contains an example EigenScript program."""
    index_file = PLAYGROUND_DIR / "index.html"
    with open(index_file) as f:
        content = f.read()

    # Should have the "Inaugural Algorithm" example
    assert (
        "Inaugural Algorithm" in content or "loop while" in content
    ), "Should contain example EigenScript code"
    assert "print of" in content, "Example should use print statement"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
