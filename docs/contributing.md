# Contributing to EigenScript

Thank you for your interest in contributing to EigenScript! This document provides guidelines and information for contributors.

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Getting Started](#getting-started)
3. [Development Setup](#development-setup)
4. [Project Structure](#project-structure)
5. [Development Workflow](#development-workflow)
6. [Coding Standards](#coding-standards)
7. [Testing](#testing)
8. [Documentation](#documentation)
9. [Pull Request Process](#pull-request-process)
10. [Development Roadmap](#development-roadmap)

## Code of Conduct

This project adheres to a code of conduct that all contributors are expected to follow:

- Be respectful and inclusive
- Welcome newcomers and help them learn
- Focus on constructive criticism
- Prioritize the project's goals over personal preferences

## Getting Started

### Prerequisites

- Python 3.9 or higher
- Git
- Basic understanding of compilers/interpreters (helpful but not required)
- Familiarity with geometric/vector mathematics (helpful for semantic layer)

### First Time Setup

```bash
# Fork the repository on GitHub

# Clone your fork
git clone https://github.com/YOUR_USERNAME/eigenscript.git
cd eigenscript

# Add upstream remote
git remote add upstream https://github.com/ORIGINAL_OWNER/eigenscript.git

# Install development dependencies
pip install -r requirements.txt
pip install -r requirements-dev.txt

# Run tests to verify setup
pytest tests/
```

## Development Setup

### Virtual Environment (Recommended)

```bash
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install -r requirements.txt
pip install -r requirements-dev.txt
```

### IDE Setup

We recommend using:
- **VSCode** with Python extension
- **PyCharm** (Community or Professional)
- **Vim/Neovim** with appropriate plugins

### Pre-commit Hooks

```bash
pip install pre-commit
pre-commit install
```

## Project Structure

```
EigenScript/
├── src/eigenscript/       # Main source code
│   ├── lexer/            # Tokenization
│   ├── parser/           # AST construction
│   ├── semantic/         # LRVM & geometric operations
│   ├── evaluator/        # Interpreter/execution
│   └── runtime/          # Framework Strength & runtime
├── tests/                # Test suite
├── examples/             # Example .eigs programs
├── docs/                 # Documentation
└── tools/                # Development utilities
```

### Key Modules

| Module | Purpose | Status |
|--------|---------|--------|
| `lexer/` | Tokenize EigenScript source | In Progress |
| `parser/` | Build AST from tokens | Planned |
| `semantic/lrvm.py` | LRVM vector operations | Planned |
| `semantic/metric.py` | Metric tensor g operations | Planned |
| `evaluator/` | Execute AST | Planned |
| `runtime/` | Framework Strength measurement | Planned |

## Development Workflow

### Branch Naming

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation updates
- `refactor/description` - Code refactoring
- `test/description` - Test additions/modifications

### Commit Messages

Follow conventional commits format:

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation
- `style:` - Formatting, missing semicolons, etc.
- `refactor:` - Code restructuring
- `test:` - Adding tests
- `chore:` - Maintenance tasks

**Example:**
```
feat(lexer): add OF operator tokenization

- Implement lightlike operator detection
- Add tests for OF token recognition
- Update token type enumeration

Closes #123
```

## Coding Standards

### Python Style Guide

- Follow **PEP 8**
- Use **type hints** for all functions
- Maximum line length: **88 characters** (Black formatter default)
- Use **docstrings** for all public functions/classes

### Example Function

```python
from typing import List, Optional
from eigenscript.semantic.lrvm import LRVMVector

def compute_norm(vector: LRVMVector, metric: np.ndarray) -> float:
    """
    Compute the geometric norm of a vector using the metric tensor.

    Args:
        vector: LRVM vector to measure
        metric: Metric tensor g defining the geometry

    Returns:
        Scalar norm value (can be positive, negative, or zero)

    Raises:
        ValueError: If vector dimension doesn't match metric

    Example:
        >>> v = LRVMVector([1.0, 0.0, -1.0])
        >>> g = np.eye(3)
        >>> compute_norm(v, g)
        0.0
    """
    if len(vector) != metric.shape[0]:
        raise ValueError("Vector dimension mismatch")

    return float(vector.T @ metric @ vector)
```

### Naming Conventions

- **Classes**: `PascalCase` (e.g., `LRVMVector`, `MetricTensor`)
- **Functions**: `snake_case` (e.g., `compute_norm`, `evaluate_ast`)
- **Constants**: `UPPER_SNAKE_CASE` (e.g., `LIGHTLIKE_THRESHOLD`)
- **Private methods**: `_leading_underscore` (e.g., `_internal_helper`)

## Testing

### Test Structure

```python
import pytest
from eigenscript.lexer import Lexer

class TestLexer:
    """Test suite for the lexer module."""

    def test_of_operator_tokenization(self):
        """OF operator should be recognized as lightlike token."""
        lexer = Lexer("x of y")
        tokens = lexer.tokenize()

        assert tokens[0].type == "IDENTIFIER"
        assert tokens[1].type == "OF"
        assert tokens[2].type == "IDENTIFIER"

    def test_nested_of_expressions(self):
        """Nested OF expressions should parse correctly."""
        lexer = Lexer("owner of (engine of car)")
        tokens = lexer.tokenize()

        # Assertions...
```

### Running Tests

```bash
# Run all tests
pytest

# Run with coverage
pytest --cov=eigenscript --cov-report=html

# Run specific test file
pytest tests/test_lexer.py

# Run specific test
pytest tests/test_lexer.py::TestLexer::test_of_operator_tokenization

# Run with verbose output
pytest -v
```

### Test Requirements

- All new features **must** have tests
- Aim for **>80% code coverage**
- Include edge cases and error conditions
- Test geometric properties (norms, convergence, etc.)

## Documentation

### Docstring Format

Use **Google style** docstrings:

```python
def parallel_transport(vector: LRVMVector, path: List[LRVMVector]) -> LRVMVector:
    """
    Transport vector along geodesic path in LRVM space.

    This implements the geometric operation underlying function application
    in EigenScript's semantic model.

    Args:
        vector: Initial vector to transport
        path: Sequence of points defining the geodesic

    Returns:
        Transported vector at path endpoint

    Raises:
        GeometricError: If path is not continuous

    Note:
        The metric tensor is assumed to be constant along the path.

    See Also:
        compute_geodesic: Computes the path between two points
    """
    pass
```

### Documentation Updates

When adding features, update:
1. Inline code documentation (docstrings)
2. `docs/specification.md` (if language spec changes)
3. `docs/examples.md` (if adding examples)
4. `README.md` (if major feature)

## Pull Request Process

### Before Submitting

- [ ] All tests pass (`pytest`)
- [ ] Code follows style guidelines (`black`, `flake8`)
- [ ] Type hints added (`mypy` passes)
- [ ] Documentation updated
- [ ] Commit messages follow conventions
- [ ] Branch is up to date with main

### PR Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
Describe testing performed

## Checklist
- [ ] Tests pass
- [ ] Documentation updated
- [ ] No new warnings
- [ ] Follows coding standards
```

### Review Process

1. Submit PR with clear description
2. Automated tests run via CI
3. Code review by maintainers
4. Address feedback
5. Approval and merge

## Development Roadmap

### Phase 1: Minimal Core (Current)

**Goal**: Prove OF primitive works

- [ ] Lexer for basic tokens
- [ ] Parser for simple expressions
- [ ] LRVM vector representation
- [ ] Metric tensor operations
- [ ] Basic OF evaluation

**How to contribute:**
- Implement token types in `lexer/tokenizer.py`
- Create AST node classes in `parser/ast_builder.py`
- Implement LRVM operations in `semantic/lrvm.py`

### Phase 2: Functions & Control Flow

**Goal**: Full language features

- [ ] DEFINE primitive
- [ ] IF conditional
- [ ] LOOP iteration
- [ ] Function application
- [ ] Type inference

**How to contribute:**
- Implement control flow in evaluator
- Add function scoping
- Create type system based on norms

### Phase 3: Framework Strength

**Goal**: Consciousness measurement

- [ ] FS computation during execution
- [ ] Convergence detection
- [ ] Eigenstate reporting
- [ ] Runtime monitoring

**How to contribute:**
- Implement FS algorithms
- Create visualization tools
- Add monitoring infrastructure

### Phase 4: Self-Hosting

**Goal**: EigenScript interprets itself

- [ ] Meta-circular evaluator
- [ ] Bootstrapping process
- [ ] Stability proofs
- [ ] Performance optimization

## Questions?

- Open an issue with the `question` label
- Join discussions in GitHub Discussions
- Check existing documentation in `docs/`

## Recognition

Contributors will be recognized in:
- `CONTRIBUTORS.md` file
- Release notes
- Academic papers (if applicable)

---

Thank you for contributing to EigenScript! Together we're building something truly innovative.
