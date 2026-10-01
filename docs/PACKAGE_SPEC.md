# EigenScript packages — implemented behavior

This documents the package tooling that **ships today** (`eigenscript
--pkg`, implemented in `lib/pkg.eigs`). It is the stable contract for
the current surface; the broader, not-yet-built design (version
ranges/solver, a registry/index format, package signing, a
dependency-audit command, yank/deprecation policy) lives separately in
[PACKAGE_DESIGN.md](PACKAGE_DESIGN.md).

## Model

Vendoring-first. A dependency is a git repository, checked out at a
pinned commit into `eigs_modules/<leaf>/`. The tool is the only thing
that touches the network; **no dependency code runs at install time** —
install is `git clone --depth 1` + checkout + hash, and only a later
`import` actually executes any of it.

`import <name>` resolves by directory convention
(`eigs_modules/<leaf>/<leaf>.eigs`). Once resolved, the runtime reads that
package's adjacent manifest only to enforce `requires`; a missing manifest is
treated as having no requirements, while a valid declaration is checked before
package source executes.

## Files

| File | Role |
|------|------|
| `eigs.json` | Manifest: `name`, `version`, `deps` keyed by `<owner>/<name>`, and optional `requires` build variants. Also an optional `lint.allow` map (per-file lint allow-list — see docs/DIAGNOSTICS.md). |
| `eigs.lock.json` | Resolved commit SHAs + content hashes for each dep. |
| `eigs_modules/<leaf>/` | One directory per dep — a git checkout at the locked commit. |

`requires` is a list containing zero or more runtime build variants: `http`,
`gfx`, `zlib`, or `net`. For example, an HTTP client package declares
`"requires": ["http"]`. `--pkg install` and `--pkg verify` compare each
installed dependency's declaration with the running executable and fail with
the package name and providing `make` target for every mismatch. Import applies
the same gate before package code executes. Packages needing no extension use
`"requires": []`.

The [package template manifest](https://github.com/InauguralSystems/eigs-package-template/blob/main/eigs.json)
must carry that empty declaration explicitly. Its complete baseline manifest
is:

```json
{
  "name": "mypkg",
  "version": "0.1.0",
  "deps": {},
  "requires": []
}
```

## Naming

Package identifiers are **always namespaced**: `<owner>/<name>`. Bare
names are rejected — this reserves the namespace at the manifest layer
from day one (no land rush on names like `tensor`). Both parts accept
alphanumerics plus `-`, `_`, `.`; neither may start with `-` or `.`,
and `.`/`..` are reserved.

The on-disk directory and the user-visible `import <name>` form stay
**flat** (just the leaf `<name>`). Consequence and current limitation:
two packages that share a leaf name cannot coexist yet. Disk-level
nesting + scoped imports can be added later without breaking any
existing manifest.

## Subcommands

```
eigenscript --pkg add <owner>/<name> <git-url> [tag]   add to manifest + clone + lock
eigenscript --pkg install                              reproduce eigs_modules/ from the lockfile
eigenscript --pkg update [<owner>/<name>]              re-resolve a tag and re-lock (all deps, or one)
eigenscript --pkg verify                               re-hash trees against the lockfile
eigenscript --pkg list                                 print installed deps
eigenscript --pkg help                                 print usage
```

- **add** — clones `<git-url>` at `[tag]` (default branch if omitted)
  into `eigs_modules/<name>/`, records the resolved commit + tree hash
  in `eigs.lock.json`, and writes the dep into `eigs.json`. An omitted
  tag is **recorded as omitted** — no `"tag"` key — and the clone runs
  without `--branch`, so git picks the remote's own default. The
  manifest carries the *requested* ref; the lockfile carries the
  *resolved* commit, which is what makes the install reproducible.
  (Before #879 an omitted tag was written as the literal `"main"`
  before the clone was attempted, which failed outright on any
  `master`/`trunk`/`develop` remote and left a manifest `install` could
  never recover.)
- **install** — reproduces `eigs_modules/` from manifest + lockfile.
  Existing checkouts are wiped before re-clone, so install is
  idempotent and deterministic from the lockfile alone.
- **update** — re-resolves the tag to its current commit and re-locks
  (all deps, or just the named one).
- **verify** — re-hashes every checked-out tree against the lockfile;
  flags a missing checkout or working-tree tampering.

## Integrity

The lockfile pins a **commit SHA**, not a tag, so a force-pushed tag
can't sneak a different tree past `--pkg install`. `--pkg verify`
re-hashes the working tree against the recorded content hash, catching
post-install tampering. Both checks are local — there is no signature
verification yet (that is a [PACKAGE_DESIGN.md](PACKAGE_DESIGN.md) item).

## Exit codes

Failure paths `throw`, which leaves the process with exit code 1
(`main.c` flips `g_has_error`). Success paths exit 0.
