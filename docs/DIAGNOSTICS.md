# EigenScript Diagnostics

EigenScript reports errors with source line numbers and consistent
formatting. This document defines the error contract. The behaviors
here are enforced by the suite (`run_all_tests.sh` EM1–EM30 and
`examples/errors/`).

## Error Categories

| Category | Format | Exit Code | Behavior |
|----------|--------|-----------|----------|
| Syntax error | `Syntax error line N: ...` | 1 | Tokenizer problem. Accumulates all errors, aborts before execution. |
| Parse error | `Parse error line N: ...` | 1 | Parser problem. Accumulates all errors, aborts before execution. |
| Runtime error (uncaught) | `Error line N: ...` + stack trace | 1 | Type mismatch, undefined variable, index out of bounds, non-callable, uncaught `throw`. Prints to stderr and **halts** — no statement after the error runs. |
| Runtime error (caught) | `{kind, message, line}` dict bound to the `catch` variable | — | Recoverable with `try`/`catch`; execution continues in the handler. `kind` is from the closed set below. |
| Warning | `Warning line N: ...` | 0 | Recoverable issue (division by zero yields `0`). Prints to stderr, continues execution. |
| Assertion | `Error line N: ASSERT FAIL: ...` | 1 | `assert` failure — an ordinary runtime error with kind `assert` (catchable). |

Parse errors prevent execution entirely — the program never runs if
parsing fails. Warnings allow execution to continue; **uncaught runtime
errors do not** — they halt with exit 1 so scripts fail loudly for
callers, Makefiles, and CI.

## Stack traces

An uncaught runtime error (or uncaught `throw`) prints, to stderr: the
error line, a one-line source excerpt with a `^` caret under the
offending column (#407 residual — same format as parse errors), then
the call stack — every frame between the failure and the top level,
innermost first:

```
Error line 6: index 99 out of range (list length 2)
     6 | v is items[99]
       |           ^
  at inner (line 6)
  at middle (line 8)
  at <module> (line 9)
```

The excerpt block is additive: the `Error line N: ...` message and the
`  at fn (line N)` trace lines are byte-unchanged, so tools that match
on them keep working. The caret is suppressed (message + trace only)
when the failing position can't be attributed confidently — e.g. inside
JIT-compiled loops or when the unit's source isn't available.

Caught errors print nothing; the handler decides.

## What `catch` binds

- A **built-in runtime error** binds a `{kind, message, line}` dict
  (#406): `kind` from the closed vocabulary below, `message` without
  the `Error line N:` frame (`"cannot apply '-' to list and num"`),
  `line` 1-based. Discriminate on `kind`, never on message text —
  messages are wording, kinds are contract.
- A **thrown value** binds unchanged: `throw of {"kind": "validation"}`
  gives the catch variable that dict — match on fields instead of
  substring-searching a message. Thrown strings bind as strings.

## Runtime error kinds (closed set)

Every built-in runtime error carries exactly one kind. The set is
CLOSED by design — the same instinct as the closed trajectory
vocabulary. Extending it is a SPEC + DIAGNOSTICS change, not a
patch-release tweak. (`ErrKind` in `src/eigenscript.h`; the strings
below are the contract.)

| kind | meaning | examples |
|------|---------|----------|
| `undefined_name` | no binding for a name | `undefined variable 'x'` |
| `type_mismatch` | operation/argument of the wrong type | `cannot apply '-' to list and num`, `bit_not expects a number` |
| `value` | right type, unacceptable value | `index must be an integer, got 1.5`, `chr of 0`, invalid channel |
| `index_range` | index/slice outside bounds | `index 10 out of range (list length 3)` |
| `parse` | runtime-surfaced parse/compile failure | `eval: parse error in code string`, `import: parse errors in 'm'` |
| `io` | the outside world failed | `import: cannot read 'm'`, `store_open: cannot create`, thread-create failure |
| `limit` | engine resource cap hit | `call stack overflow`, `store_put: record too large`, route table full |
| `sandbox` | sandbox policy denial or budget | `blocked in sandbox`, `sandbox memory budget exceeded` |
| `interrupt` | host-requested abort (`eigs_abort`) | `aborted` |
| `assert` | `assert` builtin failure | `ASSERT FAIL: ...` |
| `deadlock` | #408 all cooperative tasks blocked, none runnable | `all tasks are blocked — deadlock` |
| `internal` | VM invariant broke — report it | `unknown opcode`, `SET_LOCAL slot out of range` |

`throw` stamps kind `user` for host/embed introspection
(`eigs_last_error_kind`), but a catch never sees it — the thrown value
itself binds. `sandbox_run` reports failures with the same shape: its
result dict gains `"error": {kind, message, line}` when `ok` is 0.

## Exit Codes

| Situation | Exit Code |
|-----------|-----------|
| Successful execution | 0 |
| File not found | 1 |
| Syntax / parse errors | 1 |
| Uncaught runtime error or `throw` | 1 |
| Unjoined task dies of an uncaught error (fire-and-forget) | 1 |
| Assertion failure | 1 |
| Errors caught by `try`/`catch` | 0 |
| Warnings only | 0 |

## Examples

### Parse error — aborts before execution
```
$ cat bad.eigs
if x > 0
    print of x

$ eigenscript bad.eigs
Parse error line 1:9: expected ':', got newline
     1 | if x > 0
       |         ^
1 parse error(s) — aborting
$ echo $?
1
```

Column-carrying parse errors print a one-line source excerpt with a caret
under the offending column (#407). The excerpt lines are additive — the
`Parse error line N:C: ...` message itself is byte-unchanged, so tools that
match on it keep working. Errors without a tracked column (deep-nesting
caps, size limits) print the message only.

### Uncaught runtime error — halts with a trace
```
$ cat type_err.eigs
x is [1, 2, 3]
y is x - 5
print of "reached"

$ eigenscript type_err.eigs
Error line 2: cannot apply '-' to list and num
     2 | y is x - 5
       |        ^
  at <module> (line 2)
$ echo $?
1
```
(`"reached"` does **not** print.)

### Caught runtime error — execution continues
```
$ cat caught.eigs
try:
    y is [1] - 5
catch e:
    print of "recovered"
print of "reached"

$ eigenscript caught.eigs
recovered
reached
$ echo $?
0
```

### Warning — returns a fallback value and continues
```
$ cat div_zero.eigs
result is 10 / 0
print of result

$ eigenscript div_zero.eigs
Warning line 1: division by zero
0
$ echo $?
0
```

## Runtime Error Types

| Error | Trigger | Example |
|-------|---------|---------|
| `cannot apply 'OP' to T1 and T2` | Binary operator on incompatible types | `[1,2] - 5` |
| `undefined variable 'NAME'` | Using a name that hasn't been assigned | `print of x` (never defined) |
| `index N out of range (list length M)` | List/string/buffer index outside bounds | `items[10]` on a 3-element list |
| `index must be an integer, got X` | Fractional index (use `floor of`) | `items[2.5]` |
| `'for' requires a list, got T` | For loop over non-list value | `for i in 42:` |
| `cannot call T (not a function)` | Using `of` with a non-function | `5 of 10` |
| `cannot negate T` | Unary minus on non-number | `-"hello"` |
| `cannot index T` | Indexing a non-list/non-string | `42[0]` |
| `import: module 'M' not found (tried lib/M.eigs and M.eigs)` | Missing stdlib/user module | `import nope` |
| `division by zero` | Dividing or modulo by zero | `10 / 0` (warning, returns 0) |

Numeric overflow and invalid math domains are not diagnostics. They are
handled by the finite-number invariant: `NaN` -> `0`, overflow/Inf ->
`+/-1e308`, and selected functions clamp their domains.

## Builtin Errors

Builtin functions report errors without line numbers (the error is in the
builtin's domain, not at a specific source location):

```
Type error: json_decode requires a string, got num
load_file: cannot read 'missing.eigs'
```

## Informational Messages

Diagnostic messages use bracketed prefixes and are not errors. They are
**off by default** (#560 — a shipped CLI must be able to keep stderr clean;
no successful builtin announces itself). Set `EIGS_VERBOSE_LOAD=1` to enable
the `load_file` banner during development:

```
[load_file] Loading lib/math.eigs (1301 bytes)
```

## Diagnostic codes

Every diagnostic has a **stable code** so tools can match on it without
substring-parsing the human message. The code namespace is a contract:
a code's meaning never changes, and retired codes are not reused.

| Code | Severity | Meaning |
|------|----------|---------|
| `E000` | error | File cannot be read (lint). |
| `E001` | error | *Reserved* — tokenizer/syntax error. Not currently emitted: lexer-level failures surface through the parser as `E002`. The code is held so `E002` keeps its meaning if a distinct tokenizer diagnostic is added later. |
| `E002` | error | Parse error (parser). `--lint --json` reports the first one. |
| `E003` | error | Undefined name — **no binding on any path** (#404). A name is read somewhere but bound nowhere: not by any assignment in any scope, not a parameter/binder (function/lambda params, `for`/comprehension variables, `catch` names, list-pattern names, `import` module names), not a builtin, and not a top-level name of a file pulled in by a literal `load_file` (resolved with the runtime's own resolution chain, transitively). The runtime raises `undefined variable` the moment such a path executes; `E003` surfaces it statically, including on cold branches. See "Name resolution (`E003`)" below for the exact model and escapes. |
| `E100` | error | Uncaught runtime error (category code; see note below). |
| `W001` | warning | Unused variable. |
| `W002` | warning | Unused function parameter. |
| `W003` | warning | Unreachable code after `return`. |
| `W004` | warning | Empty `if` block. |
| `W005` | warning | Empty loop block. |
| `W006` | warning | Empty `for` block. |
| `W007` | warning | Empty function body. |
| `W008` | warning | Empty `try` block. |
| `W009` | warning | Empty `catch` block. |
| `W010` | warning | Duplicate dict key. |
| `W011` | warning | `name is ...` used in a condition (likely meant `==`). |
| `W012` | warning | Assignment shadows a builtin. The builtin set is derived from `register_builtins()` itself plus the extension names (`ext_names.h`) — never a hand list (#459: the old hand-copied array was ~120 names behind the binary, so shadowing `dispatch`, `chr`, `eval`, … lint'd clean). |
| `W013` | warning | Function definition shadows a builtin (same registry-derived set as `W012`). For the observer special forms (`report`, `report_value`, `observe`) this warning is load-bearing: their name-keyed forms are compiler-resolved and a rebinding does NOT change them (#459) — the shadowing function is only reachable through non-ident argument forms. |
| `W014` | warning | Bare trajectory predicate in a loop condition reads the last-observed binding, but the body assigns two or more bindings — name it (`<predicate> of <var>`). |
| `W015` | warning | A function assigns (without `local`) over a module-level **function** name, clobbering it via mutate-outward so later `<fn> of ...` calls fail — add `local` or rename. (Scoped to function clobbering; benign module-variable reuse is not flagged — that is #404's dataflow-aware territory. `_`-prefixed names are skipped as intentional module state.) |
| `W016` | warning | Bare trajectory predicate **outside a loop condition** (`if stable:`, `ok is converged`, `return diverging`) reads the last-observed binding — an invisible alias (#247/#262) — write `<predicate> of <var>`. Loop conditions are exempt: the single-assign `loop while not converged` form is the documented idiom, and the ambiguous multi-assign case is `W014`. Any explicit subject counts as named, including `stable of (x + 0.0)`; deliberate bare reads carry `# lint: allow W016`. |
| `W017` | warning | Bare 1-element literal arg list: `f of [x]` passes **one argument** — the element, not the list (#405; the pre-#405 rule meant the opposite, so the form reads ambiguously). Write `f of x` for one argument, or `f of ([x])` (#355) to pass a 1-element list. Doubles as the #405 migration audit: `--lint` over a consumer repo surfaces every behavior-changed call site. |
| `W018` | warning | A `catch`-bound error's `.kind` is compared (`==`/`!=`) against a string that is a **near-miss** of a real kind — a case variant (`"IO"`) or a single-character typo (`"index_rage"`), or a kind renamed out from under the handler — so the branch is dead code that silently never fires (#469). Kinds are a closed set (below). Zero-false-positive by construction: only near-misses of a closed kind fire, and only off a catch-bound variable — an exactly-valid kind, and a genuinely custom `throw {kind: "..."}` value many edits from every builtin, both stay silent. |
| `W019` | warning | An interrogative used as a **bare statement** — `why is "..."`, `what is x`, `prev of y` at statement level — evaluates and **discards** its result: a silent no-op (#583). Question words (`what/who/when/where/why/how`) cannot be assigned with `is` — the "assignment" is the interrogative expression form — so when a same-named binding exists in scope the statement is almost certainly a mistaken assignment (the real hit: a catch handler "reassigning" a `local why` that silently kept its stale value). An interrogative inside an expression (`print of (why is x)`, `r is prev of y`) is never flagged. |
| `W020` | warning | An `unobserved:` block in which **every** assignment targets a dict field or list element (`d.k is ...`, `xs[i] is ...`) — a provable no-op (#655). Observer bookkeeping is gated on the named env path, so a dict field is never observed and there is nothing to skip; the in-place numeric mutation the block used to enable became unconditional with NaN-boxing B-3a (`dict_set_cached_immediate`), so it costs nothing to drop the block. This shape was true when written and expired silently, which is why it needs a lint — our own README shipped the dead form as its headline example for two months. Conservative by construction: `g_unobserved_depth` is a global, so a **call** inside the block runs the callee unobserved too and suppresses the warning; any plain-variable assignment, or a name-binding form (`for` / listcomp / `catch` / `match`), also suppresses it. Only a provably inert block fires. |

The human linter output carries the code inline:

```
$ eigenscript --lint app.eigs
app.eigs:2: warning[W001]: unused variable 'temp'
```

## Machine-readable output (`--json`)

`eigenscript --lint --json file.eigs` writes a JSON array of diagnostics
to **stdout** (human text and the `--version`-style banner go to stderr,
so `--lint --json 2>/dev/null` is pure JSON). Each element is:

```json
{"code": "W001", "severity": "warning", "line": 2,
 "file": "app.eigs", "message": "unused variable 'temp'"}
```

- A clean file emits `[]` (and still exits 0).
- A file that doesn't parse emits a single `E002` element built from the
  first parse error (the same one the LSP surfaces), and exits 1. The `E002`
  element carries a 1-based `"column"` (#407) alongside `"line"`; human parser
  errors show `line:col` too, and the LSP diagnostic range starts at that
  column. (Warning elements are line-only for now — per-warning spans are the
  remaining #407 work.)
- Exit code follows `--lint-level` (see below); the default fails on any
  surviving warning.

The `--json` flag may appear before or after the path. Runtime errors are
not part of `--lint` (it never executes the program).

## Severity control and suppression

By default `--lint` exits 1 on any warning, which is warnings-as-errors. Two
escape hatches let a project wire `--lint` into CI without that being all or
nothing:

- **`--lint-level error|warning`** chooses the exit-1 threshold. `warning` (the
  default) fails on any warning; **`error`** makes warnings advisory — they are
  still printed (and still appear in `--json`), but the exit code is 0 unless an
  error-severity diagnostic is present. Use `error` to surface diagnostics in CI
  without breaking the build on style warnings.

- **`# lint: allow <CODE>...`** silences specific codes inline. The comment
  suppresses the listed codes (space- or comma-separated; `all` silences every
  code) on **its own line** and **the line below it**, so it works as a trailing
  comment or on the line above the flagged construct:

  ```eigenscript
  scratch is compute of x   # lint: allow W001
  # lint: allow W001 W014
  next is other of y
  ```

  A suppressed diagnostic is removed from both the human and `--json` output.

- **`# lint: allow-file <CODE>...`** silences the listed codes (or `all`) for
  the **whole file**, in both `--lint` and the LSP. Conventionally the first
  line. This is the escape for module *fragments* — files that a loader
  `load_file`s into scope the loader provides (e.g. `lib/ui_w_*.eigs` expect
  `lib/ui.eigs` to have bound `_theme`/`_ui` first), where `E003` would flag
  every loader-bound name and per-line allows would drown the file:

  ```eigenscript
  # lint: allow-file E003 -- fragment of lib/ui.eigs: loader binds _theme/_ui
  ```

  For the `E003` fragment case specifically, prefer `# lint: loaded-by`
  (below) — it keeps undefined-name protection that `allow-file E003`
  abandons.

- **`# lint: loaded-by <relpath>`** (#460) declares this file a library
  *fragment* of the named composer. E003 collects the named file's
  **transitive binding set** (its binders, plus everything its literal
  `load_file`s bind, exactly as if linting it as an entry point) and lints
  this file against that context — so the composed-in names stop flagging
  while **a genuine typo in the fragment still fires**. The path resolves
  like a `load_file` target from the fragment's directory. The directive is
  repeatable, works in both `--lint` and the LSP, and covers both
  composition styles:

  ```eigenscript
  # lint: loaded-by ../dmg.eigs        (the entry point that load_files me)
  ```

  ```eigenscript
  # lint: loaded-by sibling.eigs       (out-of-language concat: the named
                                        file need not load me — its binders
                                        become context either way)
  ```

  Fail-open like every `E003` edge: a context file the linter cannot
  resolve, read, or parse disables the pass for the fragment (never a false
  positive).

- **Per-file allow-list in `eigs.json`** (#455) silences codes for a whole
  file **without editing the file** — the escape for generated or vendored
  modules a project should not sprinkle `# lint: allow` comments through:

  ```json
  {
    "lint": {
      "allow": {
        "lib/generated_tables.eigs": ["W003", "W015"],
        "vendor/thirdparty.eigs": ["all"]
      }
    }
  }
  ```

  Keys are paths **relative to the project root** (the directory containing
  `eigs.json`); `all` silences every code. Resolution walks up from the
  linted file to that root — the same walk the module resolver uses — so it
  applies regardless of the cwd the linter runs from. A code allowed here is
  filtered exactly like a `# lint: allow-file <code>` in the file. (`--lint`
  only for now; the in-file directives above also cover the LSP.)

## Name resolution (`E003`)

`E003` is the scope-aware name-resolution pass (#404, increments one and
two) — ROADMAP's sanctioned alternative to a type system. Its model:

- **Binding sets are scope-precise, path-insensitive** (increment two).
  The pass models the runtime's actual rules, each pinned empirically
  against the interpreter: a fresh-name `is` (or `local`) inside a
  function is function-local — invisible to siblings and module code;
  closures read enclosing function scopes; module names are
  order-insensitive (a body may read a module name bound after the
  definition); a nested `define` binds its name in the enclosing
  function only; a **module-level `for` loop-scopes its variable** (the
  VM drops it at loop exit — a function-level `for` var survives);
  listcomp and `catch` vars bind in the containing scope. Within a
  scope, "bound on some path" still suppresses (sibling-branch first
  assignments stay silent) — path-precise analysis is the remaining
  #404 increment. Over-collecting can only *miss* a bug, never invent
  one — a false positive would break consumer CI, so every
  approximation fails open.
- **Near-miss suggestions.** When an undefined name is edit-distance 1
  from a visible binding, the message appends `(did you mean 'x'?)`.
  Distance 1 only, names ≥ 3 chars — a suggestion is near-certain or
  absent.
- **Builtins come from the runtime's own registry** — the linter calls
  `register_builtins()` on a scratch environment rather than keeping a name
  list that can drift. Extension builtins (`gfx_*`/`audio_*`, `http_*`,
  `db_*`, model) bind by name regardless of the binary's build flags, from
  the same `ext_names.h` lists their registrars expand: the lint describes
  the language surface, not one build. `report_value` (a compiler special
  form) and the observed-loop bindings `__loop_exit__`/`__loop_iterations__`
  are also known.
- **Literal `load_file` is followed.** `load_file of "path"` resolves with
  the runtime's resolution chain (anchored at the linted file's directory)
  and the loaded file's top-level binders are collected transitively, so an
  entry-point file that assembles its program from parts lints clean.
- **Dynamic escape.** `eval` appearing anywhere, or a `load_file` whose
  argument is not a string literal, can bind names invisible to static
  analysis — the pass disables itself for that file. A `load_file` the
  linter cannot resolve, read, or parse also fails open.
- **Module members are not checked.** `import m` binds `m`; `m.anything` is
  a dict key, outside this pass.
- For a file that is *deliberately* a fragment of a larger program, declare
  its composer with `# lint: loaded-by <relpath>` (above) — it lints the
  fragment against the composer's binding set and keeps typo protection.
  `# lint: allow-file E003` remains the blunt escape (silences the pass
  entirely); for a single host-injected name, a per-line
  `# lint: allow E003` works as usual.

`E100` is the **category code** for an uncaught runtime error. It is
deliberately *not* injected into the `Error line N: ...` text — the
message half of that string is also the `message` field a `try`/`catch`
binds (see "What `catch` binds"), and in-language error discrimination
goes through the caught dict's `kind`, not through tag-matching text.
Tools map the `Error line N:` prefix to `E100`; the specific failure is
in the message (see "Runtime Error Types").

## Editor diagnostics

The LSP server (`make lsp` → `src/eigenlsp`) surfaces the first syntax
or parse error of each open document as a
`textDocument/publishDiagnostics` squiggle (`tests/test_lsp.py` pins the
protocol behavior). Ranges are token-precise (#407 residual): parse
errors (E002) and undefined-name errors (E003) squiggle exactly the
offending token (`start`/`end` from the token's column and length);
diagnostics without a tracked position fall back to a whole-line range.
For batch static checks, `eigenscript --lint file.eigs` runs the linter
and `eigenscript --fmt` the formatter.
