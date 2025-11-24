"""
Observer Effect Analyzer

Detects which variables require geometric tracking (EigenValue) vs raw scalars.

The "Observer Effect": A variable only needs geometric state tracking if it's
interrogated (what, why, how, when, where) or passed to a function that might
interrogate it. Otherwise, it can be compiled to a raw double for C-level speed.

This implements zero-cost abstraction: pay for geometric semantics only when used.
"""

from typing import Set
from eigenscript.parser.ast_builder import (
    ASTNode,
    Identifier,
    Interrogative,
    Relation,
    FunctionDef,
    Assignment,
    Conditional,
    Loop,
    Return,
    BinaryOp,
    UnaryOp,
    ListLiteral,
    Index,
    Program,
)


class ObserverAnalyzer:
    """Analyzes which variables need geometric tracking.

    Variables are "observed" if:
    1. They are interrogated directly (why is x, how is x, etc.)
    2. They are passed to user-defined functions (which might interrogate them)
    3. They are used in predicates (converged, diverging, etc.)

    Unobserved variables can be compiled to raw doubles for maximum performance.
    """

    def __init__(self):
        self.observed: Set[str] = set()
        self.user_functions: Set[str] = set()
        self.current_function: str = None

    def analyze(self, ast_nodes: list[ASTNode]) -> Set[str]:
        """Analyze AST and return set of variable names that need EigenValue tracking.

        Args:
            ast_nodes: List of AST nodes to analyze

        Returns:
            Set of variable names that are "observed" and need geometric tracking
        """
        # Reset state
        self.observed = set()
        self.user_functions = set()
        self.current_function = None

        # First pass: collect all user-defined function names
        for node in ast_nodes:
            if isinstance(node, FunctionDef):
                self.user_functions.add(node.name)

        # Second pass: find observed variables
        for node in ast_nodes:
            self._visit(node)

        return self.observed

    def _visit(self, node: ASTNode):
        """Visit an AST node and detect observations."""
        if node is None:
            return

        if isinstance(node, Program):
            for stmt in node.statements:
                self._visit(stmt)

        elif isinstance(node, FunctionDef):
            # Function parameters are always observed (might be interrogated inside)
            prev_function = self.current_function
            self.current_function = node.name

            # In EigenScript, functions implicitly have parameter 'n'
            self.observed.add("n")

            for stmt in node.body:
                self._visit(stmt)

            self.current_function = prev_function

        elif isinstance(node, Assignment):
            self._visit(node.expression)

        elif isinstance(node, Interrogative):
            # Direct observation: "why is x" marks x as observed
            if isinstance(node.expression, Identifier):
                self.observed.add(node.expression.name)
                # Mark as observed for debugging
                # print(f"  Observed: {node.expression.name} (interrogative: {node.interrogative})")
            self._visit(node.expression)

        elif isinstance(node, Relation):
            # Check if this is a call to a user-defined function
            if isinstance(node.left, Identifier):
                func_name = node.left.name
                if func_name in self.user_functions:
                    # Argument to user function is observed (might be interrogated inside)
                    if isinstance(node.right, Identifier):
                        self.observed.add(node.right.name)
                    elif isinstance(node.right, BinaryOp):
                        # Expression passed to function - observe all identifiers
                        self._mark_expression_observed(node.right)

            self._visit(node.left)
            self._visit(node.right)

        elif isinstance(node, Conditional):
            # Check if condition uses predicates (converged, diverging, etc.)
            self._check_for_predicates(node.condition)
            self._visit(node.condition)
            for stmt in node.if_block:
                self._visit(stmt)
            if node.else_block:
                for stmt in node.else_block:
                    self._visit(stmt)

        elif isinstance(node, Loop):
            self._check_for_predicates(node.condition)
            self._visit(node.condition)
            for stmt in node.body:
                self._visit(stmt)

        elif isinstance(node, Return):
            self._visit(node.expression)

        elif isinstance(node, BinaryOp):
            self._visit(node.left)
            self._visit(node.right)

        elif isinstance(node, UnaryOp):
            self._visit(node.operand)

        elif isinstance(node, ListLiteral):
            for elem in node.elements:
                self._visit(elem)

        elif isinstance(node, Index):
            self._visit(node.list_expr)
            self._visit(node.index_expr)

        elif isinstance(node, Identifier):
            # Check if this identifier is a predicate
            if node.name in [
                "converged",
                "diverging",
                "oscillating",
                "stable",
                "improving",
            ]:
                # Predicates require the last variable to be observed
                # This is a simplified heuristic - ideally we'd track scope
                pass

    def _check_for_predicates(self, node: ASTNode):
        """Check if condition uses predicates (converged, diverging, etc.)."""
        if isinstance(node, Identifier):
            if node.name in [
                "converged",
                "diverging",
                "oscillating",
                "stable",
                "improving",
            ]:
                # TODO: Mark the variable being tested as observed
                # For now, this is handled by the codegen heuristic of "last variable"
                pass

    def _mark_expression_observed(self, node: ASTNode):
        """Recursively mark all identifiers in an expression as observed."""
        if isinstance(node, Identifier):
            self.observed.add(node.name)
        elif isinstance(node, BinaryOp):
            self._mark_expression_observed(node.left)
            self._mark_expression_observed(node.right)
        elif isinstance(node, UnaryOp):
            self._mark_expression_observed(node.operand)
