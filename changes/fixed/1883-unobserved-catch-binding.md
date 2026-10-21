- A name bound by name inside a module-level `unobserved:` block reads its
  binding again, instead of `null` or a value from another scope (#1883). Such
  names are a `catch` binder, a `for` binder, a defined function's name, a
  comprehension binder, an `import`ed module, `loop while`'s `__loop_exit__`
  and `__loop_iterations__`, and a `local` in a `for` body. The block's slot
  promotion now skips every such name, even when the block also assigns it with
  `is`, so its reads and writes use the same storage on the interpreter, the
  JIT and forced OSR.
