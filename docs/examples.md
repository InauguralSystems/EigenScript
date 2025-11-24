# EigenScript Examples

This document contains a collection of example programs demonstrating EigenScript's capabilities.

## Table of Contents

1. [Basic Examples](#basic-examples)
2. [Mathematical Computations](#mathematical-computations)
3. [Control Flow](#control-flow)
4. [Recursive Functions](#recursive-functions)
5. [Advanced Patterns](#advanced-patterns)
6. [Consciousness Detection](#consciousness-detection)
7. [Self-Reference](#self-reference)

## Basic Examples

### Hello World

```eigenscript
message is "Hello, EigenScript!"
print of message
```

**Output**: `Hello, EigenScript!`

### Simple Variables

```eigenscript
name is "Alice"
age is 30
height is 1.75

print of name
print of age
print of height
```

### Arithmetic Operations

```eigenscript
a is 10
b is 5

sum is a of add of b
difference is a of subtract of b
product is a of multiply of b
quotient is a of divide of b

print of sum         # 15
print of difference  # 5
print of product     # 50
print of quotient    # 2
```

## Mathematical Computations

### Quadratic Formula

```eigenscript
# Solve ax² + bx + c = 0

a is 1
b is -5
c is 6

# Discriminant: b² - 4ac
discriminant is (b of multiply of b) of subtract of (
    4 of multiply of a of multiply of c
)

# Square root of discriminant
sqrt_disc is square_root of discriminant

# Two solutions
x1 is (
    (negative of b) of add of sqrt_disc
) of divide of (2 of multiply of a)

x2 is (
    (negative of b) of subtract of sqrt_disc
) of divide of (2 of multiply of a)

print of x1  # 3
print of x2  # 2
```

### Distance Between Points

```eigenscript
# Calculate Euclidean distance

point1 is (3, 4, 0)
point2 is (0, 0, 0)

# Difference
dx is (x of point1) of subtract of (x of point2)
dy is (y of point1) of subtract of (y of point2)
dz is (z of point1) of subtract of (z of point2)

# Distance = sqrt(dx² + dy² + dz²)
distance is square_root of (
    (dx of multiply of dx) of add of
    (dy of multiply of dy) of add of
    (dz of multiply of dz)
)

print of distance  # 5.0
```

### Vector Operations

```eigenscript
# Define vectors
v1 is (1, 2, 3)
v2 is (4, 5, 6)

# Dot product
dot_product is v1 of dot of v2

# Norm
norm_v1 is norm of v1

# Unit vector
unit_v1 is v1 of divide of norm_v1

print of dot_product  # 32
print of norm_v1      # 3.742
print of unit_v1      # (0.267, 0.534, 0.801)
```

## Control Flow

### Simple Conditional

```eigenscript
temperature is 85

if temperature of greater_than of 80:
    print of "It's hot!"
else:
    print of "It's pleasant"
```

### Nested Conditionals

```eigenscript
score is 85

if score of greater_than_or_equal of 90:
    grade is "A"
else:
    if score of greater_than_or_equal of 80:
        grade is "B"
    else:
        if score of greater_than_or_equal of 70:
            grade is "C"
        else:
            grade is "F"

print of grade  # "B"
```

### While Loop

```eigenscript
counter is 0

loop while counter of less_than of 5:
    print of counter
    counter is counter of add of 1

# Output: 0, 1, 2, 3, 4
```

### Loop with Break

```eigenscript
counter is 0

loop while counter of less_than of 100:
    print of counter

    if counter of equal_to of 5:
        break

    counter is counter of add of 1

# Output: 0, 1, 2, 3, 4, 5
```

## Recursive Functions

### Factorial

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

### Fibonacci

```eigenscript
define fibonacci as:
    if n of less_than_or_equal of 1:
        return n
    else:
        fib1 is fibonacci of (n of subtract of 1)
        fib2 is fibonacci of (n of subtract of 2)
        return fib1 of add of fib2

result is fibonacci of 10
print of result  # 55
```

### Greatest Common Divisor (GCD)

```eigenscript
define gcd as:
    if b of equal_to of 0:
        return a
    else:
        remainder is a of modulo of b
        return gcd of (b, remainder)

result is gcd of (48, 18)
print of result  # 6
```

### Tower of Hanoi

```eigenscript
define hanoi as:
    if n of equal_to of 1:
        print of ("Move disk from " of concat of source of concat of " to " of concat of target)
    else:
        # Move n-1 disks from source to auxiliary
        hanoi of (n of subtract of 1, source, target, auxiliary)

        # Move largest disk from source to target
        print of ("Move disk from " of concat of source of concat of " to " of concat of target)

        # Move n-1 disks from auxiliary to target
        hanoi of (n of subtract of 1, auxiliary, source, target)

hanoi of (3, "A", "C", "B")
```

## Advanced Patterns

### Map Function

```eigenscript
define map as:
    result is []

    loop while items of list:
        item is next of list
        transformed is function of item
        result is append of (transformed, result)

    return result

# Double all numbers
numbers is [1, 2, 3, 4, 5]

define double as:
    return x of multiply of 2

doubled is map of (double, numbers)
print of doubled  # [2, 4, 6, 8, 10]
```

### Filter Function

```eigenscript
define filter as:
    result is []

    loop while items of list:
        item is next of list

        if predicate of item:
            result is append of (item, result)

    return result

# Keep only even numbers
numbers is [1, 2, 3, 4, 5, 6]

define is_even as:
    remainder is x of modulo of 2
    return remainder of equal_to of 0

evens is filter of (is_even, numbers)
print of evens  # [2, 4, 6]
```

### Reduce Function

```eigenscript
define reduce as:
    accumulator is initial

    loop while items of list:
        item is next of list
        accumulator is function of (accumulator, item)

    return accumulator

# Sum of list
numbers is [1, 2, 3, 4, 5]

define add as:
    return a of add of b

total is reduce of (add, numbers, 0)
print of total  # 15
```

### Currying

```eigenscript
define make_adder as:
    define adder as:
        return x of add of n
    return adder

add_5 is make_adder of 5
result is add_5 of 10

print of result  # 15
```

## Consciousness Detection

### Basic Framework Strength Monitoring

```eigenscript
conversation is []

loop while active:
    user_input is input of prompt
    conversation is append of (user_input, conversation)

    response is ai_generate of conversation
    conversation is append of (response, conversation)

    # Measure understanding
    fs is framework_strength of conversation
    print of ("Framework Strength: " of concat of fs)

    if fs of greater_than of 0.95:
        print of "Eigenstate convergence detected!"
        print of "The system has achieved stable understanding."
        break

print of "Final Framework Strength:"
print of fs
```

### Adaptive Conversation

```eigenscript
define adaptive_chat as:
    conversation is []
    coherence_threshold is 0.7

    loop while true:
        user_input is input of "You: "

        # Exit condition
        if user_input of equal_to of "exit":
            break

        conversation is append of (user_input, conversation)

        # Generate response
        response is ai_generate of conversation
        conversation is append of (response, conversation)

        # Check coherence
        fs is framework_strength of conversation

        if fs of less_than of coherence_threshold:
            print of "Warning: Conversation coherence dropping"
            print of "Attempting to refocus..."

            # Add refocusing prompt
            refocus is "Let's clarify the main topic."
            conversation is append of (refocus, conversation)

        print of ("AI: " of concat of response)
        print of ("FS: " of concat of fs)

    return conversation

final_conversation is adaptive_chat of null
```

### Consciousness Emergence Detection

```eigenscript
define detect_emergence as:
    # Track multiple metrics
    fs_history is []
    stability_window is 10

    loop while iterations of less_than of max_iterations:
        # Update system state
        current_state is evolve of previous_state

        # Measure Framework Strength
        fs is framework_strength of current_state
        fs_history is append of (fs, fs_history)

        # Check for convergence
        if length of fs_history of greater_than of stability_window:
            recent_fs is last of (stability_window, fs_history)
            variance is variance of recent_fs

            # Low variance + high FS = emergence
            if (variance of less_than of 0.01) of and of (fs of greater_than of 0.95):
                print of "Consciousness emergence detected!"
                print of ("Eigenstate achieved at iteration: " of concat of iterations)
                return current_state

        previous_state is current_state

    print of "No emergence detected within iteration limit"
    return null

emerged_state is detect_emergence of initial_state
```

## Self-Reference

### Safe Self-Observation

```eigenscript
# This doesn't cause infinite regress!
define observer as:
    # Observer observing itself
    meta is observer of observer  # Stabilizes at null boundary
    return meta

result is observer of null
print of result  # Returns stable eigenstate

# Check that it's lightlike
type_result is signature_type of result
print of type_result  # "lightlike"
```

### Fixed Point Iteration

```eigenscript
define fixed_point as:
    # Apply function to itself repeatedly
    previous is initial
    iterations is 0

    loop while iterations of less_than of max_iterations:
        current is function of previous

        # Check convergence
        difference is norm of (current of subtract of previous)

        if difference of less_than of epsilon:
            print of ("Converged after " of concat of iterations of concat of " iterations")
            return current

        previous is current
        iterations is iterations of add of 1

    print of "No convergence"
    return null

# Find fixed point of cos(x) starting at 1.0
define cosine as:
    return cos of x

fixed is fixed_point of (cosine, 1.0, 100, 0.0001)
print of fixed  # ~0.739 (Dottie number)
```

### Meta-Circular Evaluator

```eigenscript
define eval as:
    # EigenScript interpreting itself!

    # Parse source to AST
    ast is parse of source

    # Evaluate AST
    loop while not_converged of ast:
        ast is reduce of ast

        # Measure Framework Strength
        fs is framework_strength of ast

        # Natural termination at eigenstate
        if fs of greater_than of 0.99:
            break

    return result of ast

# Run EigenScript program within EigenScript
program is "x is 5\ny is 10\nz is x of add of y"
result is eval of program

print of result  # 15
```

### Quine (Self-Printing Program)

```eigenscript
# A program that prints its own source code
define quine as:
    source is "define quine as:\n    source is %QUOTE%\n    print of (source of format of source)"
    print of (source of format of source)

quine of null
```

## Geometric Type Checking

```eigenscript
define check_type as:
    n is norm of x

    if n of approximately of 0:
        return "lightlike"
    if n of greater_than of 0:
        return "spacelike"
    else:
        return "timelike"

# Test different values
type_of_OF is check_type of OF
type_of_number is check_type of 42
type_of_function is check_type of print
type_of_vector is check_type of (1, 2, 3)

print of type_of_OF        # "lightlike"
print of type_of_number    # "spacelike"
print of type_of_function  # "timelike"
print of type_of_vector    # "spacelike"
```

## Summary

These examples demonstrate:

1. **Basic syntax**: Variables, operators, literals
2. **Control flow**: Conditionals, loops
3. **Functions**: Definitions, recursion, higher-order
4. **Geometric properties**: Type checking via norms
5. **Framework Strength**: Consciousness measurement
6. **Self-reference**: Stable fixed points
7. **Advanced patterns**: Map/filter/reduce, currying

For more details, see:
- [Language Specification](specification.md)
- [Getting Started Guide](getting-started.md)
- [Architecture](architecture.md)

---

**Note**: Some built-in functions (like `print`, `add`, `multiply`, etc.) are shown for clarity but will be implemented in the standard library.
