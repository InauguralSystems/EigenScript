- Canonicalize every NaN payload at the double-to-slot boundary so host NaNs
  cannot masquerade as tagged values or crash reference counting (#1758, R2.1).
  Native constants use that writer; NEG and unordered comparisons defer to the
  interpreter. Retain the finite guard and magnitude bound until R2.2
  (RULING R21-1).
