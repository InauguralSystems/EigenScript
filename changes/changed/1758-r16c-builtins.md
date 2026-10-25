- Numeric builtins now use their final integer or float readers (#1758, R1.6c).
  Integer-valued positions, counts, handles, bytecode fields and bytes reject
  fractions instead of truncating; continuous durations use checked rounding.
  Count, index and status results are ints; buffer data remains float.
  Migrated buffer readers refuse non-finite payloads (N13), retaining the
  first strict-NaN diagnostic and INVALID flag.
