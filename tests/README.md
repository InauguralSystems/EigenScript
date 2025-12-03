# EigenScript Test Suite

This directory contains the comprehensive test suite for EigenScript, covering all major components of the language implementation.

## Test Organization

### Core Language Tests
- **test_lexer.py** - Tokenization and lexical analysis
- **test_parser.py** - AST generation and syntax parsing
- **test_evaluator.py** - Core evaluation and runtime execution
- **test_interpreter.py** - Main interpreter functionality

### Language Features
- **test_builtins_coverage.py** - Built-in functions and operators
- **test_higher_order_functions.py** - map, filter, reduce
- **test_list_comprehensions.py** - List comprehension syntax
- **test_list_operations.py** - List manipulation functions
- **test_list_mutations.py** - In-place list modifications
- **test_enhanced_lists.py** - Advanced list features
- **test_string_operations.py** - String manipulation
- **test_not_operator.py** - NOT operator logic
- **test_new_operators.py** - New operator implementations

### Semantic & Mathematical Core
- **test_lrvm.py** - Latent Relational Vector Matrix
- **test_matrix.py** - Matrix operations
- **test_metric.py** - Geometric metrics
- **test_unified_theory.py** - Unified theoretical framework
- **test_autodiff.py** - Automatic differentiation

### Interrogatives & Predicates
- **test_interrogatives.py** - what, who, when, where, why, how
- **test_temporal_operators.py** - was, change, status, trend
- **test_predicate_aliases.py** - converged, stable, settled, etc.
- **test_eigencontrol.py** - EigenControl system
- **test_explain.py** - Explanatory capabilities

### Standard Library
- **test_math_functions.py** - Mathematical functions
- **test_statistics_stdlib.py** - Statistical operations
- **test_datetime.py** - Date/time functions
- **test_json.py** - JSON operations
- **test_file_io.py** - File I/O operations
- **test_ai_stdlib.py** - AI-related functions
- **test_transformer_builtins.py** - Transformer operations

### Module System
- **test_modules.py** - Module loading and imports
- **test_module_evaluator.py** - Module evaluation
- **test_resolver.py** - Name resolution
- **test_packages/** - Package system tests

### Meta & Advanced Features
- **test_meta_evaluator.py** - Meta-circular evaluation
- **test_turing_completeness.py** - Turing completeness proofs

### Compiler Tests (requires llvmlite)
- **compiler/test_codegen.py** - LLVM code generation
- **compiler/test_optimizer.py** - Optimization passes
- **compiler/test_module_init_calls.py** - Module initialization
- **compiler/test_module_vs_program.py** - Module vs program compilation
- **test_architecture_agnostic.py** - Cross-platform compilation
- **test_runtime_build_system.py** - Runtime build system

### Integration & Performance
- **test_examples.py** - Example programs validation
- **test_playground.py** - Interactive playground tests
- **test_benchmark.py** - Benchmarking suite
- **test_performance_scalability.py** - Performance tests
- **test_cli.py** - Command-line interface

### Coverage & Quality
- **test_final_coverage_push.py** - Coverage completeness
- **test_more_coverage.py** - Additional coverage tests

## Running Tests

### Run All Tests
```bash
pytest tests/ -v
```

### Run Specific Test File
```bash
pytest tests/test_lexer.py -v
```

### Run Tests by Category
```bash
# Core language tests
pytest tests/test_lexer.py tests/test_parser.py tests/test_evaluator.py -v

# Feature tests
pytest tests/test_higher_order_functions.py tests/test_list_comprehensions.py -v

# Semantic tests
pytest tests/test_lrvm.py tests/test_matrix.py tests/test_metric.py -v
```

### Run Tests with Coverage
```bash
pytest tests/ -v --cov=eigenscript --cov-report=html --cov-report=term
```

### Skip Compiler Tests (if llvmlite not installed)
```bash
pytest tests/ --ignore=tests/compiler --ignore=tests/test_architecture_agnostic.py -v
```

## Test Statistics

As of v0.4.0:
- **Total Tests:** 1000+
- **Pass Rate:** 100%
- **Code Coverage:** ~80% overall
- **Core Coverage:** ~90%

## Writing New Tests

### Test Structure
Tests follow pytest conventions:
- Test files named `test_*.py`
- Test classes named `Test*`
- Test functions named `test_*`

### Example Test
```python
import pytest
from eigenscript import Tokenizer, Parser, Interpreter

class TestMyFeature:
    def test_basic_functionality(self):
        """Test basic feature behavior."""
        code = 'x is 42\nprint of x'
        interpreter = Interpreter()
        result = interpreter.eval(code)
        assert result is not None
        
    def test_edge_case(self):
        """Test edge case handling."""
        # Test code here
```

### Test Guidelines
1. **Descriptive names** - Test names should describe what they test
2. **One assertion focus** - Each test should focus on one thing
3. **Arrange-Act-Assert** - Follow AAA pattern
4. **Edge cases** - Include boundary conditions and error cases
5. **Documentation** - Add docstrings explaining complex tests

## Dependencies

### Required
- pytest >= 7.4.0
- pytest-cov >= 4.1.0

### Optional (for compiler tests)
- llvmlite >= 0.41.0

Install with:
```bash
pip install -r requirements-dev.txt
```

## Continuous Integration

Tests are automatically run on:
- All pull requests
- Commits to main branch
- Multiple Python versions (3.10, 3.11, 3.12)
- Multiple platforms (Linux, macOS, Windows)

See `.github/workflows/` for CI configuration.

## Troubleshooting

### Import Errors
Ensure EigenScript is installed:
```bash
pip install -e .
```

### Compiler Test Failures
Install compiler dependencies:
```bash
pip install -e ".[compiler]"
```

### Coverage Issues
Generate coverage report:
```bash
pytest --cov=eigenscript --cov-report=html
open htmlcov/index.html
```

## Contributing

When adding new features:
1. Write tests first (TDD approach recommended)
2. Ensure all existing tests pass
3. Add tests to appropriate category
4. Update this README if adding new test files
5. Maintain >= 80% code coverage

See [CONTRIBUTING.md](../CONTRIBUTING.md) for detailed guidelines.
