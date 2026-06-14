# Governance

This document describes how decisions get made on EigenScript, and how
contributors can earn more responsibility over time. It is deliberately
minimal — the project has one maintainer today, and this doc will grow
as the maintainer set grows.

## Current state

EigenScript has one active maintainer
([@InauguralPhysicist](https://github.com/InauguralPhysicist), under
the [InauguralSystems](https://github.com/InauguralSystems) org). All
merges to `main`, all releases, and all design decisions currently
flow through that one person. This is not the long-term goal — it is
the current reality.

The project is MIT-licensed and unpaid. Nobody is being compensated
for working on it. Contributions are voluntary; so is maintenance.
This is the honest reason the project is open source: making it open
is the only way the work outlives a single person's time and energy.

## How decisions get made

- **Code changes**: PRs are reviewed and merged by a maintainer.
  Small, well-scoped, test-covered changes are merged on the same
  cadence as review bandwidth allows.
- **Design changes** (language semantics, stdlib API, on-disk
  formats): open an issue first. The
  [executable spec gate](CONTRIBUTING.md#making-changes) means
  semantic changes update `docs/SPEC.md` in the same PR.
- **Disagreement**: the maintainer makes the call. There is no formal
  voting process while the maintainer set is one person — adding one
  would be ceremony without substance. The process here will change
  when there are enough maintainers to disagree meaningfully.

## Paths to more responsibility

There is no application form. Trust is earned by visible,
sustained work. The bars below are signals, not checklists.

### Becoming a recognized contributor

You are a recognized contributor when you have landed PRs the
maintainer can point to and say "this person ships solid work."
Concretely:

- Multiple merged PRs that did not need substantial rework
- Tests that pass under both release and `make asan` (the suite has
  two gates — see CONTRIBUTING)
- Behavior that respects the
  [executable spec](docs/SPEC.md) and the
  [stability contract](README.md#stability)

Recognized contributors get listed in release notes and are the
first people consulted on adjacent design questions.

### Becoming a committer (commit access)

A committer can merge PRs they did not author. The bar:

- A track record as a recognized contributor (rough heuristic: 5+
  non-trivial PRs across at least two of the project's areas —
  runtime, stdlib, tooling, docs)
- Demonstrated judgment about what *not* to change — accepting
  scope, declining churn, holding the spec line
- Visible engagement with review: catching bugs in others' PRs,
  asking the right questions, not just rubber-stamping

Commit access is granted by the existing maintainer set. Reaching
the bar does not guarantee an invitation — it makes one possible.
Adding a committer requires that the existing maintainers agree it
is the right call for the project's stability.

### Becoming a maintainer

A maintainer can cut releases, make design calls, and grant commit
access to others. The bar:

- An active committer for long enough that the existing maintainers
  can predict your judgment on a novel question
- Willingness to do the unglamorous work: triage, releases,
  CHANGELOG hygiene, security response, contributor onboarding
- Agreement on the project's direction (see
  [README's stability section](README.md#stability) and the
  [CHANGELOG](CHANGELOG.md) for the trajectory the project has been
  taking)

The first additional maintainer changes the project meaningfully: it
unlocks the Code-Review and Branch-Protection axes that Scorecard
currently flags as zero, and it is the first point at which design
disagreement is resolved by discussion rather than by one person.
That transition will be documented here when it happens.

### Stepping down

Maintainers and committers can step down at any time by opening a PR
against this file. Inactive committers (no PR activity for ~12
months) may have their access reviewed by the active maintainers —
the goal is to keep the access list honest, not to punish people for
having other priorities.

## What this document is not

- **Not a contract.** Reaching a bar described here is necessary but
  not sufficient. The project's stability is the priority.
- **Not stable forever.** The first additional maintainer is a real
  governance event, and so is the second, and so is whatever shape
  the project takes after that. This doc will be revised at those
  points rather than written once and frozen.
- **Not a substitute for [CONTRIBUTING](CONTRIBUTING.md) or
  [SECURITY](SECURITY.md).** Those describe how to file PRs and
  report vulnerabilities respectively; this describes how authority
  flows.

## Code of conduct

All participation in the project is governed by
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
