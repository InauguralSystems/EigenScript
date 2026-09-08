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
| `buffer` | flat mutable array of nums | `buffer of 8`, `zeros of 8` |
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
enclosing scope, that binding is updated; otherwise a new binding is
created in the enclosing scope. `local name is expr` forces the binding
into the current scope even when an outer scope has the same name.

This holds at **every** block form. A name first bound inside an `if`
body, a `loop while` body or a `for` body is visible after the block, in
exactly the same way, whether the block is at module level or inside a
function — `local` is the only way to confine a binding to the block.

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

Division by zero is a runtime error, not a silent result: it has no
defined value, so — like an out-of-range index — it raises rather than
inventing one. Uncaught it halts with exit 1; caught, the bound error's
`kind` is `"value"`. (Modulo by zero raises the same way.)

```eigenscript
try:
    x is 10 / 0
catch e:
    print of e.kind
    print of "still running"
```
```output
value
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
  at `±1e308` instead of becoming `Infinity`. Every *defined* operation returns
  a usable finite number; an *undefined* one — division or modulo by zero —
  raises a `value` error rather than inventing a result (above).
- **Strict mode (`EIGS_STRICT=1`) makes invalid arguments loud.** By
  default the substitutions above keep a program running (a kernel or grader
  wants the finite stand-in). Set the environment variable `EIGS_STRICT=1` and
  an out-of-domain operation — `sqrt` of a negative, `log` of `≤0`, `asin`/
  `acos` outside `[-1, 1]` — raises a catchable `value` error instead of
  substituting, for callers that need arithmetic invalidity to fail loudly.
  The same flag governs **argument-type guards**: builtins that answered a
  wrong-typed argument with a stand-in, so `cos of "hello"` was `0` and
  `str_upper of 42` was `""` — a type mistake became a plausible value. Under
  strict those raise a catchable `type` error naming the builtin, across the
  whole builtin surface (`builtins.c`, the host builtins, the tensor ops, the
  embedded store, and — since #1007 — the graphics/audio extension, where the
  stand-in is usually `null` rather than `0`/`""`: `gfx_rect of [x, y, w, h,
  "255", 0, 0]` drew a BLACK rectangle where red was asked for, in silence).
  A guard covers the argument's **container** as well as its elements — a
  short argument list, or a scalar where a list belonged, is a caller mistake
  and raises. That half is the one an element-typed probe cannot see, and in
  the extension it was the difference between "drew nothing" and a silent
  *success*: `audio_stream_open of [48000]` opened the device at the 44100/1
  defaults and answered a real device id, so the caller that asked for 48000
  was told it got 48000.
  A `0`, `""` or `null` that is a genuine *answer* is untouched
  in both modes: `try_parse` of invalid syntax still returns `0`, `task_alive`
  of an unknown id still returns `0`, `char_at` past the end is still `""`,
  and `num` still *coerces* (`num of ([1, 2])` is `0` — that is its documented
  contract, not a guard).
  The distinction is not derivable from the code: `task_alive` has two
  `return make_num(0)` lines four apart, one a type guard and one the
  documented answer. Every site in the surface therefore carries a written
  classification, mechanically enforced by
  `tools/failsoft_classify_check.sh`.
  Three further classes are loud under the same flag and unchanged without it:
  - **The `NaN`→`0` collapse.** With the flag off a `NaN` still collapses to
    `0` and sets `math_flags.invalid`. Under strict every reachable `NaN`
    source raises a catchable `value` error naming the builtin: `pow` of a
    negative base with a fractional exponent, `num of "nan"`,
    `f64_from_bytes` of a `NaN` bit pattern, `matmul` when its accumulation
    reaches `inf - inf`, `tensor_load` of a file carrying `NaN` bytes — and
    the elementwise `divide` by zero, which answers `0` by default where the
    `/` operator raises. The arithmetic operators themselves cannot reach a
    `NaN` from finite operands (`0 / 0` and `x % 0` raise first, and no
    operand can hold an infinity), so any other source hits a backstop that
    raises as `arithmetic`. The JIT bails to the interpreter on a non-finite
    result, so both tiers raise from the same guard. One default-path
    asymmetry is older than strict mode and is left alone by it: a `matmul`
    whose result is a **buffer** keeps the raw `NaN` the kernel wrote (it
    reads back as `null`, and `math_flags` is not set), where a list result
    collapses to `0` — strict raises on both.
  - **JSON parse failure in `json_path`.** With the flag off a malformed
    document is walked leniently and a parse failure answers the same `""`
    an absent key does. Under strict `json_path` applies `json_decode`'s
    acceptance test and raises a catchable `value` error naming the position;
    JSON `false`, `null` and an absent key are answers and stay quiet.
  - **The sentinel and falsy families.** `index_of`/`list_index_of`/`ord`
    (`-1`), `file_exists`/`is_dir`/`is_file`/`read_text`/`read_bytes`/`ls`/
    `mkdir`/`env_get` (`0`/`""`), and the wrong-type launderers the sweep
    found (`split`, `scan_ints`, `buffer`, `channel_closed`, `f64_to_bytes`,
    `json_build`, `sort`, `random_int`, `random_hex`, `token_name`,
    `tokenize_ids`...) raise on a wrong-typed argument; the documented
    sentinel for a valid-but-absent input — `index_of` miss `-1`,
    `file_exists` of a missing path `0` — is unchanged in both modes.
  Overflow saturation is unchanged by the flag. (Division and modulo by zero
  raise in *both* modes — no defined value.)
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

Key names are not restricted by the keyword table: after `.` nothing but
a field name can appear, so any word — including keywords like `loop`,
`in`, or `when` (common in `json_decode` output) — works as a dot key,
read or write, at any chain depth.

```eigenscript
ev is {"when": 3, "loop": 1}
ev.loop is ev.loop + 1
print of ev.when
print of ev.loop
```
```output
3
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

**Arity-1 carve-out.** "One rule" describes the call site, not what a
1-parameter, non-defaulted callee does with the list it receives. Such
a callee has only one slot, so a 2+-element argument list doesn't
distribute into it — the whole list re-collects and binds to that one
parameter instead: `one of [3, 4]` (with `define one(a)`) binds
`a = [3, 4]`, not `a = 3`. This is what keeps `len of [1, 2]` returning
`2` and `print of [1, 2]` printing the list — removing the carve-out
would break every 1-parameter function that takes a list.

```eigenscript
define one(a) as:
    return a
print of (type of (one of [3, 4]))
```
```output
list
```

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

**Over-arity raises.** The spread is exact: passing **more** arguments
than the callee's parameter count is a runtime error, not a silent
truncation. With `define two(a, b)`, `two of [1, 2, 99]` raises a
catchable `value`-kind error naming both counts — at the call site, in
the interpreter and the JIT alike, and across module boundaries. (Lint
`W022` still catches the same-file case earlier, at `--lint` time.) The
zero/one-parameter callees above are exempt by design. Under-arity is
unchanged and deliberately silent for now: missing parameters bind
`null` (or fire their default), no error.

```eigenscript
define two(a, b) as:
    return a - b

try:
    print of (two of [1, 2, 99])
catch e:
    print of e.kind
    print of e.message
```
```output
value
call passes 3 arguments but the callee takes 2
```

This holds wherever a user function is *entered*, not only where it is
written as a call. A function reached as a callback — `sort_by`'s key
function, or the entry point of `spawn` / `task_spawn` — raises the same
`value`-kind error with the same message, so a callback and a direct call
are indistinguishable to the program. For `spawn` and `task_spawn` the
error is raised at the spawn site, before the thread or task starts: the
mismatch is known in advance, and an error raised inside a worker has no
route back to the code that made it.

The arity-1 carve-out travels with it. A 1-parameter callee re-collects
the whole argument list at *every* entry point, so `spawn of [one, 5, 6]`
binds `a = [5, 6]` exactly as `one of [5, 6]` does — it does not bind `5`
and discard `6`. Under-arity null-fills on all of these paths.

For `sort_by`'s key function specifically, a **list** element is the
argument list (which is what lets a 2-parameter key destructure a record,
and what makes over-arity on a 3-wide element an error), while a
non-list element is a single argument: a 2-parameter key over `[3, 1, 2]`
receives `a = 3, b = null`, the same binding `two of (3)` produces.

Default parameter values fire on all of these paths too: `d of 1` on
`define d(a, b is 3)` gives `[1, 3]`, and so do `spawn of [d, 1]`,
`task_spawn of [d, 1]`, and a `sort_by` key reached with one element. An
explicitly supplied argument always wins over a default, on every path.

A key function that raises propagates its own error; `sort_by` does not
report "key function must return a number" on top of it.

```eigenscript
define two(a, b) as:
    return a - b

try:
    print of (sort_by of [[[3, 1, 2]], two])
catch e:
    print of e.kind
    print of e.message
```
```output
value
call passes 3 arguments but the callee takes 2
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
runtime error stops the program with a nonzero exit.

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
| `deadlock` | every cooperative task is blocked and none is runnable (#408) |
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

`try` blocks nest up to **8 deep within one function body** (each
function gets its own handler stack, so nesting across a call is not
counted). Going deeper is a compile error rather than a silent
mis-dispatch. Leaving a `try` by `break`, `continue`, or `return`
unregisters its handler, exactly as reaching the end of the block does.

An *uncaught* error prints the error, a one-line source excerpt with a
`^` caret under the offending column, and a stack trace — every frame
between the failure and the top level, innermost first — then exits
with code 1:

```eigenscript skip
# uncaught: stderr shows
#   Error line 6: index 99 out of range (list length 2)
#        6 | v is items[99]
#          |           ^
#     at inner (line 6)
#     at middle (line 8)
#     at <module> (line 9)
```

## Modules

`import name` loads a module into a **namespace**: it executes
`name.eigs` resolved relative to the script (the project) or, failing
that, `lib/name.eigs` (the standard library) — and binds the module's
top-level definitions as a dict named `name`. Nothing leaks into the
global scope; names starting with `_` stay private to the module.

Resolution is **project-first** (#821): a `name.eigs` beside the
importing file wins over a stdlib module of the same name. The stdlib
namespace grows over release to release, so the other order would let a
new stdlib module silently capture an existing project's import. When a
name matches **both**, the runtime prints a one-line warning to stderr
(once per name per process) naming the file used and the file shadowed
— rename the project file if the stdlib module is the one you want.

The *project* arm means a file you wrote. An **installed** stdlib
(`<prefix>/lib/eigenscript/`, what `make install` writes) answers the bare
`name.eigs` shape as readily as `lib/name.eigs`, but it is the stdlib arm
either way: it never counts as a project file, so it neither warns nor
displaces the stdlib shipped alongside the running binary or extracted
from a bundle (#904).

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

`import` and `load_file` use one resolution chain. `import name` first
requests `name.eigs`, then `lib/name.eigs`; a project/stdlib collision warns
and uses the project file. For each request, the order is:

1. An absolute path is used as-is.
2. Relative to the directory of the **file containing the call**, with
   symlinks and `..` canonicalized. This is the loaded file's directory for
   nested loads, and remains the defining file's directory inside a function,
   including `eval` in that function while its caller is running through
   `import`, `load_file`, or an embedding host's `eigs_eval_file` call. The entry
   file's compile directory does not override a helper's runtime `eval`.
3. The `eigs_modules` walk described below.
4. Relative to the **project root**: the nearest ancestor of that containing
   directory with an `eigs.json`, including the containing directory itself.
   If none exists, this step is skipped.
5. The existing stdlib locations, in order: `<exe>/../<path>`,
   `<exe>/../lib/eigenscript/<path>`, the latter again with a leading `lib/`
   stripped, then `$HOME/.local/lib/eigenscript/<path>` and its `lib/`-stripped
   form. Here `<exe>` is the executable's directory.

There is **no process cwd search step**, and no containing-directory-parent
fallback. The REPL (including piped input) and the embed API without a file
path use their working directory as the containing directory; this is the
only way the working directory enters resolution. Files using project-root
paths from subdirectories need an `eigs.json` at their root. Failed resolution
raises an `io` error naming the containing directory, project root (or
`no eigs.json above <dir>`), and stdlib roots tried.

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

**A namespace is a live view, not a snapshot** (#1057). `name.x` reads
the module's *current* binding `x`, and `name.x is v` writes that
binding — the module and its importers see one state, whatever the
value's type:

```eigenscript
write_text of ["spec_live.eigs", "hits is 0\ndefine record() as:\n    hits is hits + 1\ndefine total() as:\n    return hits\n"]
import spec_live
spec_live.record of null
spec_live.record of null
print of spec_live.hits
spec_live.hits is 10
print of (spec_live.total of null)
rm of "spec_live.eigs"
```
```output
2
10
```

Before this, the namespace was a *shallow copy* of the module's
bindings taken at import time, so whether an importer saw live state
depended on the value's TYPE: a dict or list was shared by reference
and tracked, a number or string was frozen and went silently stale, and
a write through the namespace reached only the copy. The failure mode
was a wrong number rather than an error. Values read *out* of a
namespace are ordinary values — `n is name.hits` binds the number, not
a live alias.

`_`-private bindings are not part of the namespace and are not
projected; everything else about a namespace is unchanged — it is still
a dict (`type of name` is `"dict"`), still enumerable with `keys` /
`values` / `len`, and its functions are still callable as `name.f of x`
or extractable as values.

`load_file of "path.eigs"` is the older, non-namespaced form: it
executes a file directly **in the current scope**. The standard
library's helper modules (`lib/test.eigs`'s `assert_eq`, ...) are
conventionally loaded this way.

The same file has the same block and return rules on all three roads (main,
`load_file`, `import`). A `for` binder is loop-scoped and never writes a
same-named outer binding. A `for` body's plain `is` updates the nearest existing
binding, including a `local` in the current or an enclosing loop. Otherwise it
creates a binding in the enclosing scope, like `if`, `loop while`, and `try`.
At an imported module's top level the search stops at the module boundary;
fresh bindings belong to the module and are exported normally, without writing
to the importer.
A top-level `return value` ends the current file, skipping all later statements:
`load_file` yields the value to its caller; import finishes its namespace;
the main program discards the value and exits successfully.

There is no function-scope exception (#1105): a binder with no prior binding
inside a function is loop-scoped like any other, so reading it after the loop
raises `undefined variable` on every road. A pre-existing parameter, `local`
or module binding is restored after the loop; a post-loop plain assignment to
the name creates a fresh binding.

```eigenscript
define probe() as:
    for z in [7, 8]:
        0
    return z
try:
    print of (probe of [])
catch e:
    print of e.message
x is 5
define over_module() as:
    for x in [7, 8]:
        0
    return x
print of (over_module of [])
```
```output
undefined variable 'z'
5
```

**Module write boundary.** A loaded (or imported) module's *functions*
can read the loader's globals and call its functions, but they can
never bind a write through to them — a bare `name is expr` inside a
module function that doesn't refer to a local, a captured name, or the
module's own top-level state creates a fresh local, regardless of what
happens to exist in the loader's scope. The same boundary applies one
level up to an **imported** module's own top-level statements: a bare
`name is expr` at an imported file's top level binds in *that module's
own scope*, never walking through to a same-named binding the importer
happens to already have — `counter is 0` at a module's top level can
never rebind an importer's pre-existing `counter`. `load_file` is the
one exception, per its older, documented contract above: its top-level
statements still execute directly in the current (caller's) scope, so
a same-named top-level assignment there *does* bind through.

Mutable state shared across files can live in a plain top-level binding
— an importer reads and writes it through the live namespace (#1057) —
or in a dict or list whose fields are mutated. Boxing state in a dict
is now a **style** choice, not a correctness requirement; the standard
library's UI toolkit (`lib/ui.eigs`'s `_ui` state dict, shared by 17
sub-modules) remains the reference pattern for grouping related state
under one private name.

```eigenscript skip
load_file of "lib/test.eigs"     # assert_eq, test_summary, ...
load_file of "mymodule.eigs"     # definitions land in *your* scope
```

## Interrogatives: asking your code

Every observed variable can be interrogated. `what is x` is its value,
`who is x` its name, `when is x` the number of times it has been
assigned — **every** assignment, including those made inside an
`unobserved:` block, which suppresses observation and not assignment
(#908). (`where`, `why`, `how` return the observer's entropy,
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
the value's entropy and its trend. The entropy walk **stops at a
reference**: a list or dict computes over its own elements, and an element
that is itself a container contributes only its size term `log2(count+1)`
rather than being entered. This is the rule buffers and text builders
have always followed, so a dict holding a 5-element list measures exactly
as one holding a 5-element buffer. The cost of an observed assignment is
therefore proportional to the value's own size, never to everything it can
reach, and cyclic or shared object graphs are well-defined because they are
never traversed (see [OBSERVER.md](OBSERVER.md)). Six bare-keyword predicates query
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

For a **numeric** binding the predicates classify the value's own
trajectory (#861): the observed signal is the relative step
`Δv / max(|v|, |v_prev|, scale)` (#1045) — the standard mixed-tolerance
stopping criterion `|Δx| ≤ rtol·|x|` with the settle deadband as `rtol`
and `dh_zero · scale` as the absolute floor (`scale` is
`set_observer_scale`, default `0.001`) — so the starting value, the
limit's magnitude and the **unit** the value is stored in do not matter.
A loop converging to `5`, `5000` or `0.005` certifies identically, and a
bank angle reads the same in radians and degrees. Non-numeric bindings (strings,
containers) classify their entropy trajectory as before; the entropy
MEASUREMENT (`where is x`) is unchanged for everything.

**Convergence-halting is opt-in.** A `loop while` is auto-halted on a
quiet observer trajectory (~100 iterations without motion, at any
entropy) **only when its condition is observer-based** — i.e. references a
predicate, as in `loop while not converged`. A plain loop whose
condition is an ordinary expression (`loop while i < n`,
`loop while not done`) is **never** halted by the observer; it runs until
its own condition is false. An absolute iteration cap exists only under an
explicitly armed sandbox budget (`sandbox_run`'s `max_iter`); ordinary
execution never truncates a loop. This keeps loop termination
compositional: a plain loop can't be cut short by what its body — or a
function it calls — happens to assign to the global observer.
The division of labour (#861): `converged` ends an observer loop when the
value settles at the deadband; `stalled` ends it when 100 quiet
iterations pass without certification (a runaway pinned at the
saturation ceiling, sub-deadband drift); `__loop_exit__` records which
one happened.

`report` and `report_value` are **reserved observer forms**, like the
predicate keywords: neither may be a binding name (including function names,
parameters, `local`, loop/comprehension variables, destructuring targets,
`catch` names, or an `import` module name). They are not first-class values.
Misuse is a compile-time parse error **`E005`**, before any statement in that
source unit executes. The rule also applies to REPL input, `eval`, `load_file`,
`import`, the embedding API, and `--lint`; the CLI accepts source strings with
`eigenscript -e '<source>'`.

Both forms require an **identifier operand**, optionally parenthesized:
`report of x`, `report of (x)`, and `report_value of ((x))` query the same
binding history as before. Literals, arithmetic expressions, calls, indexing,
field access, and literal argument lists (`[]`, `[x]`, `[x, y]`) are rejected
with `E005` and “requires a variable name operand”. Assign an expression to a
variable first; a temporary value has no named assignment history. This also
replaces `report`'s old non-identifier fallback (`equilibrium`, or `opaque` for
a function) and `report_value`'s undefined-name error. `of` precedence is
unchanged: `report of x + "!"` appends to the report of `x`.

As with other keywords, quoted dict keys and dot fields remain legal:
`d.report` and `d.report_value` are data fields, not bindings of reserved names.
`match` cases compare expressions; they do not introduce binders.

**`report of x`** names the most specific band true of the same
trajectory the predicates read (value channel for numerics, entropy
otherwise — #861), resolving `oscillating` → `diverging` → `improving` →
`converged` → `equilibrium` → `stable`. At a full window it agrees with the
bare predicates by construction: it either names a band whose predicate is
true, or — when a full window matches none of them — returns `moving`. The
bands are not exhaustive, and `moving` is the honest answer for the gap
(#735); only while the window is still filling may `report` fall back to an
instantaneous label the predicates don't yet confirm. See
[PREDICATES.md](PREDICATES.md).

**Entropy is current-state; dH is the assignment trajectory** (#711).
`where is x` — and the entropy every classification surface reads
(`report`, the predicates, `observe`'s band, `trajectory` snapshots) —
is recomputed from the binding's **current value at ask time**, so an
in-place mutation (`dict_set`, `append`, an indexed store) is visible:
two containers with identical contents answer identical entropies, no
matter how each got there. `why is x` (dH) and its windows are a
**trajectory of assignments** — recorded when the binding is assigned,
deliberately untouched by mutation and never perturbed by a query
(asking never writes anything back):

```eigenscript
d is {"k": 1}
dict_set of [d, "k", 999999]
e is {"k": 999999}
print of ((where is d) == (where is e))
print of why is d
```
```output
1
0
```

**Function values are `opaque`** (#708). A function has no content the
observer can sample — its entropy is a constant — so a binding whose
current value is a function (or builtin) sits outside what the observer
measures. Rather than reporting a confident `equilibrium` that could
never move, `report`, `report_value`, and `observe`'s band answer
`opaque`, and every predicate is false. This is the same honesty rule
as `moving`: name the gap instead of picking a plausible band. The
entropy *constant* is unchanged — containers holding functions measure
exactly as before; only the direct classification of a function-valued
binding names the gap:

```eigenscript
define a() as:
    return 1
define b(p, q, r) as:
    return p + q + r
f is a
f is b
print of report of f
print of (equilibrium of f)
```
```output
opaque
0
```

**The saturation ceiling is not a rest state** (#861). Overflow saturates
at `±1e308` (*Numbers*, above), which turns an unbounded trajectory into a
fixed point: the dH window fills with zeros and the entropy of `1e308`
falls under the low-entropy threshold, so a runaway satisfies every clause
of `converged`. The window really is quiet — the quiet is an artifact of
the clamp, produced *after* the evidence of divergence was destroyed. So a
binding sitting at `±1e308` is `diverging` in both channels and in no rest
band: `converged`, `equilibrium`, `stable`, and `improving` are all false.
A binding assigned a literal `±1e308` that never overflowed reads
`diverging` too — the runtime cannot distinguish the two, and this is the
direction that fails loudly. Below the ceiling nothing changes:

```eigenscript
z is 2.0
i is 0
loop while i < 20:
    z is z * z
    i is i + 1
print of report of z
print of (converged of z)
```
```output
diverging
0
```

**The value channel** (`report_value of x`) is, since #861, the same
classifier the predicate words and `report` use on numeric bindings —
the two surfaces cannot disagree about one trajectory. Over a window of
relative steps `Δv / max(|v|, |v_prev|, scale)` — `N` samples deep, 10
by default, `set_observer_window of n` per state or
`set_observer_window of ["x", n]` per binding (#1044; a mode slower than
`N` samples of the observation cadence cannot fold inside the window) —
`converged` is a full window all
under the settle deadband; `stable` all under the small-motion band;
`equilibrium` zero-mean, variance under deadband²; `improving` monotone
steps contracting geometrically (a summable tail — genuinely closing on
a limit); `diverging` the #422 raw rule (non-vanishing same-sign steps —
an additive runaway whose relative step vanishes is still unbounded) or
a value at the saturation ceiling; `oscillating` deadband sign-flips,
non-vanishing alternation (a perpetual oscillation below the deadband is
still an oscillation), or window-scale folding (net travel small against
path length — a sinusoid sampled slower than its half-period).
`converged` is a **stopping criterion, not a proof**: vanishing steps do
not imply a limit (the harmonic series' steps vanish; its sum does not
converge), so it means *settled at the deadband* — the strongest claim a
finite window supports. The deadband is the tolerance knob
(`set_observer_thresholds`), the characteristic scale
(`set_observer_scale`) is where the tolerance turns absolute, and the
window depth (`set_observer_window`) is how many samples a verdict
spans; the structure rules are deliberately threshold-free.

**Trajectories cross call boundaries as snapshots** (#421). Observer state
is binding-identity — a value passed to a function arrives with no history —
so `trajectory of x` captures the binding's observer windows into a plain
dict, and `classify of t` (value channel; `classify of [t, "entropy"]` for
the entropy channel) classifies it with the same machinery. `classify` of
anything that is not a snapshot raises a `type_mismatch` error:

```eigenscript
define judge(t) as:
    return classify of t

x is 400000.0
i is 0
loop while i < 40:
    x is x + 5000.0
    i is i + 1
print of (report_value of x)
print of (judge of (trajectory of x))
```
```output
diverging
diverging
```

`unobserved:` blocks (and `loop` bodies inside them) skip the
**entropy** half of observation — use them for hot numeric loops. The
depth is dynamic, so it covers functions called from inside the block; an
observer predicate asked anywhere under one **raises**, because there is
no trajectory for it to classify (a performance annotation must not
change an answer):

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

What the block suppresses is the **entropy walk**, not assignment. The
writes still happen, still land in the history, and are still counted and
addressed like any other: `when is x` includes them, and each one takes
an ordinal that `<kw> is x when <n>` can address (#908). The same rule
that makes a predicate raise rather than answer from a dead trajectory
is why the counter does not quietly shrink — a performance annotation
must not change an answer.

For the same reason a scalar assignment inside the block still records
its **sample into the value window** (#1049): the relative and raw step
enter the 10-deep ring the numeric predicates, `report` and
`report_value` read, at O(1) per assignment. So the window is complete,
and the verdicts a numeric binding gives after (or inside) the block are
identical to the ones it gives without it — an elided initialiser no
longer shifts the window-fill boundary, and a mid-stream elided step no
longer merges two steps into one. What is *not* computed for an elided
assignment is the entropy and everything built on it: `where`'s stored
entropy (the query-time read is unaffected), `dH` and its window
(`why`/`how`, `observe`'s dH pair, a `trajectory` snapshot's `dh`/`dH`),
the tape's observer snapshot, and the bare-predicate alias (a bare
`converged` keeps reading the last **observed** binding, so scratch work
inside the block cannot hijack it). Those entropy-channel readers — and
`report`/the predicates on a **non-numeric** binding, which route
through the entropy channel — therefore remain sensitive to elision;
[PREDICATES.md](PREDICATES.md#inputs) lists them. (It follows that the
block is not a way to declare a numeric binding without a sample; seed
with `null`, which is never sampled.)

```eigenscript
x is 9.0
unobserved:
    x is x * 0.5
    x is x * 0.5
print of (report of x)
print of (len of (trajectory of x).rel)
print of (why is x)
```
```output
moving
2
0
```

```eigenscript
c is 0
c is 1
unobserved:
    c is 2
c is 3
print of (when is c)
print of (what is c when 3)
```
```output
4
2
```

## Temporal interrogatives

With temporal queries the runtime records assignment history. `prev of
x` is the value x held before its latest assignment. `what is x at
<line>` reads the value x had at a source line. (History recording
turns on automatically when a program contains a temporal query.)

`prev of` takes a **variable name** — it looks back through that binding's
history — and binds like any other `of` (tighter than arithmetic, per the
Application rule above): `prev of x + 1` is `(prev of x) + 1`. A non-name
operand (a literal, an index/dot, or a parenthesised expression) has no
trajectory and is a parse error.

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

### Addressing an occurrence: `when <n>`

`at <line>` addresses a **source line**, which is not injective: a line inside
a loop or a repeatedly-called function executes many times, and only the most
recent execution is reachable. `when <n>` addresses the **nth recorded
assignment** to that binding instead — 1-based, in execution order — so every
iteration is individually addressable, and the query does not shift meaning
when a line is inserted above it.

```eigenscript
x is 0
for i in range of 3:
    x is i * 10
print of (what is x when 2)
print of (what is x when 4)
print of (prev of x when 4)
print of (when is x)
```
```output
0
20
10
4
```

Every interrogative takes the qualifier: `who is x when 2`, `where is x when
2`, and `prev of x when n` (the value at assignment `n - 1`).

Retention is **bounded** — the last 256 assignments per queried binding, so a
long-running loop cannot grow without limit. `EIGS_OCC_WINDOW` sets a different
window. The two ways a query can come back empty are kept distinct: an ordinal
that has not happened yet answers `null`, while one that has aged out of the
window **raises**, because reporting a dropped value as `null` would be
indistinguishable from one that was never assigned.

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

A worker that **dies of an uncaught error** prints its trace and the
**process exits non-zero** (status 1) whether or not anything ever
`thread_join`s it — the same rule as cooperative tasks below (#493), so a
fire-and-forget thread's failure is never swallowed into a success exit.
This covers a builtin spawned directly (`spawn of [recv, 5]` raises
"invalid channel" on the worker) as well as a function body. An error
`catch`-ed inside the worker recovers normally (exit 0), and a worker's
`exit of N` still decides the status (#739). The failure is always a
clean exit, never a signal (#1112).

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

Tasks are scoped to the OS thread that spawned them: each thread has its
own scheduler and its own ready queue, so `task_yield` hands control to
the next task **on this thread** and never disturbs another. Mixing the
two models is therefore well-defined — a `spawn`ed worker runs its own
program while the parent interleaves tasks. (Before #739 the suspend
request was process-wide, so one thread's `task_yield` made every other
thread's next call return `null` mid-evaluation.)

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
error, reported loudly rather than hanging. The `deadlock` is delivered
as an ordinary **catchable** error at the main task's blocked join/recv
site: a `try`/`catch` there binds `e.kind == "deadlock"` and execution
continues after the block. Only if the main task has no handler is the
deadlock terminal (loud message, non-zero exit) — a handler inside a
*worker* does not catch it, since the deadlock is delivered to main.

A task that **dies of an uncaught error** prints its stack trace, and if
nothing ever `task_join`s it the **process still exits non-zero** — a
fire-and-forget worker's failure is never silently swallowed into a
success exit. `task_join`-ing the dead task and `catch`-ing its error
recovers normally (exit 0), exactly as for an inline `try`/`catch`. A
task ended deliberately with `task_kill` is a teardown, not an uncaught
error, and does not by itself fail the process.

Tasks communicate through **mailboxes**. `task_send of [id, value]`
appends a deep-copied message to task `id`'s FIFO mailbox (share-
nothing, like channel sends); `task_recv of null` returns the next
message or blocks cooperatively until one arrives. `task_try_recv`
is the non-blocking form.

A task learns its **own** id with `task_self of null` — the same
integer space `task_spawn` returns; the main task is 0. That is what
makes a *reply address* expressible: a spawner passes `task_self of
null` down as an argument (or a worker sends its own `task_self` up),
and messages can then flow back to whoever asked — the link pattern
message-based supervision needs.

A task nobody will ever join can be marked **fire-and-forget** with
`task_detach of id` (a task may detach itself via `task_self`). A
detached task releases all its resources the moment it finishes, so a
long-running program can spawn an unbounded stream of short-lived
tasks; an undetached task instead stays joinable until the program
ends. A detached task that dies of an uncaught error still prints its
trace and still makes the process exit non-zero — fire-and-forget
never silently swallows a failure.

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

### Scheduler trace

`task_sched_trace of 1` arms a trace of the scheduler's decisions (off by
default; `EIGS_TASK_TRACE=1` arms it from the environment). While armed, every
task **resume** appends one entry — `{seq, tick, task, cause}`: the entry's
index, the virtual clock, the resumed task's id (`0` is the main task), and
why it became runnable: `spawn` (its first run), `yield` (a `task_yield`
re-enqueue), `sleep-wake` (the clock reached its `task_sleep` deadline),
`join-release` (the task it joined finished), `kill-release` (the task it
joined was killed), `recv-wake` (a message reached its empty mailbox), or
`deadlock` (main re-enqueued to receive the catchable deadlock error).
`task_sched_trace of null` reads the history; `task_sched_trace of 0` disarms
it and discards it. The trace is a **pure reader**: arming it changes no pick,
no clock and no seed — a traced run is byte-identical to the untraced one —
and its entries are derived from the deterministic schedule rather than
recorded on the trace tape, so a replayed run reproduces the same history.

```eigenscript
task_sched_trace of 1
define step(tag) as:
    task_yield of null
    task_sleep of 10
    return tag

a is task_spawn of [step, "a"]
b is task_spawn of [step, "b"]
task_join of a
task_join of b
for e in task_sched_trace of null:
    print of f"{e.seq} t={e.tick} task={e.task} {e.cause}"
```
```output
0 t=0 task=1 spawn
1 t=0 task=2 spawn
2 t=0 task=1 yield
3 t=0 task=2 yield
4 t=10 task=1 sleep-wake
5 t=10 task=2 sleep-wake
6 t=10 task=0 join-release
```

## Buffers

`buffer of count` allocates a flat array of `count` nums (all 0).
Buffers index, slice, and iterate like lists but hold only numbers —
they are the fast path for numeric work and the JIT. Storing anything but
a number into an element is a runtime error (`cannot store str in a
buffer`), the same rule every other numeric context follows; it was the
last one that silently tolerated a non-number (#1061).

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

### `zeros of n` is a buffer

`zeros of n` is the same flat container under the name numeric code reaches
for first: it returns a **buffer** of `n` zeros, not a list of `n` boxed
numbers. `zeros of [rows, cols]` is unchanged — that spelling still builds the
nested-list tensor, because 2-D list code indexes rows. `zeros_like of t`
mirrors its argument's container: a buffer in gives a buffer out, a list in
gives a list out.

```eigenscript
z is zeros of 4
print of (type of z)
print of z
z[1] is 2.5
print of (sum of z)
m is zeros of [2, 3]
print of (type of m)
print of m
print of (type of (zeros_like of z))
```
```output
buffer
<buffer:4>
2.5
list
[[0, 0, 0], [0, 0, 0]]
buffer
```

This is a **breaking change** (#1093). Before it, `zeros of n` answered a list:
`type of (zeros of 4)` was `list` and `print of` showed `[0, 0, 0, 0]`. Code
that genuinely needs the list form spells it out — `[0 for i in range of n]` —
and code that only indexes, assigns, iterates, reduces or passes the vector to
a tensor builtin needs no change, because a buffer supports all of those.

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
so `matmul of [vec, mat]` returns a 1-D result); `matmul_at` / `matmul_bt`
multiply with the first / second operand transposed (`aᵀ·b`, `a·bᵀ`) without
materialising the transpose; `add`, `subtract`, `multiply`, `divide` are
elementwise, with a `[cols]` buffer broadcast over the rows of a
`[rows × cols]` buffer and a number broadcast over every element; `relu`,
`leaky_relu`, `softmax`, `log_softmax`, `sum`, `mean`, `norm`, `gather`
compute on the shape, and `scatter_add` is `gather`'s in-place dual. The
result is identical to the nested-list tensor form, so storing weights as
shaped buffers is purely a performance choice — and it is the substrate the
reverse-mode autograd tape in `lib/autograd.eigs` runs on.

### `gather` and an out-of-range index

`gather of [matrix, indices]` selects `matrix[i][indices[i]]` for each row.
An index outside the row **raises** `index_range` — in every form, on a list
tensor and on a shaped buffer alike. There is no element at that index, so an
answer of `0.0` would be a stand-in the caller cannot tell from a real `0`
(a Q-value, a log-probability); `scatter_add`, which is `gather`'s gradient and
takes the same index, raises on it too.

```eigenscript
q is [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
print of (gather of [q, [2, 0]])
try:
    print of (gather of [q, [2, 3]])
catch e:
    print of e["kind"]
    print of e["message"]
```
```output
[3, 4]
index_range
gather: column index 3 out of range for row 1 (cols 3)
```

Changed in this release (#973/#1093): the list form used to answer `0.0` for
an out-of-range index and the buffer form was added folding the same way. A
tensor that is not a matrix in the per-row form still answers `0.0` for that
row — that is the shape reading, not the index one — and a wrong-typed
argument still answers `0.0` unless `EIGS_STRICT=1` is set.

Every tensor builtin that accepts a flat numeric list accepts a buffer in the
same position, and returns a buffer when **every** tensor operand was a buffer:
`add`/`subtract`/`multiply`/`divide`/`pow`, `sqrt`/`exp`/`log`/`negative`,
`matmul`, `softmax`/`log_softmax`/`relu`/`leaky_relu`, `gather`, `shape`,
`zeros_like`, `tensor_save`, and the `numerical_grad`/`sgd_update` family
(including the `_rows`/`_cols` variants, whose index vector may also be a
buffer). Mixing a buffer with a list yields a list. The reductions
(`sum`, `mean`, `norm`) return a number from either container. A 1-D buffer
reads as a 1-D tensor and a shaped buffer as its `rows x cols` 2-D tensor, so
the numbers agree element for element with the equivalent list.

```eigenscript
l is [1.0, 4.0, 9.0]
b is buf_from_list of l
print of (sqrt of l)
print of ((sqrt of b)[2])
print of (type of (sqrt of b))
print of (type of (add of [b, l]))
print of (mean of b)
```
```output
[1, 2, 3]
3
buffer
list
4.666666666666667
```

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
   list passed via a variable never spreads. Exception: a 1-parameter,
   non-defaulted callee has only one parameter to spread into, so a
   2+-element list doesn't spread there either — it re-collects whole
   and binds to that one parameter (`one of [3, 4]` binds `a = [3, 4]`
   for `define one(a)`).
4. **Scope**: `is` updates the nearest enclosing binding or creates a
   local; `local` forces the current scope. Functions see and may
   mutate their defining environment (closure capture by reference).
5. **Values**: numbers are 64-bit floats; strings immutable; lists,
   dicts, and buffers mutable and passed by reference; `==` is
   structural.
6. **Truthiness**: `0`, `null`, `""`, `[]`, `{}` are falsy; everything
   else is truthy. Comparisons yield `1`/`0`.
7. **Errors**: runtime errors unwind to the nearest `try`; uncaught
   they halt the program with exit code 1. Division and modulo by zero
   raise a `value` error (they have no defined result).
8. **Observation**: every assignment outside `unobserved` updates the
   observer; predicates and interrogatives read it. Temporal queries
   additionally record history.

<!-- Embed contract: #1038/#1028; language-level observer semantics unchanged. -->
The C embedding API starts observer recording open. Source evals retain
cross-unit history by default; hosts may explicitly promise isolated observer
use with `eigs_set_eval_observer_isolated`. Missing history then raises
conservatively instead of answering a rest value. See the
[embedding observer contract](EMBEDDING.md#observer-contract-1038--1028).
