# EigenScript principles

The rules every design decision is checked against. When a decision issue,
PR or review cites one, it cites it by name. A principle changes only by an
explicit decision recorded in an issue, never by drift.

## 1. Best practice by default; depart only by measurement

For any question mature languages have already answered, their consensus is
the default. EigenScript departs from it only where a measurement shows our
approach is better, and the measurement is recorded where the decision is.
A departure without one reverts to the default. This applies to what makes
EigenScript different (the observer, the trace tape) as much as to anything
else: those stay because measurement shows they earn their place.
(#1286)

## 2. No silent wrong answers

A result that is wrong must be loud. A builtin that cannot do what was asked
raises; it does not return a plausible default. Loss of precision, a
wrong-typed argument quietly treated as zero, a value that changed meaning
under the program: each is a bug even when nothing crashes. A loud failure
is never traded for a quiet one. (#975)

## 3. Determinism is a guarantee with a stated boundary

Same program, same inputs and same tape give the same output, on every
execution tier. Every source of nondeterminism is either recorded on the
tape or visible in the source; no capability bypasses the tape. Where
determinism ends (thread scheduling, for one) the language says so rather
than leaving it implicit. (#1287)

## 4. A small core; everything else a package

`lib/` holds what the language needs to be usable and what the runtime's
own guarantees depend on. Domain libraries are free packages, versioned
independently, so the core stays small and consistent and the libraries
can move faster than the language. (#1286)

## 5. Checks are anchored outside the system, narrow, and few

A deterministic check that is wrong is wrong every time, with full
confidence, so a check is trusted only when it is anchored to something
outside itself: the real target, the real CI, a real consumer, or a
structural guarantee that makes the failure impossible. A check is narrow
enough to audit by reading. It proves it fires once, when it is written or
changed; it is not re-proven by a permanent check of the check. A new check
must be correct, likely enough to catch real problems to be worth its cost,
and precise (the criteria of Go's vet). (#1275)

## 6. Semantics settle before the first outside user

EigenScript is pre-v1, and v1 follows real users, not a date. While we are
the only users, changing the language is free, so the founding decisions
(numbers, absence, booleans, strings, concurrency, versioning) are settled
now. Once someone outside depends on a behavior, changing it needs a
migration path. (#1286)

## 7. Every piece of work states when it is done

An issue, a PR and an experiment each carry a checklist someone else could
verify. An issue that cannot state one is several issues. An experiment
records its targets, thresholds and predictions before it runs, and a
threshold changed after the run makes a new experiment. (#1287)

## 8. The design in the tree is a hypothesis

Most of this code was designed by earlier AI sessions on much older models,
and nothing is frozen by compatibility yet. A decision found in the tree
carries no authority from seniority. When a design looks forced, ask
whether it is a law (language semantics, an external contract) or a
decision, and price the alternative. Gaps go upstream as issues; they are
not worked around silently. (See CLAUDE.md.)
