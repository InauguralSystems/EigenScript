# Contributing to EigenScript

Thanks for your interest in contributing to EigenScript.

## Getting Started

```bash
git clone https://github.com/InauguralSystems/EigenScript.git
cd EigenScript
./build.sh
cd tests && bash run_all_tests.sh
```

Requires only `gcc` — no external dependencies.

## Making Changes

1. Fork the repository
2. Create a branch from `main`
3. Make your changes
4. Run the test suite: `cd tests && bash run_all_tests.sh`
5. Open a pull request

Two gates worth knowing before you push:

- **The suite must also pass under sanitizers** (CI enforces it):
  `make asan && cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh`.
  The final summary prints a tolerated-leak tally (known closure-cycle
  leaks, see `docs/CLOSURE_CYCLE_GC.md`) — if your change makes that
  number jump, you've introduced a leak.
- **The spec is executable.** Every example in `docs/SPEC.md` and
  `docs/COMPARISON.md` runs in CI and must match its output block
  byte-for-byte. If you change language semantics, update the spec in
  the same PR or CI fails — that's by design. Same for the expected
  messages in `examples/errors/`.

## Code Style

- **C source** (`src/`): 4-space indent, no tabs. Keep functions short. Every builtin gets a signature comment.
- **EigenScript libraries** (`lib/`): Follow the conventions in [docs/STDLIB.md](docs/STDLIB.md) — header block, signature comments, snake_case naming.
- **Tests**: One `.eigs` file per feature area. Tests should print clear pass/fail output.

## What to Contribute

- **Bug fixes** — always welcome.
- **New builtins** — open an issue first to discuss the API.
- **Standard library modules** — see `lib/` for the pattern. New modules should include docs in `docs/STDLIB.md`.
- **Examples** — add to `examples/` with a comment header explaining what the example demonstrates.
- **Documentation** — improvements to `docs/` or `README.md`.

## Publishing a Package

EigenScript packages are git repos with `eigs.json` (manifest) and
`<name>.eigs` (entry point) at the root. Consumers run
`eigenscript --pkg add <name> <git-url> <tag>` to clone them into
`eigs_modules/<name>/`. See [docs/PACKAGE_DESIGN.md](docs/PACKAGE_DESIGN.md)
for the design intent.

**Start here**: fork [eigs-package-template](https://github.com/InauguralSystems/eigs-package-template).
It has the layout, MIT license, smoke test, and CI workflow already
wired up. The README walks through the rename.

### Naming

- **Lowercase identifiers, no hyphens.** A consumer writes
  `import <name>`, and EigenScript identifiers can't contain `-`.
  Underscores are fine; prefer one or two short words.
- **Don't collide with the stdlib.** The resolver tries
  `lib/<name>.eigs` first, so a stdlib module of the same name
  shadows your package. Names like `json`, `math`, `os`, `string`
  are reserved by convention even when not yet implemented.
- **Repos are conventionally named `eigs-<name>`** (e.g.,
  `eigs-vecmath`), but the consumer's `--pkg add <name> <url>`
  determines the imported name — the repo name is a label, not a
  rule.

### Versioning

- **Follow semver**: patch = bugfix; minor = additive surface change;
  major = removed or repurposed surface. The lockfile pins a commit
  SHA so existing consumers won't break on a tag move — but a moved
  tag still breaks `--pkg add` for *new* consumers, and a tampered
  tag is a security signal `--pkg verify` will catch. **Cut a new
  tag rather than force-pushing an old one.**
- **Top-level statements run once at import time** (cached after the
  first importer). Side effects beyond binding names (network I/O,
  file writes, etc.) at the top level are a footgun — keep them
  inside `define`d functions the consumer chooses to call.
- **Leading-underscore names are private** to the module: visible
  inside the package's `.eigs` files, hidden from importers.

### Getting your package listed

Once your package has a tagged release and a green CI run, open a PR
against [awesome-eigenscript](https://github.com/InauguralSystems/awesome-eigenscript)
adding a one-line entry under the right category. This is a curated
list, not a registry — there is no install-time lookup, so listing
is purely for discoverability.

## Reporting Bugs

Use the [bug report template](https://github.com/InauguralSystems/EigenScript/issues/new?template=bug_report.md) and include a minimal `.eigs` reproducer.

For private or non-issue contact, email contact@inauguralsystems.com with one
of these subject prefixes:

- `[SECURITY]` Vulnerabilities or suspected security issues. Do not file public
  GitHub issues for suspected vulnerabilities.
- `[BUG]` Reproducible bugs that are not appropriate for a public issue.
- `[SUPPORT]` Installation, usage, or release questions.
- `[PRESS]` Media, interviews, or public inquiries.
- `[LEGAL]` Licensing or trademark questions.

## Governance

How decisions get made on the project, and how contributors can earn
commit access over time, is described in
[GOVERNANCE.md](GOVERNANCE.md). Short version: trust is earned by
visible, sustained work; there is no application form.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
