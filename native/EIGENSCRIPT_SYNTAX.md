# EigenScript v0.4.1 Syntax Guide

This document describes the EigenScript syntax used in iLambdaAi, translated for compatibility with EigenScript v0.4.1.

## Core Syntax

### Variables and Assignment
```eigenscript
x is 5
name is "hello"
data is [1, 2, 3, 4, 5]
```

### Functions

**Single argument** - `arg` is the value directly:
```eigenscript
define square as:
    n is arg
    return n * n

result is square of 5    # Returns 25
```

**Multiple arguments** - pass as array, access via `arg[i]`:
```eigenscript
define add_three as:
    a is arg[0]
    b is arg[1]
    c is arg[2]
    return a + b + c

result is add_three of [10, 20, 30]    # Returns 60
```

**No arguments**:
```eigenscript
define greet as:
    print of "Hello!"

greet
```

### Loops
```eigenscript
loop while counter < limit:
    counter is counter + 1
    if condition:
        break
```

### Conditionals
```eigenscript
if condition:
    # code
else:
    # code
```

### Imports (flat, not dotted)
```eigenscript
from layers import Linear, ReLU
from optimizers import Adam
```

### Print (single argument only)
```eigenscript
print of "Hello"
print of value
print of "Value:"
print of x
```

## Geometric Introspection

EigenScript provides native predicates and metrics:

### Predicates (boolean)
- `converged` - Has the computation reached convergence?
- `stable` - Is the system stable?
- `improving` - Is the loss/metric improving?
- `oscillating` - Is there oscillation in values?
- `equilibrium` - Has equilibrium been reached?

### Metrics
- `framework_strength` - Returns a float (0.0-1.0) indicating system strength
- `signature` - Returns a unique identifier for the current state

### Usage Example
```eigenscript
loop while not converged:
    # training iteration
    if oscillating:
        print of "Warning: oscillating"
    if stable:
        fs is framework_strength
        print of fs
```

## Module/Class Definitions

```eigenscript
define MyClass as:
    # extends ParentClass (noted in comment)

    # Properties
    value is 0

    # Methods
    define init as:
        value is arg

    define forward as:
        x is arg
        return x * value
```

## Matrix Operations (Verified Working)

### Creating Matrices
```eigenscript
# Create from nested list (MUST use 'matrix of')
A is matrix of [[1, 2], [3, 4]]

# Create zeros/ones
Z is zeros of [3, 4]    # 3x4 zero matrix
O is ones of [2, 2]     # 2x2 ones matrix
```

### Matrix Operations
```eigenscript
# Multiplication
C is matmul of [A, B]

# Transpose
At is transpose of A

# Addition
S is matrix_add of [A, B]

# Scaling
scaled is matrix_scale of [A, 0.5]

# Softmax (per-row)
weights is softmax_matrix of scores

# Activations
activated is gelu_matrix of hidden
activated is relu_matrix of hidden

# Normalization
normed is layer_norm_matrix of input
```

### Displaying Matrix Results
```eigenscript
# Matrices display as 'null' - use matrix_to_list
result is matmul of [A, B]
result_list is matrix_to_list of result
print of result_list    # Shows [[...], [...]]
```

### Example: Attention Computation
```eigenscript
Q is matrix of [[1.0, 0.0], [0.0, 1.0]]
K is matrix of [[1.0, 0.0], [0.0, 1.0]]
V is matrix of [[1.0, 2.0], [3.0, 4.0]]

K_t is transpose of K
scores is matmul of [Q, K_t]
scaled is matrix_scale of [scores, 0.707]
weights is softmax_matrix of scaled
output is matmul of [weights, V]
```

## Translation from Original Syntax

| Original | EigenScript v0.4.1 |
|----------|-------------------|
| `fn name of arg:` | `define name as:` + `x is arg` |
| `fn name of a, b:` | `define name as:` + `a is arg[0]` + `b is arg[1]` |
| `fn name:` | `define name as:` |
| `while cond:` | `loop while cond:` |
| `module X extends Y:` | `define X as:` + `# extends Y` |
| `from core.layers import` | `from layers import` |
| `print of "a", b` | `print of "a"` + `print of b` |
| `func of a, b, c` | `func of [a, b, c]` |

## Verified Working Features

The following have been tested with EigenScript v0.4.1:
- Variables and arithmetic ✓
- Arrays and lists ✓
- Single-argument functions ✓
- Multi-argument functions with array syntax ✓
- `loop while` loops ✓
- Geometric predicates (`converged`, `stable`, `oscillating`, `improving`) ✓
- `framework_strength` metric ✓
- `signature` metric ✓
- Conditional statements ✓
- Matrix creation (`matrix of`, `zeros of`, `ones of`) ✓
- Matrix operations (`matmul`, `transpose`, `matrix_add`, `matrix_scale`) ✓
- Neural network ops (`softmax_matrix`, `gelu_matrix`, `layer_norm_matrix`) ✓

## Limitations and Workarounds

### No `==` equality operator
Use subtraction and comparison:
```eigenscript
# Instead of: if a == b:
diff is a - b
if diff < 1:
    if diff > -1:
        # a equals b
```

### No modulo `%` operator
Use division trick:
```eigenscript
# Instead of: if x % 10 == 0:
tens is x / 10
remainder is x - (tens * 10)
if remainder < 1:
    if remainder > -1:
        # x is divisible by 10
```

### No multiline arrays
Arrays must be on a single line:
```eigenscript
# Wrong:
data is [
    1,
    2
]

# Correct:
data is [1, 2, 3, 4]
```

### No nested expressions in array literals
Compute values first, then build array:
```eigenscript
# Wrong:
result is func of [(other_func of x), y]

# Correct:
temp is other_func of x
result is func of [temp, y]
```
