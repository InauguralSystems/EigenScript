- Clamp non-finite buffer elements at scalar read boundaries in the VM/runtime
  and native JIT, so indexed
  comparisons, arithmetic, structural equality, scalar reductions (including nested buffers), tensor
  element access, and embedding API reads all observe EigenScript's finite-number
  invariant consistently. Numeric byte/sample/device conversion and mixed
  buffer/list materialization follow the same rule, with defined byte wrapping.
  Raised reads stop before later operations or writes and release temporary
  conversion storage. A failing iterator read reports its for-loop or
  comprehension header, including reads after the first iteration.
  Refs #1417: direct indexed-operand parity and the runtime pin migration in
  ouroboros AOT remain unresolved; the optional boxed-accessor mirror has a
  narrower opt-out fixture scope.
