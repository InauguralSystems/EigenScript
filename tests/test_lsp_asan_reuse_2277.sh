#!/usr/bin/env bash
# #2277: the ASan shards' LSP sanitizer step must LINK the sanitizer LSP from
# the runtime objects the shard already built, not compile a second sanitizer
# variant on the critical path, and it must not be able to pass vacuously.
#
#   tests/test_lsp_asan_reuse_2277.sh             check the tree
#   tests/test_lsp_asan_reuse_2277.sh --selftest  control + planted faults
#
# Checks (each reads the REAL file: ci.yml via PyYAML, the Makefile via make,
# tests/test_lsp_asan.sh by running it against a stub `make`):
#   C1 ci.yml: the LSP step's LSP_ASAN_VARIANT is the variant the job's
#      "Build with AddressSanitizer + UBSan" step builds, and the step's run:
#      body does not override it inline (which would bypass the env: value).
#   C2 Makefile: `make -n -B lsp-asan lsp-arming-test` for that variant writes
#      only build/<variant>/ outputs (no second variant's objects).
#   C3 Makefile: a non-ASan LSP_ASAN_VARIANT is refused.
#   C4 test_lsp_asan.sh hands LSP_ASAN_VARIANT to both make variables.
#   C5 test_lsp_asan.sh refuses a non-ASan variant before building.
#   C6 test_lsp_asan.sh FAILS (never skips) without python3.
#   C7 a shard whose LSP step did not run writes lsp_asan=no in its receipt.
#   C8 the aggregator fails when no shard claims lsp_asan (and passes on one).
#   C9 Makefile: an invalid LSP_ASAN_VARIANT does not break unrelated targets
#      (the refusal is in the lsp-asan recipe, not at parse time).
#   C10 test_lsp_asan.sh refuses an uninstrumented eigenlsp AND an
#      uninstrumented arming witness (__asan_init check on both binaries).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "lsp_asan_reuse: INSTRUMENT ERROR: python3 missing"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "lsp_asan_reuse: INSTRUMENT ERROR: PyYAML missing"; exit 2; }
BASH_BIN=$(command -v bash)
W=$(mktemp -d "${TMPDIR:-/tmp}/lsp_asan_reuse.XXXXXX"); trap 'rm -rf "$W"' EXIT

BUILD_STEP="Build with AddressSanitizer + UBSan"
LSP_STEP_PREFIX="Behavior-test the LSP under sanitizers"
RECEIPT_STEP="Write the shard receipt"
AGG_STEP="Require one receipt per shard, and a summed leak tally of zero"

# step_field CI STEP_NAME_PREFIX FIELD -> prints the field of the unique step
# in job sanitizers-core (or the whole workflow for the aggregator).
step_field() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
want, field = sys.argv[2], sys.argv[3]
st = [s for j in wf["jobs"].values() for s in j.get("steps") or []
      if str(s.get("name", "")).startswith(want)]
if len(st) != 1:
    print(f"__ERROR__ {len(st)} steps named {want!r}"); sys.exit(0)
s = st[0]
if field == "run":
    print(s.get("run", ""))
elif field.startswith("env."):
    print((s.get("env") or {}).get(field[4:], ""))
PY
}

# Stub bin dirs: one with a recording `make`, one without python3 at all.
mkdir -p "$W/stub" "$W/nopy"
cat > "$W/stub/make" <<EOF
#!$BASH_BIN
printf '%s\n' "\$*" >> "\$STUB_MAKE_LOG"
exit 3
EOF
chmod +x "$W/stub/make"
cp "$W/stub/make" "$W/nopy/make"
ln -s "$(command -v dirname)" "$W/nopy/dirname"
# C10's stubs: make succeeds, nm reports __asan_init except for the binary
# whose path matches $STUB_NM_BARE, python3 records that the harness ran.
mkdir -p "$W/nmstub"
cat > "$W/nmstub/make" <<EOF
#!$BASH_BIN
exit 0
EOF
cat > "$W/nmstub/nm" <<EOF
#!$BASH_BIN
case "\$1" in *"\$STUB_NM_BARE") exit 0 ;; esac
echo "                 U __asan_init"
EOF
cat > "$W/nmstub/python3" <<EOF
#!$BASH_BIN
echo "python3 \$*" >> "\$STUB_MAKE_LOG"
exit 0
EOF
chmod +x "$W/nmstub/make" "$W/nmstub/nm" "$W/nmstub/python3"

# run_checks CI MAKEFILE SCRIPT -> one "ok Cn" / "bad Cn: why" line per check.
run_checks() {
    local ci=$1 mk=$2 script=$3 v run out rc log d
    # C1
    run=$(step_field "$ci" "$BUILD_STEP" run)
    v=$(printf '%s\n' "$run" | sed -n 's/^make \([a-z][a-z-]*\)[[:space:]]*$/\1/p' | head -1)
    local lspv lsprun
    lspv=$(step_field "$ci" "$LSP_STEP_PREFIX" env.LSP_ASAN_VARIANT)
    lsprun=$(step_field "$ci" "$LSP_STEP_PREFIX" run)
    if [ -z "$v" ]; then echo "bad C1: cannot read the shard build variant from '$run'"
    elif [ "$lspv" != "$v" ]; then echo "bad C1: LSP step LSP_ASAN_VARIANT='$lspv', shard builds '$v'"
    elif [[ $lsprun != *"test_lsp_asan.sh"* ]]; then echo "bad C1: LSP step does not run test_lsp_asan.sh"
    elif printf '%s\n' "$lsprun" | grep -qE 'LSP_ASAN_VARIANT[[:space:]]*='; then
        echo "bad C1: LSP step's run: body overrides LSP_ASAN_VARIANT inline: $(printf '%s\n' "$lsprun" | grep -E 'LSP_ASAN_VARIANT[[:space:]]*=' | head -1)"
    else echo "ok C1 (shard builds $v; LSP step links $lspv)"; fi
    [ -n "$v" ] || v=asan-server
    # C2
    out=$(make -n -B -f "$mk" -C "$ROOT" lsp-asan lsp-arming-test LSP_ASAN_VARIANT="$v" LSP_ARMING_VARIANT="$v" 2>&1); rc=$?
    local outs stray
    outs=$(printf '%s\n' "$out" | grep -oE -- '-o build/[^ ]+' | sed 's/^-o //')
    stray=$(printf '%s\n' "$outs" | grep -v "^build/$v/" | head -3 | tr '\n' ' ')
    if [ "$rc" -ne 0 ]; then echo "bad C2: make -n failed rc=$rc: $(printf '%s' "$out" | tail -1)"
    elif ! printf '%s\n' "$outs" | grep -qx "build/$v/lsp/eigenlsp"; then echo "bad C2: make -n does not link build/$v/lsp/eigenlsp"
    elif [ -n "$stray" ]; then echo "bad C2: the $v LSP build writes outside build/$v/: $stray"
    else echo "ok C2 ($(printf '%s\n' "$outs" | grep -c .) outputs, all under build/$v/)"; fi
    # C3
    out=$(make -n -f "$mk" -C "$ROOT" lsp-asan LSP_ASAN_VARIANT=release 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [[ $out == *"not an ASan variant"* ]]; then echo "ok C3 (release refused)"
    else echo "bad C3: make lsp-asan LSP_ASAN_VARIANT=release rc=$rc, not refused"; fi
    # C4
    log="$W/make.log"; : > "$log"
    out=$(STUB_MAKE_LOG="$log" LSP_ASAN_VARIANT="$v" PATH="$W/stub:$PATH" "$BASH_BIN" "$script" 2>&1); rc=$?
    if grep -q "lsp-asan lsp-arming-test LSP_ASAN_VARIANT=$v LSP_ARMING_VARIANT=$v\$" "$log"; then echo "ok C4 (make got both variables = $v)"
    else echo "bad C4: test_lsp_asan.sh called make with: $(cat "$log")"; fi
    # C5
    : > "$log"
    out=$(STUB_MAKE_LOG="$log" LSP_ASAN_VARIANT=release PATH="$W/stub:$PATH" "$BASH_BIN" "$script" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [ ! -s "$log" ] && [[ $out == *"not an ASan variant"* ]]; then echo "ok C5 (release refused before make)"
    else echo "bad C5: LSP_ASAN_VARIANT=release rc=$rc, make called: $(cat "$log")"; fi
    # C6
    : > "$log"
    out=$(STUB_MAKE_LOG="$log" PATH="$W/nopy" "$BASH_BIN" "$script" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [[ $out == *"FAIL:"* ]]; then echo "ok C6 (no python3 -> rc=$rc)"
    else echo "bad C6: without python3 the script exited rc=$rc: $out"; fi
    # C7 + C8: run the real receipt writer and aggregator bodies.
    d="$W/agg"; rm -rf "$d"; mkdir -p "$d/tools" "$d/tests" "$d/shard-receipts"
    cp "$ROOT/tools/lsan_baseline_check.sh" "$d/tools/"
    cp "$ROOT/tests/lsan_tolerated_reports.txt" "$d/tests/"
    step_field "$ci" "$RECEIPT_STEP" run | sed 's/\${{ matrix.shard }}/1/g' > "$d/receipt.sh"
    printf 'PLAN: shard=1/3 bearing=100 chunks=100\n' > "$d/shard.log"
    (cd "$d" && env -u lsp_asan -u gc_traversal GITHUB_WORKSPACE="$d" "$BASH_BIN" receipt.sh >/dev/null 2>&1)
    if grep -qx 'lsp_asan=no' "$d/shard-1.txt" 2>/dev/null; then echo "ok C7 (unrun step -> lsp_asan=no)"
    else echo "bad C7: receipt of a shard whose LSP step did not run: $(tr '\n' ' ' < "$d/shard-1.txt" 2>/dev/null)"; fi
    step_field "$ci" "$AGG_STEP" run | sed -e 's/\${{ env.ASAN_SHARDS }}/3/g' -e 's/\${{ needs.scope.outputs.code }}/true/g' > "$d/agg.sh"
    local k claim aggr0 aggr1 out0
    for claim in none one; do
        rm -f "$d/shard-receipts/"*
        for k in 1 2 3; do
            { echo "PLAN: shard=$k/3 bearing=100 chunks=100 predicted=1s unmeasured=0"; echo "leaked=0"
              if [ "$k" = 1 ]; then echo "gc_traversal=yes"; else echo "gc_traversal=no"; fi
              if [ "$k" = 1 ] && [ "$claim" = one ]; then echo "lsp_asan=yes"; else echo "lsp_asan=no"; fi
            } > "$d/shard-receipts/shard-$k.txt"
        done
        out=$(cd "$d" && "$BASH_BIN" agg.sh 2>&1); rc=$?
        if [ "$claim" = none ]; then aggr0=$rc; out0=$out; else aggr1=$rc; fi
    done
    if [ "$aggr0" -ne 0 ] && [[ $out0 == *"lsp_asan was claimed by 0 shard(s)"* ]] && [ "$aggr1" -eq 0 ]; then
        echo "ok C8 (0 claimants -> rc=$aggr0; 1 claimant -> rc=0)"
    else echo "bad C8: 0 claimants rc=$aggr0, 1 claimant rc=$aggr1: $(printf '%s' "$out0" | tail -1)"; fi
    # C9
    out=$(make -n -f "$mk" -C "$ROOT" clean LSP_ASAN_VARIANT=release 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then echo "ok C9 (make -n clean with LSP_ASAN_VARIANT=release rc=0)"
    else echo "bad C9: an invalid LSP_ASAN_VARIANT breaks 'make clean' rc=$rc: $(printf '%s' "$out" | tail -1)"; fi
    # C10: each binary uninstrumented in turn must fail before the harness runs.
    local bare why=""
    for bare in /lsp/eigenlsp /test_lsp_arming; do
        : > "$log"
        out=$(STUB_MAKE_LOG="$log" STUB_NM_BARE="$bare" LSP_ASAN_VARIANT="$v" PATH="$W/nmstub:$PATH" "$BASH_BIN" "$script" 2>&1); rc=$?
        if [ "$rc" -eq 0 ] || [[ $out != *"$bare is not AddressSanitizer-instrumented"* ]] || grep -q '^python3 ' "$log"; then
            why="$why uninstrumented ...$bare -> rc=$rc, harness ran=$(grep -c '^python3 ' "$log");"
        fi
    done
    : > "$log"
    out=$(STUB_MAKE_LOG="$log" STUB_NM_BARE=/no-such-binary LSP_ASAN_VARIANT="$v" PATH="$W/nmstub:$PATH" "$BASH_BIN" "$script" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q '^python3 ' "$log"; then why="$why both instrumented -> rc=$rc, harness ran=$(grep -c '^python3 ' "$log");"; fi
    if [ -z "$why" ]; then echo "ok C10 (uninstrumented eigenlsp or arming witness refused; both instrumented -> harness runs)"
    else echo "bad C10:$why"; fi
}

CI="$ROOT/.github/workflows/ci.yml" MK="$ROOT/Makefile" SCRIPT="$ROOT/tests/test_lsp_asan.sh"
NCHECKS=10

case "${1:-}" in
    "")
        res=$(run_checks "$CI" "$MK" "$SCRIPT")
        echo "PLAN: $NCHECKS"
        printf '%s\n' "$res" | sed -e 's/^ok /  PASS: /' -e 's/^bad /  FAIL: /'
        [ "$(printf '%s\n' "$res" | grep -c '^ok ')" -eq "$NCHECKS" ] || exit 1
        exit 0 ;;
    --selftest) ;;
    *) echo "usage: tests/test_lsp_asan_reuse_2277.sh [--selftest]" >&2; exit 2 ;;
esac

# plant NAME FILE(ci|mk|script) CHECK PYTHON-REPLACE-OLD PYTHON-REPLACE-NEW
n=0 fail=0
plant() {
    local name=$1 which=$2 want=$3 old=$4 new=$5 ci=$CI mk=$MK script=$SCRIPT src dst res
    case "$which" in ci) src=$CI ;; mk) src=$MK ;; script) src=$SCRIPT ;; esac
    dst="$W/planted.$which"
    python3 - "$src" "$dst" "$old" "$new" <<'PY' || { echo "lsp_asan_reuse selftest: INSTRUMENT ERROR, plant '$name' did not apply"; exit 2; }
import sys
s = open(sys.argv[1]).read()
if s.count(sys.argv[3]) != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4]))
PY
    case "$which" in ci) ci=$dst ;; mk) mk=$dst ;; script) script=$dst ;; esac
    res=$(run_checks "$ci" "$mk" "$script"); n=$((n + 1))
    if printf '%s\n' "$res" | grep -q "^bad $want:"; then echo "  PASS: plant $name caught by $want"
    else echo "  FAIL: plant $name NOT caught by $want"; printf '%s\n' "$res" | sed 's/^/    /'; fail=$((fail + 1)); fi
}

res=$(run_checks "$CI" "$MK" "$SCRIPT"); n=$((n + 1))
if [ "$(printf '%s\n' "$res" | grep -c '^ok ')" -eq "$NCHECKS" ]; then echo "  PASS: control: the tree passes all $NCHECKS checks"
else echo "  FAIL: control: the tree fails a check"; printf '%s\n' "$res" | sed 's/^/    /'; fail=$((fail + 1)); fi

plant "LSP step links the asan objects" ci C1 \
    "          LSP_ASAN_VARIANT: asan-server" "          LSP_ASAN_VARIANT: asan"
plant "LSP step without LSP_ASAN_VARIANT" ci C1 \
    "        env:
          LSP_ASAN_VARIANT: asan-server
" ""
plant "pre-#2277 runtime objects (OBJ_asan)" mk C2 \
    'LSP_ASAN_RUNTIME_OBJ := $(filter-out $(patsubst $(SRC_DIR)/%.c,build/$(LSP_ASAN_VARIANT)/%.o,$(CLI_ONLY)),$(OBJ_$(LSP_ASAN_VARIANT)))' \
    'LSP_ASAN_RUNTIME_OBJ := $(filter-out $(patsubst $(SRC_DIR)/%.c,build/asan/%.o,$(CLI_ONLY)),$(OBJ_asan))'
plant "Makefile accepts any variant" mk C3 \
    "\$(error LSP_ASAN_VARIANT='\$(LSP_ASAN_VARIANT)' is not an ASan variant (allowed: \$(LSP_ASAN_VARIANTS_OK)))" ""
plant "pre-#2277 make call (asan arming, default LSP)" script C4 \
    'make -C "$ROOT" lsp-asan lsp-arming-test LSP_ASAN_VARIANT="$VARIANT" LSP_ARMING_VARIANT="$VARIANT" >/dev/null' \
    'make -C "$ROOT" lsp-asan lsp-arming-test LSP_ARMING_VARIANT=asan >/dev/null'
plant "script accepts any variant" script C5 \
    '    asan|asan-server) ;;' '    *) ;;'
plant "pre-#2277 python3 skip (exit 0)" script C6 \
    '    echo "FAIL: python3 not available — the LSP sanitizer behaviour test cannot run"
    exit 1' '    echo "SKIP: python3 not available"
    exit 0'
plant "receipt defaults lsp_asan to yes" ci C7 \
    'echo "lsp_asan=${lsp_asan:-no}"' 'echo "lsp_asan=${lsp_asan:-yes}"'
plant "aggregator stops counting lsp_asan claimants" ci C8 \
    "for extra in gc_traversal lsp_asan; do" "for extra in gc_traversal; do"
plant "LSP step overrides the variant inline in run:" ci C1 \
    "cd tests && bash test_lsp_asan.sh" "cd tests && LSP_ASAN_VARIANT=asan bash test_lsp_asan.sh"
plant "parse-time variant refusal (breaks every make call)" mk C9 \
    "lsp-asan:
	\$(error LSP_ASAN_VARIANT=" "\$(error LSP_ASAN_VARIANT="
plant "__asan_init checked on eigenlsp only" script C10 \
    'for bin in "$LSP" "$ARMING"; do' 'for bin in "$LSP"; do'
plant "__asan_init checked on the arming witness only" script C10 \
    'for bin in "$LSP" "$ARMING"; do' 'for bin in "$ARMING"; do'

[ "$n" -eq 14 ] || { echo "lsp_asan_reuse selftest: ran $n cases, want 14"; exit 1; }
echo "PLAN: $n"
echo "lsp_asan_reuse selftest: $((n - fail)) of $n passed"
[ "$fail" -eq 0 ]
