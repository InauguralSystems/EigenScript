# R33-1 instrument, fixed subject 54008422, addendum 1

This directory contains inputs, labels and a manifest, not experiment scores.
The first bank commit containing MANIFEST.json must precede all binary fixture
reads. OUT/MANIFEST.json is the identical posting copy; its external sha256 is
recorded in the delivery receipts. Its own bytes are excluded from file hashes.

`populations/cal/{x1,x1e-3,x1e3}` is the untouched61-base calibration.
`confirm-cal/{x1,x1e6}` and `confirm-hcal/{x1,x1e-3,x1e3,x1e6}` below
`populations/` use the addendum's matched certification exclusions.
`populations/cal/x1e6/corpus.json` and pre-exclusion `hcal/` corpora are
attempt inputs; only the manifest's named certified sets are runnable.
`populations/confirmation-counts.json` lists every refusal and derived mask.
The BA guard separately uses original released Hcal32 and calibration72;
their staged proof sets and manifests live in `judge-proof/`.

Identity inputs are 512 seeded32-observation sequences and four IEEE anchors.
Every index is read. The harness compares six predicates, report, where/why
values and kinds, how, assignment counts and explicit signed-zero witnesses.
`quiet` is an internal C reader with no direct language query at this pin;
its implementation is hand-tested, not independently binary-compared.

After the instrument is delivered and its manifest posted, a later turn can
collect explicit policy readings using `r33_collect.py --calibration --policy
NAME --manifest MANIFEST --data populations --out FILE`. Run policies in the
order printed by `r33_metrics.arm_order()` (seed1580). Collection does not
compute metrics. `r33_run.py --sweep --data populations --readings FILE ...
--out TABLE` processes collected readings; a PRE1045 control below0.10 yields
VOID and no choice. Current instrument construction runs neither command.

Confirmation collection and point tables require `--choice POSTED-CHOICE.json`,
whose schema contains `arm` and `sweep_tables_sha256`; every output carries
the sha256 of its exact bytes. They cannot prove human posting chronology.
The selected real build must first match the port. Bounds come only from the
unchanged judge program through `r33_judge.py`, with10000 paired resamples,
seed175833. Its commands/staging and F0/F0 program-acceptance proof are in OUT.
No bootstrap is copied. Printed bounds retain the judge's four-decimal text;
discarded counts come from the equal-support arms' printed BA rows.

No H1 input is used or generated. No runtime source or frozen oracle is edited.
