# AI contribution benchmark driver foundation

This periodic benchmark is evidence **for AI agents** and AI-written software; it is never a merge gate. The provider-neutral driver owns the lifecycle while small named adapters expose, rather than erase, provider telemetry differences. Raw result events are retained unchanged.

Exact EigenScript invocation (replace pinned values, never use a moving ref):

```sh
python3 tools/ai_benchmark.py --repository /clean/EigenScript --task bench/ai_contribution/tasks/eigenscript-1236.json --revision b3bf498791ef1048ae7df270216948fd5f48566a --adapter codex --model <model-id> --output /artifacts/<run-id> [--pricing /recorded/prices.json]
```

The source fixture must be clean. The output records all arguments, a one-commit history-free snapshot whose `origin/main` is a local stub, prompt/task copies, environment, command transcript and streams, raw event, normalized versioned result, and diff. EigenScript validation is exactly `make precheck` then `make test-changed BASE=origin/main`; remote first-push CI is a separate, initially unavailable result.

## Still open

The memo did not choose the exact established-language bug/revision, the three model IDs and pricing snapshot, run/re-run dates, execution host, artifact publisher, or remote-CI submission mechanism. Choose and record these when conducting the measurement; do not encode them as protocol policy.

Local success requires agent exit zero, successful Git inspection proving a nonempty committed diff against the immutable snapshot, and all driver validation commands passing. The worktree must match the committed artifact before and after validation, with unchanged HEAD and no tracked or untracked residue (ignored build products are allowed). Failed runs retain worktree, raw streams, inspection receipts and result artifacts; local_completed_at is null. Driver validation attempts are distinct from agent-observed runs/retries. Adapters accept optional explicit benchmark round telemetry; missing observations keep round totals unavailable.

Refs #1302: this PR supplies only the driver foundation. The real three-model campaign, established-language baseline, publication and first-push CI campaign remain open. No campaign measurements are claimed.
