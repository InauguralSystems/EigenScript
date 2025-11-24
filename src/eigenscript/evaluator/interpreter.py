"""
Interpreter for EigenScript.

Executes Abstract Syntax Trees using geometric transformations
in LRVM space.
"""

import numpy as np
from typing import Dict, Optional, Any, List, Union
from dataclasses import dataclass
from eigenscript.parser.ast_builder import *
from eigenscript.semantic.lrvm import LRVMVector, LRVMSpace
from eigenscript.semantic.metric import MetricTensor
from eigenscript.runtime.framework_strength import FrameworkStrengthTracker
from eigenscript.builtins import BuiltinFunction, get_builtins

# Type alias for values that can flow through the interpreter
Value = Union[LRVMVector, "EigenList"]


@dataclass
class Function:
    """
    Represents a function object in EigenScript.

    Functions are timelike transformations stored with their definition
    and lexical closure.
    """

    name: str
    parameters: List[str]
    body: List[ASTNode]
    closure: "Environment"  # Captured environment
    interpreter: Optional["UnifiedInterpreter"] = (
        None  # Reference to interpreter for higher-order functions
    )

    def __repr__(self) -> str:
        return f"Function({self.name!r}, params={self.parameters})"


@dataclass
class EigenList:
    """
    Represents a list object in EigenScript.

    Lists are sequences of LRVM vectors or other EigenLists, allowing
    dynamic collections while maintaining geometric consistency.
    """

    elements: List[Union[LRVMVector, "EigenList"]]

    def __repr__(self) -> str:
        return f"EigenList({len(self.elements)} elements)"

    def __len__(self) -> int:
        return len(self.elements)

    def append(self, element: Union[LRVMVector, "EigenList"]) -> None:
        """
        Append an element to the end of the list.

        Args:
            element: LRVM vector or EigenList to append
        """
        self.elements.append(element)

    def pop(self) -> Union[LRVMVector, "EigenList"]:
        """
        Remove and return the last element from the list.

        Returns:
            The last element (LRVM vector or EigenList)

        Raises:
            IndexError: If the list is empty
        """
        if len(self.elements) == 0:
            raise IndexError("Cannot pop from empty list")
        return self.elements.pop()


class ReturnValue(Exception):
    """
    Exception used to implement return statements.

    Raised when a RETURN statement is executed, carrying the return value.
    """

    def __init__(self, value: Union[LRVMVector, "EigenList"]):
        self.value = value
        super().__init__()


class Environment:
    """
    Manages variable bindings in LRVM space.

    Supports lexical scoping with parent environments.

    Example:
        >>> env = Environment()
        >>> v = LRVMVector([1.0, 0.0, 0.0])
        >>> env.bind("x", v)
        >>> env.lookup("x")
        LRVMVector([1.0, 0.0, 0.0])
    """

    def __init__(self, parent: Optional["Environment"] = None):
        """
        Initialize environment.

        Args:
            parent: Parent environment for nested scopes
        """
        self.bindings: Dict[
            str, Union[LRVMVector, Function, BuiltinFunction, EigenList]
        ] = {}
        self.parent = parent

    def bind(
        self, name: str, value: Union[LRVMVector, Function, BuiltinFunction, EigenList]
    ) -> None:
        """
        Create an immutable binding.

        In EigenScript, bindings are immutable - each IS creates
        a new point in semantic spacetime rather than mutating.

        Args:
            name: Variable name
            value: LRVM vector, Function object, or BuiltinFunction
        """
        self.bindings[name] = value

    def lookup(
        self, name: str
    ) -> Union[LRVMVector, Function, BuiltinFunction, EigenList]:
        """
        Resolve a variable to its value.

        Searches current environment, then parent environments.

        Args:
            name: Variable name

        Returns:
            LRVM vector, Function, BuiltinFunction, or EigenList bound to the name

        Raises:
            NameError: If variable is not defined
        """
        if name in self.bindings:
            return self.bindings[name]
        elif self.parent:
            return self.parent.lookup(name)
        else:
            raise NameError(f"Undefined variable: {name!r}")

    def __repr__(self) -> str:
        """String representation."""
        return f"Environment({len(self.bindings)} bindings)"


class Interpreter:
    """
    Main interpreter for EigenScript.

    Evaluates AST nodes using geometric transformations in LRVM space.

    Example:
        >>> from eigenscript.lexer import Tokenizer
        >>> from eigenscript.parser import Parser
        >>> source = "x is 5"
        >>> tokens = Tokenizer(source).tokenize()
        >>> ast = Parser(tokens).parse()
        >>> interpreter = Interpreter()
        >>> result = interpreter.evaluate(ast)
    """

    def __init__(
        self,
        dimension: int = 768,
        metric_type: str = "euclidean",
        max_iterations: Optional[int] = None,
        convergence_threshold: float = 0.95,
        enable_convergence_detection: bool = True,
    ):
        """
        Initialize the interpreter.

        Args:
            dimension: LRVM space dimensionality
            metric_type: Type of metric tensor to use
            max_iterations: Maximum loop iterations (None = unbounded for Turing completeness)
            convergence_threshold: FS threshold for eigenstate detection (default: 0.95)
            enable_convergence_detection: Enable automatic convergence detection (default: True)
        """
        # Geometric components
        self.space = LRVMSpace(dimension=dimension)
        self.metric = MetricTensor(dimension=dimension, metric_type=metric_type)

        # Runtime state
        self.environment = Environment()
        self.fs_tracker = FrameworkStrengthTracker()
        self.max_iterations = max_iterations

        # Convergence detection
        self.convergence_threshold = convergence_threshold
        self.enable_convergence_detection = enable_convergence_detection
        self.recursion_depth = 0
        self.max_recursion_depth = 1000  # Safety limit

        # Special lightlike OF vector
        self._of_vector = self._create_of_vector()

        # Load built-in functions into environment
        builtins = get_builtins(self.space)
        for name, builtin_func in builtins.items():
            self.environment.bind(name, builtin_func)

    def _create_of_vector(self) -> LRVMVector:
        """
        Create the special lightlike OF vector.

        The OF operator must have ||OF||² = 0 (null norm).

        For different metric signatures:
        - Minkowski (-,+,+,+): Use (1,1,0,...) where -1²+1²=0 (lightlike)
        - Euclidean (+,+,+,+): Only zero vector has norm 0

        The choice of lightlike vector is geometrically correct for each metric type.
        In Euclidean space, the zero vector is the unique lightlike vector.

        Returns:
            Lightlike LRVM vector appropriate for the metric
        """
        if self.metric.metric_type == "minkowski":
            # Minkowski metric: Use (1,1,0,...) for lightlike vector
            # With signature (-,+,+,+): norm = -1² + 1² = -1 + 1 = 0 ✓
            coords = np.zeros(self.space.dimension)
            coords[0] = 1.0  # Timelike component
            coords[1] = 1.0  # Spacelike component
        else:
            # Euclidean metric: Zero vector is the only lightlike vector
            # With signature (+,+,+,+): only ||0||² = 0 satisfies the requirement
            coords = np.zeros(self.space.dimension)

        return LRVMVector(coords)

    def run(self, source: str) -> Union[LRVMVector, EigenList]:
        """
        Convenience method to parse and evaluate source code.

        Args:
            source: EigenScript source code string

        Returns:
            Result of evaluating the program
        """
        from eigenscript.lexer import Tokenizer
        from eigenscript.parser import Parser

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        return self.evaluate(ast)

    def evaluate(self, node: ASTNode) -> Union[LRVMVector, EigenList]:
        """
        Evaluate an AST node to an LRVM vector.

        Dispatches to appropriate evaluation method based on node type.

        Args:
            node: AST node to evaluate

        Returns:
            LRVM vector result

        Raises:
            RuntimeError: If evaluation fails
        """
        if isinstance(node, Program):
            return self._eval_program(node)
        elif isinstance(node, Assignment):
            return self._eval_assignment(node)
        elif isinstance(node, Relation):
            return self._eval_relation(node)
        elif isinstance(node, BinaryOp):
            return self._eval_binary_op(node)
        elif isinstance(node, UnaryOp):
            return self._eval_unary_op(node)
        elif isinstance(node, Conditional):
            return self._eval_conditional(node)
        elif isinstance(node, Loop):
            return self._eval_loop(node)
        elif isinstance(node, FunctionDef):
            return self._eval_function_def(node)
        elif isinstance(node, Return):
            return self._eval_return(node)
        elif isinstance(node, Literal):
            return self._eval_literal(node)
        elif isinstance(node, Identifier):
            return self._eval_identifier(node)
        elif isinstance(node, Interrogative):
            return self._eval_interrogative(node)
        elif isinstance(node, ListLiteral):
            return self._eval_list_literal(node)
        elif isinstance(node, ListComprehension):
            return self._eval_list_comprehension(node)
        elif isinstance(node, Index):
            return self._eval_index(node)
        elif isinstance(node, Slice):
            return self._eval_slice(node)
        else:
            raise RuntimeError(f"Unknown AST node type: {type(node).__name__}")

    def _eval_program(self, node: Program) -> Union[LRVMVector, EigenList]:
        """Evaluate a program (sequence of statements)."""
        result = self.space.zero_vector()

        for statement in node.statements:
            result = self.evaluate(statement)
            # Update Framework Strength tracker (only for vectors)
            if isinstance(result, LRVMVector):
                self.fs_tracker.update(result)

        return result

    def _eval_assignment(self, node: Assignment) -> LRVMVector:
        """
        Evaluate IS operator: x is y

        Semantic: Projection/binding in LRVM space
        """
        # Evaluate right-hand side
        value = self.evaluate(node.expression)

        # Bind in environment (handles both vectors and lists)
        self.environment.bind(node.identifier, value)

        # Return the value as-is (may be EigenList or LRVMVector)
        return value

    def _eval_relation(self, node: Relation) -> LRVMVector:
        """
        Evaluate OF operator: x of y

        Semantic: Metric contraction x^T g y OR function application
        """
        # Special handling for function calls:
        # If left side is an identifier, check if it's a function before evaluating
        if isinstance(node.left, Identifier):
            try:
                left_value = self.environment.lookup(node.left.name)
                if isinstance(left_value, Function):
                    # This is a user-defined function call!
                    return self._call_function(left_value, node.right)
                elif isinstance(left_value, BuiltinFunction):
                    # This is a built-in function call!
                    arg_value = self.evaluate(node.right)
                    # Call built-in (may return EigenList or LRVMVector)
                    return left_value.func(arg_value, self.space, self.metric)
            except NameError:
                pass  # Not found, will evaluate normally below

        # Evaluate both sides normally
        left = self.evaluate(node.left)
        right = self.evaluate(node.right)

        # Check if left is a function (in case it came from a complex expression)
        if isinstance(left, Function):
            # right should already be evaluated
            return self._call_function_with_value(left, right)
        elif isinstance(left, BuiltinFunction):
            # right should already be evaluated
            return left.func(right, self.space, self.metric)

        # Special case: OF of OF = OF
        if self._is_of_vector(left) and self._is_of_vector(right):
            return self._of_vector

        # Perform metric contraction and return as vector
        return self.metric.contract_to_vector(left, right)

    def _eval_binary_op(self, node: "BinaryOp") -> LRVMVector:
        """
        Evaluate binary operators (+, -, *, /, %, =, <, >, <=, >=, !=, and, or).

        Semantic: Operators as equilibrium operations:
            + = additive equilibrium (vector composition)
            - = subtractive equilibrium (directed distance)
            * = multiplicative equilibrium (radial scaling)
            / = projected multiplicative equilibrium (ratio)
            % = modulo equilibrium (cyclic distance)
            = = equality equilibrium (IS test)
            != = inequality equilibrium
            < = proximity to equilibrium test
            <= = proximity or equality
            > = distance from equilibrium test
            >= = distance or equality
            and = logical conjunction (both must hold) - SHORT-CIRCUITS
            or = logical disjunction (either must hold) - SHORT-CIRCUITS
        """
        # Special handling for AND/OR: evaluate left first for short-circuit
        # Initialize right to None for type checker
        right: Optional[Value] = None

        if node.operator in ("and", "or"):
            left = self.evaluate(node.left)
            # Right will be evaluated conditionally in the operator handlers
        else:
            # For all other operators, evaluate both operands
            left = self.evaluate(node.left)
            right = self.evaluate(node.right)

            # Ensure both operands are vectors (not lists) for arithmetic/comparison operations
            # Note: equality operators (=, !=) allow lists for list comparison
            if node.operator in ("+", "-", "*", "/", "%", "<", ">", "<=", ">="):
                if isinstance(left, EigenList) or isinstance(right, EigenList):
                    # Special case: string concatenation with +
                    if (
                        node.operator == "+"
                        and isinstance(left, LRVMVector)
                        and isinstance(right, LRVMVector)
                    ):
                        # Will be handled below in string concatenation
                        pass
                    else:
                        raise TypeError(
                            f"Operator '{node.operator}' requires vector operands, not lists"
                        )

        if node.operator == "+":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for +"
            # Check if both operands are strings (have string_value metadata)
            # Only check metadata if both are LRVMVectors (not EigenLists)
            if isinstance(left, LRVMVector) and isinstance(right, LRVMVector):
                left_str = left.metadata.get("string_value")
                right_str = right.metadata.get("string_value")

                if left_str is not None and right_str is not None:
                    # String concatenation: combine strings and re-embed
                    result_str = left_str + right_str
                    return self.space.embed_string(result_str)

            # Numeric addition: additive equilibrium composition
            # ‖a+b‖² = ‖a‖² + ‖b‖² + 2(a^T g b)
            # At this point both must be LRVMVector due to type check above
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            return left.add(right)

        elif node.operator == "-":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for -"
            # Subtraction: additive equilibrium inversion
            # ‖a-b‖² = ‖a‖² + ‖b‖² - 2(a^T g b)
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            return left.subtract(right)

        elif node.operator == "*":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for *"
            # Multiplication: multiplicative equilibrium scaling
            # Extract scalar from first coordinate and scale
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            scalar = right.coords[0]
            return left.scale(scalar)

        elif node.operator == "/":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for /"
            # Division: projected multiplicative equilibrium
            # Project through inverse scaling
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            scalar = right.coords[0]
            if abs(scalar) < 1e-10:
                raise RuntimeError("Division by zero (equilibrium singularity)")
            return left.scale(1.0 / scalar)

        elif node.operator == "=":
            # right must be defined for equality operators
            assert right is not None, "Right operand must be evaluated for ="
            # Equality: IS operator (equilibrium test)
            # Returns 1 if equal, 0 otherwise (as embedded scalar)

            # Handle list equality
            if isinstance(left, EigenList) and isinstance(right, EigenList):
                # Lists are equal if they have same length and all elements are equal
                if len(left.elements) != len(right.elements):
                    return self.space.embed_scalar(0.0)
                # Check element-wise equality
                for i in range(len(left.elements)):
                    elem_left = left.elements[i]
                    elem_right = right.elements[i]
                    # Both must be vectors for comparison
                    if isinstance(elem_left, EigenList) or isinstance(
                        elem_right, EigenList
                    ):
                        # Nested lists not supported for equality yet
                        return self.space.embed_scalar(0.0)
                    if not self.space.is_operator(elem_left, elem_right, self.metric.g):
                        return self.space.embed_scalar(0.0)
                return self.space.embed_scalar(1.0)
            elif isinstance(left, EigenList) or isinstance(right, EigenList):
                # One is list, one is vector - not equal
                return self.space.embed_scalar(0.0)
            else:
                # Both are vectors
                is_equal = self.space.is_operator(left, right, self.metric.g)
                return self.space.embed_scalar(1.0 if is_equal else 0.0)

        elif node.operator == "<":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for <"
            # Less than: ordered equilibrium test
            # For scalars, compare first coordinate directly
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            left_val = left.coords[0]
            right_val = right.coords[0]
            result = 1.0 if left_val < right_val else 0.0
            return self.space.embed_scalar(result)

        elif node.operator == ">":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for >"
            # Greater than: inverse ordered equilibrium test
            # For scalars, compare first coordinate directly
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            left_val = left.coords[0]
            right_val = right.coords[0]
            result = 1.0 if left_val > right_val else 0.0
            return self.space.embed_scalar(result)

        elif node.operator == "<=":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for <="
            # Less than or equal: ordered equilibrium test with equality
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            left_val = left.coords[0]
            right_val = right.coords[0]
            result = 1.0 if left_val <= right_val else 0.0
            return self.space.embed_scalar(result)

        elif node.operator == ">=":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for >="
            # Greater than or equal: inverse ordered equilibrium test with equality
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            left_val = left.coords[0]
            right_val = right.coords[0]
            result = 1.0 if left_val >= right_val else 0.0
            return self.space.embed_scalar(result)

        elif node.operator == "!=":
            # right must be defined for equality operators
            assert right is not None, "Right operand must be evaluated for !="
            # Not equal: inverse equality equilibrium

            # Handle list inequality
            if isinstance(left, EigenList) and isinstance(right, EigenList):
                # Lists are not equal if they have different length or any element differs
                if len(left.elements) != len(right.elements):
                    return self.space.embed_scalar(1.0)
                # Check element-wise equality
                for i in range(len(left.elements)):
                    elem_left = left.elements[i]
                    elem_right = right.elements[i]
                    # Both must be vectors for comparison
                    if isinstance(elem_left, EigenList) or isinstance(
                        elem_right, EigenList
                    ):
                        # Nested lists not supported for equality yet
                        return self.space.embed_scalar(1.0)
                    if not self.space.is_operator(elem_left, elem_right, self.metric.g):
                        return self.space.embed_scalar(1.0)
                return self.space.embed_scalar(0.0)
            elif isinstance(left, EigenList) or isinstance(right, EigenList):
                # One is list, one is vector - not equal
                return self.space.embed_scalar(1.0)
            else:
                # Both are vectors
                is_equal = self.space.is_operator(left, right, self.metric.g)
                return self.space.embed_scalar(0.0 if is_equal else 1.0)

        elif node.operator == "%":
            # right must be defined for arithmetic operators
            assert right is not None, "Right operand must be evaluated for %"
            # Modulo: cyclic equilibrium (remainder after division)
            assert isinstance(left, LRVMVector) and isinstance(right, LRVMVector)
            left_val = left.coords[0]
            right_val = right.coords[0]
            if abs(right_val) < 1e-10:
                raise RuntimeError("Modulo by zero (cyclic equilibrium singularity)")
            result = left_val % right_val
            return self.space.embed_scalar(result)

        elif node.operator == "and":
            # Logical AND: conjunction equilibrium with short-circuit evaluation
            # Evaluate left first
            if isinstance(left, EigenList):
                raise TypeError(
                    "Logical operator 'and' requires vector operands, not lists"
                )
            left_val = left.coords[0]

            # Short-circuit: if left is false, return false without evaluating right
            if abs(left_val) < 1e-10:
                return self.space.embed_scalar(0.0)

            # Left is true, evaluate right
            right = self.evaluate(node.right)
            if isinstance(right, EigenList):
                raise TypeError(
                    "Logical operator 'and' requires vector operands, not lists"
                )
            right_val = right.coords[0]

            # Return true only if right is also true
            result = 1.0 if abs(right_val) > 1e-10 else 0.0
            return self.space.embed_scalar(result)

        elif node.operator == "or":
            # Logical OR: disjunction equilibrium with short-circuit evaluation
            # Evaluate left first
            if isinstance(left, EigenList):
                raise TypeError(
                    "Logical operator 'or' requires vector operands, not lists"
                )
            left_val = left.coords[0]

            # Short-circuit: if left is true, return true without evaluating right
            if abs(left_val) > 1e-10:
                return self.space.embed_scalar(1.0)

            # Left is false, evaluate right
            right = self.evaluate(node.right)
            if isinstance(right, EigenList):
                raise TypeError(
                    "Logical operator 'or' requires vector operands, not lists"
                )
            right_val = right.coords[0]

            # Return true if right is true
            result = 1.0 if abs(right_val) > 1e-10 else 0.0
            return self.space.embed_scalar(result)

        else:
            raise RuntimeError(f"Unknown binary operator: {node.operator}")

    def _eval_unary_op(self, node: UnaryOp) -> LRVMVector:
        """
        Evaluate unary operators (not).

        Semantic: NOT operator flips boolean value:
            not x → 1.0 if x ≈ 0.0, else 0.0

        Geometric interpretation: ||NOT(x)||² = -||x||²
        Boolean approximation: NOT true = false, NOT false = true
        """
        # Evaluate operand
        operand = self.evaluate(node.operand)

        if node.operator == "not":
            # Ensure operand is a vector, not a list
            if isinstance(operand, EigenList):
                raise TypeError(
                    "Unary operator 'not' requires vector operand, not list"
                )

            # Get the boolean value (first coordinate)
            value = operand.coords[0]

            # Flip: if value is truthy (>0), return 0.0; if falsy (≈0), return 1.0
            result = 0.0 if abs(value) > 1e-10 else 1.0
            return self.space.embed_scalar(result)
        else:
            raise RuntimeError(f"Unknown unary operator: {node.operator}")

    def _eval_conditional(self, node: Conditional) -> Value:
        """
        Evaluate IF statement.

        Semantic: Branch based on value
        - For boolean results (from comparisons): check coords[0] > 0
        - For other values: check norm > 0
        """
        # Evaluate condition
        condition = self.evaluate(node.condition)

        # Ensure condition is a vector, not a list
        if isinstance(condition, EigenList):
            raise TypeError("Conditional requires vector condition, not list")

        # Determine truthiness
        # For comparison results, use first coordinate (0.0 or 1.0)
        # For other values, use norm
        condition_value = condition.coords[0]

        # Branch based on condition value
        # True if first coordinate is non-zero (handles both boolean and norm cases)
        if abs(condition_value) > 1e-10:
            return self._eval_block(node.if_block)
        else:
            if node.else_block:
                return self._eval_block(node.else_block)
            else:
                return self.space.zero_vector()

    def _eval_loop(self, node: Loop) -> Value:
        """
        Evaluate LOOP statement.

        Semantic: Iterate until convergence in LRVM space.

        When max_iterations is None, loops can execute unbounded computation,
        achieving Turing completeness.
        """
        result: Value = self.space.zero_vector()
        previous: Optional[LRVMVector] = None
        convergence_threshold = 1e-6
        iterations = 0

        while True:
            # Check iteration limit (if set)
            if self.max_iterations is not None and iterations >= self.max_iterations:
                break

            # Evaluate condition
            condition = self.evaluate(node.condition)

            # Ensure condition is a vector, not a list
            if isinstance(condition, EigenList):
                raise TypeError("Loop condition requires vector, not list")

            # Exit if condition is "false" (first coordinate ≈ 0)
            # This handles both comparison operators and norm-based conditions
            condition_value = condition.coords[0]
            if abs(condition_value) < convergence_threshold:
                break

            # Execute loop body
            result = self._eval_block(node.body)

            # Check for convergence (only for vector results)
            if isinstance(result, LRVMVector) and previous is not None:
                distance = self.metric.distance(result, previous)
                if distance < convergence_threshold:
                    break

            # Update previous for next iteration
            if isinstance(result, LRVMVector):
                previous = result
            iterations += 1

        return result

    def _eval_function_def(self, node: FunctionDef) -> LRVMVector:
        """
        Evaluate function definition.

        Semantic: Create timelike transformation
        """
        # Create function object with current environment as closure
        func = Function(
            name=node.name,
            parameters=(
                node.parameters if node.parameters else ["n"]
            ),  # Default parameter name
            body=node.body,
            closure=self.environment,
            interpreter=self,  # Store interpreter reference for higher-order functions
        )

        # Bind function in environment
        self.environment.bind(node.name, func)

        # Return a vector representation of the function (for geometric consistency)
        # Functions have timelike signature (negative norm)
        func_vector = self.space.embed_string(f"<function {node.name}>")
        return func_vector

    def _eval_return(self, node: Return) -> LRVMVector:
        """
        Evaluate return statement.

        Semantic: Project onto observer frame

        Raises:
            ReturnValue: To unwind the stack and return from function
        """
        value = self.evaluate(node.expression)
        raise ReturnValue(value)

    def _eval_literal(self, node: Literal) -> LRVMVector:
        """
        Evaluate a literal value.

        Convert literal to LRVM vector using appropriate embedding.
        """
        if node.literal_type == "number":
            return self.space.embed_scalar(float(node.value))
        elif node.literal_type == "string":
            return self.space.embed_string(node.value)
        elif node.literal_type == "null":
            return self.space.zero_vector()
        elif node.literal_type == "vector":
            # node.value should be a list of numbers
            return LRVMVector(node.value)
        else:
            raise RuntimeError(f"Unknown literal type: {node.literal_type}")

    def _eval_list_literal(self, node: ListLiteral) -> EigenList:
        """
        Evaluate a list literal.

        Lists in EigenScript are first-class objects that store sequences
        of LRVM vectors or other EigenLists while maintaining geometric consistency.
        """
        # Evaluate all elements - can be LRVM vectors or EigenLists
        evaluated_elements = []
        for elem in node.elements:
            elem_value = self.evaluate(elem)
            # Store values directly - supports both vectors and nested lists
            evaluated_elements.append(elem_value)

        return EigenList(evaluated_elements)

    def _eval_list_comprehension(self, node: "ListComprehension") -> EigenList:
        """
        Evaluate a list comprehension.

        Syntax: [expression for variable in iterable if condition]

        Geometric semantics:
        - The comprehension transforms each element in semantic spacetime
        - Optional filter creates a constraint manifold
        - Result is a new trajectory through LRVM space

        Example:
            [x * 2 for x in numbers]
            [x for x in numbers if x > 0]
        """
        # Evaluate the iterable expression
        iterable_value = self.evaluate(node.iterable)

        # Ensure it's a list
        if not isinstance(iterable_value, EigenList):
            raise TypeError(
                f"List comprehension requires iterable to be a list, got {type(iterable_value).__name__}"
            )

        # Result accumulator
        result_elements = []

        # Create a new environment for the loop variable (lexical scope)
        old_env = self.environment
        self.environment = Environment(parent=old_env)

        try:
            # Iterate over each element in the iterable
            for element in iterable_value.elements:
                # Bind loop variable to current element
                self.environment.bind(node.variable, element)

                # Evaluate optional filter condition
                if node.condition is not None:
                    condition_value = self.evaluate(node.condition)

                    # Condition must be a vector (boolean check via first coordinate)
                    if isinstance(condition_value, EigenList):
                        raise TypeError(
                            "List comprehension condition requires vector, not list"
                        )

                    # Check if condition is true (using same logic as conditionals)
                    # For comparison results, first coordinate is 0.0 (false) or 1.0 (true)
                    if abs(condition_value.coords[0]) <= 1e-10:
                        continue  # Skip this element (filter out)

                # Evaluate the expression for this element
                expr_value = self.evaluate(node.expression)

                # Collect the result
                result_elements.append(expr_value)
        finally:
            # Restore original environment
            self.environment = old_env

        return EigenList(result_elements)

    def _eval_index(self, node: Index) -> Value:
        """
        Evaluate list or string indexing.

        Supports indexing into EigenLists and strings to extract elements.

        Example:
            my_list[0]  # Get first element from list
            numbers[i]  # Get element at index i from list
            text[0]     # Get first character from string
        """
        # Evaluate the indexed expression
        indexed_value = self.evaluate(node.list_expr)

        # Evaluate the index expression
        index_value = self.evaluate(node.index_expr)

        # Ensure index is a vector, not a list
        if isinstance(index_value, EigenList):
            raise TypeError("Index must be a number, not a list")

        # Decode the index to an integer
        from eigenscript.builtins import decode_vector

        decoded_index = decode_vector(index_value, self.space, self.metric)

        if not isinstance(decoded_index, (int, float)):
            raise TypeError(
                f"Index must be a number, got {type(decoded_index).__name__}"
            )

        index = int(decoded_index)

        # Check if indexed_value is an EigenList
        if isinstance(indexed_value, EigenList):
            # Check bounds
            if index < 0 or index >= len(indexed_value.elements):
                raise IndexError(
                    f"List index {index} out of range (list has {len(indexed_value.elements)} elements)"
                )

            # Return the element
            return indexed_value.elements[index]

        # Check if indexed_value is a string (has string_value metadata)
        elif (
            isinstance(indexed_value, LRVMVector)
            and "string_value" in indexed_value.metadata
        ):
            string_val = indexed_value.metadata["string_value"]

            # Check bounds
            if index < 0 or index >= len(string_val):
                raise IndexError(
                    f"String index {index} out of range (string has {len(string_val)} characters)"
                )

            # Return the character at index as a new string
            char = string_val[index]
            return self.space.embed_string(char)

        else:
            raise TypeError(f"Cannot index into non-list/non-string type")

    def _eval_slice(self, node: Slice) -> Value:
        """
        Evaluate slicing operation for strings and lists.

        Supports slicing syntax:
            text[0:5]    # slice from 0 to 5
            text[2:]     # slice from 2 to end
            text[:3]     # slice from start to 3
            my_list[1:4] # slice list elements

        Args:
            node: Slice AST node

        Returns:
            Sliced string (as LRVM vector) or sliced list (as EigenList)
        """
        # Evaluate the expression being sliced
        sliced_value = self.evaluate(node.expr)

        # Evaluate start and end indices
        from eigenscript.builtins import decode_vector

        start_index = None
        end_index = None

        if node.start is not None:
            start_val = self.evaluate(node.start)
            if isinstance(start_val, EigenList):
                raise TypeError("Slice index must be a number, not a list")
            decoded_start = decode_vector(start_val, self.space, self.metric)
            if not isinstance(decoded_start, (int, float)):
                raise TypeError(
                    f"Slice start must be a number, got {type(decoded_start).__name__}"
                )
            start_index = int(decoded_start)

        if node.end is not None:
            end_val = self.evaluate(node.end)
            if isinstance(end_val, EigenList):
                raise TypeError("Slice index must be a number, not a list")
            decoded_end = decode_vector(end_val, self.space, self.metric)
            if not isinstance(decoded_end, (int, float)):
                raise TypeError(
                    f"Slice end must be a number, got {type(decoded_end).__name__}"
                )
            end_index = int(decoded_end)

        # Handle list slicing
        if isinstance(sliced_value, EigenList):
            # Apply Python slicing rules
            sliced_elements = sliced_value.elements[start_index:end_index]
            return EigenList(sliced_elements)
        # Handle string slicing
        elif (
            isinstance(sliced_value, LRVMVector)
            and "string_value" in sliced_value.metadata
        ):
            string_val = sliced_value.metadata["string_value"]

            # Apply Python slicing rules
            sliced_str = string_val[start_index:end_index]
            return self.space.embed_string(sliced_str)
        else:
            raise TypeError(f"Cannot slice non-list/non-string type")

    def _eval_identifier(
        self, node: Identifier
    ) -> Union[Value, Function, BuiltinFunction]:
        """
        Evaluate an identifier (variable lookup or semantic predicate).

        Supports semantic predicates that evaluate to geometric state:
        - converged: True if FS >= convergence_threshold
        - stable: True if spacetime signature is timelike
        - diverging: True if spacetime signature is spacelike
        - equilibrium: True if at lightlike boundary
        """
        # Special case: OF is the lightlike operator
        if node.name.upper() == "OF":
            return self._of_vector

        # Check for semantic predicates (case-insensitive)
        name_lower = node.name.lower()

        # Geometric state predicates
        if name_lower == "converged":
            # Check if Framework Strength exceeds threshold
            fs = self.fs_tracker.compute_fs()
            result = 1.0 if fs >= self.convergence_threshold else 0.0
            return self.space.embed_scalar(result)

        elif name_lower == "stable":
            # Check if system is timelike (converged, stable dimensions dominate)
            _, classification = self.get_spacetime_signature()
            result = 1.0 if classification == "timelike" else 0.0
            return self.space.embed_scalar(result)

        elif name_lower == "diverging":
            # Check if system is spacelike (exploring, unstable)
            _, classification = self.get_spacetime_signature()
            result = 1.0 if classification == "spacelike" else 0.0
            return self.space.embed_scalar(result)

        elif name_lower == "equilibrium":
            # Check if at lightlike boundary
            _, classification = self.get_spacetime_signature()
            result = 1.0 if classification == "lightlike" else 0.0
            return self.space.embed_scalar(result)

        elif name_lower == "improving":
            # Check if trajectory is contracting (radius decreasing)
            if self.fs_tracker.get_trajectory_length() >= 2:
                recent = self.fs_tracker.trajectory[-2:]
                # Compute radii
                from eigenscript.runtime.eigencontrol import EigenControl

                r1 = np.sqrt(np.dot(recent[0].coords, recent[0].coords))
                r2 = np.sqrt(np.dot(recent[1].coords, recent[1].coords))
                result = 1.0 if r2 < r1 else 0.0
            else:
                result = 0.0
            return self.space.embed_scalar(result)

        elif name_lower == "oscillating":
            # Check for oscillation pattern
            if self.fs_tracker.get_trajectory_length() >= 5:
                values = [state.coords[0] for state in self.fs_tracker.trajectory[-5:]]
                deltas = np.diff(values)
                if len(deltas) > 1:
                    sign_changes = np.sum(np.diff(np.sign(deltas)) != 0)
                    oscillation_score = sign_changes / len(deltas)
                    result = 1.0 if oscillation_score > 0.15 else 0.0
                else:
                    result = 0.0
            else:
                result = 0.0
            return self.space.embed_scalar(result)

        elif name_lower == "framework_strength" or name_lower == "fs":
            # Return current Framework Strength as numeric value
            fs = self.fs_tracker.compute_fs()
            return self.space.embed_scalar(fs)

        elif name_lower == "signature":
            # Return spacetime signature S² - C² as numeric value
            signature, _ = self.get_spacetime_signature()
            return self.space.embed_scalar(signature)

        # Regular variable lookup
        return self.environment.lookup(node.name)

    def _eval_interrogative(self, node: Interrogative) -> LRVMVector:
        """
        Evaluate interrogative operator.

        Interrogatives extract geometric information from expressions:
        - WHO: Identity/entity (extract identifier name as string)
        - WHAT: Magnitude (scalar value r = √I from first coordinate)
        - WHEN: Temporal/iteration coordinate (current recursion depth or iteration count)
        - WHERE: Position (spatial coordinates in semantic space)
        - WHY: Gradient/direction (normalized difference vector if trajectory exists)
        - HOW: Transformation (current Framework Strength as process quality measure)

        Args:
            node: Interrogative AST node

        Returns:
            LRVM vector containing the requested geometric information
        """
        # Evaluate the expression being interrogated
        value = self.evaluate(node.expression)

        interrogative = node.interrogative.lower()

        if interrogative == "who":
            # WHO: Identity extraction
            # If the expression is an identifier, return its name
            # Otherwise, return a representation of the value type
            if isinstance(node.expression, Identifier):
                identity = node.expression.name
            else:
                identity = f"<value at {hex(id(value))}>"
            return self.space.embed_string(identity)

        elif interrogative == "what":
            # WHAT: Magnitude extraction (scalar value)
            # Extract the primary scalar value (first coordinate)
            if isinstance(value, EigenList):
                # For lists, return the length as magnitude
                return self.space.embed_scalar(float(len(value)))
            scalar_value = value.coords[0]
            return self.space.embed_scalar(scalar_value)

        elif interrogative == "when":
            # WHEN: Temporal coordinate
            # Return current iteration/recursion depth or trajectory length
            if self.recursion_depth > 0:
                temporal = float(self.recursion_depth)
            else:
                temporal = float(self.fs_tracker.get_trajectory_length())
            return self.space.embed_scalar(temporal)

        elif interrogative == "where":
            # WHERE: Spatial position
            # Return the coordinates themselves (first few dimensions for readability)
            # Create a readable embedding that preserves position information
            return value  # The value itself IS its position in semantic space

        elif interrogative == "why":
            # WHY: Causal direction (gradient)
            # Compute normalized direction of change from trajectory
            if self.fs_tracker.get_trajectory_length() >= 2:
                recent = self.fs_tracker.trajectory[-2:]
                # Direction vector: where we're going minus where we were
                direction = recent[1].subtract(recent[0])
                # Normalize to unit direction
                norm = np.sqrt(np.dot(direction.coords, direction.coords))
                if norm > 1e-10:
                    direction = direction.scale(1.0 / norm)
                return direction
            else:
                # No trajectory, return zero (no causal direction yet)
                return self.space.zero_vector()

        elif interrogative == "how":
            # HOW: Process quality/transformation
            # Return Framework Strength as measure of "how well" the process is working
            fs = self.fs_tracker.compute_fs()

            # Also compute additional process metrics
            from eigenscript.runtime.eigencontrol import EigenControl

            # If we have trajectory, compute EigenControl geometry
            if self.fs_tracker.get_trajectory_length() >= 2:
                recent = self.fs_tracker.trajectory[-2:]
                eigen = EigenControl(recent[-1], recent[-2])

                # Create a rich "how" response with multiple metrics
                # Embed as a structured description
                how_description = (
                    f"FS={fs:.4f} "
                    f"r={eigen.radius:.4e} "
                    f"κ={eigen.curvature:.4e} "
                    f"{eigen.get_conditioning()}"
                )
                return self.space.embed_string(how_description)
            else:
                # Just return Framework Strength
                return self.space.embed_scalar(fs)

        else:
            raise RuntimeError(f"Unknown interrogative: {interrogative}")

    def _eval_block(self, statements: List[ASTNode]) -> Value:
        """
        Evaluate a block of statements.

        Returns the value of the last statement.
        """
        result: Value = self.space.zero_vector()

        for statement in statements:
            result = self.evaluate(statement)

        return result

    def _call_function(self, func: Function, arg_node: ASTNode) -> Value:
        """
        Call a function with an unevaluated argument expression.

        Args:
            func: Function object to call
            arg_node: AST node for the argument (will be evaluated)

        Returns:
            Result of function execution
        """
        # Evaluate the argument
        arg_value = self.evaluate(arg_node)
        return self._call_function_with_value(func, arg_value)

    def _call_function_with_value(self, func: Function, arg_value: Value) -> Value:
        """
        Call a function with an already-evaluated argument.

        Implements convergence detection: if FS > threshold during recursion,
        return current eigenstate instead of continuing.

        Args:
            func: Function object to call
            arg_value: Evaluated argument value

        Returns:
            Result of function execution or eigenstate if converged
        """
        # Track recursion depth
        self.recursion_depth += 1

        # Safety check: prevent infinite recursion
        if self.recursion_depth > self.max_recursion_depth:
            self.recursion_depth -= 1
            raise RuntimeError(
                f"Maximum recursion depth ({self.max_recursion_depth}) exceeded. "
                "System may be diverging."
            )

        # Convergence detection: check if we've reached eigenstate
        if self.enable_convergence_detection and self.recursion_depth > 2:
            # Update FS tracker with current argument value to build trajectory (only for vectors)
            if isinstance(arg_value, LRVMVector):
                self.fs_tracker.update(arg_value)

            fs = self.fs_tracker.compute_fs()

            # Detect convergence via multiple criteria (inspired by EigenFunction):
            # 1. High Framework Strength (FS > threshold)
            # 2. Fixed-point loop detection (low variance)
            # 3. Oscillation pattern detection (paradox/divergence indicator)
            converged = False
            variance = 0.0
            oscillation_score = 0.0

            if fs >= self.convergence_threshold:
                converged = True
            elif self.recursion_depth > 5:  # Deep enough to detect patterns
                trajectory_len = self.fs_tracker.get_trajectory_length()
                if trajectory_len >= 3:
                    # Check variance of recent states to detect cycles
                    recent_states = self.fs_tracker.trajectory[-3:]
                    coords = np.array([s.coords for s in recent_states])
                    variance = float(np.var(coords))

                    # Low variance indicates a fixed-point or cycle
                    if variance < 1e-6:
                        converged = True

                # Oscillation detection (EigenFunction-inspired)
                # Track sign changes in coordinate deltas to detect paradoxical loops
                if trajectory_len >= 5:
                    # Compute deltas from first coordinate of trajectory
                    values = [
                        state.coords[0] for state in self.fs_tracker.trajectory[-5:]
                    ]
                    deltas = np.diff(values)

                    if len(deltas) > 1:
                        # Count sign changes (oscillation indicator)
                        sign_changes = np.sum(np.diff(np.sign(deltas)) != 0)
                        oscillation_score = sign_changes / len(deltas)

                        # High oscillation (> 0.15) suggests divergence/paradox
                        # In this case, force convergence to eigenstate
                        if oscillation_score > 0.15:
                            converged = True

            if converged:
                # Eigenstate convergence detected!
                self.recursion_depth -= 1

                # Create eigenstate marker vector with diagnostic info
                eigenstate_str = f"<eigenstate FS={fs:.4f} var={variance:.6f} osc={oscillation_score:.3f} depth={self.recursion_depth}>"
                eigenstate = self.space.embed_string(eigenstate_str)
                return eigenstate

        # Create new environment for function execution
        # Parent is the function's closure (lexical scoping)
        func_env = Environment(parent=func.closure)

        # Bind arguments to parameters
        # For now, we support single-argument functions with implicit parameter 'n'
        if func.parameters:
            param_name = func.parameters[0]
        else:
            param_name = "n"  # Default parameter name

        func_env.bind(param_name, arg_value)

        # Also bind under 'arg' for compatibility with tests that use 'arg'
        # This allows functions to use either 'n' or 'arg' as the implicit parameter
        if param_name == "n":
            func_env.bind("arg", arg_value)

        # Execute function body
        # Save current environment and switch to function environment
        saved_env = self.environment
        self.environment = func_env

        try:
            result = self.space.zero_vector()

            # Execute each statement in function body
            for statement in func.body:
                result = self.evaluate(statement)
                # Update Framework Strength tracker during execution
                self.fs_tracker.update(result)

            return result

        except ReturnValue as ret:
            # Return statement was executed
            # Update FS with return value
            self.fs_tracker.update(ret.value)
            return ret.value

        finally:
            # Restore original environment and decrement recursion depth
            self.environment = saved_env
            self.recursion_depth -= 1

    def _is_of_vector(self, vector: LRVMVector) -> bool:
        """
        Check if a vector is the special OF vector.
        """
        return self.metric.is_lightlike(vector)

    def get_framework_strength(self) -> float:
        """
        Get current Framework Strength.

        Returns:
            FS value between 0.0 and 1.0
        """
        return self.fs_tracker.compute_fs()

    def has_converged(self, threshold: float = 0.95) -> bool:
        """
        Check if execution has reached eigenstate convergence.

        Args:
            threshold: FS threshold for convergence

        Returns:
            True if FS >= threshold
        """
        return self.fs_tracker.has_converged(threshold)

    def get_spacetime_signature(
        self, window: int = 10, epsilon: float = 1e-6
    ) -> tuple[float, str]:
        """
        Compute spacetime signature S² - C² inspired by Eigen-Geometric-Control.

        This provides richer convergence diagnostics than FS alone by analyzing
        the dimensional structure of the trajectory:
        - S = number of stable (low-variance) dimensions
        - C = number of changing (high-variance) dimensions

        The signature S² - C² classifies the system state:
        - Timelike (S² - C² > 0): System has converged, stable
        - Lightlike (S² - C² = 0): System at equilibrium boundary
        - Spacelike (S² - C² < 0): System exploring, unstable

        Args:
            window: Number of recent trajectory points to analyze
            epsilon: Variance threshold for considering dimension stable

        Returns:
            Tuple of (signature_value, classification)
            where classification is "timelike", "lightlike", or "spacelike"

        Example:
            >>> signature, classification = interp.get_spacetime_signature()
            >>> print(f"System is {classification} with signature {signature:.2f}")
        """
        trajectory_len = self.fs_tracker.get_trajectory_length()

        if trajectory_len < 2:
            # Not enough data to compute variance
            return 0.0, "lightlike"

        # Get recent trajectory window
        recent_count = min(window, trajectory_len)
        recent_states = self.fs_tracker.trajectory[-recent_count:]

        # Extract coordinate arrays (filter out any non-vectors)
        valid_states = [
            state for state in recent_states if isinstance(state, LRVMVector)
        ]
        if len(valid_states) < 2:
            return 0.0, "lightlike"
        coords_array = np.array([state.coords for state in valid_states])

        # Compute per-dimension variance
        variances = np.var(coords_array, axis=0)

        # Count stable vs changing dimensions
        S = int(np.sum(variances < epsilon))  # Stable count
        C = int(np.sum(variances >= epsilon))  # Changing count

        # Compute spacetime signature
        signature = S**2 - C**2

        # Classify
        if signature > 0:
            classification = "timelike"  # Converged, stable
        elif signature == 0:
            classification = "lightlike"  # Boundary state
        else:  # signature < 0
            classification = "spacelike"  # Exploring, unstable

        return float(signature), classification
