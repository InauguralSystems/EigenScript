#!/bin/bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS_BIN:-$TESTS_DIR/../src/eigenscript}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_token_range.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

"$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$WORK/model.json" || exit 1
cat > "$WORK/check.eigs" <<EIGS
eigen_model_load of "$WORK/model.json"
define rejects(label, thunk) as:
    try:
        thunk of null
        assert of [false, f"{label} accepted bad token"]
    catch e:
        assert of [e.kind == "index_range", f"{label} raises index_range"]
        print of f"PASS {label}"
define bad_generate(_) as:
    return eigen_generate of [[0, 8], 0, 1]
define bad_eval_prompt(_) as:
    return eigen_eval_loss of [[-1], 0]
define bad_eval_target(_) as:
    return eigen_eval_loss of [[0], 8]
define bad_train_input(_) as:
    return native_train_step_builtin of [[0, 8], [1], 0.01]
define bad_train_output(_) as:
    return native_train_step_builtin of [[0], [1, -1], 0.01]
rejects of ["eigen_generate", bad_generate]
rejects of ["eigen_eval_loss prompt", bad_eval_prompt]
rejects of ["eigen_eval_loss target", bad_eval_target]
rejects of ["native_train_step input", bad_train_input]
rejects of ["native_train_step output", bad_train_output]
print of "MODEL TOKEN RANGE ALL PASS"
EIGS

for tier in interp default osr; do
    case "$tier" in
        interp) EIGS_JIT_OFF=1 "$EIGS" "$WORK/check.eigs" > "$WORK/$tier.out" 2> "$WORK/$tier.err" ;;
        default) "$EIGS" "$WORK/check.eigs" > "$WORK/$tier.out" 2> "$WORK/$tier.err" ;;
        osr) EIGS_JIT_OSR_THRESHOLD=1 "$EIGS" "$WORK/check.eigs" > "$WORK/$tier.out" 2> "$WORK/$tier.err" ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q '^MODEL TOKEN RANGE ALL PASS$' "$WORK/$tier.out" || grep -q '^FAIL ' "$WORK/$tier.out"; then
        echo "FAIL model token range ($tier, rc=$rc)"
        cat "$WORK/$tier.out" "$WORK/$tier.err"
        exit 1
    fi
    echo "  PASS: model token range ($tier)"
done
