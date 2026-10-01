- A runtime error raised by a written binary operator whose operands span lines reports the operator's
  physical line in `e.line`, the error header, excerpt/caret and traceback (#1425). This includes plain-name
  compound assignment (`x += rhs`) and written operators inside f-string interpolations, in the interpreter,
  JIT and OSR. After success the compiler's temporary operator stamp restores the previous runtime line,
  preserving attribution for an enclosing unary operation, index or call, including conditional operands.
  Single-line code compiles to identical bytecode. Interpreted execution adds a tape line record before
  the operation and a restoring line record on success. Temporal filing remains the statement's first line. Dedicated compound
  field/index assignments retain their prior attribution pending a separate owner decision.
