#!/usr/bin/env bash
# Load-bearing edge fixtures for the executable-enrolment graph (#1880).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-enrol-edges.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.github/workflows" "$WORK/tests/sections" "$WORK/tests/phase2" "$WORK/tools" "$WORK/bench" "$WORK/src"

cat >"$WORK/.github/workflows/ci.yml" <<'EOF'
jobs:
  gate:
    steps:
      - run: make freestanding-check
      - run: make lsp
      - run: bash bench/check_regression.sh
      - run: |
          make indented-check
EOF
cat >"$WORK/Makefile" <<'EOF'
LSP := src/eigenlsp
freestanding-check:
	bash tools/freestanding_check.sh
lsp: $(LSP)
$(LSP): src/stdlib.h src/builtin.h
src/stdlib.h: tools/gen_lsp_stdlib_index.sh
	bash tools/gen_lsp_stdlib_index.sh
src/builtin.h: tools/gen_lsp_builtin_index.sh
	bash tools/gen_lsp_builtin_index.sh
indented-check:
	bash tools/indented_check.sh
EOF
cat >"$WORK/tests/sections/fixture.sh" <<'EOF'
python3 tests/test_importer.py
bash tests/phase2/slot_layer.sh
variant=$("$TESTS_DIR/../tools/subst_tool.sh" "$TESTS_DIR/..")
inline=$(tools/bare_subst.sh)
echo "$(tools/quoted_subst.sh)"
EOF
cat >"$WORK/tests/test_importer.py" <<'EOF'
import tools.ai_benchmark
import subprocess
subprocess.run(["python3", "tools/phase2_inventory.py"])
print("tools/orphan.py")
EOF
cat >"$WORK/tests/phase2/slot_layer.sh" <<'EOF'
python3 tools/phase2_inventory.py
EOF
cat >"$WORK/bench/check_regression.sh" <<'EOF'
bash tools/phase2_cost.sh
EOF
for f in freestanding_check.sh gen_lsp_stdlib_index.sh gen_lsp_builtin_index.sh phase2_cost.sh indented_check.sh subst_tool.sh bare_subst.sh quoted_subst.sh; do
    printf '#!/bin/sh\n' >"$WORK/tools/$f"
done
for f in ai_benchmark.py phase2_inventory.py orphan.py; do printf '# fixture\n' >"$WORK/tools/$f"; done

python3 "$ROOT/tools/enrolment_edges.py" "$WORK" >"$WORK/edges"
bad=0
row() {
    if grep -Fxq "$2" "$WORK/edges"; then echo "  PASS: $1"
    else echo "  FAIL: $1 (missing edge: $2)"; bad=1; fi
}
row "make recipe" $'@make:freestanding-check\ttools/freestanding_check.sh'
row "make prerequisite: stdlib generator" $'@make:src/stdlib.h\ttools/gen_lsp_stdlib_index.sh'
row "make prerequisite: builtin generator" $'@make:src/builtin.h\ttools/gen_lsp_builtin_index.sh'
row "Python import" $'tests/test_importer.py\ttools/ai_benchmark.py'
row "Python argv literal from nested tests" $'tests/test_importer.py\ttools/phase2_inventory.py'
row "bench script" $'bench/check_regression.sh\ttools/phase2_cost.sh'
row "indented workflow make" $'.github/workflows/ci.yml\t@make:indented-check'
row "indented make recipe reaches tool" $'@make:indented-check\ttools/indented_check.sh'
row "command substitution in an assignment" $'tests/sections/fixture.sh\ttools/subst_tool.sh'
row "bare command substitution" $'tests/sections/fixture.sh\ttools/bare_subst.sh'
row "quoted command substitution" $'tests/sections/fixture.sh\ttools/quoted_subst.sh'
if grep -Fq $'tests/test_importer.py\ttools/orphan.py' "$WORK/edges"; then
    echo "  FAIL: print string falsely enrolled tools/orphan.py"; bad=1
else
    echo "  PASS: print string is not an execution edge"
fi
# A whole shell file the tokenizer stops on while `bash -n` accepts it must
# fail the gate, naming file and line -- never pass on the prefix (#2559).
# SHELL_TOKENS_PLANT_GAP makes the tokenizer stop at the marker.
printf 'bash tools/phase2_cost.sh\n: PLANT_GAP_MARK\nbash tools/indented_check.sh\n' >"$WORK/tests/gap.sh"
gap_rc=0
SHELL_TOKENS_PLANT_GAP=PLANT_GAP_MARK python3 "$ROOT/tools/enrolment_edges.py" "$WORK" \
    >"$WORK/gap.out" 2>"$WORK/gap.err" || gap_rc=$?
if [ "$gap_rc" -eq 2 ] && grep -Fq 'INSTRUMENT ERROR: tests/gap.sh:2: ' "$WORK/gap.err"; then
    echo "  PASS: plant: enrolment edges refuse a file bash accepts but the tokenizer stops on"
else
    echo "  FAIL: plant: enrolment edges passed on a prefix (rc=$gap_rc)"; cat "$WORK/gap.err"; bad=1
fi
dv_rc=0
SHELL_TOKENS_PLANT_GAP=PLANT_GAP_MARK python3 "$ROOT/tools/_derive_variants.py" --shell "$WORK/tests/gap.sh" \
    >"$WORK/dv.out" 2>"$WORK/dv.err" || dv_rc=$?
if [ "$dv_rc" -eq 2 ] && grep -Fq 'INSTRUMENT ERROR: gap.sh:2: ' "$WORK/dv.err"; then
    echo "  PASS: plant: variant deriver refuses a file bash accepts but the tokenizer stops on"
else
    echo "  FAIL: plant: variant deriver derived from a prefix (rc=$dv_rc)"; cat "$WORK/dv.err"; bad=1
fi
pt_rc=0
PORTABILITY_BASH=/bin/bash PORTABILITY_MAX_MAJOR=99 PORTABILITY_FILES="$WORK/tests/gap.sh" \
    PORTABILITY_FILE_FLOOR=1 PORTABILITY_RUN_TARGETS= PORTABILITY_RUN_N=0 \
    SHELL_TOKENS_PLANT_GAP=PLANT_GAP_MARK bash "$ROOT/tools/portability_parse_check.sh" \
    >"$WORK/pt.out" 2>&1 || pt_rc=$?
if [ "$pt_rc" -ne 0 ] && grep -Fq "INSTRUMENT ERROR: $WORK/tests/gap.sh:2: " "$WORK/pt.out"; then
    echo "  PASS: plant: portability check refuses a file bash accepts but the tokenizer stops on"
else
    echo "  FAIL: plant: portability check read a prefix (rc=$pt_rc)"; cat "$WORK/pt.out"; bad=1
fi
# Control: a file bash rejects too is read up to the line where it stops.
printf 'bash tools/phase2_cost.sh\n: PLANT_GAP_MARK "unclosed\n' >"$WORK/tests/gap.sh"
ctl_rc=0
SHELL_TOKENS_PLANT_GAP=PLANT_GAP_MARK python3 "$ROOT/tools/enrolment_edges.py" "$WORK" \
    >"$WORK/gap.out" 2>"$WORK/gap.err" || ctl_rc=$?
if [ "$ctl_rc" -eq 0 ] && grep -Fxq $'tests/gap.sh\ttools/phase2_cost.sh' "$WORK/gap.out"; then
    echo "  PASS: control: a file bash rejects is read up to where it stops"
else
    echo "  FAIL: control: rc=$ctl_rc for a file bash rejects"; cat "$WORK/gap.err"; bad=1
fi
exit "$bad"
