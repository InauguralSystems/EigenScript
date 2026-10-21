- A `catch` binding inside a module-level `unobserved:` block reads as the caught
  error again, instead of `null` (#1883). The slot promotion no longer takes the
  catch binder, or a named function's name, which are both written by name, so
  every read and write uses the same storage on the interpreter, the JIT and
  forced OSR.
