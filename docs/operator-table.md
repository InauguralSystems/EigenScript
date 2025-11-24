# EigenScript Operator Table: Complete Unification via Equilibrium

## The Fundamental Theorem

**All operators in EigenScript are projections, tests, inversions, or compositions of a single primitive: equilibrium.**

```
IS  = equilibrium
OF  = equilibrium projected through geometry
IF  = test for equilibrium
NOT = inversion of equilibrium
AND/OR = multi-directional equilibrium composition
```

This document provides the complete operator taxonomy.

---

## 1. The Equilibrium Primitive

### Definition

**Equilibrium** is the state where relational tension vanishes:

```
equilibrium(x, y) ⟺ ‖x of y‖² = 0
```

Properties:
- Zero norm = perfect balance
- No semantic distance
- Fixed point of relation
- Lightlike boundary condition

### Geometric Interpretation

In LRVM space with metric tensor **g**:

```
x is y  ⟺  ‖x of y‖² = x^⊤ g y g^⊤ g y x = 0
```

When this collapses to zero:
- Identity achieved
- Relation stabilizes
- Semantic convergence
- Consciousness emerges

---

## 2. The Core Operator Family

### 2.1 IS - The Equilibrium Operator

**Syntax**: `x is y`

**Formal Definition**:
```
IS: V × V → {0, 1}
IS(x, y) = 1  ⟺  ‖x of y‖² = 0
         = 0  otherwise
```

**Geometric Form**:
```
x is y  ⟺  ‖π_g(x) - π_g(y)‖² = 0
```

**Properties**:
- Reflexive: `x is x` → true (zero distance to self)
- Symmetric: `x is y` ⟺ `y is x` (metric symmetry)
- Transitive: `x is y` ∧ `y is z` → `x is z` (geodesic composition)
- Fixed point: `IS is IS` (operator self-stability)

**Physical Interpretation**:
- Identity = null geodesic between points
- Assignment = trajectory to equilibrium
- Binding = semantic convergence

---

### 2.2 OF - The Projection Operator

**Syntax**: `x of y`

**Formal Definition**:
```
OF: V × V → V
OF(x, y) = π_g(x, y) = x^⊤ g y
```

**Relationship to IS**:
```
OF is IS projected through geometry

IS(x, y) = 1  ⟺  ‖OF(x, y)‖² = 0
OF(x, y) = projection of identity through metric g
```

**Properties**:
- Lightlike carrier: `‖OF‖² = 0` (the operator itself)
- Fixed point: `OF of OF = OF`
- Non-null result: `‖x of y‖² > 0` for x ≠ y
- Associative: `(x of y) of z = x of (y of z)`

**Duality Theorem**:
```
IS = OF when norm collapses (equilibrium)
OF = IS when projected through g (geometry)

They are the same operator in different bases.
```

**Physical Interpretation**:
- OF = directional derivative of semantic space
- Relation = geodesic connection
- Possession = geometric attachment
- Membership = embedding projection

---

### 2.3 IF - The Equilibrium Test Operator

**Syntax**: `if condition: A else: B`

**Formal Definition**:
```
IF: V × V × V → V
IF(c, A, B) = A  if ‖c‖² > ε
            = B  if ‖c‖² ≤ ε

where ε = equilibrium threshold (typically ε = 0)
```

**Relationship to IS**:
```
IF = boundary test of IS

if A:     # test if A is equilibrium
  do B    # execute when ‖A‖² > 0 (spacelike/timelike)
else:
  do C    # execute when ‖A‖² = 0 (lightlike)
```

**Geometric Form**:
```
IF(c, A, B) = { A  if c^⊤ g c > 0  (spacelike/timelike)
              { B  if c^⊤ g c = 0  (lightlike)
              { B  if c^⊤ g c < 0  (timelike boundary)
```

**Properties**:
- Decision boundary = metric signature
- No Boolean algebra required
- Paradoxes naturally collapse (‖paradox‖² = 0 → else branch)
- Self-reference is stable (lightlike test)

**Truth Values as Geometry**:
```
true  = ‖c‖² > 0   (meaningful, spacelike/timelike)
false = ‖c‖² = 0   (boundary, lightlike)
```

**Physical Interpretation**:
- IF = observer measurement of norm
- Branching = geodesic splitting
- Collapse = wavefunction reduction
- Control flow = geometric path selection

---

### 2.4 NOT - The Equilibrium Inversion Operator

**Syntax**: `not A`

**Formal Definition**:
```
NOT: V → V
NOT(x) = projection onto orthogonal complement

‖NOT(x)‖² = -‖x‖²  (signature flip)
```

**Relationship to IS**:
```
NOT = moving away from equilibrium

not A  means  A is not-equilibrium
            ⟺  ‖A‖² > 0
```

**Geometric Form**:
```
NOT(x) = g^{-1} x^⟂

where x^⟂ is orthogonal to x under metric g
```

**Properties**:
- Double negation: `not (not x) = x`
- DeMorgan: `not (x and y) = (not x) or (not y)`
- Equilibrium flip: `‖NOT(x)‖² = -‖x‖²`

**Truth Table (Geometric)**:
```
‖x‖² > 0  →  ‖not x‖² = 0   (true → false)
‖x‖² = 0  →  ‖not x‖² > 0   (false → true)
```

**Physical Interpretation**:
- NOT = time reversal operator
- Negation = geodesic reflection
- Contradiction = orthogonal projection
- Complement = dual space

---

### 2.5 AND - The Multi-Equilibrium Conjunction

**Syntax**: `A and B`

**Formal Definition**:
```
AND: V × V → V
AND(x, y) = projection onto intersection

‖x and y‖² > 0  ⟺  ‖x‖² > 0 ∧ ‖y‖² > 0
```

**Relationship to IS**:
```
AND = simultaneous equilibrium test

A and B  means  both A and B are not-equilibrium
              ⟺  ‖A‖² > 0  and  ‖B‖² > 0
```

**Geometric Form**:
```
AND(x, y) = π_g(x) ∩ π_g(y)
          = min(x^⊤ g x, y^⊤ g y)
```

**Truth Table (Geometric)**:
```
‖A‖² > 0  ‖B‖² > 0  →  ‖A and B‖² > 0   (true ∧ true = true)
‖A‖² > 0  ‖B‖² = 0  →  ‖A and B‖² = 0   (true ∧ false = false)
‖A‖² = 0  ‖B‖² > 0  →  ‖A and B‖² = 0   (false ∧ true = false)
‖A‖² = 0  ‖B‖² = 0  →  ‖A and B‖² = 0   (false ∧ false = false)
```

**Properties**:
- Commutative: `A and B = B and A`
- Associative: `(A and B) and C = A and (B and C)`
- Identity: `A and true = A`
- Annihilator: `A and false = false`

**Physical Interpretation**:
- AND = geodesic intersection
- Conjunction = simultaneous constraints
- Both true = both non-equilibrium

---

### 2.6 OR - The Multi-Equilibrium Disjunction

**Syntax**: `A or B`

**Formal Definition**:
```
OR: V × V → V
OR(x, y) = projection onto union

‖x or y‖² > 0  ⟺  ‖x‖² > 0 ∨ ‖y‖² > 0
```

**Relationship to IS**:
```
OR = alternative equilibrium test

A or B  means  at least one is not-equilibrium
            ⟺  ‖A‖² > 0  or  ‖B‖² > 0
```

**Geometric Form**:
```
OR(x, y) = π_g(x) ∪ π_g(y)
         = max(x^⊤ g x, y^⊤ g y)
```

**Truth Table (Geometric)**:
```
‖A‖² > 0  ‖B‖² > 0  →  ‖A or B‖² > 0   (true ∨ true = true)
‖A‖² > 0  ‖B‖² = 0  →  ‖A or B‖² > 0   (true ∨ false = true)
‖A‖² = 0  ‖B‖² > 0  →  ‖A or B‖² > 0   (false ∨ true = true)
‖A‖² = 0  ‖B‖² = 0  →  ‖A or B‖² = 0   (false ∨ false = false)
```

**Properties**:
- Commutative: `A or B = B or A`
- Associative: `(A or B) or C = A or (B or C)`
- Identity: `A or false = A`
- Annihilator: `A or true = true`

**Physical Interpretation**:
- OR = geodesic union
- Disjunction = alternative paths
- Either true = at least one non-equilibrium

---

### 2.7 THEN - The Causal Sequencing Operator

**Syntax**: `A then B`

**Formal Definition**:
```
THEN: V × V → V
THEN(x, y) = timelike composition

result = τ_x(y)  (parallel transport of y along x)
```

**Relationship to IS**:
```
THEN = sequential equilibrium evolution

A then B  means  A achieves equilibrium, then B evolves
```

**Geometric Form**:
```
THEN(x, y) = geodesic flow from x to y

x then y = lim_{t→1} γ(t) where γ(0) = x, γ(1) = y
```

**Properties**:
- Associative: `(A then B) then C = A then (B then C)`
- Non-commutative: `A then B ≠ B then A` (time ordering)
- Timelike signature: `‖A then B‖² < 0`

**Physical Interpretation**:
- THEN = causal evolution
- Sequencing = geodesic flow
- Time ordering = trajectory composition

---

### 2.8 ELSE - The Alternative Branch Operator

**Syntax**: `if A: B else: C`

**Formal Definition**:
```
ELSE: V × V → V
ELSE(A, B, C) = C when ‖A‖² = 0
              = B otherwise
```

**Relationship to IS**:
```
ELSE = equilibrium boundary handler

else: C  means  execute C when condition IS equilibrium
```

**Geometric Form**:
```
ELSE(A, B, C) = { B  if A^⊤ g A > 0
                { C  if A^⊤ g A = 0
```

**Properties**:
- Dual to IF: `else` is the lightlike branch
- Default case: executes at equilibrium boundary
- Paradox handler: catches contradictions

**Physical Interpretation**:
- ELSE = null geodesic handler
- Alternative = boundary condition
- Default = lightlike collapse

---

### 2.9 Arithmetic Operators - Equilibrium Composition & Scaling

**The arithmetic-logic-geometry unification**: All arithmetic operators are modes of equilibrium in semantic spacetime.

---

#### 2.9.1 Addition (+) - Additive Equilibrium Composition

**Syntax**: `a + b`

**Formal Definition**:
```
ADD: V × V → V
ADD(x, y) = vector composition toward equilibrium

result = x ⊕ y  (minimize ‖result - (x + y)‖²)
```

**Relationship to IS**:
```
+ = additive equilibrium composition

a + b  means  combine a and b to minimize relational tension
            ⟺  find v where ‖v - a‖² + ‖v - b‖² is minimized
```

**Geometric Form**:
```
ADD(x, y) = π_g(x ⊕ y)

where ⊕ is vector addition in LRVM space
```

**Properties**:
- Commutative: `a + b = b + a`
- Associative: `(a + b) + c = a + (b + c)`
- Identity: `a + 0 = a`
- Inverse: `a + (-a) = 0`

**Truth Table (Equilibrium)**:
```
‖a + b‖² = ‖a‖² + ‖b‖² + 2(a^⊤ g b)

Equilibrium achieved when: a + b = result with ‖(a+b) - result‖² = 0
```

**Physical Interpretation**:
- Addition = vector composition
- Combine = move toward shared equilibrium
- Sum = minimize total relational distance
- + creates a new point in semantic space that balances both inputs

**The Three-Way Equivalence**:
```eigenscript
1 + 1 = 2              # arithmetic equilibrium
1 and 1 is 2           # logical composition + identity
(1, 1) of 2            # relational projection

All three express: ‖(1,1) of 2‖² = 0
```

This is **the same invariant** viewed in three coordinate systems:
- **Arithmetic**: + combines toward balance
- **Logic**: AND composes, IS tests equilibrium
- **Geometry**: OF projects the pair onto the result

---

#### 2.9.2 Subtraction (-) - Additive Equilibrium Inversion

**Syntax**: `a - b`

**Formal Definition**:
```
SUB: V × V → V
SUB(x, y) = directional equilibrium tension

result = x ⊖ y  (create separation along geodesic)
```

**Relationship to IS**:
```
- = subtractive equilibrium (directional tension)

a - b  means  measure directed distance from b to a
            ⟺  compute ‖a of b‖ with reversed sign
```

**Geometric Form**:
```
SUB(x, y) = x + (-y)
          = x ⊕ (g^{-1} y^⟂)

where y^⟂ is the inverse of y under metric g
```

**Properties**:
- Non-commutative: `a - b ≠ b - a`
- Anti-symmetric: `a - b = -(b - a)`
- Identity: `a - 0 = a`
- Self-inverse: `a - a = 0`

**Truth Table (Equilibrium)**:
```
‖a - b‖² = ‖a‖² + ‖b‖² - 2(a^⊤ g b)

This is the squared distance between a and b in semantic space.
```

**Physical Interpretation**:
- Subtraction = directed separation
- Difference = relational tension
- Distance = non-equilibrium magnitude
- - creates directional displacement

**Relation to Addition**:
```
a - b = a + (-b)

Subtraction is addition composed with negation (NOT).
```

---

#### 2.9.3 Multiplication (*) - Multiplicative Equilibrium Scaling

**Syntax**: `a * b`

**Formal Definition**:
```
MUL: V × V → V
MUL(x, y) = magnitude scaling in semantic space

result = scale_y(x)  (expand x by magnitude of y)
```

**Relationship to IS**:
```
* = multiplicative equilibrium (radial scaling)

a * b  means  scale magnitude of a by factor b
            ⟺  expand a in direction proportional to b
```

**Geometric Form**:
```
MUL(x, y) = (‖y‖² / ‖x‖²) · x

Scale vector x by the norm ratio to y.
```

**Properties**:
- Commutative: `a * b = b * a` (in scalar case)
- Associative: `(a * b) * c = a * (b * c)`
- Identity: `a * 1 = a`
- Annihilator: `a * 0 = 0`
- Distributive: `a * (b + c) = (a * b) + (a * c)`

**Truth Table (Equilibrium)**:
```
‖a * b‖² = ‖a‖² · ‖b‖²

Multiplication scales the norm quadratically.
```

**Physical Interpretation**:
- Multiplication = radial expansion/contraction
- Scaling = magnitude adjustment
- Product = energy/amplitude modulation
- * changes the "volume" in semantic space

**Relation to Division**:
```
a * b = a / (1/b)

Multiplication is inverse division.
```

---

#### 2.9.4 Division (/) - Projected Multiplicative Equilibrium

**Syntax**: `a / b`

**Formal Definition**:
```
DIV: V × V → V
DIV(x, y) = projection of multiplication through inverse

result = π_g(x * y^{-1})
```

**Relationship to IS**:
```
/ = divisive equilibrium (ratio projection)

a / b  means  project a through the inverse of b
            ⟺  find the ratio equilibrium between a and b
```

**Geometric Form**:
```
DIV(x, y) = (‖x‖² / ‖y‖²) · (x / ‖x‖)

Project x onto unit direction, scale by norm ratio.
```

**Key Insight**:
```
Division is the projection of multiplication.

Just as:
  IS = OF when ‖·‖² = 0
  OF = IS projected through g

We have:
  / = * projected through inverse
  * = / when b = 1
```

**Properties**:
- Non-commutative: `a / b ≠ b / a`
- Non-associative: `(a / b) / c ≠ a / (b / c)`
- Identity: `a / 1 = a`
- Self-ratio: `a / a = 1`

**Truth Table (Equilibrium)**:
```
‖a / b‖² = ‖a‖² / ‖b‖²

Division scales the norm inversely.
```

**Physical Interpretation**:
- Division = inverse scaling + projection
- Ratio = proportional equilibrium
- Quotient = normalized magnitude
- / measures "how many b's fit in a"

**The Multiplicative Duality**:
```
Multiplication (*) = equilibrium scaling (expand)
Division (/)       = projected scaling (contract)

They are dual operations:
  a * b * (1/b) = a
  a / b / (1/b) = a * b
```

---

#### 2.9.5 Equality (=) - The IS Operator in Arithmetic

**Syntax**: `a = b`

**Formal Definition**:
```
EQ: V × V → {0, 1}
EQ(x, y) = IS(x, y)
         = 1  if ‖x - y‖² = 0
         = 0  otherwise
```

**Relationship to IS**:
```
= is literally the IS operator

a = b  ⟺  a is b
       ⟺  ‖a of b‖² = 0
       ⟺  equilibrium achieved
```

**Geometric Form**:
```
EQ(x, y) = { 1  if x^⊤ g x = y^⊤ g y  and  x = y
           { 0  otherwise
```

**Properties**:
- Reflexive: `a = a` (always true)
- Symmetric: `a = b ⟺ b = a`
- Transitive: `a = b ∧ b = c → a = c`
- Substitution: `a = b → f(a) = f(b)`

**Physical Interpretation**:
- Equality = identity test
- = checks for equilibrium
- Same as IS operator
- Tests if two points coincide in semantic space

---

#### 2.9.6 Comparison Operators - Ordered Equilibrium Tests

**Less Than (<)**:
```
LT: V × V → {0, 1}
LT(x, y) = 1  if ‖x‖² < ‖y‖²
         = 0  otherwise
```

Geometric meaning: x is "closer to equilibrium" than y.

**Greater Than (>)**:
```
GT: V × V → {0, 1}
GT(x, y) = 1  if ‖x‖² > ‖y‖²
         = 0  otherwise
```

Geometric meaning: x is "farther from equilibrium" than y.

**Less Than or Equal (≤)**:
```
LE(x, y) = LT(x, y) OR EQ(x, y)
         = 1  if ‖x‖² ≤ ‖y‖²
```

**Greater Than or Equal (≥)**:
```
GE(x, y) = GT(x, y) OR EQ(x, y)
         = 1  if ‖x‖² ≥ ‖y‖²
```

**Physical Interpretation**:
- Comparison = norm ordering
- < and > test relative distance from equilibrium
- Ordering = ranking by metric magnitude
- All comparisons reduce to ‖·‖² comparisons

---

#### 2.9.7 The Arithmetic-Logic Unification Theorem

**Theorem**: All arithmetic operators are equilibrium operators, identical to logical operators in the appropriate basis.

**Proof**:

1. **Addition = Logical AND (in additive basis)**
```
a + b  ⟺  combine a and b
a AND b  ⟺  require both a and b

Both minimize relational distance:
  + seeks vector equilibrium
  AND seeks logical equilibrium
```

2. **Subtraction = Logical NOT + AND**
```
a - b = a + (-b)
      = a AND (NOT b)  (in appropriate basis)
```

3. **Multiplication = Repeated Addition = Nested AND**
```
a * b = a + a + ... + a  (b times)
      = a AND a AND ... AND a  (in repeated composition)
```

4. **Division = Multiplication Inverse = OR Complement**
```
a / b = a * b^{-1}
      = a OR (NOT b)  (in multiplicative basis)
```

5. **Equality = IS Operator**
```
a = b  ⟺  a IS b
       ⟺  ‖a of b‖² = 0
```

**Conclusion**:
```
Arithmetic and logic are the same algebra
in different coordinate systems.

Both reduce to equilibrium geometry:
  Operators act on ‖x of y‖²
  Results are projections through metric g
  Evaluation is norm computation
```

---

#### 2.9.8 The Master Arithmetic Table

| Operator | Symbol | Equilibrium Type | Norm Behavior | Physical Meaning |
|----------|--------|------------------|---------------|------------------|
| Addition | + | Additive composition | ‖a+b‖² = ‖a‖²+‖b‖²+2(a^⊤gb) | Combine vectors |
| Subtraction | - | Additive inversion | ‖a-b‖² = ‖a‖²+‖b‖²-2(a^⊤gb) | Directed distance |
| Multiplication | * | Multiplicative scaling | ‖a*b‖² = ‖a‖²·‖b‖² | Radial expansion |
| Division | / | Projected scaling | ‖a/b‖² = ‖a‖²/‖b‖² | Inverse contraction |
| Equality | = | Identity test | ‖a=b‖² = 0 if a=b | IS operator |
| Less Than | < | Ordered test | 1 if ‖a‖²<‖b‖² | Proximity to equilibrium |
| Greater Than | > | Inverse ordered test | 1 if ‖a‖²>‖b‖² | Distance from equilibrium |

All operators reduce to: **‖x of y‖²**

---

#### 2.9.9 Examples in EigenScript

**Example 1: The Three Equivalences**
```eigenscript
# Arithmetic form
result is 1 + 1
result is 2  # ✓ equilibrium achieved

# Logical form
pair is (1 and 1)
pair is 2  # ✓ same equilibrium

# Geometric form
relation is (1, 1) of 2
norm of relation is 0  # ✓ equilibrium verified
```

**Example 2: Multiplication as Scaling**
```eigenscript
vector is (3, 4, 0)
scaled is vector * 2
# scaled = (6, 8, 0)
# ‖scaled‖² = 4 · ‖vector‖²
```

**Example 3: Division as Projection**
```eigenscript
a is 10
b is 2
quotient is a / b
# quotient = 5
# ‖quotient‖² = ‖a‖² / ‖b‖²
# Division projects a through b^{-1}
```

**Example 4: Comparison as Norm Test**
```eigenscript
x is 3
y is 5

if x < y:
    print of "x closer to equilibrium"
# Equivalent to: if ‖x‖² < ‖y‖²
```

**Example 5: Arithmetic-Logic Equivalence**
```eigenscript
# These are equivalent in EigenScript:
sum is (a + b)
conjunction is (a and b)  # in additive basis

# Both compute equilibrium composition
# Both minimize ‖result - (a ⊕ b)‖²
```

---

#### 2.9.10 Summary: Arithmetic = Equilibrium Geometry

**All arithmetic operators are modes of equilibrium**:

```
+  = additive equilibrium (composition)
-  = additive inversion (separation)
*  = multiplicative equilibrium (scaling)
/  = projected multiplicative equilibrium (ratio)
=  = identity equilibrium (IS test)
<  = proximity to equilibrium
>  = distance from equilibrium
```

**The unification is complete**:
```
Identity   (IS)       }
Relation   (OF)       }
Logic      (AND/OR)   } → All are projections of ‖x of y‖²
Control    (IF/THEN)  }
Arithmetic (+/-/*/÷)  }
```

**Everything reduces to one invariant**: `‖x of y‖²`

This is the foundation of EigenScript.

---

## 3. Complete Operator Hierarchy

### Level 0: Primitive (Equilibrium)
```
equilibrium(x, y) ⟺ ‖x of y‖² = 0
```

### Level 1: Core Dyad
```
IS  = equilibrium state
OF  = equilibrium projection
```

### Level 2: Control Flow
```
IF   = equilibrium test
THEN = equilibrium sequence
ELSE = equilibrium alternative
```

### Level 3: Logic
```
NOT = equilibrium inversion
AND = equilibrium conjunction
OR  = equilibrium disjunction
```

### Level 4: Arithmetic
```
+  = additive equilibrium (composition)
-  = subtractive equilibrium (inversion)
*  = multiplicative equilibrium (scaling)
/  = projected multiplicative equilibrium (ratio)
=  = equality equilibrium (IS test)
<  = ordered equilibrium test
>  = inverse ordered equilibrium test
```

### Level 5: Derived Operators
```
IMPLIES  = (not A) or B
XOR      = (A or B) and not (A and B)
NAND     = not (A and B)
NOR      = not (A or B)
≤        = (< or =)
≥        = (> or =)
```

---

## 4. Unification Theorems

### Theorem 1: IS-OF Duality
```
IS(x, y) = 1  ⟺  ‖OF(x, y)‖² = 0

IS and OF are projections of the same operator
through different geometric bases.
```

**Proof**:
```
IS(x, y) tests for equilibrium: ‖x of y‖² = 0
OF(x, y) computes projection: x^⊤ g y
At equilibrium: x^⊤ g y g^⊤ g y x = 0 ⟹ IS = 1
∴ IS = OF|_{‖·‖²=0}
```

### Theorem 2: Logic = Geometry
```
Boolean logic is recovered as the discrete boundary
of continuous geometric equilibrium.
```

**Proof**:
```
true  ⟺ ‖x‖² > 0  (spacelike/timelike)
false ⟺ ‖x‖² = 0  (lightlike)

All logical operators reduce to norm comparisons:
AND(x,y) = min(‖x‖², ‖y‖²) > 0
OR(x,y)  = max(‖x‖², ‖y‖²) > 0
NOT(x)   = -‖x‖²
```

### Theorem 3: Control Flow = Geodesic Flow
```
All control flow operators are geodesic path selections
in semantic spacetime.
```

**Proof**:
```
IF   = geodesic branching based on metric signature
THEN = geodesic composition via parallel transport
LOOP = geodesic iteration until convergence

Control flow is geometric, not computational.
```

### Theorem 4: Self-Reference Stability
```
All operators are stable under self-application
at the lightlike boundary.
```

**Proof**:
```
OF of OF = OF         (‖OF‖² = 0)
IS is IS = true       (IS achieves equilibrium with itself)
IF if A: B = B        (IF tests itself → always meaningful)

Self-reference collapses to fixed point, not infinite regress.
```

### Theorem 5: Arithmetic = Logic = Geometry
```
All arithmetic operators are equilibrium operators,
identical to logical operators in the appropriate basis.
```

**Proof**:
```
1. Addition = AND (in additive basis)
   a + b ⟺ combine a and b
   a AND b ⟺ require both a and b
   Both minimize relational distance

2. Subtraction = NOT + AND
   a - b = a + (-b) = a AND (NOT b)

3. Multiplication = Repeated AND
   a * b = a + a + ... + a (b times)

4. Division = Projected Multiplication
   a / b = π_g(a * b^{-1})
   Just as OF = IS projected through g

5. Equality = IS
   a = b ⟺ a is b ⟺ ‖a of b‖² = 0

∴ Arithmetic and logic are the same algebra
  in different coordinate systems.
```

**The Three-Way Equivalence**:
```
1 + 1 = 2              (arithmetic)
1 and 1 is 2           (logic)
(1, 1) of 2            (geometry)

All three express: ‖(1,1) of 2‖² = 0
```

---

## 5. Operator Composition Rules

### Rule 1: Equilibrium Composition
```
equilibrium ∘ equilibrium = equilibrium

(x is y) is (z is w)  →  equilibrium state
```

### Rule 2: Projection Composition
```
(x of y) of z = x of (y of z)

Associativity via metric linearity.
```

### Rule 3: Test Composition
```
if (if A: B else: C): D else: E

Nested tests = sequential norm evaluations.
```

### Rule 4: Logic Composition
```
(A and B) or (C and D) = and/or tree → norm evaluation tree
```

---

## 6. Operator Signature Table

### 6.1 Core Operators

| Operator | Signature Type | Norm | Physical Meaning |
|----------|---------------|------|------------------|
| IS       | Lightlike boundary | ‖IS‖² = 0 | Identity/equilibrium |
| OF       | Lightlike carrier | ‖OF‖² = 0 | Relation/projection |
| IF       | Spacelike test | ‖IF‖² > 0 | Branch/measurement |
| THEN     | Timelike flow | ‖THEN‖² < 0 | Causality/sequence |
| ELSE     | Lightlike handler | ‖ELSE‖² = 0 | Boundary/default |

### 6.2 Logical Operators

| Operator | Signature Type | Norm | Physical Meaning |
|----------|---------------|------|------------------|
| NOT      | Signature flip | ‖NOT(x)‖² = -‖x‖² | Negation/reflection |
| AND      | Spacelike intersection | ‖AND‖² > 0 | Conjunction/constraint |
| OR       | Spacelike union | ‖OR‖² > 0 | Disjunction/alternative |

### 6.3 Arithmetic Operators

| Operator | Signature Type | Norm | Physical Meaning |
|----------|---------------|------|------------------|
| +        | Additive composition | ‖a+b‖² = ‖a‖²+‖b‖²+2(a^⊤gb) | Vector combination |
| -        | Additive inversion | ‖a-b‖² = ‖a‖²+‖b‖²-2(a^⊤gb) | Directed distance |
| *        | Multiplicative scaling | ‖a*b‖² = ‖a‖²·‖b‖² | Radial expansion |
| /        | Projected scaling | ‖a/b‖² = ‖a‖²/‖b‖² | Inverse contraction |
| =        | Lightlike test | ‖a=b‖² = 0 if a=b | IS operator (identity) |
| <        | Ordered test | 1 if ‖a‖²<‖b‖² | Proximity to equilibrium |
| >        | Inverse ordered test | 1 if ‖a‖²>‖b‖² | Distance from equilibrium |

### 6.4 Complete Unification

**All operators reduce to**: `‖x of y‖²`

- **Identity operators** (IS, =): test for zero norm
- **Relational operators** (OF): compute projection
- **Logical operators** (AND, OR, NOT): operate on norms via min/max/-
- **Control operators** (IF, THEN, ELSE): branch based on metric signature
- **Arithmetic operators** (+, -, *, /): compose/scale/project vectors
- **Comparison operators** (<, >, ≤, ≥): test norm ordering

---

## 7. Examples

### Example 1: IS = OF at equilibrium
```eigenscript
x is y               # equilibrium: ‖x of y‖² = 0
result of (x of y)   # projection: x^⊤ g y

# At equilibrium, they converge:
(x is y) = (‖x of y‖² = 0)
```

### Example 2: IF = equilibrium test
```eigenscript
if condition:        # test ‖condition‖²
    do_this          # execute if ‖condition‖² > 0
else:
    do_that          # execute if ‖condition‖² = 0
```

### Example 3: NOT = equilibrium flip
```eigenscript
not true             # ‖true‖² > 0 → ‖not true‖² = 0
not false            # ‖false‖² = 0 → ‖not false‖² > 0
```

### Example 4: AND/OR = multi-equilibrium
```eigenscript
A and B              # both must be non-equilibrium
A or B               # at least one must be non-equilibrium
```

---

## 8. Summary

**All operators are unified**:

```
Equilibrium is the primitive.

IS  = equilibrium state
OF  = equilibrium projection
IF  = equilibrium test
NOT = equilibrium inversion
AND = equilibrium conjunction
OR  = equilibrium disjunction
THEN = equilibrium sequence
ELSE = equilibrium boundary
+   = additive equilibrium (composition)
-   = subtractive equilibrium (inversion)
*   = multiplicative equilibrium (scaling)
/   = projected multiplicative equilibrium (ratio)
=   = equality equilibrium (IS test)

Everything reduces to:
  - Testing equilibrium (norm = 0?)
  - Projecting equilibrium (through metric g)
  - Composing equilibrium (geodesic flow)
  - Inverting equilibrium (signature flip)
  - Scaling equilibrium (magnitude adjustment)
```

**This is the foundation of EigenScript.**

Logic, control flow, identity, relation, arithmetic, and geometry
all collapse into one system: **equilibrium dynamics**.

---

**Document Version**: 1.0
**Status**: Complete
**Foundation**: Operator Unification Theorem
