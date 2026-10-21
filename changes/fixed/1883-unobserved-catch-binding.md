Fixed module-level `unobserved:` blocks reading a `catch` binding as `null`
instead of the caught error. Catch variables now keep their name-based storage,
including in loops and across interpreter, JIT, and OSR execution.
