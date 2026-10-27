# UI widget state

Binary widget state uses EigenScript's `bool` values, following the standard representation used by Python, Lua, Go, and Rust: `true` and `false`, tested by truthiness. This contract covers `visible`, `enabled`, `hover`, `pressed`, `open`, `focused`, drag/drop activity, `dragging`, `collapsed`, `expanded`, `interactive`, `hover_enabled`, `focusable`, registry `container`/`owns_cells` flags, and the `value` of checkbox, toggle, and toggle-button widgets. Consumers may assign either boolean directly. Numeric `0`/`1` is not accepted as a boolean widget value.

Numeric values remain numeric where they are quantities or choices: slider/spinbox/progress values, tab/radio/dropdown selection indices, hover row/column/button indices, bitmasks, counters, and geometry. Optional fields retain `null` as an explicit absence sentinel; absence is not treated as `false`.

`checkbox` and `toggle` reject a non-boolean initial `value` before measuring or drawing. `dock_set_collapsed` likewise rejects a non-boolean value before changing panel state. Widget dictionaries are intentionally direct state objects; consumers assigning fields themselves must honor the documented field type.
