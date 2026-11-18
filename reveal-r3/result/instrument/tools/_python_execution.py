"""Shared definition of Python calls which launch or locate executables."""

import ast


EXECUTION_CALL_NAMES = frozenset({
    "system", "popen", "run", "call", "check_call", "check_output",
    "Popen", "which", "execv", "execve", "execvp", "execvpe", "execl",
    "execlp", "execle", "spawnv", "spawnvp", "spawnl", "spawnlp",
})


def name_of(func):
    """Return the unqualified name of an AST call target."""
    if isinstance(func, ast.Attribute):
        return func.attr
    if isinstance(func, ast.Name):
        return func.id
    return ""
