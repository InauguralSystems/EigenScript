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

The release notes belong in CHANGELOG.md, assembled from the `changes/` fragments (#1268): before
tagging, run `bash tools/changelog_fragments.sh cut <version> <YYYY-MM-DD>`, which writes the new
section, bumps `VERSION` and deletes the fragments, and commit that as the cut PR (`changes/README.md`).
Check `git tag` for published versions. The front-door docs do not carry a copied latest-version line.

The Homebrew tap at github.com/InauguralSystems/homebrew-eigenscript must
track the latest release automatically.  Its `bump-formula.yml` workflow runs
on a schedule and can also be started with `workflow_dispatch`.  It reads the latest
EigenScript release from GitHub's public API, downloads that tag's source
tarball, computes the formula's `sha256` from the downloaded bytes, and opens a
formula-bump PR when the formula is behind.  Do not copy a checksum into the
formula by hand and do not add a cross-repository credential to this release
workflow.

After a release, look in the tap's pull requests for the automated formula
bump and its `brew test-bot` result. GitHub may require a maintainer to approve
the test-bot runs on a PR created with `GITHUB_TOKEN`; approve those runs on
the generated PR before waiting for its formula checks. A manual dispatch of
the test-bot runs only setup/syntax checks and does not replace PR formula checks.
A red PR is repaired in the tap; do not
paper over it by declaring the release complete here.  If no PR appears after
the scheduled run, dispatch `bump-formula.yml` in the tap and inspect that
workflow's log.
