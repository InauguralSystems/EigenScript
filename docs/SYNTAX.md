# EigenScript v0.5.0 Syntax Guide

## Variables and Assignment

Assignment uses `is`. It is **outward-mutable**: if a variable exists in a
parent scope, assignment updates that binding. If not found, it creates a
new local.

```eigenscript
x is 42
name is "hello"
data is [1, 2, 3, 4, 5]
```

## Functions

Functions are defined with `define ... as:`. The argument is always called `n`.

**Single argument** — `n` is the value:
```eigenscript
define square as:
    return n * n

result is square of 5    # 25
```

**Multiple arguments** — pass a list, unpack with `n[0]`, `n[1]`:
```eigenscript
define add_three as:
    a is n[0]
    b is n[1]
    c is n[2]
    return a + b + c

result is add_three of [10, 20, 30]    # 60
```

**No arguments** — pass `null`:
```eigenscript
define greet as:
    print of "Hello!"

greet of null
```

**Convention:** Single-value functions use `n` directly. Multi-argument
functions pass a list and unpack with `n[0]`, `n[1]`, etc.

## Conditionals

```eigenscript
if x > 0:
    print of "positive"
elif x == 0:
    print of "zero"
else:
    print of "negative"
```

## Loops

**While loop:**
```eigenscript
loop while counter < limit:
    counter is counter + 1
```

**For loop** — iterates over a list:
```eigenscript
for i in range of 10:
    print of i

for item in items:
    print of item
```

## Operators

**Arithmetic:** `+`, `-`, `*`, `/`, `%`
**Comparison:** `==`, `!=`, `<`, `>`, `<=`, `>=`
**Logical:** `and`, `or`, `not`
**String:** `+` (concatenation when either side is a string)

## Lists

```eigenscript
items is [1, 2, 3, 4, 5]
print of items[0]         # 1
print of (len of items)   # 5
append of [items, 6]      # mutates items
```

Note: list literals must be on a single line.

## Modules (load_file)

```eigenscript
load_file of "lib/math.eigs"
print of (abs of -5)
```

The loaded file's definitions are added to the global environment.

## Observer Semantics

Every value tracks its own change history (entropy, dH):

```eigenscript
x is 10.0
x is 8.0
x is 6.0

status is report of x     # "improving"
state is observe of x     # [status, entropy, dH, prev_dH]
```

The runtime classifies trajectories as: `improving`, `diverging`,
`stable`, `equilibrium`, `oscillating`, or `converged`.

**Predicates** — boolean keywords for use in conditions:
```eigenscript
loop while not converged:
    x is x * 0.9
    if stable:
        print of "reached stable band"
```

## Standard Library

Libraries live in `lib/` and are loaded with `load_file`:

| Module | Functions |
|--------|-----------|
| `lib/math.eigs` | `abs`, `max_val`, `min_val`, `clamp`, `lerp`, `dot` |
| `lib/list.eigs` | `map`, `filter`, `reduce`, `reverse`, `zip`, `flatten` |
| `lib/string.eigs` | `join`, `repeat`, `pad_left` |
| `lib/sanitize.eigs` | `sanitize_text`, `is_garble`, `clean_response` |
| `lib/auth.eigs` | `auth_login`, `auth_check`, `auth_logout` |

See [BUILTINS.md](BUILTINS.md) for the complete builtin reference.

## Limitations

**Single-line arrays only:**
```eigenscript
# Arrays must be on one line
data is [1, 2, 3, 4]
```

**Single-parameter functions:**
Functions take exactly one argument (`n`). Pass multiple values as a list.

**No break/continue:**
Use flag variables to exit loops early.

**No try/catch:**
Errors print to stderr but execution continues (except parse errors, which abort).
