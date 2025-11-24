"""
Tokenizer for EigenScript.

Converts source code text into a stream of tokens.
"""

from enum import Enum
from dataclasses import dataclass
from typing import List, Optional, Any


class TokenType(Enum):
    """Token types for EigenScript."""

    # Keywords
    OF = "OF"
    IS = "IS"
    IF = "IF"
    ELSE = "ELSE"
    LOOP = "LOOP"
    WHILE = "WHILE"
    DEFINE = "DEFINE"
    AS = "AS"
    RETURN = "RETURN"
    BREAK = "BREAK"
    NULL = "NULL"
    NOT = "NOT"
    AND = "AND"
    OR = "OR"
    FOR = "FOR"
    IN = "IN"
    IMPORT = "IMPORT"

    # Interrogatives (geometric projection operators)
    WHO = "WHO"
    WHAT = "WHAT"
    WHEN = "WHEN"
    WHERE = "WHERE"
    WHY = "WHY"
    HOW = "HOW"

    # Literals
    NUMBER = "NUMBER"
    STRING = "STRING"
    VECTOR = "VECTOR"
    IDENTIFIER = "IDENTIFIER"

    # Operators and Punctuation
    COLON = "COLON"
    COMMA = "COMMA"
    LPAREN = "LPAREN"
    RPAREN = "RPAREN"
    LBRACKET = "LBRACKET"
    RBRACKET = "RBRACKET"
    DOT = "DOT"

    # Arithmetic Operators (equilibrium operations)
    PLUS = "PLUS"
    MINUS = "MINUS"
    MULTIPLY = "MULTIPLY"
    DIVIDE = "DIVIDE"
    MODULO = "MODULO"
    EQUALS = "EQUALS"
    NOT_EQUAL = "NOT_EQUAL"
    LESS_THAN = "LESS_THAN"
    LESS_EQUAL = "LESS_EQUAL"
    GREATER_THAN = "GREATER_THAN"
    GREATER_EQUAL = "GREATER_EQUAL"

    # Whitespace (significant in Python-style indentation)
    NEWLINE = "NEWLINE"
    INDENT = "INDENT"
    DEDENT = "DEDENT"

    # Special
    EOF = "EOF"


@dataclass
class Token:
    """
    Represents a single token in the source code.

    Attributes:
        type: The type of token (from TokenType enum)
        value: The actual value of the token (if applicable)
        line: Line number where token appears
        column: Column number where token starts
    """

    type: TokenType
    value: Any = None
    line: int = 0
    column: int = 0

    def __repr__(self) -> str:
        if self.value is not None:
            return f"Token({self.type.name}, {self.value!r}, {self.line}:{self.column})"
        return f"Token({self.type.name}, {self.line}:{self.column})"


class Tokenizer:
    """
    Tokenizes EigenScript source code.

    This lexer converts raw source text into a stream of tokens
    that can be parsed into an Abstract Syntax Tree (AST).

    Example:
        >>> tokenizer = Tokenizer("x is 5")
        >>> tokens = tokenizer.tokenize()
        >>> print(tokens)
        [Token(IDENTIFIER, 'x'), Token(IS), Token(NUMBER, 5), Token(EOF)]
    """

    # Keywords mapping
    KEYWORDS = {
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
        "not": TokenType.NOT,
        "and": TokenType.AND,
        "or": TokenType.OR,
        "for": TokenType.FOR,
        "in": TokenType.IN,
        "import": TokenType.IMPORT,
        # Interrogatives
        "who": TokenType.WHO,
        "what": TokenType.WHAT,
        "when": TokenType.WHEN,
        "where": TokenType.WHERE,
        "why": TokenType.WHY,
        "how": TokenType.HOW,
    }

    def __init__(self, source: str):
        """
        Initialize the tokenizer with source code.

        Args:
            source: EigenScript source code as string
        """
        self.source = source
        self.position = 0
        self.line = 1
        self.column = 1
        self.tokens: List[Token] = []

        # For tracking indentation (Python-style)
        self.indent_stack = [0]

    def tokenize(self) -> List[Token]:
        """
        Tokenize the entire source code.

        Returns:
            List of tokens including EOF token at the end

        Raises:
            SyntaxError: If invalid syntax is encountered
        """
        # Track if we're at the beginning of a line for indentation
        at_line_start = True

        while self.position < len(self.source):
            # Handle indentation at the start of lines
            if at_line_start:
                self.handle_indentation()
                at_line_start = False
                continue

            # Skip whitespace (but not newlines)
            self.skip_whitespace()

            # Skip comments
            if self.current_char() == "#":
                self.skip_comment()
                continue

            char = self.current_char()

            if char is None:
                break

            # Newlines are significant (for indentation tracking)
            if char == "\n":
                token = Token(TokenType.NEWLINE, line=self.line, column=self.column)
                self.tokens.append(token)
                self.advance()
                at_line_start = True
                continue

            # Numbers
            if char.isdigit() or (
                char == "-" and self.peek_char() and self.peek_char().isdigit()
            ):
                self.tokens.append(self.read_number())
                continue

            # Strings
            if char in ('"', "'"):
                self.tokens.append(self.read_string())
                continue

            # Identifiers and keywords
            if char.isalpha() or char == "_":
                self.tokens.append(self.read_identifier())
                continue

            # Punctuation and Operators
            start_line = self.line
            start_col = self.column

            if char == ":":
                self.advance()
                self.tokens.append(
                    Token(TokenType.COLON, line=start_line, column=start_col)
                )
            elif char == ",":
                self.advance()
                self.tokens.append(
                    Token(TokenType.COMMA, line=start_line, column=start_col)
                )
            elif char == "(":
                self.advance()
                self.tokens.append(
                    Token(TokenType.LPAREN, line=start_line, column=start_col)
                )
            elif char == ")":
                self.advance()
                self.tokens.append(
                    Token(TokenType.RPAREN, line=start_line, column=start_col)
                )
            elif char == "[":
                self.advance()
                self.tokens.append(
                    Token(TokenType.LBRACKET, line=start_line, column=start_col)
                )
            elif char == "]":
                self.advance()
                self.tokens.append(
                    Token(TokenType.RBRACKET, line=start_line, column=start_col)
                )
            # Arithmetic operators
            elif char == "+":
                self.advance()
                self.tokens.append(
                    Token(TokenType.PLUS, line=start_line, column=start_col)
                )
            elif char == "-" and not (self.peek_char() and self.peek_char().isdigit()):
                # Only treat as operator if not start of negative number
                self.advance()
                self.tokens.append(
                    Token(TokenType.MINUS, line=start_line, column=start_col)
                )
            elif char == "*":
                self.advance()
                self.tokens.append(
                    Token(TokenType.MULTIPLY, line=start_line, column=start_col)
                )
            elif char == "/":
                self.advance()
                self.tokens.append(
                    Token(TokenType.DIVIDE, line=start_line, column=start_col)
                )
            elif char == "%":
                self.advance()
                self.tokens.append(
                    Token(TokenType.MODULO, line=start_line, column=start_col)
                )
            elif char == "!":
                self.advance()
                if self.current_char() == "=":
                    self.advance()
                    self.tokens.append(
                        Token(TokenType.NOT_EQUAL, line=start_line, column=start_col)
                    )
                else:
                    raise SyntaxError(
                        f"Unexpected character '!' at line {start_line}, column {start_col}. Did you mean 'not' or '!='?"
                    )
            elif char == "=":
                self.advance()
                self.tokens.append(
                    Token(TokenType.EQUALS, line=start_line, column=start_col)
                )
            elif char == "<":
                self.advance()
                if self.current_char() == "=":
                    self.advance()
                    self.tokens.append(
                        Token(TokenType.LESS_EQUAL, line=start_line, column=start_col)
                    )
                else:
                    self.tokens.append(
                        Token(TokenType.LESS_THAN, line=start_line, column=start_col)
                    )
            elif char == ">":
                self.advance()
                if self.current_char() == "=":
                    self.advance()
                    self.tokens.append(
                        Token(
                            TokenType.GREATER_EQUAL, line=start_line, column=start_col
                        )
                    )
                else:
                    self.tokens.append(
                        Token(TokenType.GREATER_THAN, line=start_line, column=start_col)
                    )
            elif char == ".":
                self.advance()
                self.tokens.append(
                    Token(TokenType.DOT, line=start_line, column=start_col)
                )
            else:
                raise SyntaxError(
                    f"Unexpected character '{char}' at line {self.line}, column {self.column}"
                )

        # Close any remaining indentation levels
        while len(self.indent_stack) > 1:
            self.indent_stack.pop()
            self.tokens.append(
                Token(TokenType.DEDENT, line=self.line, column=self.column)
            )

        # Add EOF token
        self.tokens.append(Token(TokenType.EOF, line=self.line, column=self.column))
        return self.tokens

    def current_char(self) -> Optional[str]:
        """Get current character without advancing."""
        if self.position >= len(self.source):
            return None
        return self.source[self.position]

    def peek_char(self, offset: int = 1) -> Optional[str]:
        """Peek at character ahead without advancing."""
        pos = self.position + offset
        if pos >= len(self.source):
            return None
        return self.source[pos]

    def advance(self) -> Optional[str]:
        """Advance position and return current character."""
        if self.position >= len(self.source):
            return None

        char = self.source[self.position]
        self.position += 1

        if char == "\n":
            self.line += 1
            self.column = 1
        else:
            self.column += 1

        return char

    def skip_whitespace(self):
        """Skip whitespace except newlines (which are significant)."""
        while self.current_char() and self.current_char() in " \t\r":
            self.advance()

    def skip_comment(self):
        """Skip single-line comments starting with #."""
        if self.current_char() == "#":
            while self.current_char() and self.current_char() != "\n":
                self.advance()

    def read_number(self) -> Token:
        """
        Read a number literal (integer or float).

        Returns:
            Token with NUMBER type and numeric value
        """
        start_line = self.line
        start_col = self.column
        num_str = ""

        # Handle negative sign
        if self.current_char() == "-":
            num_str += self.advance()

        # Read digits before decimal point
        while self.current_char() and self.current_char().isdigit():
            num_str += self.advance()

        # Check for decimal point
        if (
            self.current_char() == "."
            and self.peek_char()
            and self.peek_char().isdigit()
        ):
            num_str += self.advance()  # Add the '.'
            while self.current_char() and self.current_char().isdigit():
                num_str += self.advance()

        # Convert to appropriate numeric type
        if "." in num_str:
            value = float(num_str)
        else:
            value = int(num_str)

        return Token(TokenType.NUMBER, value, start_line, start_col)

    def read_string(self) -> Token:
        """
        Read a string literal.

        Returns:
            Token with STRING type and string value
        """
        start_line = self.line
        start_col = self.column

        # Get quote character (either ' or ")
        quote_char = self.advance()
        value = ""

        while self.current_char() and self.current_char() != quote_char:
            char = self.current_char()

            # Handle escape sequences
            if char == "\\":
                self.advance()
                next_char = self.current_char()
                if next_char is None:
                    raise SyntaxError(
                        f"Unterminated string at line {start_line}, column {start_col}"
                    )

                # Common escape sequences
                escape_map = {
                    "n": "\n",
                    "t": "\t",
                    "r": "\r",
                    "\\": "\\",
                    "'": "'",
                    '"': '"',
                }
                value += escape_map.get(next_char, next_char)
                self.advance()
            else:
                value += self.advance()

        # Consume closing quote
        if self.current_char() != quote_char:
            raise SyntaxError(
                f"Unterminated string at line {start_line}, column {start_col}"
            )
        self.advance()

        return Token(TokenType.STRING, value, start_line, start_col)

    def read_identifier(self) -> Token:
        """
        Read an identifier or keyword.

        Returns:
            Token with IDENTIFIER or keyword type
        """
        start_line = self.line
        start_col = self.column
        identifier = ""

        # Read first character (letter or underscore)
        identifier += self.advance()

        # Read remaining characters (letters, digits, underscores)
        while self.current_char() and (
            self.current_char().isalnum() or self.current_char() == "_"
        ):
            identifier += self.advance()

        # Check if it's a keyword
        identifier_lower = identifier.lower()
        if identifier_lower in self.KEYWORDS:
            return Token(
                self.KEYWORDS[identifier_lower], line=start_line, column=start_col
            )

        # It's a regular identifier
        return Token(TokenType.IDENTIFIER, identifier, start_line, start_col)

    def read_vector(self) -> Token:
        """
        Read a vector literal like (1, 2, 3).

        Returns:
            Token with VECTOR type and list value
        """
        # Note: Vector parsing is currently handled by the parser
        # This method is a placeholder for future enhancements
        # For now, vectors are parsed as LPAREN, values, RPAREN sequences
        raise NotImplementedError("Vector literals are parsed at the parser level")

    def handle_indentation(self):
        """
        Handle indentation-based block structure.

        Emits INDENT and DEDENT tokens similar to Python.
        """
        # Count spaces/tabs at the beginning of the line
        indent_level = 0
        start_pos = self.position

        while self.current_char() and self.current_char() in " \t":
            if self.current_char() == " ":
                indent_level += 1
            else:  # tab
                indent_level += 4  # Treat tab as 4 spaces
            self.advance()

        # Skip blank lines (lines with only whitespace)
        if self.current_char() in ("\n", None, "#"):
            return

        # Compare with current indent level
        current_indent = self.indent_stack[-1]

        if indent_level > current_indent:
            # Increased indentation - emit INDENT
            self.indent_stack.append(indent_level)
            self.tokens.append(Token(TokenType.INDENT, line=self.line, column=1))
        elif indent_level < current_indent:
            # Decreased indentation - emit DEDENT(s)
            while len(self.indent_stack) > 1 and self.indent_stack[-1] > indent_level:
                self.indent_stack.pop()
                self.tokens.append(Token(TokenType.DEDENT, line=self.line, column=1))

            # Check for indentation error (mismatched indent level)
            if self.indent_stack[-1] != indent_level:
                raise SyntaxError(
                    f"Indentation error at line {self.line}: "
                    f"expected {self.indent_stack[-1]} spaces, got {indent_level}"
                )
