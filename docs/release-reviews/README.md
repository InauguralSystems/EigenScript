# Release legibility reviews

Before each release, the documentation and configuration that changed since the previous release are reviewed. Then the released state means what it says. One record per version, `vX.Y.Z.md`, is committed in the cut PR. The Release workflow (`.github/workflows/release.yml`) refuses to tag a version without its record.

## What the review covers

Over the range `<previous-tag>..<candidate>`:

- **Docs drift:** claims in BUILTINS, SPEC, COMPARISON, README, llms.txt and EMBEDDING against actual behaviour, and a `changes/` fragment for every user-visible change. Run `tools/docs_claims_check.sh`, `tools/stdlib_index_check.sh` and the executed doc fences.
- **Stale references:** names the range deleted (files, builtins, flags, make targets), references to issues now closed in text that says they are open, version prose and pins, and dead links.
- **Config drift:** Makefile targets, CI steps, `.github/actions/` and `tools/selftests.txt` rows that point at something removed or renamed. Run `tools/workflow_yaml_check.sh`, `tools/ci_tier_check.sh`, `tools/enrolment_check.sh` and `tools/codspeed_targets_check.sh`.
- **Duplicated logic:** two implementations of one rule added in the range, and temporary shims whose reason is gone.
- **Dead code:** functions, scripts, fixtures and flags with no remaining user.

## Record format

The workflow checks two lines; the rest is for readers.

- `Range: <previous-tag>..<candidate-sha>`
- one row per finding: `| category | location | FIXED <commit> |` or `| category | location | FLAGGED #<issue> |`
- the instruments run, each with its result
- `Verdict: <one line>`, for example `Verdict: clean, 4 fixed, 2 flagged`
