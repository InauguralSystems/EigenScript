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

## Reporting Bugs

Use the [bug report template](https://github.com/InauguralSystems/EigenScript/issues/new?template=bug_report.md) and include a minimal `.eigs` reproducer.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
