- **A distinct `bool` type (#1637).** Comparisons and `not` return `true`/`false` of type `bool`
  instead of the numbers `1`/`0`. Truthiness is unchanged (`false` is falsy, `true` truthy).
  Arithmetic on a bool raises, and so does `==`/`!=` between a bool and a number: migrate
  `(pred of x) == 1` to `if pred of x:` or `== true`.
