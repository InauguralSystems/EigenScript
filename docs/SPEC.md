# EigenScript Language Specification

This is the canonical, executable specification of EigenScript. Every
`eigenscript` code block that is followed by an `output` block is run by
the test suite (`tests/test_doc_examples.py`) and its stdout must match
the output block exactly — the spec cannot drift from the
implementation. Blocks marked `eigenscript skip` show valid syntax that
is deliberately not executed (nondeterministic, interactive, or
environment-dependent).

Companion documents: [SYNTAX.md](SYNTAX.md) (tutorial-style guide),
[GRAMMAR.md](GRAMMAR.md) (formal grammar), [LANGUAGE_CONTRACT.md](LANGUAGE_CONTRACT.md)
(edge-case promises), [BUILTINS.md](BUILTINS.md) (built-in functions),
[OBSERVER.md](OBSERVER.md) (observer semantics in depth),
[COMPARISON.md](COMPARISON.md) (EigenScript next to Python/JS/Rust/Lisp).

## Table of contents

- [Program model](#program-model)
- [Lexical structure](#lexical-structure)
- [Values and types](#values-and-types)
- [Variables and assignment](#variables-and-assignment)
- [Numbers and arithmetic](#numbers-and-arithmetic)
- [Strings](#strings)
- [Booleans, comparison, and logic](#booleans-comparison-and-logic)
- [Bitwise operators](#bitwise-operators)
- [Conditionals](#conditionals)
- [Loops](#loops)
- [Lists](#lists)
- [Dictionaries](#dictionaries)
- [Functions](#functions)
- [Closures and lambdas](#closures-and-lambdas)
- [The pipe operator](#the-pipe-operator)
- [Pattern matching](#pattern-matching)
- [Error handling](#error-handling)
- [Modules](#modules)
- [Interrogatives: asking your code](#interrogatives-asking-your-code)
- [Observer semantics and predicates](#observer-semantics-and-predicates)
- [Temporal interrogatives](#temporal-interrogatives)
- [Concurrency](#concurrency)
- [Buffers](#buffers)
- [Evaluation model reference](#evaluation-model-reference)

## Program model

An EigenScript program is a sequence of statements executed top to
bottom. There is no required entry point — the file *is* the program.
Statements are expressions, assignments, definitions, or control
structures. Blocks are delimited by indentation (like Python), and a
statement ends at the end of its line.

Function application uses the keyword `of`: `f of x` calls `f` with the
argument `x`. `print` is an ordinary builtin function.

```eigenscript
print of "hello, world"
```
```output
hello, world
```

## Lexical structure

- Comments run from `#` to end of line.
- Blocks open with a `:` at the end of the introducing line and contain
  the following indented lines. Indentation must be consistent within a
  block.
- Identifiers are `[a-zA-Z_][a-zA-Z0-9_]*`.
- Keywords include: `is of define as if elif else loop while for in
  return and or not null try catch break continue import match case
  unobserved local what who when where why how converged stable
  improving oscillating diverging equilibrium`.

```eigenscript
# this is a comment
x is 1   # trailing comments are fine
if x == 1:
    print of "block body is indented"
```
```output
block body is indented
```

## Values and types

EigenScript is dynamically typed. The runtime types are:

| type label | description | literal |
|---|---|---|
| `num` | 64-bit float (the only number type) | `42`, `3.14` |
| `str` | immutable byte string | `"text"` |
| `list` | mutable ordered sequence | `[1, 2, 3]` |
| `dict` | mutable string-keyed map | `{"k": 1}` |
| `buffer` | flat mutable array of nums | `buffer of 8` |
| `fn` | user-defined function / closure | `define` / `(x) => x` |
| `builtin` | native function | `print` |
| `none` | the null value | `null` |

`type of v` returns the type label as a string.

```eigenscript
print of (type of 1)
print of (type of "a")
print of (type of [1])
print of (type of {"k": 1})
print of (type of null)
print of (type of print)
```
```output
num
str
list
dict
none
builtin
```

## Variables and assignment

Assignment uses `is`. It is outward-mutable: if the name exists in an
enclosing scope, that binding is updated; otherwise a new local binding
is created. `local name is expr` forces the binding into the current
scope even when an outer scope has the same name.

```eigenscript
x is 42
x is x + 1
print of x

name is "outer"
define demo as:
    local name is "inner"
    return name
print of (demo of null)
print of name
```
```output
43
inner
outer
```

Compound assignment operators update in place: `+= -= *= /= %= &= |= ^=
<<= >>=`. They work on plain names, dict fields, and indexed elements.

```eigenscript
total is 10
total += 5
total *= 2
print of total

d is {"hits": 0}
d.hits += 3
print of d.hits

xs is [1, 2, 3]
xs[1] += 10
print of xs
```
```output
30
3
[1, 12, 3]
```

## Numbers and arithmetic

All numbers are 64-bit floats. Integer-valued numbers print without a
decimal point. Division is true division. `%` is modulo. There is no
exponent operator; use `pow of [base, exp]`.

```eigenscript
print of (7 + 3)
print of (7 - 3)
print of (7 * 3)
print of (7 / 2)
print of (7 % 3)
print of (1 / 3)
print of (pow of [2, 10])
print of (abs of -5)
```
```output
10
4
21
3.5
1
0.3333333333333333
1024
5
```

Division by zero is a *warning*, not an error: the program continues
and the result of the division is `0`.

```eigenscript
x is 10 / 0
print of x
print of "still running"
```
```output
0
still running
```

## Strings

Strings are immutable. `+` concatenates (both operands must be strings
— there is no implicit coercion). `len of s` gives the length. Strings
support indexing, negative indexing, and half-open slicing `s[start:end]`.

```eigenscript
s is "hello"
print of (s + " " + "world")
print of (len of s)
print of s[1]
print of s[-1]
print of s[1:4]
print of s[2:]
print of s[:2]
```
```output
hello world
5
e
o
ell
llo
he
```

F-strings interpolate expressions inside `{}`:

```eigenscript
name is "Ada"
year is 1815
print of f"{name} was born in {year}"
print of f"sum = {1 + 2 + 3}"
```
```output
Ada was born in 1815
sum = 6
```

Convert explicitly with `str of n` and `num of s`:

```eigenscript
print of ("value is " + (str of 42))
print of ((num of "10") + 5)
```
```output
value is 42
15
```

## Booleans, comparison, and logic

There is no separate boolean type: comparisons produce `1` (true) or
`0` (false), and any value can be tested for truthiness (0, `null`,
empty string/list/dict are falsy). Logical operators are the words
`and`, `or`, `not`.

```eigenscript
print of (3 > 2)
print of (3 < 2)
print of (3 == 3)
print of (3 != 3)
print of (3 >= 3)
print of (1 and 0)
print of (1 or 0)
print of (not 0)
```
```output
1
0
1
0
1
0
1
1
```

Equality on lists and dicts is structural (deep):

```eigenscript
print of ([1, [2, 3]] == [1, [2, 3]])
print of ({"a": 1} == {"a": 1})
print of ({"a": 1} == {"a": 2})
```
```output
1
1
0
```

## Bitwise operators

`& | ^ << >> ~` operate on the integer part of nums. Note `^` is XOR,
not exponentiation.

```eigenscript
print of (12 & 10)
print of (12 | 10)
print of (12 ^ 10)
print of (1 << 4)
print of (16 >> 2)
print of (~0 & 255)
```
```output
8
14
6
16
4
255
```

## Conditionals

`if` / `elif` / `else`, each introducing an indented block. The
condition is any expression, tested for truthiness.

```eigenscript
x is 15
if x > 20:
    print of "big"
elif x > 10:
    print of "medium"
else:
    print of "small"
```
```output
medium
```

## Loops

`loop while cond:` repeats while the condition is truthy. `for v in
seq:` iterates a list, buffer, or `range of n` (0 to n-1). `break` and
`continue` behave conventionally and do not escape function-call
boundaries.

```eigenscript
i is 0
loop while i < 3:
    print of i
    i is i + 1

for v in [10, 20, 30]:
    print of v

for k in range of 5:
    if k == 1:
        continue
    if k == 3:
        break
    print of k
```
```output
0
1
2
10
20
30
0
2
```

## Lists

Lists are mutable, heterogeneous, zero-indexed. They support negative
indexing, half-open slicing with optional bounds, `append`, `len`,
element assignment, comprehension, and destructuring.

```eigenscript
xs is [10, 20, 30, 40]
print of xs[0]
print of xs[-1]
print of xs[1:3]
print of xs[2:]
xs[1] is 99
print of xs
append of [xs, 50]
print of (len of xs)
```
```output
10
40
[20, 30]
[30, 40]
[10, 99, 30, 40]
5
```

List comprehensions support an optional filter:

```eigenscript
xs is [1, 2, 3, 4, 5]
print of [v * v for v in xs]
print of [v for v in xs if v % 2 == 0]
```
```output
[1, 4, 9, 16, 25]
[2, 4]
```

Destructuring assignment unpacks a list into names:

```eigenscript
[a, b, c] is [1, 2, 3]
print of (a + b + c)
```
```output
6
```

Out-of-range indexing is a runtime error (catchable with `try`):

```eigenscript
xs is [1, 2]
try:
    v is xs[10]
catch e:
    print of "caught:"
    print of e
```
```output
caught:
Error line 3: index 10 out of range (list length 2)
```

## Dictionaries

Dicts map string keys to values. Access fields with dot syntax or
`d["key"]`; assign the same way (assignment creates the key if absent).
`keys of d` lists the keys; `len of d` counts entries.

```eigenscript
d is {"name": "Ada", "year": 1815}
print of d.name
print of d["year"]
d.field is "computing"
d["honor"] is "first programmer"
print of (len of d)
print of (keys of d)
```
```output
Ada
1815
4
["name", "year", "field", "honor"]
```

Nested structures compose naturally:

```eigenscript
app is {"config": {"debug": 0}, "users": [{"id": 1}, {"id": 2}]}
app.config.debug is 1
print of app.config.debug
print of app.users[1].id
```
```output
1
2
```

## Functions

`define name(params) as:` introduces a function. `return` exits with a
value; falling off the end returns `null`. Calling conventions:

- `f of x` — one argument.
- `f of [a, b, c]` — a **literal** list with 2+ elements spreads into
  the parameters.
- `f of (x)` — parenthesised single argument (required for one-argument
  calls to multi-parameter functions — see the warning below).
- `f of null` — call with no meaningful argument.

```eigenscript
define add(a, b) as:
    return a + b

define shout(msg) as:
    return msg + "!"

print of (add of [3, 4])
print of (shout of "hey")
```
```output
7
hey!
```

**Spread warning:** a literal list with exactly **one** element does
not spread — `f of [x]` binds the whole list `[x]` to the first
parameter. For one-argument calls to multi-parameter (including
defaulted) functions, write `f of (x)`.

```eigenscript
define first(a, b) as:
    return a

print of (first of [10, 20])
print of (type of (first of [10]))
```
```output
10
list
```

Default parameter values use `is` in the parameter list; defaults fire
for every unsupplied slot:

```eigenscript
define scaled(x, factor is 2) as:
    return x * factor

print of (scaled of (5))
print of (scaled of [5, 10])
```
```output
10
50
```

A `define` with no parameter list gets one implicit parameter named
`n`:

```eigenscript
define double as:
    return n * 2

print of (double of 21)
```
```output
42
```

Recursion works as expected. Note the parenthesised recursive call —
`fib of (m - 1)`, not `fib of [m - 1]`:

```eigenscript
define fib(m) as:
    if m < 2:
        return m
    return (fib of (m - 1)) + (fib of (m - 2))

print of (fib of 10)
```
```output
55
```

Argument passing is by reference for mutable values: a function that
mutates a list or dict parameter mutates the caller's value.

```eigenscript
define push_two(items) as:
    append of [items, 2]

xs is [1]
push_two of xs
print of xs
```
```output
[1, 2]
```

## Closures and lambdas

Functions capture their defining environment by reference: inner
functions can read *and write* outer variables, and the captured state
survives after the outer function returns. Lambda syntax is
`(params) => expr`.

```eigenscript
define make_counter as:
    count is 0
    define step as:
        count is count + 1
        return count
    return step

c is make_counter of null
print of (c of null)
print of (c of null)

add5 is (x) => x + 5
print of (add5 of 1)

apply is (f, v) => f of v
print of (apply of [add5, 10])
```
```output
1
2
6
15
```

`sort_by` is a builtin; `map` and `filter` come from the standard
library (`lib/list.eigs`):

```eigenscript
load_file of "lib/list.eigs"
xs is [3, 1, 2]
print of (map of [xs, (v) => v * 10])
print of (filter of [xs, (v) => v > 1])
print of (sort_by of [xs, (v) => v])
```
```output
[30, 10, 20]
[3, 2]
[1, 2, 3]
```

## The pipe operator

`value |> f` is `f of value`; pipes chain left to right.

```eigenscript
double is (x) => x * 2
inc is (x) => x + 1
print of (5 |> double |> inc)
print of (-3 |> abs)
```
```output
11
3
```

## Pattern matching

`match expr:` with `case` arms. Cases compare against literals or
expressions; `_` is the wildcard. Without a matching arm and no
wildcard, no arm runs.

```eigenscript
code is 404
match code:
    case 200:
        print of "OK"
    case 404:
        print of "Not Found"
    case _:
        print of "other"

target is 9
probe is 9
match probe:
    case target:
        print of "expressions match too"
```
```output
Not Found
expressions match too
```

## Error handling

`try:` / `catch name:` captures runtime errors; the caught message is
bound as a string. `throw of value` raises a user error. An *uncaught*
runtime error stops the program with a nonzero exit; warnings (like
division by zero) do not.

```eigenscript
try:
    throw of "custom failure"
catch e:
    print of ("caught: " + e)

try:
    x is undefined_name
catch e:
    print of e

print of "execution continues"
```
```output
caught: custom failure
Error line 7: undefined variable 'undefined_name'
execution continues
```

`throw` preserves the thrown *value*: throw a dict (or list) and the
catch variable binds it unchanged, so errors can carry data and be
matched on fields. Runtime errors and thrown strings bind as strings.

```eigenscript
define validate(age) as:
    if age < 0:
        throw of {"kind": "validation", "field": "age", "got": age}
    return age

try:
    v is validate of (0 - 5)
catch e:
    print of (type of e)
    print of e.kind
    print of e.got
```
```output
dict
validation
-5
```

An *uncaught* error prints the error followed by a stack trace —
every frame between the failure and the top level, innermost first —
then exits with code 1:

```eigenscript skip
# uncaught: stderr shows
#   Error line 6: index 99 out of range (list length 2)
#     at inner (line 6)
#     at middle (line 8)
#     at <module> (line 9)
```

## Modules

`import name` loads a module into a **namespace**: it executes
`lib/name.eigs` (the standard library) or, failing that, `name.eigs`
resolved relative to the script — and binds the module's top-level
definitions as a dict named `name`. Nothing leaks into the global
scope; names starting with `_` stay private to the module.

```eigenscript
import math
print of (math.clamp of [15, 0, 10])
print of (type of math)
print of (abs of -10)
```
```output
10
dict
10
```

A user module is just a file next to your script:

```eigenscript
write_text of ["spec_shapes.eigs", "PI is 3.14159\ndefine area(r) as:\n    return PI * r * r\n"]
import spec_shapes
print of spec_shapes.PI
print of (spec_shapes.area of 2)
rm of "spec_shapes.eigs"
```
```output
3.14159
12.56636
```

(In a project, the idiom is simply `import shapes` with `shapes.eigs`
sitting next to `app.eigs`.)

`load_file of "path.eigs"` is the older, non-namespaced form: it
executes a file directly **in the current scope**. The standard
library's helper modules (`lib/test.eigs`'s `assert_eq`, ...) are
conventionally loaded this way.

```eigenscript skip
load_file of "lib/test.eigs"     # assert_eq, test_summary, ...
load_file of "mymodule.eigs"     # definitions land in *your* scope
```

## Interrogatives: asking your code

Every observed variable can be interrogated. `what is x` is its value,
`who is x` its name, `when is x` the number of times it has been
assigned. (`where`, `why`, `how` return the observer's entropy,
entropy-delta, and stability — see [OBSERVER.md](OBSERVER.md).)

```eigenscript
x is 10
x is 20
x is 30
print of (what is x)
print of (who is x)
print of (when is x)
```
```output
30
x
3
```

```eigenscript skip
print of (where is x)   # entropy of x's value (a float >= 0)
print of (why is x)     # dH: change in entropy at last assignment
print of (how is x)     # stability in [0, 1]
```

## Observer semantics and predicates

Every assignment (outside `unobserved`) updates an observer that tracks
the value's entropy and its trend. Six bare-keyword predicates query
the most recently observed variable: `converged`, `stable`,
`improving`, `oscillating`, `diverging`, `equilibrium`. The canonical
use is a self-terminating loop:

```eigenscript
e is 5
loop while not converged:
    e is e * 0.5
print of (e < 0.001)
print of converged
```
```output
1
1
```

(The starting value matters: the predicate reads the observed value's
entropy, which is highest for magnitudes near 1 and low for both tiny
and huge magnitudes — a loop seeded with an already-low-entropy value
like `100` converges immediately.)

`unobserved:` blocks (and `loop` bodies inside them) skip observer
updates entirely — use them for hot numeric loops:

```eigenscript
total is 0
unobserved:
    i is 0
    loop while i < 100000:
        total is total + i
        i is i + 1
print of total
```
```output
4999950000
```

## Temporal interrogatives

With temporal queries the runtime records assignment history. `prev of
x` is the value x held before its latest assignment. `what is x at
<line>` reads the value x had at a source line. (History recording
turns on automatically when a program contains a temporal query.)

```eigenscript
score is 10
score is 25
score is 40
print of (prev of score)
print of score
```
```output
25
40
```

```eigenscript skip
print of (what is score at 2)   # 25 — line-number qualified history
```

## Concurrency

`spawn of [fn, args...]` runs a function on a new thread and returns a
handle; `thread_join of handle` waits and returns its result. Channels
(`channel of null`, `send`, `recv`, `try_recv`, `recv_timeout`)
communicate between threads.

```eigenscript
ch is channel of null
spawn of [(v) => send of [ch, v * 2], 21]
print of (recv of ch)

define work(a, b) as:
    return a + b
h is spawn of [work, 4, 5]
print of (thread_join of h)
```
```output
42
9
```

## Buffers

`buffer of count` allocates a flat array of `count` nums (all 0).
Buffers index, slice, and iterate like lists but hold only numbers —
they are the fast path for numeric work and the JIT.

```eigenscript
b is buffer of 4
b[0] is 1.5
b[3] is 4
print of b[0]
print of (len of b)
s is 0
for v in b:
    s is s + v
print of s
```
```output
1.5
4
5.5
```

## Evaluation model reference

The facts that govern every program, in one place:

1. **Execution**: statements run top to bottom; the file is the program.
   Source is compiled to bytecode and run on a stack VM; hot code is
   JIT-compiled on x86-64. None of this changes semantics.
2. **Application**: `of` is function application and binds tighter than
   arithmetic: `f of x + 1` is `(f of x) + 1`.
3. **Argument spreading**: a *literal* list argument with 2+ elements
   spreads into parameters; a 1-element literal list does **not**; a
   list passed via a variable never spreads.
4. **Scope**: `is` updates the nearest enclosing binding or creates a
   local; `local` forces the current scope. Functions see and may
   mutate their defining environment (closure capture by reference).
5. **Values**: numbers are 64-bit floats; strings immutable; lists,
   dicts, and buffers mutable and passed by reference; `==` is
   structural.
6. **Truthiness**: `0`, `null`, `""`, `[]`, `{}` are falsy; everything
   else is truthy. Comparisons yield `1`/`0`.
7. **Errors**: runtime errors unwind to the nearest `try`; uncaught
   they halt the program with exit code 1. Division by zero is a
   warning that yields `0` and continues.
8. **Observation**: every assignment outside `unobserved` updates the
   observer; predicates and interrogatives read it. Temporal queries
   additionally record history.
