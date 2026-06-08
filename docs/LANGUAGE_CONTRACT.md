# The EigenScript Language Contract

This is the list of semantic promises EigenScript makes — the decisions
every language must make, stated explicitly so they're chosen on purpose
rather than discovered by surprise. Each promise has a **status**:

- **Enforced** — the implementation guarantees it and a test locks it.
- **Planned** — the intended contract; the implementation doesn't fully
  enforce it yet (noted so the gap is visible, not hidden).

When you add a feature, add its row here *first*. Writing the promise down
is what forces you to notice the decisions you haven't made.

---

## Equality — `==` / `!=`

**Promise:** Structural for collections, by-value for scalars, by-identity
for functions. No cross-type coercion: operands of different types are
never equal (and it is never an error to compare them).

- Numbers, strings, null: by value (`3 == 3.0`, `"a" == "a"`).
- Lists: equal iff same length and elementwise-equal (recursive).
- Dicts: equal iff same keys with equal values (order-independent).
- Buffers / text-builders: by contents.
- Functions, builtins: by identity.
- Mixed types: `"3" == 3` is `false`, never an error.

**Status:** Enforced — `tests/test_equality.eigs`, `values_equal()` in
`eigenscript.c`.

## Ordering — `<` `>` `<=` `>=`

**Promise:** Both operands must be the same comparable type — number/number
or string/string (lexicographic). Comparing mixed or uncomparable types
**raises** a runtime error (it does not silently return false).

**Status:** Enforced — `tests/test_coercion.eigs`.

## Coercion

**Promise:** None. EigenScript does not implicitly convert between types.
`+` adds two numbers or concatenates two strings; a mixed operand raises.
To build text from mixed types, use an f-string (`f"n={count}"`) or
`str of` / `num of`.

**Status:** Enforced — `tests/test_coercion.eigs`.

## Errors

**Promise:** A runtime error (undefined variable, bad index, calling a
non-function, type-mismatched operator, bad builtin argument, stack
overflow) is recoverable with `try`/`catch`. If uncaught, it is **fatal**:
execution stops and the process exits non-zero. Programs never continue
past an unrecovered error or report success on failure. Warnings (e.g.
division by zero, which yields 0) are not errors and do not stop execution.

**Status:** Enforced — `run_all_tests.sh` EM14–EM18, `tests/test_trycatch.eigs`.

## Numbers

**Promise:**
- One numeric type: IEEE-754 double. Integers are exact up to 2^53.
- Finite by construction: no NaN, no Infinity. NaN-producing operations
  return 0; overflow saturates at ±1e308; division by zero warns and
  yields 0.
- `str of` produces the shortest representation that round-trips back to
  the same double; `num of (str of x) == x`.
- `%` follows the dividend's sign (C semantics): `-7 % 3 == -1`.

**Status:** Enforced — `tests/test_number_format.eigs`,
`tests/test_numeric_guard.eigs`.

## Strings

**Promise:** A string is a sequence of **bytes**, not Unicode codepoints.
- `len` returns the **byte** count (`len of "café"` is 5, not 4).
- Indexing `s[i]` returns the one-byte string at byte offset `i`; all string
  builtins (`split`, `index_of`, `substr`, `contains`, `upper`/`lower`, …)
  operate bytewise. A multi-byte UTF-8 sequence is therefore split by
  byte-offset operations — this is the documented consequence of the byte
  model, not a bug.
- Strings are immutable; comparison (`==`, `<`) is bytewise.
- String literals support the escapes `\n \t \\ \"`. There is no `\0`,
  `\xNN`, or `\u{…}` escape, so a string cannot embed a NUL or an arbitrary
  byte from source (only the raw bytes present in the source file flow
  through). An embedded NUL, if one ever arrived from file/buffer input,
  would truncate the string at that byte.

Unicode-correct length, indexing, and iteration are intentionally **out of
core scope**: they are an O(n) walk or a per-string index cache, a poor trade
for the runtime's targets. They may be added later as **opt-in helpers**
(e.g. `utf8_len`, `utf8_chars`) — purely additive, so this promise does not
foreclose them.

**Status:** Enforced — `builtin_len` (byte count) and the string index paths
in `builtins.c` / `vm.c`.

## Bitwise — `&` `|` `^` `<<` `>>` `~`

**Promise:** Bitwise operators (and the `bit_and` / `bit_or` / `bit_xor` /
`bit_not` / `bit_shl` / `bit_shr` builtins) operate on 32-bit two's-complement
integers; operands are truncated toward zero to `int32`. Shift amounts are
masked to `[0,31]`, so large or negative shifts are defined, not UB.
Non-numeric operands **raise** a runtime error — they are not silently
treated as `0`. This is the same strict error model the arithmetic operators
use; it makes the **Errors** promise ("type-mismatched operator … raises")
hold for *every* operator with no exceptions.

**Status:** Enforced — `tests/test_bitwise.eigs`, `INT_BINOP` / `CASE(BNOT)`
in `vm.c`, `bit_*` builtins in `builtins.c`.

## Truthiness

**Promise:** Falsy values are `0`, `""`, `[]`, `{}`, and `null`. Everything
else is truthy (including functions).

**Status:** Enforced — `tests/test_coverage_v2.eigs` (CV2-87/88).

## Scope & binding

**Promise:**
- Lexical scope. Functions capture their defining environment (closures).
- For-loop variables are block-scoped — they do not leak after the loop,
  and each iteration binds a fresh variable (so closures created in a loop
  capture distinct values).
- Name resolution walks the scope chain; an unresolved name is a fatal
  runtime error.
- Functions resolve referenced names at call time (late binding), so
  mutual recursion works regardless of definition order; but a *top-level*
  call must follow the definition in source order.

**Status:** Enforced — `tests/test_closures.eigs`,
`tests/test_scope_semantics.eigs`.

## Evaluation

**Promise:** `and` / `or` short-circuit and return the deciding operand
(`5 and 3 == 3`, `0 or 7 == 7`).

**Status:** Enforced.

## Mutability & aliasing

**Promise:** Assignment binds a reference, it does not copy. Lists and
dicts are reference types: after `b is a`, mutating `b` (e.g. `b[0] is 9`)
also changes `a`. Numbers and strings are immutable, so sharing them is
unobservable. To get an independent copy, copy explicitly.

**Status:** Enforced (behavior) — `tests/test_call_semantics.eigs`.

## Function calls & argument unpacking

**Promise:** `f of X` calls `f` with argument `X`.
- If `f` has **two or more** parameters and `X` is a list, the list's
  elements are spread across the parameters in order. Extra elements are
  ignored; missing parameters are `null`.
- If `f` has **exactly one** parameter, the *entire* argument binds to it —
  a list is **not** spread. So `mean of [1,2,3,4]` passes the whole list,
  while `momentum of [2,3]` passes `m=2, v=3`.
- To pass a single scalar to a one-parameter function, pass it directly:
  `frequency of 0.25` (not `frequency of [0.25]`, which binds the list).

**Status:** Enforced — `tests/test_call_semantics.eigs`.

## Operator precedence

From lowest (binds loosest) to highest (binds tightest):

| Level | Operators | Notes |
|------:|-----------|-------|
| 1 | `\|>` | pipe |
| 2 | `or` | |
| 3 | `and` | |
| 4 | `==` `!=` `<` `>` `<=` `>=` | comparison |
| 5 | `\|` | bitwise OR |
| 6 | `^` | bitwise XOR |
| 7 | `&` | bitwise AND |
| 8 | `<<` `>>` | shift |
| 9 | `+` `-` | |
| 10 | `*` `/` `%` | |
| 11 | `-` `not` `~` | unary (prefix) |
| 12 | `of` | function application |
| 13 | `[]` `.` `( )` | indexing, field access, grouping |

Two consequences worth knowing:
- **Bitwise binds tighter than comparison** (unlike C). `x & mask == 0`
  parses as `(x & mask) == 0` — the intended reading, avoiding C's classic
  footgun.
- **`of` binds tighter than arithmetic.** `len of xs - 1` is
  `(len of xs) - 1`; `sqrt of x + 1` is `(sqrt of x) + 1`. Parenthesize
  the argument when it's an expression: `sqrt of (x + 1)`.

**Status:** Enforced (parser). Binary operators are left-associative;
unary and `of` are right-associative.

## Indexing — `[ ]`

**Promise (decision):** An index must be an integer in `[0, length)`.
- Out-of-range indices (including negative) raise a runtime error.
- A non-integer index **raises** (`a[1.5]` → error). Integer-valued doubles
  are accepted (`a[2.0]` works), since EigenScript has a single number type;
  but a fractional value is never silently truncated. Because `/` always
  yields a double, a division-derived index must be collapsed explicitly —
  `a[floor of (lo + hi) / 2]` — which keeps the rounding decision in the
  programmer's hands. A value that is fractional only through float drift
  (`2.9999998`) also raises, surfacing the sloppy arithmetic rather than
  mis-indexing.

**Status:** Enforced — `tests/test_trycatch.eigs`; `vm_index_is_int` guards
every dynamic index site in `OP_INDEX_GET`/`OP_INDEX_SET` and
`jit_helper_index_get` in `vm.c`.

**Reserved (not yet implemented): negative indexing and slicing.** The
`a[-1]` and `a[start:end]` syntax is reserved for one coherent future
addition; today `a[-1]` raises (out of range) and `a[1:3]` is a parse error.
When it lands, the committed design is:
- **Negative indices** count from the end (`a[-1]` is the last element),
  resolved to `len + i` *before* any bounds check.
- **Slices** are half-open `a[start:end)`, with defaults `a[start:]`
  (end = len), `a[:end]` (start = 0), `a[:]` (the whole sequence).
- **Slice bounds are positions between elements**, so the valid range is
  `0 <= start <= end <= len` (note `<=` on the upper end): `a[len:]` and
  `a[start:len]` are legal and yield an empty slice — even though the bare
  index `a[len]` raises.
- **Out-of-range slice bounds raise** (they do not clamp), consistent with
  the single-index rule and with Rust/Go; only the coercion-happy languages
  (Python/JS) clamp. Write `min of [end, len of a]` for explicit clamping.
- Once negative indexing lands, negatives resolve to absolute positions
  first, then the `0 <= start <= end <= len` check applies.

**Dict access — missing key returns `null` (deliberate, not an error).**
A missing dict key (`d["k"]`) or field (`d.k`) evaluates to `null`, on
purpose: a missing key is a *lookup miss*, not a logic error. This is
distinct from out-of-range **list** indexing, which raises — an out-of-range
list index is a logic error. Both forms of dict access (`d.k` and `d["k"]`)
agree. Use `has_key of [d, "k"]` to test membership when `null` is itself a
valid stored value.

**Status:** Enforced — `tests/test_dict.eigs`, `OP_DOT_GET` /
`OP_INDEX_GET` in `vm.c`.

## Statistics convention (library)

**Promise:** `variance` / `std_dev` are **population** statistics (÷N).
`variance_sample` / `std_dev_sample` are the sample estimators with
Bessel's correction (÷N−1).

**Status:** Enforced — `tests/test_stem_accuracy.eigs`, `lib/stats.eigs`.

---

## How to use this document

1. Before implementing a feature, write its promise here and pick its
   answer deliberately — borrow the conventional answer unless you have a
   reason not to.
2. Write the contract test (`tests/test_*.eigs`) that pins the promise,
   then make the implementation satisfy it.
3. Keep the **status** honest. A row marked Enforced must have a passing
   test; a gap is marked Planned, never hidden.

The point isn't to memorize language theory — it's that writing the
contract down forces you to notice the decisions you haven't made yet.
