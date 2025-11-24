"""
Unit tests for EigenScript module system (import statement and member access).

Tests parsing of import statements and member access operations.
"""

import pytest
from eigenscript.lexer import Token, TokenType, Tokenizer
from eigenscript.parser import (
    Parser,
    Import,
    MemberAccess,
    Identifier,
    Assignment,
    Literal,
)


class TestModuleTokenization:
    """Test suite for module-related tokenization."""

    def test_import_keyword_tokenization(self):
        """Should tokenize import keyword correctly."""
        tokenizer = Tokenizer("import physics")
        tokens = tokenizer.tokenize()

        assert len(tokens) == 3  # IMPORT, IDENTIFIER, EOF
        assert tokens[0].type == TokenType.IMPORT
        assert tokens[1].type == TokenType.IDENTIFIER
        assert tokens[1].value == "physics"
        assert tokens[2].type == TokenType.EOF

    def test_dot_operator_tokenization(self):
        """Should tokenize DOT operator correctly."""
        tokenizer = Tokenizer("physics.gravity")
        tokens = tokenizer.tokenize()

        assert len(tokens) == 4  # IDENTIFIER, DOT, IDENTIFIER, EOF
        assert tokens[0].type == TokenType.IDENTIFIER
        assert tokens[0].value == "physics"
        assert tokens[1].type == TokenType.DOT
        assert tokens[2].type == TokenType.IDENTIFIER
        assert tokens[2].value == "gravity"
        assert tokens[3].type == TokenType.EOF

    def test_import_with_as_tokenization(self):
        """Should tokenize import with alias correctly."""
        tokenizer = Tokenizer("import math as m")
        tokens = tokenizer.tokenize()

        assert len(tokens) == 5  # IMPORT, IDENTIFIER, AS, IDENTIFIER, EOF
        assert tokens[0].type == TokenType.IMPORT
        assert tokens[1].type == TokenType.IDENTIFIER
        assert tokens[1].value == "math"
        assert tokens[2].type == TokenType.AS
        assert tokens[3].type == TokenType.IDENTIFIER
        assert tokens[3].value == "m"
        assert tokens[4].type == TokenType.EOF

    def test_dot_not_confused_with_float(self):
        """DOT operator should be distinct from decimal numbers."""
        tokenizer = Tokenizer("x.y 3.14")
        tokens = tokenizer.tokenize()

        # x.y should be: IDENTIFIER, DOT, IDENTIFIER
        # 3.14 should be: NUMBER
        assert tokens[0].type == TokenType.IDENTIFIER
        assert tokens[0].value == "x"
        assert tokens[1].type == TokenType.DOT
        assert tokens[2].type == TokenType.IDENTIFIER
        assert tokens[2].value == "y"
        assert tokens[3].type == TokenType.NUMBER
        assert tokens[3].value == 3.14


class TestImportParsing:
    """Test suite for parsing import statements."""

    def test_parse_simple_import(self):
        """Should parse simple import statement."""
        source = "import physics"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, Import)
        assert stmt.module_name == "physics"
        assert stmt.alias is None

    def test_parse_import_with_alias(self):
        """Should parse import statement with alias."""
        source = "import math as m"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, Import)
        assert stmt.module_name == "math"
        assert stmt.alias == "m"

    def test_parse_multiple_imports(self):
        """Should parse multiple import statements."""
        source = """import physics
import math
import geometry"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 3
        assert all(isinstance(stmt, Import) for stmt in program.statements)
        assert program.statements[0].module_name == "physics"
        assert program.statements[1].module_name == "math"
        assert program.statements[2].module_name == "geometry"

    def test_parse_import_with_mixed_statements(self):
        """Should parse imports mixed with other statements."""
        source = """import physics
x is 10
import math
y is 20"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 4
        assert isinstance(program.statements[0], Import)
        assert isinstance(program.statements[1], Assignment)
        assert isinstance(program.statements[2], Import)
        assert isinstance(program.statements[3], Assignment)


class TestMemberAccessParsing:
    """Test suite for parsing member access operations."""

    def test_parse_simple_member_access(self):
        """Should parse simple member access."""
        source = "physics.gravity"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        expr = program.statements[0]
        assert isinstance(expr, MemberAccess)
        assert isinstance(expr.object, Identifier)
        assert expr.object.name == "physics"
        assert expr.member == "gravity"

    def test_parse_member_access_in_assignment(self):
        """Should parse member access in assignment."""
        source = "y is physics.gravity"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, Assignment)
        assert stmt.identifier == "y"
        assert isinstance(stmt.expression, MemberAccess)
        assert isinstance(stmt.expression.object, Identifier)
        assert stmt.expression.object.name == "physics"
        assert stmt.expression.member == "gravity"

    def test_parse_chained_member_access(self):
        """Should parse chained member access."""
        source = "a.b.c"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        expr = program.statements[0]

        # Should be MemberAccess(MemberAccess(Identifier("a"), "b"), "c")
        assert isinstance(expr, MemberAccess)
        assert expr.member == "c"
        assert isinstance(expr.object, MemberAccess)
        assert expr.object.member == "b"
        assert isinstance(expr.object.object, Identifier)
        assert expr.object.object.name == "a"

    def test_parse_member_access_with_operation(self):
        """Should parse member access in arithmetic operations."""
        source = "x is physics.gravity + 1"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 1
        stmt = program.statements[0]
        assert isinstance(stmt, Assignment)
        # The expression should be a BinaryOp with member access on left
        from eigenscript.parser import BinaryOp

        assert isinstance(stmt.expression, BinaryOp)
        assert stmt.expression.operator == "+"
        assert isinstance(stmt.expression.left, MemberAccess)
        assert isinstance(stmt.expression.right, Literal)


class TestCompleteModuleExample:
    """Test suite for complete module usage examples."""

    def test_complete_example_with_import_and_usage(self):
        """Should parse complete example with import and member access."""
        source = """import physics
import math

x is 10
y is physics.gravity of x
z is math.pi"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        assert len(program.statements) == 5

        # Check imports
        assert isinstance(program.statements[0], Import)
        assert program.statements[0].module_name == "physics"
        assert isinstance(program.statements[1], Import)
        assert program.statements[1].module_name == "math"

        # Check assignments
        assert isinstance(program.statements[2], Assignment)
        assert program.statements[2].identifier == "x"

        assert isinstance(program.statements[3], Assignment)
        assert program.statements[3].identifier == "y"
        # The expression should contain member access

        assert isinstance(program.statements[4], Assignment)
        assert program.statements[4].identifier == "z"
        assert isinstance(program.statements[4].expression, MemberAccess)

    def test_import_at_top_of_file(self):
        """Should parse imports at the top of a file correctly."""
        source = """import physics
import math as m
import geometry

define calculate as:
    x is physics.gravity
    y is m.pi
    return x + y"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        program = parser.parse()

        # Should have 3 imports and 1 function definition
        assert len(program.statements) == 4
        assert isinstance(program.statements[0], Import)
        assert isinstance(program.statements[1], Import)
        assert isinstance(program.statements[2], Import)

        from eigenscript.parser import FunctionDef

        assert isinstance(program.statements[3], FunctionDef)


class TestEdgeCases:
    """Test suite for edge cases and error handling."""

    def test_member_access_with_reserved_word_fails_gracefully(self):
        """Member access with reserved words should fail appropriately."""
        # This tests that we properly handle edge cases
        # For now, member names should be identifiers, not keywords
        source = "x.if"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)

        # Should raise SyntaxError because "if" is not an identifier
        with pytest.raises(SyntaxError):
            parser.parse()

    def test_import_without_module_name_fails(self):
        """Import without module name should fail."""
        # Just the IMPORT keyword without identifier
        tokens = [
            Token(TokenType.IMPORT, line=1, column=1),
            Token(TokenType.EOF, line=1, column=7),
        ]
        parser = Parser(tokens)

        with pytest.raises(SyntaxError):
            parser.parse()

    def test_member_access_incomplete_fails(self):
        """Incomplete member access (trailing dot) should fail."""
        source = "x."
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)

        with pytest.raises(SyntaxError):
            parser.parse()
