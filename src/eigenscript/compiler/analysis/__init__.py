"""
EigenScript Compiler Analysis Passes

This module contains semantic analysis passes that run before code generation.
"""

from eigenscript.compiler.analysis.observer import ObserverAnalyzer

__all__ = ["ObserverAnalyzer"]
