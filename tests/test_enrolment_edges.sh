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
EOF
cat >"$WORK/tests/sections/fixture.sh" <<'EOF'
python3 tests/test_importer.py
bash tests/phase2/slot_layer.sh
EOF
cat >"$WORK/tests/test_importer.py" <<'EOF'
import tools.ai_benchmark
import subprocess
subprocess.run(["python3", "tools/phase2_inventory.py"])
EOF
cat >"$WORK/tests/phase2/slot_layer.sh" <<'EOF'
python3 tools/phase2_inventory.py
EOF
cat >"$WORK/bench/check_regression.sh" <<'EOF'
bash tools/phase2_cost.sh
EOF
for f in freestanding_check.sh gen_lsp_stdlib_index.sh gen_lsp_builtin_index.sh phase2_cost.sh; do
    printf '#!/bin/sh\n' >"$WORK/tools/$f"
done
for f in ai_benchmark.py phase2_inventory.py; do printf '# fixture\n' >"$WORK/tools/$f"; done

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
exit "$bad"
