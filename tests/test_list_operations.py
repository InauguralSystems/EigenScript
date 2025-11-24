"""
Unit tests for list/array operations in EigenScript.

Tests list literals, indexing, range(), len(), type(), and iteration.
"""

import pytest
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.evaluator.interpreter import EigenList


class TestListLiterals:
    """Test list literal parsing and evaluation."""

    def test_empty_list(self):
        """Test empty list literal."""
        source = "[]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_number_list(self):
        """Test list of numbers."""
        source = "[1, 2, 3, 4, 5]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        assert isinstance(result, EigenList)
        assert len(result.elements) == 5

    def test_single_element_list(self):
        """Test list with single element."""
        source = "[42]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        assert isinstance(result, EigenList)
        assert len(result.elements) == 1

    def test_list_assignment(self):
        """Test assigning a list to a variable."""
        source = "my_list is [10, 20, 30]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        # Assignment returns the value
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3


class TestListIndexing:
    """Test list indexing operations."""

    def test_index_zero(self):
        """Test accessing index 0."""
        source = "[10, 20, 30][0]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        from eigenscript.builtins import decode_vector

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 10

    def test_index_middle(self):
        """Test accessing middle element."""
        source = "[100, 200, 300, 400, 500][2]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        from eigenscript.builtins import decode_vector

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 300

    def test_index_out_of_bounds(self):
        """Test indexing beyond list bounds raises error."""
        source = "[1, 2, 3][10]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()

        with pytest.raises(IndexError):
            interpreter.evaluate(ast)


class TestRangeFunction:
    """Test the range() built-in function."""

    def test_range_zero(self):
        """Test range of 0 returns empty list."""
        source = "range of 0"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_range_five(self):
        """Test range of 5 returns [0, 1, 2, 3, 4]."""
        source = "range of 5"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        assert isinstance(result, EigenList)
        assert len(result.elements) == 5

        # Verify elements are 0 through 4
        from eigenscript.builtins import decode_vector

        for i, elem in enumerate(result.elements):
            value = decode_vector(elem, interpreter.space, interpreter.metric)
            assert value == i


class TestListBuiltins:
    """Test built-in functions with lists."""

    def test_len_of_list(self):
        """Test len() on list."""
        source = "len of [10, 20, 30, 40, 50]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        from eigenscript.builtins import decode_vector

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 5

    def test_len_of_empty_list(self):
        """Test len() on empty list."""
        source = "len of []"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        from eigenscript.builtins import decode_vector

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0

    def test_type_of_list(self):
        """Test type() returns encoded 'list'."""
        source = "type of [1, 2, 3]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        # type() returns a string-encoded vector
        assert result is not None


class TestListIteration:
    """Test iterating over lists using loops."""

    def test_manual_iteration(self):
        """Test manual iteration with index."""
        from eigenscript.builtins import decode_vector

        interpreter = Interpreter()

        # Access first element
        source1 = "[5, 10, 15][0]"
        r1 = interpreter.evaluate(Parser(Tokenizer(source1).tokenize()).parse())
        assert decode_vector(r1, interpreter.space, interpreter.metric) == 5

        # Access second element
        source2 = "[5, 10, 15][1]"
        r2 = interpreter.evaluate(Parser(Tokenizer(source2).tokenize()).parse())
        assert decode_vector(r2, interpreter.space, interpreter.metric) == 10

        # Access third element
        source3 = "[5, 10, 15][2]"
        r3 = interpreter.evaluate(Parser(Tokenizer(source3).tokenize()).parse())
        assert decode_vector(r3, interpreter.space, interpreter.metric) == 15


class TestListEdgeCases:
    """Test edge cases and error conditions."""

    def test_index_non_list_fails(self):
        """Test indexing a non-list raises TypeError."""
        source = "42[0]"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()

        with pytest.raises(TypeError):
            interpreter.evaluate(ast)
