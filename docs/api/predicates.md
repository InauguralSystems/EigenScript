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

---

# Communication Clarity Predicates

The Communication Clarity Framework extends EigenScript with predicates that check the *clarity of intent*, not just computational state. These predicates implement hypothesis-driven communication semantics where code debugs itself by refusing to execute on unverified assumptions.

---

## clarified

Check if all bindings have verified intent.

**Syntax:**
```eigenscript
if clarified:
    # All intents verified, safe to proceed
```

**Returns:** `true` if clarity score meets threshold, `false` otherwise

**Example:**
```eigenscript
config might is "production"  # Tentative: hypothesis
database might is "postgres"  # Tentative: hypothesis

# Won't proceed until intent is clarified
if not clarified:
    print of "Please clarify intent before proceeding"
    clarify of config
    clarify of database

if clarified:
    # Safe to execute critical operations
    initialize_system of config
```

**Semantics:** Measures the ratio of clarified bindings to total bindings. Returns true when clarity score >= threshold (default 0.95).

---

## ambiguous

Check if there are any unresolved bindings.

**Syntax:**
```eigenscript
if ambiguous:
    # Some bindings need clarification
```

**Returns:** `true` if any bindings are tentative/unresolved, `false` otherwise

**Example:**
```eigenscript
user_input might is value

if ambiguous:
    print of "Warning: ambiguous state detected"
    # Force disambiguation
    clarify of user_input
```

**Semantics:** Returns true if any bindings have not been clarified.

---

## explicit

Check if all intents are fully explicit (opposite of ambiguous).

**Syntax:**
```eigenscript
if explicit:
    # All intents are explicit
```

**Returns:** `true` if clarity score is 100%, `false` otherwise

**Example:**
```eigenscript
x is 10      # Clarified (normal assignment)
y is 20      # Clarified (normal assignment)

if explicit:
    print of "All intents are explicit"
```

**Semantics:** Returns true only when clarity score is exactly 1.0.

---

## clarity / cs

Get the current clarity score as a numeric value.

**Syntax:**
```eigenscript
score is clarity
# or
score is cs
```

**Returns:** Float between 0.0 (fully ambiguous) and 1.0 (fully clarified)

**Example:**
```eigenscript
a might is 1  # Tentative
b is 2        # Clarified
c might is 3  # Tentative

score is clarity
print of score  # Prints 0.333... (1/3 clarified)

clarify of a
clarify of c
print of clarity  # Prints 1.0 (all clarified)
```

**Semantics:** Computes ratio of clarified bindings to total bindings.

---

## assumed

Check if there are any unverified assumptions (hidden variables).

**Syntax:**
```eigenscript
if assumed:
    # Hidden variables detected
```

**Returns:** `true` if any assumptions exist, `false` otherwise

**Example:**
```eigenscript
# The clarity tracker can detect implicit assumptions
if assumed:
    print of "Warning: hidden variables detected"
```

**Semantics:** Returns true if any assumptions have been registered.

---

# Clarity Operators

## might is

Create a tentative (hypothesis) binding.

**Syntax:**
```eigenscript
identifier might is expression
```

**Example:**
```eigenscript
mode might is "strict"     # Hypothesis: we want strict mode
count might is 0           # Hypothesis: count starts at zero

# The bindings exist but are marked as tentative
print of mode              # Prints "strict"
print of clarified         # Prints 0.0 (not clarified)
```

**Semantics:** Creates a binding marked as TENTATIVE. The `clarified` predicate returns false until all tentative bindings are clarified.

---

## clarify of

Clarify a tentative binding, changing it from TENTATIVE to CLARIFIED.

**Syntax:**
```eigenscript
clarify of identifier
```

**Returns:** `1.0` on success, `0.0` on failure

**Example:**
```eigenscript
mode might is "strict"
print of clarified         # Prints 0.0

clarify of mode
print of clarified         # Prints 1.0
```

**Semantics:** Marks the binding as clarified in the clarity tracker.

---

## assumes is

Query hidden variables/assumptions for a binding.

**Syntax:**
```eigenscript
assumptions is assumes is identifier
```

**Returns:** String listing assumptions, or empty string if none

**Example:**
```eigenscript
x is 10
assumptions is assumes is x
print of assumptions       # Prints "" (no assumptions)
```

**Semantics:** Returns any assumptions detected for the binding.

---

# Complete Examples

### Self-Debugging Configuration

```eigenscript
# Configuration with hypothesis-driven clarity
db_host might is "localhost"
db_port might is 5432
db_name might is "production"

# The program refuses to proceed until intent is clear
if not clarified:
    print of "Configuration requires clarification:"
    print of clarity

# Explicit verification of each hypothesis
clarify of db_host
clarify of db_port
clarify of db_name

if clarified:
    print of "Configuration verified. Proceeding..."
    connect_database of db_host
```

### Clarity-Driven Loop

```eigenscript
define safe_process as:
    config might is input

    # Loop until all ambiguity resolved
    loop while not clarified:
        print of "Please confirm configuration"
        clarify of config

    # Now safe to proceed
    return execute of config

result is safe_process of user_config
```

### Combining Clarity and Convergence

```eigenscript
# Hybrid predicates: both semantic AND communicative clarity
define robust_algorithm as:
    params might is initial
    x is start

    # Verify intent before heavy computation
    if not clarified:
        clarify of params

    loop while not converged:
        if diverging:
            print of "Warning: diverging"
            break
        x is iterate of x

    return x

result is robust_algorithm of problem
```

### Agency-Preserving Design

```eigenscript
# The framework presents options without deciding for the user
mode might is unknown

# Instead of guessing, the program asks for clarification
if ambiguous:
    print of "Possible modes:"
    print of "1. strict - Full validation"
    print of "2. relaxed - Permissive parsing"
    print of "3. auto - Detect from input"
    print of "Which mode is intended?"

    # User must clarify before proceeding
    mode is input of "Enter mode: "
    clarify of mode

if clarified:
    process_with_mode of mode
```

---

## Geometric Interpretation

Clarity predicates measure communication properties:

| Predicate | Communication Property |
|-----------|----------------------|
| `clarified` | All intents verified |
| `ambiguous` | Hidden variables exist |
| `explicit` | 100% clarity score |
| `clarity`/`cs` | Ratio of clarified bindings |
| `assumed` | Unverified assumptions present |

The `might is` operator creates a hypothesis binding (lightlike).
The `clarify of` operator transforms it to clarified (timelike).

---

## The Framework Principles

The clarity predicates implement these principles:

1. **Questions and statements both assign objectives** - Creating a binding assigns intent-verification work
2. **Implication is not universal** - `might is` makes hidden variables visible
3. **Clarification is hypothesis testing** - Bindings start as hypotheses, become facts
4. **Withhold inference intentionally** - Don't collapse ambiguity silently
5. **Control remains with the speaker** - Present options, don't decide for user
6. **Speakers discover their own intent** - `might is` forces intent externalization

---

## Summary

Semantic predicates:

- `converged` - Reached stable solution
- `stable` - Small perturbations safe
- `improving` - Making progress
- `diverging` - Moving away from solution
- `oscillating` - Periodic behavior
- `equilibrium` - At balance point

Communication clarity predicates:

- `clarified` - All intents verified
- `ambiguous` - Unresolved bindings exist
- `explicit` - 100% clarity
- `clarity`/`cs` - Clarity score (0.0-1.0)
- `assumed` - Hidden variables detected

Clarity operators:

- `might is` - Tentative (hypothesis) binding
- `clarify of` - Verify intent
- `assumes is` - Query hidden variables

**Total: 11 predicates + 3 operators**

These enable self-debugging code that refuses to execute on unverified assumptions.

---

**Congratulations!** You've explored the complete EigenScript API.

**Return to:** [API Index](index.md)
