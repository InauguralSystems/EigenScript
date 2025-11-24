# Language Constructs

Core syntax elements and operators in EigenScript.

---

## IS - Assignment Operator

Bind a value to a name.

**Syntax:**
```eigenscript
name is value
```

**Example:**
```eigenscript
x is 42
name is "Alice"
numbers is [1, 2, 3]
flag is true
```

**Semantics:** Creates a binding in the current scope. In LRVM terms, performs a projection operation.

---

## OF - Relational Operator

Apply functions, access elements, or express relationships.

**Syntax:**
```eigenscript
result is function of argument
element is list of index
```

**Example:**
```eigenscript
# Function application
root is sqrt of 16

# List indexing
first is numbers of 0

# Nested application
result is sqrt of (abs of -16)
```

**Semantics:** Geometric relational operator with lightlike properties (‖OF‖² = 0).

---

## IF/ELSE - Conditional

Conditional execution based on a predicate.

**Syntax:**
```eigenscript
if condition:
    # true branch
else:
    # false branch
```

**Example:**
```eigenscript
if x > 10:
    print of "Big"
else:
    print of "Small"

# Without else
if flag:
    print of "True"

# Nested
if x > 0:
    if x < 10:
        print of "Between 0 and 10"
```

**Semantics:** Norm-based branching in semantic spacetime.

---

## LOOP/WHILE - Iteration

Repeat execution while a condition is true.

**Syntax:**
```eigenscript
loop while condition:
    # body
```

**Example:**
```eigenscript
count is 0
loop while count < 5:
    print of count
    count is count + 1

# With break logic (via condition)
found is false
i is 0
loop while (i < 10) and (not found):
    if numbers of i is target:
        found is true
    i is i + 1
```

**Semantics:** Geodesic flow through semantic spacetime.

---

## DEFINE - Function Definition

Define a named function.

**Syntax:**
```eigenscript
define function_name as:
    # body
    return value
```

**Example:**
```eigenscript
# Simple function
define greet as:
    print of "Hello, "
    print of name

# With computation
define factorial as:
    if n is 0:
        return 1
    prev is n of -1
    return n * (factorial of prev)

# Multiple parameters via argument unpacking
define add as:
    a is args of 0
    b is args of 1
    return a + b
```

**Semantics:** Creates a timelike transformation in LRVM.

---

## RETURN - Function Exit

Return a value from a function.

**Syntax:**
```eigenscript
return value
```

**Example:**
```eigenscript
define compute as:
    result is x * 2
    return result

define early_exit as:
    if x < 0:
        return 0
    return x * x
```

**Semantics:** Projects result back to caller's observer frame.

---

## Complete Examples

### Pattern Matching (via IF chains)

```eigenscript
define classify as:
    if n is 0:
        return "zero"
    if n > 0:
        return "positive"
    return "negative"

result is classify of -5
print of result  # "negative"
```

### Accumulation Pattern

```eigenscript
define sum_list as:
    total is 0
    i is 0
    loop while i < (len of numbers):
        total is total + (numbers of i)
        i is i + 1
    return total

result is sum_list of [1, 2, 3, 4, 5]
print of result  # 15
```

### Guard Clauses

```eigenscript
define safe_divide as:
    if b is 0:
        print of "Error: Division by zero"
        return 0
    return a / b

result is safe_divide of [10, 2]  # 5
error is safe_divide of [10, 0]   # 0 (with error message)
```

### Recursion with Base Case

```eigenscript
define fibonacci as:
    if n is 0:
        return 0
    if n is 1:
        return 1
    
    prev1 is fibonacci of (n - 1)
    prev2 is fibonacci of (n - 2)
    return prev1 + prev2

fib10 is fibonacci of 10
print of fib10  # 55
```

---

## Operator Precedence

From highest to lowest:

1. Function application (`OF`)
2. Arithmetic (`*`, `/`, `%`)
3. Arithmetic (`+`, `-`)
4. Comparison (`<`, `>`, `<=`, `>=`)
5. Equality (`is`)
6. Logical (`and`, `or`, `not`)

**Example:**
```eigenscript
# These are equivalent:
result is sqrt of 16 + 9
result is (sqrt of 16) + 9  # 4 + 9 = 13

# Not this:
# result is sqrt of (16 + 9)  # sqrt(25) = 5
```

---

## Scoping Rules

```eigenscript
# Global scope
x is 10

define outer as:
    # Outer function scope
    y is 20
    
    define inner as:
        # Inner function scope
        z is 30
        # Can access x, y, z
        return x + y + z
    
    return inner of 0

result is outer of 0  # 60
```

---

## Comments

```eigenscript
# Single line comment

# Multi-line comments via multiple single lines
# This is line 1
# This is line 2
```

---

## Summary

Language constructs:

- `IS` - Assignment/binding
- `OF` - Function application/relation
- `IF/ELSE` - Conditional execution
- `LOOP/WHILE` - Iteration
- `DEFINE` - Function definition
- `RETURN` - Function exit

**Total: 6 constructs**

These form the syntactic foundation of EigenScript.

---

**Next:** [Interrogatives](interrogatives.md) →
