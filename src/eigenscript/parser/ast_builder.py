"""
Abstract Syntax Tree (AST) builder for EigenScript.

Defines AST node classes and the parser that builds them from tokens.
"""

from dataclasses import dataclass
from typing import List, Optional, Any
from eigenscript.lexer import Token, TokenType


# ============================================================================
# AST Node Classes
# ============================================================================


class ASTNode:
    """Base class for all AST nodes."""

    def __repr__(self) -> str:
        return f"{self.__class__.__name__}()"


@dataclass
class Literal(ASTNode):
    """
    Represents a literal value (number, string, vector, null).

    Example:
        42, "hello", (1, 2, 3), null
    """

    value: Any
    literal_type: str  # "number", "string", "vector", "null", "list"

    def __repr__(self) -> str:
        return f"Literal({self.value!r}, {self.literal_type})"


@dataclass
class ListLiteral(ASTNode):
    """
    Represents a list literal.

    Example:
        [1, 2, 3]
        ["a", "b", "c"]
        [x, y, z]
    """

    elements: List[ASTNode]

    def __repr__(self) -> str:
        return f"ListLiteral({self.elements})"


@dataclass
class ListComprehension(ASTNode):
    """
    Represents a list comprehension.

    Example:
        [x * 2 for x in numbers]
        [x for x in numbers if x > 0]
    """

    expression: ASTNode  # The expression to evaluate for each element
    variable: str  # The loop variable name
    iterable: ASTNode  # The list/iterable to loop over
    condition: Optional[ASTNode] = None  # Optional filter condition

    def __repr__(self) -> str:
        return f"ListComprehension({self.expression}, {self.variable}, {self.iterable}, {self.condition})"


@dataclass
class Index(ASTNode):
    """
    Represents list indexing.

    Example:
        my_list[0]
        numbers[i]
    """

    list_expr: ASTNode
    index_expr: ASTNode

    def __repr__(self) -> str:
        return f"Index({self.list_expr}, {self.index_expr})"


@dataclass
class Slice(ASTNode):
    """
    Represents slicing (for lists and strings).

    Example:
        text[0:5]     # slice from 0 to 5
        text[2:]      # slice from 2 to end
        text[:3]      # slice from start to 3
        my_list[1:4]  # slice list elements
    """

    expr: ASTNode
    start: Optional[ASTNode]  # None means start from beginning
    end: Optional[ASTNode]  # None means go to end

    def __repr__(self) -> str:
        return f"Slice({self.expr}, {self.start}, {self.end})"


@dataclass
class Identifier(ASTNode):
    """
    Represents a variable identifier.

    Example:
        x, my_variable, position
    """

    name: str

    def __repr__(self) -> str:
        return f"Identifier({self.name!r})"


@dataclass
class Relation(ASTNode):
    """
    Represents the OF operator (relational operation).

    Semantic: x of y → x^T g y (metric contraction)

    Example:
        engine of car
        parent of child
    """

    left: ASTNode
    right: ASTNode

    def __repr__(self) -> str:
        return f"Relation({self.left}, {self.right})"


@dataclass
class BinaryOp(ASTNode):
    """
    Represents binary arithmetic operations (+, -, *, /, =, <, >).

    Semantic: Arithmetic operators as equilibrium operations:
        + = additive equilibrium (composition)
        - = subtractive equilibrium (inversion)
        * = multiplicative equilibrium (scaling)
        / = projected multiplicative equilibrium (ratio)
        = = equality equilibrium (IS test)
        < = proximity to equilibrium test
        > = distance from equilibrium test

    Example:
        a + b
        x * 2
        count < 10
    """

    left: ASTNode
    operator: (
        str  # "+", "-", "*", "/", "%", "=", "<", ">", "<=", ">=", "!=", "and", "or"
    )
    right: ASTNode

    def __repr__(self) -> str:
        return f"BinaryOp({self.left}, {self.operator!r}, {self.right})"


@dataclass
class UnaryOp(ASTNode):
    """
    Represents unary operations (not).

    Semantic: NOT operator flips the metric signature:
        not x → ||not x||² = -||x||²
        In boolean terms: not true = false, not false = true

    Example:
        not converged
        not (x = 5)
    """

    operator: str  # "not"
    operand: ASTNode

    def __repr__(self) -> str:
        return f"UnaryOp({self.operator!r}, {self.operand})"


@dataclass
class Assignment(ASTNode):
    """
    Represents the IS operator (identity/binding).

    Semantic: x is y → v_x ← v_y (projection in LRVM space)

    Example:
        position is (3, 4, 0)
        name is "Alice"
    """

    identifier: str
    expression: ASTNode

    def __repr__(self) -> str:
        return f"Assignment({self.identifier!r}, {self.expression})"


@dataclass
class TentativeAssignment(ASTNode):
    """
    Represents the MIGHT IS operator (tentative/hypothesis binding).

    Semantic: x might is y → v_x ← v_y with clarity_type=TENTATIVE

    This creates a binding that is explicitly marked as a hypothesis,
    not yet verified. The program can check for tentative bindings and
    refuse to execute certain operations until intent is clarified.

    From the Communication Clarity Framework:
    - Treats the binding as a hypothesis, not a fact
    - Forces intent to be externalized before execution
    - Prevents reinforcing the false belief that implication was sufficient

    Example:
        count might is 0        # Hypothesis: count starts at zero
        mode might is "strict"  # Hypothesis: we want strict mode
    """

    identifier: str
    expression: ASTNode
    hypothesis: Optional[str] = None  # Optional description of the hypothesis

    def __repr__(self) -> str:
        return f"TentativeAssignment({self.identifier!r}, {self.expression}, hypothesis={self.hypothesis!r})"


@dataclass
class IndexedAssignment(ASTNode):
    """
    Represents indexed assignment (list element assignment).

    Semantic: list[index] is value → set list element at index to value

    Example:
        numbers[0] is 42
        matrix[i][j] is value
    """

    list_expr: ASTNode  # The list/array being indexed (e.g., numbers, matrix[i])
    index_expr: ASTNode  # The index expression
    value: ASTNode  # The value to assign

    def __repr__(self) -> str:
        return f"IndexedAssignment({self.list_expr}, {self.index_expr}, {self.value})"


@dataclass
class Conditional(ASTNode):
    """
    Represents an IF statement (geometric conditional).

    Semantic: Branch based on norm signature of condition

    Example:
        if temperature of greater_than of 80:
            print of "Hot!"
        else:
            print of "Pleasant"
    """

    condition: ASTNode
    if_block: List[ASTNode]
    else_block: Optional[List[ASTNode]] = None

    def __repr__(self) -> str:
        return f"Conditional({self.condition}, if={len(self.if_block)}, else={len(self.else_block) if self.else_block else 0})"


@dataclass
class Loop(ASTNode):
    """
    Represents a LOOP statement (geodesic iteration).

    Semantic: Iterate until convergence in LRVM space

    Example:
        loop while count of less_than of 10:
            print of count
            count is count of add of 1
    """

    condition: ASTNode
    body: List[ASTNode]

    def __repr__(self) -> str:
        return f"Loop({self.condition}, body={len(self.body)})"


@dataclass
class FunctionDef(ASTNode):
    """
    Represents a function definition (timelike transformation).

    Semantic: Creates timelike transformation in LRVM

    Example:
        define factorial as:
            if n is 0:
                return 1
            else:
                return n of multiply of (factorial of (n of subtract of 1))
    """

    name: str
    parameters: List[str]
    body: List[ASTNode]

    def __repr__(self) -> str:
        return f"FunctionDef({self.name!r}, params={self.parameters}, body={len(self.body)})"


@dataclass
class Return(ASTNode):
    """
    Represents a RETURN statement (flow termination).

    Semantic: Project onto observer frame

    Example:
        return result
    """

    expression: ASTNode

    def __repr__(self) -> str:
        return f"Return({self.expression})"


@dataclass
class Break(ASTNode):
    """
    Represents a BREAK statement (loop termination).

    Example:
        break
    """

    def __repr__(self) -> str:
        return "Break()"


@dataclass
class Continue(ASTNode):
    """
    Represents a CONTINUE statement (skip to next loop iteration).

    Example:
        continue
    """

    def __repr__(self) -> str:
        return "Continue()"


@dataclass
class Interrogative(ASTNode):
    """
    Represents an interrogative operator (WHO, WHAT, WHEN, WHERE, WHY, HOW).

    These extract geometric information from expressions:
    - WHO: Identity/entity projection
    - WHAT: Scalar magnitude (r = √I)
    - WHEN: Temporal/iteration coordinate
    - WHERE: Spatial position in semantic space
    - WHY: Causal direction (gradient)
    - HOW: Transformation/process
    - ASSUMES: Hidden variables/assumptions (clarity framework)

    Example:
        what is x
        why is change
        how is convergence
        assumes is x
    """

    interrogative: str  # "who", "what", "when", "where", "why", "how", "assumes"
    expression: ASTNode

    def __repr__(self) -> str:
        return f"Interrogative({self.interrogative!r}, {self.expression})"


@dataclass
class Import(ASTNode):
    """
    Represents an import statement.

    Example:
        import physics
        import math as m
    """

    module_name: str
    alias: Optional[str] = None

    def __repr__(self) -> str:
        return f"Import({self.module_name!r}, alias={self.alias!r})"


@dataclass
class ImportFrom(ASTNode):
    """
    Represents a from...import statement.

    Example:
        from physics import gravity, velocity
        from math import sqrt as square_root
        from geometry import *
        from . import sibling
        from .. import parent
        from .submodule import function
    """

    module_name: (
        str  # Module name (can be "" for relative imports like "from . import")
    )
    names: List[str]  # Names to import (empty list if wildcard)
    aliases: Optional[List[Optional[str]]] = None  # Optional aliases for each name
    wildcard: bool = False  # True for "from module import *"
    level: int = 0  # Relative import level (0=absolute, 1=., 2=.., etc.)

    def __repr__(self) -> str:
        prefix = "." * self.level if self.level > 0 else ""
        module = prefix + self.module_name if self.module_name else prefix
        if self.wildcard:
            return f"ImportFrom({module!r}, wildcard=True)"
        return f"ImportFrom({module!r}, names={self.names}, aliases={self.aliases})"


@dataclass
class MemberAccess(ASTNode):
    """
    Represents accessing a member of a module or object.

    Example:
        physics.gravity
        module.variable
    """

    object: ASTNode  # The module/object (Identifier)
    member: str  # The member name (string)

    def __repr__(self) -> str:
        return f"MemberAccess({self.object}, {self.member!r})"


@dataclass
class StructDef(ASTNode):
    """
    Represents a struct type definition (for self-hosting).

    Defines a new compound data type with named fields.
    Structs are essential for representing tokens, AST nodes, etc.

    Example:
        struct Token:
            type
            value
            line
            column
    """

    name: str  # Struct type name (e.g., "Token")
    fields: List[str]  # Field names in order

    def __repr__(self) -> str:
        return f"StructDef({self.name!r}, fields={self.fields})"


@dataclass
class StructLiteral(ASTNode):
    """
    Represents a struct instantiation.

    Creates an instance of a struct type with field values.

    Example:
        Token of [1, "hello", 10, 5]
        # Creates Token with type=1, value="hello", line=10, column=5
    """

    struct_name: str  # Name of the struct type
    values: List[ASTNode]  # Values for each field (in order)

    def __repr__(self) -> str:
        return f"StructLiteral({self.struct_name!r}, {len(self.values)} values)"


@dataclass
class GPUBlock(ASTNode):
    """
    Represents a GPU compute block.

    Groups operations that should be executed on the GPU,
    enabling batch processing and minimizing host↔device transfers.

    Semantic: GPU blocks use "GPU-lite" EigenValues that only track
    value + gradient on device. Full geometric tracking (stability,
    history) is synced to host on observation.

    Example:
        gpu:
            result is matmul of [A, B]
            normalized is result / norm of result
    """

    body: List[ASTNode]

    def __repr__(self) -> str:
        return f"GPUBlock(body={len(self.body)})"


@dataclass
class Program(ASTNode):
    """
    Represents a complete EigenScript program.

    Contains a list of top-level statements.
    """

    statements: List[ASTNode]

    def __repr__(self) -> str:
        return f"Program({len(self.statements)} statements)"


# ============================================================================
# Parser
# ============================================================================


class Parser:
    """
    Recursive descent parser for EigenScript.

    Converts a token stream into an Abstract Syntax Tree (AST).

    Example:
        >>> from eigenscript.lexer import Tokenizer
        >>> tokenizer = Tokenizer("x is 5")
        >>> tokens = tokenizer.tokenize()
        >>> parser = Parser(tokens)
        >>> ast = parser.parse()
    """

    def __init__(self, tokens: List[Token]):
        """
        Initialize parser with token stream.

        Args:
            tokens: List of tokens from the lexer
        """
        self.tokens = tokens
        self.position = 0

    def parse(self) -> Program:
        """
        Parse the token stream into an AST.

        Returns:
            Program node containing all statements

        Raises:
            SyntaxError: If invalid syntax is encountered
        """
        statements = []

        while self.current_token() and self.current_token().type != TokenType.EOF:
            # Skip newlines at the top level
            if self.current_token().type == TokenType.NEWLINE:
                self.advance()
                continue

            # Parse statement
            stmt = self.parse_statement()
            if stmt:
                statements.append(stmt)

        return Program(statements)

    def current_token(self) -> Optional[Token]:
        """Get current token without advancing."""
        if self.position >= len(self.tokens):
            return None
        return self.tokens[self.position]

    def peek_token(self, offset: int = 1) -> Optional[Token]:
        """Peek at token ahead without advancing."""
        pos = self.position + offset
        if pos >= len(self.tokens):
            return None
        return self.tokens[pos]

    def advance(self) -> Token:
        """Advance to next token and return current."""
        token = self.current_token()
        if token:
            self.position += 1
        return token

    def expect(self, token_type: TokenType) -> Token:
        """
        Expect a specific token type and advance.

        Args:
            token_type: Expected token type

        Returns:
            The matched token

        Raises:
            SyntaxError: If current token doesn't match expected type
        """
        token = self.current_token()
        if not token or token.type != token_type:
            if token:
                raise SyntaxError(
                    f"Line {token.line}, Column {token.column}: "
                    f"Expected {token_type.name}, got {token.type.name}"
                )
            else:
                raise SyntaxError(f"Expected {token_type.name}, got EOF")
        return self.advance()

    def parse_statement(self) -> Optional[ASTNode]:
        """
        Parse a single statement.

        Returns:
            AST node representing the statement
        """
        token = self.current_token()

        if not token or token.type == TokenType.EOF:
            return None

        # Skip newlines
        if token.type == TokenType.NEWLINE:
            self.advance()
            return None

        # FROM - from...import statement
        if token.type == TokenType.FROM:
            return self.parse_import_from()

        # IMPORT - import statement
        if token.type == TokenType.IMPORT:
            return self.parse_import()

        # DEFINE - function definition
        if token.type == TokenType.DEFINE:
            return self.parse_definition()

        # STRUCT - struct type definition (for self-hosting)
        if token.type == TokenType.STRUCT:
            return self.parse_struct_def()

        # GPU - GPU compute block
        if token.type == TokenType.GPU:
            return self.parse_gpu_block()

        # IF - conditional
        if token.type == TokenType.IF:
            return self.parse_conditional()

        # LOOP - loop statement
        if token.type == TokenType.LOOP:
            return self.parse_loop()

        # RETURN - return statement
        if token.type == TokenType.RETURN:
            return self.parse_return()

        # BREAK - break statement
        if token.type == TokenType.BREAK:
            self.advance()
            # Consume optional newline
            if self.current_token() and self.current_token().type == TokenType.NEWLINE:
                self.advance()
            return Break()

        # CONTINUE - continue statement
        if token.type == TokenType.CONTINUE:
            self.advance()
            # Consume optional newline
            if self.current_token() and self.current_token().type == TokenType.NEWLINE:
                self.advance()
            return Continue()

        # Assignment (identifier IS expression) or IndexedAssignment (identifier[idx] IS expression)
        # or TentativeAssignment (identifier MIGHT IS expression)
        if token.type == TokenType.IDENTIFIER:
            # Look ahead for IS token (simple assignment)
            next_token = self.peek_token()
            if next_token and next_token.type == TokenType.IS:
                return self.parse_assignment()

            # Look ahead for MIGHT IS (tentative assignment)
            if next_token and next_token.type == TokenType.MIGHT:
                return self.parse_tentative_assignment()

            # Look ahead for LBRACKET (potential indexed assignment)
            if next_token and next_token.type == TokenType.LBRACKET:
                return self.parse_potential_indexed_assignment()

        # Expression statement (e.g., function call)
        expr = self.parse_expression()

        # Check if this expression is followed by IS (could be indexed assignment)
        if self.current_token() and self.current_token().type == TokenType.IS:
            return self.parse_indexed_assignment_from_expr(expr)

        # Consume optional newline after expression
        if self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        return expr

    def parse_assignment(self) -> Assignment:
        """
        Parse an assignment statement.

        Grammar: identifier IS expression
        """
        # Get identifier
        id_token = self.expect(TokenType.IDENTIFIER)
        identifier = id_token.value

        # Expect IS token
        self.expect(TokenType.IS)

        # Parse expression
        expression = self.parse_expression()

        # Consume optional newline
        if self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        return Assignment(identifier, expression)

    def parse_tentative_assignment(self) -> "TentativeAssignment":
        """
        Parse a tentative assignment statement.

        Grammar: identifier MIGHT IS expression

        This creates a hypothesis binding that must be clarified before
        certain operations can proceed. From the Communication Clarity Framework:
        - Treats the binding as a hypothesis, not a fact
        - Forces intent to be externalized
        - Prevents silent execution on unverified assumptions
        """
        # Get identifier
        id_token = self.expect(TokenType.IDENTIFIER)
        identifier = id_token.value

        # Expect MIGHT token
        self.expect(TokenType.MIGHT)

        # Expect IS token
        self.expect(TokenType.IS)

        # Parse expression
        expression = self.parse_expression()

        # Consume optional newline
        if self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        return TentativeAssignment(identifier, expression)

    def parse_potential_indexed_assignment(self) -> ASTNode:
        """
        Parse potential indexed assignment (identifier[idx] IS expression).

        If we find IS after parsing the indexed expression, it's an indexed assignment.
        Otherwise, it's just an expression statement.

        Grammar: identifier (LBRACKET expression RBRACKET)+ IS expression
        """
        # Parse the left-hand side as an expression (will include indexing)
        expr = self.parse_expression()

        # Check if followed by IS
        if self.current_token() and self.current_token().type == TokenType.IS:
            return self.parse_indexed_assignment_from_expr(expr)

        # Otherwise it's just an expression statement
        if self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        return expr

    def parse_indexed_assignment_from_expr(self, expr: ASTNode) -> "IndexedAssignment":
        """
        Convert an Index expression followed by IS into an IndexedAssignment.

        Args:
            expr: The left-hand side expression (must be an Index node)

        Returns:
            IndexedAssignment node
        """
        from eigenscript.parser.ast_builder import Index, IndexedAssignment

        if not isinstance(expr, Index):
            token = self.current_token()
            if token:
                raise SyntaxError(
                    f"Line {token.line}, Column {token.column}: "
                    f"Cannot assign to expression (expected identifier or indexed expression)"
                )
            else:
                raise SyntaxError("Cannot assign to expression")

        # Consume IS
        self.expect(TokenType.IS)

        # Parse the value expression
        value = self.parse_expression()

        # Consume optional newline
        if self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        return IndexedAssignment(expr.list_expr, expr.index_expr, value)

    def parse_import(self) -> Import:
        """
        Parse an import statement.

        Grammar: IMPORT identifier (AS identifier)?
        """
        self.expect(TokenType.IMPORT)

        module_token = self.expect(TokenType.IDENTIFIER)
        module_name = module_token.value
        alias = None

        # Check for optional alias (AS keyword)
        if self.current_token() and self.current_token().type == TokenType.AS:
            self.advance()  # consume AS
            alias_token = self.expect(TokenType.IDENTIFIER)
            alias = alias_token.value

        # Consume newline if present
        if self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        return Import(module_name, alias)

    def parse_import_from(self) -> ImportFrom:
        """
        Parse a from...import statement.

        Grammar: FROM (DOT* identifier | DOT+) IMPORT (MULTIPLY | identifier (AS identifier)? (, identifier (AS identifier)?)*)

        Examples:
            from physics import gravity
            from math import sqrt, pow
            from utils import norm as magnitude, clamp
            from geometry import *
            from . import sibling
            from .. import parent
            from .submodule import function
        """
        self.expect(TokenType.FROM)

        # Count leading dots for relative imports
        level = 0
        while self.current_token() and self.current_token().type == TokenType.DOT:
            level += 1
            self.advance()

        # Get module name (optional for relative imports)
        module_name = ""
        if self.current_token() and self.current_token().type == TokenType.IDENTIFIER:
            module_token = self.current_token()
            module_name = module_token.value
            self.advance()

        # Expect IMPORT keyword
        self.expect(TokenType.IMPORT)

        # Check for wildcard import (*)
        if self.current_token() and self.current_token().type == TokenType.MULTIPLY:
            self.advance()  # consume *

            # Consume newline if present
            if self.current_token() and self.current_token().type == TokenType.NEWLINE:
                self.advance()

            return ImportFrom(module_name, [], None, wildcard=True, level=level)

        # Parse list of names to import
        names = []
        aliases = []

        # Parse first name
        name_token = self.expect(TokenType.IDENTIFIER)
        names.append(name_token.value)

        # Check for alias
        if self.current_token() and self.current_token().type == TokenType.AS:
            self.advance()  # consume AS
            alias_token = self.expect(TokenType.IDENTIFIER)
            aliases.append(alias_token.value)
        else:
            aliases.append(None)

        # Parse additional names (comma-separated)
        while self.current_token() and self.current_token().type == TokenType.COMMA:
            self.advance()  # consume COMMA

            name_token = self.expect(TokenType.IDENTIFIER)
            names.append(name_token.value)

            # Check for alias
            if self.current_token() and self.current_token().type == TokenType.AS:
                self.advance()  # consume AS
                alias_token = self.expect(TokenType.IDENTIFIER)
                aliases.append(alias_token.value)
            else:
                aliases.append(None)

        # Consume newline if present
        if self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        return ImportFrom(module_name, names, aliases, level=level)

    def parse_definition(self) -> FunctionDef:
        """
        Parse a function definition.

        Grammar: DEFINE identifier (OF (identifier | LBRACKET identifier (COMMA identifier)* RBRACKET))? AS COLON block

        Examples:
            define factorial as:        # no parameters
            define add of x as:         # single parameter
            define add of [x, y] as:    # multiple parameters
        """
        # Consume DEFINE
        self.expect(TokenType.DEFINE)

        # Get function name
        name_token = self.expect(TokenType.IDENTIFIER)
        name = name_token.value

        # Parse optional parameters (OF clause)
        parameters = []
        if self.current_token() and self.current_token().type == TokenType.OF:
            self.advance()  # consume OF

            # Check if parameters are in a list [x, y, z] or single identifier
            if self.current_token() and self.current_token().type == TokenType.LBRACKET:
                self.advance()  # consume LBRACKET

                # Parse parameter list
                if (
                    self.current_token()
                    and self.current_token().type != TokenType.RBRACKET
                ):
                    # First parameter
                    param_token = self.expect(TokenType.IDENTIFIER)
                    parameters.append(param_token.value)

                    # Additional parameters
                    while (
                        self.current_token()
                        and self.current_token().type == TokenType.COMMA
                    ):
                        self.advance()  # consume COMMA
                        param_token = self.expect(TokenType.IDENTIFIER)
                        parameters.append(param_token.value)

                self.expect(TokenType.RBRACKET)
            else:
                # Single parameter
                param_token = self.expect(TokenType.IDENTIFIER)
                parameters.append(param_token.value)

        # Expect AS (optional in some grammars, required here)
        if self.current_token() and self.current_token().type == TokenType.AS:
            self.advance()

        # Expect colon
        self.expect(TokenType.COLON)

        # Consume all newlines (handles comment-only lines)
        while self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        # Parse block
        body = self.parse_block()

        return FunctionDef(name, parameters, body)

    def parse_struct_def(self) -> StructDef:
        """
        Parse a struct type definition.

        Grammar: STRUCT identifier COLON NEWLINE INDENT field+ DEDENT

        Example:
            struct Token:
                type
                value
                line
                column
        """
        # Consume STRUCT
        self.expect(TokenType.STRUCT)

        # Get struct name
        name_token = self.expect(TokenType.IDENTIFIER)
        name = name_token.value

        # Expect colon
        self.expect(TokenType.COLON)

        # Consume all newlines (handles comment-only lines)
        while self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        # Expect INDENT
        self.expect(TokenType.INDENT)

        # Parse field names
        fields = []
        while self.current_token() and self.current_token().type != TokenType.DEDENT:
            # Skip newlines
            if self.current_token().type == TokenType.NEWLINE:
                self.advance()
                continue

            # Each field is just an identifier
            field_token = self.expect(TokenType.IDENTIFIER)
            fields.append(field_token.value)

            # Consume optional newline
            if self.current_token() and self.current_token().type == TokenType.NEWLINE:
                self.advance()

        # Expect DEDENT
        if self.current_token() and self.current_token().type == TokenType.DEDENT:
            self.advance()

        return StructDef(name, fields)

    def parse_gpu_block(self) -> GPUBlock:
        """
        Parse a GPU compute block.

        Grammar: GPU COLON NEWLINE INDENT statement+ DEDENT

        Example:
            gpu:
                result is matmul of [A, B]
                normalized is result / norm of result
        """
        # Consume GPU
        self.expect(TokenType.GPU)

        # Expect colon
        self.expect(TokenType.COLON)

        # Consume all newlines (handles comment-only lines)
        while self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        # Parse block
        body = self.parse_block()

        return GPUBlock(body)

    def parse_conditional(self) -> Conditional:
        """
        Parse an IF statement.

        Grammar: IF expression COLON block (ELSE COLON block)?
        """
        # Consume IF
        self.expect(TokenType.IF)

        # Parse condition
        condition = self.parse_expression()

        # Expect colon
        self.expect(TokenType.COLON)

        # Consume all newlines (handles comment-only lines)
        while self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        # Parse if block
        if_block = self.parse_block()

        # Check for ELSE
        else_block = None
        if self.current_token() and self.current_token().type == TokenType.ELSE:
            self.advance()

            # Expect colon
            self.expect(TokenType.COLON)

            # Consume all newlines (handles comment-only lines)
            while (
                self.current_token() and self.current_token().type == TokenType.NEWLINE
            ):
                self.advance()

            # Parse else block
            else_block = self.parse_block()

        return Conditional(condition, if_block, else_block)

    def parse_loop(self) -> Loop:
        """
        Parse a LOOP statement.

        Grammar: LOOP WHILE expression COLON block
        """
        # Consume LOOP
        self.expect(TokenType.LOOP)

        # Expect WHILE
        self.expect(TokenType.WHILE)

        # Parse condition
        condition = self.parse_expression()

        # Expect colon
        self.expect(TokenType.COLON)

        # Consume all newlines (handles comment-only lines)
        while self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        # Parse loop body
        body = self.parse_block()

        return Loop(condition, body)

    def parse_return(self) -> Return:
        """
        Parse a RETURN statement.

        Grammar: RETURN expression
        """
        # Consume RETURN
        self.expect(TokenType.RETURN)

        # Parse expression
        expression = self.parse_expression()

        # Consume optional newline
        if self.current_token() and self.current_token().type == TokenType.NEWLINE:
            self.advance()

        return Return(expression)

    def parse_interrogative(self) -> Interrogative:
        """
        Parse an interrogative operator.

        Grammar: (WHO | WHAT | WHEN | WHERE | WHY | HOW | WAS | CHANGE | STATUS | TREND | ASSUMES) (IS)? primary

        Example:
            what x
            what is x  (IS is optional and ignored)
            why convergence
            was is x    (previous value)
            change is x (delta/difference)
            status is x (alias for how)
            trend is x  (trajectory analysis)
            assumes is x (hidden variables - clarity framework)
        """
        # Get interrogative type
        token = self.current_token()
        interrogative_map = {
            TokenType.WHO: "who",
            TokenType.WHAT: "what",
            TokenType.WHEN: "when",
            TokenType.WHERE: "where",
            TokenType.WHY: "why",
            TokenType.HOW: "how",
            # Temporal operators
            TokenType.WAS: "was",
            TokenType.CHANGE: "change",
            # Interrogative aliases
            TokenType.STATUS: "status",
            TokenType.TREND: "trend",
            # Clarity operators
            TokenType.ASSUMES: "assumes",
        }
        interrogative = interrogative_map[token.type]
        self.advance()

        # IS is optional after interrogatives (for natural language feel)
        if self.current_token() and self.current_token().type == TokenType.IS:
            self.advance()

        # Parse a primary expression (identifier, literal, etc)
        # This avoids infinite recursion since primary won't parse interrogatives
        expression = self.parse_identifier_or_literal()

        return Interrogative(interrogative, expression)

    def parse_identifier_or_literal(self) -> ASTNode:
        """
        Parse just an identifier or literal (for interrogatives).

        This is a subset of parse_primary that doesn't handle interrogatives.
        """
        token = self.current_token()

        if not token:
            # Get the position from the last token we saw
            last_pos = self.tokens[self.position - 1] if self.position > 0 else None
            if last_pos:
                raise SyntaxError(
                    f"Line {last_pos.line}, Column {last_pos.column}: Unexpected end of input"
                )
            else:
                raise SyntaxError("Unexpected end of input")

        # Number literal
        if token.type == TokenType.NUMBER:
            self.advance()
            return Literal(token.value, "number")

        # String literal
        if token.type == TokenType.STRING:
            self.advance()
            return Literal(token.value, "string")

        # Null literal
        if token.type == TokenType.NULL:
            self.advance()
            return Literal(None, "null")

        # Identifier
        if token.type == TokenType.IDENTIFIER:
            self.advance()
            return Identifier(token.value)

        # Parenthesized expression
        if token.type == TokenType.LPAREN:
            self.advance()
            expr = self.parse_expression()
            self.expect(TokenType.RPAREN)
            return expr

        raise SyntaxError(
            f"Expected identifier or literal, got {token.type.name} at line {token.line}, column {token.column}"
        )

    def parse_block(self) -> List[ASTNode]:
        """
        Parse an indented block of statements.

        Returns:
            List of AST nodes in the block
        """
        statements = []

        # Expect INDENT
        self.expect(TokenType.INDENT)

        # Parse statements until DEDENT
        while self.current_token() and self.current_token().type != TokenType.DEDENT:
            # Skip newlines
            if self.current_token().type == TokenType.NEWLINE:
                self.advance()
                continue

            stmt = self.parse_statement()
            if stmt:
                statements.append(stmt)

        # Expect DEDENT
        self.expect(TokenType.DEDENT)

        return statements

    def parse_expression(self) -> ASTNode:
        """
        Parse an expression.

        This handles operator precedence and expression composition.
        Precedence (lowest to highest):
        1. Logical OR (or)
        2. Logical AND (and)
        3. Comparison (=, <, >, <=, >=, !=)
        4. Addition/Subtraction (+, -)
        5. Multiplication/Division/Modulo (*, /, %)
        6. OF operator
        7. Primary (literals, identifiers, parens)
        """
        return self.parse_logical_or()

    def parse_logical_or(self) -> ASTNode:
        """
        Parse logical OR operator.

        Grammar: logical_and (OR logical_and)*
        """
        left = self.parse_logical_and()

        while self.current_token() and self.current_token().type == TokenType.OR:
            self.advance()
            right = self.parse_logical_and()
            left = BinaryOp(left, "or", right)

        return left

    def parse_logical_and(self) -> ASTNode:
        """
        Parse logical AND operator.

        Grammar: comparison (AND comparison)*
        """
        left = self.parse_comparison()

        while self.current_token() and self.current_token().type == TokenType.AND:
            self.advance()
            right = self.parse_comparison()
            left = BinaryOp(left, "and", right)

        return left

    def parse_comparison(self) -> ASTNode:
        """
        Parse comparison operators (=, <, >, <=, >=, !=).

        Grammar: additive ((EQUALS | LESS_THAN | GREATER_THAN | LESS_EQUAL | GREATER_EQUAL | NOT_EQUAL) additive)*
        """
        left = self.parse_additive()

        while self.current_token() and self.current_token().type in (
            TokenType.EQUALS,
            TokenType.NOT_EQUAL,
            TokenType.LESS_THAN,
            TokenType.LESS_EQUAL,
            TokenType.GREATER_THAN,
            TokenType.GREATER_EQUAL,
        ):
            op_token = self.current_token()
            self.advance()

            right = self.parse_additive()

            op_map = {
                TokenType.EQUALS: "=",
                TokenType.NOT_EQUAL: "!=",
                TokenType.LESS_THAN: "<",
                TokenType.LESS_EQUAL: "<=",
                TokenType.GREATER_THAN: ">",
                TokenType.GREATER_EQUAL: ">=",
            }
            left = BinaryOp(left, op_map[op_token.type], right)

        return left

    def parse_additive(self) -> ASTNode:
        """
        Parse addition and subtraction operators (+, -).

        Grammar: multiplicative ((PLUS | MINUS) multiplicative)*
        """
        left = self.parse_multiplicative()

        while self.current_token() and self.current_token().type in (
            TokenType.PLUS,
            TokenType.MINUS,
        ):
            op_token = self.current_token()
            self.advance()

            right = self.parse_multiplicative()

            op_map = {TokenType.PLUS: "+", TokenType.MINUS: "-"}
            left = BinaryOp(left, op_map[op_token.type], right)

        return left

    def parse_multiplicative(self) -> ASTNode:
        """
        Parse multiplication, division, and modulo operators (*, /, %).

        Grammar: relation ((MULTIPLY | DIVIDE | MODULO) relation)*
        """
        left = self.parse_relation()

        while self.current_token() and self.current_token().type in (
            TokenType.MULTIPLY,
            TokenType.DIVIDE,
            TokenType.MODULO,
        ):
            op_token = self.current_token()
            self.advance()

            right = self.parse_relation()

            op_map = {
                TokenType.MULTIPLY: "*",
                TokenType.DIVIDE: "/",
                TokenType.MODULO: "%",
            }
            left = BinaryOp(left, op_map[op_token.type], right)

        return left

    def parse_relation(self) -> ASTNode:
        """
        Parse a relation (OF operator).

        Grammar: postfix (OF postfix)*

        The OF operator is right-associative:
        a of b of c → a of (b of c)
        """
        # Start with postfix expression (handles indexing)
        left = self.parse_postfix()

        # Handle OF operator (right-associative)
        if self.current_token() and self.current_token().type == TokenType.OF:
            self.advance()
            # Recursively parse right side to handle right-associativity
            right = self.parse_relation()
            return Relation(left, right)

        return left

    def parse_postfix(self) -> ASTNode:
        """
        Parse postfix operators (indexing, slicing, and member access).

        Grammar: unary ( (LBRACKET (slice | index) RBRACKET) | (DOT identifier) )*

        Example:
            my_list[0]       # indexing
            matrix[i][j]     # multiple indexing
            text[0:5]        # slicing
            text[2:]         # slice from 2 to end
            text[:3]         # slice from start to 3
            physics.gravity  # member access
            a.b.c            # chained member access
        """
        expr = self.parse_unary()

        # Handle indexing, slicing, and member access
        while self.current_token() and self.current_token().type in (
            TokenType.LBRACKET,
            TokenType.DOT,
        ):
            if self.current_token().type == TokenType.DOT:
                # Handle Member Access (x.y)
                self.advance()  # consume DOT
                member_token = self.expect(TokenType.IDENTIFIER)
                expr = MemberAccess(expr, member_token.value)
            else:
                # Handle Indexing/Slicing (Existing logic)
                self.advance()

                # Check if this is slicing or indexing
                # Peek ahead to see if there's a colon
                start_expr = None
                end_expr = None

                # Parse the first expression (if any) before potential colon
                if (
                    self.current_token()
                    and self.current_token().type != TokenType.COLON
                    and self.current_token().type != TokenType.RBRACKET
                ):
                    start_expr = self.parse_expression()

                # Check for colon (indicates slicing)
                if (
                    self.current_token()
                    and self.current_token().type == TokenType.COLON
                ):
                    # This is a slice
                    self.advance()  # consume COLON

                    # Parse end expression (if any)
                    if (
                        self.current_token()
                        and self.current_token().type != TokenType.RBRACKET
                    ):
                        end_expr = self.parse_expression()

                    self.expect(TokenType.RBRACKET)
                    expr = Slice(expr, start_expr, end_expr)
                else:
                    # This is regular indexing
                    if start_expr is None:
                        token = self.current_token()
                        if token:
                            raise SyntaxError(
                                f"Line {token.line}, Column {token.column}: Expected index expression"
                            )
                        else:
                            raise SyntaxError("Expected index expression")
                    self.expect(TokenType.RBRACKET)
                    expr = Index(expr, start_expr)

        return expr

    def parse_unary(self) -> ASTNode:
        """
        Parse unary operators (not).

        Grammar: (NOT)* primary

        Example:
            not converged
            not (x = 5)
            not not true
        """
        token = self.current_token()

        # Handle NOT operator
        if token and token.type == TokenType.NOT:
            self.advance()
            operand = self.parse_unary()  # Allow chaining: not not x
            return UnaryOp("not", operand)

        # Otherwise parse primary
        return self.parse_primary()

    def parse_primary(self) -> ASTNode:
        """
        Parse a primary expression (literal, identifier, parenthesized expression, interrogative).

        Grammar: NUMBER | STRING | VECTOR | IDENTIFIER | LPAREN expression RPAREN | interrogative
        """
        token = self.current_token()

        if not token:
            # Get the position from the last token we saw
            last_pos = self.tokens[self.position - 1] if self.position > 0 else None
            if last_pos:
                raise SyntaxError(
                    f"Line {last_pos.line}, Column {last_pos.column}: Unexpected end of input"
                )
            else:
                raise SyntaxError("Unexpected end of input")

        # Interrogative operators
        if token.type in (
            TokenType.WHO,
            TokenType.WHAT,
            TokenType.WHEN,
            TokenType.WHERE,
            TokenType.WHY,
            TokenType.HOW,
            # Temporal operators
            TokenType.WAS,
            TokenType.CHANGE,
            # Interrogative aliases
            TokenType.STATUS,
            TokenType.TREND,
            # Clarity operators
            TokenType.ASSUMES,
        ):
            return self.parse_interrogative()

        # Number literal
        if token.type == TokenType.NUMBER:
            self.advance()
            return Literal(token.value, "number")

        # String literal
        if token.type == TokenType.STRING:
            self.advance()
            return Literal(token.value, "string")

        # Null literal
        if token.type == TokenType.NULL:
            self.advance()
            return Literal(None, "null")

        # Identifier
        if token.type == TokenType.IDENTIFIER:
            self.advance()
            return Identifier(token.value)

        # List literal or list comprehension
        if token.type == TokenType.LBRACKET:
            self.advance()

            # Check for empty list
            if self.current_token() and self.current_token().type == TokenType.RBRACKET:
                self.advance()
                return ListLiteral([])

            # Parse first expression
            first_expr = self.parse_expression()

            # Check if this is a list comprehension: [expr FOR var IN iterable]
            if self.current_token() and self.current_token().type == TokenType.FOR:
                self.advance()  # consume FOR

                # Parse variable name
                if (
                    not self.current_token()
                    or self.current_token().type != TokenType.IDENTIFIER
                ):
                    token = self.current_token()
                    if token:
                        raise SyntaxError(
                            f"Line {token.line}, Column {token.column}: Expected variable name after FOR in list comprehension"
                        )
                    else:
                        raise SyntaxError(
                            "Expected variable name after FOR in list comprehension"
                        )
                var_name = self.current_token().value
                self.advance()

                # Expect IN keyword
                if (
                    not self.current_token()
                    or self.current_token().type != TokenType.IN
                ):
                    token = self.current_token()
                    if token:
                        raise SyntaxError(
                            f"Line {token.line}, Column {token.column}: Expected IN keyword in list comprehension"
                        )
                    else:
                        raise SyntaxError("Expected IN keyword in list comprehension")
                self.advance()

                # Parse iterable expression
                iterable = self.parse_expression()

                # Check for optional IF condition
                condition = None
                if self.current_token() and self.current_token().type == TokenType.IF:
                    self.advance()  # consume IF
                    condition = self.parse_expression()

                self.expect(TokenType.RBRACKET)
                return ListComprehension(first_expr, var_name, iterable, condition)

            # Otherwise, it's a regular list literal
            elements = [first_expr]
            while self.current_token() and self.current_token().type == TokenType.COMMA:
                self.advance()  # consume COMMA
                if (
                    self.current_token()
                    and self.current_token().type != TokenType.RBRACKET
                ):
                    elements.append(self.parse_expression())

            self.expect(TokenType.RBRACKET)
            return ListLiteral(elements)

        # Parenthesized expression or vector literal
        if token.type == TokenType.LPAREN:
            self.advance()

            # Check if it's a vector literal (1, 2, 3)
            # or a parenthesized expression (x of y)
            elements = []
            while (
                self.current_token() and self.current_token().type != TokenType.RPAREN
            ):
                elements.append(self.parse_expression())

                # Check for comma (vector literal)
                if (
                    self.current_token()
                    and self.current_token().type == TokenType.COMMA
                ):
                    self.advance()
                elif (
                    self.current_token()
                    and self.current_token().type != TokenType.RPAREN
                ):
                    # Single expression in parens
                    break

            self.expect(TokenType.RPAREN)

            # If we have multiple elements or saw a comma, it's a vector
            if len(elements) > 1:
                # Extract numeric values if all are literals
                values = []
                for elem in elements:
                    if isinstance(elem, Literal) and elem.literal_type == "number":
                        values.append(elem.value)
                    else:
                        # Mixed types - keep as list of AST nodes
                        return Literal(elements, "vector")
                return Literal(values, "vector")
            elif len(elements) == 1:
                # Single element in parentheses
                return elements[0]
            else:
                # Empty parentheses - treat as empty vector
                return Literal([], "vector")

        # Bracket notation for vectors
        if token.type == TokenType.LBRACKET:
            self.advance()
            elements = []

            while (
                self.current_token() and self.current_token().type != TokenType.RBRACKET
            ):
                elements.append(self.parse_expression())

                if (
                    self.current_token()
                    and self.current_token().type == TokenType.COMMA
                ):
                    self.advance()

            self.expect(TokenType.RBRACKET)

            # Extract values
            values = []
            for elem in elements:
                if isinstance(elem, Literal) and elem.literal_type == "number":
                    values.append(elem.value)
                else:
                    return Literal(elements, "vector")
            return Literal(values, "vector")

        raise SyntaxError(
            f"Unexpected token {token.type.name} at line {token.line}, column {token.column}"
        )
