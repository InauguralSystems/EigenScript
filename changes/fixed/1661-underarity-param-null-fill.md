- **An unsent parameter is null-filled at every call entry, with or without
  defaults (#1661).** A 2+-parameter callee without defaults, called with
  fewer arguments than it takes, left the unsent parameters unbound. Once the
  JIT compiled the callee, reading one read a stale slot of a recycled call
  env: a heap-use-after-free that aborted release builds in `malloc` (seen in
  recursion around depth 1000 or more), or a stale non-null value. Even
  without the JIT, a closure over an unsent parameter resolved the name in an
  outer scope instead of reading `null`. Direct calls, JIT-to-JIT calls,
  `dispatch` (both forms) and `task_spawn` now bind every unsent parameter to
  `null`, as SPEC.md and `docs/llms.txt` already promised. The bug was also
  present in v0.44.0.
