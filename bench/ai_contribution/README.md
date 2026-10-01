# AI contribution benchmark

This periodic benchmark is evidence **for AI agents** and AI-written software; it is never a merge gate. The provider-neutral driver owns the lifecycle while small named adapters expose, rather than erase, provider telemetry differences. Raw result events are retained unchanged.

Exact EigenScript invocation (replace pinned values, never use a moving ref):

```sh
python3 tools/ai_benchmark.py --repository /clean/EigenScript --task bench/ai_contribution/tasks/eigenscript-1236.json --revision <full-commit> --adapter codex --model <model-id> --output /artifacts/<run-id> [--pricing /recorded/prices.json]
```

The source fixture must be clean. The output records all arguments, a one-commit history-free snapshot whose `origin/main` is a local stub, prompt/task copies, environment, command transcript and streams, raw event, normalized versioned result, and diff. EigenScript validation is exactly `make precheck` then `make test-changed BASE=origin/main`; remote first-push CI is a separate, initially unavailable result.

## Still open

The memo did not choose the exact established-language bug/revision, the three model IDs and pricing snapshot, run/re-run dates, execution host, artifact publisher, or remote-CI submission mechanism. Choose and record these when conducting the measurement; do not encode them as protocol policy.
