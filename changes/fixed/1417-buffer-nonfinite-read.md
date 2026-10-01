- Clamp non-finite buffer elements at every scalar read boundary, so indexed
  comparisons, arithmetic, `buf_get`, tensor element access, and embedding API
  reads all observe EigenScript's finite-number invariant consistently.
