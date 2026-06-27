# EigenScript packages — design proposal

**Status: partially implemented — this is the forward-looking design
pass; for what actually ships today see
[PACKAGE_SPEC.md](PACKAGE_SPEC.md).** The core install/lock/verify flow
landed (`eigenscript --pkg add/install/update/verify`: namespaced deps,
an `eigs.json` manifest, a lockfile pinning commit SHAs, and
tree-hash verification). This document is the broader design it grew
from; the open questions at the bottom (version ranges/solver, a
registry/index format, package signing, a dependency-audit command,
yank/deprecation policy) are still real decisions, not rhetorical ones.
As each part ships, the shipped behavior moves into
[SPEC.md](SPEC.md) and becomes subject to the stability contract.

## Goals

1. **Use someone else's EigenScript code** with a pinned, reproducible
   version — today the only options are copy-paste or a git submodule
   you manage by hand.
2. **Reproducible installs**: same project + same lockfile = same code,
   byte for byte, on any machine, offline once fetched.
3. **No code execution at install time.** Installing a package must be
   inert (fetch + checkout + hash-check). No hooks, no build scripts.
4. **No new runtime dependencies.** The interpreter stays a single
   zero-dependency C binary; everything network-ish lives in a tool.
5. **Minimal runtime surface change** — the resolver grows one search
   step and a cache; everything else is tooling and convention.

Non-goals, deliberately: a central registry (git URLs *are* the
namespace), native/C extensions in packages, build steps, and version
constraint *solving* (pin exact versions; a solver can come later if
real projects demand ranges).

## Current state (as-built, 0.13.0)

- `import name` tries `lib/name.eigs` (the stdlib), then `name.eigs`,
  each through the full resolution chain in `resolve_eigenscript_file`
  (builtins.c): cwd → `$script_dir` → `$script_dir/..` → `$exe_dir/..`
  → `$exe_dir/../lib/eigenscript` → `~/.local/lib/eigenscript`.
  Public top-level names bind into a dict named `name`; `_`-prefixed
  names stay private ([SPEC.md — Modules](SPEC.md#modules)).
- **Every `import` re-executes the module.** There is no module cache:
  two importers get two copies of the module's state, and a diamond
  (app → a → c, app → b → c) would run `c` twice with divergent state.
- Resolution is anchored to the **main script's** directory
  (`g_script_dir` is global). A module imported from another directory
  resolves *its* imports relative to the app, not itself — harmless
  today (modules sit next to the script), wrong for packages.
- `lib/name.eigs` is tried before `name.eigs`, so the stdlib shadows
  user modules of the same name — but a project-local `lib/` directory
  shadows the *installed* stdlib (the chain hits `cwd/lib/` first).
  This is how the repo runs its own tests; it's also an existing
  footgun the package design must not widen.

## Design

### Vendoring-first, git as transport

Dependencies live in **`eigs_modules/`** at the project root, one
directory per package, each a plain checked-out tree of a git repo at
a pinned commit. There is no registry: a package *is* a git URL plus a
tag, and the URL is the namespace. Committing `eigs_modules/` is
supported (Go-vendor-style, true offline builds); the lockfile makes
it optional.

### Manifest and lockfile

`eigs.json` at the project root, read **only by the tool** — the
runtime never parses it (resolution works by directory convention, so
a missing manifest never breaks `import`):

```json
{
  "name": "myapp",
  "version": "0.1.0",
  "deps": {
    "vecmath": { "git": "https://github.com/alice/eigs-vecmath", "tag": "v1.2.0" }
  }
}
```

`eigs.lock.json` records, per package: the git URL, the resolved
commit SHA, and a sha256 over the package's `.eigs` tree (sorted
paths + contents). The commit SHA gives git's integrity; the content
hash catches a force-pushed tag or a tampered mirror — same trust
posture as the release CHECKSUMS file.

JSON over TOML because `lib/json.eigs` already exists (the tool stays
dependency-free too) — and over an evaluated `.eigs` manifest because
an executable manifest violates goal 3.

A package is just a repo with `eigs.json` (name, version, its own
`deps`) and `<name>.eigs` at its root as the entry point. Transitive
dependencies are resolved by the tool into the **app's** flat
`eigs_modules/` — one version of a name per project; two pins that
disagree are an error naming both requirers, not a silent pick.

### Runtime change 1: one resolver step

`import name` gains one step. Proposed order:

1. `lib/name.eigs` — stdlib first, **unchanged**
2. `eigs_modules/name/name.eigs` — searched from the importing file's
   directory upward to the project root (so packages find *their*
   dependencies in the app's flat `eigs_modules/`)
3. `name.eigs` script-relative — unchanged

Stdlib-first means a future stdlib module can collide with an existing
package name; the tool errors at `add` time when a dep name matches a
stdlib module, and package naming guidance is "prefix it" (`alice_vec`,
not `vec`). The alternative (packages shadow stdlib) trades that
papercut for a supply-chain hole — a dep silently becoming your `math`
— and loses.

### Runtime change 2: import becomes cached and module-relative

Two prerequisites that are worth doing even if nothing else ships:

- **Module cache**: first `import` of a resolved real path executes
  the module; subsequent imports bind the same dict. Diamond deps
  share one instance of module state. The cache holds counted refs
  (Value dict + module Env) released at teardown — the closure-cycle
  collector's ownership rules apply (every edge counted, walker +
  `gc_clear_node` updated in lockstep).
- **Per-file resolution base**: an import executing inside a module
  resolves relative paths against *that module's* directory, not the
  main script's. `g_script_dir` becomes a stack (or a parameter
  threaded through the import path), with `load_file` keeping its
  current main-script-relative behavior for back-compat.

Both are observable behavior changes (re-import today re-executes;
side-effecting modules can tell) — minor-version territory with
CHANGELOG + SPEC.md updates per the stability contract.

### The tool: `eigenscript --pkg`

Written **in EigenScript** (`lib/pkg.eigs` + a `--pkg` dispatcher in
main.c next to `--fmt`/`--lint`) — dogfooding pressure on the
subprocess/string/JSON APIs is a feature. It shells out to `git` (the
one external requirement, tool-only) via the streaming `proc_*` API.

```
eigenscript --pkg add <owner>/<name> <git-url> [tag]   # manifest + fetch + lock
eigenscript --pkg install                              # reproduce eigs_modules/ from lockfile
eigenscript --pkg update [<owner>/<name>]              # re-resolve tag → new commit, re-lock
eigenscript --pkg verify                               # re-hash trees against lockfile
eigenscript --pkg list                                 # what's installed, from where
```

Package identifiers are namespaced `<owner>/<name>` from day one —
bare names like `tensor` are reserved at the manifest and CLI layers
so an early popularity spike can't fragment the namespace. The
on-disk layout (`eigs_modules/<name>/`) and `import <name>` form
stay flat for now: two packages sharing the leaf can't coexist in
the same project yet, but disk-level nesting + scoped imports can
land later without breaking any existing manifest.

Install is `git clone --depth 1` + checkout + hash — nothing from the
package is ever executed (goal 3). One caveat to respect: `proc_*` is
an unwrapped replay hole (issue #148), so `--pkg` runs outside the
trace/replay machinery entirely.

### Phasing

- **Phase 0 — runtime prerequisites** (small, independently valuable):
  module cache; per-file resolution base; the `eigs_modules/` resolver
  step. Each lands with SPEC.md examples and suite sections.
- **Phase 1 — the tool**: `--pkg` with add/install/verify/list/update,
  manifest + lockfile, docs page, and a [eigs-package-template](
  https://github.com/InauguralSystems/eigs-package-template) repo
  showing layout + semver tagging.
- **Phase 2 — ecosystem**: naming/versioning guidance in
  [CONTRIBUTING.md](../CONTRIBUTING.md#publishing-a-package), the
  [awesome-eigenscript](https://github.com/InauguralSystems/awesome-eigenscript)
  index (a list, not a registry), and — once real packages exist —
  revisit version ranges, and attestation.

## Open questions

1. **Manifest format**: JSON (proposed) vs TOML (friendlier to hand-
   editing, needs a parser the project doesn't have).
2. **Stdlib-first precedence** (proposed) vs packages-first: accept
   "new stdlib module may collide with a package name" vs accept "a
   dep can shadow `math`". Proposal picks the first.
3. **Flat `eigs_modules/`** (proposed, one version per name) vs nested
   per-package trees (npm-style, allows version skew, complicates the
   resolver and the mental model).
4. **Entry point**: `<name>.eigs` at package root (proposed) vs an
   explicit `"main"` field in the package's `eigs.json` (more flexible,
   but then the *runtime* has to read manifests).
5. Should `import` ever accept a string path (`import "vendor/x.eigs"`)?
   Proposal says no — identifiers only; paths stay `load_file`'s job.
