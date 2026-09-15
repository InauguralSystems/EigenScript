#!/bin/bash
# #1141: a dict key written on ANY thread must stay valid for the DICT's
# lifetime, whatever thread reads it and whether or not the writer has exited.
#
# Probe-gated. Cwd is src/ when the suite invokes this (tests/run_all_tests.sh
# does `cd .../src`), so every path here is derived from $0 and absolute.
# Prints PASS:/FAIL: lines. Exit 0 iff FAIL=0. The suite pins BOTH totals.
#
# Two kinds of row, with different blind spots (mechanical-gates §51):
#
#   LIVE rows run a probe program and compare its capture against a
#   hand-written expected file (never against the binary's own output —
#   §4). They see the defect BEHAVIOURALLY: on a binary without the fix the
#   keys come back as freed bytes and every new field reads `null`.
#   Measured discriminating against a pristine pre-fix release build — all
#   six MT probes red, `dict_keys_mt_single` (the no-spawn control) green on
#   both, which is what makes the st-mt-identity row meaningful (§64).
#   `dict_keys_mt_module` needs the ASAN lane to red on the module-namespace
#   half alone: the capture includes stderr, so the ASan report lands inside
#   it and `exact` fires. Verified by building the `env-name-not-rehomed`
#   mutant with `make asan` — 3 rows red, this probe among them.
#
#   STRUCTURAL rows pin the CONSTRUCTION in src/eigenscript.c. They exist for
#   the one property no live row on this box can witness: that the
#   process-global insert is under its mutex. Removing that mutex loses list
#   nodes and duplicates entries — it LEAKS, it does not corrupt, because
#   every lookup falls back to strcmp and no reader walks the buckets outside
#   the lock. So there is no output a release run can be wrong about, and a
#   "kill" that depended on a scheduler window would be luck, not a gate
#   (same reasoning as the close-count-toctou rows in test_trace_mt.sh).
#   Residual (§6): these are TEXT checks over C source. They pin the SHAPE of
#   the insert — one lock, one unlock per exit, one writer of the bucket
#   array — not the atomicity of pthread_mutex_lock itself, and a second
#   global key table added under a different name is outside their
#   population.
#
# --selftest drives the SAME verify_capture() the live rows drive
# (mechanical-gates §99) with captures taken from a REAL binary built without
# the fix (tests/dict_keys_mt_fixtures/bad_*.cap, §40), plus a zero-population
# capture, plus a positive control that must stay GREEN. Each fixture pins the
# EXACT SET of check names that fire, not a count — that is what witnesses
# each individual check (§16, §38): delete `keychars` and the garbage fixture's
# set changes; delete `exact` and the wrong-value fixture goes green.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/../src" && pwd)"
EIGS="$SRC_DIR/eigenscript"
FIX_DIR="$TESTS_DIR/dict_keys_mt_fixtures"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_dict_keys_mt.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

# ---- the gate -----------------------------------------------------------
#
# Sets VERIFY_FIRED to a "+"-joined, sorted list of the CHECK NAMES that fired
# (empty string = the capture is good). Deliberately NOT echo-and-capture: a
# `v=$(verify_capture ...)` would run it in a subshell and the caller could not
# see the globals (the same trap tests/test_tsan.sh records for tsan_warnings).
#
# Checks, and what each one alone can see:
#   rc         the probe exited nonzero (the nested/reuse shapes die on a
#              `cannot access field ... on null` once the key is garbage)
#   nonempty   the capture has no bytes at all
#   population the number of KEYS lines differs from the expected file, or is 0
#              (§121: a row that examined nothing is a FAIL, not a pass)
#   keycount   a `KEYS n ...` line does not carry n fields, or declares n <= 0
#   keychars   a key field is not [A-Za-z0-9_]+ — the freed-bytes signature,
#              and the one check that needs no expected file
#   valnull    a VALS line contains `null` — the other half of the symptom
#              (the key is gone, so the lookup misses), also expected-free
#   exact      the capture differs from the hand-written expected file
VERIFY_FIRED=""
verify_capture() {   # verify_capture <expected_file> <actual_file> <rc>
    local expected=$1 actual=$2 rc=$3
    local fired=""
    [ "$rc" -eq 0 ] || fired="$fired rc"
    if [ ! -s "$actual" ]; then
        fired="$fired nonempty"
    fi
    # One awk pass over the capture. Every regex is a STATIC ERE and the key
    # split uses a bracket expression, never a bare "|" — a single-character
    # split string is literal in some awks and a regex in others (§63), and a
    # gate whose meaning depends on which awk is installed is a coin flip.
    local stats a_keys badcount badchars valnull
    stats=$(awk '
        $1 == "KEYS" {
            keys++
            n = $2 + 0
            rest = $0
            sub(/^KEYS [0-9]+ /, "", rest)
            cnt = split(rest, parts, "[|]")
            if (n <= 0 || cnt != n) badcount++
            for (i = 1; i <= cnt; i++)
                if (parts[i] !~ /^[A-Za-z0-9_]+$/) badchars++
        }
        $1 == "VALS" {
            if ($0 ~ /(^| |[|])null([|]| |$)/) valnull++
        }
        END { print keys+0, badcount+0, badchars+0, valnull+0 }' "$actual" 2>/dev/null)
    # Fail CLOSED if awk produced nothing (a dialect that choked, a missing
    # file): a default of all-zeros would make a broken instrument read as a
    # clean capture (§18 — degrade to noisy, never to quiet).
    read -r a_keys badcount badchars valnull <<< "${stats:-0 1 1 1}"
    local e_keys
    e_keys=$(awk '$1 == "KEYS" { keys++ } END { print keys+0 }' "$expected" 2>/dev/null)
    [ "$a_keys" = "$e_keys" ] && [ "${a_keys:-0}" -gt 0 ] || fired="$fired population"
    [ "${badcount:-1}" -eq 0 ] || fired="$fired keycount"
    [ "${badchars:-1}" -eq 0 ] || fired="$fired keychars"
    [ "${valnull:-1}" -eq 0 ] || fired="$fired valnull"
    cmp -s "$expected" "$actual" || fired="$fired exact"
    VERIFY_FIRED=$(printf '%s\n' $fired | sort | paste -sd+ -)
    [ -z "$VERIFY_FIRED" ]
}

# Bounded run, pure shell. `timeout` is not on the macOS runners (a child that
# calls it bare dies rc 127 there), so background / poll / kill BY PID.
RUN_RC=0
run_probe() {   # run_probe <eigs file> <out file>
    local prog=$1 out=$2 pid rc="" waited=0
    "$EIGS" "$prog" > "$out" 2>&1 &
    pid=$!
    while [ "$waited" -lt 300 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; break; fi
        sleep 0.1
        waited=$((waited + 1))
    done
    if [ -z "$rc" ]; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        echo "TIMEOUT after 30s" >> "$out"
        rc=124
    fi
    RUN_RC=$rc
}

# ---- selftest -----------------------------------------------------------

selftest() {
    # Each row: fixture name, rc to feed, expected file, and the EXACT set of
    # check names that must fire. The sets are pinned literals derived from
    # what each capture IS, not copied from a run (§4). A "" set means the
    # fixture must be accepted.
    #
    #   bad_inplace   real capture, binary without the fix: 3 fields as
    #                 declared, so keycount stays quiet; the keys are freed
    #                 bytes and both new fields read null.
    #   bad_list      real capture, same binary, different shape.
    #   bad_nested    real capture: dies mid-print, so the capture is short
    #                 (population) and the probe exits nonzero (rc).
    #   wrong_count   synthetic: clean keys, rc 0, but the declared field
    #                 count does not match the fields. `keycount` is the only
    #                 structural check that fires — none of the three real
    #                 captures happened to carry a `|` inside the freed bytes,
    #                 and a branch with no fixture where it is the sole
    #                 structural evidence is untested however many fixtures
    #                 exist (§38).
    #   wrong_value   synthetic: clean keys, right counts, rc 0, one VALUE
    #                 changed. `exact` is the SOLE evidence here — delete it
    #                 and this row reads green (§38).
    #   empty         the zero-population case: no bytes at all.
    #   good_inplace  POSITIVE control — a byte-correct capture must pass, or
    #                 a gate that always fails would satisfy every row above
    #                 (§15: a positive control needs both halves).
    local rows='
bad_inplace|0|expect_inplace.out|exact+keychars+valnull
bad_list|0|expect_list.out|exact+keychars+valnull
bad_nested|1|expect_nested.out|exact+keychars+keycount+population+rc
wrong_count|0|expect_inplace.out|exact+keycount
wrong_value|0|expect_inplace.out|exact
empty|0|expect_inplace.out|exact+nonempty+population
good_inplace|0|expect_inplace.out|
'
    local examined=0 declared=0
    declared=$(printf '%s\n' "$rows" | grep -c '|')
    local name rc expfile want
    while IFS='|' read -r name rc expfile want; do
        [ -n "$name" ] || continue
        examined=$((examined + 1))
        local cap="$FIX_DIR/$name.cap"
        if [ ! -f "$cap" ]; then
            fail "selftest: fixture $name.cap present" "missing $cap"
            continue
        fi
        verify_capture "$FIX_DIR/$expfile" "$cap" "$rc"
        if [ "$VERIFY_FIRED" = "$want" ]; then
            ok "selftest: $name fires exactly [${want:-none}]"
        else
            fail "selftest: $name fires exactly [${want:-none}]" "got [${VERIFY_FIRED:-none}]"
        fi
    done <<< "$rows"
    if [ "$examined" -eq "$declared" ] && [ "$examined" -gt 0 ]; then
        ok "selftest: examined == declared fixtures ($examined)"
    else
        fail "selftest: examined == declared fixtures" "examined=$examined declared=$declared"
    fi

    echo ""
    echo "DICT_KEYS_MT_SELFTEST: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
fi

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "DICT_KEYS_MT: 0 passed, 1 failed"
    exit 1
fi

# ---- structural rows ----------------------------------------------------

echo "=== construction: the process-global key insert is serialised ==="
SRC="$SRC_DIR/eigenscript.c"
if [ ! -f "$SRC" ]; then
    fail "construction: src/eigenscript.c not found" "$SRC"
else
    sik_body=$(awk '/^static const char \*shared_intern_key\(const char \*name\) \{/ {f=1}
                    f {print}
                    f && /^\}$/ {exit}' "$SRC")
    sik_lines=$(printf '%s\n' "$sik_body" | grep -c .)
    # §121: a renamed or reshaped function yields an empty body and every row
    # below would pass having examined nothing.
    if [ "$sik_lines" -gt 5 ]; then
        ok "construction: shared_intern_key body located (examined=$sik_lines lines)"
    else
        fail "construction: shared_intern_key body located" "examined=$sik_lines lines"
    fi
    n_lock=$(printf '%s\n' "$sik_body" | grep -c 'pthread_mutex_lock(&g_shared_key_mutex)')
    n_unlock=$(printf '%s\n' "$sik_body" | grep -c 'pthread_mutex_unlock(&g_shared_key_mutex)')
    n_return=$(printf '%s\n' "$sik_body" | grep -c '^ *return ')
    if [ "$n_lock" -eq 1 ]; then
        ok "construction: shared_intern_key takes the mutex exactly once (n=$n_lock)"
    else
        fail "construction: shared_intern_key takes the mutex exactly once" "n=$n_lock"
    fi
    # Not "unlock >= 1": an exit that forgets the unlock deadlocks the next
    # writer, so the property is one unlock PER EXIT, checked against the
    # return count rather than a literal.
    if [ "$n_unlock" -eq "$n_return" ] && [ "$n_return" -gt 1 ]; then
        ok "construction: every shared_intern_key exit unlocks (returns=$n_return unlocks=$n_unlock)"
    else
        fail "construction: every shared_intern_key exit unlocks" \
             "returns=$n_return unlocks=$n_unlock"
    fi
    # The bucket array must have exactly one writer, and it must be the
    # locked one. A second writer anywhere is an unsynchronised push.
    n_writers=$(grep -c 'g_shared_key_interns\[[a-z]*\] *=' "$SRC")
    if [ "$n_writers" -eq 1 ]; then
        ok "construction: g_shared_key_interns has exactly 1 writer (n=$n_writers)"
    else
        fail "construction: g_shared_key_interns has exactly 1 writer" \
             "n=$n_writers at $(grep -n 'g_shared_key_interns\[[a-z]*\] *=' "$SRC" | head -2 | tr '\n' ' ')"
    fi
    # The four SUBSCRIPTED uses are the declaration, the lookup walk, and the
    # two halves of the push. A fifth means a second owner of the table — a
    # reader outside the lock, or a drain that frees entries the fix promised
    # would outlive every thread. Matching on the `[` keeps ordinary prose
    # about the table out of the population without constraining how comments
    # are written (§54); a comment that does spell the subscript trips this
    # LOUDLY, which is the right direction.
    n_uses=$(grep -c 'g_shared_key_interns\[' "$SRC")
    if [ "$n_uses" -eq 4 ]; then
        ok "construction: g_shared_key_interns subscripted at exactly 4 sites (n=$n_uses)"
    else
        fail "construction: g_shared_key_interns subscripted at exactly 4 sites" \
             "n=$n_uses (declaration + lookup + push->next + push->head)"
    fi

    dsr_body=$(awk '/^void dict_set_hashed_raw\(Value \*dict, const char \*key, uint32_t h, Value \*val\) \{/ {f=1}
                    f {print}
                    f && /^\}$/ {exit}' "$SRC")
    dsr_lines=$(printf '%s\n' "$dsr_body" | grep -c .)
    if [ "$dsr_lines" -gt 5 ]; then
        ok "construction: dict_set_hashed_raw body located (examined=$dsr_lines lines)"
    else
        fail "construction: dict_set_hashed_raw body located" "examined=$dsr_lines lines"
    fi
    n_gate=$(printf '%s\n' "$dsr_body" | grep -c '__builtin_expect(g_vm_multithreaded, 0)')
    n_shared=$(printf '%s\n' "$dsr_body" | grep -c 'shared_intern_key(key)')
    if [ "$n_gate" -eq 1 ] && [ "$n_shared" -eq 1 ]; then
        ok "construction: the insert re-homes under the MT gate (gate=$n_gate rehome=$n_shared)"
    else
        fail "construction: the insert re-homes under the MT gate" \
             "gate=$n_gate rehome=$n_shared"
    fi

    # The module-namespace half. `M.k is v` on a worker writes BOTH a dict key
    # (re-homed above) and an env BINDING NAME in a sealed root env, and only
    # the second is read back by `keys of M` (eigs_module_ns_sync walks
    # e->names[]). A fix that covers only the dict leaves a live
    # heap-use-after-free that no dict-only row can see.
    esl_body=$(awk '/^void env_set_local_hashed\(Env \*env, const char \*name, uint32_t h, Value \*val\) \{/ {f=1}
                    f {print}
                    f && /^\}$/ {exit}' "$SRC")
    esl_lines=$(printf '%s\n' "$esl_body" | grep -c .)
    n_esl_rehome=$(printf '%s\n' "$esl_body" | grep -c 'shared_intern_key(name)')
    n_esl_gate=$(printf '%s\n' "$esl_body" | grep -c '__builtin_expect(g_vm_multithreaded, 0)')
    if [ "$esl_lines" -gt 5 ] && [ "$n_esl_rehome" -eq 1 ] && [ "$n_esl_gate" -ge 1 ]; then
        ok "construction: a shared-root binding name re-homes too (examined=$esl_lines rehome=$n_esl_rehome)"
    else
        fail "construction: a shared-root binding name re-homes too" \
             "examined=$esl_lines rehome=$n_esl_rehome gate=$n_esl_gate"
    fi
    # The guard must be the bare multithreaded flag and NOTHING ELSE — an
    # extra conjunct is how this half was wrong the first time (env_mt_shared
    # is `multithreaded && parent == NULL`, and a module env has a parent, so
    # the re-home never ran). This is the one
    # row in the file anchored on a spelling rather than on a property, and
    # the reason is measured, not stylistic: narrowing the guard produces a
    # real heap-use-after-free (ASan: module_ns_public <- eigs_module_ns_sync
    # <- builtin_keys, freed by the worker in env_intern_table_unref) that the
    # RELEASE binary does not show — `keys of M` prints the DICT's key array,
    # which is re-homed either way, so the stale env name is read and
    # discarded without reaching the output. Measured on a build with the
    # guard narrowed: dict_keys_mt_module printed the correct keys 5 of 5
    # times. The harm is gated by the ASan/TSan arms; this row gates the
    # decision (mechanical-gates §78 — a decision-witness runs every time and
    # is strictly weaker than a harm-witness, and must not be described as
    # though it were the same thing).
    n_esl_guard=$(printf '%s\n' "$esl_body" \
                  | grep -cE '^ *env->names\[env->count\] = __builtin_expect\(g_vm_multithreaded, 0\)$')
    if [ "$n_esl_guard" -eq 1 ]; then
        ok "construction: the binding-name guard is the bare MT flag (n=$n_esl_guard)"
    else
        fail "construction: the binding-name guard is the bare MT flag" \
             "n=$n_esl_guard — an extra conjunct narrows it to a no-op"
    fi

    # T3: the per-thread tables must still drain at detach for keys only that
    # thread ever used — the fix adds a lifetime, it does not remove one.
    drain_body=$(awk '/^void eigs_thread_drain_caches\(EigsThread \*th\) \{/ {f=1}
                      f {print}
                      f && /^\}$/ {exit}' "$SRC")
    drain_lines=$(printf '%s\n' "$drain_body" | grep -c .)
    n_unref=$(printf '%s\n' "$drain_body" | grep -c 'env_intern_table_unref(th->intern_tbl)')
    if [ "$drain_lines" -gt 5 ] && [ "$n_unref" -eq 1 ]; then
        ok "construction: detach still releases the thread intern table (examined=$drain_lines n=$n_unref)"
    else
        fail "construction: detach still releases the thread intern table" \
             "examined=$drain_lines n=$n_unref"
    fi
fi

# ---- live rows ----------------------------------------------------------
#
# The table IS the population (§121): every probe listed here is run and
# verified, and the run asserts examined == declared > 0 at the end.
PROBES='
dict_keys_mt_inplace|expect_inplace.out
dict_keys_mt_list|expect_list.out
dict_keys_mt_nested|expect_nested.out
dict_keys_mt_reuse|expect_reuse.out
dict_keys_mt_concurrent|expect_concurrent.out
dict_keys_mt_module|expect_module.out
dict_keys_mt_single|expect_single.out
'
declared=$(printf '%s\n' "$PROBES" | grep -c '|')
examined=0

echo "=== live: a key written by a worker survives the worker ==="
while IFS='|' read -r probe expfile; do
    [ -n "$probe" ] || continue
    examined=$((examined + 1))
    prog="$TESTS_DIR/$probe.eigs"
    exp="$FIX_DIR/$expfile"
    if [ ! -f "$prog" ] || [ ! -f "$exp" ]; then
        fail "$probe: fixture present" "prog=$prog exp=$exp"
        continue
    fi
    out="$TMPDIR/$probe.out"
    run_probe "$prog" "$out"
    if verify_capture "$exp" "$out" "$RUN_RC"; then
        ok "$probe: keys and values intact (rc=$RUN_RC)"
    else
        fail "$probe: keys and values intact" \
             "rc=$RUN_RC fired=[$VERIFY_FIRED] got=$(head -1 "$out" | cat -v | cut -c1-90)"
    fi
done <<< "$PROBES"

if [ "$examined" -eq "$declared" ] && [ "$examined" -gt 0 ]; then
    ok "live: examined == declared probes ($examined)"
else
    fail "live: examined == declared probes" "examined=$examined declared=$declared"
fi

# T2's behaviour-identity row: the spawning program and the identical
# non-spawning one must produce the SAME output. This is the row that fails if
# the MT arm ever starts doing something the single-threaded arm does not.
echo "=== T2: the single-threaded arm is byte-identical to the MT arm ==="
if [ -s "$TMPDIR/dict_keys_mt_inplace.out" ] && [ -s "$TMPDIR/dict_keys_mt_single.out" ]; then
    if cmp -s "$TMPDIR/dict_keys_mt_inplace.out" "$TMPDIR/dict_keys_mt_single.out"; then
        ok "st-mt-identity: spawn and no-spawn produce identical output"
    else
        # cat -v: the differing bytes are freed heap and are not valid UTF-8.
        # A raw copy of them into the suite log breaks every later reader of
        # that log, including the mutation train's own attribution matcher.
        fail "st-mt-identity: spawn and no-spawn produce identical output" \
             "$(diff "$TMPDIR/dict_keys_mt_inplace.out" "$TMPDIR/dict_keys_mt_single.out" | head -4 | cat -v | tr '\n' ' ')"
    fi
else
    fail "st-mt-identity: both captures are non-empty" "one or both probes produced nothing"
fi

echo ""
echo "DICT_KEYS_MT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
