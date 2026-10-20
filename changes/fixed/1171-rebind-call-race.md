- A thread calling a module-level function while another thread rebinds the same
  name (a `define`, an outward `is`, or two workers `load_file`-ing one module) no
  longer uses the old function after the rebind has freed it (#1171). The reader
  now takes its reference inside the lock the rebind holds while it releases the
  old value, the assignment count is bumped inside that lock too, and inline
  caches filled before the first `spawn` can no longer read such a binding
  without it. A call also keeps its callee until the new frame holds the
  callee's code: a function from a `load_file`'d module whose name was rebound
  while its call was being set up (by another thread, or by the call's own
  argument reloading the module) used to run freed code, even single-threaded.
  Which value a racing reader gets is still the program's own race. A binding in
  a function's scope that closures on two threads share is not covered yet
  (#1837).
