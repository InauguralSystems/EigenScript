- After a call returns, a raise in the caller's expression reports the caller's line (#1424). The VM kept the
  callee's last line as the current line, so `e.line`, the `Error line N` header and the traceback's frame line
  named a line inside the callee for `sqrt of (f of x)`, `1 / (f of x)`, `a % (f of x)` and a builtin raising after
  it ran a user callback (`sort_by`). Every frame now records its caller's line when it is pushed, and `RETURN`,
  `RETURN_NULL` and the JIT's return helpers restore it, in the interpreter, the JIT and OSR. Trace-tape `L`
  records and temporal answers are unchanged.
