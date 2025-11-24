"""
Parser module for EigenScript.

This module handles parsing of token streams into Abstract Syntax Trees (AST).
"""

from eigenscript.parser.ast_builder import (
    Parser,
    ASTNode,
    Assignment,
    Relation,
    BinaryOp,
    Conditional,
    Loop,
    FunctionDef,
    Return,
    Break,
    Literal,
    Identifier,
    Program,
    Import,
    MemberAccess,
)

__all__ = [
    "Parser",
    "ASTNode",
    "Assignment",
    "Relation",
    "BinaryOp",
    "Conditional",
    "Loop",
    "FunctionDef",
    "Return",
    "Break",
    "Literal",
    "Identifier",
    "Program",
    "Import",
    "MemberAccess",
]
