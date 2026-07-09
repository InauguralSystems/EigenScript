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
statement ends at the end of its line. A `return` at module level ends
the program immediately (exit status 0); the returned value is
discarded.

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
print of (type of [1, 2])
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

Numeric literals accept the usual decimal forms plus a leading or
trailing dot and scientific notation: `.5`, `1.`, `1e5`, `1E5` are all
single numbers. Hexadecimal *integer* literals are lexed explicitly:
`0x10`/`0X10` is 16, digits `0-9a-fA-F`, and the literal ends at the
first non-hex-digit character. Hex-float forms (`0x1p4`, `0xA.8`) are
not numbers. A malformed form like `1.2.3` is a parse error.

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

### The numeric model (deliberate position)

There is one number kind — the IEEE-754 f64 — and by design there is no
bigint or decimal type. This is a chosen position, not an oversight; the
consequences are contracts you can rely on:

- **Integer exactness ends at 2^53.** Whole numbers up to `9007199254740992`
  are exact; past that the gaps between representable values exceed 1, so
  `+ 1` can be invisible. Keep integer identifiers, counters, and money-in-cents
  below 2^53, or use the bitwise seam below for wider exact integer work.
- **Finite by construction — no `NaN`, no `Infinity` ever reach your program.**
  A `NaN` result collapses to `0` (`sqrt of -1` is `0`), and overflow saturates
  at `±1e308` instead of becoming `Infinity`. Arithmetic is total: every
  operation returns a usable finite number (division by zero warns and yields
  `0`, above).
- **Integer bitwise ops act on int64, exact past 2^32.** `&` `|` `^` `~` `<<`
  `>>` and their `bit_*` builtin forms interpret operands as 64-bit integers, so
  `1 << 40` is exact where an f64 mantissa alone would not help. This is the
  seam for checksums, hashing, and byte protocols (see docs/BUILTINS.md).

```eigenscript
print of (9007199254740992 + 1)              # +1 is invisible past 2^53
print of (9007199254740993 == 9007199254740992)
print of (sqrt of -1)                        # NaN collapses to 0
print of (1e308 * 10)                        # saturates, never Infinity
print of (bit_and of [0xFFFFFFFF, 0xFF])     # int64 bitwise
print of (bit_shl of [1, 40])                # exact past 2^32
```
```output
9007199254740992
1
0
1e+308
255
1099511627776
```

Bigint / decimal value kinds would be a VM representation change rippling through
the JIT and the AOT (whose numeric speed rests on everything-being-a-double), so
they are deferred until a consumer genuinely forces them — not adopted
speculatively. Nothing above says "a number *is* an f64" any more than it must:
the contracts are exactness-below-2^53, finiteness, and the int64 bitwise seam,
which a future wider numeric kind could still honor.

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

Convert explicitly with `str of n` and `num of s`. `num of` accepts
decimal and hex-integer strings (hex converts identically on every
profile and stops at the first non-hex character); a string with no
leading number converts to `0`:

```eigenscript
print of ("value is " + (str of 42))
print of ((num of "10") + 5)
print of (num of "0xFF")
print of (num of "zebra")
```
```output
value is 42
15
255
0
```

### Text and Unicode (bytes by definition)

A `str` is a **byte string**, and that is a deliberate, documented position, not
an accident. `len`, `char_at`, `[]` indexing, and slicing all operate on
**bytes**, not characters. Source is UTF-8, so a non-ASCII literal is stored as
its UTF-8 bytes and round-trips exactly through concatenation, f-strings, and
printing — you just don't get character indexing for free.

```eigenscript
print of (len of "hello")     # 5 — all ASCII, 1 byte each
print of (len of "héllo")     # 6 — é is 2 UTF-8 bytes
euro is "€"
print of (len of euro)        # 3 — one character, three bytes
print of (euro == "€")        # 1 — bytes round-trip exactly
print of ("price: " + euro)   # f-strings / concat are byte-wise, multibyte-safe
```
```output
5
6
3
1
price: €
```

This is the Lua-shaped choice: it keeps the runtime zero-dependency and the
freestanding profile viable, at the cost of native character semantics. When you
need those — counting codepoints, indexing by character, validating input —
`lib/utf8.eigs` decodes UTF-8 over the byte string (`utf8_len`,
`utf8_codepoints`, `utf8_at`, `utf8_char_at`, `utf8_validate`). Native
UTF-8-by-construction is deliberately **not** adopted: it would ripple through
the VM, JIT, AOT, and every tool, for a bill this scale doesn't need.

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

`& | ^ << >> ~` operate on the integer part of nums as 64-bit
two's-complement values. Note `^` is XOR, not exponentiation. The
`bit_and`/`bit_or`/`bit_xor`/`bit_not`/`bit_shl`/`bit_shr` builtins
are the SAME operation in call form — one semantics, two spellings —
so the full unsigned-32-bit range (device registers, CRC polynomials)
works identically through either:

```eigenscript
print of (12 & 10)
print of (12 | 10)
print of (12 ^ 10)
print of (1 << 4)
print of (16 >> 2)
print of (~0 & 255)
print of (0xEDB88320 & 0xFFFFFFFF)
print of (bit_and of [0xEDB88320, 0xFFFFFFFF])
print of (bit_shl of [1, 32])
```
```output
8
14
6
16
4
255
3988292384
3988292384
4294967296
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
seq:` iterates a list, buffer, or `range of n` (0 to n-1). The iteration
length is **fixed at loop entry**: mutating `seq` inside the body is
well-defined — the loop visits the indices that existed when it started,
reading each element live, so appending does not extend the loop and
removing stops it early (rather than looping forever or reading past the
end). `break` and `continue` behave conventionally and do not escape
function-call boundaries. A `break` or `continue` with no enclosing loop — including
inside a function body that has no loop of its own — is a **compile
error** (`'break' outside a loop`), not a silent no-op.

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

Out-of-range indexing is a runtime error (catchable with `try`; the
caught value is a `{kind, message, line}` dict — see
[Error handling](#error-handling)):

```eigenscript
xs is [1, 2]
try:
    v is xs[10]
catch e:
    print of e.kind
    print of e.message
```
```output
index_range
index 10 out of range (list length 2)
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
- `f of [a, b, c]` — a **bare literal** list after `of` is always an
  argument list, at every element count: `f of []` is zero arguments,
  `f of [x]` is one argument (x itself, not a 1-element list),
  `f of [a, b]` is two.
- `f of (x)` — parenthesised single argument. This also works for
  literal lists: `f of ([a, b])` binds the whole list `[a, b]` as the
  single argument — parentheses always mean "one argument", so only a
  *bare* literal list is ever an argument list.
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

**One rule, one sentence:** brackets after `of` are an argument list;
parentheses are one argument. So `f of [x]` and `f of x` are the same
one-argument call, and `f of ([x])` passes a literal 1-element list
whole. (Before #405, `f of [x]` bound the whole list `[x]` to the
first parameter — lint `W017` flags the historically ambiguous
1-element form and names both unambiguous spellings.)

```eigenscript
define first(a, b) as:
    return a

print of (first of [10, 20])
print of (type of (first of [10]))
print of (first of ([10, 20]))
```
```output
10
num
[10, 20]
```

**Syntactic limits.** A function or lambda takes at most **16
parameters**, a `match` at most **64 cases**, and a list literal at most
**1024 elements**. Exceeding any of these is a parse error that names
the limit (`function exceeds 16 parameters`, `match exceeds 64 cases`,
`list literal exceeds 1024 elements`) — generated code that outgrows a
cap fails loudly at the cap, never with a stray-token cascade.

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

Because `n` is a real parameter, it shadows any enclosing `n` — exactly
as a named parameter shadows an outer binding of the same name. Assigning
`n is expr` inside such a function updates the parameter, **not** an
outer `n`; the update-outer scope rule (above) cannot reach a name that
is already bound as a parameter. Give the function an explicit parameter
list when you need `n` to follow the update-outer rule.

```eigenscript
define bump as:
    n is 99
    return n

n is 5
print of (bump of 7)
print of n
```
```output
99
5
```

Recursion works as expected, including the bracketed recursive call
`fib of [m - 1]` (one argument — see the call rule above):

```eigenscript
define fib(m) as:
    if m < 2:
        return m
    return (fib of [m - 1]) + (fib of [m - 2])

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
`(params) => expr`. A zero-parameter lambda `() => expr` mirrors the
classic no-parameter `define` style: it receives the implicit
parameter `n` (so `h is () => n * 2` then `h of 21` is `42`).

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

`try:` / `catch name:` captures runtime errors. A **built-in** runtime
error binds a small dict `{kind, message, line}`: `kind` is drawn from
a closed vocabulary (below), `message` is the error text without the
`Error line N:` frame, `line` is the 1-based source line. `throw of
value` raises a user error and the catch variable binds the thrown
value itself, unchanged — a thrown string stays a string. An *uncaught*
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
    print of e.kind
    print of e.message
    print of e.line

print of "execution continues"
```
```output
caught: custom failure
undefined_name
undefined variable 'undefined_name'
7
execution continues
```

The kind set is **closed** — the same design instinct as the closed
trajectory vocabulary. Every built-in runtime error carries exactly one
of:

| kind | raised by |
|------|-----------|
| `undefined_name` | reading a name with no binding |
| `type_mismatch` | an operation or builtin argument of the wrong type |
| `value` | right type, unacceptable value (fractional index, `chr of 0`) |
| `index_range` | index or slice outside the target's bounds |
| `parse` | runtime-surfaced parse/compile failure (`eval`, `import`, `load_file`) |
| `io` | the outside world failed: files, stores, sockets, threads |
| `limit` | an engine resource cap: stack overflow, size caps |
| `sandbox` | sandbox policy denial or budget exhaustion |
| `interrupt` | host-requested abort |
| `assert` | `assert` builtin failure |
| `internal` | a VM invariant broke (report it) |

Discriminate on `kind`, not on message text — messages are wording,
kinds are contract:

```eigenscript
xs is [1, 2, 3]
define get(i) as:
    try:
        return xs[i]
    catch e:
        if e.kind == "index_range":
            return null
        throw of e

print of (get of 1)
print of (get of 99)
```
```output
2
null
```

`throw` preserves the thrown *value*: throw a dict (or list) and the
catch variable binds it unchanged, so errors can carry data and be
matched on fields. Thrown strings bind as strings.

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

An `import` inside a module resolves relative to *that module's* own
directory, not the main script's. A submodule can safely
`import its_peer` and the peer is looked up next to the importer,
flattening symlinks and `..` segments. The other steps in the resolver
chain (cwd, exe-relative, `$HOME/.local/lib/eigenscript`) are
unchanged.

Project-local dependencies live under `eigs_modules/<name>/<name>.eigs`
at the project root (any directory containing `eigs.json`). The
resolver walks upward from the importing file's directory checking
each level for `eigs_modules/<name>/<name>.eigs`; once it finds
`eigs.json` it halts (the project root is the top of the walk). This
is the runtime hook for the `--pkg` tool; a hand-curated
`eigs_modules/` works today.

A module's body executes **once** per program. Repeated `import name`s
(directly, or transitively through a diamond like `a → c, b → c`) bind
the same dict and reuse the same module state — top-level side effects
fire on the first import only. The cache is keyed on the canonicalized
absolute path of the resolved file.

```eigenscript
write_text of ["spec_cached.eigs", "print of \"side effect\"\nn is 1\n"]
import spec_cached
import spec_cached
print of spec_cached.n
rm of "spec_cached.eigs"
```
```output
side effect
1
```

`load_file of "path.eigs"` is the older, non-namespaced form: it
executes a file directly **in the current scope**. The standard
library's helper modules (`lib/test.eigs`'s `assert_eq`, ...) are
conventionally loaded this way.

**Module write boundary.** A loaded (or imported) module's *functions*
can read the loader's globals and call its functions, but they can
never bind a write through to them — a bare `name is expr` inside a
module function that doesn't refer to a local, a captured name, or the
module's own top-level state creates a fresh local, regardless of what
happens to exist in the loader's scope. (Top-level statements in the
loaded file still execute directly in the current scope.) To share
mutable state across files, put it in a dict or list and mutate fields
— reads cross the boundary and field/index writes are value mutations,
not bindings. The standard library's UI toolkit (`lib/ui.eigs`'s `_ui`
state dict, shared by 17 sub-modules) is the reference pattern.

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

**Convergence-halting is opt-in.** A `loop while` is auto-halted on
observer convergence (a settled, high-entropy value for ~100 iterations)
**only when its condition is observer-based** — i.e. references a
predicate, as in `loop while not converged`. A plain loop whose
condition is an ordinary expression (`loop while i < n`,
`loop while not done`) is **never** halted by the observer; it runs until
its own condition is false. Both kinds keep an absolute iteration cap
(the runaway-loop guard). This keeps loop termination compositional: a
plain loop can't be cut short by what its body — or a function it calls —
happens to assign to the global observer.

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

## Cooperative tasks

`task_spawn` creates a **cooperative task** on the single interpreter
thread (unlike `spawn`, which uses an OS thread). Tasks are scheduled
round-robin: a task runs until it calls `task_yield of null`, which
hands control to the next ready task; it resumes where it left off.
Because there is one thread and a fixed policy, the interleaving is
**deterministic by construction** — the same program prints identically
on every run, with no threads and no clock. Args and results cross the
task boundary deep-copied (share-nothing, like channel sends).

`task_join of id` blocks until task `id` finishes and returns its
result (or re-raises its uncaught error as the same `{kind, message,
line}` dict — see [Error handling](#error-handling)). `task_alive of
id` is 1 until the task finishes.

```eigenscript
order is []
define step(tag) as:
    order is append of [order, f"{tag}-1"]
    task_yield of null
    order is append of [order, f"{tag}-2"]
    return tag

a is task_spawn of [step, "a"]
b is task_spawn of [step, "b"]
ra is task_join of a
rb is task_join of b
print of order
print of f"{ra}{rb}"
```
```output
["a-1", "b-1", "a-2", "b-2"]
ab
```

When the main program returns, any tasks still running are torn down
(the program ends). If every task is blocked with none runnable — for
example two tasks each `task_join`-ing the other — that is a `deadlock`
error, reported loudly rather than hanging.

Tasks communicate through **mailboxes**. `task_send of [id, value]`
appends a deep-copied message to task `id`'s FIFO mailbox (share-
nothing, like channel sends); `task_recv of null` returns the next
message or blocks cooperatively until one arrives. `task_try_recv`
is the non-blocking form.

```eigenscript
worker_id is 0
define worker() as:
    a is task_recv of null
    b is task_recv of null
    return a + b

worker_id is task_spawn of worker
task_send of [worker_id, 10]
task_send of [worker_id, 32]
print of (task_join of worker_id)
```
```output
42
```

### Virtual time

`task_sleep of ticks` suspends a task until a **virtual clock** advances by
`ticks`; `task_now of null` reads that clock. The clock is *logical*, not
wall-clock: it starts at 0 and only ever jumps **forward to the earliest
sleeper** when nothing else is runnable. So a program that sleeps runs in
zero real time and — like the rest of the task layer — replays identically,
with no dependence on how fast the machine is. Tasks therefore resume in
virtual-time order regardless of the order they were spawned, and the clock
lands on the last wake time.

```eigenscript
log is []
define nap(tag, ticks) as:
    task_sleep of ticks
    t is task_now of null
    log is append of [log, f"{tag}@{t}"]
    return tag

a is task_spawn of [nap, "a", 30]
b is task_spawn of [nap, "b", 10]
c is task_spawn of [nap, "c", 20]
task_join of a
task_join of b
task_join of c
print of log
print of (task_now of null)
```
```output
["b@10", "c@20", "a@30"]
30
```

### Seeded scheduling

By default the ready tasks run round-robin (FIFO). `task_sched_seed of n`
switches the scheduler to pick the next ready task from a seeded,
platform-independent PRNG. The schedule stays **fully deterministic** — the
same seed produces the same interleaving on every run and replays
byte-identically, recording no tape nondeterminism — but a *different* seed
explores a *different* ordering. This is the lever a deterministic simulation
tester uses to search the space of interleavings while keeping every run
reproducible. Without a seed the scheduler is unchanged, so existing programs
behave exactly as before.

```eigenscript
task_sched_seed of 42
order is []
define step(tag) as:
    order is append of [order, tag]
    task_yield of null
    order is append of [order, tag]
    return tag

a is task_spawn of [step, "a"]
b is task_spawn of [step, "b"]
c is task_spawn of [step, "c"]
task_join of a
task_join of b
task_join of c
print of order
```
```output
["b", "c", "a", "b", "c", "a"]
```

The same program with no seed prints the round-robin order
`["a", "b", "c", "a", "b", "c"]`; a different seed prints a different — but
equally reproducible — permutation.

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

### Reductions

`sum of a` returns the total of a buffer's (or tensor's) elements, and
`norm of a` returns the L2 (Euclidean) norm, `sqrt(sum_i a[i]*a[i])`.

```eigenscript
v is buffer of 4
v[0] is 1
v[1] is 2
v[2] is 3
v[3] is 4
print of (sum of v)
print of (norm of v)
```
```output
10
5.477225575051661
```

`dot of [a, b]` returns the sum over `i` of `a[i] * b[i]` for two numeric
buffers (the length is the shorter of the two).

```eigenscript
a is buffer of 4
b is buffer of 4
a[0] is 1
a[1] is 2
a[2] is 3
a[3] is 4
b[0] is 0.5
b[1] is 1.5
b[2] is 2.5
b[3] is 3.5
print of (dot of [a, b])
```
```output
25
```

For all three reductions (`sum`, `norm`, `dot`) the summation **order
(association) is unspecified**: callers must not depend on the exact low-bit
rounding of the result. This is a deliberate opt-in — it licenses an
optimizing backend (such as the AOT native compiler) to reassociate the sum
across SIMD lanes, which a strict left-to-right `loop while` accumulation
forbids. The no-NaN/no-Inf invariant still holds. Write the explicit loop when
you need a fixed reduction order.

### Shaped buffers (tensors)

A buffer can carry a 2-D shape, making it a flat-backed matrix. `buffer of
[rows, cols]` allocates a `rows*cols` buffer with that shape, and `reshape of
[buf, rows, cols]` shapes an existing flat buffer (the element count must
match). `shape of buf` returns `[rows, cols]` for a shaped buffer, or `[count]`
when unshaped. Indexing stays flat (`buf[r*cols + c]`).

The tensor builtins operate directly on the flat data — no per-call conversion.
`matmul of [a, b]` multiplies two shaped buffers (a 1-D buffer is a row vector,
so `matmul of [vec, mat]` returns a 1-D result); `add` and `relu` are
elementwise. The result is identical to the nested-list tensor form, so storing
weights as shaped buffers is purely a performance choice.

```eigenscript
w is buffer of [2, 2]
w[0] is 1
w[1] is 2
w[2] is 3
w[3] is 4
x is buffer of 2
x[0] is 1
x[1] is 1
y is matmul of [x, w]
print of y[0]
print of y[1]
print of (shape of w)
```
```output
4
6
[2, 2]
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
