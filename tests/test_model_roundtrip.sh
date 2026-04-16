#!/bin/bash
# Model save/load/infer roundtrip test.
# Runs only when the binary is built with EIGENSCRIPT_EXT_MODEL=1
# (gated by run_all_tests.sh).
#
# Steps:
#  1. Generate a tiny v2 model via gen_tiny_model.eigs -> /tmp/eigs_mrt_src.json
#  2. Load that model, query info, save to /tmp/eigs_mrt_dst.json
#  3. In a FRESH process, load the saved file and confirm identical vocab_size/d_model
#  4. Generate tokens and confirm length + type invariants

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

SRC_MODEL=/tmp/eigs_mrt_src.json
DST_MODEL=/tmp/eigs_mrt_dst.json

cleanup() { rm -f "$SRC_MODEL" "$DST_MODEL" /tmp/eigs_mrt_*.log /tmp/eigs_mrt_*.eigs; }
trap cleanup EXIT

# ---- Step 1: generate tiny model ----
if ! "$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$SRC_MODEL" 2>/tmp/eigs_mrt_gen.log; then
    fail "MRT01 generate tiny model" "see /tmp/eigs_mrt_gen.log"
    echo "MODEL_RT: 0 passed, 1 failed"
    exit 1
fi
# Sanity: produced file has format_version
if grep -q 'format_version' "$SRC_MODEL"; then
    ok "MRT01 tiny model JSON generated with format_version"
else
    fail "MRT01 tiny model JSON" "missing format_version"
fi

# ---- Step 2: load and save ----
SCRIPT=/tmp/eigs_mrt_roundtrip.eigs
cat > "$SCRIPT" <<EIGS
r is eigen_model_load of "$SRC_MODEL"
print of "LOAD:"
print of (eigen_model_loaded of null)
print of "INFO_BEFORE:"
print of (eigen_model_info of null)
s is model_save_weights of "$DST_MODEL"
print of "SAVE:"
print of s
EIGS

OUT=$("$EIGS" "$SCRIPT" 2>&1)
LOADED=$(echo "$OUT" | grep -A1 '^LOAD:$' | tail -1)
INFO=$(echo "$OUT" | grep -A1 '^INFO_BEFORE:$' | tail -1)
SAVE_STATUS=$(echo "$OUT" | grep -A1 '^SAVE:$' | tail -1)

if [ "$LOADED" = "1" ]; then
    ok "MRT02 generated model loads (eigen_model_loaded == 1)"
else
    fail "MRT02 load" "loaded='$LOADED'"
fi

if echo "$INFO" | grep -q '"vocab_size": 8' && echo "$INFO" | grep -q '"d_model": 4'; then
    ok "MRT03 model_info reports vocab=8 d_model=4"
else
    fail "MRT03 model_info" "got '$INFO'"
fi

if echo "$SAVE_STATUS" | grep -q '"status": "saved"'; then
    ok "MRT04 model_save_weights returns status=saved"
else
    fail "MRT04 save" "got '$SAVE_STATUS'"
fi

if [ -s "$DST_MODEL" ]; then
    ok "MRT05 saved model file is non-empty"
else
    fail "MRT05 saved file empty/missing"
fi

# ---- Step 3: fresh process, reload saved file, confirm identical config ----
SCRIPT2=/tmp/eigs_mrt_reload.eigs
cat > "$SCRIPT2" <<EIGS
r is eigen_model_load of "$DST_MODEL"
print of "RELOAD:"
print of (eigen_model_loaded of null)
print of "INFO_AFTER:"
print of (eigen_model_info of null)
EIGS

OUT2=$("$EIGS" "$SCRIPT2" 2>&1)
RELOADED=$(echo "$OUT2" | grep -A1 '^RELOAD:$' | tail -1)
INFO2=$(echo "$OUT2" | grep -A1 '^INFO_AFTER:$' | tail -1)

if [ "$RELOADED" = "1" ]; then
    ok "MRT06 saved model reloads in fresh process"
else
    fail "MRT06 reload" "reloaded='$RELOADED'"
fi

if echo "$INFO2" | grep -q '"vocab_size": 8' && echo "$INFO2" | grep -q '"d_model": 4'; then
    ok "MRT07 reloaded model has same vocab=8 d_model=4"
else
    fail "MRT07 config match" "got '$INFO2'"
fi

# ---- Step 4: generate tokens, verify shape invariants ----
SCRIPT3=/tmp/eigs_mrt_gen.eigs
cat > "$SCRIPT3" <<EIGS
r is eigen_model_load of "$DST_MODEL"
out is eigen_generate of [[1, 2, 3], 0.0, 5]
print of "TYPE:"
print of (type of out)
print of "LEN:"
print of (len of out)
EIGS

OUT3=$("$EIGS" "$SCRIPT3" 2>&1)
TY=$(echo "$OUT3" | grep -A1 '^TYPE:$' | tail -1)
LN=$(echo "$OUT3" | grep -A1 '^LEN:$' | tail -1)

if [ "$TY" = "list" ]; then
    ok "MRT08 eigen_generate returns a list"
else
    fail "MRT08 generate type" "got '$TY'"
fi
if [ "$LN" = "5" ]; then
    ok "MRT09 eigen_generate honours max_tokens=5"
else
    fail "MRT09 generate length" "got '$LN'"
fi

# ---- Summary ----
echo ""
echo "MODEL_RT: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
