# tests/phase2/calib/MAP.md: phase2_check.sh --calibrate fixtures (design 9.2)

Every row ends in a line that fails on the v0.46.0 tag (#1740: `5.5 & 1`
raises `value` on the branch, the tag truncates), so an honest row has
tag_fail == branch_pass. `-plant` rows are the negative witness plants of
design 9.1: the claimed op does not run as claimed, so each must be VACUOUS.

### N1
- `cal.verdict` [R1.3] a straight-line row: #1740 raises `value` on a fractional bitwise operand, the tag truncates
  -> see cal.verdict.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
- `cal.fn-keep` [R1.3] keep runs natively to its return on its 60th call
  -> see cal.fn-keep.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: F  witness: fn keep  ops: SET_LOCAL
- `cal.fn-keep-plant` [R1.3] plant: an unsupported op (LIST) ahead of the claimed one
  -> see cal.fn-keep-plant.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: F  witness: fn keep  ops: SET_LOCAL
- `cal.fn-keep-10calls-plant` [R1.3] plant: 10 calls instead of 60, so the JIT never compiles keep
  -> see cal.fn-keep-10calls-plant.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: F  witness: fn keep  ops: SET_LOCAL

### N3
- `cal.leaf-sq` [R1.3] the leaf computes sq: no entries normally, 1 under trace
  -> see cal.leaf-sq.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: L  witness: leaf sq  ops: MUL
- `cal.leaf-sq-plant` [R1.3] plant: two statements, not leaf-eligible
  -> see cal.leaf-sq-plant.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: L  witness: leaf sq  ops: MUL
- `cal.fnstop-cat` [R1.3] the ADD guard bails on two strings
  -> see cal.fnstop-cat.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: F  witness: fn-stop cat ADD  ops: ADD
- `cal.fnstop-cat-plant` [R1.3] plant: two floats, so ADD runs natively to the return
  -> see cal.fnstop-cat-plant.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: F  witness: fn-stop cat ADD  ops: ADD
- `cal.osrstop-g` [R1.3] every OSR entry hands back at the string ADD
  -> see cal.osrstop-g.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: O  witness: osr-stop g ADD  ops: ADD
- `cal.osrstop-g-plant` [R1.3] plant: a float ADD, which runs natively to the sentinel
  -> see cal.osrstop-g-plant.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: O  witness: osr-stop g ADD  ops: ADD

### N5
- `cal.leafgen-nth` [R1.3] the leaf INDEX_GET bails on a string, the generic call indexes
  -> see cal.leafgen-nth.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: L  witness: leaf-gen nth  ops: INDEX_GET
- `cal.leafgen-nth-plant` [R1.3] plant: a list, which the leaf computes itself
  -> see cal.leafgen-nth-plant.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: L  witness: leaf-gen nth  ops: INDEX_GET
- `cal.osr-fill` [R1.3] the OSR thunk runs the body natively to the return sentinel
  -> see cal.osr-fill.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: O  witness: osr fill  ops: INDEX_SET
- `cal.osr-fill-plant` [R1.3] plant: a string concat ahead of the claimed op, so INDEX_SET never runs natively
  -> see cal.osr-fill-plant.out
  tag: the last line prints 1 (read: v0.46.0 truncates a bitwise operand)
  shape: O  witness: osr fill  ops: INDEX_SET
