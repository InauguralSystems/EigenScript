# Predicates

Semantic state checking in EigenScript. These predicates let your code check its own computational state.

---

## converged

Check if computation has converged to a stable state.

**Syntax:**
```eigenscript
if converged:
    # Handle convergence
```

**Returns:** `true` if converged, `false` otherwise

**Example:**
```eigenscript
define iterative_sqrt as:
    guess is n / 2
    
    loop while not converged:
        guess is (guess + n / guess) / 2
    
    return guess

result is iterative_sqrt of 16
# Automatically stops when converged!
```

**Semantics:** Measures if framework strength has stabilized.

---

## stable

Check if computation is in a stable state.

**Syntax:**
```eigenscript
if stable:
    # State is stable
```

**Returns:** `true` if stable, `false` otherwise

**Example:**
```eigenscript
define newton_method as:
    x is initial_guess
    
    loop while not stable:
        x is x - (f of x) / (df of x)
    
    return x

root is newton_method of equation
```

**Semantics:** Checks if small perturbations won't cause large changes.

---

## improving

Check if computation is making progress.

**Syntax:**
```eigenscript
if improving:
    # Making progress
else:
    # Stuck or regressing
```

**Returns:** `true` if improving, `false` otherwise

**Example:**
```eigenscript
define optimization as:
    best is initial
    
    loop while improving:
        candidate is generate_next of best
        if (score of candidate) > (score of best):
            best is candidate
    
    return best

result is optimization of problem
```

**Semantics:** Measures positive trajectory in semantic spacetime.

---

## diverging

Check if computation is diverging (moving away from solution).

**Syntax:**
```eigenscript
if diverging:
    # Handle divergence
```

**Returns:** `true` if diverging, `false` otherwise

**Example:**
```eigenscript
define safe_iteration as:
    x is start
    
    loop while not converged:
        if diverging:
            print of "Warning: Diverging!"
            return null
        
        x is iterate of x
    
    return x

result is safe_iteration of initial_value
```

**Semantics:** Detects negative trajectory or instability.

---

## oscillating

Check if computation is oscillating between states.

**Syntax:**
```eigenscript
if oscillating:
    # Handle oscillation
```

**Returns:** `true` if oscillating, `false` otherwise

**Example:**
```eigenscript
define damped_iteration as:
    x is start
    
    loop while not converged:
        if oscillating:
            # Reduce step size
            damping_factor is 0.5
            x is x * damping_factor
        
        x is iterate of x
    
    return x

result is damped_iteration of value
```

**Semantics:** Detects periodic behavior in computation.

---

## equilibrium

Check if computation is at an equilibrium point.

**Syntax:**
```eigenscript
if equilibrium:
    # At equilibrium
```

**Returns:** `true` if at equilibrium, `false` otherwise

**Example:**
```eigenscript
define find_equilibrium as:
    state is initial
    
    loop while not equilibrium:
        state is update of state
    
    print of "Equilibrium reached!"
    return state

final is find_equilibrium of system
```

**Semantics:** Balance point in semantic spacetime (no net flow).

---

## Complete Examples

### Adaptive Convergence

```eigenscript
define adaptive_solve as:
    x is initial_guess
    step is 1.0
    
    loop while not converged:
        if improving:
            # Increase step when improving
            step is step * 1.1
        
        if diverging:
            # Decrease step when diverging
            step is step * 0.5
        
        if oscillating:
            # Dampen when oscillating
            step is step * 0.7
        
        x is x + step * (gradient of x)
    
    return x

solution is adaptive_solve of problem
```

### Smart Termination

```eigenscript
define smart_iteration as:
    result is start
    max_iterations is 1000
    count is 0
    
    loop while count < max_iterations:
        if converged:
            print of "Converged successfully!"
            return result
        
        if stable:
            print of "Reached stable state"
            return result
        
        if equilibrium:
            print of "Found equilibrium"
            return result
        
        if diverging:
            print of "Error: Diverging!"
            return null
        
        result is iterate of result
        count is count + 1
    
    print of "Max iterations reached"
    return result

answer is smart_iteration of data
```

### Progress Monitor

```eigenscript
define monitored_computation as:
    x is start
    
    loop while not converged:
        if improving:
            print of "Progress: improving"
        
        if oscillating:
            print of "Warning: oscillating"
        
        if not stable:
            print of "State: unstable"
        
        x is compute_next of x
    
    print of "Final: converged!"
    return x

result is monitored_computation of initial
```

### Fibonacci with Auto-Stop

```eigenscript
define smart_fibonacci as:
    if n is 0:
        return 0
    if n is 1:
        return 1
    
    # Compute recursively
    f1 is smart_fibonacci of (n - 1)
    f2 is smart_fibonacci of (n - 2)
    result is f1 + f2
    
    # Check convergence at each level
    if converged:
        print of "Computation converged at n="
        print of n
    
    return result

fib is smart_fibonacci of 10
```

### Multi-State Detector

```eigenscript
define analyze_computation as:
    print of "=== Computation State ==="
    
    if converged:
        print of "Status: CONVERGED"
    
    if stable:
        print of "Stability: STABLE"
    
    if improving:
        print of "Trend: IMPROVING"
    
    if diverging:
        print of "Trend: DIVERGING"
    
    if oscillating:
        print of "Pattern: OSCILLATING"
    
    if equilibrium:
        print of "State: EQUILIBRIUM"
    
    print of "====================="

analyze_computation of 0
```

---

## Geometric Interpretation

Predicates measure geometric properties of semantic spacetime:

| Predicate | Geometric Property |
|-----------|-------------------|
| `converged` | Framework strength → 1 |
| `stable` | Small curvature |
| `improving` | Positive trajectory |
| `diverging` | Negative trajectory |
| `oscillating` | Periodic geodesic |
| `equilibrium` | Zero flow |

---

## Combining Predicates

```eigenscript
# Multiple conditions
if converged and stable:
    print of "Safe to stop"

# Complex logic
if improving or (stable and not diverging):
    # Continue iteration
    continue_process of data

# Nested checks
if not converged:
    if diverging:
        # Emergency handling
        abort_computation of 0
```

---

## Use Cases

### Iterative Algorithms

```eigenscript
# Gradient descent
loop while not converged:
    gradient is compute_gradient of x
    x is x - learning_rate * gradient
```

### Numerical Methods

```eigenscript
# Newton-Raphson
loop while not converged:
    x is x - (f of x) / (df of x)
```

### Fixed-Point Iteration

```eigenscript
# Find x = g(x)
loop while not equilibrium:
    x is g of x
```

### Optimization

```eigenscript
# Maximize objective
loop while improving:
    candidate is generate_next of current
    current is select_best of [current, candidate]
```

---

## Performance

- Predicates are computed lazily
- Zero overhead when not used
- Based on geometric measurements
- Automatically updated each iteration

---

## Notes

- Predicates are **boolean expressions**
- Can be used in any boolean context
- Updated automatically by the runtime
- Based on framework strength and trajectory
- No manual convergence checking needed!

---

## Summary

Semantic predicates:

- `converged` - Reached stable solution
- `stable` - Small perturbations safe
- `improving` - Making progress
- `diverging` - Moving away from solution
- `oscillating` - Periodic behavior
- `equilibrium` - At balance point

**Total: 6 predicates**

These enable automatic convergence detection and adaptive algorithms.

---

**Congratulations!** You've explored the complete EigenScript API.

**Return to:** [API Index](index.md)
