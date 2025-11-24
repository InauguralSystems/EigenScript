# EigenScript Theoretical Foundations

**Purpose**: Core mathematical/geometric principles underlying the language
**Status**: Foundational theory for future rewrite
**Author**: Original conceptual design

---

## Operator Theory

### The Three Fundamental Operators

1. **`is`** - Identity/Binding
   - Creates identity in semantic space
   - Immutable binding (trajectory point, not mutation)
   - Example: `x is 5`

2. **`of`** - Projection/Relation
   - Lightlike operator (||OF||² = 0)
   - Projects through metric tensor g
   - Example: `parent of child`

3. **`=`** - Equilibrium
   - Balance/equality test
   - Used in conditionals
   - Example: `if x = 0:`

---

## Operator Duality

### IS ↔ OF Projections

**Core Principle**: `is` and `of` are projections of each other

```
1 and 1 is 2    # Identity form
1 and 1 of 2    # Relational form
```

**Mathematical Insight**:
- IS and OF are dual operators
- They represent the same underlying geometric operation
- Viewed from different reference frames in semantic space

**CRUCIAL DISCOVERY**: Both `is` and `of` are **lightlike**

```
||is||² = 0
||of||² = 0
```

**Why This Matters**:
1. **Zero norm** means they exist on the null boundary of semantic space
2. **Lightlike operators don't add weight** - they're carriers without content
3. **Transformations preserve lightlike property** - `is` can become `of` without changing norm
4. **Self-reference stays bounded** - operations on null boundary can't diverge
5. **OF of OF = OF** - composing lightlike operators remains lightlike (fixed point)

This is the **fundamental innovation**: making relational operators lightlike enables stable self-reference.

---

## Loop Transformation Principle

**Key Discovery**: Operators transform in loops/iteration

### Transformation Rules:

1. **`is` in loop → becomes `of`**
   - Identity transforms to projection under iteration
   - Repeated binding becomes relational flow

2. **`of` in loop → becomes `is`**
   - Projection transforms to identity under iteration
   - Repeated relations converge to binding

### Why This Matters:

Iteration in EigenScript is not just repetition - it's **geometric transformation**. Each loop iteration moves through a different projection of semantic space, causing the operators to swap roles.

This explains:
- Why self-reference should converge (transforms at each step)
- Why loops are inherently geometric (not just control flow)
- Why recursion is fundamentally different from traditional languages

---

## Temporal Reference Model: The Mechanism of is and of

### The Complete Formalization

**is and of are temporal reference operations:**

```
is = Create immutable fact at time t (write operation)
of = Retrieve immutable fact from time t-1 (read operation)
```

**The Fundamental Examples:**

```eigenscript
1 is 1     # Creates truth: "1 equals 1" at t=now
           # Assertion that creates immutable fact

1 of 1     # Retrieves truth: "previous answer already known" from t-1
           # Reference to previously established fact

In time: 1 of 1 = 1  (reference evaluates to value)
```

**Key insight:** `of` is always **1 iteration behind** `is`
- `is` operates in the present (writes)
- `of` references the past (reads from t-1)
- Both are lightlike because they are REFERENCE operations, not copies

### How "of becomes is" Through Time

Through iteration, retrieved values become available for new bindings:

```eigenscript
# Iteration 0 (t=0):
x is 1          # Write: x → 1 at t=0

# Iteration 1 (t=1):
y of x          # Read: x from t=0 → evaluates to 1
z is y          # Write: z → retrieved value (1) at t=1
                # "of became is" - retrieved value enabled new binding

# Iteration 2 (t=2):
a of z          # Read: z from t=1 → evaluates to 1
b is a          # Write: b → 1 at t=2
                # Propagation continues forward in time
```

**The propagation pattern:**
```
t=0: x is 1       (fact created)
t=1: y of x = 1   (fact retrieved: "previous answer already known")
     z is y       (retrieved value becomes new fact)
t=2: a of z = 1   (new fact retrieved)
     b is a       (propagates forward)

Each iteration:
  - of reads from previous iteration (t-1)
  - is writes to current iteration (t)
  - Values flow forward through time
```

### Why Both Are Lightlike

```
||is||² = 0  → Creates reference (pointer), not semantic content
||of||² = 0  → Dereferences pointer, no weight added

Both are carriers without content:
  is: Creates binding (relationship, not data)
  of: Follows binding (reference, not copy)

Neither operation adds weight to semantic space:
  - is creates immutable pointer at time t
  - of retrieves through pointer from time t-1
  - Both preserve lightlike property (zero norm)
  - No accumulation possible
```

### Self-Reference Convergence Explained

```eigenscript
define observer as:
    meta is observer of observer
    return meta
```

**With temporal reference understanding:**

```
Iteration 0 (first call):
  "observer of observer" references iteration -1 (doesn't exist)
  meta is null (or initial_state)
  return null

Iteration 1:
  "observer of observer" references iteration 0
  Retrieves: observer₀ = null
  meta is null
  return null

Iteration 2:
  "observer of observer" references iteration 1
  Retrieves: observer₁ = null
  meta is null (same as previous)
  return null

Converged: observer_i = observer_{i-1} (eigenstate reached)
```

**The key difference from traditional recursion:**

```
Traditional recursion:
  f() calls CURRENT f()
  Stack grows: f₀ → f₁ → f₂ → ... → ∞
  Diverges

EigenScript temporal reference:
  f() reads from PREVIOUS f() (iteration i-1)
  No stack growth: just iteration chain
  Converges when f_i = f_{i-1}
```

### Implementation Model

**Each iteration maintains:**
- Current bindings (writable via `is`)
- Link to previous iteration (readable via `of`)
- Immutable after iteration completes

**Function calls create new iterations:**

```c
typedef struct IterationState {
    HashMap* bindings;        // name → value at this iteration
    int iteration_number;
    struct IterationState* prev;  // Link to previous iteration
} IterationState;

// is: Create binding at CURRENT iteration
void eigen_is(Context* ctx, Symbol name, Value value) {
    hashmap_set(
        ctx->current_iteration->bindings,
        name,
        value  // Lightlike reference, not copy
    );
    assert(value.norm == 0.0);
}

// of: Retrieve binding from PREVIOUS iteration
Value eigen_of(Context* ctx, Symbol name) {
    if (!ctx->current_iteration->prev) {
        return null_value;  // No previous iteration
    }

    Value* prev_value = hashmap_get(
        ctx->current_iteration->prev->bindings,
        name
    );

    return prev_value ? *prev_value : null_value;
}
```

### What This Model Explains

**Why recursion works:**
```eigenscript
define factorial as:
    if n < 2:
        return 1
    else:
        prev is n - 1
        sub_result is factorial of prev
        # Creates NEW iteration at t+1
        # That iteration can "of" reference its predecessor at t
        return n * sub_result
```

**Why self-reference converges:**
```eigenscript
meta is observer of observer
# At iteration i: references observer from iteration i-1
# Eventually: observer_i = observer_{i-1} (eigenstate)
# Not infinite recursion - bounded temporal reference
```

**Why emotions don't accumulate:**
```eigenscript
anger is emotion_at(t=yesterday)  # Created at t=yesterday
today of anger                     # Retrieved today (t-1 reference)
# Both lightlike (reference operations)
# No accumulation - just temporal lookup
# Can store infinite history without burden
```

**Why "what if" on past fails:**
```eigenscript
# Past state at t=0 is IMMUTABLE
past is state_at(t=0)  # Fact created

# At t=1: trying to change it
"what if I had..."     # Attempts: past is different_state
                       # But past already immutable at t=0
                       # Causality violation
                       # Creates contradiction loop
```

### Temporal Causality Preservation

**The unidirectional flow:**
```
Past (t-1) → Present (t) → Future (t+1)

Valid operations:
  is: Create at time t ✓
  of: Read from time t-1 ✓
  Propagate forward ✓

Invalid operations:
  Modify time t-1 from time t ✗
  "What if" on past ✗
  Backward causation ✗
```

This temporal reference model is the **concrete mechanism** underlying:
- Lightlike operator property (references, not copies)
- Loop transformation (temporal progression)
- Self-reference convergence (bounded iteration)
- Causality preservation (unidirectional time)

---

## Geometric Foundations

### The Lightlike Breakthrough

**Core Innovation**: Making `is` and `of` lightlike (zero norm) solves the self-reference problem.

**In Physics**: Light travels on the null boundary of spacetime (||light||² = 0)
- Can't be caught (moves at c)
- Defines the causal boundary
- Connects all points without "distance"

**In EigenScript**: `is` and `of` exist on the null boundary of semantic space (||is||² = ||of||² = 0)
- Can't diverge (no accumulation)
- Define the relational boundary
- Connect concepts without "semantic weight"

**Why Traditional Languages Fail**:
```
Traditional: function calls are timelike (||call||² < 0)
→ Each recursion adds negative norm
→ Accumulates "execution weight"
→ Diverges to infinity
```

**Why EigenScript Works** (in theory):
```
EigenScript: operations are lightlike (||is||² = ||of||² = 0)
→ Each iteration stays at zero norm
→ No accumulation possible
→ Bounded on null surface
→ Converges to eigenstate
```

### LRVM Space (Linguistic Relational Vector Model)

- **Dimensionality**: 768-dimensional semantic space
- **Metric**: Tensor g defines geometric properties
- **Norm**: ||v||² = v^T g v

### Signature Types:

1. **Lightlike** (||v||² ≈ 0)
   - Relations, operators
   - OF operator is fundamentally lightlike

2. **Spacelike** (||v||² > 0)
   - Values, data
   - Content with semantic weight

3. **Timelike** (||v||² < 0)
   - Functions, transformations
   - Sequential operations

---

## Self-Reference Theory

### The Problem in Traditional Languages:

```
function f() {
    return f();
}
```
This diverges (infinite recursion) because each call is **timelike** - moving forward in "execution time" with no convergence.

### EigenScript Solution (Theoretical):

```eigenscript
define observer as:
    meta is observer of observer
    return meta
```

**Why it should converge**:
1. **Both `is` AND `of` are lightlike** (||is||² = 0, ||of||² = 0)
2. **Lightlike operators don't accumulate weight** - they're carriers without content
3. **Self-reference stays on null boundary** - can't diverge because norm stays zero
4. **Loop transformation**: `is` → `of` → `is` at each iteration (preserves lightlike)
5. **Geometric flow reaches eigenstate** - operations on null boundary have natural fixed points
6. **Self-reference becomes stable boundary condition** - not a diverging spiral

**The Key Insight**: Traditional recursion diverges because each call adds timelike "execution weight". EigenScript self-reference stays on the lightlike boundary where weight = 0.

**Current Status**: Theory sound, implementation has infinite recursion bug. The Python interpreter doesn't properly implement lightlike property preservation. Needs proper geometric operations in rewrite.

---

## Framework Strength (FS)

**Definition**: Measure of semantic convergence during execution

**Formula**: `FS = 1.0 / (1.0 + variance_of_recent_states)`

**Components**:
1. **Variance reduction**: Lower variance → higher FS
2. **Trajectory smoothness**: Steady flow → higher FS
3. **Eigenstate stability**: Approaching fixed point → higher FS

**Range**: 0.0 (fragmented/chaotic) to 1.0 (converged/understood)

---

## EigenControl Universal Primitive

**Formula**: `I = (A - B)²`

**Insight**: Single measurement of "distance between where we are and where we were"

**Yields**:
- Convergence metrics
- Stability detection
- Direction/trajectory
- Quality assessment

All geometric state emerges from this one simple measurement.

---

## Predicates (Self-Awareness)

Programs can query their own geometric state:

1. **`converged`**: Is trajectory stable? (FS ≥ threshold)
2. **`stable`**: Is system in equilibrium? (timelike trajectory)
3. **`improving`**: Is progress being made? (decreasing distances)
4. **`diverging`**: Moving away from solution?
5. **`oscillating`**: Going in cycles?
6. **`equilibrium`**: At a tipping point?

These aren't manually tracked - they emerge from the **geometric properties** of execution.

---

## Interrogatives (Self-Interrogation)

Programs can ask questions about values:

1. **`who is x`**: Get identity/name
2. **`what is x`**: Get value/magnitude
3. **`when is x`**: Get temporal position
4. **`where is x`**: Get spatial position
5. **`why is x`**: Get change direction
6. **`how is x`**: Get quality metrics

Traditional languages require explicit print statements. EigenScript has **built-in introspection**.

---

## Why This Is Novel

### Traditional Programming:
- Execution is **blind** (no self-awareness)
- Self-reference causes **divergence** (infinite loops)
- State is **opaque** (must print to debug)
- Control flow is **procedural** (not geometric)

### EigenScript:
- Execution is **self-aware** (can query own state)
- Self-reference **converges** (geometric fixed points)
- State is **transparent** (interrogatives reveal it)
- Control flow is **geometric** (transformations in semantic space)

---

## Implementation Challenges

### Current Python Implementation:

**What Works**:
- ✅ LRVM 768-dimensional space
- ✅ Metric tensor calculations
- ✅ Framework Strength tracking
- ✅ Interrogatives and predicates
- ✅ Basic operators

**What Doesn't Work**:
- ❌ Loop transformation (`is` ↔ `of` duality not implemented)
- ❌ Stable self-reference (infinite recursion instead of convergence)
- ❌ Parser doesn't match spec (comments break, IS in conditionals)

### For Future Rewrite:

**Must Implement**:
1. **Loop transformation** - `is` becomes `of` and vice versa in iterations
2. **Convergence detection** - Detect when self-reference reaches eigenstate
3. **Proper geometry** - All operations must respect metric tensor
4. **Comment handling** - Parser should allow comments anywhere
5. **Syntax consistency** - `if n is 0:` should work (not just `if n = 0:`)

---

## Mathematical Rigor (Future Work)

To make this a real research contribution:

1. **Prove convergence** - Show self-reference reaches fixed points under what conditions
2. **Prove completeness** - Show language is Turing complete (currently informal)
3. **Formalize semantics** - Mathematical definition of LRVM operations
4. **Prove loop duality** - Show `is` ↔ `of` transformation is well-defined
5. **Benchmark against λ-calculus** - Compare expressiveness

---

## Vision for Rewrite

When rewriting in Java/other language:

### Core Goals:
1. **Implement loop duality properly** - This is the key innovation
2. **Make self-reference work** - Show stable convergence in practice
3. **Rigorous geometry** - All operations through metric tensor
4. **Performance** - Optimize LRVM operations, maybe compile to bytecode
5. **Clean syntax** - Match spec exactly, no implementation quirks

### Language Choice Considerations:
- **Java**: Good type system, performance, familiar
- **Rust**: Memory safety, performance, explicit geometry
- **C++**: Maximum performance, full control
- **Haskell**: Functional, good for algebraic operations
- **OCaml**: Good for language implementation, fast

**Recommendation**: Start with language you're learning (Java) for first rewrite, optimize later if needed.

---

## Related Documents

- `README.md` - Project overview
- `docs/specification.md` - Language specification
- `docs/architecture.md` - Implementation architecture
- `KNOWN_ISSUES.md` - Current implementation problems
- `HONEST_ROADMAP.md` - Development plan

---

## Key Insights for Future Self

**What makes EigenScript unique:**
1. Operators transform in loops (`is` ↔ `of`)
2. Self-reference converges (in theory)
3. Programs are self-aware (interrogatives + predicates)
4. Computation is geometric (flow in semantic space)

**What needs work:**
1. Loop transformation not implemented
2. Convergence detection incomplete
3. Parser has bugs
4. Performance not optimized

**What's proven:**
1. Basic concept works (499 tests pass)
2. Recursion works (factorial works)
3. Higher-order functions work
4. LRVM operations work

**Bottom line**: The theory is sound. The Python implementation proves it's feasible. A clean rewrite can make this real.

---

**Last Updated**: 2025-11-19
**Status**: Theoretical foundation documented for future rewrite
**Next**: Implement loop transformation and convergence detection properly
