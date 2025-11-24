"""
Tests for file I/O operations in EigenScript.
"""

import pytest
import os
import tempfile
import textwrap
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter


@pytest.fixture
def interpreter():
    """Create a fresh interpreter for each test."""
    return Interpreter()


@pytest.fixture
def temp_dir():
    """Create a temporary directory for tests."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield tmpdir


def run_code(code: str, interpreter):
    """Helper to run EigenScript code."""
    code = textwrap.dedent(code).strip()
    tokenizer = Tokenizer(code)
    tokens = tokenizer.tokenize()
    parser = Parser(tokens)
    ast = parser.parse()
    return interpreter.evaluate(ast)


class TestFileOpen:
    """Tests for file_open function."""

    def test_open_read_mode(self, interpreter, temp_dir):
        """Test opening file in read mode."""
        # Create a test file
        test_file = os.path.join(temp_dir, "test.txt")
        with open(test_file, "w") as f:
            f.write("Hello, World!")

        code = f"""
        handle is file_open of ["{test_file}", "r"]
        file_close of handle
        """
        run_code(code, interpreter)

    def test_open_write_mode(self, interpreter, temp_dir):
        """Test opening file in write mode."""
        test_file = os.path.join(temp_dir, "output.txt")

        code = f"""
        handle is file_open of ["{test_file}", "w"]
        file_close of handle
        """
        run_code(code, interpreter)

        assert os.path.exists(test_file)

    def test_open_nonexistent_file(self, interpreter, temp_dir):
        """Test error when opening nonexistent file."""
        test_file = os.path.join(temp_dir, "nonexistent.txt")

        code = f"""
        handle is file_open of ["{test_file}", "r"]
        """

        with pytest.raises(FileNotFoundError):
            run_code(code, interpreter)

    def test_open_invalid_mode(self, interpreter, temp_dir):
        """Test error with invalid mode."""
        test_file = os.path.join(temp_dir, "test.txt")

        code = f"""
        handle is file_open of ["{test_file}", "x"]
        """

        with pytest.raises(ValueError, match="Invalid mode"):
            run_code(code, interpreter)


class TestFileReadWrite:
    """Tests for file_read and file_write functions."""

    def test_read_file(self, interpreter, temp_dir):
        """Test reading file contents."""
        test_file = os.path.join(temp_dir, "test.txt")
        test_content = "Hello, EigenScript!"

        with open(test_file, "w") as f:
            f.write(test_content)

        code = f"""
        handle is file_open of ["{test_file}", "r"]
        content is file_read of handle
        file_close of handle
        content
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        content = decode_vector(result, interpreter.space)
        assert content == test_content

    def test_write_file(self, interpreter, temp_dir):
        """Test writing to file."""
        test_file = os.path.join(temp_dir, "output.txt")
        test_content = "Testing file write"

        code = f"""
        handle is file_open of ["{test_file}", "w"]
        file_write of [handle, "{test_content}"]
        file_close of handle
        """

        run_code(code, interpreter)

        with open(test_file, "r") as f:
            content = f.read()

        assert content == test_content

    def test_read_empty_file(self, interpreter, temp_dir):
        """Test reading empty file."""
        test_file = os.path.join(temp_dir, "empty.txt")
        open(test_file, "w").close()  # Create empty file

        code = f"""
        handle is file_open of ["{test_file}", "r"]
        content is file_read of handle
        file_close of handle
        content
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        content = decode_vector(result, interpreter.space)
        assert content == ""

    def test_write_multiline(self, interpreter, temp_dir):
        """Test writing multiline content."""
        test_file = os.path.join(temp_dir, "multiline.txt")

        code = f"""
        handle is file_open of ["{test_file}", "w"]
        file_write of [handle, "Line 1"]
        file_write of [handle, "\\nLine 2"]
        file_write of [handle, "\\nLine 3"]
        file_close of handle
        """

        run_code(code, interpreter)

        with open(test_file, "r") as f:
            content = f.read()

        assert content == "Line 1\nLine 2\nLine 3"


class TestFileExists:
    """Tests for file_exists function."""

    def test_file_exists_true(self, interpreter, temp_dir):
        """Test file_exists returns 1 for existing file."""
        test_file = os.path.join(temp_dir, "exists.txt")
        open(test_file, "w").close()

        code = f"""
        file_exists of "{test_file}"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        exists = decode_vector(result, interpreter.space)
        assert exists == 1

    def test_file_exists_false(self, interpreter, temp_dir):
        """Test file_exists returns 0 for nonexistent file."""
        test_file = os.path.join(temp_dir, "nonexistent.txt")

        code = f"""
        file_exists of "{test_file}"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        exists = decode_vector(result, interpreter.space)
        assert exists == 0

    def test_directory_exists(self, interpreter, temp_dir):
        """Test file_exists works for directories."""
        code = f"""
        file_exists of "{temp_dir}"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        exists = decode_vector(result, interpreter.space)
        assert exists == 1


class TestListDir:
    """Tests for list_dir function."""

    def test_list_directory(self, interpreter, temp_dir):
        """Test listing directory contents."""
        # Create some test files
        for i in range(3):
            open(os.path.join(temp_dir, f"file{i}.txt"), "w").close()

        code = f"""
        list_dir of "{temp_dir}"
        """

        result = run_code(code, interpreter)
        from eigenscript.evaluator.interpreter import EigenList
        from eigenscript.builtins import decode_vector

        assert isinstance(result, EigenList)
        files = [decode_vector(elem, interpreter.space) for elem in result.elements]

        assert len(files) == 3
        assert "file0.txt" in files
        assert "file1.txt" in files
        assert "file2.txt" in files

    def test_list_empty_directory(self, interpreter, temp_dir):
        """Test listing empty directory."""
        empty_dir = os.path.join(temp_dir, "empty")
        os.mkdir(empty_dir)

        code = f"""
        list_dir of "{empty_dir}"
        """

        result = run_code(code, interpreter)
        from eigenscript.evaluator.interpreter import EigenList

        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_list_nonexistent_directory(self, interpreter, temp_dir):
        """Test error when listing nonexistent directory."""
        nonexistent = os.path.join(temp_dir, "nonexistent")

        code = f"""
        list_dir of "{nonexistent}"
        """

        with pytest.raises(FileNotFoundError):
            run_code(code, interpreter)


class TestFileSize:
    """Tests for file_size function."""

    def test_file_size_empty(self, interpreter, temp_dir):
        """Test file size of empty file."""
        test_file = os.path.join(temp_dir, "empty.txt")
        open(test_file, "w").close()

        code = f"""
        file_size of "{test_file}"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        size = decode_vector(result, interpreter.space)
        assert size == 0

    def test_file_size_with_content(self, interpreter, temp_dir):
        """Test file size of file with content."""
        test_file = os.path.join(temp_dir, "test.txt")
        test_content = "Hello, World!"

        with open(test_file, "w") as f:
            f.write(test_content)

        code = f"""
        file_size of "{test_file}"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        size = decode_vector(result, interpreter.space)
        assert size == len(test_content)

    def test_file_size_nonexistent(self, interpreter, temp_dir):
        """Test error when getting size of nonexistent file."""
        test_file = os.path.join(temp_dir, "nonexistent.txt")

        code = f"""
        file_size of "{test_file}"
        """

        with pytest.raises(FileNotFoundError):
            run_code(code, interpreter)


class TestPathOperations:
    """Tests for path operation functions."""

    def test_dirname(self, interpreter):
        """Test dirname function."""
        code = """
        dirname of "/path/to/file.txt"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        dir_name = decode_vector(result, interpreter.space)
        assert dir_name == "/path/to"

    def test_dirname_no_directory(self, interpreter):
        """Test dirname with no directory component."""
        code = """
        dirname of "file.txt"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        dir_name = decode_vector(result, interpreter.space)
        assert dir_name == "."

    def test_basename(self, interpreter):
        """Test basename function."""
        code = """
        basename of "/path/to/file.txt"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        base_name = decode_vector(result, interpreter.space)
        assert base_name == "file.txt"

    def test_basename_no_directory(self, interpreter):
        """Test basename with no directory component."""
        code = """
        basename of "file.txt"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        base_name = decode_vector(result, interpreter.space)
        assert base_name == "file.txt"

    def test_absolute_path(self, interpreter, temp_dir):
        """Test absolute_path function."""
        # Change to temp directory
        original_dir = os.getcwd()
        try:
            os.chdir(temp_dir)

            code = """
            absolute_path of "test.txt"
            """

            result = run_code(code, interpreter)
            from eigenscript.builtins import decode_vector

            abs_path = decode_vector(result, interpreter.space)

            expected = os.path.join(temp_dir, "test.txt")
            assert abs_path == expected
        finally:
            os.chdir(original_dir)

    def test_absolute_path_already_absolute(self, interpreter):
        """Test absolute_path with already absolute path."""
        code = """
        absolute_path of "/path/to/file.txt"
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        abs_path = decode_vector(result, interpreter.space)
        assert abs_path == "/path/to/file.txt"


class TestFileIOIntegration:
    """Integration tests combining multiple file I/O operations."""

    def test_full_workflow(self, interpreter, temp_dir):
        """Test complete file I/O workflow."""
        test_file = os.path.join(temp_dir, "workflow.txt")

        code = f"""
        # Check file doesn't exist initially
        exists1 is file_exists of "{test_file}"
        
        # Write to file
        handle is file_open of ["{test_file}", "w"]
        file_write of [handle, "Test content"]
        file_close of handle
        
        # Check file exists now
        exists2 is file_exists of "{test_file}"
        
        # Read back the content
        handle2 is file_open of ["{test_file}", "r"]
        content is file_read of handle2
        file_close of handle2
        
        # Get file size
        size is file_size of "{test_file}"
        
        content
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        content = decode_vector(result, interpreter.space)
        assert content == "Test content"

    def test_directory_operations(self, interpreter, temp_dir):
        """Test directory and path operations together."""
        test_file = os.path.join(temp_dir, "test.txt")
        open(test_file, "w").close()

        code = f"""
        # List directory
        files is list_dir of "{temp_dir}"
        
        # Get path components
        dir is dirname of "{test_file}"
        name is basename of "{test_file}"
        abs is absolute_path of "{test_file}"
        
        name
        """

        result = run_code(code, interpreter)
        from eigenscript.builtins import decode_vector

        name = decode_vector(result, interpreter.space)
        assert name == "test.txt"
