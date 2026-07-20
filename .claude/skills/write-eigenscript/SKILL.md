---
name: write-eigenscript
description: Use when writing or generating EigenScript (.eigs) source code — in any repo of the ecosystem (EigenScript itself, ouroboros, or a consumer project like a port/lab). Captures the call syntax, the single-element-list spread trap, reserved/soft keywords, the outward-mutable scope model and when to use `local`, and the observer/temporal idioms. These are the mistakes that produce silent-wrong or undefined-variable bugs, and they are NOT loaded outside the EigenScript repo itself.
---

# Writing EigenScript (.eigs)

The error-prone parts of the language. Most are not surfaced when working in a consumer repo (the EigenScript runtime's CLAUDE.md isn't loaded there).

## One statement per line (enforced since v0.23.0)
- Leftover tokens after a complete statement are a **parse error** ("one
  statement per line"). Before v0.23.0 they silently ran as a second
  statement — the killer case was the typo `throw "boom"` (missing `of`),
  which silently disabled error handling. **Raising is `throw of value`**
  (`throw` is a builtin, not a keyword).
- `break`/`continue` with no enclosing loop are **compile errors** (they
  were silent no-ops). A module-level `return` ends the program (exit 0,
  value discarded).

## Calls — `of`, never `f(x)`
- Apply with `of`: `print of x`, `sqrt of x`, `len of xs`.
- Multi-arg passes a list: `f of [a, b]` spreads to `f(a, b)`.
- **One rule since #405 (post-v0.26.0 main): a bare literal list after `of` is ALWAYS the argument list, at every count** — `f of [x]` is ONE argument (x itself, not a 1-element list), so `fib of [n - 1]` just works, defaulted params and all. To pass a literal 1-element list whole, parenthesize: `f of ([x])`. Lint W017 flags the bare 1-element form. **On a v0.26.0-or-earlier PIN the old trap still holds**: `f of [x]` binds the whole list to the first parameter — use `f of (x)` for one argument there; `f of ([x])` means the same thing under both rules.
- **Parentheses always mean one argument** (since the #355 fix, post-v0.23.0): `f of ([a, b])` binds the literal list whole — the escape hatch for passing a literal 2+-element list to a multi-param function. `f of ([])` is a one-argument empty-list call; bare `f of []` is the zero-arg form. On a v0.23.0-or-earlier pin, `f of ([a, b])` still SPREADS (parens were transparent) — bind to a variable first on old pins.
- `of` binds tighter than infix arithmetic: `sqrt of x + 1` is `(sqrt of x) + 1`; `len of xs - 1` is `(len of xs) - 1`. Parenthesize when you mean otherwise: `sqrt of (x + 1)`.

## Reserved and soft keywords
- `in` is reserved — never a variable name.
- `prev`, `at`, and the six question words (`what who when where why how`) are **soft**: usable as ordinary identifiers (assignment, `local`, params, loop vars, catch names, compound assign) — EXCEPT a bare `what is e` is the interrogative form, so you can NEVER bind a question word with plain `is` (`how is 7` is a silent interrogative no-op, not an assignment — question-word variables only come into existence as params/loop vars/catch names; `what += 1` on an existing one is fine). `prev of x` and `what is x [at line]` are the special forms. Since v0.23.0 the identifier fallbacks take full postfix (`prev[0]`, `at.k`).
- Observer predicates (`converged stable improving diverging oscillating equilibrium`) are **reserved** bare keywords — not usable as identifiers.
- Still: prefer not naming variables after any keyword.

## Scope — outward-mutable; use `local` in library functions
- `name is expr` **updates an existing OUTER binding** if one exists up the scope chain (it mutates the caller's variable), and only creates a new binding if none exists. **Inside a library/helper function, use `local name is expr`** so you don't clobber a caller's same-named variable. `local` is order-sensitive: it binds from its declaration onward.
- **Module functions never write the loader's globals** (#373 fix, post-v0.23.0): a `load_file`'d/imported module function's bare assignment to a non-local name creates a fresh local — reads and calls still cross the boundary, and dict/list FIELD writes are value mutations that cross too. Cross-file shared state goes in a dict (the stdlib UI toolkit's `_ui` is the reference pattern). On a v0.23.0-or-earlier pin the old behavior is load-order-dependent (a caller global declared BEFORE the load IS clobberable) — the `local` discipline is the defense that works on every pin. Two `local` traps a mechanical pass misses: **sibling if-branches** (a `local x` in one branch never executes when a sibling branch runs — each branch's first assignment needs its own `local`), and first-assignments inside a `loop while` body.
- `if` blocks do NOT create a scope (assignments leak to the surrounding scope). `for` loops DO (a name assigned only inside a `for` body is loop-local and does not leak; the loop variable does not leak). **Comprehension variables DO leak** to the surrounding scope.
- The outward mutation is also a deliberate **idiom**: a module-private helper `define` can update several of its caller's module bindings in one call by plain `name is expr` (no return-and-reassign needed) — e.g. a UI helper that sets its caller's focus/drag/offset state. Fine when the helper is module-private and the mutation is its documented job; use `local` for everything else in its body.
- A no-argument `define f as:` has an implicit parameter `n` — a body reference to `n` is that param, not an outer `n`.

## Observer & temporal idioms
- Bare predicates read the **last-observed** variable; an intervening assignment repoints that alias, so `report`/predicate after unrelated work may read the wrong var. Observer dH/entropy state is keyed to the **Value object**, not the variable name — a temp-built or aliased iterate loses its trajectory. For a stable observed variable use an equilibrium/debounce idiom or force a fresh value (`x is expr + 0.0`).
- Wrap hot loops in `unobserved:` to suppress per-assignment observer bookkeeping when you don't need convergence tracking — it's a large speedup and avoids cross-talk halting.
- Temporal reads: `prev of x` (value before the most recent assignment), `what is x at L` / `state_at of L` (past-line state; **bare `x at L` is a parse error** — `at` only qualifies an interrogative or `prev of`), interrogatives `what/who/when/where/why/how is x`. An interrogative used as a *statement* prints nothing — it's an expression like any other; `print of (what is x)` to see it.
- `converged` requires LOW absolute entropy on top of a settled dH-window (`h_low`, default 0.1): a variable pinned at `5.0` reports `stable`, never `converged`; pinned at `0.0`/`1.0`/`100.0` it converges. Pick the predicate by the lattice, not intuition (docs/PREDICATES.md).

## Values
- `+` concatenates **strings only** — list concat is `append of [xs, v]` (in place) or a comprehension; `xs + ys` is a runtime error.
- Numbers are finite by construction: NaN collapses to `0`, overflow saturates at ±1e308 (`sqrt of -1` is `0`, not an error).
- **Hex integer literals** (`0xFF`, `0X10`; digits only, ends at the first non-hex char) are a real lexed form since #378 (post-v0.24.0); hex-FLOAT forms (`0x1p4`, `0xA.8`) are loud parse errors. **On a v0.24.0-or-earlier pin hex is a strtod accident**: it works HOSTED (including hex floats) but the freestanding profile lexes `0xFF` as `0` + identifier `xFF` — don't use hex in code that must run freestanding on an old pin. No modulo keyword — the operator is `%` (`mod` is a parse error).

## Strings
- f-strings interpolate: `f"step {i}: {report of x}"`. `\n`, `\t`, `\r`, `\\`, `\"`, `\{`, `\}` are escapes. Whitespace inside `{ ... }` and braces inside nested string literals are fine since v0.23.0.

## Before hand-rolling a helper
The runtime has ~255 builtins and `lib/` is ~75 modules — it covers more
than you think. **Start at the task-oriented "I need X" index shipped with
docs/STDLIB.md** (statistics -> lib/stats, tables/CSV/group-by -> lib/data,
distributions -> lib/probability, matrices -> linalg/tensor, locks ->
lib/sync, sorting/dedup -> sort/set...). Builtins:
`ord`/`chr`/`str_lower`/`str_upper`/`char_at`/`index_of`/`hex of [n, nibbles]`
all exist (there is NO bare `lower` — it's `str_lower`); lib has
`string.pad_left`, `format.fmt_*`, `checksum.crc32/adler32`, and datetime's
pure civil-date math (`days_from_civil`/`epoch_from_civil` — no host clock
needed). Check the index, then `grep define lib/<area>.eigs` and builtins.c's
pure-names list before writing a helper. The hand-roll hall of shame — each
written downstream while sitting in the stdlib: hex formatting (twice),
zero-padding (twice), and **median/mean** (a consumer's piano-roll UI, while
`lib/stats.eigs` shipped both). If you catch yourself defining `mean`,
`clamp`, `median`, a log base, or a checksum: stop and look first. Note
`lib/datetime.eigs` is two halves — the clock functions shell out to
`date` (host-only); the civil-math half runs on every profile.

## Before trusting generated .eigs
Run it: `eigenscript prog.eigs`. The common failure signatures are **"undefined variable"** (a `local` you forgot, or a soft-keyword/scope surprise), **"unexpected X after statement"** (two statements landed on one line — check generated joins), and **silently wrong numbers** (on a v0.26.0-or-earlier pin, a `f of [x]` that didn't spread — one rule post-#405). For library code, parse-check with `--lint`.
