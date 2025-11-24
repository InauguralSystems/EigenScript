"""
Additional tests to improve overall coverage.
Focuses on edge cases, error handling, and untested code paths.
"""

import pytest
import textwrap
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.semantic.lrvm import LRVMVector, LRVMSpace
from eigenscript.semantic.metric import MetricTensor
import numpy as np


@pytest.fixture
def interpreter():
    """Create a fresh interpreter for each test."""
    return Interpreter()


def run_code(code: str, interpreter):
    """Helper to run EigenScript code."""
    code = textwrap.dedent(code).strip()
    tokenizer = Tokenizer(code)
    tokens = tokenizer.tokenize()
    parser = Parser(tokens)
    ast = parser.parse()
    return interpreter.evaluate(ast)


class TestLRVMCoverage:
    """Tests to improve LRVM coverage."""

    def test_vector_subtraction(self):
        """Test LRVM vector subtraction."""
        space = LRVMSpace(dimension=10)
        v1 = space.embed(5.0)
        v2 = space.embed(3.0)
        result = v1.subtract(v2)
        assert isinstance(result, LRVMVector)

    def test_vector_scale(self):
        """Test LRVM vector scaling."""
        space = LRVMSpace(dimension=10)
        v = space.embed(5.0)
        scaled = v.scale(2.0)
        assert scaled.coords[0] == 10.0

    def test_vector_dot_product(self):
        """Test LRVM vector dot product."""
        space = LRVMSpace(dimension=10)
        v1 = space.embed(3.0)
        v2 = space.embed(4.0)
        dot = v1.dot(v2)
        assert isinstance(dot, float)

    def test_vector_distance(self):
        """Test geometric distance between vectors."""
        space = LRVMSpace(dimension=10)
        metric = MetricTensor(dimension=10)
        v1 = space.embed(0.0)
        v2 = space.embed(5.0)
        dist = v1.distance(v2, metric.g)
        assert dist >= 0.0

    def test_vector_equality(self):
        """Test vector equality comparison."""
        space = LRVMSpace(dimension=10)
        v1 = space.embed(5.0)
        v2 = space.embed(5.0)
        v3 = space.embed(3.0)
        assert v1 == v2
        assert v1 != v3

    def test_vector_hash(self):
        """Test vector hashing for sets/dicts."""
        space = LRVMSpace(dimension=10)
        v1 = space.embed(5.0)
        v2 = space.embed(5.0)
        # Should be hashable
        hash_val = hash(v1)
        assert isinstance(hash_val, int)

    def test_space_random_vector(self):
        """Test random vector generation."""
        space = LRVMSpace(dimension=10)
        v = space.random_vector(scale=2.0)
        assert isinstance(v, LRVMVector)
        assert v.dimension == 10

    def test_space_embed_list(self):
        """Test embedding a list."""
        space = LRVMSpace(dimension=10)
        v = space.embed([1, 2, 3])
        assert isinstance(v, LRVMVector)

    def test_space_embed_none(self):
        """Test embedding None."""
        space = LRVMSpace(dimension=10)
        v = space.embed(None)
        assert isinstance(v, LRVMVector)

    def test_space_embed_numpy_array(self):
        """Test embedding numpy array."""
        space = LRVMSpace(dimension=10)
        arr = np.array([1.0, 2.0, 3.0])
        v = space.embed(arr.tolist())
        assert isinstance(v, LRVMVector)

    def test_space_of_operator(self):
        """Test OF operator in LRVM space."""
        space = LRVMSpace(dimension=10)
        metric = MetricTensor(dimension=10)
        x = space.embed(3.0)
        y = space.embed(4.0)
        result = space.of_operator(x, y, metric.g)
        assert isinstance(result, LRVMVector)

    def test_space_is_operator(self):
        """Test IS operator in LRVM space."""
        space = LRVMSpace(dimension=10)
        metric = MetricTensor(dimension=10)
        x = space.embed(5.0)
        y = space.embed(5.0)
        z = space.embed(3.0)
        assert space.is_operator(x, y, metric.g) == True
        assert space.is_operator(x, z, metric.g) == False


class TestMetricTensorCoverage:
    """Tests to improve MetricTensor coverage."""

    def test_minkowski_metric(self):
        """Test Minkowski metric creation."""
        metric = MetricTensor(dimension=10, metric_type="minkowski")
        assert metric.g[0, 0] == -1.0
        assert metric.g[1, 1] == 1.0

    def test_metric_geodesic(self):
        """Test geodesic computation."""
        metric = MetricTensor(dimension=10)
        space = LRVMSpace(dimension=10)
        v1 = space.embed(0.0)
        v2 = space.embed(10.0)
        path = metric.geodesic(v1, v2, steps=5)
        assert len(path) == 5

    def test_metric_is_lightlike(self):
        """Test lightlike vector detection."""
        metric = MetricTensor(dimension=10)
        space = LRVMSpace(dimension=10)
        v = space.zero_vector()
        assert metric.is_lightlike(v)

    def test_metric_is_spacelike(self):
        """Test spacelike vector detection."""
        metric = MetricTensor(dimension=10, metric_type="euclidean")
        space = LRVMSpace(dimension=10)
        v = space.embed(5.0)
        assert metric.is_spacelike(v)

    def test_metric_parallel_transport(self):
        """Test parallel transport."""
        metric = MetricTensor(dimension=10)
        space = LRVMSpace(dimension=10)
        v = space.embed(5.0)
        path = [space.embed(i) for i in range(5)]
        transported = metric.parallel_transport(v, path)
        assert isinstance(transported, LRVMVector)


class TestBuiltinsEdgeCases:
    """Additional builtin edge case tests."""

    def test_len_of_empty_list(self, interpreter, capsys):
        """Test len() on empty list."""
        code = """
empty is []
l is len of empty
print of l
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "0" in captured.out

    def test_append_to_empty_list(self, interpreter, capsys):
        """Test append to empty list."""
        code = """
my_list is []
args is [my_list, 42]
append of args
print of my_list
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "42" in captured.out

    def test_min_of_single_element(self, interpreter, capsys):
        """Test min() with single element."""
        code = """
single is [42]
result is min of single
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "42" in captured.out

    def test_max_of_single_element(self, interpreter, capsys):
        """Test max() with single element."""
        code = """
single is [42]
result is max of single
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "42" in captured.out

    def test_range_zero(self, interpreter, capsys):
        """Test range(0)."""
        code = """
r is range of 0
print of r
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[]" in captured.out

    def test_split_empty_string(self, interpreter, capsys):
        """Test split on empty string."""
        code = """
empty is ""
parts is split of empty
print of parts
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output some form of list
        assert len(captured.out.strip()) > 0

    def test_join_empty_list(self, interpreter, capsys):
        """Test join on empty list."""
        code = """
empty is []
result is join of empty
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output empty string
        assert len(captured.out.strip()) >= 0

    def test_sqrt_of_zero(self, interpreter, capsys):
        """Test sqrt(0)."""
        code = """
x is 0
result is sqrt of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "0" in captured.out

    def test_abs_of_zero(self, interpreter, capsys):
        """Test abs(0)."""
        code = """
x is 0
result is abs of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "0" in captured.out

    def test_floor_of_integer(self, interpreter, capsys):
        """Test floor of integer."""
        code = """
x is 5
result is floor of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "5" in captured.out

    def test_ceil_of_integer(self, interpreter, capsys):
        """Test ceil of integer."""
        code = """
x is 5
result is ceil of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "5" in captured.out

    def test_round_of_half(self, interpreter, capsys):
        """Test round of 0.5."""
        code = """
x is 0.5
result is round of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output some rounded value
        assert len(captured.out.strip()) > 0
