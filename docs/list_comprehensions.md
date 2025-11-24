# List Comprehensions in EigenScript

**Phase 4 - Option B**: Concise syntax for transforming and filtering lists.

## Overview

List comprehensions provide a compact, readable way to create new lists by applying expressions and filters to existing lists. They combine the power of `map` and `filter` in a single, elegant syntax.

## Syntax

```eigenscript
[expression for variable in iterable]
[expression for variable in iterable if condition]
```

### Components

- **expression**: The transformation applied to each element
- **variable**: Loop variable that takes each element's value
- **iterable**: The source list to iterate over
- **condition** (optional): Filter predicate; only elements where this is true are included

## Geometric Semantics

List comprehensions in EigenScript maintain geometric consistency:

- **Transformation**: Each expression creates a trajectory through LRVM space
- **Filter**: The condition creates a constraint manifold in semantic spacetime
- **Result**: A new list representing the filtered trajectory

The comprehension variable lives in its own lexical scope, preventing namespace pollution.

## Basic Examples

### Simple Transformation

```eigenscript
numbers is [1, 2, 3, 4, 5]
doubled is [x * 2 for x in numbers]
# Result: [2, 4, 6, 8, 10]
```

### With Filter

```eigenscript
numbers is [1, 2, 3, 4, 5, 6]
evens is [x for x in numbers if x % 2 = 0]
# Result: [2, 4, 6]
```

### Transform and Filter

```eigenscript
mixed is [-2, -1, 0, 1, 2, 3]
positive_doubled is [x * 2 for x in mixed if x > 0]
# Result: [2, 4, 6]
```

## Advanced Examples

### Chaining Comprehensions

```eigenscript
data is [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
evens is [x for x in data if x % 2 = 0]
doubled is [x * 2 for x in evens]
large is [x for x in doubled if x > 10]
# Result: [12, 14, 16, 18, 20]
```

### Complex Expressions

```eigenscript
values is [1, 2, 3, 4, 5]
transformed is [(x + 5) * 2 for x in values]
# Result: [12, 14, 16, 18, 20]
```

### Multiple Conditions

```eigenscript
numbers is [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
special is [x for x in numbers if x > 3 and x < 8]
# Result: [4, 5, 6, 7]
```

## Real-World Use Cases

### Temperature Conversion

```eigenscript
celsius is [0, 10, 20, 30, 40]
fahrenheit is [c * 9 / 5 + 32 for c in celsius]
# Result: [32, 50, 68, 86, 104]
```

### Data Validation

```eigenscript
scores is [45, 78, 92, 33, 88, 105, -5, 67]
valid is [s for s in scores if s >= 0 and s <= 100]
# Result: [45, 78, 92, 33, 88, 67]
```

### Conditional Bonuses

```eigenscript
valid_scores is [45, 78, 92, 88, 67]
bonuses is [s * 0.1 for s in valid_scores if s > 80]
# Result: [9.2, 8.8]
```

## Edge Cases

### Empty Lists

```eigenscript
empty is []
result is [x * 2 for x in empty]
# Result: []
```

### No Matches

```eigenscript
numbers is [1, 2, 3]
none is [x for x in numbers if x > 100]
# Result: []
```

### Single Element

```eigenscript
single is [42]
result is [x * 3 for x in single]
# Result: [126]
```

## Variable Scoping

List comprehension variables are locally scoped and don't leak into the outer environment:

```eigenscript
numbers is [1, 2, 3]
result is [x * 2 for x in numbers]
# x is NOT defined here
y is 42  # This works fine
```

This prevents accidental variable pollution and makes code more predictable.

## Comparison with Higher-Order Functions

List comprehensions provide syntactic sugar that's often more readable than equivalent `map`/`filter` chains:

### Using Higher-Order Functions

```eigenscript
define is_positive as:
    return n > 0
define double as:
    return n * 2

numbers is [-2, -1, 0, 1, 2, 3]
positives is filter of [is_positive, numbers]
result is map of [double, positives]
```

### Using List Comprehension

```eigenscript
numbers is [-2, -1, 0, 1, 2, 3]
result is [x * 2 for x in numbers if x > 0]
```

Both approaches are valid; comprehensions excel at simple, inline transformations, while higher-order functions shine when reusing complex logic.

## Performance Characteristics

List comprehensions:
- Create a new list (non-mutating)
- Iterate through elements once
- Maintain geometric consistency in LRVM space
- Use lexical scoping for loop variables

## Error Handling

### Non-List Iterable

```eigenscript
not_a_list is 42
result is [x * 2 for x in not_a_list]
# Error: List comprehension requires iterable to be a list
```

### List Condition Error

```eigenscript
numbers is [1, 2, 3]
lists is [[1], [2], [3]]
result is [x for x in numbers if lists]
# Error: List comprehension condition requires vector, not list
```

## Best Practices

1. **Keep it simple**: If the expression is complex, consider using `map` with a function
2. **Readable filters**: Complex conditions might be clearer as separate predicates
3. **Chain wisely**: Too many chained comprehensions can be hard to follow
4. **Name well**: Assign intermediate results to clearly named variables
5. **Consider alternatives**: For very complex logic, explicit loops might be clearer

## See Also

- [Higher-Order Functions](higher_order_functions.md) - `map`, `filter`, `reduce`
- [List Operations](../examples/lists.eigs) - List manipulation
- [Loops](../README.md#loops) - Traditional iteration

## Examples

For complete, runnable examples, see:
- `examples/list_comprehensions.eigs` - Comprehensive demonstrations
