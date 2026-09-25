---
name: release
description: Cut an EigenScript release — the tag/dispatch path this environment requires, the Homebrew tap that tracks it. Use when tagging a version, running the Release workflow, or a release build fails its own suite.
disable-model-invocation: true
---

# Releasing EigenScript

Push a `v*` tag **or** dispatch the Release workflow (Actions → Release → Run
workflow), which creates the tag and builds in the same run. This
environment's git proxy **cannot push tags**, and GITHUB_TOKEN-pushed tags
don't retrigger workflows — so use the dispatch path.

The release notes belong in CHANGELOG.md; check `git tag` for published
versions. The front-door docs do not carry a copied latest-version line.

Homebrew tap: github.com/InauguralSystems/homebrew-eigenscript (tracks the
latest release).
