- Native code that runs EigenScript gets its own line back when that code returns (#1434). A builtin's callback,
  an embedder's `eigs_eval_string` and an AOT binary's call into interpreted code all go through `vm_execute`,
  and the called code's lines overwrote both the VM's line and the trace line stamp. Nothing restored the stamp,
  and #1424's restore covered only a normal return. So with no interpreter frame live (an AOT binary or an
  embedder) a builtin raising after the callback, such as `sort_by` with a key that returns a string, reported
  the callback's line, and a store right after the call was filed under that line. In the interpreter a callback
  that stopped on an error `sandbox_run` swallowed left the next raise in the caller's expression on the chunk's
  line (`e.line`, the `Error line N` header and the traceback). `vm_execute` now restores both lines on every
  exit, in the interpreter, the JIT and OSR, and writes an `L` record for the restored line when a tape is
  recording, so `eigenscript --step` and the DAP file a store made right after the call under the same line as
  live history. With an interpreter frame live the restored line is the caller's own line, even when a call
  that returned earlier in the expression left the stamp on its last line. Tapes of programs that return from
  `load_file`/`import` or whose builtins run callbacks gain those `L` records; the record shape is unchanged.
