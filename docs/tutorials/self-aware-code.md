# Tutorial 5: Self-Aware Code

**⏱️ Time: 60 minutes** | **Difficulty: Advanced**

Unlock EigenScript's unique self-awareness features.

## Topics Covered

- Interrogatives (WHO, WHAT, WHEN, etc.)
- Predicates (converged, stable, etc.)
- Geometric semantics
- Adaptive algorithms

## Interrogatives

```eigenscript
define traced_function as:
    func is WHO
    value is WHAT
    time is WHEN
    
    print of "Function: "
    print of func
    print of "Value: "
    print of value
    print of "Time: "
    print of time
    
    return n * 2

result is traced_function of 42
```

## Predicates

```eigenscript
define adaptive_iteration as:
    x is initial
    
    loop while not converged:
        if improving:
            print of "Making progress!"
        
        if oscillating:
            print of "Oscillating - damping"
        
        x is iterate of x
    
    print of "Converged!"
    return x
```

## Complete Example

```eigenscript
define smart_solver as:
    x is guess
    
    loop while not converged:
        # Check state
        if diverging:
            print of "Error: diverging!"
            return null
        
        if stable:
            print of "Stable state reached"
            return x
        
        # Adapt strategy
        if improving:
            step is 1.1  # Accelerate
        else:
            step is 0.9  # Slow down
        
        # Iterate
        x is x + step * (gradient of x)
    
    print of "Solution found!"
    return x
```

## Key Features

✅ WHO - Current function name
✅ WHAT - Current value
✅ WHEN - Timestamp
✅ converged - Has converged?
✅ stable - Is stable?
✅ improving - Making progress?

**Congratulations!** You've completed the tutorial series!

**Explore more:**
- [Examples](../examples/index.md)
- [API Reference](../api/index.md)
- [Mathematical Foundations](../mathematical_foundations.md)
