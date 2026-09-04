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

**What `catch` binds (#406):** a **built-in** runtime error binds a small
dict `{kind, message, line}` — `kind` is drawn from a closed vocabulary
(see `docs/DIAGNOSTICS.md`), `message` is the error text without the
`Error line N:` frame, and `line` is the 1-based source line. A `throw`n
value binds **unchanged** — `throw of {"kind": ...}` gives the handler that
dict, and a thrown string stays a string. Re-throwing a structured value
preserves it; a built-in error raised while a structured value is in flight
supersedes it.

**Status:** Enforced — `run_all_tests.sh` EM14–EM18,
`tests/test_trycatch.eigs` (incl. structured-throw checks),
`examples/errors/uncaught_with_trace.eigs`. (Before #406, a built-in error
bound only its message string.)

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
- **Every clamp is recorded.** The finite invariant keeps a program
  running, but it keeps it running with a plausible number, so the
  clamps are readable as sticky status flags — IEEE-754's own model
  (`fetestexcept`) — rather than being undetectable (#865):

  ```eigenscript
  clear_math_flags of null
  result is risky of xs
  if (math_flags of null).overflow:
      print of "a value saturated; this result is contaminated"
  ```

  `overflow` is set by the ±1e308 clamp. `invalid` is set by the
  out-of-domain substitutions: `log of x` for `x <= 0` (which
  returns `log(1e-10)`, i.e. `-23.025850929940457`), `sqrt of x` for
  negative `x` (returns 0, otherwise indistinguishable from
  `sqrt of 0`), and `asin`/`acos` outside [-1, 1] (argument clamped).
  `invalid` is also set when a NaN is collapsed, which arithmetic
  cannot produce (there is no way to obtain an Inf to combine) but
  string conversion can: `num of "nan"` is `0` and `num of "inf"` is
  `1e308`, so a data column containing either used to parse to a
  plausible number with nothing to check. Both bits are sticky until
  `clear_math_flags`, so bracket a computation the way you would on an
  FPU.
- **Saturation is not associative, and that is not detectable from the
  value alone.** `(1e300 * 1e300) / 1e300` is `1e8`; `1e300 * (1e300 /
  1e300)` is `1e300`. The first overflowed and came back down, and
  `1e8` will pass any plausibility check a caller applies. The results
  are what the finite invariant requires — the `overflow` flag is how
  you tell. Stated here because the trade should be visible rather than
  discovered.
- `str of` produces the shortest representation that round-trips back to
  the same double; `num of (str of x) == x`.
- **Every producer of number text obeys that same rule** — `str of`,
  `json_encode`, `json_build`, `json_path`, and the SIGUSR1 observer dump
  all share one implementation (`eigs_num_text`), so a JSON round-trip
  returns the same double and `json_encode of x` equals `str of x` for
  every number (#875).
- `%` follows the dividend's sign (C semantics): `-7 % 3 == -1`.

**Status:** Enforced — `tests/test_number_format.eigs`,
`tests/test_numeric_guard.eigs` (NG20–NG30 cover the flags),
`tests/test_json_roundtrip.eigs`.

## Strings

**Promise:** A string is a sequence of **bytes**, not Unicode codepoints.
- `len` returns the **byte** count (`len of "café"` is 5, not 4).
- Indexing `s[i]` returns the one-byte string at byte offset `i`; all string
  builtins (`split`, `index_of`, `substr`, `contains`, `upper`/`lower`, …)
  operate bytewise. A multi-byte UTF-8 sequence is therefore split by
  byte-offset operations — this is the documented consequence of the byte
  model, not a bug.
- Strings are immutable; comparison (`==`, `<`) is bytewise.
- String literals recognize the escapes `\n \t \r \\ \"`; any other `\x`
  yields the literal character `x` (the backslash is dropped) — this is how
  `\{` and `\}` produce literal braces in f-strings. There is no `\0`,
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
  capture distinct values). Inside a function, a binder whose name was
  already bound (a parameter, a `local`, an earlier assignment) has that
  earlier value again after the loop (#1064). Function-scope note: a binder
  whose name had NO prior binding in the function stays readable after the
  loop with its last value — the loop var lives in a frame slot there, and
  the unbound case is not diagnosed the way module scope diagnoses it.
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

**Promise (#405):** brackets after `of` are an **argument list**;
parentheses are **one argument**. A bare literal list `[...]` after `of`
is the call's argument list at *every* count — its elements bind to the
callee's parameters in order:
- `f of []` — **zero** arguments (every default fires).
- `f of [x]` — **one** argument: the *element* `x`, not the list `[x]`.
  So `one of [7]` binds `a = 7`.
- `f of [a, b]` — **two** arguments. So `momentum of [2, 3]` passes
  `m = 2, v = 3`.
- **Extra elements raise (#974):** on a callee with 2+ parameters, passing
  more elements than it has parameters is a runtime error, not a silent
  truncation — `two of [1, 2, 99]` against `define two(a, b)` raises a
  catchable `value`-kind error at the call site (`call passes 3 arguments
  but the callee takes 2`), in the interpreter and the JIT alike, and
  across module boundaries. Lint `W022` flags the same-file case earlier,
  at `--lint` time.
- Parameters with no matching element take their default, else `null`.
  Under-arity stays silent; #974 changed the over-arity half only.
- **Arity-1 carve-out:** the elements-bind-in-order rule above assumes
  a callee with 2+ parameters. A 1-parameter, non-defaulted callee has
  only one slot, so a 2+-element list doesn't distribute into it — and it
  neither raises nor binds just the first element, because the over-arity
  rule above is scoped to callees with 2+ parameters. The whole list
  re-collects and binds to that one parameter: for `define one(a)`,
  `one of [3, 4]` binds
  `a = [3, 4]`, not `a = 3`. This is what keeps `len of [1, 2]`
  returning `2` and `print of [1, 2]` printing the list. The `f of []`
  half of this same exception — an empty list still binds `a = []`
  rather than firing a zero-arg default — is covered under Default
  parameter values below.
- **Parentheses always mean one argument** (issue #355). To pass a literal
  list *whole*, parenthesise it: `f of ([a, b])` binds the list `[a, b]`
  to the first parameter, and `f of ([7])` binds the one-element list
  `[7]`. `f of (x)` is likewise always a one-argument call binding `x` to
  the first parameter (later params take defaults or `null`); `f of x` is
  the same one-argument form when `x` isn't a bare list literal.
- A list held in a **variable** never spreads: `xs is [1,2,3]; f of xs`
  binds the whole list to the first parameter (only a *literal* bracket at
  the call site is an argument list). So `mean of [1,2,3,4]` passes the
  four elements to a 4-param `mean`, while `mean of xs` passes the list
  whole — pass `(...)` or a variable when you mean "one list argument."

Lint **W017** flags the bare 1-element form `f of [x]` as ambiguous-looking
(pre-#405 it bound the list; now it binds the element) — write `f of (x)`
for one scalar arg or `f of ([x])` for one list arg.

**Status:** Enforced — `tests/test_call_semantics.eigs`. (This is the #405
model; before #405 a length-1 literal list bound as the whole list and
`f of []`/`f of [x, y]` were the only spreading forms — see the CHANGELOG
for #405/#153.)

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
- **Resolved footgun (issue #153, fixed by #405):** a bare `f of [x]`
  now binds the *element* `x` as one argument (see the argument-unpacking
  section above), so bracketed recursion on a defaulted function works:
  `define fib(n, memo is 0)` with `fib of [n - 1]` binds `n = n - 1` and
  lets `memo` default — no "compare list and num". Before #405 the
  length-1 literal bound the whole list `[x]`, which surprised such calls;
  lint **W017** still flags the bare 1-element form as ambiguous-looking,
  so prefer `f of (x)` for one scalar arg.
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
  `a[floor of ((lo + hi) / 2)]` — which keeps the rounding decision in the
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

That rationale covers a **dict**. It does not cover `null`, which is not a
dict — so `null.k` and `null["k"]` **raise**, like field access on any other
non-dict (#872). This is what keeps a typo'd path from propagating: `d.mising`
is `null` at the miss, and walking through it (`d.mising.deeper`) fails
*there* rather than yielding `null` through arbitrary depth and surfacing
somewhere unrelated, or nowhere.

**Status:** Enforced — `tests/test_dict.eigs` (incl. the null-receiver
cases), `OP_DOT_GET` / `OP_INDEX_GET` in `vm.c`.

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
