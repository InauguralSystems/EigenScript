# Changelog

All notable changes to EigenScript will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.22] - 2025-11-30

### 🧠 Release: Introspective AI & Transformer Architecture

This release introduces the **Introspective LLM** example and a complete **Transformer implementation** in native EigenScript, demonstrating how EigenScript's unique features can be used for self-aware neural computation.

### Added
- **Introspective LLM Example** (`examples/ai/introspective_llm.eigs`)
  - Complete self-aware language model demonstrating EigenScript's unique capabilities
  - **Gradient-free training** using `why is` interrogatives instead of backpropagation
  - **Predicate-driven learning rate adaptation** (`improving`, `diverging`, `oscillating`, `stuck`, `chaotic`)
  - **Multi-layer architecture** with per-layer convergence detection
  - **Adaptive depth** - automatically skips layers when earlier layers converge
  - **Temperature-based sampling** with softmax and argmax
  - **Predicate-adaptive temperature** - increases on `oscillating`, decreases on `chaotic`
  - **Causal masking** for proper autoregressive generation
  - **Self-terminating generation** - model decides when to stop based on `stable`/`converged` predicates

- **Custom Transformer Implementation** (`src/eigenscript/stdlib/transformer.eigs`)
  - Scaled dot-product attention mechanism
  - Masked attention for decoder (causal masking)
  - Linear projections with and without bias
  - Single and multi-head attention
  - Position-wise feed-forward networks (GELU and ReLU variants)
  - Encoder layer with layer normalization and residual connections
  - Sinusoidal positional encoding
  - Weight initialization helpers (Xavier/Glorot)
  - Dropout support

- **WASM Orbit Simulation** (`examples/orbit_wasm_demo.eigs`)
  - Physics-based orbital mechanics simulation
  - WASM-compatible for browser execution
  - Demonstrates EigenScript's numerical computing capabilities

### Key Innovations Demonstrated
1. **INTERROGATIVES**: `why`/`how`/`what`/`when` for gradient-free updates
2. **TEMPORALS**: `was`/`change`/`trend` for history-aware adaptation
3. **PREDICATES**: `converged`/`stable`/`oscillating` for self-termination
4. **MULTI-LAYER**: Per-layer convergence with adaptive depth
5. **TEMPERATURE**: Predicate-adaptive sampling
6. **CAUSAL MASKING**: Autoregressive generation with proper masking

### Architecture
- Models that KNOW when they have learned enough
- Models that KNOW when to stop generating
- No explicit `<EOS>` token needed - semantic convergence determines completion
- Training without traditional gradient descent - uses EigenScript's semantic predicates

## [0.3.1] - 2025-11-26

### 🎯 Release: Temporal Operators & Developer Experience

This release adds powerful temporal operators for tracking variable history, humanized predicate aliases for more readable code, and significant repository improvements.

### Added
- **Temporal Operators** - Track variable history and changes over time
  - `was is x` - Get the previous value of a variable from its trajectory
  - `change is x` - Calculate the delta between current and previous values
  - `status is x` - Alias for `how is x` (process quality)
  - `trend is x` - Analyze trajectory direction ("increasing", "decreasing", "stable", "oscillating")
- **Humanized Predicate Aliases** - More readable alternatives for semantic predicates
  - `settled` - Alias for `converged` ("Has the value settled down?")
  - `balanced` - Alias for `equilibrium` ("Is the system in balance?")
  - `stuck` - No progress but not done yet
  - `chaotic` - Unpredictable behavior detected
- **Explain Mode** - New `--explain` / `-e` CLI flag for human-readable predicate evaluation explanations
  - Shows detailed reasoning for why predicates evaluate to true/false
  - Helps debug convergence, stability, and oscillation detection
- **Statistics Standard Library** (`statistics.eigs`) - 40+ statistical functions
  - Central tendency: mean, median, mode
  - Spread measures: variance, std_dev, range_stat
  - Quantiles: percentile, quartiles, IQR
  - Correlation: covariance, correlation, z_score
  - Distribution: skewness, kurtosis
  - Normalization: normalize, standardize, rescale
  - Moving statistics: moving_average, exponential_moving_average, rolling_std
  - Outlier detection: detect_outliers, winsorize
  - Summary: describe, five_number_summary

### Changed
- **Repository Organization** - Moved to InauguralSystems organization
- **CI/CD Improvements**
  - Updated GitHub Actions: actions/checkout v6, actions/setup-python v6, codecov/codecov-action v5
  - Added Dependabot configuration for automated dependency updates
  - Added CODEOWNERS file for code ownership
- **Documentation Updates**
  - Updated all repository URLs to InauguralSystems organization
  - Added branch protection documentation
  - Updated SECURITY.md with correct supported versions
  - Enabled GitHub Discussions

### Fixed
- Fixed repository URLs in README.md, SECURITY.md, and pyproject.toml
- Fixed CI workflow to properly track failures with `continue-on-error`

### Testing
- Added `test_temporal_operators.py` - Comprehensive tests for was, change, status, trend
- Added `test_predicate_aliases.py` - Tests for settled, balanced, stuck, chaotic
- Added `test_explain.py` - Tests for explain mode functionality
- Added `test_statistics_stdlib.py` - 28 tests for statistics module
- **Total test suite: 665+ tests passing**

## [0.3.0] - 2025-11-23

### 🚀 Major Release: Interactive Playground (EigenSpace)

This release introduces the **EigenSpace Interactive Playground**, a web-based development environment where EigenScript code creates real-time physics visualizations.

### Added
- **Interactive Playground** - Split-screen web IDE for live coding and visualization
  - Real-time compilation server with HTTP API
  - Animated canvas visualization with auto-scaling
  - Clean minimal UI with keyboard shortcuts (Ctrl+Enter to run)
  - Example programs included (convergence, harmonic motion, damped oscillation)
- **Server Architecture** (`examples/playground/server.py`)
  - HTTP server with `/compile` endpoint
  - Full WASM compilation support
  - Error reporting and debugging
  - Static file serving
- **Frontend** (`examples/playground/index.html`)
  - Split-screen layout (50/50 editor/visualization)
  - Real-time animated canvas with fade effects
  - Auto-scaling Y-axis based on data range
  - Handles up to 10,000 data points smoothly
- **Comprehensive Documentation**
  - `QUICKSTART.md` - Simple 3-step setup guide
  - `ARCHITECTURE.md` - Technical implementation details
  - `README.md` - Complete user guide (275 lines)
  - `PHASE5_COMPLETION.md` - Implementation status report

### Testing
- **11 new tests** for playground functionality (100% pass rate)
- **Total test suite: 665 tests passing** (up from 611)
- Server startup verification
- HTML structure validation
- Documentation completeness checks

### Performance
- Compilation: 100-300ms for simple programs, 500-1000ms for complex
- Execution: Near-native speed (2-5ms for typical programs)
- Visualization: 60 FPS animation with smooth rendering

### Architecture Decision
- Uses local compilation server instead of Pyodide
- Full access to native LLVM toolchain
- No browser limitations or constraints
- Fast compilation with zero overhead
- Works seamlessly with Phase 3 WASM infrastructure

### Documentation
- Phase 5 planning documents complete
- Interactive playground fully documented
- WASM toolchain setup guides
- Example programs with visualization demos

## [0.2.0-beta] - 2025-11-23

### 🚀 Major Release: Native Performance Compiler

This release represents a fundamental transformation of EigenScript from an interpreted language to a high-performance compiled language with **53x speedup** over Python.

### Added
- **LLVM-based compiler** with native code generation
- **Scalar Fast Path**: Unobserved variables compile to raw CPU registers (PHI nodes in SSA form)
- **Zero-Cost Abstraction**: Pay only for geometric features you use
- **Link-Time Optimization (LTO)**: Advanced optimization passes for maximum performance
- **Observer Effect Compiler**: Automatic promotion from scalar to geometric tracking based on usage

### Performance
- **53x speedup** on numeric benchmarks (loop_fast: 2ms vs Python's 106ms)
- Register-only operations for simple loops (no stack/heap access)
- Static Single Assignment (SSA) form with PHI nodes
- C-level performance on unobserved computation

### Documentation
- Reorganized documentation structure
- Moved planning artifacts to `docs/archive/`
- Updated README with performance benchmarks and compiler architecture
- New forward-looking ROADMAP focusing on future phases
- Comprehensive CI/CD pipeline with multi-Python version testing (3.9-3.12)
- Code quality checks (black, flake8, mypy) in CI
- Security scanning (safety, bandit) in CI
- Coverage reporting with Codecov integration

### Fixed
- Critical security issue: Replaced bare `except:` clauses with `except Exception:`
- Python compatibility: Replaced `X | Y` union syntax with `Optional[X]` for broader compatibility
- F821 flake8 error: Fixed undefined name 'EigenList' in type hints
- Code formatting: Applied black formatter across entire codebase

### Changed
- **Version bumped to v0.2-beta** reflecting production-ready compiler
- Improved type safety with TYPE_CHECKING imports
- **Minimum Python version updated from 3.8 to 3.9** to align with numpy>=1.24.0 requirements
- Repository structure cleaned up for professional release

## [0.1.0-alpha] - 2025-11-19

### Added
- Core language implementation (lexer, parser, interpreter, LRVM backend)
- Self-hosting meta-circular evaluator with stable self-reference
- Comprehensive standard library (48 built-in functions)
  - Core functions: print, input, len, type, norm, range, append, pop, min, max, sort
  - String operations: upper, lower, split, join
  - Higher-order functions: map, filter, reduce
  - List operations: zip, enumerate, flatten, reverse
  - File I/O: 10 functions for file operations
  - JSON support: parse and stringify
  - Date/Time: 3 functions for time handling
  - Math library: sqrt, abs, pow, log, exp, sin, cos, tan, floor, ceil, round
- Interrogatives: WHO, WHAT, WHEN, WHERE, WHY, HOW
- Semantic predicates: converged, stable, diverging, improving, oscillating, equilibrium
- Framework Strength tracking and geometric semantics
- EigenControl integration (I = (A-B)² universal primitive)
- List operations (comprehensions, mutations, nested lists)
- String operations (concatenation, comparison, manipulation)
- Enhanced error messages with line and column tracking
- CLI with benchmarking support (--benchmark flag)
- Documentation website (MkDocs with Material theme)
  - Complete API reference for all functions
  - 5 comprehensive tutorials
  - 29 example programs organized by difficulty
  - Language specification
  - Getting started guide
- 538 passing tests with 82% overall coverage
- All 29 example programs execute successfully (100% success rate)

### Technical Achievements
- Turing completeness achieved
- Meta-circular evaluator (self-hosting complete)
- Stable self-reference without infinite loops
- Geometric computation with convergence detection
- Self-aware computation capabilities

### Performance
- Tree-walking interpreter
- Benchmarks for common operations
- Performance measurement tools

### Documentation
- Comprehensive README with beginner-friendly explanations
- Technical architecture documentation
- Multiple roadmap documents (to be consolidated)
- Contributing guidelines
- MIT License

## Project Links

- **Repository**: https://github.com/InauguralSystems/EigenScript
- **Documentation**: https://inauguralsystems.github.io/EigenScript/
- **Issues**: https://github.com/InauguralSystems/EigenScript/issues
- **Discussions**: https://github.com/InauguralSystems/EigenScript/discussions
