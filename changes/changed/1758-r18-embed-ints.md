The embedding API adds exact int64 construction and conversion
(`eigs_value_new_int`, `eigs_value_as_int`) and an int-kind predicate
(`eigs_value_is_int`), following Lua's numeric C API. Numeric literal hover
distinguishes int and float. The iterator's hidden int position again uses
an in-place immediate update, recovering the S9-K1 fast path. Phase 2 cost
declarations have separate local and CI maxima measured by each gate.
