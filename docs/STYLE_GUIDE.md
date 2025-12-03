# EigenScript Style Guide

This document defines coding and documentation standards for the EigenScript project.

## Table of Contents

1. [Python Code Style](#python-code-style)
2. [EigenScript Code Style](#eigenscript-code-style)
3. [Documentation Style](#documentation-style)
4. [File Organization](#file-organization)
5. [Naming Conventions](#naming-conventions)

---

## Python Code Style

### General Guidelines

EigenScript follows [PEP 8](https://pep8.org/) with some project-specific conventions.

### Formatting

- **Line Length**: 88 characters (Black default)
- **Indentation**: 4 spaces (no tabs)
- **String Quotes**: Double quotes `"` preferred for docstrings, single quotes `'` acceptable for regular strings
- **Imports**: Organized in three groups (stdlib, third-party, local) with blank lines between

### Code Formatting Tools

```bash
# Format code with Black
black src/ tests/

# Check with flake8
flake8 src/ tests/

# Type check with mypy
mypy src/
```

### Import Order

```python
# 1. Standard library imports
import os
import sys
from typing import List, Optional

# 2. Third-party imports
import numpy as np
from llvmlite import ir

# 3. Local application imports
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
```

### Type Hints

Use type hints for function signatures:

```python
def process_node(node: ASTNode, env: Environment) -> EigenValue:
    """Process an AST node in the given environment."""
    pass
```

### Docstrings

Use Google-style docstrings:

```python
def calculate_metric(vector: LRVMVector, tensor: MetricTensor) -> float:
    """Calculate the metric value for a vector.
    
    Args:
        vector: The LRVM vector to measure
        tensor: The metric tensor defining the space
        
    Returns:
        The calculated metric value
        
    Raises:
        ValueError: If vector and tensor dimensions don't match
    """
    pass
```

### Module Structure

All modules should have:
- Module-level docstring
- `__all__` definition listing public API
- Imports organized by group
- Classes and functions with docstrings

Example:
```python
"""
Module for handling EigenScript semantic operations.

This module provides core semantic functionality including
LRVM vector operations and metric tensor calculations.
"""

from typing import List, Optional
from eigenscript.semantic.lrvm import LRVMVector

__all__ = ["LRVMVector", "calculate_norm"]

def calculate_norm(vector: LRVMVector) -> float:
    """Calculate the norm of an LRVM vector."""
    pass
```

---

## EigenScript Code Style

### General Conventions

- **Keywords**: Use lowercase primitives: `is`, `of`, `if`, `loop`, `define`, `return`
- **Indentation**: 4 spaces
- **Comments**: Use `#` for comments
- **Whitespace**: Space around operators (`x is 42`, not `x is42`)

### Naming in EigenScript

- **Variables**: lowercase with underscores: `user_name`, `total_sum`
- **Functions**: lowercase with underscores: `calculate_total`, `process_data`
- **Constants**: (not formally supported yet, use regular variables)

### Example Programs

```eigenscript
# Good style - clear and readable
total is 0
count is 0
limit is 100

loop while count < limit:
    count is count + 1
    total is total + count

print of total

# Function definition
define factorial as:
    if n <= 1:
        return 1
    else:
        return n * (factorial of (n - 1))
```

### Comments

Use comments to explain "why", not "what":

```eigenscript
# Good - explains purpose
# Calculate Fibonacci using dynamic programming to avoid stack overflow
define fib as:
    # ...

# Bad - states the obvious  
# Add 1 to x
x is x + 1
```

---

## Documentation Style

### Markdown Files

- **Headers**: Use ATX-style headers (`#`, `##`, `###`)
- **Lists**: Use `-` for unordered lists, numbers for ordered
- **Code Blocks**: Always specify language (```python, ```eigenscript, ```bash)
- **Links**: Use reference-style links for repeated URLs
- **Line Length**: Aim for 80-100 characters, but not strict for readability

### README Structure

Main README should include:
1. Project title and logo
2. Brief description
3. Key features
4. Installation instructions
5. Quick start / usage examples
6. Link to full documentation
7. Contributing information
8. License

### Documentation Files

Standard documentation files in root:
- `README.md` - Project overview
- `CHANGELOG.md` - Version history
- `CONTRIBUTING.md` - Contribution guidelines
- `CODE_OF_CONDUCT.md` - Community standards
- `SECURITY.md` - Security policy
- `LICENSE` - License text
- `ROADMAP.md` - Future plans

### Version References

- Use format `v0.4.0` in prose: "Version v0.4.0 introduces..."
- Use format `0.4.0` in code: `__version__ = "0.4.0"`
- Keep versions consistent across all files

---

## File Organization

### Repository Structure

```
EigenScript/
├── src/eigenscript/          # Source code
│   ├── lexer/               # Tokenization
│   ├── parser/              # AST building
│   ├── evaluator/           # Interpretation
│   ├── compiler/            # Native compilation
│   ├── semantic/            # Semantic layer
│   ├── runtime/             # Runtime support
│   └── stdlib/              # Standard library
├── tests/                   # Test suite
├── docs/                    # Documentation
│   ├── archive/            # Historical docs
│   ├── api/                # API reference
│   └── tutorials/          # Tutorials
├── examples/               # Example programs
├── benchmarks/             # Performance benchmarks
└── scripts/                # Utility scripts
```

### Source File Organization

Within modules:
1. Module docstring
2. Imports (stdlib, third-party, local)
3. `__all__` definition
4. Constants
5. Classes (alphabetically)
6. Functions (alphabetically)

---

## Naming Conventions

### Python Files and Modules

- **Modules**: lowercase with underscores: `ast_builder.py`, `llvm_backend.py`
- **Packages**: lowercase, no underscores: `eigenscript`, `compiler`, `semantic`
- **Test Files**: `test_` prefix: `test_lexer.py`, `test_parser.py`

### Python Classes and Functions

- **Classes**: PascalCase: `Tokenizer`, `ASTNode`, `LRVMVector`
- **Functions**: snake_case: `parse_expression`, `eval_node`
- **Methods**: snake_case: `calculate_metric`, `get_value`
- **Private**: prefix with `_`: `_internal_helper`, `_parse_impl`

### EigenScript Example Files

Use consistent prefixes:
- `demo_*.eigs` - Demonstrations of features: `demo_math.eigs`
- `tutorial_*.eigs` - Tutorial examples: `tutorial_fibonacci.eigs`
- `example_*.eigs` - General examples: `example_file_io.eigs`
- `benchmark_*.eigs` - Performance tests: `benchmark_loop.eigs`

### Documentation Files

- **Root docs**: ALLCAPS.md: `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`
- **Subdirectory docs**: lowercase with hyphens: `getting-started.md`, `api-reference.md`
- **Archived docs**: Keep original names in `docs/archive/`

---

## Git Commit Messages

### Format

```
<type>: <subject>

<body>

<footer>
```

### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, no logic change)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

### Examples

```
feat: Add support for list comprehensions

Implement list comprehension syntax following Python conventions.
Includes parser updates, AST nodes, and evaluator support.

Closes #42
```

```
fix: Correct version mismatch in __init__.py

Update version from 0.3.23 to 0.4.0 to match pyproject.toml
```

---

## Testing Standards

### Test Organization

- One test file per module: `test_lexer.py` for `lexer.py`
- Group related tests in classes: `class TestTokenizer:`
- Descriptive test names: `test_tokenize_handles_multiline_strings`

### Test Structure

```python
def test_feature_name(self):
    """Test description of what is being tested."""
    # Arrange
    input_data = "test input"
    
    # Act
    result = function_under_test(input_data)
    
    # Assert
    assert result == expected_value
```

### Coverage

- Aim for 80%+ code coverage overall
- Core modules should have 90%+ coverage
- Test both success and error cases
- Include edge cases and boundary conditions

---

## Pre-commit Checks

Before committing:

```bash
# Format code
black src/ tests/

# Check linting
flake8 src/ tests/

# Run type checking
mypy src/

# Run tests
pytest tests/ -v

# Check coverage
pytest tests/ --cov=eigenscript --cov-report=term
```

Consider using pre-commit hooks (see `.pre-commit-config.yaml` when available).

---

## Questions or Suggestions?

If you have questions about style or suggestions for improvements, please:
1. Open an issue on GitHub
2. Discuss in pull request reviews
3. Propose changes to this guide

This style guide is a living document and will evolve with the project.
