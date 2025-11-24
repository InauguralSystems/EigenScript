# Example Gallery

Explore 29 working EigenScript programs organized by difficulty and topic.

---

## Quick Navigation

- [Basic Examples](#basic-examples) - Hello World, arithmetic, simple I/O
- [Algorithms](#algorithms) - Factorial, Fibonacci, recursion
- [Data Processing](#data-processing) - Lists, strings, file I/O, JSON
- [Advanced](#advanced) - Self-awareness, meta-evaluation, self-hosting

---

## Basic Examples

Perfect for beginners learning the language.

### Hello World
**File:** `hello_world.eigs`  
**Difficulty:** ⭐ Beginner  
**Topics:** Basic I/O, print

The simplest EigenScript program - displays a greeting.

```eigenscript
message is "Hello, EigenScript!"
print of message
```

**Learn:** Basic syntax, variables, output

---

### Factorial (Simple)
**File:** `factorial_simple.eigs`  
**Difficulty:** ⭐⭐ Beginner  
**Topics:** Recursion, functions

Calculate factorial using recursion.

```eigenscript
define factorial as:
    if n is 0:
        return 1
    else:
        prev is n - 1
        return n * (factorial of prev)

result is factorial of 5
print of result  # 120
```

**Learn:** Function definition, recursion, base cases

---

### Strings
**File:** `strings.eigs`  
**Difficulty:** ⭐⭐ Beginner  
**Topics:** String operations

String manipulation examples.

```eigenscript
text is "Hello, World"
upper_text is upper of text
lower_text is lower of text
words is split of text
```

**Learn:** String functions, upper, lower, split, join

---

## Algorithms

Recursive and iterative algorithms demonstrating EigenScript's computational power.

### Factorial
**File:** `factorial.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Recursion, convergence

Full-featured factorial with convergence checking.

**Learn:** Automatic convergence detection, predicates

---

### Core Operators
**File:** `core_operators.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Operators, arithmetic

Comprehensive demonstration of all operators.

**Learn:** IS, OF, arithmetic, comparison operators

---

### IF-THEN-ELSE
**File:** `if_then_else_complete.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Control flow

Complete conditional logic examples.

**Learn:** IF/ELSE, nested conditionals, boolean logic

---

## Data Processing

Real-world data manipulation examples.

### List Operations
**File:** `list_operations.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Lists, collections

Basic list operations and manipulation.

```eigenscript
numbers is [1, 2, 3, 4, 5]
first is numbers of 0
length is len of numbers
sorted is sort of numbers
```

**Learn:** List access, len, append, pop, sort

---

### Lists (Complete)
**File:** `lists.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Lists, comprehensions

Comprehensive list examples including comprehensions.

**Learn:** Advanced list patterns, functional programming

---

### List Comprehensions
**File:** `list_comprehensions.eigs`  
**Difficulty:** ⭐⭐⭐ Intermediate  
**Topics:** Functional programming

List comprehension patterns.

**Learn:** Map, filter, functional transformations

---

### Higher-Order Functions
**File:** `higher_order_functions.eigs`  
**Difficulty:** ⭐⭐⭐ Intermediate  
**Topics:** Functional programming

Complete guide to map, filter, reduce.

```eigenscript
define square as:
    return n * n

numbers is [1, 2, 3, 4, 5]
squared is map of [square, numbers]
```

**Learn:** Map, filter, reduce, functional patterns

---

### Enhanced Lists
**File:** `enhanced_lists_demo.eigs`  
**Difficulty:** ⭐⭐⭐ Intermediate  
**Topics:** Advanced lists

Advanced list operations.

```eigenscript
# Zip
paired is zip of [names, ages]

# Enumerate
indexed is enumerate of fruits

# Flatten
flat is flatten of nested
```

**Learn:** Zip, enumerate, flatten, reverse

---

### File I/O
**File:** `file_io_demo.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Files, I/O

Reading and writing files.

```eigenscript
handle is file_open of ["data.txt", "r"]
content is file_read of handle
file_close of handle
```

**Learn:** File operations, reading, writing

---

### JSON Operations
**File:** `json_demo.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** JSON, data

JSON parsing and serialization.

```eigenscript
json_str is '{"name": "Alice", "age": 30}'
data is json_parse of json_str
```

**Learn:** JSON parse, stringify, data handling

---

### Date/Time
**File:** `datetime_demo.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Time, dates

Date and time operations.

```eigenscript
now is time_now of 0
formatted is time_format of [now, "%Y-%m-%d"]
```

**Learn:** Time functions, formatting, timestamps

---

### Math Showcase
**File:** `math_showcase.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Math, calculations

Mathematical operations demonstration.

```eigenscript
root is sqrt of 16
sine is sin of 1.5708
power is pow of [2, 8]
```

**Learn:** Math functions, trigonometry, calculations

---

## Advanced

Advanced features showcasing EigenScript's unique capabilities.

### Interrogatives Showcase
**File:** `interrogatives_showcase.eigs`  
**Difficulty:** ⭐⭐⭐ Advanced  
**Topics:** Self-awareness, interrogatives

Using WHO, WHAT, WHEN, WHERE, WHY, HOW.

```eigenscript
define traced as:
    print of WHO   # Function name
    print of WHAT  # Current value
    print of WHEN  # Timestamp
```

**Learn:** Interrogatives, self-awareness, introspection

---

### Debug with Interrogatives
**File:** `debug_with_interrogatives.eigs`  
**Difficulty:** ⭐⭐⭐ Advanced  
**Topics:** Debugging, interrogatives

Debugging using self-awareness features.

**Learn:** Debugging techniques, interrogative use cases

---

### Smart Iteration
**File:** `smart_iteration_showcase.eigs`  
**Difficulty:** ⭐⭐⭐ Advanced  
**Topics:** Predicates, iteration

Iteration with automatic convergence.

```eigenscript
loop while not converged:
    if improving:
        # Accelerate
    if diverging:
        # Abort
```

**Learn:** Predicates, converged, stable, improving

---

### Self-Aware Computation
**File:** `self_aware_computation.eigs`  
**Difficulty:** ⭐⭐⭐⭐ Advanced  
**Topics:** Self-awareness, geometric semantics

Computation that understands itself.

**Learn:** Self-awareness, geometric properties, framework strength

---

### Self-Reference
**File:** `self_reference.eigs`  
**Difficulty:** ⭐⭐⭐⭐ Advanced  
**Topics:** Meta-programming, self-reference

Programs that reference themselves.

**Learn:** Self-reference, meta-programming

---

### Self-Simulation
**File:** `self_simulation.eigs`  
**Difficulty:** ⭐⭐⭐⭐ Advanced  
**Topics:** Self-hosting, simulation

EigenScript simulating itself.

**Learn:** Self-hosting, meta-circular evaluation

---

### Self-Simulation with Lists
**File:** `self_simulation_with_lists.eigs`  
**Difficulty:** ⭐⭐⭐⭐ Advanced  
**Topics:** Self-hosting, lists

Self-simulation with list operations.

**Learn:** Advanced self-hosting

---

### Eval
**File:** `eval.eigs`  
**Difficulty:** ⭐⭐⭐⭐ Advanced  
**Topics:** Meta-evaluation, dynamic execution

Dynamic code evaluation.

**Learn:** Meta-evaluation, dynamic execution

---

### Meta-Eval (Simple)
**File:** `meta_eval_simple.eigs`  
**Difficulty:** ⭐⭐⭐⭐ Advanced  
**Topics:** Meta-evaluation

Simple meta-circular evaluator.

**Learn:** Meta-circular evaluation basics

---

### Meta-Eval (Complete)
**File:** `meta_eval_complete.eigs`  
**Difficulty:** ⭐⭐⭐⭐⭐ Expert  
**Topics:** Meta-evaluation, self-hosting

Complete meta-circular evaluator.

**Learn:** Full self-hosting, advanced meta-programming

---

### Consciousness Detection
**File:** `consciousness_detection.eigs`  
**Difficulty:** ⭐⭐⭐⭐ Advanced  
**Topics:** Self-awareness, philosophy

Detecting computational self-awareness.

**Learn:** Advanced self-awareness concepts

---

### NOT Operator
**File:** `not_operator.eigs`  
**Difficulty:** ⭐⭐ Intermediate  
**Topics:** Boolean logic

Boolean negation examples.

**Learn:** NOT operator, boolean logic

---

## By Topic

### Beginner-Friendly
- `hello_world.eigs` - Simplest example
- `factorial_simple.eigs` - Basic recursion
- `strings.eigs` - String operations

### Lists & Collections
- `list_operations.eigs` - Basic lists
- `lists.eigs` - Complete list guide
- `list_comprehensions.eigs` - Functional patterns
- `higher_order_functions.eigs` - Map, filter, reduce
- `enhanced_lists_demo.eigs` - Advanced operations

### File & Data
- `file_io_demo.eigs` - File operations
- `json_demo.eigs` - JSON handling
- `datetime_demo.eigs` - Time operations

### Self-Awareness
- `interrogatives_showcase.eigs` - WHO, WHAT, etc.
- `debug_with_interrogatives.eigs` - Debugging
- `smart_iteration_showcase.eigs` - Predicates
- `self_aware_computation.eigs` - Full self-awareness

### Meta-Programming
- `self_reference.eigs` - Self-reference
- `self_simulation.eigs` - Self-simulation
- `eval.eigs` - Dynamic evaluation
- `meta_eval_simple.eigs` - Simple evaluator
- `meta_eval_complete.eigs` - Complete evaluator

---

## Running Examples

All examples are in the `examples/` directory:

```bash
# Run any example
eigenscript examples/hello_world.eigs

# Run factorial
eigenscript examples/factorial.eigs

# Run meta-eval
eigenscript examples/meta_eval_complete.eigs
```

---

## Learning Path

### New to Programming
1. `hello_world.eigs`
2. `strings.eigs`
3. `list_operations.eigs`
4. `factorial_simple.eigs`

### Some Experience
1. `core_operators.eigs`
2. `higher_order_functions.eigs`
3. `file_io_demo.eigs`
4. `interrogatives_showcase.eigs`

### Advanced Programmers
1. `self_aware_computation.eigs`
2. `meta_eval_simple.eigs`
3. `self_simulation.eigs`
4. `meta_eval_complete.eigs`

---

## Complete Example List

**29 Examples:**
1. hello_world.eigs
2. factorial_simple.eigs
3. factorial.eigs
4. strings.eigs
5. list_operations.eigs
6. lists.eigs
7. list_comprehensions.eigs
8. higher_order_functions.eigs
9. enhanced_lists_demo.eigs
10. file_io_demo.eigs
11. json_demo.eigs
12. datetime_demo.eigs
13. math_showcase.eigs
14. core_operators.eigs
15. if_then_else_complete.eigs
16. not_operator.eigs
17. interrogatives_showcase.eigs
18. debug_with_interrogatives.eigs
19. smart_iteration_showcase.eigs
20. self_aware_computation.eigs
21. self_reference.eigs
22. self_simulation.eigs
23. self_simulation_with_lists.eigs
24. eval.eigs
25. meta_eval_simple.eigs
26. meta_eval.eigs
27. meta_eval_v2.eigs
28. meta_eval_complete.eigs
29. consciousness_detection.eigs

---

**Start exploring!** Pick an example and dive in. Each example is fully commented and ready to run.
