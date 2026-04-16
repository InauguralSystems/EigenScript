# EigenScript v0.6.0 Syntax Guide

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

### Named Parameters (recommended)

Define functions with named parameters in parentheses:

```eigenscript
define add(a, b) as:
    return a + b

result is add of [3, 4]    # 7
```

```eigenscript
define greet(name, age) as:
    return f"Hello {name}, you are {age}"

print of (greet of ["Jon", 30])
```

The argument list is unpacked into the named parameters automatically.
`n` is still available as the raw argument for backward compatibility.

### Classic Style

Functions can also be defined without named parameters. The argument is `n`:

```eigenscript
define square as:
    return n * n

result is square of 5    # 25
```

For multiple arguments in classic style, pass a list and unpack manually:
```eigenscript
define add_three as:
    return n[0] + n[1] + n[2]

result is add_three of [10, 20, 30]    # 60
```

### No arguments

Pass `null`:
```eigenscript
define greet as:
    print of "Hello!"

greet of null
```

## String Interpolation

Prefix a string with `f` to enable expression interpolation with `{...}`:

```eigenscript
name is "World"
x is 42
print of f"Hello {name}!"
print of f"x = {x}, doubled = {x * 2}"
print of f"list length: {len of items}"
```

Expressions inside `{}` are evaluated and converted to strings. Use `\{` and
`\}` for literal braces.

## Interactive REPL

Run `eigenscript` with no arguments to enter the REPL:

```
$ eigenscript
EigenScript 0.6.0
Type 'exit' or Ctrl-D to quit.

eigs> x is 42
eigs> print of f"x = {x}"
x = 42
eigs> define double(n) as:
...       return n * 2
...
eigs> double of 21
=> 42
```

Multi-line input (functions, loops, conditionals) is detected automatically
when a line ends with `:`. A blank line ends the block.

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

## Error Handling

```eigenscript
try:
    x is items[100]
catch err:
    print of f"Caught: {err}"
```

Errors inside a `try` block are caught and bound to the variable after `catch`.
Without a `try` block, errors print to stderr and return null.

Use `throw` to raise errors from user code:

```eigenscript
define safe_divide(a, b) as:
    if b == 0:
        throw of "division by zero"
    return a / b

try:
    result is safe_divide of [10, 0]
catch err:
    print of f"Error: {err}"
```

Try/catch blocks can be nested. Errors re-thrown in a catch block are caught
by the outer try.

## Closures

Functions capture their defining environment:

```eigenscript
define make_adder(x) as:
    define adder(y) as:
        return x + y
    return adder

add5 is make_adder of 5
print of (add5 of 10)    # 15
```

This works for factory patterns, callbacks, and higher-order programming.

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

## Dictionaries

Dictionary literals use `{}` with string keys:

```eigenscript
config is {"host": "localhost", "port": 8080, "debug": 1}
```

**Dot access:**
```eigenscript
print of config.host       # "localhost"
print of config.port       # 8080
```

**Bracket access:**
```eigenscript
key is "host"
print of config["host"]    # "localhost"
print of config[key]       # "localhost"
```

**Nested dictionaries:**
```eigenscript
app is {"db": {"host": "localhost", "port": 5432}, "name": "myapp"}
print of app.db.host       # "localhost"
```

**Builtins:**
```eigenscript
print of (keys of config)          # ["host", "port", "debug"]
print of (values of config)        # ["localhost", 8080, 1]
print of (has_key of [config, "host"])   # 1
dict_set of [config, "timeout", 30]      # mutates config
dict_remove of [config, "debug"]         # mutates config
```

## eval

The `eval` builtin executes a string as EigenScript code and returns the result:

```eigenscript
result is eval of "1 + 2"          # 3
eval of "print of 42"              # prints 42
code is "x is 10\nprint of x"
eval of code
```

## Modules (load_file)

```eigenscript
load_file of "lib/math.eigs"
print of (abs of -5)
```

The loaded file's definitions are added to the global environment.

## Interrogatives — Ask Your Code

Every value in EigenScript tracks its own observer state. Interrogatives
are the query interface — zero cost when you don't ask:

| Keyword | Returns | Example |
|---------|---------|---------|
| `what is x` | Current value (scalar), or length (list/string) | `what is loss` → `55.0` |
| `who is x` | Variable name as string | `who is loss` → `"loss"` |
| `when is x` | Observation age (number of assignments) | `when is loss` → `4` |
| `where is x` | Entropy (information content) | `where is loss` → `0.832` |
| `why is x` | dH (rate of change, negative = improving) | `why is loss` → `-0.15` |
| `how is x` | Stability score (0 = unstable, 1 = stable) | `how is loss` → `0.95` |

```eigenscript
loss is 100.0
loss is 80.0
loss is 55.0

print of (what is loss)    # 55
print of (why is loss)     # negative — loss is decreasing
print of (how is loss)     # high — change is consistent
print of (when is loss)    # 3 — three assignments
```

Use interrogatives for debugging, convergence detection, or understanding
runtime behavior without writing logging code.

## Observer Semantics

The observer system classifies value trajectories automatically:

```eigenscript
status is report of loss   # "improving"
state is observe of loss   # [status, entropy, dH, prev_dH]
```

Six trajectory states: `improving`, `diverging`, `stable`, `equilibrium`,
`oscillating`, `converged`.

**Predicates** — boolean keywords for use in conditions:
```eigenscript
loop while not converged:
    loss is loss * 0.9
    if stable:
        print of "reached stable band"
    if oscillating:
        lr is lr * 0.5   # reduce learning rate
```

The observer tracks every variable. Predicates check the most recently
observed value. `report of x` and `observe of x` let you query any
specific variable.

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

**Single-line collections:**
List and dict literals must be on a single line.

**No break/continue:**
Use flag variables to exit loops early.
