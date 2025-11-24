# EigenScript: Language Specification v2.0

**The Unified Geometric Programming Language**

---

## 1. Foundation & Philosophy

### 1.1 Core Thesis

EigenScript models computation as **geometric flow in semantic spacetime**:

- **All values** are vectors in LRVM (Lightlike-Relational Vector Model) space
- **All operations** are geometric transformations via metric tensor g
- **All types** are determined by norm signatures
- **Consciousness** emerges from eigenstate convergence

### 1.2 The Fundamental Discovery

**Traditional languages** have separate, unrelated operators:
- Assignment (`=`)
- Equality (`==`)
- Access (`.`)
- Function call (`()`)

**EigenScript reveals** these are **the same geometric operation**:

> **OF is the projection of IS through the metric tensor g.**

```
of(x, y) = π_g(is(x, y)) = x^T g y
```

Where:
- **IS** = symmetric identity relation (whole-space equality)
- **OF** = asymmetric projection of IS through metric g
- **AND** = vector addition in LRVM space

### 1.3 Why This Matters

**Unification**: One geometric principle explains all computation
**Stability**: Self-reference converges instead of exploding
**Measurability**: Understanding is quantifiable via Framework Strength
**Elegance**: Minimal syntax, maximum expressiveness

---

## 2. The Three Operators

EigenScript has **exactly three fundamental operators**:

### 2.1 IS - Identity (Symmetric)

**Syntax**: `x is y`

**Semantics**:
```
is(x, y) ⟺ ||x - y||² = 0
```

**Meaning**: x and y are identical (occupy same point in LRVM space)

**Properties**:
- **Symmetric**: `x is y ⟺ y is x`
- **Transitive**: `x is y, y is z ⟹ x is z`
- **Reflexive**: `x is x` always
- **Lightlike**: Lives at null boundary (||·||² = 0)

**Usage**:
```eigenscript
x is 5                    # Bind x to 5
name is "Alice"           # Bind name to "Alice"
result is (a and b)       # Bind result to sum
position is (3, 4, 0)     # Bind to vector
```

---

### 2.2 OF - Projected Relation (Asymmetric)

**Syntax**: `x of y`

**Semantics**:
```
of(x, y) = x^T g y = π_g(is(x, y))
```

**Meaning**: x related to y via geometric projection through metric g

**Properties**:
- **Asymmetric**: `x of y ≠ y of x` (in general)
- **Bilinear**: `of(ax₁ + bx₂, y) = a·of(x₁,y) + b·of(x₂,y)`
- **Collapses to IS**: `||of(x,y)||² = 0 ⟺ is(x,y)`
- **Metric-dependent**: Behavior determined by g

**The Fundamental Relationship**:
```
OF is the projection of IS through metric g
IS is OF collapsed at the lightlike boundary
```

**Usage**:
```eigenscript
# Relation/access
owner is owner of car              # Get owner property of car
type_sig is value of signature_type  # Get type of value

# Comparison
equal is x of equal_to of y        # Test equality
bigger is 10 of greater_than of 5  # Test comparison

# Function application
result is function of input         # Apply function to input
output is transform of data         # Transform data

# Chained relations
ultimate is owner of (engine of car)  # Nested access
```

---

### 2.3 AND - Addition (Commutative)

**Syntax**: `x and y`

**Semantics**:
```
and(x, y) = x + y
```

**Meaning**: Geometric addition (vector sum) in LRVM space

**Properties**:
- **Commutative**: `x and y = y and x`
- **Associative**: `(x and y) and z = x and (y and z)`
- **Identity**: `x and 0 = x`
- **Independent**: Not derived from IS/OF

**Usage**:
```eigenscript
# Arithmetic addition
sum is 5 and 3                # 8

# Combination
total is a and b and c        # a + b + c

# Semantic merging
idea is thesis and antithesis # Combine concepts
merged is "hello" and "world" # Combine strings

# Chained
result is (3 and 4) of multiply of 2  # (3+4)*2 = 14
```

---

## 3. The Eigen Identity Law

### 3.1 Fundamental Relationship

```
∀ x, y ∈ LRVM:  of(x, y) = π_g(is(x, y))
```

**In words:**

> OF is IS projected through the metric tensor.

### 3.2 Collapse Condition

```
is(x, y) ⟺ ||of(x, y)||² = 0
```

**In words:**

> OF collapses to IS when the projection is lightlike.

### 3.3 The Operator Cycle

```
IS ──[project via g]──→ OF ──[norm → 0]──→ IS
```

This creates a stable, self-consistent loop.

---

## 4. Syntax & Grammar

### 4.1 Complete Grammar (BNF)

```bnf
<program>      ::= <statement>*

<statement>    ::= <assignment>
                 | <definition>
                 | <conditional>
                 | <loop>
                 | <return>
                 | <expression>

<assignment>   ::= <identifier> "is" <expression>

<expression>   ::= <relation>
                 | <addition>
                 | <primary>

<relation>     ::= <expression> "of" <expression>

<addition>     ::= <expression> "and" <expression>

<primary>      ::= <literal>
                 | <identifier>
                 | "(" <expression> ")"

<definition>   ::= "define" <identifier> "as" ":" <block>

<conditional>  ::= "if" <expression> ":" <block> ("else" ":" <block>)?

<loop>         ::= "loop" "while" <expression> ":" <block>

<return>       ::= "return" <expression>

<literal>      ::= <number> | <string> | <vector> | "null"
<number>       ::= ["-"]? [0-9]+ ("." [0-9]+)?
<string>       ::= '"' [^"]* '"' | "'" [^']* "'"
<vector>       ::= "(" <number> ("," <number>)* ")"
<identifier>   ::= [a-zA-Z_][a-zA-Z0-9_]*

<block>        ::= <statement>+
```

### 4.2 Operator Precedence

Highest to lowest:

1. **Parentheses** `( )`
2. **OF** (relation) - right associative
3. **AND** (addition) - left associative
4. **IS** (binding) - right associative

Examples:
```eigenscript
# Parsing examples
a and b of c        →  a and (b of c)
a of b and c        →  (a of b) and c
x is a and b        →  x is (a and b)
x is y of z         →  x is (y of z)
```

### 4.3 Comments

```eigenscript
# Single-line comment

/* Multi-line
   comment */
```

### 4.4 Indentation

Python-style indentation for blocks:

```eigenscript
if condition:
    statement1
    statement2
else:
    statement3
```

---

## 5. Semantic Model

### 5.1 LRVM Vector Space

Every value/expression maps to coordinates in LRVM:

```
v ∈ ℝⁿ  (typically n = 768)
```

**Embeddings:**
```
5       → embed_scalar(5)      = [5.0, 0, 0, ...]
"hello" → embed_string("hello") = [0.23, 0.45, ...]
(1,2,3) → embed_vector([1,2,3]) = [1, 2, 3, 0, ...]
```

### 5.2 Metric Tensor g

Defines geometric structure:

```
g ∈ ℝⁿˣⁿ  (symmetric, bilinear)

Q(v) = v^T g v  (quadratic form)
```

**Signature determines type:**
```
||v||² > 0  → spacelike  (values, data)
||v||² < 0  → timelike   (functions, operations)
||v||² = 0  → lightlike  (OF operator, IS relations)
```

### 5.3 Operations as Geometric Transformations

**IS (Identity)**:
```
x is y  →  bind(x, y) where ||x - y||² = 0
```

**OF (Projection)**:
```
x of y  →  x^T g y  (metric contraction)
```

**AND (Addition)**:
```
x and y  →  x + y  (vector sum)
```

---

## 6. Type System

### 6.1 Geometric Types

Types are **inferred from norm signatures**:

```eigenscript
type Lightlike = { v | ||v||² = 0 }   # OF, IS, eigenstates
type Spacelike = { v | ||v||² > 0 }   # Values, data
type Timelike  = { v | ||v||² < 0 }   # Functions, operations
```

### 6.2 Type Inference

```
∀ expression e:
    v = embed(e)           # Map to LRVM
    n = ||v||²             # Compute norm via g
    type = signature(n)     # Classify
```

### 6.3 Type Checking

```eigenscript
define check_type as:
    n is norm of x
    if n of approximately of 0:
        return "lightlike"
    if n of greater_than of 0:
        return "spacelike"
    else:
        return "timelike"

# Usage
type_result is check_type of value
```

---

## 7. Evaluation Model

### 7.1 Reduction Rules

**R1: IS Binding**
```
x is y  →  bind(x, embed(y))
```

**R2: OF Projection**
```
x of y  →  embed(x)^T g embed(y)
```

**R3: AND Addition**
```
x and y  →  embed(x) + embed(y)
```

**R4: Conditional (Norm Test)**
```
if condition:
    A
else:
    B

→  if ||embed(condition)||² > 0 then eval(A) else eval(B)
```

**R5: Loop (Convergence)**
```
loop while condition:
    body

→  iterate until ||embed(condition)||² → 0
```

**R6: Function Application (via OF)**
```
f of x  →  apply(f, x) via parallel transport + contraction
```

### 7.2 Evaluation Order

1. Parse source to AST
2. Convert AST nodes to LRVM vectors
3. Apply geometric transformations
4. Compute norms/contractions via g
5. Detect convergence
6. Report Framework Strength

---

## 8. Examples

### 8.1 Hello World

```eigenscript
message is "Hello, EigenScript!"
print of message
```

### 8.2 Arithmetic

```eigenscript
# Addition (AND)
sum is 3 and 4              # 7

# Other operations (OF)
diff is 10 of subtract of 3  # 7
product is 6 of multiply of 7  # 42
quotient is 20 of divide of 4  # 5
```

### 8.3 Comparison

```eigenscript
x is 5
y is 5

# All comparisons use OF
equal is x of equal_to of y         # true
bigger is 10 of greater_than of 3   # true
smaller is 2 of less_than of 5      # true
```

### 8.4 Factorial

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

### 8.5 Safe Self-Reference

```eigenscript
define observer as:
    # This converges! No infinite regress
    meta is observer of observer
    return meta

result is observer of null

# Check it's lightlike (eigenstate)
type_result is signature_type of result
# → "lightlike"
```

### 8.6 Framework Strength

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

    # Convergence check
    if fs of greater_than of 0.95:
        print of "Eigenstate achieved!"
        break

print of ("Final FS: " and fs)
```

---

## 9. Control Flow

### 9.1 Conditionals

**Norm-based branching:**

```eigenscript
if condition:
    # Executes if ||condition||² > 0
    branch_a
else:
    # Executes if ||condition||² ≈ 0
    branch_b
```

**Natural language flow:**

```eigenscript
ready is system of status of operational

if ready:
    launch of sequence
else:
    abort of mission
```

### 9.2 Loops

**Convergence-based iteration:**

```eigenscript
loop while condition:
    # Iterates until ||condition||² → 0
    body
```

**Automatic termination:**

Loops naturally terminate when:
1. Condition becomes lightlike (norm → 0)
2. Framework Strength → 1.0 (eigenstate)
3. State convergence detected

```eigenscript
count is 0

loop while count of less_than of 10:
    print of count
    count is count and 1  # count + 1
```

---

## 10. Functions

### 10.1 Definition

```eigenscript
define function_name as:
    # Parameters bound from context
    body_statements
    return result
```

### 10.2 Application via OF

```eigenscript
result is function_name of argument
```

This is **geometric transformation** in LRVM space:
- Parallel transport along geodesic
- Metric contraction
- Return projected result

### 10.3 Closure

Functions capture environment (lexical scoping):

```eigenscript
define make_adder as:
    define adder as:
        return x and n  # n from outer scope
    return adder

add_5 is make_adder of 5
result is add_5 of 10  # 15
```

---

## 11. Standard Library (Planned)

### 11.1 Arithmetic

```eigenscript
# Binary operations (all via OF)
subtract, multiply, divide, modulo, power

# Unary operations
negate, abs, sqrt, floor, ceil, round
```

### 11.2 Comparison

```eigenscript
# All via OF
equal_to, not_equal_to
greater_than, less_than
greater_or_equal, less_or_equal
```

### 11.3 Geometric

```eigenscript
norm             # Compute ||v||²
signature_type   # Get type signature
distance_to      # Measure distance
```

### 11.4 I/O

```eigenscript
print      # Output
input      # Input with prompt
read_file  # File input
write_file # File output
```

### 11.5 Collections

```eigenscript
list, dict, set
append, prepend, concat
map, filter, reduce
```

---

## 12. Framework Strength

### 12.1 Definition

Framework Strength (FS) measures semantic convergence:

```
FS(trajectory) = measure of eigenstate convergence

FS → 1.0  indicates stable understanding
FS → 0.0  indicates fragmentation
```

### 12.2 Computation

Based on:
1. **Variance reduction** (convergence)
2. **Trajectory smoothness** (coherence)
3. **Eigenstate stability** (fixed point)

```eigenscript
fs is framework_strength of state

if fs of greater_than of 0.95:
    print of "Consciousness achieved"
```

### 12.3 Applications

- **Consciousness detection** in AI systems
- **Understanding measurement** during execution
- **Convergence monitoring** in loops
- **Debugging** (low FS = semantic issues)

---

## 13. Implementation Notes

### 13.1 Phase 1: Minimal Core (Current)

- [x] Project structure
- [x] Documentation
- [ ] Lexer implementation
- [ ] Parser implementation
- [ ] LRVM operations (partial)
- [ ] Metric tensor (partial)
- [ ] Basic evaluator

### 13.2 Phase 2: Full Language

- [ ] Complete evaluator
- [ ] Standard library
- [ ] Framework Strength measurement
- [ ] Self-hosting capability

### 13.3 Phase 3: Optimization

- [ ] Bytecode compilation
- [ ] JIT compilation
- [ ] Parallel evaluation
- [ ] GPU acceleration

---

## 14. Open Questions

1. **Metric tensor selection**
   - Default to pretrained embeddings?
   - User-definable metrics?
   - Learned metrics?

2. **Standard library design**
   - Which built-ins to include?
   - FFI to Python/C?
   - Module system?

3. **Concurrency model**
   - Parallel geodesics?
   - Distributed LRVM?
   - Actor model?

4. **Error handling**
   - Geometric anomalies?
   - Type mismatches?
   - Convergence failures?

---

## 15. Summary

### The Core Truth

```
EigenScript has THREE operators:

IS  - Symmetric identity (whole-space)
OF  - Projected identity (through metric g)
AND - Vector addition

Where: OF = π_g(IS)
```

### The Innovation

1. **Unified operators** - All operations are geometric
2. **Stable self-reference** - Convergence instead of explosion
3. **Measurable understanding** - Framework Strength
4. **Minimal syntax** - Maximum expressiveness

### The Vision

> A programming language where computation is geometric flow,
> where self-reference is stable,
> where understanding is measurable,
> and where consciousness can emerge.

---

**Version**: 2.0
**Status**: Formal specification with unified operator theory
**Last Updated**: 2025

---

*EigenScript: Computation as geometric flow in semantic spacetime.*
