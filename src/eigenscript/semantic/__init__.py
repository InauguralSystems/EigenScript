"""
Semantic module for EigenScript.

This module handles the geometric semantic layer:
- LRVM (Lightlike-Relational Vector Model) vector representation
- Metric tensor operations
- Matrix and tensor operations
- Norm computation and type inference
"""

from eigenscript.semantic.lrvm import LRVMVector
from eigenscript.semantic.metric import MetricTensor
from eigenscript.semantic.matrix import Matrix

__all__ = ["LRVMVector", "MetricTensor", "Matrix"]
