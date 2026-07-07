# EigenScript Diagnostics

EigenScript reports errors with source line numbers and consistent
formatting. This document defines the error contract. The behaviors
here are enforced by the suite (`run_all_tests.sh` EM1–EM23 and
`examples/errors/`).

## Error Categories

| Category | Format | Exit Code | Behavior |
|----------|--------|-----------|----------|
| Syntax error | `Syntax error line N: ...` | 1 | Tokenizer problem. Accumulates all errors, aborts before execution. |
| Parse error | `Parse error line N: ...` | 1 | Parser problem. Accumulates all errors, aborts before execution. |
| Runtime error (uncaught) | `Error line N: ...` + stack trace | 1 | Type mismatch, undefined variable, index out of bounds, non-callable, uncaught `throw`. Prints to stderr and **halts** — no statement after the error runs. |
| Runtime error (caught) | bound to the `catch` variable | — | Recoverable with `try`/`catch`; execution continues in the handler. |
| Warning | `Warning line N: ...` | 0 | Recoverable issue (division by zero yields `0`). Prints to stderr, continues execution. |
| Assertion | `ASSERT FAIL: ...` | 1 | Intentional termination via `assert`. |

Parse errors prevent execution entirely — the program never runs if
parsing fails. Warnings allow execution to continue; **uncaught runtime
errors do not** — they halt with exit 1 so scripts fail loudly for
callers, Makefiles, and CI.

## Stack traces

An uncaught runtime error (or uncaught `throw`) prints the call stack
to stderr after the error line — every frame between the failure and
the top level, innermost first:

```
Error line 6: index 99 out of range (list length 2)
  at inner (line 6)
  at middle (line 8)
  at <module> (line 9)
```

Caught errors print nothing; the handler decides.

## What `catch` binds

- A **runtime error** binds its message string
  (`"Error line 2: cannot apply '-' to list and num"`).
- A **thrown value** binds unchanged: `throw of {"kind": "validation"}`
  gives the catch variable that dict — match on fields instead of
  substring-searching a message. Thrown strings bind as strings.

## Exit Codes

| Situation | Exit Code |
|-----------|-----------|
| Successful execution | 0 |
| File not found | 1 |
| Syntax / parse errors | 1 |
| Uncaught runtime error or `throw` | 1 |
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
1 parse error(s) — aborting
$ echo $?
1
```

### Uncaught runtime error — halts with a trace
```
$ cat type_err.eigs
x is [1, 2, 3]
y is x - 5
print of "reached"

$ eigenscript type_err.eigs
Error line 2: cannot apply '-' to list and num
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

Diagnostic messages use bracketed prefixes and are not errors:

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

(Per-file allow-lists in `eigs.json` are not yet wired up — see #455.)

## Name resolution (`E003`)

`E003` is increment one of the scope-aware name-resolution pass (#404) —
ROADMAP's sanctioned alternative to a type system. Its model:

- **Binding set = whole-file over-approximation.** Every binder anywhere in
  the file counts (mutate-outward makes most bindings cross-scope visible
  anyway). Over-collecting can only *miss* a bug, never invent one — a false
  positive would break consumer CI, so the approximation always fails open.
  Consequently `E003` is silent on outward-`is`, `local` shadowing, and
  sibling-branch first assignments; path-precise analysis is later #404 work.
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
deliberately *not* injected into the `Error line N: ...` text, because
that exact string is also what a `try`/`catch` binds (see "What `catch`
binds") — tagging it inline would change the bound value and break the
stability contract. Tools map the `Error line N:` prefix to `E100`; the
specific failure is in the message (see "Runtime Error Types").

## Editor diagnostics

The LSP server (`make lsp` → `src/eigenlsp`) surfaces the first syntax
or parse error of each open document as a
`textDocument/publishDiagnostics` squiggle at the failing line
(`tests/test_lsp.py` pins the protocol behavior). For batch static
checks, `eigenscript --lint file.eigs` runs the linter and
`eigenscript --fmt` the formatter.
