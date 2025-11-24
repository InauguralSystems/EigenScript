# Interrogatives

Self-aware execution queries in EigenScript. These keywords let your code ask questions about its own execution.

---

## WHO - Function Identity

Query the current function name.

**Syntax:**
```eigenscript
name is WHO
```

**Returns:** String with current function name

**Example:**
```eigenscript
define example as:
    func_name is WHO
    print of "I am in function: "
    print of func_name  # "example"

example of 0
```

**Use Case:** Self-documentation, debugging, logging.

---

## WHAT - Value Context

Query the current computational value.

**Syntax:**
```eigenscript
value is WHAT
```

**Returns:** Current value being computed

**Example:**
```eigenscript
define compute as:
    result is n * 2
    current is WHAT
    print of "Computing: "
    print of current
    return result

answer is compute of 21  # Prints current computation state
```

**Use Case:** Introspection, debugging recursive functions.

---

## WHEN - Temporal Context

Query the current execution timestamp.

**Syntax:**
```eigenscript
timestamp is WHEN
```

**Returns:** Execution timestamp

**Example:**
```eigenscript
define timed_operation as:
    start is WHEN
    # ... do work ...
    end is WHEN
    elapsed is end - start
    print of "Operation took: "
    print of elapsed
    return result

timed_operation of data
```

**Use Case:** Performance monitoring, timing operations.

---

## WHERE - Spatial Context

Query the current position in the call stack.

**Syntax:**
```eigenscript
location is WHERE
```

**Returns:** Call stack information

**Example:**
```eigenscript
define nested as:
    location is WHERE
    print of "Call stack: "
    print of location
    
    define inner as:
        inner_location is WHERE
        print of "Inner location: "
        print of inner_location
    
    inner of 0

nested of 0
```

**Use Case:** Debugging, understanding call hierarchy.

---

## WHY - Causal Context

Query the reason for the current computation.

**Syntax:**
```eigenscript
reason is WHY
```

**Returns:** Call context information

**Example:**
```eigenscript
define process as:
    cause is WHY
    print of "Called because: "
    print of cause
    return result

process of data
```

**Use Case:** Understanding computation flow, debugging.

---

## HOW - Computational Method

Query how the current computation is being performed.

**Syntax:**
```eigenscript
method is HOW
```

**Returns:** Computation method information

**Example:**
```eigenscript
define compute as:
    approach is HOW
    print of "Computing via: "
    print of approach
    return result

compute of value
```

**Use Case:** Understanding execution strategy, optimization.

---

## Complete Examples

### Self-Documenting Function

```eigenscript
define factorial as:
    # Log entry
    func is WHO
    time is WHEN
    print of "Entering "
    print of func
    print of " at "
    print of time
    
    # Base case
    if n is 0:
        return 1
    
    # Recursive case
    prev is n of -1
    result is n * (factorial of prev)
    return result

answer is factorial of 5
```

### Debug Tracer

```eigenscript
define traced_function as:
    # Collect all context
    who is WHO
    what is WHAT
    when is WHEN
    where is WHERE
    why is WHY
    how is HOW
    
    # Print trace
    print of "=== Function Trace ==="
    print of "WHO: "
    print of who
    print of "WHAT: "
    print of what
    print of "WHEN: "
    print of when
    print of "WHERE: "
    print of where
    print of "WHY: "
    print of why
    print of "HOW: "
    print of how
    
    # Do actual work
    return n * 2

result is traced_function of 42
```

### Performance Monitor

```eigenscript
define monitored_operation as:
    start_time is WHEN
    func_name is WHO
    
    # Do work
    result is expensive_computation of data
    
    end_time is WHEN
    elapsed is end_time - start_time
    
    # Log performance
    print of func_name
    print of " took "
    print of elapsed
    print of " seconds"
    
    return result

answer is monitored_operation of large_dataset
```

### Recursive Depth Tracker

```eigenscript
define recursive_with_depth as:
    location is WHERE
    depth is len of location  # Approximate depth
    
    print of "Recursion depth: "
    print of depth
    
    if n is 0:
        return 1
    
    return n * (recursive_with_depth of (n - 1))

result is recursive_with_depth of 5
```

### Conditional Logging

```eigenscript
define logged_function as:
    # Only log in certain conditions
    value is WHAT
    
    if value > 1000:
        time is WHEN
        func is WHO
        print of "Large value detected in "
        print of func
        print of " at "
        print of time
    
    return value * 2

result is logged_function of 2000
```

---

## Geometric Semantics

Interrogatives provide access to the geometric structure of computation:

- **WHO** - Function identity (timelike)
- **WHAT** - Current value (spacelike)
- **WHEN** - Temporal coordinate
- **WHERE** - Spatial coordinate in call stack
- **WHY** - Causal chain
- **HOW** - Computational trajectory

These form a complete coordinate system in semantic spacetime.

---

## Use Cases

### Debugging

```eigenscript
# Add interrogatives to any function for instant debugging
define mystery_bug as:
    print of "Debug: WHO="
    print of WHO
    print of ", WHAT="
    print of WHAT
    # ... rest of function
```

### Logging

```eigenscript
# Automatic context in log messages
define logged_api_call as:
    func is WHO
    time is WHEN
    log_entry is func + " called at " + time
    # Write to log file
```

### Profiling

```eigenscript
# Measure execution time
define profiled as:
    start is WHEN
    # ... work ...
    end is WHEN
    performance_data is [WHO, end - start]
```

### Self-Aware Algorithms

```eigenscript
# Adapt based on execution context
define adaptive as:
    location is WHERE
    depth is len of location
    
    if depth > 10:
        # Use iterative approach
        return iterative_version of n
    else:
        # Use recursive approach
        return recursive_version of n
```

---

## Notes

- Interrogatives are **keywords**, not functions
- They access runtime metadata automatically
- No parentheses needed (but `WHO of 0` also works)
- Values are computed on demand
- No performance overhead when not used

---

## Summary

Interrogatives provide self-awareness:

- `WHO` - Function name
- `WHAT` - Current value
- `WHEN` - Timestamp
- `WHERE` - Call stack location
- `WHY` - Call context
- `HOW` - Computation method

**Total: 6 interrogatives**

These make EigenScript programs self-aware and introspective.

---

**Next:** [Predicates](predicates.md) →
