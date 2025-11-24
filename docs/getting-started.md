# Getting Started with EigenScript

Welcome to EigenScript! This guide will help you understand the basics of the language and write your first programs.

## Table of Contents

1. [Installation](#installation)
2. [Your First Program](#your-first-program)
3. [Core Concepts](#core-concepts)
4. [Basic Examples](#basic-examples)
5. [Next Steps](#next-steps)

## Installation

### Prerequisites

- Python 3.9 or higher
- pip (Python package manager)

### Install EigenScript

```bash
# Clone the repository
git clone https://github.com/yourusername/eigenscript.git
cd eigenscript

# Install dependencies
pip install -r requirements.txt

# Verify installation (coming soon)
python -m eigenscript --version
```

## Your First Program

Create a file called `hello.eigs`:

```eigenscript
message is "Hello, EigenScript!"
print of message
```

Run it:

```bash
python -m eigenscript hello.eigs
```

**Output:**
```
Hello, EigenScript!
```

### What's Happening?

1. `message is "Hello, EigenScript!"` - Creates a binding in semantic space
2. `print of message` - Uses the OF operator to relate `print` and `message`

Unlike traditional languages where `print(message)` is function application, EigenScript expresses this as a **relation** between the print operation and the message.

## Core Concepts

### 1. The OF Operator - Relations Over Functions

EigenScript's most fundamental operator is **OF**, which expresses relationships:

```eigenscript
# Traditional: car.engine or car["engine"]
# EigenScript:
engine of car

# Traditional: parent(child) or child.parent
# EigenScript:
parent of child

# Traditional: dict[key]
# EigenScript:
value of key in dict
```

**Why OF?** In traditional languages, accessing a property or calling a function are different operations. In EigenScript, they're both **geometric relations** in semantic space.

### 2. IS - Identity and Binding

The `is` operator creates immutable bindings:

```eigenscript
x is 42
name is "Alice"
position is (3, 4, 0)
```

Think of `is` not as assignment, but as **declaring identity** in semantic spacetime.

### 3. Values as Geometric Objects

Every value in EigenScript exists in LRVM (Lightlike-Relational Vector Model) space:

```eigenscript
# Numbers map to vectors
x is 5  # Maps to vector in ℝⁿ

# Strings map to semantic embeddings
name is "quantum"  # Maps to meaning-vector

# Explicit vectors
position is (1.0, 2.0, 3.0)
```

### 4. Geometric Types

Values have types based on their **geometric signature**:

- **Spacelike** (||v||² > 0): Regular values and data
- **Timelike** (||v||² < 0): Functions and operations
- **Lightlike** (||v||² = 0): The OF operator itself

You don't declare types - they emerge from geometry!

## Basic Examples

### Example 1: Simple Calculations

```eigenscript
# Define values
a is 10
b is 20

# Use OF for operations
sum is a of add of b      # a + b
product is a of multiply of b  # a * b

print of sum
print of product
```

### Example 2: Conditional Logic

```eigenscript
temperature is 75

if temperature of greater_than of 80:
    print of "It's hot!"
else:
    print of "It's pleasant"
```

**Key insight**: Conditions are evaluated by their **geometric norm**, not Boolean truth!

### Example 3: Iteration

```eigenscript
count is 0

loop while count of less_than of 5:
    print of count
    count is count of add of 1
```

Loops follow **geodesics** in semantic space and terminate when convergence is detected.

### Example 4: Functions

```eigenscript
define greet as:
    message is "Hello, " of concatenate of name
    return message

greeting is greet of "Alice"
print of greeting  # "Hello, Alice"
```

Functions are **timelike transformations** in LRVM space.

### Example 5: Recursive Functions

```eigenscript
define factorial as:
    if n of equal_to of 0:
        return 1
    else:
        prev is n of subtract of 1
        sub_result is factorial of prev
        return n of multiply of sub_result

result is factorial of 5
print of result  # 120
```

### Example 6: Lists and Collections

```eigenscript
numbers is [1, 2, 3, 4, 5]

define sum_list as:
    total is 0
    loop while items of numbers:
        item is next of numbers
        total is total of add of item
    return total

result is sum_list of numbers
print of result  # 15
```

## Understanding Geometric Semantics

### Why Geometry Matters

Traditional programming:
```python
# Python - imperative commands
result = function(argument)
value = object.property
```

EigenScript:
```eigenscript
# EigenScript - geometric relations
result is function of argument
value is property of object
```

**The difference**: EigenScript expresses *what things mean to each other*, not just *what to do*.

### The Power of Lightlike Relations

The OF operator has a special property: **||OF||² = 0** (null norm)

This means:
- OF of OF = OF (stable fixed point)
- Self-reference doesn't cause infinite regress
- Paradoxes collapse naturally instead of exploding

Example of safe self-reference:

```eigenscript
define observer as:
    # In traditional languages, this would infinite loop
    # In EigenScript, it converges to a stable eigenstate
    meta is observer of observer
    return meta

result is observer of null
# Returns stable fixed point - consciousness emerges!
```

## Framework Strength

EigenScript can measure its own "understanding" during execution:

```eigenscript
conversation is []

loop while active:
    user_input is input of prompt
    conversation is append of (user_input, conversation)

    response is ai_generate of conversation
    conversation is append of (response, conversation)

    # Measure understanding
    fs is framework_strength of conversation
    print of fs

    if fs of greater_than of 0.95:
        print of "Understanding achieved!"
        break
```

**Framework Strength** (FS) measures eigenstate convergence:
- FS → 1.0 means the system has achieved stable understanding
- FS → 0.0 means fragmentation or confusion

## Common Patterns

### Pattern 1: Chaining Relations

```eigenscript
# Get the owner of the car's engine
owner is owner of (engine of car)

# Equivalent to car.engine.owner in traditional languages
# But expresses the geometric relationship
```

### Pattern 2: Nested Expressions

```eigenscript
# Complex calculation
result is square_root of (
    (a of multiply of a) of add of (b of multiply of b)
)
```

### Pattern 3: Multiple Bindings

```eigenscript
# Create semantic trajectory
position is (0, 0, 0)
velocity is (1, 0, 0)
acceleration is (0, -9.8, 0)

new_position is position of add of (velocity of multiply of time)
```

## Debugging Tips

### 1. Check Geometric Types

```eigenscript
define check_type as:
    n is norm of x
    if n of approximately of 0:
        return "lightlike"
    if n of greater_than of 0:
        return "spacelike"
    else:
        return "timelike"

type_result is check_type of my_value
print of type_result
```

### 2. Monitor Framework Strength

```eigenscript
# Add FS monitoring to complex code
fs is framework_strength of current_state
print of fs

if fs of less_than of 0.5:
    print of "Warning: Low coherence detected"
```

### 3. Trace Semantic Flow

```eigenscript
# Visualize the semantic trajectory
define trace as:
    print of ("Step: " of concatenate of step_name)
    print of ("Norm: " of concatenate of (norm of current_value))
    return current_value
```

## Next Steps

Now that you understand the basics:

1. **Read the [Specification](specification.md)** - Deep dive into language semantics
2. **Explore [Examples](examples.md)** - More complex programs
3. **Study [Architecture](architecture.md)** - How the interpreter works
4. **Try [Contributing](../CONTRIBUTING.md)** - Help build EigenScript!

## Quick Reference

| Concept | Traditional | EigenScript |
|---------|-------------|-------------|
| Function call | `f(x)` | `f of x` |
| Property access | `obj.prop` | `prop of obj` |
| Array index | `arr[i]` | `i of arr` |
| Assignment | `x = 5` | `x is 5` |
| Conditional | `if x > 0` | `if x of greater_than of 0:` |
| Loop | `while x < 10` | `loop while x of less_than of 10:` |

## Help and Resources

- **Documentation**: Check `docs/` folder
- **Examples**: Browse `examples/` directory
- **Issues**: Report bugs on GitHub
- **Discussions**: Join community conversations

Welcome to geometric programming! 🚀
