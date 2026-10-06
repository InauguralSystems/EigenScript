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
