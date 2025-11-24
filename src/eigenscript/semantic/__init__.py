"""
Semantic module for EigenScript.

This module handles the geometric semantic layer:
- LRVM (Lightlike-Relational Vector Model) vector representation
- Metric tensor operations
- Norm computation and type inference
"""

from eigenscript.semantic.lrvm import LRVMVector
from eigenscript.semantic.metric import MetricTensor

__all__ = ["LRVMVector", "MetricTensor"]
