# The Round 3 reveal: the record of the one sealed run (EigenScript#1758)

This folder is the whole output of the one sealed run of the observer's held-out
test, as the hosted job uploaded it, and the job's own log. It is published on a
tag and is not part of `main`'s tree.

- Workflow: `.github/workflows/observer-reveal.yml` on `main` at
  `e55567024e1a63c3efb82a2a04124a9dabb8d6cf`, dispatched once, run 44233360250,
  2026-11-18T03:51:55Z to 04:03:37Z, runner image `ubuntu-24.04` 20261111.370.1.
- Inputs, each fixed in public before the round existed: `round` = 6648927 (drand's
  default mainnet chain), `r3` = `5b93b236720c202f62d950e25ec9b888091cd809`,
  `r3_std` = `3eed5cafd678665ba1d0667fb73ce1b1437fa724`, 10,000 resamples.
- Status: `COMPLETE`.

`result/` holds: `decision.json` (the canonical decision table), `raw.json` (the raw
log it is extracted from), `H1/` (the held-out set drawn from the round: `corpus.json`,
`labels.json`, `certificate.json`, `manifest.json`), the three `*-population.json`
files (every arm's confusion table by family, and every disagreement, for the
calibration set, H-cal and H1), the judge's logs, each arm's build log and
declarations, and `instrument/`, the copy of the instrument the run used.
`hosted-job.log` is the job's log.

sha256:

| file | sha256 |
|---|---|
| `result/decision.json` | `d5fd4381137922518ee4c0b4508804a6f05e3cdbadca47b7a982d21e21c34a8d` |
| `result/raw.json` | `a080bfba8b650418971bbe7926dbca40bc352b0df84e4720c5e042a141196d09` |
| `result/H1/corpus.json` | `85be07d96390ad23f583d640be4fe46fa7a1d4affde37e82bf7125535e016cff` |
| `result/H1/labels.json` | `22ed149951e75ae83cdf0c867aef228f0a407133a74f588f7e7dd2b4bccdf644` |
| `result/H1/certificate.json` | `f627eeb9e7db4e4a873fb700e0f10fa83ceb6c48c1d9a92e8e582b8494ca3e59` |
| `result/H1/manifest.json` | `8e3095af031e79ef72addb72cba3dd1705069037caca0df308dda9ed06a29913` |

The rules the run was judged by, and what follows from it, are on EigenScript#1758.
