#!/bin/bash
# #727: the JSON model loader must reject an incomplete or misordered
# checkpoint loudly instead of committing it — a short `layers` array
# used to leave layer weight pointers NULL (deref in
# requantize_all_layers), weight arrays parsed before `config` were
# sized from a zeroed config (heap-OOB read at inference), and a
# checkpoint missing whole sections still set loaded=1. Mirrors the
# validate-then-commit discipline the .eigen loader always had.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
BIN="$SRC_DIR/eigenscript"

PASS=0
FAIL=0

# Probe: model extension present? (Skip cleanly if built minimal.)
PROBE=$(mktemp /tmp/eigs_mi_XXXXXX.eigs)
cat > "$PROBE" <<'E'
r is eigen_model_load of "/nonexistent.json"
print of r
E
OUT=$("$BIN" "$PROBE" 2>&1)
rm -f "$PROBE"
if echo "$OUT" | grep -q "undefined variable"; then
    echo "SKIP: model extension not built (model_incomplete)"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available (model_incomplete)"
    exit 0
fi

GOOD=$(mktemp /tmp/eigs_good_XXXXXX.json)
python3 "$TESTS_DIR/gen_tiny_model.py" > "$GOOD" 2>/dev/null

# One helper: load a checkpoint, print rejected/accepted, never crash.
run_case() {
    local label="$1" file="$2" expect="$3"
    local script out rc
    script=$(mktemp /tmp/eigs_mi_XXXXXX.eigs)
    cat > "$script" <<E
r is eigen_model_load of "$file"
if contains of [r, "error"]:
    print of "rejected"
else:
    print of "accepted"
E
    out=$(timeout 10 "$BIN" "$script" 2>&1)
    rc=$?
    rm -f "$script"
    if [ $rc -ne 0 ] && [ $rc -ne 1 ]; then
        echo "  FAIL: $label caused exit $rc (crash?)"
        FAIL=$((FAIL + 1))
    elif echo "$out" | grep -q "$expect"; then
        echo "  PASS: $label $expect"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label expected $expect"
        echo "$out" | tail -3
        FAIL=$((FAIL + 1))
    fi
}

# MI1: control — the generated tiny model still loads.
run_case "MI1 valid tiny checkpoint" "$GOOD" "accepted"

# MI2: short layers array — config says n_layers, the array has fewer.
SHORT=$(mktemp /tmp/eigs_short_XXXXXX.json)
python3 - "$GOOD" "$SHORT" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["config"]["n_layers"] = 2          # keep the single layer in place
json.dump(m, open(sys.argv[2], "w"))
PY
run_case "MI2 short layers array" "$SHORT" "rejected"

# MI3: weight array before config — sizes must not come from a zeroed config.
REORD=$(mktemp /tmp/eigs_reord_XXXXXX.json)
python3 - "$GOOD" "$REORD" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
out = {"format_version": m["format_version"],
       "token_embeddings": m["token_embeddings"]}   # before config
for k, v in m.items():
    if k not in out:
        out[k] = v
json.dump(out, open(sys.argv[2], "w"))
PY
run_case "MI3 weights before config" "$REORD" "rejected"

# MI4: missing output_proj — incomplete checkpoint must not set loaded.
NOOUT=$(mktemp /tmp/eigs_noout_XXXXXX.json)
python3 - "$GOOD" "$NOOUT" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
del m["output_proj"]
json.dump(m, open(sys.argv[2], "w"))
PY
run_case "MI4 missing output_proj" "$NOOUT" "rejected"

# MI5: a rejected load leaves the runtime usable — the valid model still
# loads afterward (the live model is untouched by a failed parse).
BOTH=$(mktemp /tmp/eigs_mi_XXXXXX.eigs)
cat > "$BOTH" <<E
bad is eigen_model_load of "$NOOUT"
good is eigen_model_load of "$GOOD"
if contains of [good, "error"]:
    print of "second-load-broken"
else:
    print of "second-load-ok"
E
OUT5=$(timeout 10 "$BIN" "$BOTH" 2>&1)
RC5=$?
rm -f "$BOTH"
if [ $RC5 -ne 0 ] && [ $RC5 -ne 1 ]; then
    echo "  FAIL: MI5 reject-then-load caused exit $RC5 (crash?)"
    FAIL=$((FAIL + 1))
elif echo "$OUT5" | grep -q "second-load-ok"; then
    echo "  PASS: MI5 valid load succeeds after a rejected one"
    PASS=$((PASS + 1))
else
    echo "  FAIL: MI5 valid load broken after a rejected one"
    echo "$OUT5" | tail -3
    FAIL=$((FAIL + 1))
fi

rm -f "$GOOD" "$SHORT" "$REORD" "$NOOUT"

echo ""
if [ $FAIL -gt 0 ]; then
    exit 1
fi
echo "All model-incomplete tests passed"
exit 0
