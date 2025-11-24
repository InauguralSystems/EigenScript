"""
Tests for Phase 2: String Power - string operations in EigenScript.

Tests string concatenation, indexing, slicing, and built-in string functions.
"""

import pytest
from eigenscript.lexer.tokenizer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.evaluator.interpreter import Interpreter
from eigenscript.builtins import decode_vector


class TestStringConcatenation:
    """Test string concatenation with + operator."""

    def test_simple_concatenation(self):
        """Test basic string concatenation."""
        source = """
first is "Hello"
second is " World"
result is first + second
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "Hello World"

    def test_multiple_concatenation(self):
        """Test chaining multiple concatenations."""
        source = """
result is "A" + "B" + "C"
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "ABC"

    def test_empty_string_concatenation(self):
        """Test concatenating empty strings."""
        source = """
result is "Hello" + ""
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "Hello"

    def test_chained_concatenation(self):
        """Test chained string concatenation (metadata propagation)."""
        source = """
result is "A" + "B" + "C" + "D"
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "ABCD"


class TestStringIndexing:
    """Test string indexing operations."""

    def test_index_first_character(self):
        """Test getting first character."""
        source = """
text is "Hello"
result is text[0]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "H"

    def test_index_last_character(self):
        """Test getting last character."""
        source = """
text is "World"
result is text[4]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "d"

    def test_index_middle_character(self):
        """Test getting middle character."""
        source = """
text is "Python"
result is text[2]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "t"

    def test_index_out_of_bounds(self):
        """Test indexing out of bounds raises error."""
        source = """
text is "Hi"
result is text[10]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        with pytest.raises(IndexError):
            interpreter.evaluate(ast)


class TestStringSlicing:
    """Test string slicing operations."""

    def test_slice_range(self):
        """Test slicing with start and end."""
        source = """
text is "Hello World"
result is text[0:5]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "Hello"

    def test_slice_from_start(self):
        """Test slicing from beginning."""
        source = """
text is "Python"
result is text[:3]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "Pyt"

    def test_slice_to_end(self):
        """Test slicing to end."""
        source = """
text is "Hello World"
result is text[6:]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "World"

    def test_slice_entire_string(self):
        """Test slicing entire string."""
        source = """
text is "Test"
result is text[:]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "Test"


class TestStringBuiltins:
    """Test string built-in functions."""

    def test_upper_function(self):
        """Test upper function."""
        source = """
text is "hello world"
result is upper of text
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "HELLO WORLD"

    def test_lower_function(self):
        """Test lower function."""
        source = """
text is "HELLO WORLD"
result is lower of text
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "hello world"

    def test_split_function(self):
        """Test split function."""
        source = """
text is "hello world test"
words is split of text
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        words_list = interpreter.environment.lookup("words")
        assert len(words_list.elements) == 3

        word0 = decode_vector(
            words_list.elements[0], interpreter.space, interpreter.metric
        )
        word1 = decode_vector(
            words_list.elements[1], interpreter.space, interpreter.metric
        )
        word2 = decode_vector(
            words_list.elements[2], interpreter.space, interpreter.metric
        )

        assert word0 == "hello"
        assert word1 == "world"
        assert word2 == "test"

    def test_join_function(self):
        """Test join function."""
        source = """
words is ["hello", "world"]
result is join of words
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "hello world"


class TestComplexStringOperations:
    """Test complex combinations of string operations."""

    def test_concat_and_upper(self):
        """Test concatenation followed by upper."""
        source = """
result is upper of ("hello" + " world")
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "HELLO WORLD"

    def test_slice_and_concat(self):
        """Test slicing and concatenation."""
        source = """
text is "Hello World"
result is text[0:5] + text[6:]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "HelloWorld"

    def test_split_index_upper(self):
        """Test split, index, and upper."""
        source = """
text is "hello world"
words is split of text
first is words[0]
result is upper of first
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == "HELLO"
