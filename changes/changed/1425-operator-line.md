- A runtime error raised by a binary operator whose operands span lines reports the OPERATOR's line (#1425,
  decided there). `z is 1 / (` on line 2 with its operand `0)` on line 3 used to report `Error line 3` (the line
  the right operand ended on) with no excerpt; it now reports line 2 in `e.line`, the `Error line N` header, the
  excerpt and caret, and the traceback. This covers every binary operator, comparisons and the operator of a
  compound assignment (`+=`), including one written inside an f-string interpolation, in the interpreter, the JIT
  and OSR. The compiler re-stamps the operator's line only when the right operand stamped another line, so
  single-line code compiles to the same bytecode. A recorded tape gains an `L` record before such an operator.
  Temporal filing (a statement's first line, #1381) is unchanged.
