- Tensor builtins now raise a catchable `type` error by default when a list
  tensor contains a non-number element, rather than silently replacing it with
  zero. Set `EIGS_STRICT=0` to retain the legacy coercion.
