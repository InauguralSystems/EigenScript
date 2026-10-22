# EigenScript compared to Python, JavaScript, Rust, and Lisp

A translation guide: each section shows the same program in a language
you already know, then in EigenScript. Every EigenScript block followed
by an `output` block is executed by the test suite
(`tests/test_doc_examples.py`) and must produce exactly that output.
The other languages' blocks are illustrative only.

The one-paragraph summary: EigenScript reads like Python (indentation
blocks, dynamic types), applies functions with a keyword like a
concatenative language (`f of x`), is a Lisp-like single-value-kind
world underneath (everything is one of eight runtime types, code runs
top to bottom, no static pass), and differs from all of them in one
fundamental way: **every assignment is observed**, and the language has
first-class constructs (`converged`, `what is x`, `prev of x`) for
asking the running program about its own state and history.


Bitwise operators and `bit_*` builtins return ints, including when an
operand is an integral float. They use Lua 5.4's 64-bit shift rules: `>>`
zero-fills; a negative count shifts in the opposite direction; a count of
64 or more, or -64 or less, gives zero. Each operand must be an exact int64;
a fractional or out-of-range float raises `value`.

```eigenscript
print of [1 << 64, 1 << -1, -1 >> 1, 8 >> -1, 1 << 63]
print of [bit_shr of [-1, 1], bit_shl of [8, -1], num_type of (3.0 & 1)]
```
```output
[0, 0, 9223372036854775807, 16, -9223372036854775808]
[9223372036854775807, 4, "int"]
```

`//` floors the quotient; `%` has the divisor's sign. `//=` applies the same
operation to its assignment target, like `/=`. Zero divisors raise `value`
for all numeric operand kinds in this round. Two ints produce an int for
`//` and `%`; a float operand produces a float. `/` always produces a float.
Float and mixed `//` use Python’s `divmod` quotient correction: `1.0 // 0.1`
is `9.0`, and `1e-300 // -1e300` is `-1.0`. `//=` uses the same rule.

```eigenscript
x is -7
x //= 2
print of [x, 7 // -2, -7 % 3, 7 % -3, -7.5 % 2]
print of [num_type of (7 // 2), num_type of (7.0 // 2)]
y is 1.0
y //= 0.1
print of [1.0 // 0.1, 1 // 0.1, 1e-300 // -1e300, y, num_type of y]
```
```output
[-4, -4, 2, -2, 0.5]
["int", "float"]
[9, 9, -1, 9, "float"]
```

## At a glance

| | Python | JavaScript | Rust | Lisp | EigenScript |
|---|---|---|---|---|---|
| typing | dynamic | dynamic | static | dynamic | dynamic |
| numbers | int + float | float | many | many | int64 + float64 |
| assignment | `x = 1` | `let x = 1` | `let x = 1;` | `(define x 1)` | `x is 1` |
| call | `f(x)` | `f(x)` | `f(x)` | `(f x)` | `f of x` |
| blocks | indentation | braces | braces | parens | indentation |
| booleans | `True/False` | `true/false` | `bool` | `#t/#f` | `true`/`false` (`bool`) |
| null | `None` | `null/undefined` | `Option` | `nil` | `null` |
| errors | exceptions | exceptions | `Result` | conditions | `try`/`catch` |
| self-inspection | none | none | none | macros | interrogatives + observer |

Binary tensor files use a shared 10,000,000-element cap. `tensor_load` and
`tensor_save` raise catchable `limit` errors above it; `stream_open` requires
an integral count from 1 through that cap, and `build_corpus` includes file
separators in its capped token count. These limits also raise under
`EIGS_STRICT=0`; see [BUILTINS.md](BUILTINS.md) for the I/O contracts.
Unlike Python text mode, `read_line of null` does not translate line endings:
it returns each stdin line with its terminator. This follows Lua's preservation
of the `\r` in CRLF input while additionally retaining `\n`, making the final
newline observable and making pipes match redirected regular files byte for byte.

Like Python, EigenScript's `read_text`, `read_bytes`, and `read_bytes_buf`
raise a catchable `io` error carrying the path and operating-system reason for
missing, unreadable, and directory paths. Empty files return empty values.

`vm_run_bytecode` raises a catchable `value` error naming a rejected chunk descriptor; a valid program may still return `null`. `sandbox_run` reports descriptor rejection in its structured `{ok: false, error: ...}` result. Its optional fourth limit, `max_work`, bounds cumulative bytecode instructions across function calls and callback re-entry (default 10,000,000), independently of loop and allocation limits. This meters VM work, not elapsed time: a blocking native callback must return before the sandbox can stop.

The positions and counts of `char_at`, `substr`, `get_at`, `set_at`,
`copy_into`, `fill` and the `list_*` mutation/slice builtins use exact conversion
(N5). So do handle fields, bytecode ABI/counts/bytes, sandbox limits and numeric
exit codes. Integral floats are accepted; fractions and values outside the
receiving C type raise `value` before indexing or effects.
`recv_timeout` rounds milliseconds half away from zero and raises beyond the
C long range, with no one-year cap. `task_detach` and sandbox error lines return ints.

```eigenscript
print of (substr of ["hello", 1.0, 2.0])
try:
    print of (substr of ["hello", 1.5, 2])
catch e:
    print of e.kind
```
```output
el
value
```


Sandbox execution does not update shared temporal history: assignment values, names, counts and observer snapshots stay outside that history even when recording is armed. Ordinary tape assignment records still emit. Host and trusted descriptor history recording resumes normally outside the sandbox; sandbox temporal reads remain refused.

`lib/eigen.eigs` snapshots the host values used by its tokenizer, parser, evaluator, import helpers, and fresh meta environments when it loads (#1386). Later host builtin rebinding does not change those dependencies, including entropy's `log`/`divide` calls. For `load_file`, the snapshots use values visible during initialization; loaded code still shares the host scope. String conversion still uses the pristine reserved f-string bridge. Explicit custom environments, debug hooks, and rebinding the interpreter's own helper names remain caller-controlled; captured caller-defined functions retain their own binding behavior.

## Variables and arithmetic

In VM/native-JIT evaluation, an unresolved omitted HTTP, network, database,
or model builtin name raises a catchable `value` error at its first reference,
naming the unavailable capability and required profile. This occurs before
call arguments are evaluated. Local, captured and host bindings take precedence,
including a binding to null; other unknown names retain `undefined_name` errors.
`--api`, lint and token-vocabulary discovery describe the language surface,
not callable availability. Direct host global lookup returns actual absence.
Direct AOT adoption, capability imports and host grants remain separate work.

Python:

```python
x = 42
x += 1
print(x)            # 43
print(7 / 2)        # 3.5
print(7 // 2)       # 3   (floor division operator)
```

EigenScript — int64 and float64 share the `num` type; `num_type of`
distinguishes their kind. Int `+ - *` raise `value` on overflow; mixed-kind
comparison is exact. `/` returns a float; `//` floors the quotient:

```eigenscript
x is 42
x += 1
print of x
print of (7 / 2)
print of (7 // 2)
```
```output
43
3.5
3
```


Empty `min`/`max` raises `value` in both call forms (R1.6b-D2); empty
`sum` remains int zero (C2). `sign_extend` reads exact int64 arguments and
raises `value` if its existing subtraction underflows (R1.6b-D1).

Counts and indices are ints. `floor`, `ceil` and half-away-from-zero `round`
return an int when the result fits int64. `min`/`max` return the winning
argument with its kind; the first argument wins a tie. `num` requires a
complete numeric-literal string (N10). JSON integer text fitting int64
decodes exactly (N14).

```eigenscript
print of [num_type of (len of "abc"), num_type of (floor of -2.5)]
print of [num of "9007199254740993", num_type of (num of "3.0")]
print of [num_type of (min of [3, 3.0]), num_type of (min of [3.0, 3])]
print of (json_path of ["{\"n\":9223372036854775807}", "n"])
try:
    min of []
catch e:
    print of [e.kind, (index_of of [e.message, "min"]) >= 0]
try:
    print of (num of "12abc")
catch e:
    print of e.kind
```
```output
["int", "int"]
[9007199254740993, "float"]
["int", "float"]
9223372036854775807
["value", true]
value
```

`add`, `subtract` and `multiply` preserve exact ints for scalar operands and
for each pair of list elements, with `value` on int64 overflow. `negative`
preserves int scalar and list elements and raises at INT64_MIN. Buffer
arithmetic remains float. A buffer kernel stops at its first raised result,
releases its partial output and does not read later elements (#1417).
An all-int `sum` returns an exact int, while a
float anywhere in a nested input selects float addition for the entire
reduction. A buffer selects float addition too. An empty list's sum is int
zero, in both call forms. `sum` refuses non-finite buffer elements with a
`value` error in every strict mode (N13). In strict mode, it stops at the first NaN with a "not a number" diagnostic and sets `math_flags.invalid`; later elements are not read (#1417).

```eigenscript
exact is sum of [9007199254740993, 1]
print of [exact, num_type of exact]
mixed is sum of [9223372036854775807, 1, 0.5]
print of [num_type of mixed, mixed == 9223372036854775808.0]
print of [num_type of (sum of []), num_type of (sum of ([]))]
print of (add of [[9007199254740993, 2], [1, 3]])
try:
    negative of (-9223372036854775807 - 1)
catch e:
    print of e.kind
```
```output
[9007199254740994, "int"]
["float", true]
["int", "int"]
[9007199254740994, 5]
value
```

PostgreSQL integer columns (`smallint`, `integer`, `bigint`, `oid`) return
exact int64 values through `db_query_value`; `db_query_json` retains their
exact decimal digits (N14, Q-DB253). A `bigint` beyond 2^53 is an int,
including both int64 boundaries. `numeric` remains text, and finite real
columns returned directly remain floats. Float parameter text stays in its
existing format until R1.7. The executable DB examples and boundary assertions
in `tests/test_db.eigs` run on the server-db profile with PostgreSQL.

The HTTP shared counter `shared_incr` follows numeric `+`: two int operands
return an exact int and int64 overflow raises `value` without changing the
stored counter (A). A missing counter starts at int zero. A float operand
produces a float. The stored operand is its JSON-decoded value; existing
float text stays until R1.7, so an integer-valued float may read back as an
int during this transition. Executable shared-counter examples in
`tests/test_http.eigs` cover exact values, both overflow directions and the
next operation after a raise.

`http_post` also preserves every digit of JSON integer header values within
int64 before sending them as text (N14, B6). The executed loopback example
is `tests/phase2/builtins/builtins/http_post.eigs`.

## Functions

Python:

```python
def add(a, b):
    return a + b

print(add(3, 4))
```

JavaScript:

```javascript
const add = (a, b) => a + b;
console.log(add(3, 4));
```

EigenScript — a bare literal list after `of` is the argument list, at
every element count: `f of [a, b]` is two arguments, `f of [x]` is one.
(Parentheses always mean one argument: `f of ([x])` passes a literal
1-element list whole.) Parameters are comma-separated in `define` and in lambdas; a
missing comma (`define add(a b)`) is a parse error, not a second parameter.

```eigenscript
define add(a, b) as:
    return a + b

print of (add of [3, 4])

inc is (x) => x + 1
print of (inc of 41)
```
```output
7
42
```

## Closures: the counter

Python:

```python
def make_counter():
    count = 0
    def step():
        nonlocal count
        count += 1
        return count
    return step
```

JavaScript:

```javascript
function makeCounter() {
    let count = 0;
    return () => ++count;
}
```

EigenScript — no `nonlocal` needed: assignment is outward-mutable, so
inner functions write outer variables directly:

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
```
```output
1
2
```

## Lists: map / filter / comprehension

Python:

```python
xs = [1, 2, 3, 4, 5]
print([v * v for v in xs])
print([v for v in xs if v % 2 == 0])
print(list(map(lambda v: v * 10, xs)))
```

EigenScript — same comprehension shape; `map`/`filter` come from the
standard library:

```eigenscript
load_file of "lib/list.eigs"
xs is [1, 2, 3, 4, 5]
print of [v * v for v in xs]
print of [v for v in xs if v % 2 == 0]
print of (map of [xs, (v) => v * 10])
```
```output
[1, 4, 9, 16, 25]
[2, 4]
[10, 20, 30, 40, 50]
```

## Numeric arrays: the list is not the fast container

Python separates a `list` of boxed objects from a NumPy array of raw doubles,
and you pick one per use. EigenScript draws the same line between `list` and
`buffer` — and `zeros of n` hands you the flat one, because numeric code
reaches for that name first (#1093).

Python:

```python
import numpy as np
z = np.zeros(4)              # flat float64 array
z[1] = 2.5
print(type(z).__name__, z.sum())
xs = [0] * 4                 # a boxed list, when you want one
print(type(xs).__name__, sum(xs))
```

EigenScript — no import, and every tensor builtin takes either container:

```eigenscript
z is zeros of 4
z[1] is 2.5
print of (type of z)
print of (sum of z)
xs is [0 for i in range of 4]
print of (type of xs)
print of (sum of xs)
```
```output
buffer
2.5
list
0
```

`zeros of [rows, cols]` still builds the nested list (the 2-D tensor form);
`buffer of [rows, cols]` and `reshape of [buf, rows, cols]` build the
flat-backed matrix. `matmul`, `softmax`, `sum`, `mean`, `norm`, `gather` and
the rest accept either, and hand back a buffer when every operand was one.
`matmul`, `matmul_at`, and `matmul_bt` round each multiplication to binary64
before adding it to the accumulator, in ascending inner-index order, on both
containers. They do not fuse the multiplication and addition.
Raw non-finite results may remain in a buffer's internal work area, but every
ordinary indexed read applies EigenScript's numeric guard: infinity saturates at
±`1e308`, and a NaN raises in strict mode (or becomes `0` and sets the invalid
math flag under `EIGS_STRICT=0`). `sum`, `get_at`
instead refuse non-finite buffer elements in every strict mode (N13).
Structural buffer equality and the remaining scalar reductions normalize each
input before comparison or arithmetic; the reduction
association contracts remain unchanged. Mixed buffer/list tensor operations and
numeric byte/sample/device conversions also normalize reads and stop on the
first error. Numeric bytes truncate and wrap modulo 256 after normalization.
Raw copies, typed serialization and buffer-only work areas preserve their data.
`type_mismatch` error by default; `EIGS_STRICT=0` retains numeric-zero
substitution. `str_from_bytes` stops at numeric NUL and does not inspect later
elements, while compression codecs consume and validate the complete list.

One place EigenScript is louder than NumPy: an out-of-range index in `gather`
**raises** rather than answering a stand-in, on both containers — NumPy's
`np.take` raises too, while a fancy-indexed read with an out-of-range entry is
an `IndexError` there as well, so this matches. It is `gather`'s own history
that changed: the list form used to answer `0.0` (#973/#1093).

Fixed- or optional-shape builtin argument lists reject surplus outer elements in strict mode with a catchable `type_mismatch` error naming the builtin and maximum width. The check precedes the call's mutation, I/O and tape effects. `EIGS_STRICT=0` keeps each builtin's legacy result, including existing null/error stand-ins. Scalar overloads, lists used as data and genuinely variadic arguments keep their documented meaning.

## Dictionaries / objects

JavaScript:

```javascript
const user = { name: "Ada", year: 1815 };
user.field = "computing";
console.log(user.name, Object.keys(user).length);
```

EigenScript — dot access and bracket access are interchangeable
(keyword-named fields too: `d.loop`, `d.when` — like JavaScript member
access, the position disambiguates); assignment creates keys:

```eigenscript
user is {"name": "Ada", "year": 1815}
user.field is "computing"
print of user.name
print of (len of (keys of user))
```
```output
Ada
3
```

`store_get`, `store_delete`, and `store_update` accept string keys or exact
int64 numeric keys. Integral floats convert; fractional or out-of-range floats
raise `value` before lookup or mutation. Numeric keys retain all int64 digits.
Stored decimal integer text within int64 decodes as an int; a decimal point or
exponent selects a float. Buffer payloads remain floats. Float persistence keeps
its existing text format until R1.7, so a whole float such as `3.0` may read back
as an int during this transition.

See the [stored-record example](SPEC.md#stored-records) for an exact key above
2^53 and a fractional-key refusal.

## Pattern matching

Rust:

```rust
match code {
    200 => println!("OK"),
    404 => println!("Not Found"),
    _   => println!("other"),
}
```

EigenScript:

```eigenscript
code is 404
match code:
    case 200:
        print of "OK"
    case 404:
        print of "Not Found"
    case _:
        print of "other"
```
```output
Not Found
```

## Error handling

Python:

```python
try:
    raise ValueError("boom")
except Exception as e:
    print(f"caught: {e}")
```

EigenScript — `throw of` raises, `catch name:` binds. A thrown value
binds unchanged; a built-in runtime error binds a `{kind, message,
line}` dict with `kind` from a closed vocabulary (no exception
hierarchy — discriminate on the kind string):

```eigenscript
try:
    throw of "boom"
catch e:
    print of f"caught: {e}"

try:
    x is [1] - 1
catch e:
    print of f"caught: {e.kind} at line {e.line}"
```
```output
caught: boom
caught: type_mismatch at line 7
```

The optional model extension also uses catchable `value` errors for context
limits: `eigen_generate` and `eigen_eval_loss` reject prompts longer than the
loaded model's `max_seq_len`, while `native_train_step_builtin` checks the
combined input and output length. This refusal applies even with
`EIGS_STRICT=0`; context truncation is the caller's explicit choice.

## Pipes (vs Lisp threading / shell pipes)

Clojure:

```clojure
(-> 5 double inc)   ; threading macro
```

EigenScript — `|>` is built in:

```eigenscript
double is (x) => x * 2
inc is (x) => x + 1
print of (5 |> double |> inc)
```
```output
11
```

## Concurrency

EigenScript's trace replay identifies script workers by their parent and that
parent's spawn occurrence. Independent embedding threads use host-provided
stable keys; matching does not depend on first-event scheduling. Unbound replay
calls raise instead of borrowing another thread's nondeterministic values.
The tape association contract is documented in `docs/TRACE.md`.
Replay session changes require an explicit quiescent host advance, which refuses
while a sibling has an unread outcome. Memory replay suspends and restores the
file source's cursor, pending outcomes, correspondence and strictness together.
Replay refuses host effects it cannot reconstruct: `mktemp`, for example,
raises at the filesystem boundary before creating a file, while ordinary calls
retain their create-and-return-path behavior.

Python (threads + queue):

```python
import threading, queue
q = queue.Queue()
threading.Thread(target=lambda: q.put(21 * 2)).start()
print(q.get())
```

EigenScript — `spawn` + channels:

```eigenscript
ch is channel of null
spawn of [(v) => send of [ch, v * 2], 21]
print of (recv of ch)
```
```output
42
```

Channel messages and joined/task results deep-copy ordinary values, including
buffers and text builders. Closures keep their captured environment by
reference, and resource handles still name shared process state; the executable
kind table and graph-depth limits are in `docs/CONCURRENCY.md`.

One difference in failure: a Python thread's uncaught exception is printed
and the process still exits 0. A `spawn`ed EigenScript worker that dies of
an uncaught error and is never joined fails the whole run (exit status 1) —
the exit status an unjoined cooperative task gets, including one created on
a spawned worker thread (see SPEC.md "Concurrency").
A joined worker hands its error to the joiner instead: `thread_join`
re-raises it, so catching that raise observes the failure and the run exits
0, as with `task_join`; left uncaught, it ends the joiner like any uncaught
error.
A *detached* cooperative task goes further, like a goroutine's panic in Go:
nothing can ever join it, so its uncaught error stops the program at once
(`docs/CONCURRENCY.md`, #1736).
A worker's `exit of N` requests an uncatchable stop of the whole state:
blocked concurrency calls wake, and VM threads unwind when they observe the
request at a loop back edge or builtin return. The first request sets the
process status. Teardown retains workers until native I/O or host callbacks
return; those calls are not asynchronously cancelled. An embedded worker keeps
the stop scope of its spawning eval, isolated from later outer evals.
Cooperative task IDs are opaque numeric handles: their packed generation
prevents a detached task's recycled slot from naming a later task.

## Convergence loops: boilerplate you stop writing

Before the metaphysics, the everyday win. Every numeric fixed-point loop in
Python or JavaScript hand-rolls the same three things — and beginners get them
wrong: an **epsilon threshold**, a way to **remember** the previous value(s),
and a **max-iteration guard** so a non-converging loop doesn't hang.

```python
# Python: the epsilon, the remembering, and the guard are all yours
def newton_sqrt(n, eps=1e-12, max_iter=1000):
    guess = n / 2 or 1.0
    for _ in range(max_iter):            # max-iter guard, by hand
        nxt = (guess + n / guess) / 2
        if abs(nxt - guess) < eps:       # epsilon threshold, by hand
            return nxt
        guess = nxt                      # remember the last value, by hand
    return guess                         # ...and hope it converged
```

EigenScript watches every value settle for you, so the loop *is* the
convergence test — no epsilon, no remembered previous, no guard:

```eigenscript
define newton_sqrt as:
    guess is n / 2.0
    if guess == 0:
        guess is 1.0
    loop while not converged:
        guess is (guess + n / guess) / 2.0
    return guess

print of ("sqrt(2) = " + (str of (newton_sqrt of 2)))
```
```output
sqrt(2) = 1.414213562373095
```

`converged` reads the loop's last-assigned value and fires once a full
window of its relative steps (`Δv` over the step's own scale, #1045 — so
the unit the value is stored in does not matter) sits under the settle
deadband — the standard mixed-tolerance stopping criterion, built in
(#861). This run exits
through the predicate itself in 13 iterations; the deadband is the
diverges ends via the observer's stall backstop with
`__loop_exit__ == "stalled"` instead of hanging or lying. (Use the loop
inside a function so it gets a fresh binding to watch — see
`examples/observer_vs_boilerplate.eigs`.) The next section is *why* this
works; you can reach for it long before you need the theory.

## What has no equivalent elsewhere: the observer

Every assignment (outside `unobserved` blocks) updates an observer
tracking the value's entropy and trend (for containers, one pass over the
value's own elements — the walk stops at a reference, so a nested container
contributes only its size term, #685). The boundary is explicit too: a
binding holding a function classifies `opaque` — a function has no content
to sample, and the observer names its blind spots (#708) rather than
reporting a band it cannot defend. (The `unobserved` boundary is about
the entropy walk only — assignments inside such a block are still counted
by `when is x` and still addressable by ordinal, #908, and a scalar's
sample still enters the value window the numeric predicates read, #1049,
because a performance annotation must not change an answer; what stays
elided is entropy/dH, so `why`/`how` and the non-numeric route can still
differ.) You can ask a variable about
itself, terminate loops on *convergence* instead of a hand-written
epsilon test, and read a variable's past:

```eigenscript
x is 10
x is 20
x is 30
print of (what is x)
print of (who is x)
print of (when is x)
print of (prev of x)

e is 5
loop while not converged:
    e is e * 0.5
print of (e < 0.001)
```
```output
30
x
3
20
true
```

The past is addressable per **assignment**, not just as a single step back —
so a loop's individual iterations stay reachable after it has finished:

```eigenscript
total is 0
for n in [5, 10, 20]:
    total is total + n
print of (what is total when 2)
print of (what is total when 3)
print of (what is total when 4)
```
```output
5
15
35
```

In Python the equivalent is a list you remembered to append to before the fact,
inside a loop you had already decided to instrument. Here the question is asked
afterwards, of a program that was not written to answer it. (Retention is
bounded — the last 256 assignments per queried binding — so this costs a fixed
amount rather than growing with the loop.)

In Python you would write the convergence loop with an explicit
threshold; in EigenScript the loop condition *is* the semantic intent:

```python
# Python: the epsilon is yours to pick, plumb, and tune
while abs(e_prev - e) > 1e-9:
    e_prev, e = e, step(e)
```

```eigenscript fragment e=1.0 step='(v) => v * 0.5'
loop while not converged:    # EigenScript: the runtime watches e
    e is step of e
```

And because the measurement is already paid, a trajectory is a first-class
thing you can hand to another function — `trajectory of x` snapshots the
observer's windows into a plain dict, and `classify` reads it on the other
side of the call (no equivalent exists elsewhere; a debugger watch window
is the closest analogue, and it can't cross a function boundary either):

```eigenscript
define diagnose(t) as:
    return classify of t

r is 1.0
i is 0
loop while i < 40:
    r is r * 2.0
    i is i + 1
print of (diagnose of (trajectory of r))
```
```output
diverging
```

One difference to carry across when you port numeric code: EigenScript has
no `Infinity`, so an overflow that Python would show you as `inf` saturates
at `±1e308` instead (see [SPEC.md](SPEC.md), *Numbers*). A clamped value
stops moving, which would make a runaway look like the calmest possible
trajectory — so the observer treats the ceiling as evidence of divergence,
not of rest (#861). Keep the runaway above going and the verdict holds:

`report` and `report_value` are reserved observer forms: unlike ordinary
functions in Python or JavaScript, they cannot be rebound or passed as values.
Their `of` operand must be a variable name (parentheses allowed); other operands
and all binding attempts fail before the source unit runs with `E005`.

```eigenscript
r is 1.0
i is 0
loop while i < 2000:
    r is r * 2.0
    i is i + 1
print of (report of r)
print of (converged of r)
```
```output
diverging
false
```

## Before / after: porting checklist

Transformations you will apply constantly when porting Python code:

| Python | EigenScript | why |
|---|---|---|
| `x = v` | `x is v` | assignment keyword |
| `f(a)` | `f of a` | application keyword |
| `f(a, b)` | `f of [a, b]` | bare literal list = argument list |
| `f([a])` (pass a 1-element list) | `f of ([a])` | parentheses = one argument |
| `True` / `False` / `None` | `true` / `false` / `null` | `bool` is not a number: `true + 1` and `true == 1` raise |
| `x ** y` | `pow of [x, y]` | `^` is XOR |
| `len(x)` | `len of x` | builtin, same name |
| `xs.append(v)` | `append of [xs, v]` | builtins, not methods |
| `while c:` | `loop while c:` | loop keyword |
| `def f():` body using `nonlocal` | plain `is` | assignment is outward-mutable |
| `d["k"]` / `d.get("k")` | `d.k` or `d["k"]` | dot works on any dict |

A worked port — Python before:

```python
def word_lengths(words):
    out = {}
    for w in words:
        out[w] = len(w)
    return out

print(word_lengths(["ada", "grace"]))
```

EigenScript after:

```eigenscript
define word_lengths(words) as:
    out is {}
    for w in words:
        out[w] is len of w
    return out

print of (word_lengths of (["ada", "grace"]))
```
```output
{"ada": 3, "grace": 5}
```

(Note the `of (["ada", "grace"])` — parenthesised: parentheses always
make the argument a single value, so the literal list arrives whole. A
bare `of ["ada", "grace"]` would also work here — two arguments to a
one-parameter function pack back into a list — but the parenthesised
form says "one list" directly and works for any arity.)

## File loading and block scope

Unlike a working-directory-based include path, EigenScript resolves imports
and loads from the file containing the call, then the `eigs_modules` walk,
then the nearest `eigs.json` project root, then stdlib locations. Absolute
paths are used as-is. There is no process cwd search; the REPL (including piped
input) and the embed API without a file path use their working directory as the
containing directory. A function retains its defining file's directory through
`eval`, including calls made while another module is being imported or an
embedding host is executing `eigs_eval_file`. The complete chain is in
[SPEC, Modules](SPEC.md#modules).

Main, import and load_file share these rules: a `for` binder is loop-scoped
and never writes an outer binding. Plain `is` in its body updates the nearest
existing binding, including a loop-local; otherwise it creates a binding in
the enclosing scope, like other blocks. In an imported module this search
stops at the module boundary, preserving the importer's bindings. Top-level `return` ends the file:
load_file yields its value, import finishes its namespace, and main discards
its value.

There is no function-scope exception (#1105): a binder with no prior binding
inside a function is loop-scoped like any other, so reading it after the loop
raises `undefined variable` on every road (Python, by contrast, leaks the
loop variable into the enclosing function). A pre-existing parameter, `local`
or module binding is restored after the loop.

```eigenscript
define probe() as:
    for z in [7, 8]:
        0
    return z
try:
    print of (probe of [])
catch e:
    print of e.message
```
```output
undefined variable 'z'
```

An imported module's namespace is a **live view** of that module's
bindings, the way Python's module objects are — `m.x` reads the current
binding and `m.x is v` writes it, for a number or string exactly as for
a dict. It is not a copy taken at import time, so no "box your module
state in a container or importers go stale" rule exists (#1057):

```eigenscript
write_text of ["cmp_live.eigs", "seen is 0\ndefine tick() as:\n    seen is seen + 1\n"]
import cmp_live
cmp_live.tick of null
print of cmp_live.seen
if file_exists of "cmp_live.eigs":
    remove_file of "cmp_live.eigs"
```
```output
1
```

The namespace is still an ordinary dict, so `keys`, `values`, `len` and
indexing work on it — closer to a Lua module table than to a Rust `mod`,
which has no runtime value at all.

Builtin names inside a module are isolated the way Python's are: a Python
module's `len` is unaffected by `__main__` rebinding `len`, and an
EigenScript module's `len`, `str` or `append` is the builtin unless the
module itself rebinds it (#1388). Unlike Python, a name the module does not
bind and that is not a builtin still resolves to the importer's globals.

<!-- Embed contract: #1038/#1028; language-level observer semantics unchanged. -->
The C embedding API starts observer recording open. Source evals retain
cross-unit history by default; hosts may explicitly promise isolated observer
use with `eigs_set_eval_observer_isolated`. Missing history then raises
conservatively instead of answering a rest value. See the
[embedding observer contract](EMBEDDING.md#observer-contract-1038--1028).

### HTTP startup and response attribution

With the HTTP extension, `http_early_bind of port` (or `of null`) listens
while initialization continues, answering 503 with `Retry-After: 1`.
`http_early_bind of [port, "/livez"]` explicitly opts one exact GET/HEAD
request target into liveness 200s; `http_serve` then hands every path to the
normal router. Readiness must check the actual routed resource.
`http_response_header of ["X-Eigen-Release", "build-id"]` before serving
attaches that field to every response, including startup and static files.
Header names/values are validated and a rejected registration prevents server
startup. See [HTTP builtin rules](BUILTINS.md#optional-http-extension) for the full
limits and reserved names (#1128, #1129).
Routes and the static root are fixed once `http_serve` starts: `http_route`,
`http_route_authed` and `http_static` then raise, including from a `code`
route, and an uncaught error in a `code` route's source answers 500 with a
generic body; the error message goes to the server's stderr only (#1140).
