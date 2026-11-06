#!/usr/bin/env bash
# tools/phase2_plants.sh [--ref REF] [--selftest] [--only ID] -- #1758: Phase 2's planted
# faults (docs/design/phase2-numbers.md 9.3). A check proves it fires when it
# is written or changed (docs/PRINCIPLES.md 5), so this runs as a
# tools/selftests.txt row keyed on the checks the plants name, never on every
# suite or CI run; `--selftest` is that row's spelling of the same run. Each
# plant:
#   1. `git archive REF` (default HEAD) into a scratch tree with no .git;
#   2. applies one replacement, refusing unless the original text occurs
#      exactly once before and the planted text after (else BROKEN);
#   3. builds what its named check needs (plain make, one at a time);
#   4. runs the named check and requires the check's OWN failure line naming
#      the row (keyed on the message, not on a nonzero exit) -> KILLED.
# Then, once per plant, the transverse run (9.3, "deleting its named check's
# assertion must let the plant through"): the same planted tree with the
# check's assertion removed must NOT print that line -> the plant survives
# exactly the deletion of the assertion that names it.
#
# Plants land with their named checks: plant 1 with R1.1 (the C slot test),
# plant 2 with R2.1 (C NaN-writer rows) and R2.4 (program rows under ASan).
# Plant3 joins at R2.3: JSON and store refuse inside their encoders.
# Other MAP-row plants join as their named checks land. The R1.1
# fix round added three instrument plants on the slot test: an integer overflow
# that wraps instead of raising (Part D), and a population scan that writes noise
# to stderr or an unparsed line to stdout (the critic's class); and #1775's
# plant, the missing return that makes the -O0 amalgamation warn.
# R3.1 adds eleven observer plants. Each first runs its named MAP check on
# an unmodified archive. The named assertion, four tiers, JIT witness and
# finite control then run on the mutant and its assertion-deleted twin.
# Four design-named oracle messages are also required on the mutant, after
# one pristine oracle control. Reuse that built mutant for its transverse
# assertion deletion; only the check changes, so a second product build is
# neither needed nor allowed to change the artifact under measurement.
# Prints one line per plant and `plants=N killed=N survived=0 broken=0
# transverse=N`; exit 0 only for exactly that, with N > 0. --only ID runs
# one named plant and its transverse control; a successful restricted run
# prints RESTRICTED and exits 3, never PASS for the full population.
# About 3 minutes
# per plant on the 4 GB box (two -O0 compiles of the amalgamated slot test).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF=HEAD
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ref)
            [ $# -gt 1 ] || { echo "phase2-plants: FAIL: --ref needs a value"; exit 2; }
            REF="$2"; shift 2 ;;
        --selftest) shift ;;
        --only)
            [ $# -gt 1 ] || { echo "phase2-plants: FAIL: --only needs a plant id"; exit 2; }
            [ -z "$ONLY" ] || { echo "phase2-plants: FAIL: --only may be given once"; exit 2; }
            case "$2" in
                1|2|3-json|3-store|overflow-wrap|stderr-noise|stdout-noise|return-type|\
                r31-absolute-tolerance|r31-zero-floor|r31-smi-exact|r31-jit-inline-double|\
                r31-nan-diverging|r31-inf-sign|r31-converged-incumbent|r31-improving-incumbent|\
                r31-nan-report|r31-where-entropy|r31-how-infinite|\
                r312-stall-quiet|r312-stall-nonfinite|r312-stall-diverging|\
                r314-stall-oscillating|r314-stall-nonfinite-order|\
                r317-stall-window-current|r317-stall-window-extent|r317-stall-step-overflow|\
                r318-stall-window-index|r319-stall-window-newest|\
                r32-cfg-legacy-five|r32-cfg-at-least-four|r32-cfg-at-most-four) ONLY="$2" ;;
                *) echo "phase2-plants: FAIL: unknown plant id $2"; exit 2 ;;
            esac
            shift 2 ;;
        *) echo "phase2-plants: FAIL: unknown argument $1"; exit 2 ;;
    esac
done
TMO=""
if command -v timeout >/dev/null 2>&1; then TMO="timeout 1500"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 1500"; fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-phase2-plants.XXXXXX") || { echo "phase2-plants: FAIL: mktemp"; exit 2; }
VERDICT_DONE=0
# A run that ends without its verdict line is a FAIL, named with the command
# it was running (the #988 rule).
trap 'rc=$?; [ "$VERDICT_DONE" = 1 ] || echo "phase2-plants: FAIL: exited ($rc) before a verdict, at: $BASH_COMMAND"; rm -rf "$WORK"' EXIT

# replace FILE OLD NEW: exactly one OLD before, NEW present after.
replace() {
    python3 -W error - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as f:
    text = f.read()
n = text.count(old)
if n != 1:
    print('replace: %s: the original occurs %d times, want exactly 1' % (path, n))
    sys.exit(1)
text = text.replace(old, new)
if new not in text:
    print('replace: %s: the planted text is absent after the replacement' % path)
    sys.exit(1)
with open(path, 'w', encoding='utf-8') as f:
    f.write(text)
PY
}

plants=0; killed=0; survived=0; broken=0; transverse=0; available=0; observer_green=0
oracle_red=0; oracle_green=0
EXPECTED_ORACLE=4
stall_plants=0; stall_killed=0; stall_survived=0; stall_broken=0; stall_green=0; stall_available=0
EXPECTED_STALL=10
ocfg_plants=0; ocfg_killed=0; ocfg_survived=0; ocfg_broken=0; ocfg_green=0; ocfg_transverse=0; ocfg_available=0
EXPECTED_OCFG=3
PRISTINE="$WORK/observer-pristine"
EXPECTED_PLANTS=19
EXPECTED_OBSERVER=11

# Two registered concepts have two production sites. Each individual edit
# retains the same exactly-once anchor requirement as the primary edit.
observer_second_edit() {
    case "$1" in
        r31-absolute-tolerance)
            replace "$2/src/eigenscript.c" \
                '        return obs_num_exact_diameter(s) <= 2.0 * g_obs_dh_small * scale;' \
                '        return obs_num_exact_diameter(s) <= 2.0 * g_obs_dh_small * obs_fmax(fabs(s->last_value), scale);' ;;
        r31-inf-sign)
            replace "$2/src/eigenscript.c" \
                '    if (isinf(s->last_value)) return !obs_num_opposite_inf(s);' \
                '    if (isinf(s->last_value)) return 1; /* PLANT: no polarity rule */' ;;
    esac
}

observer_red_complete() {
    [ "$1" != r31-improving-incumbent ] || {
        grep -q '^observer-map: FAIL O2.report-noisy-loss tier=' "$2" &&
        grep -q '^observer-map: FAIL O2.noisy-loss-improving-count tier=' "$2"
    }
}

# The design names these literal oracle keys in addition to each MAP row.
# The frozen score/floor/labels/declarations are never edited by this half.
# Build the anchor from the Git checkout, not the deliberately .git-free
# mutant archive. As in ci_lane.sh, score.py's own rc1 is a verdict failure;
# rc2, a timeout or a build failure is not a killed plant.
observer_oracle_key() {
    case "$1" in
        r31-absolute-tolerance) echo 'int64_count@10 converged' ;;
        r31-zero-floor) echo 'int64_count@10 diverging' ;;
        r31-nan-diverging) echo 'ieee_nan@3 diverging' ;;
        r31-inf-sign) echo 'ieee_inf_alternating@20 oscillating' ;;
    esac
}

observer_oracle() {
    local id="$1" mode="$2" dir="$3" key log rc
    key=$(observer_oracle_key "$id")
    [ -n "$key" ] || return 0
    [ "$mode" != transverse ] || return 0
    if [ "$mode" = green ] && [ "$oracle_green" -ne 0 ]; then return 0; fi
    log="$WORK/$id-$mode-oracle.log"
    if [ "$mode" = green ]; then
        (cd "$ROOT" && $TMO make observer-anchor) > "$log" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "  $id: pristine anchor setup failed (rc=$rc):"
            tail -30 "$log" | sed 's/^/    | /'
            return 1
        fi
    else
        : > "$log"
    fi
    (cd "$dir" && $TMO python3 tools/observer_oracle/score.py src/eigenscript \
        --floor tools/observer_oracle/floor.json --expect ieee,int64 \
        --declared tests/phase2/oracle_expect.txt) >> "$log" 2>&1
    rc=$?
    if [ "$mode" = green ]; then
        if [ "$rc" -ne 0 ] || ! grep -qxF 'floor: 1872 verdicts checked, 0 lost' "$log" ||
           grep -q 'CAPABILITY WRONG' "$log"; then
            echo "  $id: unplanted oracle failed (rc=$rc):"
            tail -30 "$log" | sed 's/^/    | /'
            return 1
        fi
        oracle_green=$((oracle_green + 1))
        echo '    unplanted oracle: floor: 1872 verdicts checked, 0 lost; CAPABILITY WRONG=0'
    else
        local pattern="^  CAPABILITY WRONG [^ ]+ $key: expected=(true|false)$"
        if [ "$rc" -ne 1 ] || ! grep -Eq "$pattern" "$log" ||
           grep -q 'warning:\|build: \|DRIVER_TIMEOUT' "$log"; then
            echo "  $id: oracle did not give its named capability failure (rc=$rc):"
            tail -30 "$log" | sed 's/^/    | /'
            return 1
        fi
        oracle_red=$((oracle_red + 1))
        grep -E "$pattern" "$log" | head -3 | sed 's/^/    oracle red: /'
        echo "    oracle $id: named=$key rc=$rc RED"
    fi
}

# run_plant ID FILE OLD NEW CHECK_FILE CHECK_OLD CHECK_NEW FAIL_RE CHECK_CMD...
run_plant() {
    local id="$1" file="$2" old="$3" new="$4" cfile="$5" cold="$6" cnew="$7" re="$8"
    shift 8
    available=$((available + 1))
    [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || return 0
    plants=$((plants + 1))
    local verdict="" trans="" observer=0 modes="plant transverse"
    case "$id" in r31-*) observer=1; modes="green plant transverse" ;; esac
    for mode in $modes; do
        local dir="$WORK/$id-$mode" fresh=1
        # Observer greens share one untouched archive. A transverse check
        # reuses its already measured mutant: only the assertion is removed.
        if [ "$observer" -eq 1 ]; then
            if [ "$mode" = green ]; then
                dir="$PRISTINE"
                [ ! -d "$dir" ] || fresh=0
            elif [ "$mode" = transverse ]; then
                dir="$WORK/$id-plant"; fresh=0
            fi
        fi
        if [ "$fresh" -eq 1 ]; then
            mkdir -p "$dir"
            if ! git -C "$ROOT" archive "$REF" | tar -x -C "$dir"; then verdict=BROKEN; echo "  $id: archive of $REF failed"; break; fi
            if [ "$mode" != green ]; then
                if ! replace "$dir/$file" "$old" "$new"; then verdict=BROKEN; break; fi
                if ! observer_second_edit "$id" "$dir"; then verdict=BROKEN; break; fi
            fi
        fi
        if [ "$mode" = transverse ] && ! replace "$dir/$cfile" "$cold" "$cnew"; then trans=BROKEN; break; fi
        # Plant2 has two named halves. Delete its program assertion after the
        # child returns too: a corrupted HEAP payload may crash before any
        # language assertion. Keep all 15 children and finite controls live.
        if [ "$mode" = transverse ] && [ "$id" = 2 ] && ! replace \
            "$dir/tests/phase2/nan_payload_map_check.py" \
            '                if not payload_matched:' \
            '                if False and not payload_matched:'; then trans=BROKEN; break; fi
        local log="$WORK/$id-$mode.log"
        (cd "$dir" && $TMO "$@") > "$log" 2> "$log.err"
        local rc=$?
        if [ -s "$log.err" ]; then      # the check's own stderr: unexpected, shown, BROKEN
            sed 's/^/    check stderr: /' "$log.err"
            [ "$mode" = plant ] && verdict=BROKEN || trans=BROKEN
            break
        fi
        if [ "$mode" = green ]; then
            if [ "$rc" -ne 0 ] || ! grep -q '^observer-map: PASS ' "$log"; then
                verdict=BROKEN; echo "  $id: unplanted named check did not pass (rc=$rc):"; tail -20 "$log" | sed 's/^/    | /'; break
            fi
            observer_green=$((observer_green + 1))
            tail -1 "$log" | sed 's/^/    unplanted: /'
            if ! observer_oracle "$id" "$mode" "$dir"; then verdict=BROKEN; break; fi
        elif [ "$mode" = plant ]; then
            if [ "$rc" -eq 124 ] || grep -q 'build: \|make phase2-slot-test exited\|^writer-map: BROKEN\|^nan-payload-map: BROKEN\|^observer-map: BROKEN' "$log"; then
                verdict=BROKEN; echo "  $id: the check did not complete (rc=$rc):"; tail -20 "$log" | sed 's/^/    | /'
            elif [ "$observer" -eq 1 ] && [ "$rc" -ne 1 ]; then
                verdict=SURVIVED; echo "  $id: named row assertion did not return rc=1 (rc=$rc)"
            elif grep -Eq "$re" "$log" && { [ "$id" != 2 ] || { \
                grep -q '^nan-payload-map: FAIL N12.nan-payload-tags payload=' "$log" && \
                grep -qxF 'nan-payload-map: row=N12.nan-payload-tags payloads=5 tiers=3 examined=15 failures=15 controls=3 control_failures=0 timeouts=0' "$log"; }; } && observer_red_complete "$id" "$log"; then verdict=KILLED
            else verdict=SURVIVED; echo "  $id: no failure line matching /$re/ (rc=$rc):"; tail -20 "$log" | sed 's/^/    | /'; fi
            grep -E "$re" "$log" | head -3 | sed 's/^/    red: /'
            if [ "$id" = 2 ]; then
                grep '^nan-payload-map: FAIL N12.nan-payload-tags payload=' "$log" | head -3 | sed 's/^/    program red: /'
                grep '^nan-payload-map: row=' "$log" | sed 's/^/    program counts: /'
            fi
            [ "$verdict" = KILLED ] || break
            if ! observer_oracle "$id" "$mode" "$dir"; then verdict=BROKEN; break; fi
        else
            if grep -Eq "$re" "$log"; then trans=NOT-TRANSVERSE; echo "  $id: the line still fired with its assertion deleted"
            elif [ "$rc" -ne 0 ] || grep -q 'build: \|make phase2-slot-test exited\|^writer-map: BROKEN\|^nan-payload-map: BROKEN\|^observer-map: BROKEN' "$log"; then
                trans=BROKEN; echo "  $id: assertion-deleted check did not complete cleanly (rc=$rc)"
            elif [ "$observer" -eq 1 ] && ! grep -Eq '^observer-map: PASS .*mismatches=[1-9][0-9]* ' "$log"; then
                trans=BROKEN; echo "  $id: assertion-deleted observer check lost its live mismatch"
            else trans=TRANSVERSE; fi
            tail -2 "$log" | sed 's/^/    assertion deleted: /'
        fi
    done
    case "$verdict" in
        KILLED) killed=$((killed + 1)) ;;
        SURVIVED) survived=$((survived + 1)) ;;
        *) broken=$((broken + 1)); verdict=BROKEN ;;
    esac
    [ "$trans" = TRANSVERSE ] && transverse=$((transverse + 1))
    echo "plant $id: $verdict transverse=${trans:-not-run}"
}

# Plant 1 (9.3): an int that fits inline stored boxed. slot_from_int, the one
# int writer, skips the small-int rule and allocates a real VAL_INT box.
# A heap tag on the integer bits is an invalid pointer, not this plant: it
# also crashes unrelated VM/container checks after Part C's assertion is
# deleted, so cannot prove that the small-int assertion is transverse.
# Named check: the C slot test's slot_from_int rows (Part C).
run_plant 1 src/value_slot.h \
    'EigsSlot s; s.u = TAG_SMI | ((uint64_t)i & SLOT_PAYLOAD_MASK); return s;' \
    'return slot_from_heap(make_int(i));' \
    tests/phase2/slot_layer.c \
    '        if (s.u != smi(v).u)' \
    '        if (0)' \
    '^slot-layer-test: FAIL slot_from_int\(0\): bits 0x' \
    bash tests/phase2/slot_layer.sh release

# Plant 2 (R2.1/R2.4, design 9.3): preserve the incoming double bits,
# bypassing the single writer's canonical branch. Part F must report the
# HEAP-spelling payload's SIGSEGV from slot_incref, reproducing #1746.
# The real N12 program row also runs under ASan: five payloads isolated in
# three tiers, so one crash cannot skip another payload. Transverse deletes
# the C NaN assertion and the program's returned-result assertion; all C
# children/non-NaN controls and the three finite program controls remain.
run_plant 2 src/value_slot.h \
    '    if ((s.u & 0x7FFFFFFFFFFFFFFFULL) > 0x7FF0000000000000ULL)
        s.u = 0x7FF8000000000000ULL;' \
    '    /* PLANT 2: raw NaN bits bypass canonicalization. */' \
    tests/phase2/slot_layer.c \
    '        if (strcmp(got, want) != 0)
            FAILF("N12.nan-payload-tags' \
    '        if (!nan && strcmp(got, want) != 0)
            FAILF("N12.nan-payload-tags' \
    '^slot-layer-test: FAIL N12.nan-payload-tags slot_from_f64\(fffb000000001000\): got X:signal 11:' \
    bash -c 'slot_rc=0; bash tests/phase2/slot_layer.sh release || slot_rc=$?; map_rc=0; python3 -W error tests/phase2/nan_payload_map_check.py || map_rc=$?; [ "$slot_rc" -eq 0 ] && [ "$map_rc" -eq 0 ]'

# Plant 3 (R2.3, design 9.3): delete only the encoder's finite refusal.
# The public JSON row is an R23-1 invariant on the accepted parent, but the
# encoder now owns its error: removing that refusal must expose accepted inf.
# Transverse deletes this named row's assertion, not the row or its controls.
run_plant 3-json src/builtins.c \
    '            if (!isfinite(n)) {
                rt_error(EK_VALUE, 0, "eigs_json_encode_value: expected a finite number");
                return -1;
            }' \
    '            /* PLANT 3-json: accept non-finite numeric JSON text. */' \
    tests/phase2/writer_map_check.py \
    "            if row == 'N13.json-refuses-inf' and not matched:" \
    "            if False and row == 'N13.json-refuses-inf' and not matched:" \
    '^writer-map: FAIL N13\.json-refuses-inf tier=' \
    python3 -W error tests/phase2/writer_map_check.py N13.json-refuses-inf

# All store scalar/slot/buffer arms use this encoder helper. Its deletion
# accepts the actual MAP NaN record; no unrelated I/O or parser fault is added.
run_plant 3-store src/ext_store.c \
    '    if (!isfinite(d)) {
        rt_error(EK_VALUE, 0, "store: cannot encode a non-finite number");
        return -1;
    }' \
    '    /* PLANT 3-store: accept non-finite stored numeric text. */' \
    tests/phase2/writer_map_check.py \
    "            if row == 'N13.store-refuses-nan' and not matched:" \
    "            if False and row == 'N13.store-refuses-nan' and not matched:" \
    '^writer-map: FAIL N13\.store-refuses-nan tier=' \
    python3 -W error tests/phase2/writer_map_check.py N13.store-refuses-nan

# R1.3 N3/(A): overflow must raise, never return the wrapped int64 result.
# The builtin computes the wrapped bits through __builtin_*_overflow; dropping
# the checked raise therefore reproduces the exact fault the row promises.
# Named check: the slot test's Part D overflow_add row, with a float control.
run_plant overflow-wrap src/vm.c \
    '    if (overflow) {' \
    '    if (overflow && 0) {   /* PLANT: return the wrapped int64 result */' \
    tests/phase2/slot_layer.c \
    '        if (strcmp(got, "ran") != 0 || strcmp(pre, want) != 0) {' \
    '        if (0) {' \
    "^slot-layer-test: FAIL arm overflow_add with an int: got " \
    bash tests/phase2/slot_layer.sh release

# The critic's class: a population scan whose diagnostics reach the parser.
# Named checks: the runner's stderr refusal, and its grammar whitelist.
run_plant stderr-noise tools/phase2_inventory.py \
    "    out, bad = [], []
    for (rel, k), (cls, c) in sorted(slots.items()):" \
    "    print('phase2-plant: noise on stderr', file=sys.stderr)
    out, bad = [], []
    for (rel, k), (cls, c) in sorted(slots.items()):" \
    tests/phase2/slot_layer.sh \
    'show_stderr "$TMP/pop.err" "the population scan"' \
    ':' \
    "^slot-layer: FAIL: the population scan wrote to stderr" \
    bash tests/phase2/slot_layer.sh release
run_plant stdout-noise tools/phase2_inventory.py \
    "    out, bad = [], []
    for (rel, k), (cls, c) in sorted(slots.items()):" \
    "    print('phase2-plant: an unparsed line')
    out, bad = [], []
    for (rel, k), (cls, c) in sorted(slots.items()):" \
    tests/phase2/slot_layer.sh \
    'if [ -s "$TMP/pop.bad" ]; then' \
    'if false; then' \
    "^slot-layer: FAIL: the population scan printed lines outside its grammar" \
    bash tests/phase2/slot_layer.sh release

# #1775: the missing return comes back. -O0 does not fold ARG_GUARD's
# constant test, so the amalgamation warns (-Wreturn-type). Named check: the
# runner's build-warning refusal.
run_plant return-type src/builtins_tensor.c \
    "    return make_null();   /* unreachable: the guard above always returns, but
                           * -O0 does not fold its constant test (#1775) */
" \
    "" \
    tests/phase2/slot_layer.sh \
    "if grep -q 'warning:' \"\$TMP/build.txt\"; then" \
    'if false; then' \
    "^slot-layer: FAIL: the slot test build printed [0-9]+ warning" \
    bash tests/phase2/slot_layer.sh release

# R3.1's named checks reuse the MAP runner/transcripts. The transverse copy
# disables only the selected rows' comparison: all four runs, the fn-stop
# witness and the independent finite control still execute.
run_observer_plant() {
    local id="$1" file="$2" old="$3" new="$4"
    shift 4
    local row_re=${1//./\\.}
    run_plant "$id" "$file" "$old" "$new" \
        tests/phase2/observer_map_check.py \
        '                if not matched:' \
        '                if False and not matched:' \
        "^observer-map: FAIL $row_re tier=" \
        python3 -W error tests/phase2/observer_map_check.py "$@"
}

# Both settled tests lose their absolute tolerance, while the raw zero
# floor stays intact. observer_second_edit changes stable's matching site.
run_observer_plant r31-absolute-tolerance src/eigenscript.c \
    '        return obs_num_exact_diameter(s) <= g_obs_dh_zero * scale;' \
    '        return obs_num_exact_diameter(s) <= g_obs_dh_zero * obs_fmax(fabs(s->last_value), scale);' \
    O2.int-counter-2p53

run_observer_plant r31-zero-floor src/eigenscript.c \
    '    return observer_slot_all_exact(s) ? 0.0
        : 4.0 * DBL_EPSILON * (1.0 + fabs(s->last_value));' \
    '    return 4.0 * DBL_EPSILON * (1.0 + fabs(s->last_value));' \
    O2.int-down-counter-2p53

# SMI is the half-open range [-2^47, 2^47). Boxed pairs stay exact, so the
# SMI invariant is the unique named check of this registered fault.
run_observer_plant r31-smi-exact src/eigenscript.c \
    '        int exact = v.is_int && s->last_is_int &&' \
    '        int exact = v.is_int && s->last_is_int &&
            (v.integer < -140737488355328LL || v.integer >= 140737488355328LL ||
             s->last_int < -140737488355328LL || s->last_int >= 140737488355328LL) &&' \
    O2.int-smi-alternating

# Reproduce the former inline double writer at its JIT-only private sample
# site. The shared recorder still maintains the new authoritative W+1
# inputs/D2 scalars, but receives the rounded float and writes no exact flag.
# Copying only the old two ring stores would instead leave the W+1 inputs
# empty and fail on a different defect than the registered double writer.
run_observer_plant r31-jit-inline-double src/vm.c \
    '    observer_slot_record_num(s, value);
    s->used = 1;
}' \
    '    observer_slot_record_num(s, slot_from_f64(eigs_slot_float(value, __func__)));
    s->used = 1;
}' \
    O1.unobserved-jit-sample

run_observer_plant r31-nan-diverging src/eigenscript.c \
    'static int obs_num_diverging(const ObserverSlot *s) {
    if (isnan(s->last_value)) return 0;' \
    'static int obs_num_diverging(const ObserverSlot *s) {
    if (isnan(s->last_value)) return 1; /* PLANT: R2.2 non-finite veto */' \
    O2.nan-all-false

# Removing the polarity rule restores the old infinity result in both
# predicates; observer_second_edit changes diverging's matching site.
run_observer_plant r31-inf-sign src/eigenscript.c \
    '    if (isinf(s->last_value)) return obs_num_opposite_inf(s);' \
    '    if (isinf(s->last_value)) { (void)obs_num_opposite_inf; return 0; } /* PLANT */' \
    O2.inf-alternating-oscillates

# Restore the incumbent body as an early-return block. The STD body stays
# compiled below it so its private helpers do not become unused warnings:
# build warnings must never be mistaken for a killed numeric plant.
run_observer_plant r31-converged-incumbent src/eigenscript.c \
    'static int obs_num_converged(const ObserverSlot *s) {' \
    'static int obs_num_converged(const ObserverSlot *s) {
    { /* PLANT: incumbent relative-step band */
        if (observer_slot_nonfinite(s)) return 0;
        if (obs_v_count(s) < (size_t)observer_slot_window(s)) return 0;
        int all_zero, all_small;
        obs_num_flags(s, &all_zero, &all_small);
        if (!all_zero) return 0;
        if (observer_slot_raw_diverging(s) || observer_slot_raw_oscillating(s)) return 0;
        return 1;
    }' \
    O2.harmonic-not-converged

run_observer_plant r31-improving-incumbent src/eigenscript.c \
    'static int obs_num_improving(const ObserverSlot *s) {' \
    'static int obs_num_improving(const ObserverSlot *s) {
    { /* PLANT: incumbent contraction band */
        if (observer_slot_nonfinite(s)) return 0;
        size_t cnt = obs_v_count(s);
        if (cnt < 4) return 0;
        int all_zero, all_small;
        obs_num_flags(s, &all_zero, &all_small);
        if (all_zero || obs_num_oscillating(s)) return 0;
        double first = observer_slot_vr_get(s, 0);
        if (first >= 0.0) return 0;
        for (size_t i = 1; i < cnt; i++)
            if (observer_slot_vr_get(s, i) * first <= 0.0) return 0;
        const double CONTRACT = 0.7;
        double floor_eps = 4.0 * DBL_EPSILON * (1.0 + fabs(s->last_value));
        size_t half = cnt / 2;
        double recent = 0.0, older = 0.0, recent_max = 0.0, older_max = 0.0;
        for (size_t i = 0; i < half; i++) {
            double m = fabs(observer_slot_vr_get(s, i));
            recent += m;
            if (m > recent_max) recent_max = m;
        }
        for (size_t i = half; i < cnt; i++) {
            double m = fabs(observer_slot_vr_get(s, i));
            older += m;
            if (m > older_max) older_max = m;
        }
        recent /= (double)half;
        older /= (double)(cnt - half);
        if (older <= floor_eps || recent <= floor_eps) return 0;
        return recent <= older * CONTRACT && recent_max <= older_max * CONTRACT;
    }' \
    O2.report-noisy-loss O2.noisy-loss-improving-count

run_observer_plant r31-nan-report src/eigenscript.c \
    '    if (isnan(s->last_value)) return "undefined";' \
    '    if (isnan(s->last_value)) return "moving";' \
    O2.nan-report-undefined

run_observer_plant r31-where-entropy src/eigenscript.c \
    '    if (kind == 3) return observer_number_slot(s->where);' \
    '    if (kind == 3) return slot_from_f64(entropy_of_num(s->where.value));' \
    O1.where-is-value

run_observer_plant r31-how-infinite src/eigenscript.c \
    '    if (isinf(raw)) return 0.0;' \
    '    /* PLANT: apply the relative-step formula even for an infinite step. */' \
    O4.how-infinite-step

# R31-9: ten independently named clause/order/index plants. The first three
# retain their original witnesses. Finite constant alternation isolates the
# oscillation arm; infinite alternation witnesses non-finite priority, and
# period-three and period-eleven NaN cycles isolate the retained-input window.
# A finite contracting alternation protects against counting overflowed steps.
# An initial NaN distinguishes the newest index before the ring fills.
# A newest prefix NaN distinguishes the opposite starting-index error.
run_stall_plant() {
    local id="$1" case_name="$2" old="$3" new="$4" mode dir log build rc verdict="" pattern
    stall_available=$((stall_available + 1))
    [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || return 0
    stall_plants=$((stall_plants + 1))
    for mode in green plant; do
        if [ "$mode" = green ]; then dir="$PRISTINE"; else dir="$WORK/$id-plant"; fi
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            if ! git -C "$ROOT" archive "$REF" | tar -x -C "$dir"; then
                verdict=BROKEN; echo "  $id: archive of $REF failed"; break
            fi
        fi
        if [ "$mode" = plant ] && ! replace "$dir/src/vm.c" "$old" "$new"; then verdict=BROKEN; break; fi
        build="$WORK/$id-$mode-build.log"
        (cd "$dir" && $TMO make) > "$build" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ] || grep -q 'warning:' "$build"; then
            verdict=BROKEN; echo "  $id: build did not finish warning-free (rc=$rc):"
            tail -20 "$build" | sed 's/^/    | /'; break
        fi
        log="$WORK/$id-$mode.log"
        (cd "$dir" && $TMO python3 -W error tests/phase2/stall_contract.py src/eigenscript --case "$case_name") > "$log" 2> "$log.err"
        rc=$?
        if [ -s "$log.err" ]; then
            verdict=BROKEN; sed 's/^/    check stderr: /' "$log.err"; break
        fi
        pattern="^stall-contract: FAIL $case_name tier="
        if [ "$mode" = green ]; then
            if [ "$rc" -ne 0 ] || ! grep -qxF 'stall-contract: measured=4 failures=0' "$log"; then
                verdict=BROKEN; echo "  $id: unplanted named check failed (rc=$rc):"
                tail -20 "$log" | sed 's/^/    | /'; break
            fi
            stall_green=$((stall_green + 1))
            tail -1 "$log" | sed "s/^/    unplanted $id: /"
        elif [ "$rc" -eq 1 ] && [ "$(grep -Ec "$pattern" "$log")" -eq 4 ] &&
             grep -qxF 'stall-contract: measured=4 failures=4' "$log"; then
            verdict=KILLED
            grep -E "$pattern" "$log" | sed 's/^/    red: /'
        else
            verdict=SURVIVED; echo "  $id: four own-message failures absent (rc=$rc):"
            tail -20 "$log" | sed 's/^/    | /'
        fi
    done
    case "$verdict" in
        KILLED) stall_killed=$((stall_killed + 1)) ;;
        SURVIVED) stall_survived=$((stall_survived + 1)) ;;
        *) stall_broken=$((stall_broken + 1)); verdict=BROKEN ;;
    esac
    echo "stall plant $id: $verdict"
}

run_stall_plant r312-stall-quiet quiet \
    '    if (observer_slot_quiet(s)) return 1;' \
    '    if (0 && observer_slot_quiet(s)) return 1; /* PLANT: no quiet arm */'
run_stall_plant r312-stall-nonfinite nan \
    '    if (obs_stall_window_nonfinite(s)) return 1;' \
    '    if (0 && obs_stall_window_nonfinite(s)) return 1; /* PLANT: no nonfinite arm */'
run_stall_plant r312-stall-diverging doubling \
    '    if (observer_slot_diverging(s)) return 1;' \
    '    if (0 && observer_slot_diverging(s)) return 1; /* PLANT: no diverging arm */'
run_stall_plant r314-stall-oscillating alternating \
    '    if (observer_slot_oscillating(s))' \
    '    if (0 && observer_slot_oscillating(s)) /* PLANT: no oscillating arm */'
run_stall_plant r314-stall-nonfinite-order infinite-alternating \
    '    if (obs_stall_window_nonfinite(s)) return 1;
    if (observer_slot_quiet(s)) return 1;
    if (observer_slot_diverging(s)) return 1;
    if (observer_slot_oscillating(s))
        return obs_stall_amplitude_noncontracting(s);' \
    '    if (observer_slot_oscillating(s))
        return obs_stall_amplitude_noncontracting(s); /* PLANT: finite-only veto before nonfinite */
    if (obs_stall_window_nonfinite(s)) return 1;
    if (observer_slot_quiet(s)) return 1;
    if (observer_slot_diverging(s)) return 1;'

run_stall_plant r317-stall-window-current nan-period3 \
    '    if (obs_stall_window_nonfinite(s)) return 1;' \
    '    if (!isfinite(s->last_value) || (0 && obs_stall_window_nonfinite(s))) return 1; /* PLANT: current value only */'
run_stall_plant r317-stall-window-extent nan-window-edge \
    'static int obs_stall_window_nonfinite(const ObserverSlot *s) {
    size_t n = s->values_count;
    size_t full = (size_t)observer_slot_window(s) + 1;' \
    'static int obs_stall_window_nonfinite(const ObserverSlot *s) {
    size_t n = s->values_count;
    size_t full = (size_t)observer_slot_window(s); /* PLANT: omit oldest retained input */'
run_stall_plant r317-stall-step-overflow overflow-contracting \
    '    if (obs_stall_window_nonfinite(s)) return 1;' \
    '    if (obs_stall_window_nonfinite(s) ||
        (s->v_window_count && s->v_rel &&
         !isfinite(s->v_rel[s->v_window_head ? s->v_window_head - 1 : s->v_cap - 1]))) return 1; /* PLANT: count overflowed finite-input step */'

run_stall_plant r318-stall-window-index nan-prefix \
    'static int obs_stall_window_nonfinite(const ObserverSlot *s) {
    size_t n = s->values_count;
    size_t full = (size_t)observer_slot_window(s) + 1;
    if (n > full) n = full;
    if (!s->v_values) return 0;
    for (size_t i = 0; i < n; i++) {
        int idx = (int)s->values_head - 1 - (int)i;' \
    'static int obs_stall_window_nonfinite(const ObserverSlot *s) {
    size_t n = s->values_count;
    size_t full = (size_t)observer_slot_window(s) + 1;
    if (n > full) n = full;
    if (!s->v_values) return 0;
    for (size_t i = 0; i < n; i++) {
        int idx = (int)s->values_head - (int)i;'

run_stall_plant r319-stall-window-newest nan-newest \
    'static int obs_stall_window_nonfinite(const ObserverSlot *s) {
    size_t n = s->values_count;
    size_t full = (size_t)observer_slot_window(s) + 1;
    if (n > full) n = full;
    if (!s->v_values) return 0;
    for (size_t i = 0; i < n; i++) {
        int idx = (int)s->values_head - 1 - (int)i;' \
    'static int obs_stall_window_nonfinite(const ObserverSlot *s) {
    size_t n = s->values_count;
    size_t full = (size_t)observer_slot_window(s) + 1;
    if (n > full) n = full;
    if (!s->v_values) return 0;
    for (size_t i = 0; i < n; i++) {
        int idx = (int)s->values_head - 2 - (int)i;'

# O3: count both sides of four, using the same exact MAP transcript.
# The legacy plant consumes the third token as h_low before window/scale,
# just as the old reader did; the removed per-state h_low has no new home.
run_ocfg_plant() {
    local id="$1" case_name="$2" mode dir log build rc verdict="" trans="" pattern
    local old='                    if (fields != 4) {' new
    ocfg_available=$((ocfg_available + 1))
    [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || return 0
    ocfg_plants=$((ocfg_plants + 1))
    case "$id" in
        r32-cfg-legacy-five) new='                    if (fields != 4 && fields != 5) {' ;;
        r32-cfg-at-least-four) new='                    if (fields < 4) {' ;;
        r32-cfg-at-most-four) new='                    if (fields > 4) {' ;;
    esac
    for mode in green plant transverse; do
        if [ "$mode" = green ]; then dir="$PRISTINE"; else dir="$WORK/$id-plant"; fi
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            if ! git -C "$ROOT" archive "$REF" | tar -x -C "$dir"; then
                verdict=BROKEN; echo "  $id: archive of $REF failed"; break
            fi
        fi
        if [ "$mode" = plant ]; then
            if ! replace "$dir/src/tape_read.c" "$old" "$new"; then verdict=BROKEN; break; fi
            if [ "$id" = r32-cfg-legacy-five ]; then
                if ! replace "$dir/src/tape_read.c" \
                    '                    q0 = q; long window = strtol(q, &q, 10);' \
                    '                    if (fields == 5) {
                        q0 = q; double legacy_h_low = strtod(q, &q);
                        ok &= (q != q0 && legacy_h_low > 0.0);
                    }
                    q0 = q; long window = strtol(q, &q, 10);'; then verdict=BROKEN; break; fi
            fi
        elif [ "$mode" = transverse ]; then
            if ! replace "$dir/tests/phase2/ocfg_map_check.py" \
                '                if not matched:' \
                '                if False and not matched:'; then trans=BROKEN; break; fi
        fi
        # Transverse reuses the already measured product; only the assertion
        # has changed, and its mismatch must remain visible in the summary.
        if [ "$mode" != transverse ]; then
            build="$WORK/$id-$mode-build.log"
            (cd "$dir" && $TMO make) > "$build" 2>&1
            rc=$?
            if [ "$rc" -ne 0 ] || grep -q 'warning:' "$build"; then
                verdict=BROKEN; echo "  $id: build did not finish warning-free (rc=$rc):"
                tail -20 "$build" | sed 's/^/    | /'; break
            fi
        fi
        log="$WORK/$id-$mode.log"
        (cd "$dir" && $TMO python3 -W error tests/phase2/ocfg_map_check.py src/eigenscript --case "$case_name") > "$log" 2> "$log.err"
        rc=$?
        if [ -s "$log.err" ] || grep -q '^ocfg-map: BROKEN' "$log" || [ "$rc" -gt 1 ]; then
            verdict=BROKEN; echo "  $id: check did not complete (rc=$rc)"
            cat "$log" "$log.err"; break
        fi
        pattern="^ocfg-map: FAIL O3.ocfg-no-hlow case=$case_name tier="
        if [ "$mode" = green ]; then
            if [ "$rc" -ne 0 ] || ! grep -qxF 'ocfg-map: examined=4 mismatches=0 failures=0 controls=4 control_failures=0' "$log"; then
                verdict=BROKEN; echo "  $id: unplanted named check failed (rc=$rc)"; cat "$log"; break
            fi
            ocfg_green=$((ocfg_green + 1))
            tail -1 "$log" | sed "s/^/    unplanted $id: /"
        elif [ "$mode" = plant ]; then
            if [ "$rc" -eq 1 ] && [ "$(grep -Ec "$pattern" "$log")" -eq 4 ] &&
               grep -qxF 'ocfg-map: examined=4 mismatches=4 failures=4 controls=4 control_failures=0' "$log"; then
                verdict=KILLED; cat "$log" | sed 's/^/    red: /'
            else
                verdict=SURVIVED; echo "  $id: four own-message failures absent (rc=$rc)"; cat "$log"; break
            fi
        elif [ "$rc" -eq 0 ] && ! grep -Eq "$pattern" "$log" &&
             grep -qxF 'ocfg-map: examined=4 mismatches=4 failures=0 controls=4 control_failures=0' "$log"; then
            trans=TRANSVERSE; tail -1 "$log" | sed 's/^/    assertion deleted: /'
        else
            trans=BROKEN; echo "  $id: assertion-deleted check lost the live mismatch"; cat "$log"
        fi
    done
    case "$verdict" in
        KILLED) ocfg_killed=$((ocfg_killed + 1)) ;;
        SURVIVED) ocfg_survived=$((ocfg_survived + 1)) ;;
        *) ocfg_broken=$((ocfg_broken + 1)); verdict=BROKEN ;;
    esac
    [ "$trans" != TRANSVERSE ] || ocfg_transverse=$((ocfg_transverse + 1))
    echo "ocfg plant $id: $verdict transverse=${trans:-not-run}"
}
run_ocfg_plant r32-cfg-legacy-five cfg-5-fields
run_ocfg_plant r32-cfg-at-least-four cfg-6-fields
run_ocfg_plant r32-cfg-at-most-four cfg-3-fields

echo "plants=$plants killed=$killed survived=$survived broken=$broken transverse=$transverse"
echo "observer-unplanted=$observer_green expected=$EXPECTED_OBSERVER"
echo "observer-oracle=$oracle_red expected=$EXPECTED_ORACLE oracle-unplanted=$oracle_green"
echo "stall-plants=$stall_plants killed=$stall_killed survived=$stall_survived broken=$stall_broken"
echo "stall-unplanted=$stall_green expected=$EXPECTED_STALL"
echo "ocfg-plants=$ocfg_plants killed=$ocfg_killed survived=$ocfg_survived broken=$ocfg_broken transverse=$ocfg_transverse"
echo "ocfg-unplanted=$ocfg_green expected=$EXPECTED_OCFG"
VERDICT_DONE=1
if [ -n "$ONLY" ]; then
    if { [ "$plants" -eq 1 ] && [ "$killed" -eq 1 ] && [ "$transverse" -eq 1 ]; } ||
       { [ "$stall_plants" -eq 1 ] && [ "$stall_killed" -eq 1 ] && [ "$stall_green" -eq 1 ]; } ||
       { [ "$ocfg_plants" -eq 1 ] && [ "$ocfg_killed" -eq 1 ] && [ "$ocfg_green" -eq 1 ] && [ "$ocfg_transverse" -eq 1 ]; }; then
        echo "phase2-plants: RESTRICTED selected=$ONLY examined=$plants stall-examined=$stall_plants ocfg-examined=$ocfg_plants available=$available stall-available=$stall_available ocfg-available=$ocfg_available; full population not checked"
        exit 3
    fi
    echo "phase2-plants: FAIL: restricted plant $ONLY did not complete its named check and transverse control"
    exit 1
fi
if [ "$available" -eq "$EXPECTED_PLANTS" ] && [ "$plants" -eq "$EXPECTED_PLANTS" ] && \
   [ "$killed" -eq "$plants" ] && [ "$transverse" -eq "$plants" ] && \
   [ "$observer_green" -eq "$EXPECTED_OBSERVER" ] &&
   [ "$oracle_red" -eq "$EXPECTED_ORACLE" ] && [ "$oracle_green" -eq 1 ] &&
   [ "$stall_available" -eq "$EXPECTED_STALL" ] && [ "$stall_plants" -eq "$EXPECTED_STALL" ] &&
   [ "$stall_killed" -eq "$EXPECTED_STALL" ] && [ "$stall_green" -eq "$EXPECTED_STALL" ] &&
   [ "$ocfg_available" -eq "$EXPECTED_OCFG" ] && [ "$ocfg_plants" -eq "$EXPECTED_OCFG" ] &&
   [ "$ocfg_killed" -eq "$EXPECTED_OCFG" ] && [ "$ocfg_green" -eq "$EXPECTED_OCFG" ] &&
   [ "$ocfg_transverse" -eq "$EXPECTED_OCFG" ]; then
    echo "phase2-plants: PASS"; exit 0
fi
echo "phase2-plants: FAIL"; exit 1
