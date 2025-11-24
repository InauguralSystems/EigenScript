# Meta-Circular Evaluator Quick Start Guide

**Goal**: Implement an EigenScript interpreter in EigenScript

**Time**: 2-3 weeks

**Prerequisites**: All met ✅ (functions, lists, recursion all work)

---

## Step 1: Design AST Format (Day 1)

### Decision: List-Based AST

Represent AST nodes as lists with type tags:

```eigenscript
# Literals
["literal", 42]
["literal", "hello"]

# Variables
["var", "x"]

# Binary operations
["binop", "+", left_node, right_node]
["binop", "*", ["var", "x"], ["literal", 2]]

# Assignments
["assign", "x", expr_node]
["assign", "y", ["binop", "+", ["var", "x"], ["literal", 1]]]

# If statements
["if", condition, then_branch, else_branch]

# Function definitions
["define", "factorial", ["n"], body_nodes]

# Function calls
["call", func_expr, arg_expr]

# Return statements
["return", expr_node]
```

### Test Examples

Create test data structures:

```eigenscript
# Test 1: x is 5
test1 is ["assign", "x", ["literal", 5]]

# Test 2: x + y
test2 is ["binop", "+", ["var", "x"], ["var", "y"]]

# Test 3: Full program
test_prog is [
    ["assign", "x", ["literal", 5]],
    ["assign", "y", ["literal", 3]],
    ["binop", "+", ["var", "x"], ["var", "y"]]
]
```

---

## Step 2: Helper Functions (Days 2-3)

### List Operations

```eigenscript
# Get first element
define first as:
    return list[0]

# Get second element  
define second as:
    return list[1]

# Get third element
define third as:
    return list[2]

# Get all but first
define rest as:
    # Create new list without first element
    result is []
    i is 1
    loop while i < (len of list):
        result is append of [result, list[i]]
        i is i + 1
    return result

# Check if list is empty
define is_empty as:
    return (len of list) is 0
```

### Environment Operations

Environment = list of [name, value] pairs

```eigenscript
# Create empty environment
define empty_env as:
    return []

# Look up variable in environment
define env_lookup as:
    # env is [["x", 5], ["y", 10], ...]
    # name is "x"
    loop while not (is_empty of env):
        pair is first of env
        pair_name is first of pair
        if pair_name is name:
            return second of pair  # Found it!
        env is rest of env
    return null  # Not found

# Add binding to environment
define env_extend as:
    # env is [["x", 5]]
    # name is "y"
    # value is 10
    # Returns: [["y", 10], ["x", 5]]
    new_pair is [name, value]
    return prepend of [new_pair, env]

# Alternative: use built-in list operations
define env_extend as:
    new_env is []
    new_env is append of [new_env, [name, value]]
    # Add all existing bindings
    loop while not (is_empty of env):
        pair is first of env
        new_env is append of [new_env, pair]
        env is rest of env
    return new_env
```

### Node Type Checking

```eigenscript
# Get node type (first element of list)
define node_type as:
    return first of node

# Type predicates
define is_literal as:
    return (node_type of node) is "literal"

define is_var as:
    return (node_type of node) is "var"

define is_binop as:
    return (node_type of node) is "binop"

# ... etc for each node type
```

---

## Step 3: Basic Evaluator (Days 4-6)

### Core Eval Function

```eigenscript
define eval as:
    # Takes: node (AST node), env (environment)
    # Returns: evaluated value
    
    type is node_type of node
    
    # Case 1: Literal
    if type is "literal":
        value is second of node
        return value
    
    # Case 2: Variable
    if type is "var":
        name is second of node
        return env_lookup of [name, env]
    
    # Case 3: Binary operation
    if type is "binop":
        op is second of node
        left_node is third of node
        right_node is fourth of node
        
        left_val is eval of [left_node, env]
        right_val is eval of [right_node, env]
        
        return apply_op of [op, left_val, right_val]
    
    # Case 4: Assignment
    if type is "assign":
        name is second of node
        expr_node is third of node
        
        value is eval of [expr_node, env]
        # Note: In real implementation, would update environment
        # For now, just return value
        return value
    
    # Default
    return null

# Apply binary operator
define apply_op as:
    op is first of args
    left is second of args
    right is third of args
    
    if op is "+":
        return left + right
    if op is "-":
        return left - right
    if op is "*":
        return left * right
    if op is "/":
        return left / right
    if op is "=":
        return left is right
    if op is "<":
        return left < right
    if op is ">":
        return left > right
    
    return null
```

### Test It

```eigenscript
# Test 1: Evaluate literal
env is empty_env of null
test is ["literal", 42]
result is eval of [test, env]
print of result  # Should print: 42

# Test 2: Evaluate variable
env is [["x", 10]]
test is ["var", "x"]
result is eval of [test, env]
print of result  # Should print: 10

# Test 3: Evaluate binary op
env is empty_env of null
test is ["binop", "+", ["literal", 2], ["literal", 3]]
result is eval of [test, env]
print of result  # Should print: 5

# Test 4: Complex expression
env is [["x", 5], ["y", 3]]
test is ["binop", "*", ["var", "x"], ["binop", "+", ["var", "y"], ["literal", 2]]]
result is eval of [test, env]
print of result  # Should print: 25 (5 * (3 + 2))
```

---

## Step 4: Add Control Flow (Days 7-9)

### If Statements

```eigenscript
# In the eval function, add:
if type is "if":
    cond_node is second of node
    then_node is third of node
    else_node is fourth of node
    
    cond_val is eval of [cond_node, env]
    
    # If condition is non-zero/truthy
    if cond_val:
        return eval of [then_node, env]
    else:
        return eval of [else_node, env]
```

### Loops

```eigenscript
# In the eval function, add:
if type is "loop":
    cond_node is second of node
    body_nodes is third of node
    
    loop while eval of [cond_node, env]:
        # Evaluate each statement in body
        i is 0
        loop while i < (len of body_nodes):
            stmt is body_nodes[i]
            eval of [stmt, env]
            i is i + 1
    
    return null
```

### Functions

```eigenscript
# In the eval function, add:

# Function definition
if type is "define":
    name is second of node
    params is third of node
    body is fourth of node
    
    # Store function in environment
    func_obj is ["function", params, body, env]  # Closure
    # Update environment with function binding
    # (Implementation detail depends on environment handling)
    return func_obj

# Function call
if type is "call":
    func_node is second of node
    arg_node is third of node
    
    func_obj is eval of [func_node, env]
    arg_val is eval of [arg_node, env]
    
    # Extract function components
    params is second of func_obj
    body is third of func_obj
    closure is fourth of func_obj
    
    # Create new environment with parameter binding
    param_name is first of params  # Assuming single parameter
    new_env is env_extend of [closure, param_name, arg_val]
    
    # Evaluate function body
    result is null
    i is 0
    loop while i < (len of body):
        stmt is body[i]
        result is eval of [stmt, new_env]
        i is i + 1
    
    return result
```

---

## Step 5: Self-Evaluation Test (Days 10-12)

### The Ultimate Test

```eigenscript
# Create a simple test program
test_prog is [
    ["assign", "x", ["literal", 5]],
    ["assign", "y", ["literal", 3]],
    ["binop", "+", ["var", "x"], ["var", "y"]]
]

# Evaluate it normally
env is empty_env of null
result is eval of [test_prog, env]
print of "Normal evaluation result:"
print of result  # Should be 8

# Now, represent the evaluator itself as an AST
# (This would be created by Python by parsing meta_eval.eigs)
eval_ast is parse of "meta_eval.eigs"

# Meta-evaluation: eval evaluates eval evaluating test_prog
print of "Meta-evaluation starting..."
meta_result is eval of [eval_ast, test_prog]

print of "Meta-evaluation result:"
print of meta_result  # Should also be 8

# Check convergence
if converged:
    print of "Success! Self-reference is stable."

if stable:
    print of "Framework Strength indicates convergence."

print of "Framework Strength:"
print of fs  # Should be ≥ 0.95
```

### Success Criteria

- ✅ No infinite loops or crashes
- ✅ Meta-evaluation produces correct result
- ✅ Framework Strength ≥ 0.95
- ✅ `converged` predicate evaluates to true
- ✅ Result is stable across multiple runs

---

## Step 6: Documentation (Day 13)

### Update Files

1. **examples/meta_eval.eigs**: Add comprehensive comments
2. **examples/README.md**: Explain what meta_eval does
3. **README.md**: Mark "Month 4: Self-Hosting" as complete
4. **docs/roadmap.md**: Update Phase 4 to 100% complete
5. **Create docs/meta_circular_evaluator.md**: Tutorial

### Example Documentation

```markdown
# Meta-Circular Evaluator

The meta-circular evaluator (`examples/meta_eval.eigs`) is an EigenScript 
interpreter written in EigenScript itself.

## What It Does

It can evaluate EigenScript programs, including:
- Literals and variables
- Arithmetic operations
- Assignments
- Functions and recursion
- Control flow (if/else, loops)

## The Key Test

The evaluator can evaluate **itself**:

```eigenscript
eval of eval  # Self-reference is stable!
```

This demonstrates that self-reference converges to an eigenstate 
(Framework Strength → 1.0) instead of diverging.

## Why This Matters

1. Proves language completeness
2. Validates geometric stability hypothesis  
3. Shows LRVM space handles meta-level reasoning
4. Fulfills Month 4 roadmap milestone
```

---

## Common Issues & Solutions

### Issue 1: List Operations Don't Work

**Problem**: `first`, `rest`, etc. not defined

**Solution**: Implement them using existing list indexing:
```eigenscript
define first as:
    return list[0]
```

### Issue 2: Environment Lookup Fails

**Problem**: Can't find variables

**Solution**: Debug with print statements:
```eigenscript
define env_lookup as:
    print of "Looking for:"
    print of name
    print of "In environment:"
    print of env
    # ... rest of function
```

### Issue 3: Recursion Depth Exceeded

**Problem**: Too many nested calls

**Solution**: 
1. Check for base cases in recursive functions
2. Verify convergence detection is working
3. May need to increase max recursion depth

### Issue 4: Self-Evaluation Crashes

**Problem**: Stack overflow or infinite loop

**Solution**:
1. Test each component separately first
2. Add convergence checks
3. Start with simpler self-reference before full eval-of-eval

---

## Testing Strategy

### Phase 1: Unit Tests

Test each component:
```eigenscript
# Test literals
assert (eval of [["literal", 42], []]) is 42

# Test variables  
assert (eval of [["var", "x"], [["x", 10]]]) is 10

# Test binops
assert (eval of [["binop", "+", ["literal", 2], ["literal", 3]], []]) is 5
```

### Phase 2: Integration Tests

Test complete programs:
```eigenscript
# Test factorial
factorial_prog is [...define factorial...]
result is eval of factorial_prog
assert result is 120
```

### Phase 3: Self-Evaluation

The ultimate test:
```eigenscript
eval_ast is parse of "meta_eval.eigs"
result is eval of [eval_ast, simple_prog]
assert converged
assert fs >= 0.95
```

---

## Quick Reference: Node Types

| Type | Format | Example |
|------|--------|---------|
| Literal | `["literal", value]` | `["literal", 42]` |
| Variable | `["var", name]` | `["var", "x"]` |
| Binary Op | `["binop", op, left, right]` | `["binop", "+", l, r]` |
| Assignment | `["assign", name, expr]` | `["assign", "x", expr]` |
| If | `["if", cond, then, else]` | `["if", c, t, e]` |
| Loop | `["loop", cond, body]` | `["loop", c, [stmts]]` |
| Define | `["define", name, params, body]` | `["define", "f", ["x"], b]` |
| Call | `["call", func, arg]` | `["call", f, a]` |
| Return | `["return", expr]` | `["return", expr]` |

---

## Success Checklist

- [ ] AST format defined and documented
- [ ] Helper functions implemented (list ops, env ops)
- [ ] Basic evaluator handles literals, vars, binops
- [ ] Assignments work
- [ ] Control flow works (if/else, loops)
- [ ] Functions and calls work
- [ ] Recursion works
- [ ] Self-evaluation test passes
- [ ] Framework Strength ≥ 0.95 during self-eval
- [ ] No crashes or infinite loops
- [ ] Tests written and passing
- [ ] Documentation complete

---

## Timeline Estimate

- Day 1: Design AST format ✅
- Days 2-3: Helper functions ✅
- Days 4-6: Basic evaluator ✅
- Days 7-9: Control flow & functions ✅
- Days 10-12: Self-evaluation test ✅
- Day 13: Documentation ✅

**Total**: ~2 weeks of focused work

---

## Next Steps

1. Start with `examples/meta_eval.eigs`
2. Implement helper functions first
3. Build evaluator incrementally
4. Test each piece before moving on
5. Final test: self-evaluation!

**Ready to start coding? Let's build it!** 🚀

---

## Getting Help

If stuck:
1. Check `SELF_HOSTING_PLAN.md` for detailed theory
2. Review `docs/self_hosting_roadmap.md` for weekly breakdown
3. Look at `src/eigenscript/evaluator/interpreter.py` for Python reference
4. Run existing tests to see what's already working
5. Add print statements to debug

Remember: **All the prerequisites are in place. It's just a matter of writing the code!**
