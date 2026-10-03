- Trace tapes now declare host keys, state grouping and causal spawned-worker
origins before stream events. Replay matches host keys and parent-local spawn
occurrences instead of assigning streams in first-event order. Child identity
is reserved before launch and released through the existing handle lifecycle.
The association encoding is version 5; older tapes are refused explicitly.
