# Contributing to EigenScript

Thanks for your interest in contributing to EigenScript.

## Getting Started

```bash
git clone https://github.com/InauguralSystems/EigenScript.git
cd EigenScript
./build.sh
cd tests && bash run_all_tests.sh
```

Building needs only `gcc`. Running the test suite also needs `python3` with PyYAML
(`apt install python3-yaml`, or `python3 -m pip install --user pyyaml`).

## Making Changes

1. Fork the repository
2. Create a branch from `main`
3. Make your changes
4. Run `make precheck` — the static gates CI runs and self-tests for gates changed against `origin/main`, no suite
   needed. It catches pipefail verdicts, section-label clashes, child-exit
   accounting, the shard plan, and a new test that no suite section runs.
5. Run the test suite: `cd tests && bash run_all_tests.sh`
6. Open a pull request

Adding a test is the test file plus its section in `tests/run_all_tests.sh` —
no counts to bump, no documentation numbers to edit.

Two gates worth knowing before you push:

- **The suite must also pass under sanitizers** (CI enforces it):
  `make asan-http && cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh`.
  The final summary prints a tolerated-leak tally (currently 0 — see
  `docs/CLOSURE_CYCLE_GC.md`) — if your change makes that
  number jump, you've introduced a leak.
- **The spec is executable.** Every example in `docs/SPEC.md` and
  `docs/COMPARISON.md` runs in CI and must match its output block
  byte-for-byte. If you change language semantics, update the spec in
  the same PR or CI fails — that's by design. Same for the expected
  messages in `examples/errors/`.

## What CI will run on your PR — and how long you wait

**Expect a pull request to go green in about 15 minutes** (seconds if you only
touched `*.md`). Full detail, and the reasoning, is in [docs/CI.md](docs/CI.md);
the short version:

- **Your PR** runs the complete suite on gcc, clang, and each extension
  variant. The HTTP+model ASan build runs the complete suite in shards, with
  leak detection on and an aggregator that checks their coverage.
- **Merging to `main`** reruns the same complete variant matrix in the merge
  queue, then on the main push.
- **Nightly** runs `macos-15-intel` and a full-corpus valgrind pass, and files
  a tracking issue if either goes red.

Locally, `cd tests && bash run_all_tests.sh` runs the complete suite. To
reproduce a sanitizer shard's suite selection:

```bash
bash tools/section_plan.sh --shards 3 --check
EIGS_SUITE_SHARD=2/3 bash tests/run_all_tests.sh
```

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
`eigenscript --pkg add <owner>/<name> <git-url> <tag>` to clone them
into `eigs_modules/<name>/`. See
[docs/PACKAGE_DESIGN.md](docs/PACKAGE_DESIGN.md) for the design intent.

**Start here**: fork [eigs-package-template](https://github.com/InauguralSystems/eigs-package-template).
It has the layout, MIT license, smoke test, and CI workflow already
wired up. The README walks through the rename.

### Naming

- **Identifiers are namespaced: `<owner>/<name>`.** The tool requires
  this form at `--pkg add` time and at `install`/`update`/`verify`,
  so the manifest key is always `alice/tensor`, not bare `tensor`.
  Reserving the namespace at the manifest layer from day one prevents
  a land rush on bare leaves once the ecosystem picks up. Convention
  is to set `<owner>` to your GitHub org or user.
- **Disk layout and imports stay flat (for now).** The leaf alone
  decides `eigs_modules/<leaf>/<leaf>.eigs` and the user-facing
  `import <leaf>` form, so two packages sharing a leaf can't yet
  coexist in the same project. Disk-level nesting + scoped imports
  can land later without breaking any existing manifest.
- **Lowercase leaves, no hyphens.** A consumer writes `import <leaf>`,
  and EigenScript identifiers can't contain `-`. Underscores are
  fine; prefer one or two short words.
- **Don't collide with the stdlib.** The resolver tries
  `lib/<leaf>.eigs` first, so a stdlib module of the same name
  shadows your package. Names like `json`, `math`, `os`, `string`
  are reserved by convention even when not yet implemented.
- **Repos are conventionally named `eigs-<leaf>`** (e.g.,
  `eigs-vecmath`), but the consumer's
  `--pkg add <owner>/<leaf> <url>` determines the imported name —
  the repo name is a label, not a rule.

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

Every issue carries an `area:<subsystem>` label and a kind (`kind:*`, or the
stock `bug`/`enhancement`). You do not have to label your own issue. Two
mechanisms keep the backlog labelled, and both run from `main`
(`.github/workflows/issue-triage.yml`), never on your pull request: the
**daily audit** FAILS while any open issue is missing an `area:` label or a
kind, and the **triage job** puts
`needs-triage` on a newly opened or reopened issue that arrives without an
`area:` label and comments with the scheme, so you can add the right labels
yourself if you know them. A maintainer replaces `needs-triage` either way.

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
