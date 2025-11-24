"""
EigenScript: A geometric programming language modeling computation
as flow in semantic spacetime.

This package contains the core interpreter and runtime for EigenScript.
"""

__version__ = "0.3.0"
__author__ = "J. McReynolds"

from eigenscript.lexer import Tokenizer, Token, TokenType
from eigenscript.parser import Parser, ASTNode
from eigenscript.evaluator import Interpreter

__all__ = [
    "Tokenizer",
    "Token",
    "TokenType",
    "Parser",
    "ASTNode",
    "Interpreter",
]
