"""
Tests for predicate handling in the ObserverAnalyzer.

Ensure that predicate usage marks the relevant variables as observed so
predicate checks operate on EigenValue-tracked variables.
"""

import textwrap

from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.compiler.analysis.observer import ObserverAnalyzer


def _analyze(code: str):
    """Helper to run observer analysis on EigenScript code."""
    source = textwrap.dedent(code).strip()
    tokens = Tokenizer(source).tokenize()
    ast = Parser(tokens).parse()
    analyzer = ObserverAnalyzer()
    return analyzer.analyze(ast.statements)


def test_predicate_marks_last_assignment_observed():
    """A predicate condition should mark the last assigned variable as observed."""
    observed = _analyze(
        """
        x is 1
        if converged:
            x is x + 1
        """
    )
    assert "x" in observed


def test_predicate_with_not_marks_last_assignment_observed():
    """NOT predicate conditions should also mark the last assigned variable."""
    observed = _analyze(
        """
        value is 0
        loop while not converged:
            value is value + 1
        """
    )
    assert "value" in observed
