# UI widget state

Binary widget state uses EigenScript's `bool` values, following the standard representation used by Python, Lua, Go, and Rust: `true` and `false`, tested by truthiness. This contract covers `visible`, `enabled`, `hover`, `pressed`, `open`, `focused`, drag/drop activity, `dragging`, `collapsed`, `expanded`, `interactive`, `hover_enabled`, `auto_size`, `vertical`, chart display flags (`auto_scale`, `grid`, `axes`, `legend`, `fixed_aspect`), `line_numbers`, `sort_asc`, `draggable`, registry `container`/`clip`/`focusable`/`no_dblclick` and `owns_cells` flags, and the `value` of checkbox, toggle, and toggle-button widgets. Consumers may assign either boolean directly. Numeric `0`/`1` is not accepted as a boolean widget value.

Numeric values remain numeric where they are quantities or choices: slider/spinbox/progress values, tab/radio/dropdown selection indices, hover row/column/button indices, bitmasks, counters, and geometry. Optional fields retain `null` as an explicit absence sentinel; absence is not treated as `false`.

For hand-built dictionaries, a missing flag retains the result of the v0.48.0 numeric comparison at each read site:

| Missing flag | Result |
|---|---|
| `visible` | A negative visibility guard does not hide the widget; a positive-only visibility branch does not draw or process it. |
| `enabled` | A disabled guard does not reject the widget, but a positive-only activation branch does not activate it. |
| `auto_size`, `owns_cells`, `auto_scale` | The omitted flag takes the enabled path: labels are measured, grids own their cells, and charts derive data bounds. |
| `fixed_aspect`, `expanded`, `draggable` | The omitted flag takes the disabled path: aspect correction, expansion, and drag start do not occur. |
| `hover`, `pressed`, `open`, `focused`, drag/drop `active`, `dragging`, `collapsed`, `interactive`, `hover_enabled`, `vertical`, chart `grid`/`axes`/`legend`, `line_numbers`, `sort_asc`, registry `container`/`clip`/`focusable`/`no_dblclick`, checkbox/toggle/toggle-button `value`, and derived `has_children`/`_have_bounds` | A positive-only branch is not taken. A negative guard that was formerly `flag == 0` is also not taken; a negative guard formerly written `flag != 1` is taken. Thus `null` remains distinct from explicit `false`. |


A missing key reads as `null`; it is not normalized to either boolean:

```eigenscript
widget is {}
print of (widget.visible == null)
```
```output
true
```

`scrollbar` requires a boolean `vertical` state before computing geometry. The `separator` constructor's orientation argument remains a numeric geometry code (`1` vertical, `0` horizontal); it is not stored in the widget, and a non-number raises `separator: vertical must be num, got <type>`. `checkbox` and `toggle` reject a non-boolean initial `value` before measuring or drawing. `dock_set_collapsed` likewise rejects a non-boolean value before changing panel state. Widget dictionaries are intentionally direct state objects; consumers assigning fields themselves must honor the documented field type.

`property_editor` validates every boolean property before constructing or measuring any row. Tweens interpolate numeric fields; attempting to animate a checkbox, toggle, or toggle-button `value` raises before changing the animation queue. Assign those boolean values directly.
