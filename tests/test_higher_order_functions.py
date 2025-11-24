"""
Tests for higher-order functions: map, filter, and reduce.
"""

import pytest
from eigenscript.evaluator import Interpreter
from eigenscript.evaluator.interpreter import EigenList
from eigenscript.builtins import decode_vector


class TestHigherOrderFunctions:
    """Test map, filter, and reduce operations."""

    @pytest.fixture
    def interpreter(self):
        """Create interpreter instance for testing."""
        return Interpreter()

    def test_map_double(self, interpreter):
        """Test map with doubling function."""
        code = """
define double as:
    return n * 2

numbers is [1, 2, 3, 4, 5]
result is map of [double, numbers]
"""
        result = interpreter.run(code)
        result_var = interpreter.environment.lookup("result")

        # Check that result is a list
        assert isinstance(result_var, EigenList)
        assert len(result_var.elements) == 5

        # Decode elements and verify
        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result_var.elements
        ]
        assert values == [2, 4, 6, 8, 10]

    def test_map_square(self, interpreter):
        """Test map with squaring function."""
        code = """
define square as:
    return n * n

numbers is [1, 2, 3, 4, 5]
result is map of [square, numbers]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.evaluator.interpreter import EigenList

        assert isinstance(result, EigenList)
        assert len(result.elements) == 5

        from eigenscript.builtins import decode_vector

        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [1, 4, 9, 16, 25]

    def test_filter_positive(self, interpreter):
        """Test filter with positive number check."""
        code = """
define is_positive as:
    return n > 0

numbers is [-2, -1, 0, 1, 2, 3]
result is filter of [is_positive, numbers]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.evaluator.interpreter import EigenList

        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        from eigenscript.builtins import decode_vector

        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [1, 2, 3]

    def test_filter_greater_than_5(self, interpreter):
        """Test filter with threshold check."""
        code = """
define greater_than_5 as:
    return n > 5

numbers is [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
result is filter of [greater_than_5, numbers]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.evaluator.interpreter import EigenList

        assert isinstance(result, EigenList)
        assert len(result.elements) == 5

        from eigenscript.builtins import decode_vector

        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [6, 7, 8, 9, 10]

    def test_reduce_sum(self, interpreter):
        """Test reduce with addition."""
        code = """
define add as:
    a is n[0]
    b is n[1]
    return a + b

numbers is [1, 2, 3, 4, 5]
result is reduce of [add, numbers, 0]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.builtins import decode_vector

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 15

    def test_reduce_product(self, interpreter):
        """Test reduce with multiplication."""
        code = """
define multiply as:
    a is n[0]
    b is n[1]
    return a * b

numbers is [1, 2, 3, 4, 5]
result is reduce of [multiply, numbers, 1]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.builtins import decode_vector

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 120

    def test_reduce_max(self, interpreter):
        """Test reduce to find maximum."""
        code = """
define max_of_two as:
    a is n[0]
    b is n[1]
    result is a
    if b > a:
        result is b
    return result

numbers is [3, 7, 2, 9, 1, 5]
result is reduce of [max_of_two, numbers, 0]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.builtins import decode_vector

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 9

    def test_map_empty_list(self, interpreter):
        """Test map with empty list."""
        code = """
define double as:
    return n * 2

numbers is []
result is map of [double, numbers]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.evaluator.interpreter import EigenList

        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_filter_empty_list(self, interpreter):
        """Test filter with empty list."""
        code = """
define is_positive as:
    return n > 0

numbers is []
result is filter of [is_positive, numbers]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.evaluator.interpreter import EigenList

        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_filter_none_match(self, interpreter):
        """Test filter where no elements match."""
        code = """
define greater_than_100 as:
    return n > 100

numbers is [1, 2, 3, 4, 5]
result is filter of [greater_than_100, numbers]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.evaluator.interpreter import EigenList

        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_chained_operations(self, interpreter):
        """Test chaining map, filter, and reduce together."""
        code = """
define is_positive as:
    return n > 0

define double as:
    return n * 2

define add as:
    a is n[0]
    b is n[1]
    return a + b

numbers is [-2, -1, 0, 1, 2, 3]
positives is filter of [is_positive, numbers]
doubled is map of [double, positives]
sum is reduce of [add, doubled, 0]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("sum")

        # positives: [1, 2, 3]
        # doubled: [2, 4, 6]
        # sum: 12
        from eigenscript.builtins import decode_vector

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 12

    def test_map_with_builtin(self, interpreter):
        """Test map with a builtin function."""
        code = """
define make_string as:
    return n

numbers is [1, 2, 3]
result is map of [make_string, numbers]
"""
        interpreter.run(code)
        result = interpreter.environment.lookup("result")

        from eigenscript.evaluator.interpreter import EigenList

        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

    def test_map_error_not_function(self, interpreter):
        """Test map with non-function argument."""
        code = """
numbers is [1, 2, 3]
not_a_function is 42
result is map of [not_a_function, numbers]
"""
        with pytest.raises(TypeError, match="First argument to map must be a function"):
            interpreter.run(code)

    def test_map_error_not_list(self, interpreter):
        """Test map with non-list argument."""
        code = """
define double as:
    return n * 2

not_a_list is 42
result is map of [double, not_a_list]
"""
        with pytest.raises(TypeError, match="Second argument to map must be a list"):
            interpreter.run(code)

    def test_reduce_error_wrong_arg_count(self, interpreter):
        """Test reduce with wrong number of arguments."""
        code = """
define add as:
    a is n[0]
    b is n[1]
    return a + b

numbers is [1, 2, 3]
result is reduce of [add, numbers]
"""
        with pytest.raises(TypeError, match="reduce requires exactly 3 arguments"):
            interpreter.run(code)
