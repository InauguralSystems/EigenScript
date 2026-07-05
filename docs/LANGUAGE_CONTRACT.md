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
execution stops, the process exits non-zero, and a stack trace (every
frame from the failure to the top level, innermost first) is printed to
stderr after the error line. Programs never continue past an
unrecovered error or report success on failure. Warnings (e.g.
division by zero, which yields 0) are not errors and do not stop execution.

**What `catch` binds:** a runtime error binds its message **string**; a
`throw`n value binds **unchanged** — `throw of {"kind": ...}` gives the
handler that dict (thrown strings bind as strings). Re-throwing a
structured value preserves it; a runtime error raised while a
structured value is in flight supersedes it.

**Status:** Enforced — `run_all_tests.sh` EM14–EM18,
`tests/test_trycatch.eigs` (incl. structured-throw checks),
`examples/errors/uncaught_with_trace.eigs`.

## Modules

**Promise:** `import name` executes the module once and binds its
top-level definitions as a **dict named `name`** — nothing enters the
importing scope besides that one binding, and module names starting
with `_` are private (omitted from the dict). Resolution order:
`lib/name.eigs` (the standard library) first, then `name.eigs`
script-relative and the other standard locations; the not-found error
names both tried paths. `load_file of "path.eigs"` is the
non-namespaced form: it executes the file directly in the current
scope. **Module functions never write the loader's bindings** (issue
#373): a module function's bare assignment to a name that isn't its
own local/captured/module-top-level state creates a fresh local — it
does not depend on what existed in the loader's scope at load time
(it used to: a global declared before the load was silently
write-through, one declared after was not). Reads and calls resolve
dynamically across the boundary; share mutable state via dict/list
fields. A **parse error** in a loaded file (via `import`, `load_file`, or
`eval`) raises a catchable runtime error rather than silently executing a
partial AST — consistent with the **Errors** promise.

**Status:** Enforced — `tests/test_import.eigs`,
`tests/test_import_errors.eigs` (parse-error surfacing for `import` /
`load_file` / `eval`) (stdlib + user modules,
namespacing, `_` privacy, missing-module error), docs/SPEC.md Modules
examples (executed by the suite).

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
- String literals support the escapes `\n \t \r \\ \" \{ \}`. There is no `\0`,
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
`bit_not` / `bit_shl` / `bit_shr` builtins) operate on **64-bit** two's-complement
integers; operands are truncated toward zero to `int64` (exact for magnitudes
below 2^63). Shift amounts are masked to `[0,63]`, so large or negative shifts
are defined, not UB (`1 << 64` == `1 << 0` == `1`; `1 << 100` == `1 << 36`). The
infix operators and the `bit_*` builtins agree bit-for-bit on the same operands —
they were once a divergent `int32` implementation (`0xEDB88320`, CRC-32's
polynomial, was the first casualty). Non-numeric operands **raise** a runtime
error — they are not silently treated as `0`. This is the same strict error model
the arithmetic operators use; it makes the **Errors** promise ("type-mismatched
operator … raises") hold for *every* operator with no exceptions.

**Status:** Enforced — `tests/test_bitwise.eigs` (builtin == infix parity across
the high-bit range and out-of-range shift counts), `INT_BINOP_R` / `CASE(BNOT)`
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
- If `X` is a **bare literal list of length ≥ 2**, the elements are
  spread across the callee's parameters in order. Extra elements are
  ignored; missing parameters are `null`. So `momentum of [2, 3]`
  passes `m=2, v=3`.
- **Parentheses always mean one argument** (issue #355): a
  parenthesised literal list does not spread — `f of ([a, b])` binds
  the list `[a, b]` to the first parameter, and `f of ([])` is a
  one-argument call passing the empty list (unlike bare `f of []`,
  which is the zero-arg form). This is the literal-list counterpart of
  the `f of (x)` escape hatch below.
- A **literal list of length 1** is *not* spread — `f of [x]` binds
  the one-element list `[x]` as a single argument, regardless of the
  callee's arity. (See the default-params footgun below.)
- If `f` has **exactly one** parameter, the *entire* argument binds to it —
  a list is **not** spread. So `mean of [1,2,3,4]` passes the whole list.
- An empty literal list `f of []` is a **zero-arg call**, so a function
  with all-default params runs every default.
- To pass a single value — scalar or literal list — to a multi-param
  (or any) function, use the parenthesized form: `f of (x)` is always
  a one-argument call binding `x` to the first parameter (later params
  take defaults or `null`). `f of x` is the same one-argument form
  when `x` isn't a list literal.

**Status:** Enforced — `tests/test_call_semantics.eigs`.

## Default parameter values (0.13.0)

**Promise:** A parameter may carry a default expression: `define f(a, b is expr) as: ...`.
- Defaults are **trailing-only** — once a parameter has a default, every
  following parameter must also have one. `define f(a is 1, b)` is a
  parse error.
- The default expression is **re-evaluated on every call** that omits
  the argument (no shared mutable-default footgun).
- A default expression can reference any earlier parameter in the same
  signature, as well as any name visible in the enclosing scope at
  call time. Earlier-param references resolve against the values just
  bound for *this* call.
- `null` passed explicitly is a real argument — defaults **do not**
  fire for it. To request the default, call with fewer arguments. For
  a single-parameter function with a default, write `f of []` to call
  with zero args (since `f of null` would bind `null`).
- Lambdas (`(x) => expr`) do **not** support defaults.
- **Footgun (issue #153):** `f of [x]` does *not* spread to a
  multi-param defaulted function. Per the call-spread rule above, a
  length-1 literal list binds as one argument, so `f` receives the list
  `[x]` as its first param — defaults can then fail or surprise
  (e.g. `define fib(n, memo is 0)` with `fib of [n - 1]` binds
  `n = [n - 1]`, then `n < 2` raises "compare list and num").
  Use the parenthesized form `f of (x)` for the one-arg case:
  `fib of (n - 1)` binds `n = n - 1` and lets `memo` default.
- **Behavior change in 0.13.0 (issue #154):** `f of []` now lowers to
  a **zero-arg call** for every callee arity. On a multi-param
  function `g(a, b)` it binds `a = null, b = null` (matches the
  contract's "missing parameters are `null`"); on `g(a, b is 100)`
  the `b`-default fires and it binds `a = null, b = 100` (per #158,
  see below). Prior to 0.13.0 the empty-list literal was treated like
  any other single list argument and bound `a = [], b = null`.
  Single-param non-defaulted callees are preserved by a compile-time
  special case (`one of []` still binds `a = []` there) so existing
  code that did `f of []` to pass an empty list to a 1-arg function
  keeps working.
- **Defaults fire whenever the slot is unsupplied (issue #158):**
  An underfed call binds every supplied positional slot, then fires
  the default expression for any defaulted slot the caller skipped —
  even when `argc < first_default`. So `define f(a, b, c is 1); f of
  5` binds `a = 5, b = null, c = 1`; `f of []` binds `a = null, b =
  null, c = 1`. Prior to the fix, defaults only fired when `argc >=
  first_default`, so an underfed call below that threshold silently
  left the defaulted tail `null`.

**Status:** Enforced — `tests/test_default_params.eigs`.

## Destructuring assignment (0.13.0)

**Promise:** `[a, b, c] is rhs` evaluates `rhs` once, requires it to be
a list of length exactly 3, and binds `a` `b` `c` to its elements in
order.
- **Length is strict:** mismatch raises a runtime error. No
  truncation, no padding with `null`, no clamping. Matches the same
  decision as out-of-range indexing.
- **Type is strict:** the RHS must be a list. A non-list (number,
  string, dict, buffer, null) raises. To convert, do it explicitly
  before the destructure.
- **RHS evaluated exactly once:** side effects fire once and the
  result is unpacked. So `[a, b] is mkpair of null` calls `mkpair`
  once even though two names are bound.
- **Swap works:** `[a, b] is [b, a]` builds the RHS list first, then
  unpacks — so the two reads happen before either write.
- **Plain identifiers only (v1):** the LHS is `[ IDENT (, IDENT)* ]`.
  Nested patterns (`[a, [b, c]] is ...`), index/field targets
  (`[items[0], obj.field] is ...`), and rest patterns (`[a, *rest]`)
  are not supported yet; ambient-list-literal expressions still
  parse as expressions (lookahead requires the trailing `]` to be
  followed by `is`).

**Status:** Enforced — `tests/test_destructuring.eigs`.

## Streaming subprocess I/O (0.13.0)

**Promise:** A six-builtin surface for interacting with a child process
over time, sibling to the all-at-once `exec_capture`. The child runs
with its stdin and stdout connected to anonymous pipes that the parent
reads/writes directly with `read(2)`/`write(2)` — no parent-side stdio
buffering, no shell.

- `proc_spawn of ["cmd", "arg1", ...]` — fork+execvp; returns
  `[pid, in_fd, out_fd]`. On failure returns `[-1, -1, -1]`. The
  child's stderr is inherited from the parent. Empty argv is the
  failure sentinel.
- `proc_write of [in_fd, "text"]` — full blocking write to the child's
  stdin. Returns bytes written. After a partial write that hits an
  error (e.g. EPIPE mid-stream), returns the partial byte count so a
  caller retrying doesn't double-send the delivered prefix. Returns
  `-1` only when the very first write failed (nothing delivered).
  SIGPIPE is masked process-wide on first spawn so writes get EPIPE
  instead of killing the parent.
- `proc_read_line of out_fd` — reads bytes from the child's stdout
  until `\n` or EOF. Returns the line without the trailing newline.
  Returns `null` only when nothing was buffered before the
  EOF-or-error; a mid-stream error or EOF that follows a partial line
  returns the partial line (matches the EOF-with-partial path).
- `proc_read of [out_fd, max_bytes]` — single `read(2)` of up to
  `max_bytes` bytes (capped internally at 10 MB). Returns a **string**;
  may return fewer bytes than requested. Returns `null` on EOF.
  Text-only: EigenScript strings are C-terminated, so a NUL in the
  child's output truncates the returned string at the first one. For
  binary or possibly-NUL output use `proc_read_buf`.
- `proc_read_buf of [out_fd, max_bytes]` — same semantics as
  `proc_read` but returns a **VAL_BUFFER** (binary-safe; one
  byte-as-double per element, indexable like any buffer). Returns
  `null` on EOF. Use this for any byte stream that isn't guaranteed
  to be NUL-free.
- `proc_close of fd` — `close(2)`; idempotent (a bad fd is a no-op).
- `proc_wait of pid` — blocking `waitpid`; returns the exit code,
  `128 + signal` if the child was killed by a signal, or `-1` on
  error.

**Buffering note:** EigenScript's reads are unbuffered, but a child
that uses stdio block-buffers its own output when stdout is not a
tty. To get line-streaming behavior from such a child, invoke it via
`stdbuf -oL` or `stdbuf -o0` (or use a child that flushes after every
line). The runtime cannot change the child's stdio mode for it.

**No automatic cleanup:** the returned fds and pid are raw OS
resources, not GC-managed handles. Callers must `proc_close` both
fds and `proc_wait` the pid to avoid zombies and fd leaks. A future
revision may add a `with`-style scoped form; v1 stays explicit.

**Status:** Enforced — `tests/test_proc_stream.eigs`.

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

**Promise (decision):** An index must be an integer in `[-length, length)`.
- Negative indices count from the end: `a[-1]` is the last element,
  `a[-len of a]` is the first. Resolution is `i + len` *before* the
  bounds check, matching Python and Ruby.
- Out-of-range indices (including too-negative, e.g. `a[-(len+1)]`)
  raise a runtime error.
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

**Slicing — `a[start:end]`, half-open with defaults and negatives.**
- **Slices** are half-open `a[start:end)`, with defaults `a[start:]`
  (end = len), `a[:end]` (start = 0), `a[:]` (the whole sequence).
- **Slice bounds are positions between elements**, so the valid range is
  `0 <= start <= end <= len` (note `<=` on the upper end): `a[len:]` and
  `a[start:len]` are legal and yield an empty slice — even though the bare
  index `a[len]` raises.
- **Out-of-range slice bounds raise** (they do not clamp), consistent with
  the single-index rule and with Rust/Go; only the coercion-happy languages
  (Python/JS) clamp. Write `min of [end, len of a]` for explicit clamping.
- Negatives resolve to absolute positions first (same rule as single
  indexing), then the `0 <= start <= end <= len` check applies.
- **The slice is an independent copy** — mutating the slice does not
  alias the source (and vice versa). Applies to lists, strings (which
  are immutable anyway), and buffers.

**Status:** Enforced — `tests/test_slicing.eigs`; `OP_SLICE_GET` in
`vm.c` for `VAL_LIST` / `VAL_STR` / `VAL_BUFFER`.

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
