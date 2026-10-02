- Fixed `sandbox_run` error dictionaries borrowing run-scoped interned keys after
  a caught error, which could leave `kind`, `message`, or `line` dangling at the
  host boundary.
