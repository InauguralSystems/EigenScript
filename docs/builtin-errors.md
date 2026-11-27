# Builtin error tables

Generated from `tests/builtin_errors/` by `tools/builtin_error_table.py --write`. Do not edit.

Counts in [BUILTINS.md](BUILTINS.md) count each table line once per answer kind across its strictness states and backend alternatives.

<a id="tensor_load"></a>

## `tensor_load`

### `type_mismatch`; writes `false`

- `path-bool`: path bool (-; `true`).
- `path-null`: path null (-; `null`).
- `path-list`: path list (flat:2; `[1.5, 2.5]`).
- `path-dict`: path dict (-; `{"x": 1}`).
- `path-buffer`: path buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `path-number`: path number (-; `0.5`).

### `io`; writes `false`

- `short-header`: path string (file; `"@FILE@"`); header [], payload 0 bytes, observer 0 bytes; raw bytes 78.
- `three-words`: path string (file; `"@FILE@"`); header [1, 1, 2], payload 0 bytes, observer 0 bytes.
- `short-payload`: path string (file; `"@FILE@"`); header [2, 1, 2, 0], payload 8 bytes, observer 0 bytes.
- `observer-short`: path string (file; `"@FILE@"`); header [1, 1, 2, 1], payload 16 bytes, observer 72 bytes.
- `observer-empty`: path string (file; `"@FILE@"`); header [2, 1, 2, 1], payload 16 bytes, observer 0 bytes.
- `missing`: path string (missing; `"@FILE@"`); missing.
- `directory`: path string (directory; `"@FILE@"`); directory.
- `census-missing`: path string (missing; `"zz_census_2509"`); missing.

### `value`; writes `false`

- `flags-seven`: path string (file; `"@FILE@"`); header [2, 1, 1, 7], payload 8 bytes, observer 0 bytes.
- `flags-before-ndim`: path string (file; `"@FILE@"`); header [3, 10000, 10000, 7], payload 0 bytes, observer 0 bytes.
- `ndim-before-cap`: path string (file; `"@FILE@"`); header [3, 10000, 10000, 0], payload 0 bytes, observer 0 bytes.
- `zero-rows`: path string (file; `"@FILE@"`); header [1, 0, 1, 0], payload 0 bytes, observer 0 bytes.
- `zero-cols`: path string (file; `"@FILE@"`); header [2, 1, 0, 0], payload 0 bytes, observer 0 bytes.
- `rows-five`: path string (file; `"@FILE@"`); header [1, 5, 2, 0], payload 80 bytes, observer 0 bytes; payload values [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].
- `rows-before-cap`: path string (file; `"@FILE@"`); header [1, 5, 10000000, 0], payload 0 bytes, observer 0 bytes.
- `leg.t`: path string (file; `"@FILE@"`); header [1, 2, 0], payload 16 bytes, observer 0 bytes; payload values [0.0, 5.0].
- `leg2.t`: path string (file; `"@FILE@"`); header [1, 2, 1], payload 16 bytes, observer 0 bytes; payload values [0.0, 5.0].

### `limit`; writes `false`

- `over-cap`: path string (file; `"@FILE@"`); header [2, 10000, 10000, 0], payload 0 bytes, observer 0 bytes.

### `ok`; result [[1, 2]]; writes `false`

- `observer-ok`: path string (file; `"@FILE@"`); header [2, 1, 2, 1], payload 16 bytes, observer 80 bytes.

### `ok`; result [1, 2]; writes `false`

- `payload-ok`: path string (file; `"@FILE@"`); header [1, 1, 2, 0], payload 16 bytes, observer 0 bytes.
- `trailing-bytes`: path string (file; `"@FILE@"`); header [1, 1, 2, 0], payload 16 bytes, observer 0 bytes; 7 trailing bytes.

### `io/io/value (unset/0/1)`; writes `false`

- `nan-before-observer`: path string (file; `"@FILE@"`); header [1, 1, 1, 1], payload 8 bytes, observer 0 bytes; NaN payload.

<a id="sgd_update"></a>

## `sgd_update`

### `type_mismatch`; writes `false`

- `params-bool`: params bool (-; `true`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `params-string`: params string (-; `"x"`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `params-null`: params null (-; `null`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `params-dict`: params dict (-; `{"x": 1}`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `params-buffer`: params buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `params-number`: params number (-; `0.5`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `grad-bool`: params list (flat:2; `[1.5, 2.5]`), grad bool (-; `true`), lr number (-; `0.5`).
- `grad-string`: params list (flat:2; `[1.5, 2.5]`), grad string (-; `"x"`), lr number (-; `0.5`).
- `grad-null`: params list (flat:2; `[1.5, 2.5]`), grad null (-; `null`), lr number (-; `0.5`).
- `grad-dict`: params list (flat:2; `[1.5, 2.5]`), grad dict (-; `{"x": 1}`), lr number (-; `0.5`).
- `grad-buffer`: params list (flat:2; `[1.5, 2.5]`), grad buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`), lr number (-; `0.5`).
- `grad-number`: params list (flat:2; `[1.5, 2.5]`), grad number (-; `0.5`), lr number (-; `0.5`).
- `flat2-flat2-lr-bool`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr bool (-; `true`).
- `flat2-flat2-lr-string`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr string (-; `"x"`).
- `flat2-flat2-lr-list`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr list (flat:2; `[1.5, 2.5]`).
- `flat2-flat2-lr-dict`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr dict (-; `{"x": 1}`).
- `flat2-flat2-lr-buffer`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `flat2-flat3-lr-bool`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:3; `[1.5,2.5,3.5]`), lr bool (-; `true`).
- `rows12-flat2-lr-bool`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr bool (-; `true`).
- `flat2-rows12-lr-bool`: params list (flat:2; `[1.5, 2.5]`), grad list (rows:1x2; `[[1.5,2.5]]`), lr bool (-; `true`).
- `rows22-flat2-lr-bool`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr bool (-; `true`).
- `rows22-flat2-lr-string`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr string (-; `"x"`).
- `rows22-flat2-lr-null`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr null (-; `null`).
- `rows22-flat2-lr-list`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr list (flat:2; `[1.5, 2.5]`).
- `rows22-flat2-lr-dict`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr dict (-; `{"x": 1}`).
- `rows22-flat2-lr-buffer`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `rows22-flat2-lr-number`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `rows22-flat4-lr-bool`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:4; `[1.5,2.5,3.5,4.5]`), lr bool (-; `true`).
- `rows12-rows21-lr-bool`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (rows:2x1; `[[1.5],[2.5]]`), lr bool (-; `true`).
- `rows22-ragged-lr-bool`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2[1,2]; `[[1.5],[2.5,3.5]]`), lr bool (-; `true`).
- `empty-empty-lr-bool`: params list (flat:0; `[]`), grad list (flat:0; `[]`), lr bool (-; `true`).
- `empty-empty-lr-string`: params list (flat:0; `[]`), grad list (flat:0; `[]`), lr string (-; `"x"`).
- `empty-empty-lr-list`: params list (flat:0; `[]`), grad list (flat:0; `[]`), lr list (flat:2; `[1.5, 2.5]`).
- `empty-empty-lr-dict`: params list (flat:0; `[]`), grad list (flat:0; `[]`), lr dict (-; `{"x": 1}`).
- `empty-empty-lr-buffer`: params list (flat:0; `[]`), grad list (flat:0; `[]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `unshaped2-unshaped2-lr-bool`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr bool (-; `true`).
- `unshaped2-unshaped2-lr-string`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr string (-; `"x"`).
- `unshaped2-unshaped2-lr-list`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr list (flat:2; `[1.5, 2.5]`).
- `unshaped2-unshaped2-lr-dict`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr dict (-; `{"x": 1}`).
- `unshaped2-unshaped2-lr-buffer`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `unshaped2-shaped12-lr-bool`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr bool (-; `true`).
- `shaped12-unshaped2-lr-bool`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr bool (-; `true`).
- `shaped12-shaped21-lr-bool`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr bool (-; `true`).
- `shaped22-shaped14-lr-bool`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (1x4; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),1,4]`), lr bool (-; `true`).
- `shaped22-unshaped2-lr-bool`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr bool (-; `true`).
- `shaped22-shaped21-lr-bool`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr bool (-; `true`).
- `shaped12-shaped12-lr-bool`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr bool (-; `true`).
- `shaped12-shaped12-lr-string`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr string (-; `"x"`).
- `shaped12-shaped12-lr-list`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr list (flat:2; `[1.5, 2.5]`).
- `shaped12-shaped12-lr-dict`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr dict (-; `{"x": 1}`).
- `shaped12-shaped12-lr-buffer`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `2495-params-lr-bool`: params list (flat:2; `[1.5, inf]`), grad list (flat:2; `[1.5, 2.5]`), lr bool (-; `true`); setup `inf is 1e400`.
- `2495-params-lr-string`: params list (flat:2; `[1.5, inf]`), grad list (flat:2; `[1.5, 2.5]`), lr string (-; `"x"`); setup `inf is 1e400`.
- `2495-params-lr-list`: params list (flat:2; `[1.5, inf]`), grad list (flat:2; `[1.5, 2.5]`), lr list (flat:2; `[1.5, 2.5]`); setup `inf is 1e400`.
- `2495-params-lr-dict`: params list (flat:2; `[1.5, inf]`), grad list (flat:2; `[1.5, 2.5]`), lr dict (-; `{"x": 1}`); setup `inf is 1e400`.
- `2495-params-lr-buffer`: params list (flat:2; `[1.5, inf]`), grad list (flat:2; `[1.5, 2.5]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`); setup `inf is 1e400`.
- `2495-grad-lr-bool`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, inf]`), lr bool (-; `true`); setup `inf is 1e400`.
- `2495-grad-lr-string`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, inf]`), lr string (-; `"x"`); setup `inf is 1e400`.
- `2495-grad-lr-list`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, inf]`), lr list (flat:2; `[1.5, 2.5]`); setup `inf is 1e400`.
- `2495-grad-lr-dict`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, inf]`), lr dict (-; `{"x": 1}`); setup `inf is 1e400`.
- `2495-grad-lr-buffer`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, inf]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`); setup `inf is 1e400`.

### `ok`; writes `true`

- `params-list`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `grad-list`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `flat2-flat2-lr-null`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr null (-; `null`).
- `flat2-flat2-lr-number`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `unshaped2-unshaped2-lr-null`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr null (-; `null`).
- `unshaped2-unshaped2-lr-number`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr number (-; `0.5`).
- `shaped12-shaped12-lr-null`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr null (-; `null`).
- `shaped12-shaped12-lr-number`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr number (-; `0.5`).

### `value`; writes `false`

- `flat2-flat3-lr-string`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:3; `[1.5,2.5,3.5]`), lr string (-; `"x"`).
- `flat2-flat3-lr-null`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:3; `[1.5,2.5,3.5]`), lr null (-; `null`).
- `flat2-flat3-lr-list`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:3; `[1.5,2.5,3.5]`), lr list (flat:2; `[1.5, 2.5]`).
- `flat2-flat3-lr-dict`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:3; `[1.5,2.5,3.5]`), lr dict (-; `{"x": 1}`).
- `flat2-flat3-lr-buffer`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:3; `[1.5,2.5,3.5]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `flat2-flat3-lr-number`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:3; `[1.5,2.5,3.5]`), lr number (-; `0.5`).
- `rows12-flat2-lr-string`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr string (-; `"x"`).
- `rows12-flat2-lr-null`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr null (-; `null`).
- `rows12-flat2-lr-list`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr list (flat:2; `[1.5, 2.5]`).
- `rows12-flat2-lr-dict`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr dict (-; `{"x": 1}`).
- `rows12-flat2-lr-buffer`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `rows12-flat2-lr-number`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`).
- `flat2-rows12-lr-string`: params list (flat:2; `[1.5, 2.5]`), grad list (rows:1x2; `[[1.5,2.5]]`), lr string (-; `"x"`).
- `flat2-rows12-lr-null`: params list (flat:2; `[1.5, 2.5]`), grad list (rows:1x2; `[[1.5,2.5]]`), lr null (-; `null`).
- `flat2-rows12-lr-list`: params list (flat:2; `[1.5, 2.5]`), grad list (rows:1x2; `[[1.5,2.5]]`), lr list (flat:2; `[1.5, 2.5]`).
- `flat2-rows12-lr-dict`: params list (flat:2; `[1.5, 2.5]`), grad list (rows:1x2; `[[1.5,2.5]]`), lr dict (-; `{"x": 1}`).
- `flat2-rows12-lr-buffer`: params list (flat:2; `[1.5, 2.5]`), grad list (rows:1x2; `[[1.5,2.5]]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `flat2-rows12-lr-number`: params list (flat:2; `[1.5, 2.5]`), grad list (rows:1x2; `[[1.5,2.5]]`), lr number (-; `0.5`).
- `rows22-flat4-lr-string`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:4; `[1.5,2.5,3.5,4.5]`), lr string (-; `"x"`).
- `rows22-flat4-lr-null`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:4; `[1.5,2.5,3.5,4.5]`), lr null (-; `null`).
- `rows22-flat4-lr-list`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:4; `[1.5,2.5,3.5,4.5]`), lr list (flat:2; `[1.5, 2.5]`).
- `rows22-flat4-lr-dict`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:4; `[1.5,2.5,3.5,4.5]`), lr dict (-; `{"x": 1}`).
- `rows22-flat4-lr-buffer`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:4; `[1.5,2.5,3.5,4.5]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `rows22-flat4-lr-number`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (flat:4; `[1.5,2.5,3.5,4.5]`), lr number (-; `0.5`).
- `rows12-rows21-lr-string`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (rows:2x1; `[[1.5],[2.5]]`), lr string (-; `"x"`).
- `rows12-rows21-lr-null`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (rows:2x1; `[[1.5],[2.5]]`), lr null (-; `null`).
- `rows12-rows21-lr-list`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (rows:2x1; `[[1.5],[2.5]]`), lr list (flat:2; `[1.5, 2.5]`).
- `rows12-rows21-lr-dict`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (rows:2x1; `[[1.5],[2.5]]`), lr dict (-; `{"x": 1}`).
- `rows12-rows21-lr-buffer`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (rows:2x1; `[[1.5],[2.5]]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `rows12-rows21-lr-number`: params list (rows:1x2; `[[1.5,2.5]]`), grad list (rows:2x1; `[[1.5],[2.5]]`), lr number (-; `0.5`).
- `rows22-ragged-lr-string`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2[1,2]; `[[1.5],[2.5,3.5]]`), lr string (-; `"x"`).
- `rows22-ragged-lr-null`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2[1,2]; `[[1.5],[2.5,3.5]]`), lr null (-; `null`).
- `rows22-ragged-lr-list`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2[1,2]; `[[1.5],[2.5,3.5]]`), lr list (flat:2; `[1.5, 2.5]`).
- `rows22-ragged-lr-dict`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2[1,2]; `[[1.5],[2.5,3.5]]`), lr dict (-; `{"x": 1}`).
- `rows22-ragged-lr-buffer`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2[1,2]; `[[1.5],[2.5,3.5]]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `rows22-ragged-lr-number`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2[1,2]; `[[1.5],[2.5,3.5]]`), lr number (-; `0.5`).
- `unshaped2-shaped12-lr-string`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr string (-; `"x"`).
- `unshaped2-shaped12-lr-null`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr null (-; `null`).
- `unshaped2-shaped12-lr-list`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr list (flat:2; `[1.5, 2.5]`).
- `unshaped2-shaped12-lr-dict`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr dict (-; `{"x": 1}`).
- `unshaped2-shaped12-lr-buffer`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `unshaped2-shaped12-lr-number`: params buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), grad buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), lr number (-; `0.5`).
- `shaped12-unshaped2-lr-string`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr string (-; `"x"`).
- `shaped12-unshaped2-lr-null`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr null (-; `null`).
- `shaped12-unshaped2-lr-list`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr list (flat:2; `[1.5, 2.5]`).
- `shaped12-unshaped2-lr-dict`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr dict (-; `{"x": 1}`).
- `shaped12-unshaped2-lr-buffer`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `shaped12-unshaped2-lr-number`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr number (-; `0.5`).
- `shaped12-shaped21-lr-string`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr string (-; `"x"`).
- `shaped12-shaped21-lr-null`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr null (-; `null`).
- `shaped12-shaped21-lr-list`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr list (flat:2; `[1.5, 2.5]`).
- `shaped12-shaped21-lr-dict`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr dict (-; `{"x": 1}`).
- `shaped12-shaped21-lr-buffer`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `shaped12-shaped21-lr-number`: params buffer (1x2; `reshape of [buf_from_list of ([1.5,2.5]),1,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr number (-; `0.5`).
- `shaped22-shaped14-lr-string`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (1x4; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),1,4]`), lr string (-; `"x"`).
- `shaped22-shaped14-lr-null`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (1x4; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),1,4]`), lr null (-; `null`).
- `shaped22-shaped14-lr-list`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (1x4; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),1,4]`), lr list (flat:2; `[1.5, 2.5]`).
- `shaped22-shaped14-lr-dict`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (1x4; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),1,4]`), lr dict (-; `{"x": 1}`).
- `shaped22-shaped14-lr-buffer`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (1x4; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),1,4]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `shaped22-shaped14-lr-number`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (1x4; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),1,4]`), lr number (-; `0.5`).
- `shaped22-unshaped2-lr-string`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr string (-; `"x"`).
- `shaped22-unshaped2-lr-null`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr null (-; `null`).
- `shaped22-unshaped2-lr-list`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr list (flat:2; `[1.5, 2.5]`).
- `shaped22-unshaped2-lr-dict`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr dict (-; `{"x": 1}`).
- `shaped22-unshaped2-lr-buffer`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `shaped22-unshaped2-lr-number`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (unshaped:2; `buf_from_list of ([1.5,2.5])`), lr number (-; `0.5`).
- `shaped22-shaped21-lr-string`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr string (-; `"x"`).
- `shaped22-shaped21-lr-null`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr null (-; `null`).
- `shaped22-shaped21-lr-list`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr list (flat:2; `[1.5, 2.5]`).
- `shaped22-shaped21-lr-dict`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr dict (-; `{"x": 1}`).
- `shaped22-shaped21-lr-buffer`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`).
- `shaped22-shaped21-lr-number`: params buffer (2x2; `reshape of [buf_from_list of ([1.5,2.5,3.5,4.5]),2,2]`), grad buffer (2x1; `reshape of [buf_from_list of ([1.5,2.5]),2,1]`), lr number (-; `0.5`).
- `2495-params`: params list (flat:2; `[1.5, inf]`), grad list (flat:2; `[1.5, 2.5]`), lr number (-; `0.5`); setup `inf is 1e400`.
- `2495-grad`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, inf]`), lr number (-; `0.5`); setup `inf is 1e400`.
- `2495-params-lr-null`: params list (flat:2; `[1.5, inf]`), grad list (flat:2; `[1.5, 2.5]`), lr null (-; `null`); setup `inf is 1e400`.
- `2495-later-row-params`: params list (rows:2x2; `[[1.5,2.5],[3.5,inf]]`), grad list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), lr number (-; `0.5`); setup `inf is 1e400`.
- `2495-grad-lr-null`: params list (flat:2; `[1.5, 2.5]`), grad list (flat:2; `[1.5, inf]`), lr null (-; `null`); setup `inf is 1e400`.
- `2495-later-row-grad`: params list (rows:2x2; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2x2; `[[1.5,2.5],[3.5,inf]]`), lr number (-; `0.5`); setup `inf is 1e400`.
- `later-shape-149`: params list (rows:2[2, 2]; `[[1.5,2.5],[3.5,4.5]]`), grad list (rows:2[2, 1]; `[[1.5,2.5],[3.5]]`), lr number (-; `0.5`).
- `later-shape-150`: params list (rows:1[2]; `[[1.5,2.5]]`), grad list (rows:2[2, 2]; `[[1.5,2.5],[3.5,4.5]]`), lr number (-; `0.5`).
- `census-empty-grad`: params list (flat:0; `[]`), grad list (flat:1; `[2]`), lr number (-; `0.5`).

### `ok`; writes `false`

- `empty-empty-lr-null`: params list (flat:0; `[]`), grad list (flat:0; `[]`), lr null (-; `null`).
- `empty-empty-lr-number`: params list (flat:0; `[]`), grad list (flat:0; `[]`), lr number (-; `0.5`).

<a id="audio_music_play"></a>

## `audio_music_play`

### `type_mismatch`; writes `false`

- `path-bool`: path bool (-; `true`), loops number (-; `0`); missing.
- `path-null`: path null (-; `null`), loops number (-; `0`); missing.
- `path-list`: path list (flat:2; `[1.5, 2.5]`), loops number (-; `0`); missing.
- `path-dict`: path dict (-; `{"x": 1}`), loops number (-; `0`); missing.
- `path-buffer`: path buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`), loops number (-; `0`); missing.
- `path-number`: path number (-; `0.5`), loops number (-; `0`); missing.
- `loops-bool`: path string (missing; `"@FILE@"`), loops bool (-; `true`); missing.
- `loops-string`: path string (missing; `"@FILE@"`), loops string (-; `"x"`); missing.
- `loops-null`: path string (missing; `"@FILE@"`), loops null (-; `null`); missing.
- `loops-list`: path string (missing; `"@FILE@"`), loops list (flat:2; `[1.5, 2.5]`); missing.
- `loops-dict`: path string (missing; `"@FILE@"`), loops dict (-; `{"x": 1}`); missing.
- `loops-buffer`: path string (missing; `"@FILE@"`), loops buffer (unshaped:2; `buf_from_list of ([1.5, 2.5])`); missing.

### `io`; writes `false`

- `path-string`: path string (missing; `"@FILE@"`), loops number (-; `0`); missing.
- `directory`: path string (directory; `"@FILE@"`), loops number (-; `0`); directory.

### `value`; writes `false`

- `loops-number`: path string (missing; `"@FILE@"`), loops number (-; `0.5`); missing.
- `fraction`: path string (missing; `"@FILE@"`), loops number (-; `0.5`); missing.
- `huge`: path string (missing; `"@FILE@"`), loops number (-; `2147483648`); missing.

### `io`; writes `false` with usable dummy audio backend; `ok`; result false; writes `false` when unavailable

- `decode`: path string (invalid; `"@FILE@"`), loops number (-; `0`); invalid.

### `ok`; result true; writes `false` with usable dummy audio backend; `ok`; result false; writes `false` when unavailable

- `valid`: path string (wav; `"@FILE@"`), loops number (-; `0`); wav.

### `ok`; result false; writes `false`

- `no-device`: path string (wav; `"@FILE@"`), loops number (-; `0`); wav; SDL driver not-an-sdl-driver.
- `decode-no-device`: path string (invalid; `"@FILE@"`), loops number (-; `0`); invalid; SDL driver not-an-sdl-driver.

