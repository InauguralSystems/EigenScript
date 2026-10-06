- **A distinct `bool` type (#1637).** Comparisons and `not` return `true`/`false` of type `bool`
  instead of the numbers `1`/`0`. Truthiness is unchanged (`false` is falsy, `true` truthy).
  Arithmetic on a bool raises, and so does `==`/`!=` between a bool and a number: migrate
  `(pred of x) == 1` to `if pred of x:` or `== true`.
  `list_contains`/`list_index_of` raise on bool vs number the same way. Any
  builtin given a bool where it does not take one raises, even under
  `EIGS_STRICT=0`: as its argument, at a position of its argument list, or
  as an element of a list it reads as numbers. The slots that take a bool are
  listed in `tests/bool_fuzz_anyvalue.txt`. A bool slice bound, index, `range`
  bound or `at` line raises. Deep `==` stops at the first unequal pair, and a
  bool/number pair raises when the walk reaches it. Trace tapes are format v6;
  a v5 tape is refused, and so is a record of a kind its builtin cannot
  return. Embedding hosts declare a recorded name's kinds with
  `eigs_trace_declare_kind`.
- **Wrong-typed numbers that used to be read as garbage now raise (#1637).** The
  bool work routed every C number read through a checking accessor, which
  also changes some non-bool cases:
  - a string `at` line (`what is x at "s"`) raises; it answered null;
  - a non-number net timeout (`net_accept`/`net_dial`/`net_recv`), a
    non-number `http_serve` port, and a non-number byte or `param_count` in a
    `vm_run_bytecode`/`sandbox_run` descriptor raise; they were read as
    garbage or as 0;
  - the tensor mutators `numerical_grad*`/`sgd_update*` raise on a non-number
    cell or row in every strict mode, `EIGS_STRICT=0` included: v0.44.0 read
    a non-number cell as 0 (and `numerical_grad_rows`/`_cols` wrote into it
    in place) and skipped a null row;
  - a non-number `screen_put` color and a non-number, non-bool
    `write_bytes` append flag raise in every strict mode (neither had a
    documented `EIGS_STRICT=0` answer);
  - a non-number cell `gather` selects raises under `EIGS_STRICT` (it was
    0); `EIGS_STRICT=0` keeps the 0.
  `EIGS_STRICT=0` keeps every answer it documents for non-bool values:
  `str_from_bytes`, `inflate`/`deflate` and the other byte-list builtins
  still read a non-number element as 0 there (a bool raises in every mode).
  Embedders that include `eigenscript.h`: a Value's number is `VAL_NUM_RAW(v)`
  and a slot's is `SLOT_NUM_RAW(s)` (the members were renamed so an unchecked
  read does not compile).
