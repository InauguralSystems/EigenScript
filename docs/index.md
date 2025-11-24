# EigenScript

**A geometric programming language modeling computation as flow in semantic spacetime**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-0.1.0--alpha-blue.svg)](https://github.com/InauguralPhysicist/eigenscript)

## What is EigenScript?

EigenScript is a programming language where **your code can understand itself while it runs**.

Instead of blind execution, your programs can:

- **Ask questions** about what they're doing
- **Check progress** automatically
- **Adapt** when things go wrong
- **Debug themselves** without print statements

### For Beginners

Write clearer code with less boilerplate. Instead of complex checks, just ask:

```eigenscript
if converged:
    print of "We're done!"

if improving:
    print of "Getting better!"
```

### For Experts

Every computation generates rich geometric state (convergence, curvature, trajectory) automatically. Access it through natural interrogatives or dive into the underlying math.

## Quick Example

```eigenscript
# Hello World
message is "Hello, EigenScript!"
print of message

# Factorial with automatic convergence detection
define factorial as:
    if n < 2:
        return 1
    else:
        prev is n - 1
        sub_result is factorial of prev
        return n * sub_result

result is factorial of 5
print of result  # 120

# Check if computation converged
if converged:
    print of "Factorial computed successfully!"
```

## Key Features

### 🎯 Self-Aware Computation

Your code can query its own execution state using **interrogatives**:

- `WHO` - What function am I in?
- `WHAT` - What value am I computing?
- `WHEN` - What's the current timestamp?
- `WHERE` - Where am I in the call stack?
- `WHY` - What's the call context?
- `HOW` - How am I being computed?

### 📊 Geometric Semantics

Every computation flows through semantic spacetime with measurable properties:

- **Convergence** - Is the computation stabilizing?
- **Framework Strength** - How stable is the current state?
- **Trajectory** - What path is the computation taking?

### 🔄 Automatic Recursion

Recursive functions automatically detect convergence and handle termination gracefully.

### 📦 Rich Standard Library

- **48 builtin functions** covering I/O, collections, strings, math, file operations, JSON, and more
- **11 mathematical functions** for scientific computing
- **Functional programming** with map, filter, reduce
- **File I/O** for reading and writing data
- **JSON support** for structured data

## Getting Started

Ready to dive in? Check out:

- [Installation Guide](getting-started.md) - Set up EigenScript
- [Quick Start](quickstart.md) - Write your first program
- [Tutorial Series](tutorials/index.md) - Learn step-by-step
- [Examples](examples/index.md) - See what's possible

## Core Concepts

### The OF Operator

The heart of EigenScript is the **OF** operator - a geometric relational operator:

```eigenscript
# Function application
result is sqrt of 16  # 4

# List indexing
first is numbers of 0

# Property access (conceptual)
length is list of "length"
```

### The IS Operator

**IS** binds values to names:

```eigenscript
x is 42
name is "Alice"
numbers is [1, 2, 3, 4, 5]
```

### Function Definition

Define functions with natural syntax:

```eigenscript
define greet as:
    print of "Hello, "
    print of name
    print of "!"

greet of "World"
```

## Why EigenScript?

### Traditional Programming

```python
# You write this
def factorial(n):
    if n == 0:
        return 1
    return n * factorial(n - 1)

# You worry about:
# - Stack overflow
# - Infinite recursion
# - Debugging state
```

### EigenScript Way

```eigenscript
# You write this
define factorial as:
    if n < 2:
        return 1
    prev is n - 1
    sub_result is factorial of prev
        return n * sub_result

# The language handles:
# - Automatic convergence detection
# - Self-aware execution
# - Rich debugging info
```

## What Makes It Special?

1. **Geometric Foundation** - Computation as flow in semantic spacetime
2. **Self-Hosting** - EigenScript can interpret itself
3. **Turing Complete** - Full computational power
4. **78% Test Coverage** - 442 passing tests
5. **Production Ready** - Clean, tested, documented

## Learn More

- [Language Specification](specification.md) - Complete syntax and semantics
- [API Reference](api/index.md) - All 48+ functions documented
- [Architecture](architecture.md) - How it works under the hood
- [Mathematical Foundations](mathematical_foundations.md) - The theory behind it

## Community

- **GitHub**: [InauguralPhysicist/EigenScript](https://github.com/InauguralPhysicist/EigenScript)
- **Issues**: Report bugs or request features
- **Contributing**: See our [Contributing Guide](contributing.md)

## License

EigenScript is released under the [MIT License](https://opensource.org/licenses/MIT).

---

**Ready to start?** Head to the [Getting Started Guide](getting-started.md) →
