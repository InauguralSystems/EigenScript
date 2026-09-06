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

## Runtime resolution (shipped, #1056)

- `import name` requests `name.eigs`, then `lib/name.eigs`; project modules
  take precedence over stdlib matches and collisions warn. Public names bind
  into the module namespace. Import caching is described in
  [SPEC.md — Modules](SPEC.md#modules).
- `import` and `load_file` share `resolve_eigenscript_file_from_ex`
  (`builtins_host.c`). Absolute paths are used as-is. Relative paths search
  the containing file's directory → the `eigs_modules` walk → the nearest
  `eigs.json` project root → executable-relative and HOME stdlib roots.
  There is no process cwd or one-parent fallback. A project-local `lib/`
  can answer through the containing-directory or project-root steps before
  the installed stdlib; it does not depend on where the process was launched.
- Nested loaded files and functions called after loading retain their own
  containing directory. The REPL (including piped input) and the embed API
  without a file path use their working directory as the base.

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

### Runtime resolver: implemented order

Both loaders use the same chain, documented in full in
[SPEC.md — Modules](SPEC.md#modules): absolute path as-is; containing file's
canonical directory; `eigs_modules/<name>/<name>.eigs` walking upward through
the nearest `eigs.json` directory; that project root; then
`<exe>/../<path>`, `<exe>/../lib/eigenscript/<path>` and its leading-`lib/`-stripped
form, followed by `$HOME/.local/lib/eigenscript/<path>` and its stripped form.
The package walk stops at the project root. A project without an `eigs.json`
has no project-root-relative fallback. Project/package matches precede stdlib
roots; import collisions produce a warning.

### Runtime cache and containing-file context

- **Module cache**: first `import` of a resolved canonical path executes
  the module; subsequent imports bind the same dict. Diamond dependencies
  share one instance of module state.
- **Per-file resolution base**: imports and loads inside a module resolve
  from that module's directory. The compiled source retains this directory
  for nested files and functions called later. `load_file` follows the same
  resolver as `import` while executing the file in the caller's scope.

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
