# Higher-Order Functions in EigenScript

**Phase 4: Advanced Functional Programming**

EigenScript now supports powerful higher-order functions that enable elegant functional programming patterns while maintaining geometric semantics.

## Overview

Higher-order functions are functions that operate on other functions, taking them as arguments or returning them as results. In EigenScript, these operations maintain the geometric interpretation of computation as flow in semantic spacetime.

## The Three Core Functions

### 1. `map` - Transform Each Element

**Syntax**: `map of [function, list]`

**Description**: Applies a function to every element in a list, returning a new list with the transformed values.

**Geometric Interpretation**: Map represents a geometric transformation applied uniformly across a collection of vectors in LRVM space.

**Example**:
```eigenscript
define double as:
    return n * 2

numbers is [1, 2, 3, 4, 5]
doubled is map of [double, numbers]
# doubled = [2, 4, 6, 8, 10]
```

**Use Cases**:
- Transform all elements uniformly
- Apply computations to collections
- Data preprocessing

### 2. `filter` - Select Matching Elements

**Syntax**: `filter of [predicate, list]`

**Description**: Applies a predicate function to each element, keeping only those for which the function returns a truthy value (non-zero number or non-empty string).

**Geometric Interpretation**: Filter represents a norm-based selection operation, keeping only vectors that satisfy certain geometric constraints.

**Example**:
```eigenscript
define is_positive as:
    return n > 0

numbers is [-2, -1, 0, 1, 2, 3]
positives is filter of [is_positive, numbers]
# positives = [1, 2, 3]
```

**Example - Even Numbers**:
```eigenscript
define is_even as:
    remainder is n % 2
    return remainder = 0

all_numbers is [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
evens is filter of [is_even, all_numbers]
# evens = [2, 4, 6, 8, 10]
```

**Use Cases**:
- Data validation and cleaning
- Conditional selection
- Pattern matching

### 3. `reduce` - Fold/Accumulate Values

**Syntax**: `reduce of [function, list, initial_value]`

**Description**: Applies a binary function cumulatively to the elements of a list from left to right, reducing the list to a single value. The function receives a two-element list `[accumulator, current_element]`.

**Geometric Interpretation**: Reduce represents a sequential composition of geometric transformations, collapsing a trajectory through LRVM space into a single resulting vector.

**Example - Sum**:
```eigenscript
define add as:
    a is n[0]
    b is n[1]
    return a + b

numbers is [1, 2, 3, 4, 5]
total is reduce of [add, numbers, 0]
# total = 15
```

**Example - Product**:
```eigenscript
define multiply as:
    a is n[0]
    b is n[1]
    return a * b

numbers is [1, 2, 3, 4, 5]
product is reduce of [multiply, numbers, 1]
# product = 120
```

**Example - Maximum**:
```eigenscript
define max_of_two as:
    a is n[0]
    b is n[1]
    result is a
    if b > a:
        result is b
    return result

values is [3, 7, 2, 9, 1, 5]
maximum is reduce of [max_of_two, values, 0]
# maximum = 9
```

**Use Cases**:
- Aggregation (sum, product, etc.)
- Finding extrema (min, max)
- Custom accumulation logic

## Combining Higher-Order Functions

The real power of these functions emerges when you chain them together:

```eigenscript
define is_positive as:
    return n > 0

define double as:
    return n * 2

define add as:
    a is n[0]
    b is n[1]
    return a + b

numbers is [-2, -1, 0, 1, 2, 3]

# Step 1: Filter out negative numbers
positives is filter of [is_positive, numbers]  # [1, 2, 3]

# Step 2: Double the remaining numbers
doubled is map of [double, positives]  # [2, 4, 6]

# Step 3: Sum them all
total is reduce of [add, doubled, 0]  # 12
```

## Geometric Semantics

### Map as Uniform Transformation
When you `map` a function `f` over a list, you're applying the same geometric transformation to each vector in the collection, creating a parallel flow in LRVM space.

### Filter as Constraint Satisfaction
When you `filter` with a predicate `p`, you're performing a geometric norm test on each vector, keeping only those that satisfy the constraint (predicate returns non-zero norm).

### Reduce as Sequential Composition
When you `reduce` with a function `f`, you're performing a left-fold that sequentially composes geometric transformations, following a geodesic path through the state space until reaching a final eigenstate.

## Function Requirements

### For `map` and `filter`
- Function must accept a single argument (available as `n`)
- For `filter`, function should return a value that can be tested for truthiness:
  - Numbers: 0 is false, non-zero is true
  - Strings: empty or "null" is false, others are true

### For `reduce`
- Function must accept a two-element list as argument
- Access elements as `n[0]` (accumulator) and `n[1]` (current element)
- Function must return a value that will become the next accumulator

## Edge Cases

### Empty Lists
```eigenscript
# map and filter return empty lists
empty is []
result_map is map of [double, empty]      # []
result_filter is filter of [is_positive, empty]  # []

# reduce returns the initial value
result_reduce is reduce of [add, empty, 0]  # 0
```

### No Matches in Filter
```eigenscript
define greater_than_100 as:
    return n > 100

small_numbers is [1, 2, 3]
result is filter of [greater_than_100, small_numbers]  # []
```

## Complete Example

See `examples/higher_order_functions.eigs` for a comprehensive demonstration of all three functions with various use cases.

## Why Higher-Order Functions?

1. **Expressiveness**: Describe what you want to compute, not how to compute it
2. **Composability**: Build complex transformations from simple building blocks
3. **Geometric Clarity**: Each operation has clear geometric semantics in LRVM space
4. **Functional Purity**: Functions remain side-effect free while enabling powerful patterns

## Connection to EigenScript's Philosophy

Higher-order functions embody EigenScript's core insight: **computation is geometric flow**. Rather than imperatively manipulating state, you're composing transformations in semantic spacetime. This enables:

- Natural progression from list operations (Phase 3)
- Foundation for list comprehensions (potential Phase 4B)
- Basis for eventual meta-circular evaluation (Phase 4D)

The geometric interpretation ensures that even abstract functional patterns maintain physical meaning in LRVM space.
