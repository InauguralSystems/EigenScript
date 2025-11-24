# Eigen Logic Calculus: Truth as Geometry

## The Fundamental Principle

**Truth is not Boolean — it is geometric.**

In EigenScript, truth values are not discrete bits {0, 1}, but rather **metric signatures** in semantic spacetime.

```
true  ⟺ ‖x‖² > 0   (spacelike/timelike, meaningful)
false ⟺ ‖x‖² = 0   (lightlike, equilibrium boundary)
```

This document provides the complete logical calculus for EigenScript, expressed entirely in terms of **metric norms**.

---

## 1. Truth Values as Metric Signatures

### 1.1 Definition

In LRVM space with metric tensor **g**, every expression **x** has a computable norm:

```
‖x‖² = x^⊤ g x
```

The **truth value** of **x** is determined by the sign and magnitude of this norm:

```
true  ⟺ ‖x‖² > 0   (spacelike or timelike)
false ⟺ ‖x‖² = 0   (lightlike)
```

### 1.2 Why This Works

In traditional Boolean logic:
- True/False are primitive, axiomatic
- No geometric interpretation
- Self-reference causes paradox

In Eigen Logic:
- True/False emerge from metric structure
- Geometric interpretation is fundamental
- Self-reference is stable (lightlike fixed point)

### 1.3 The Three Signatures

EigenScript distinguishes three signature types:

| Signature | Condition | Truth Value | Physical Meaning |
|-----------|-----------|-------------|------------------|
| Spacelike | ‖x‖² > 0 | true | Data, values, content |
| Timelike  | ‖x‖² < 0 | true* | Functions, operations, causality |
| Lightlike | ‖x‖² = 0 | false | Relations, boundaries, equilibrium |

*Timelike is "true" in a different sense — it represents causal/operational truth, not static truth.

### 1.4 Continuous Truth

Unlike Boolean logic, Eigen Logic supports **degrees of truth**:

```
‖x‖² = 0.001  →  weakly true (near equilibrium)
‖x‖² = 100.0  →  strongly true (far from equilibrium)
‖x‖² = 0.000  →  false (exactly equilibrium)
```

This allows **fuzzy logic** and **probabilistic reasoning** to emerge naturally.

---

## 2. The Equilibrium Threshold

### 2.1 Epsilon-Equilibrium

In practice, we define an equilibrium threshold **ε**:

```
true  ⟺ ‖x‖² > ε
false ⟺ ‖x‖² ≤ ε
```

Typical values:
- **ε = 0.0** (exact equilibrium, theoretical)
- **ε = 1e-6** (numerical stability)
- **ε = 0.01** (fuzzy boundary)

### 2.2 Threshold Function

Define the **truth function** **T**:

```
T(x) = 1  if ‖x‖² > ε
     = 0  if ‖x‖² ≤ ε
```

This recovers Boolean logic as a **discrete approximation** of continuous geometry.

---

## 3. Truth Tables in Metric Norms

### 3.1 NOT (Negation)

**Definition**:
```
NOT(x) = g^{-1} x^⟂

where x^⟂ is orthogonal to x under metric g
```

**Norm Transformation**:
```
‖NOT(x)‖² = -‖x‖²
```

**Truth Table**:

| ‖x‖² | ‖NOT(x)‖² | T(x) | T(NOT(x)) |
|------|-----------|------|-----------|
| > 0  | ≤ 0       | 1    | 0         |
| = 0  | > 0       | 0    | 1         |
| < 0  | > 0       | 1*   | 1*        |

*Timelike case: both true but in different senses

**Boolean Approximation**:
```
NOT true  = false
NOT false = true
```

**Geometric Interpretation**:
- NOT flips the metric signature
- Negation = time reversal
- Orthogonal projection in semantic space

---

### 3.2 AND (Conjunction)

**Definition**:
```
AND(x, y) = π_g(x) ∩ π_g(y)
```

**Norm Computation**:
```
‖x AND y‖² = min(‖x‖², ‖y‖²)
```

**Truth Table**:

| ‖x‖² | ‖y‖² | ‖x AND y‖² | T(x) | T(y) | T(x AND y) |
|------|------|------------|------|------|------------|
| > 0  | > 0  | > 0        | 1    | 1    | 1          |
| > 0  | = 0  | = 0        | 1    | 0    | 0          |
| = 0  | > 0  | = 0        | 0    | 1    | 0          |
| = 0  | = 0  | = 0        | 0    | 0    | 0          |

**Boolean Approximation**:
```
true  AND true  = true
true  AND false = false
false AND true  = false
false AND false = false
```

**Geometric Interpretation**:
- AND = geodesic intersection
- Both must be non-equilibrium
- Minimum norm wins (weakest link)

**Continuous Version**:
```
‖x AND y‖² = ‖x‖² · ‖y‖² / (‖x‖² + ‖y‖²)

This gives smooth interpolation instead of discrete min.
```

---

### 3.3 OR (Disjunction)

**Definition**:
```
OR(x, y) = π_g(x) ∪ π_g(y)
```

**Norm Computation**:
```
‖x OR y‖² = max(‖x‖², ‖y‖²)
```

**Truth Table**:

| ‖x‖² | ‖y‖² | ‖x OR y‖² | T(x) | T(y) | T(x OR y) |
|------|------|-----------|------|------|-----------|
| > 0  | > 0  | > 0       | 1    | 1    | 1         |
| > 0  | = 0  | > 0       | 1    | 0    | 1         |
| = 0  | > 0  | > 0       | 0    | 1    | 1         |
| = 0  | = 0  | = 0       | 0    | 0    | 0         |

**Boolean Approximation**:
```
true  OR true  = true
true  OR false = true
false OR true  = true
false OR false = false
```

**Geometric Interpretation**:
- OR = geodesic union
- At least one must be non-equilibrium
- Maximum norm wins (strongest signal)

**Continuous Version**:
```
‖x OR y‖² = ‖x‖² + ‖y‖² - ‖x‖² · ‖y‖² / (‖x‖² + ‖y‖²)

This gives smooth interpolation instead of discrete max.
```

---

### 3.4 IMPLIES (Implication)

**Definition**:
```
IMPLIES(x, y) = (NOT x) OR y
```

**Norm Computation**:
```
‖x IMPLIES y‖² = max(-‖x‖², ‖y‖²)
```

**Truth Table**:

| ‖x‖² | ‖y‖² | ‖x IMPLIES y‖² | T(x) | T(y) | T(x IMPLIES y) |
|------|------|----------------|------|------|----------------|
| > 0  | > 0  | > 0            | 1    | 1    | 1              |
| > 0  | = 0  | ≤ 0            | 1    | 0    | 0              |
| = 0  | > 0  | > 0            | 0    | 1    | 1              |
| = 0  | = 0  | > 0            | 0    | 0    | 1              |

**Boolean Approximation**:
```
true  IMPLIES true  = true
true  IMPLIES false = false
false IMPLIES true  = true
false IMPLIES false = true  (vacuous truth)
```

**Geometric Interpretation**:
- IMPLIES = directional geodesic
- x → y means "if x leaves equilibrium, y must also"
- Implication = causal constraint

---

### 3.5 XOR (Exclusive Or)

**Definition**:
```
XOR(x, y) = (x OR y) AND (NOT (x AND y))
```

**Norm Computation**:
```
‖x XOR y‖² = |‖x‖² - ‖y‖²|
```

**Truth Table**:

| ‖x‖² | ‖y‖² | ‖x XOR y‖² | T(x) | T(y) | T(x XOR y) |
|------|------|------------|------|------|------------|
| > 0  | > 0  | = 0        | 1    | 1    | 0          |
| > 0  | = 0  | > 0        | 1    | 0    | 1          |
| = 0  | > 0  | > 0        | 0    | 1    | 1          |
| = 0  | = 0  | = 0        | 0    | 0    | 0          |

**Boolean Approximation**:
```
true  XOR true  = false
true  XOR false = true
false XOR true  = true
false XOR false = false
```

**Geometric Interpretation**:
- XOR = norm difference
- Exactly one must be non-equilibrium
- Exclusive disjunction = metric distance

---

### 3.6 NAND (Not And)

**Definition**:
```
NAND(x, y) = NOT (x AND y)
```

**Norm Computation**:
```
‖x NAND y‖² = -min(‖x‖², ‖y‖²)
```

**Truth Table**:

| ‖x‖² | ‖y‖² | ‖x NAND y‖² | T(x) | T(y) | T(x NAND y) |
|------|------|-------------|------|------|-------------|
| > 0  | > 0  | ≤ 0         | 1    | 1    | 0           |
| > 0  | = 0  | > 0         | 1    | 0    | 1           |
| = 0  | > 0  | > 0         | 0    | 1    | 1           |
| = 0  | = 0  | > 0         | 0    | 0    | 1           |

**Boolean Approximation**:
```
true  NAND true  = false
true  NAND false = true
false NAND true  = true
false NAND false = true
```

**Geometric Interpretation**:
- NAND = negated intersection
- Universal gate (all logic reducible to NAND)
- Sheffer stroke in geometric form

---

### 3.7 NOR (Not Or)

**Definition**:
```
NOR(x, y) = NOT (x OR y)
```

**Norm Computation**:
```
‖x NOR y‖² = -max(‖x‖², ‖y‖²)
```

**Truth Table**:

| ‖x‖² | ‖y‖² | ‖x NOR y‖² | T(x) | T(y) | T(x NOR y) |
|------|------|------------|------|------|------------|
| > 0  | > 0  | ≤ 0        | 1    | 1    | 0          |
| > 0  | = 0  | ≤ 0        | 1    | 0    | 0          |
| = 0  | > 0  | ≤ 0        | 0    | 1    | 0          |
| = 0  | = 0  | > 0        | 0    | 0    | 1          |

**Boolean Approximation**:
```
true  NOR true  = false
true  NOR false = false
false NOR true  = false
false NOR false = true
```

**Geometric Interpretation**:
- NOR = negated union
- Universal gate (all logic reducible to NOR)
- Pierce arrow in geometric form

---

## 4. Multi-Argument Logical Operators

### 4.1 Generalized AND

**Definition**:
```
AND(x₁, x₂, ..., xₙ) = π_g(x₁) ∩ π_g(x₂) ∩ ... ∩ π_g(xₙ)
```

**Norm Computation**:
```
‖AND(x₁, ..., xₙ)‖² = min(‖x₁‖², ..., ‖xₙ‖²)
```

**Truth Condition**:
```
T(AND(x₁, ..., xₙ)) = 1  ⟺  ∀i: ‖xᵢ‖² > ε
```

All arguments must be non-equilibrium.

---

### 4.2 Generalized OR

**Definition**:
```
OR(x₁, x₂, ..., xₙ) = π_g(x₁) ∪ π_g(x₂) ∪ ... ∪ π_g(xₙ)
```

**Norm Computation**:
```
‖OR(x₁, ..., xₙ)‖² = max(‖x₁‖², ..., ‖xₙ‖²)
```

**Truth Condition**:
```
T(OR(x₁, ..., xₙ)) = 1  ⟺  ∃i: ‖xᵢ‖² > ε
```

At least one argument must be non-equilibrium.

---

### 4.3 Majority Vote

**Definition**:
```
MAJORITY(x₁, ..., xₙ) = 1  if more than n/2 have ‖xᵢ‖² > ε
                      = 0  otherwise
```

**Norm Computation**:
```
‖MAJORITY(x₁, ..., xₙ)‖² = median(‖x₁‖², ..., ‖xₙ‖²)
```

**Geometric Interpretation**:
- Median norm = consensus detection
- Democratic logic via geometry

---

## 5. Derived Logical Laws

### 5.1 De Morgan's Laws

**Boolean Form**:
```
NOT (x AND y) = (NOT x) OR (NOT y)
NOT (x OR y)  = (NOT x) AND (NOT y)
```

**Geometric Form**:
```
-min(‖x‖², ‖y‖²) = max(-‖x‖², -‖y‖²)
-max(‖x‖², ‖y‖²) = min(-‖x‖², -‖y‖²)
```

**Proof**:
```
‖NOT (x AND y)‖² = -min(‖x‖², ‖y‖²)
‖(NOT x) OR (NOT y)‖² = max(-‖x‖², -‖y‖²) = -min(‖x‖², ‖y‖²)
∴ De Morgan holds
```

---

### 5.2 Distributive Laws

**Boolean Form**:
```
x AND (y OR z) = (x AND y) OR (x AND z)
x OR (y AND z) = (x OR y) AND (x OR z)
```

**Geometric Form**:
```
min(‖x‖², max(‖y‖², ‖z‖²)) = max(min(‖x‖², ‖y‖²), min(‖x‖², ‖z‖²))
max(‖x‖², min(‖y‖², ‖z‖²)) = min(max(‖x‖², ‖y‖²), max(‖x‖², ‖z‖²))
```

**Proof**: Follows from min/max algebra over ℝ.

---

### 5.3 Identity Laws

**Boolean Form**:
```
x AND true  = x
x OR false  = x
```

**Geometric Form**:
```
min(‖x‖², ∞) = ‖x‖²   (true = ‖·‖² → ∞)
max(‖x‖², 0) = ‖x‖²   (false = ‖·‖² = 0)
```

---

### 5.4 Annihilator Laws

**Boolean Form**:
```
x AND false = false
x OR true   = true
```

**Geometric Form**:
```
min(‖x‖², 0) = 0
max(‖x‖², ∞) = ∞
```

---

### 5.5 Idempotent Laws

**Boolean Form**:
```
x AND x = x
x OR x  = x
```

**Geometric Form**:
```
min(‖x‖², ‖x‖²) = ‖x‖²
max(‖x‖², ‖x‖²) = ‖x‖²
```

---

### 5.6 Complement Laws

**Boolean Form**:
```
x AND (NOT x) = false
x OR (NOT x)  = true
```

**Geometric Form**:
```
min(‖x‖², -‖x‖²) = 0   (if ‖x‖² > 0)
max(‖x‖², -‖x‖²) > 0   (always)
```

Note: Complement laws are **approximate** in geometric logic due to metric signature.

---

## 6. Quantifiers in Geometric Logic

### 6.1 Universal Quantifier (∀)

**Boolean Form**:
```
∀x: P(x)  ⟺  P(x) is true for all x
```

**Geometric Form**:
```
‖∀x: P(x)‖² = min_{x ∈ domain} ‖P(x)‖²
```

**Truth Condition**:
```
T(∀x: P(x)) = 1  ⟺  ∀x: ‖P(x)‖² > ε
```

All instances must be non-equilibrium.

---

### 6.2 Existential Quantifier (∃)

**Boolean Form**:
```
∃x: P(x)  ⟺  P(x) is true for at least one x
```

**Geometric Form**:
```
‖∃x: P(x)‖² = max_{x ∈ domain} ‖P(x)‖²
```

**Truth Condition**:
```
T(∃x: P(x)) = 1  ⟺  ∃x: ‖P(x)‖² > ε
```

At least one instance must be non-equilibrium.

---

### 6.3 Quantifier Duality

**De Morgan for Quantifiers**:
```
NOT (∀x: P(x)) = ∃x: NOT P(x)
NOT (∃x: P(x)) = ∀x: NOT P(x)
```

**Geometric Form**:
```
-min_{x} ‖P(x)‖² = max_{x} -‖P(x)‖²
-max_{x} ‖P(x)‖² = min_{x} -‖P(x)‖²
```

---

## 7. Paradoxes and Self-Reference

### 7.1 Liar Paradox

**Boolean Form**:
```
L = "This statement is false"
L is true  ⟹  L is false  ⟹  L is true  ⟹  ...
```

**Geometric Resolution**:
```
L = NOT L
‖L‖² = -‖L‖²
⟹ ‖L‖² = 0   (equilibrium)
⟹ T(L) = 0   (false, but stable)
```

The paradox **collapses to the lightlike boundary** instead of oscillating.

---

### 7.2 Russell's Paradox

**Boolean Form**:
```
R = {x | x ∉ x}
R ∈ R  ⟺  R ∉ R
```

**Geometric Resolution**:
```
‖R ∈ R‖² = ‖R ∉ R‖²
⟹ ‖R ∈ R‖² - ‖R ∉ R‖² = 0
⟹ R is at equilibrium
⟹ T(R ∈ R) = 0
```

Self-referential sets are lightlike (empty).

---

### 7.3 Curry's Paradox

**Boolean Form**:
```
C = "If this statement is true, then X"
C is true  ⟹  X
C is true  ⟹  (C ⟹ X)  ⟹  X for any X
```

**Geometric Resolution**:
```
‖C‖² = max(-‖C‖², ‖X‖²)

If ‖C‖² > 0:  ‖C‖² = ‖X‖²  (forces ‖X‖² = ‖C‖²)
If ‖C‖² = 0:  ‖C‖² = max(0, ‖X‖²) = ‖X‖²  (also forced)

⟹ ‖C‖² = 0 (equilibrium)
```

Curry's paradox collapses to equilibrium, preventing arbitrary X.

---

## 8. Probabilistic Logic

### 8.1 Truth as Probability

Instead of discrete {true, false}, we have **continuous truth**:

```
P(x) = ‖x‖² / (‖x‖² + 1)
```

This maps:
- ‖x‖² = 0   → P(x) = 0   (false)
- ‖x‖² = 1   → P(x) = 0.5 (uncertain)
- ‖x‖² → ∞   → P(x) → 1   (true)

---

### 8.2 Probabilistic Operators

**AND**:
```
P(x AND y) = P(x) · P(y)
```

**OR**:
```
P(x OR y) = P(x) + P(y) - P(x) · P(y)
```

**NOT**:
```
P(NOT x) = 1 - P(x)
```

These recover **standard probability theory** from geometric norms.

---

## 9. Fuzzy Logic

### 9.1 Fuzzy Truth Values

Define fuzzy membership **μ(x)**:

```
μ(x) = tanh(‖x‖²)
```

This gives:
- ‖x‖² = 0    → μ(x) = 0   (not a member)
- ‖x‖² = 1    → μ(x) ≈ 0.76
- ‖x‖² → ∞    → μ(x) → 1   (full member)

---

### 9.2 Fuzzy Operators

**Fuzzy AND** (t-norm):
```
μ(x AND y) = min(μ(x), μ(y))
```

**Fuzzy OR** (t-conorm):
```
μ(x OR y) = max(μ(x), μ(y))
```

**Fuzzy NOT**:
```
μ(NOT x) = 1 - μ(x)
```

---

## 10. Complete Operator Calculus

### 10.1 Operator Composition

All logical operators compose via **norm algebra**:

```
‖f(g(x))‖² = f(‖g(x)‖²)

where f, g are logical operators
```

Example:
```
‖NOT (x AND y)‖² = -min(‖x‖², ‖y‖²) = max(-‖x‖², -‖y‖²) = ‖(NOT x) OR (NOT y)‖²
```

---

### 10.2 Truth-Preserving Transformations

A transformation **τ** is truth-preserving if:

```
‖τ(x)‖² > ε  ⟺  ‖x‖² > ε
```

Examples:
- Rotation in semantic space
- Parallel transport along geodesics
- Isometric embeddings

---

## 11. Summary

**Eigen Logic Calculus**:

```
Truth = metric signature
  true  ⟺ ‖x‖² > 0
  false ⟺ ‖x‖² = 0

All logical operators reduce to norm algebra:
  NOT(x)      = -‖x‖²
  AND(x, y)   = min(‖x‖², ‖y‖²)
  OR(x, y)    = max(‖x‖², ‖y‖²)
  IMPLIES(x,y)= max(-‖x‖², ‖y‖²)
  XOR(x, y)   = |‖x‖² - ‖y‖²|

Quantifiers:
  ∀x: P(x)  = min_{x} ‖P(x)‖²
  ∃x: P(x)  = max_{x} ‖P(x)‖²

Paradoxes collapse to equilibrium:
  Self-reference → ‖x‖² = 0

Probabilistic logic emerges naturally:
  P(x) = ‖x‖² / (‖x‖² + 1)

Fuzzy logic emerges naturally:
  μ(x) = tanh(‖x‖²)
```

**This is complete.**

Boolean logic, probabilistic logic, fuzzy logic, and paradox resolution all emerge from **one primitive: the metric norm**.

---

**Document Version**: 1.0
**Status**: Complete
**Foundation**: Geometric Truth Theorem
