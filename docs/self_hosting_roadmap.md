# EigenScript Self-Hosting Roadmap

**Objective**: Implement a meta-circular evaluator (EigenScript interpreter written in EigenScript)

**Status**: Ready to implement (all prerequisites complete)

**Target Date**: 2-3 weeks from start

---

## Quick Reference

### What is "Self-Hosting"?

**Self-hosting** = Writing an EigenScript interpreter in EigenScript itself (meta-circular evaluator)

```eigenscript
# An EigenScript program that can interpret EigenScript programs
define eval as:
    # Takes: program (as AST)
    # Returns: evaluation result
    ...

# Can even evaluate itself!
eval of eval
```

### Why Do This?

1. **Proves language completeness** - Shows EigenScript has sufficient expressive power
2. **Validates geometric stability** - Self-reference should converge (FS → 1.0) not diverge
3. **Educational value** - Best way to understand a language is to implement it
4. **Fulfills roadmap milestone** - "Month 4: Self-Hosting" from README.md

### Current Status

✅ **ALL Prerequisites Complete**:
- Functions with recursion ✅
- Higher-order functions ✅  
- Data structures (lists) ✅
- Control flow ✅
- Built-in functions ✅
- 282 tests passing ✅

❌ **What's Missing**: The actual meta-circular evaluator code

---

## Implementation Phases

### Phase 1: Minimal Evaluator (Week 1)

**Goal**: Evaluate simple expressions

**Features**:
- ✅ Literals: `42`, `"hello"`
- ✅ Variables: `x`, `y`
- ✅ Binary ops: `x + y`, `a * b`
- ✅ Assignments: `x is 5`

**Deliverable**: `examples/meta_eval_v1.eigs`

**Test**:
```eigenscript
# Test program (as data structure)
program is [
    ["assign", "x", ["literal", 5]],
    ["assign", "y", ["literal", 3]],
    ["binop", "+", ["var", "x"], ["var", "y"]]
]

result is eval of program
# Expected: 8
```

### Phase 2: Functions & Control Flow (Week 2)

**Goal**: Evaluate programs with functions and conditionals

**Features**:
- ✅ Function definitions: `define f as: ...`
- ✅ Function calls: `f of x`
- ✅ Conditionals: `if x: ... else: ...`
- ✅ Loops: `loop while x: ...`

**Deliverable**: `examples/meta_eval_v2.eigs`

**Test**:
```eigenscript
# Factorial program as data
factorial_prog is [
    ["define", "factorial", ["n"], [
        ["if", ["binop", "=", ["var", "n"], ["literal", 0]],
            ["return", ["literal", 1]],
            ["return", ["binop", "*", 
                ["var", "n"], 
                ["call", "factorial", ["binop", "-", ["var", "n"], ["literal", 1]]]
            ]]
        ]
    ]],
    ["call", "factorial", ["literal", 5]]
]

result is eval of factorial_prog
# Expected: 120
```

### Phase 3: Self-Evaluation (Week 3)

**Goal**: The evaluator evaluates itself

**Test**:
```eigenscript
# Load the evaluator code as an AST
eval_ast is parse of "meta_eval_v2.eigs"

# Simple test program
test_prog is [["assign", "x", ["literal", 42]]]

# Meta-evaluation: eval evaluates eval evaluating test_prog
result is eval of [eval_ast, test_prog]

# Check stability
if converged:
    print of "Success! Self-reference is stable."
if stable:
    print of "Framework Strength indicates convergence."

print of fs  # Should be ≥ 0.95
```

**Success Criteria**:
- ✅ No infinite loops or crashes
- ✅ Framework Strength ≥ 0.95
- ✅ Result is correct and predictable
- ✅ Convergence detected automatically

---

## Technical Approach

### AST Representation

Represent AST nodes as lists with type tags:

```eigenscript
# Node types
literal_node is ["literal", 42]
variable_node is ["var", "x"]
binop_node is ["binop", "+", left_expr, right_expr]
assign_node is ["assign", "x", expr]
if_node is ["if", condition, then_branch, else_branch]
function_def is ["define", "name", ["param1", "param2"], body]
function_call is ["call", func_expr, arg_expr]
```

### Environment Model

Use lists of name-value pairs:

```eigenscript
# Environment = list of [name, value] pairs
empty_env is []
env_with_x is [["x", 42]]
env_with_xy is [["x", 42], ["y", 10]]

# Lookup: search list for name
define lookup as:
    loop while env:
        pair is first of env
        if (first of pair) is name:
            return second of pair
        env is rest of env
    return null  # Not found
```

### Core Evaluator Structure

```eigenscript
define eval as:
    # Get node type
    type is first of node
    
    # Dispatch on type
    if type is "literal":
        return second of node  # The value
    
    if type is "var":
        name is second of node
        return lookup of [name, env]
    
    if type is "binop":
        op is second of node
        left is third of node
        right is fourth of node
        left_val is eval of [left, env]
        right_val is eval of [right, env]
        return apply_op of [op, left_val, right_val]
    
    if type is "assign":
        name is second of node
        expr is third of node
        value is eval of [expr, env]
        new_env is extend of [env, name, value]
        return value
    
    # ... more cases ...
    
    return null
```

---

## Lightweight vs Full Self-Hosting

### Option A: Lightweight (Recommended for MVP)

**Approach**: 
- Python parses EigenScript → AST
- Convert AST to EigenScript data structures
- EigenScript evaluator processes the AST

**Pros**:
- ✅ Faster to implement
- ✅ Focuses on evaluation semantics (the interesting part)
- ✅ Still proves self-hosting capability
- ✅ Can be done in 2-3 weeks

**Cons**:
- ❌ Relies on Python for parsing (not "pure" self-hosting)

### Option B: Full Self-Hosting (Future)

**Approach**:
- Lexer in EigenScript (tokenize strings)
- Parser in EigenScript (build AST)
- Evaluator in EigenScript

**Pros**:
- ✅ True self-hosting
- ✅ More impressive
- ✅ Complete language implementation

**Cons**:
- ❌ Much more work (6-8 weeks)
- ❌ Needs extensive string manipulation
- ❌ May need additional built-in functions

**Recommendation**: Start with Option A, upgrade to Option B later if desired.

---

## Integration with Existing Code

### How It Fits

```
┌─────────────────────────────────────┐
│  Python Interpreter (Primary)       │
│  - src/eigenscript/                 │
│  - Lexer, Parser, Evaluator         │
│  - Production use                   │
└─────────────────────────────────────┘
              │
              │ parses
              ▼
┌─────────────────────────────────────┐
│  Meta-Circular Evaluator            │
│  - examples/meta_eval.eigs          │
│  - Written in EigenScript           │
│  - Educational & validation         │
└─────────────────────────────────────┘
              │
              │ evaluates
              ▼
┌─────────────────────────────────────┐
│  EigenScript Programs               │
│  - User code                        │
└─────────────────────────────────────┘
```

### Usage Example

```bash
# Normal execution (Python interpreter)
$ python -m eigenscript examples/factorial.eigs
120

# Meta-circular evaluation (testing)
$ python -m eigenscript examples/test_meta_eval.eigs
Running meta-circular evaluator...
Evaluating factorial...
Result: 120
Framework Strength: 0.987
Convergence: True
Self-reference is stable!
```

---

## Required Built-in Functions

For Option A (Lightweight), we need:

### List Operations
- ✅ `first` - Get first element of list (may need to verify)
- ✅ `rest` - Get all but first element (may need to implement)
- ✅ `append` - Add element to list
- ✅ `length` - Get list length
- ✅ Access by index: `list[0]`

### Node Construction
- ✅ Create lists: `[a, b, c]`
- ✅ Pattern matching with IF

### Environment Operations
- ✅ Can use list operations
- No special built-ins needed

### Utility Functions
- ✅ `type_of` - Get type of value (may need to add)
- ✅ `print` - For debugging

Most of these already exist. May need to add:
- `rest` function (if not present)
- `type_of` function (if not present)

---

## Testing Strategy

### Unit Tests

Test each evaluator component:

```eigenscript
# Test: Evaluate literal
test_literal is eval of [["literal", 42], []]
# Expected: 42

# Test: Evaluate variable
env is [["x", 10]]
test_var is eval of [["var", "x"], env]
# Expected: 10

# Test: Evaluate binary op
test_binop is eval of [
    ["binop", "+", ["literal", 2], ["literal", 3]],
    []
]
# Expected: 5
```

### Integration Tests

Test complete programs:

```eigenscript
# Test: Factorial
factorial_result is eval of factorial_program
assert factorial_result is 120

# Test: Fibonacci
fib_result is eval of fibonacci_program
assert fib_result is 55
```

### Self-Evaluation Test

The ultimate test:

```eigenscript
# The evaluator evaluates itself
eval_ast is load_ast of "meta_eval.eigs"
test_prog is simple_addition_program

result is eval of [eval_ast, test_prog]

# Verify stability
assert converged is true
assert fs >= 0.95
```

---

## Documentation Updates

After completing self-hosting, update:

### README.md
- ✅ Mark "Month 4: Self-Hosting" as complete
- ✅ Add example of meta-circular evaluator usage
- ✅ Highlight geometric stability achievement

### docs/roadmap.md
- ✅ Mark Phase 4 as 100% complete
- ✅ Update status from "⚠️ 40% COMPLETE" to "✅ COMPLETE"
- ✅ Remove "Critical gap: Function execution"

### examples/README.md
- ✅ Add explanation of meta_eval.eigs
- ✅ Show how to run it
- ✅ Explain what it demonstrates

### New Documents
- ✅ `docs/meta_circular_evaluator.md` - Deep dive tutorial
- ✅ `examples/meta_eval_tutorial.eigs` - Commented walkthrough

---

## Success Metrics

### Functional Requirements
- ✅ Can evaluate literals, variables, binary ops
- ✅ Can evaluate assignments
- ✅ Can evaluate function definitions and calls
- ✅ Can evaluate control flow (if/loop)
- ✅ Can evaluate itself without crashing

### Geometric Requirements
- ✅ Framework Strength ≥ 0.95 during self-evaluation
- ✅ Convergence detected (no divergence)
- ✅ Stable eigenstate reached

### Code Quality
- ✅ < 200 lines of EigenScript code
- ✅ Well-commented and readable
- ✅ Comprehensive test coverage
- ✅ Clear documentation

### Performance
- ✅ Evaluate simple programs in < 1 second
- ✅ Handle recursion depth of at least 100
- ✅ No memory leaks or runaway growth

---

## Timeline

| Week | Focus | Deliverables |
|------|-------|--------------|
| **Week 1** | Basic evaluator | Literals, variables, binary ops, assignments |
| **Week 2** | Functions & control | Function defs/calls, if/loop, recursion |
| **Week 3** | Self-evaluation | Meta-evaluation test, convergence proof, docs |

**Buffer**: Add 1 week for unexpected issues

**Total**: 2-3 weeks

---

## Open Questions

### Q1: What AST format should we use?

**Answer**: Start with simple list-based format (shown above). It's:
- Easy to construct from Python
- Easy to pattern match in EigenScript
- Familiar to anyone who knows Lisp

### Q2: Should we implement a full parser in EigenScript?

**Answer**: Not initially (Option A). Focus on the evaluator first. Parsing can come later (Option B) if desired.

### Q3: What about error handling?

**Answer**: Keep it simple initially. Return `null` or special error value for errors. Can enhance later.

### Q4: How do we measure Framework Strength during meta-evaluation?

**Answer**: The Python interpreter already tracks FS. It will automatically measure convergence even when running the meta-circular evaluator.

### Q5: What if self-evaluation doesn't converge?

**Answer**: That's a research finding! It might mean:
- Need to tune convergence thresholds
- Some computations are inherently oscillatory (which is OK)
- The geometric model needs refinement

Either way, we learn something valuable about the system.

---

## Resources

### Existing Code to Reference

- `src/eigenscript/evaluator/interpreter.py` - Python evaluator (reference implementation)
- `examples/factorial.eigs` - Example of recursive function
- `examples/higher_order_functions.eigs` - Example of HOF usage
- `tests/test_turing_completeness.py` - Shows what's already working

### Classical Meta-Circular Evaluators

- McCarthy's original Lisp eval
- SICP Chapter 4 (Scheme meta-circular evaluator)
- The Little LISPer / The Little Schemer

### EigenScript-Specific Concepts

- `docs/geometric_trilogy_analysis.md` - Geometric foundations
- `docs/eigencontrol_algorithm.md` - I = (A-B)² primitive
- `docs/mathematical_foundations.md` - Theoretical basis

---

## Next Actions

1. ✅ **Review this roadmap** - Ensure understanding of approach
2. ⏭️ **Design AST format** - Settle on representation (1 day)
3. ⏭️ **Implement helper functions** - List ops, env ops (2 days)
4. ⏭️ **Write basic evaluator** - Handle literals, vars, binops (3 days)
5. ⏭️ **Test basic evaluator** - Verify correctness (1 day)
6. ⏭️ **Add functions & control** - Complete evaluator (3 days)
7. ⏭️ **Self-evaluation test** - The ultimate test (2 days)
8. ⏭️ **Documentation** - Write it all up (1 day)

**Start Date**: When ready  
**Target Completion**: 2-3 weeks from start  
**Milestone**: Self-hosting achieved, Phase 4 complete

---

## Conclusion

We are **ready to implement self-hosting**. All language features are in place. The task is now straightforward: write the meta-circular evaluator in EigenScript.

This will:
- ✅ Prove language completeness
- ✅ Demonstrate geometric stability of self-reference
- ✅ Fulfill the Month 4 roadmap milestone
- ✅ Provide educational value

**The critical insight**: Self-hosting is not blocked by missing features. It's just a matter of **writing the code**.

Let's build it! 🚀
