"""
Unit tests for the EigenScript parser.

Tests AST construction from token streams.
"""

import pytest
from eigenscript.lexer import Token, TokenType, Tokenizer
from eigenscript.parser import (
    Parser,
    Assignment,
    Relation,
    Literal,
    Identifier,
    Conditional,
    Loop,
    FunctionDef,
    Return,
    Break,
)


class TestParser:
    """Test suite for the Parser class."""

    def test_parser_initialization(self):
        """Parser should initialize with token list."""
        tokens = [Token(TokenType.EOF)]
        parser = Parser(tokens)
        assert parser.tokens == tokens
        assert parser.position == 0

    def test_empty_program(self):
        """Empty token stream should produce empty program."""
        tokens = [Token(TokenType.EOF)]
        parser = Parser(tokens)
        program = parser.parse()
        assert len(program.statements) == 0

    def test_parse_assignment(self):
        """Should parse assignment statement."""
        # x is 5
        tokens = [
            Token(TokenType.IDENTIFIER, value="x"),
            Token(TokenType.IS),
            Token(TokenType.NUMBER, value=5),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, Assignment)
        assert stmt.identifier == "x"
        assert isinstance(stmt.expression, Literal)
        assert stmt.expression.value == 5

    def test_parse_relation(self):
        """Should parse OF relation."""
        # engine of car
        tokens = [
            Token(TokenType.IDENTIFIER, value="engine"),
            Token(TokenType.OF),
            Token(TokenType.IDENTIFIER, value="car"),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        stmt = program.statements[0]
        assert isinstance(stmt, Relation)
        assert isinstance(stmt.left, Identifier)
        assert stmt.left.name == "engine"
        assert isinstance(stmt.right, Identifier)
        assert stmt.right.name == "car"

    def test_parse_nested_relation(self):
        """Should parse nested OF expressions."""
        # owner of (engine of car)
        tokens = [
            Token(TokenType.IDENTIFIER, value="owner"),
            Token(TokenType.OF),
            Token(TokenType.LPAREN),
            Token(TokenType.IDENTIFIER, value="engine"),
            Token(TokenType.OF),
            Token(TokenType.IDENTIFIER, value="car"),
            Token(TokenType.RPAREN),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        stmt = program.statements[0]
        assert isinstance(stmt, Relation)
        # Left should be "owner"
        assert isinstance(stmt.left, Identifier)
        # Right should be another Relation
        assert isinstance(stmt.right, Relation)

    def test_parse_conditional(self):
        """Should parse IF statement."""
        # if x:
        #     y is 5
        tokens = [
            Token(TokenType.IF),
            Token(TokenType.IDENTIFIER, value="x"),
            Token(TokenType.COLON),
            Token(TokenType.NEWLINE),
            Token(TokenType.INDENT),
            Token(TokenType.IDENTIFIER, value="y"),
            Token(TokenType.IS),
            Token(TokenType.NUMBER, value=5),
            Token(TokenType.NEWLINE),
            Token(TokenType.DEDENT),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, Conditional)
        assert isinstance(stmt.condition, Identifier)
        assert stmt.condition.name == "x"
        assert len(stmt.if_block) == 1
        assert isinstance(stmt.if_block[0], Assignment)

    def test_parse_loop(self):
        """Should parse LOOP statement."""
        # loop while x:
        #     y is 5
        tokens = [
            Token(TokenType.LOOP),
            Token(TokenType.WHILE),
            Token(TokenType.IDENTIFIER, value="x"),
            Token(TokenType.COLON),
            Token(TokenType.NEWLINE),
            Token(TokenType.INDENT),
            Token(TokenType.IDENTIFIER, value="y"),
            Token(TokenType.IS),
            Token(TokenType.NUMBER, value=5),
            Token(TokenType.NEWLINE),
            Token(TokenType.DEDENT),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, Loop)
        assert isinstance(stmt.condition, Identifier)
        assert len(stmt.body) == 1

    def test_parse_function_def(self):
        """Should parse function definition."""
        # define foo as:
        #     return 42
        tokens = [
            Token(TokenType.DEFINE),
            Token(TokenType.IDENTIFIER, value="foo"),
            Token(TokenType.AS),
            Token(TokenType.COLON),
            Token(TokenType.NEWLINE),
            Token(TokenType.INDENT),
            Token(TokenType.RETURN),
            Token(TokenType.NUMBER, value=42),
            Token(TokenType.NEWLINE),
            Token(TokenType.DEDENT),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, FunctionDef)
        assert stmt.name == "foo"
        assert len(stmt.body) == 1
        assert isinstance(stmt.body[0], Return)

    def test_parse_complete_program_with_lexer(self):
        """Should parse complete EigenScript program using lexer and parser."""
        source = "x is 5\ny is x of z"

        # Tokenize
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        # Parse
        parser = Parser(tokens)
        program = parser.parse()

        # Should have 2 statements
        assert len(program.statements) == 2

        # First: x is 5
        assert isinstance(program.statements[0], Assignment)
        assert program.statements[0].identifier == "x"

        # Second: y is x of z
        assert isinstance(program.statements[1], Assignment)
        assert program.statements[1].identifier == "y"
        assert isinstance(program.statements[1].expression, Relation)

    def test_parse_vector_literal(self):
        """Should parse vector literals."""
        # (1, 2, 3)
        tokens = [
            Token(TokenType.LPAREN),
            Token(TokenType.NUMBER, value=1),
            Token(TokenType.COMMA),
            Token(TokenType.NUMBER, value=2),
            Token(TokenType.COMMA),
            Token(TokenType.NUMBER, value=3),
            Token(TokenType.RPAREN),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        stmt = program.statements[0]
        assert isinstance(stmt, Literal)
        assert stmt.literal_type == "vector"
        assert stmt.value == [1, 2, 3]

    def test_parse_string_literal(self):
        """Should parse string literals."""
        tokens = [
            Token(TokenType.STRING, value="hello"),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        stmt = program.statements[0]
        assert isinstance(stmt, Literal)
        assert stmt.literal_type == "string"
        assert stmt.value == "hello"

    def test_parse_break_statement(self):
        """Should parse BREAK statement."""
        tokens = [
            Token(TokenType.BREAK),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, Break)

    def test_parse_right_associative_of(self):
        """OF operator should be right-associative."""
        # a of b of c → a of (b of c)
        tokens = [
            Token(TokenType.IDENTIFIER, value="a"),
            Token(TokenType.OF),
            Token(TokenType.IDENTIFIER, value="b"),
            Token(TokenType.OF),
            Token(TokenType.IDENTIFIER, value="c"),
            Token(TokenType.EOF),
        ]

        parser = Parser(tokens)
        program = parser.parse()

        stmt = program.statements[0]
        # Should be: Relation(a, Relation(b, c))
        assert isinstance(stmt, Relation)
        assert isinstance(stmt.left, Identifier)
        assert stmt.left.name == "a"
        assert isinstance(stmt.right, Relation)
        assert stmt.right.left.name == "b"
        assert stmt.right.right.name == "c"


class TestASTNodes:
    """Test suite for AST node classes."""

    def test_literal_node(self):
        """Literal node should store value and type."""
        lit = Literal(value=42, literal_type="number")
        assert lit.value == 42
        assert lit.literal_type == "number"

    def test_identifier_node(self):
        """Identifier node should store name."""
        ident = Identifier(name="x")
        assert ident.name == "x"

    def test_assignment_node(self):
        """Assignment node should store identifier and expression."""
        expr = Literal(value=5, literal_type="number")
        assign = Assignment(identifier="x", expression=expr)
        assert assign.identifier == "x"
        assert assign.expression == expr

    def test_relation_node(self):
        """Relation node should store left and right."""
        left = Identifier(name="engine")
        right = Identifier(name="car")
        rel = Relation(left=left, right=right)
        assert rel.left == left
        assert rel.right == right
