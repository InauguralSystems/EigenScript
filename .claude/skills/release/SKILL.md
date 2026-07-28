---
name: release
description: Cut an EigenScript release — the tag/dispatch path this environment requires, the CLAUDE.md "Latest release" line the doc-drift rule gates on, and the Homebrew tap that tracks it. Use when tagging a version, running the Release workflow, or a release build fails its own suite.
disable-model-invocation: true
---

# Releasing EigenScript

Push a `v*` tag **or** dispatch the Release workflow (Actions → Release → Run
workflow), which creates the tag and builds in the same run. This
environment's git proxy **cannot push tags**, and GITHUB_TOKEN-pushed tags
don't retrigger workflows — so use the dispatch path.

**The cut PR must update CLAUDE.md's "Latest release" line to the new
version**: doc-drift rule 2 (`tools/doc_drift_check.sh`) compares it to the
latest tag, and the release build runs *after* the tag is created — a stale
line fails the release's own suite (bit the v0.27.0 cut).

Homebrew tap: github.com/InauguralSystems/homebrew-eigenscript (tracks the
latest release).
