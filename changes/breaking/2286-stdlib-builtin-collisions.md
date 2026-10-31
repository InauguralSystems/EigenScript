- Loading standard-library files no longer replaces same-named builtins (#2286). This is a breaking rename for shared-scope `load_file` consumers; namespaced imports keep non-colliding names unchanged.

  | Old public function | New public function |
  | --- | --- |
  | `complex.add` | `complex.complex_add` |
  | `lab.values` / `values` | `lab.lab_values` / `lab_values` |
  | `math.abs` / `abs` | `math.math_abs` / `math_abs` |
  | `math.dot` / `dot` | `math.math_dot` / `math_dot` |
  | `stats.sum` / `sum` | `stats.stats_sum` / `stats_sum` |
  | `stats.mean` / `mean` | `stats.stats_mean` / `stats_mean` |
  | `string.join` / `join` | `string.string_join` / `string_join` |
  | `ui.dispatch` / `dispatch` | `ui.ui_dispatch` / `ui_dispatch` |
