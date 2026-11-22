- Add `f64_bits`, `f64_from_bits`, `buf_get_bits` and `buf_set_bits` for signed
  int64 access to IEEE float64 representations. Integer and raw buffer bits
  preserve NaN payloads; constructing a float uses the canonical quiet NaN.
  Public embedding double inputs and outputs now canonicalize NaNs, replacing
  the prior payload-preserving C boundary contract. Non-NaN bits, including
  infinities and signed zero, remain exact. NaN arithmetic temporaries and
  default-mode leaf results use the same canonical writer.
