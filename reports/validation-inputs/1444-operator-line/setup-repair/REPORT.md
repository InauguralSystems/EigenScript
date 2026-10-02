# #1444 setup repair

The original Cloud task stopped BLOCKED_SETUP because its snapshot lacked both the pinned baseline object and origin remote. All 27 validation and 16 calibration phases remain NOT_RUN; original evidence is retained and hashed in previous-cloud-failure.json.

prepare-inputs.sh now fetches a missing exact baseline by canonical public HTTPS URL with --no-tags --depth=1, verifies commit and tree, and conditionally transfers that exact SHA locally into a clone that omitted its FETCH_HEAD-only object. No dependency, gate, oracle, runtime source or patch changed.

Actual fresh no-origin snapshot proof: baseline cat-file initially exited 128, git remote output was empty, the public exact-SHA fetch succeeded, preparation exited 0, and remotes remained empty. Candidate HEAD is the pinned base and staged tree is 3a8582ff4b54d4a70cc72f9943fb02b9a66d2696; clean baseline tree is 4100f6320ef61469d267793fa7a6b44f813410a1. Both branches are attached with external *-gitdir metadata. The complete source/gate input verifier passed. No build, test, suite, differential or runtime execution ran.

The first local proof discovered and preserved the FETCH_HEAD-only clone omission; its exact logs are in first-proof-failed/. The corrected complete proof is in no-origin-proof/. This is an environment/setup correction, not a retry of a functional failure.
