# AGENTS.md — start here

This file is the entry point for any coding agent (Codex, Copilot, Cursor,
Gemini, Claude and others). It is deliberately short: it points at the files
that hold the detail, so there is one copy of each rule and nothing here can
drift from them.

## Writing EigenScript

Read **[docs/llms.txt](docs/llms.txt)** before you write any `.eigs` code. It
is the whole language in one file: call syntax (`f of x`, never `f(x)`), the
scope model, the observer, the Python/JS habits that do not work, and the
validation ladder. Every code example in it is executed by the test suite.

To check whether a builtin or library function exists, ask the runtime:
`eigenscript --api` (or `--api --json`). Do not trust a remembered list.

Run what you write: `eigenscript --lint --json prog.eigs`, then
`eigenscript prog.eigs`.

## Working in this repository

**[CLAUDE.md](CLAUDE.md)** holds the build and test commands, the suite's
leak gates, the changelog-fragment rule and the hard-won rules. It applies to
every agent, not only Claude.

## When you hit a gap, file an issue

You will hit a missing feature, a rough edge or a bug. Surface it; do not work
around it silently. Open a GitHub issue with a minimal repro and a **"Done
when"** checklist someone else could verify, or fold the fix into your PR and
reference it. If you cannot write the checklist, it is several issues: file
those instead. CLAUDE.md explains why.
