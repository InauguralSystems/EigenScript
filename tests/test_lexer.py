"""
Unit tests for the EigenScript lexer.

Tests tokenization of EigenScript source code.
"""

import pytest
from eigenscript.lexer import Tokenizer, Token, TokenType


class TestTokenizer:
    """Test suite for the Tokenizer class."""

    def test_tokenizer_initialization(self):
        """Tokenizer should initialize with source code."""
        source = "x is 5"
        tokenizer = Tokenizer(source)
        assert tokenizer.source == source
        assert tokenizer.position == 0
        assert tokenizer.line == 1
        assert tokenizer.column == 1

    def test_empty_source(self):
        """Empty source should produce only EOF token."""
        tokenizer = Tokenizer("")
        tokens = tokenizer.tokenize()
        assert len(tokens) == 1
        assert tokens[0].type == TokenType.EOF

    def test_of_operator_tokenization(self):
        """OF operator should be recognized as lightlike token."""
        tokenizer = Tokenizer("x of y")
        tokens = tokenizer.tokenize()

        assert len(tokens) == 4  # IDENTIFIER, OF, IDENTIFIER, EOF
        assert tokens[0].type == TokenType.IDENTIFIER
        assert tokens[0].value == "x"
        assert tokens[1].type == TokenType.OF
        assert tokens[2].type == TokenType.IDENTIFIER
        assert tokens[2].value == "y"
        assert tokens[3].type == TokenType.EOF

    def test_is_operator_tokenization(self):
        """IS operator should be recognized."""
        tokenizer = Tokenizer("x is 5")
        tokens = tokenizer.tokenize()

        assert tokens[0].type == TokenType.IDENTIFIER
        assert tokens[1].type == TokenType.IS
        assert tokens[2].type == TokenType.NUMBER
        assert tokens[2].value == 5

    def test_number_literals(self):
        """Number literals should be tokenized correctly."""
        test_cases = [
            ("42", 42),
            ("3.14", 3.14),
            ("-17", -17),
            ("0.001", 0.001),
        ]

        for source, expected_value in test_cases:
            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            assert tokens[0].type == TokenType.NUMBER
            assert tokens[0].value == expected_value

    def test_string_literals(self):
        """String literals should be tokenized correctly."""
        test_cases = [
            ('"hello"', "hello"),
            ("'world'", "world"),
            ('"EigenScript"', "EigenScript"),
        ]

        for source, expected_value in test_cases:
            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            assert tokens[0].type == TokenType.STRING
            assert tokens[0].value == expected_value

    def test_keywords(self):
        """Keywords should be recognized."""
        keywords = ["of", "is", "if", "else", "loop", "while", "define", "as", "return"]

        for keyword in keywords:
            tokenizer = Tokenizer(keyword)
            tokens = tokenizer.tokenize()
            assert tokens[0].type == TokenType[keyword.upper()]

    def test_identifiers_vs_keywords(self):
        """Identifiers should be distinguished from keywords."""
        tokenizer = Tokenizer("offset")  # Contains 'of' but is identifier
        tokens = tokenizer.tokenize()
        assert tokens[0].type == TokenType.IDENTIFIER
        assert tokens[0].value == "offset"

    def test_vector_literals(self):
        """Vector literals should be tokenized."""
        tokenizer = Tokenizer("(1, 2, 3)")
        tokens = tokenizer.tokenize()
        # Should recognize as LPAREN, numbers, commas, RPAREN
        assert tokens[0].type == TokenType.LPAREN
        assert tokens[1].type == TokenType.NUMBER
        assert tokens[1].value == 1
        assert tokens[2].type == TokenType.COMMA
        assert tokens[3].type == TokenType.NUMBER
        assert tokens[3].value == 2
        assert tokens[4].type == TokenType.COMMA
        assert tokens[5].type == TokenType.NUMBER
        assert tokens[5].value == 3
        assert tokens[6].type == TokenType.RPAREN

    def test_comments(self):
        """Comments should be ignored."""
        tokenizer = Tokenizer("x is 5  # This is a comment")
        tokens = tokenizer.tokenize()

        # Should only have: IDENTIFIER, IS, NUMBER, EOF
        # Comment should be skipped
        non_eof_tokens = [t for t in tokens if t.type != TokenType.EOF]
        assert len(non_eof_tokens) == 3

    def test_indentation_tracking(self):
        """Indentation should produce INDENT/DEDENT tokens."""
        source = """if x:
    y is 5
    z is 10
done"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        # Should have INDENT and DEDENT tokens
        indent_tokens = [t for t in tokens if t.type == TokenType.INDENT]
        dedent_tokens = [t for t in tokens if t.type == TokenType.DEDENT]

        assert len(indent_tokens) > 0
        assert len(dedent_tokens) > 0

    def test_nested_of_expressions(self):
        """Nested OF expressions should tokenize correctly."""
        tokenizer = Tokenizer("owner of (engine of car)")
        tokens = tokenizer.tokenize()

        # Should have proper nesting with parentheses
        of_tokens = [t for t in tokens if t.type == TokenType.OF]
        assert len(of_tokens) == 2

    def test_string_escape_sequences(self):
        """String literals should handle escape sequences."""
        test_cases = [
            (r'"hello\nworld"', "hello\nworld"),
            (r'"tab\there"', "tab\there"),
            (r'"quote\"here"', 'quote"here'),
            (r"'single\'quote'", "single'quote"),
        ]

        for source, expected_value in test_cases:
            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            assert tokens[0].type == TokenType.STRING
            assert tokens[0].value == expected_value

    def test_complex_expression(self):
        """Complex EigenScript expression should tokenize correctly."""
        source = "z is x of y"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        # z, IS, x, OF, y, EOF
        assert len(tokens) == 6
        assert tokens[0].type == TokenType.IDENTIFIER
        assert tokens[0].value == "z"
        assert tokens[1].type == TokenType.IS
        assert tokens[2].type == TokenType.IDENTIFIER
        assert tokens[2].value == "x"
        assert tokens[3].type == TokenType.OF
        assert tokens[4].type == TokenType.IDENTIFIER
        assert tokens[4].value == "y"
        assert tokens[5].type == TokenType.EOF

    def test_all_keywords(self):
        """All EigenScript keywords should be recognized."""
        keywords_map = {
            "of": TokenType.OF,
            "is": TokenType.IS,
            "if": TokenType.IF,
            "else": TokenType.ELSE,
            "loop": TokenType.LOOP,
            "while": TokenType.WHILE,
            "define": TokenType.DEFINE,
            "as": TokenType.AS,
            "return": TokenType.RETURN,
            "break": TokenType.BREAK,
            "null": TokenType.NULL,
        }

        for keyword, expected_type in keywords_map.items():
            tokenizer = Tokenizer(keyword)
            tokens = tokenizer.tokenize()
            assert tokens[0].type == expected_type

    def test_case_insensitive_keywords(self):
        """Keywords should be case-insensitive."""
        test_cases = ["IS", "Is", "iS", "is", "OF", "Of", "oF", "of"]

        for keyword in test_cases:
            tokenizer = Tokenizer(keyword)
            tokens = tokenizer.tokenize()
            expected_type = TokenType.IS if keyword.lower() == "is" else TokenType.OF
            assert tokens[0].type == expected_type

    def test_punctuation_tokens(self):
        """All punctuation tokens should be recognized."""
        test_cases = [
            (":", TokenType.COLON),
            (",", TokenType.COMMA),
            ("(", TokenType.LPAREN),
            (")", TokenType.RPAREN),
            ("[", TokenType.LBRACKET),
            ("]", TokenType.RBRACKET),
        ]

        for source, expected_type in test_cases:
            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            assert tokens[0].type == expected_type

    def test_line_and_column_tracking(self):
        """Tokenizer should track line and column positions."""
        source = "x is 5\ny is 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        # First line tokens: x(1,1), is(1,3), 5(1,6)
        assert tokens[0].line == 1
        assert tokens[0].column == 1

        # Find 'y' token (should be on line 2)
        y_token = next(
            t for t in tokens if t.type == TokenType.IDENTIFIER and t.value == "y"
        )
        assert y_token.line == 2

    def test_multiple_indentation_levels(self):
        """Multiple indentation levels should be tracked correctly."""
        source = """define func:
    if x:
        y is 5
    z is 10"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        indent_count = sum(1 for t in tokens if t.type == TokenType.INDENT)
        dedent_count = sum(1 for t in tokens if t.type == TokenType.DEDENT)

        # Should have 2 INDENTs (one for func body, one for if body)
        # and 2 DEDENTs (one when returning to func level, one at end)
        assert indent_count == 2
        assert dedent_count == 2

    def test_blank_lines_ignored(self):
        """Blank lines should not affect indentation tracking."""
        source = """x is 5

y is 10"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        # Should not produce any INDENT/DEDENT tokens
        indent_dedent = [
            t for t in tokens if t.type in (TokenType.INDENT, TokenType.DEDENT)
        ]
        assert len(indent_dedent) == 0

    def test_equilibrium_expression(self):
        """Equilibrium expression (core EigenScript concept) should tokenize."""
        source = "equilibrium is x of y"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        # equilibrium (IDENTIFIER), IS, x (IDENTIFIER), OF, y (IDENTIFIER), EOF
        assert tokens[0].type == TokenType.IDENTIFIER
        assert tokens[0].value == "equilibrium"
        assert tokens[1].type == TokenType.IS
        assert tokens[2].type == TokenType.IDENTIFIER
        assert tokens[3].type == TokenType.OF
        assert tokens[4].type == TokenType.IDENTIFIER


class TestToken:
    """Test suite for the Token class."""

    def test_token_creation(self):
        """Token should be created with type and value."""
        token = Token(TokenType.NUMBER, value=42, line=1, column=5)
        assert token.type == TokenType.NUMBER
        assert token.value == 42
        assert token.line == 1
        assert token.column == 5

    def test_token_repr(self):
        """Token should have readable string representation."""
        token = Token(TokenType.IDENTIFIER, value="x", line=1, column=1)
        repr_str = repr(token)
        assert "IDENTIFIER" in repr_str
        assert "x" in repr_str
