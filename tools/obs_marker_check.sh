#!/bin/bash
# Observer-classification marker gate (#972).
#
# WHAT THIS GATE IS FOR
#
# The planned optimisation behind #972 is: stop emitting observer bookkeeping
# when a program provably never reads observer state. Its failure mode is
# silent and total — a program gates itself off, then reads slots nobody
# updated, and every binding answers "equilibrium" forever with no crash and
# nothing to fail on. So the scan that decides "does this chunk contain a
# reader?" must be complete, and completeness has to be pinned against the
# closed set of opcodes.
#
# WHY THE CLASSIFICATION IS NOT DERIVED
#
# Five attempts to derive the reader set from the C are recorded on #972, and
# all five produced a CONFIDENT WRONG ANSWER in one direction or the other:
#
#   1. grep the read-side API          -> missed obs_stall_trajectory(), which
#                                         reads s->used/s->dH/s->entropy with no
#                                         observer_slot_* call anywhere
#   2. objdump -dr relocations         -> missed the same reader: a struct-field
#                                         read emits no symbol reference
#   3. scan for struct-field reads     -> false-positived on three unrelated
#                                         functions reading a ->n
#   4. classify by scanning `case OP_X:`-> matched NOTHING (the VM dispatches
#                                         through CASE(NAME) computed-goto
#                                         macros) and reported a clean empty set
#   5. same scan repaired to CASE(X)   -> matched EVERYTHING, including a scope
#                                         marker and a writer, because the
#                                         handler terminator did not match and
#                                         each scan ran on into later handlers
#
# The C source is the OPEN level (mechanical-gates 48): a read can be spelled
# arbitrarily many ways, so no matcher over it bounds the population. The enum
# is the CLOSED level. So this gate does not classify anything. It asks the one
# question that IS mechanically answerable:
#
#     HAS EVERY OPCODE BEEN CLASSIFIED BY A HUMAN?
#
# A missing marker is a loud unanswered question at the moment an opcode is
# added, which is exactly when its author knows the answer and nobody else ever
# will. Same shape, and same reason, as tools/failsoft_classify_check.sh.
#
# WHAT A MARKER MEANS
#
# Observer/temporal state, for the purpose of these markers, is the state a
# program can obtain ONLY through an observer or temporal query:
#   (a) the per-binding ObserverSlot under Env::obs — entropy/last_entropy/
#       dH/prev_dH/obs_age and the dH/value/raw windows;
#   (b) Env::assign_counts, the per-slot assignment ordinals behind `when is x`;
#   (c) the recorded assignment history read by trace_query_prev/at/when
#       (`prev`, `at L`, `when N`) and the g_trace_current_line stamp it is
#       addressed by;
#   (d) the recording controls — g_unobserved_depth and the g_last_obs_slot_*
#       alias the bare predicate reads through.
#
#   obs:READS   the handler is answering FROM (a)/(b)/(c) recorded earlier: its
#               pushed result or its control-flow decision depends on them. If
#               bookkeeping is elided, this opcode answers wrong and silently.
#               THIS IS THE SET THE LIVENESS SCAN CONSUMES.
#   obs:WRITES  the handler records, updates, resets or stamps (a)-(d) and does
#               not answer from them.
#   obs:DIAG    the handler reaches observer state ONLY through the SIGUSR1
#               diagnostic dump (eigs_observe_safepoint), never through
#               program-visible semantics.
#   obs:NONE    none of the above.
#
# READS DOMINATES: an opcode that both reads and records is marked READS.
#
# obs:DIAG exists because collapsing it either way is wrong, and the choice is a
# decision rather than a derivation. OP_LOOP_CAP_CHECK is emitted at every plain
# loop and its only reach into observer state is eigs_observe_safepoint's dump.
# Calling that READS would pin bookkeeping on for every loop in every program
# and delete the entire win (mechanical-gates 9: an unbounded closure marks
# every loop as a reader). Calling it NONE would silently drop the obligation
# that the dump must SAY the gate is closed rather than render every binding as
# "equilibrium" (mechanical-gates 11). DIAG records the waiver as a marker
# instead of as prose, so the elision can enumerate exactly who owes that.
#
# WHAT THIS GATE DOES NOT DO — read this before trusting it
#
#   * It does NOT check that a verdict is CORRECT. It checks that a verdict was
#     recorded. Correctness rests on the handler having been read; the reading
#     for the initial 94 is recorded in the PR for #972.
#   * It does NOT close over callees. A marker describes the handler's own
#     semantics. Three edges are deliberately excluded, each because another
#     mechanism covers it, and each is a waiver in the mechanical-gates 3 sense:
#       - OP_CALL / OP_IMPORT / OP_DISPATCH run other code. The callee chunk is
#         scanned on its own way in, so attributing its reads here would say
#         only "this opcode can run other code".
#       - OP_JUMP_BACK can enter a JIT OSR thunk. The JIT has its OWN reader
#         (jit_helper_report_slot) and needs its own scan; #972 lists it as a
#         separate bypass route.
#       - assembled chunks (vm_run_bytecode / sandbox_run) never pass through
#         the compiler at all and need a bytecode twin of the scan;
#         chunk_arm_temporal is the precedent. Also listed on #972.
#   * The obs:WRITES set is informational here. The liveness scan keys on READS.
#
# Usage: tools/obs_marker_check.sh [--selftest] [--reads]
#   --selftest : run the mutation train against COPIES of the header in a temp
#                dir (this gate never writes to the tree it checks).
#   --reads    : print the obs:READS opcode set, one per line. This is the
#                liveness scan's input; it is derived from the markers so the
#                scan and the header cannot drift (mechanical-gates 26).
# Exit 0 = every opcode carries exactly one well-formed marker.

set -u
cd "$(dirname "$0")/.." || exit 1

VM_HEADER="${VM_HEADER:-src/vm.h}"

# Coverage floor, not an exact count. Opcodes are APPEND-ONLY by the bytecode
# ABI rule stated in the enum itself (hand-built chunks hardcode opcode
# numbers), so this number only ever grows; a floor moves only when coverage is
# REMOVED, which is always a review event. Measured on the tree that introduced
# this gate: 94 opcodes plus the OP_COUNT sentinel.
OPCODE_FLOOR="${OPCODE_FLOOR:-94}"

# Non-vacuity floor on the READS set specifically. This set IS the liveness
# scan's input: if it silently collapsed to empty, every program would be
# classified as observer-free and elided, which is precisely the catastrophic
# failure the whole gate exists to prevent. `-z` is an emptiness test, not a
# floor (mechanical-gates 43) — a set that shrinks 15 -> 14 because a reader was
# re-marked NONE is the realistic mutation, and only a floor sees it.
READS_FLOOR="${READS_FLOOR:-15}"

# The number of assertions check_tree runs. Pinned so that deleting a whole
# assertion cannot quietly shrink this gate while it keeps printing PASS
# (mechanical-gates 37). There are no skip paths: this gate needs only bash and
# awk, both hard dependencies of every other gate in tools/.
EXPECTED_CHECKS=7

# The marker vocabulary. A token outside this set is a typo (obs:READ) or an
# invention, and either way it is not a recorded decision.
VALID_MARKERS="READS WRITES NONE DIAG"

# The one exempted enum entry, with its reason, pinned by name. OP_COUNT is a
# sentinel: it has no opcode number in any chunk and no handler in vm.c, so
# there is nothing to classify. An exemption that stops firing must FAIL rather
# than pass quietly (mechanical-gates 3), so the checks below require OP_COUNT
# to be present, to be LAST, and to be unmarked.
SENTINEL="OP_COUNT"

# Emit one record per enum entry:  OP_NAME<TAB>MARKER<TAB>LINENO
# MARKER is "-" when absent, "?dup" when the line carries more than one marker,
# and the raw token otherwise (validated by the caller, not here).
# Also emits ORPHAN records for a marker sitting on a non-declaration line.
#
# awk portability (mechanical-gates 63): no 3-argument match(), no gensub(), no
# dynamic regex. The marker is found with index() on the literal "/*obs:" —
# exact substring, identical semantics in mawk, gawk, busybox awk and macOS awk.
# The literal spelling also keeps prose out of the population: a comment that
# happens to discuss obs: markers does not carry the "/*obs:" opener.
enum_records() {
    awk '
        # Track the start of every candidate enum; the OpCode enum is the one
        # that CLOSES with "} OpCode;". Anchoring on the closer rather than on
        # "the first typedef enum" survives another enum being added above it.
        /^typedef enum \{$/ { start = NR }
        { line[NR] = $0 }
        /^\} OpCode;/ {
            if (start == 0) { print "GATEERROR\tno-enum-open"; exit }
            for (i = start + 1; i < NR; i++) {
                s = line[i]
                # Opcode declaration: OP_NAME at the head of the line, followed
                # by a comma, or by whitespace/end for the trailing sentinel.
                isdecl = 0; name = ""
                if (match(s, /^[ \t]*OP_[A-Z0-9_]+/)) {
                    tok = substr(s, RSTART, RLENGTH)
                    sub(/^[ \t]*/, "", tok)
                    after = substr(s, RSTART + RLENGTH, 1)
                    if (after == "," || after == "" || after == " " || after == "\t") {
                        isdecl = 1; name = tok
                    }
                }
                # Count markers on this line with a literal substring scan.
                nmark = 0; first = ""
                rest = s
                while ((p = index(rest, "/*obs:")) > 0) {
                    nmark++
                    tail = substr(rest, p + 6)
                    q = index(tail, "*/")
                    val = (q > 0) ? substr(tail, 1, q - 1) : "?unterminated"
                    if (nmark == 1) first = val
                    rest = (q > 0) ? substr(tail, q + 2) : ""
                }
                if (isdecl) {
                    if (nmark == 0)      print name "\t-\t" i
                    else if (nmark > 1)  print name "\t?dup\t" i
                    else                 print name "\t" first "\t" i
                } else if (nmark > 0) {
                    print "ORPHAN\t" first "\t" i
                }
            }
            exit
        }
    ' "$VM_HEADER"
}

check_tree() {
    local records checks=0 fail=0
    local total=0 reads=0 writes=0 none=0 diag=0
    local name marker lineno last_name="" sentinel_marker="" sentinel_seen=0

    records=$(enum_records)

    # ---- check 1: the enum was found and parsed at all --------------------
    # Vacuity first. A gate whose derivation silently returned nothing prints a
    # confident PASS over an empty population (mechanical-gates 48).
    checks=$((checks + 1))
    if [ -z "$records" ] || printf '%s\n' "$records" | grep -q '^GATEERROR'; then
        echo "GATE ERROR: could not locate the OpCode enum in $VM_HEADER"
        echo "  (expected a 'typedef enum {' ... '} OpCode;' block)"
        return 1
    fi

    # ---- check 2: no orphan markers ---------------------------------------
    # The reverse direction of membership (mechanical-gates 2). A marker left
    # behind on a renamed or deleted opcode, or dropped onto a comment line,
    # drifts from the enum without the forward check noticing.
    checks=$((checks + 1))
    local orphans
    orphans=$(printf '%s\n' "$records" | awk -F'\t' '$1 == "ORPHAN" { print $3 }')
    if [ -n "$orphans" ]; then
        for lineno in $orphans; do
            echo "ASSERTION FAILED: orphan marker at $VM_HEADER:$lineno declares no opcode"
        done
        fail=1
    fi

    # ---- checks 3+4: every opcode is marked, with a valid token ------------
    checks=$((checks + 2))
    while IFS="$(printf '\t')" read -r name marker lineno; do
        [ "$name" = "ORPHAN" ] && continue
        if [ "$name" = "$SENTINEL" ]; then
            sentinel_seen=1
            sentinel_marker="$marker"
            last_name="$name"
            continue
        fi
        total=$((total + 1))
        last_name="$name"
        case "$marker" in
            -)
                echo "ASSERTION FAILED: $name has no obs: marker ($VM_HEADER:$lineno)"
                echo "  Read its handler in src/vm.c and record one of: $VALID_MARKERS."
                echo "  Do NOT derive this from the C — five derivations on #972 were wrong."
                fail=1
                continue ;;
            "?dup")
                echo "ASSERTION FAILED: $name carries more than one obs: marker ($VM_HEADER:$lineno)"
                fail=1
                continue ;;
        esac
        local ok=0 v
        for v in $VALID_MARKERS; do [ "$marker" = "$v" ] && ok=1; done
        if [ "$ok" -eq 0 ]; then
            echo "ASSERTION FAILED: $name has unknown marker obs:$marker ($VM_HEADER:$lineno)"
            echo "  Valid markers: $VALID_MARKERS"
            fail=1
            continue
        fi
        case "$marker" in
            READS)  reads=$((reads + 1)) ;;
            WRITES) writes=$((writes + 1)) ;;
            NONE)   none=$((none + 1)) ;;
            DIAG)   diag=$((diag + 1)) ;;
        esac
    done <<EOF
$records
EOF

    # ---- check 5: the OP_COUNT exemption still fires -----------------------
    # Present, last, and unmarked. If the sentinel gains a marker the exemption
    # has stopped describing the tree; if it disappears or moves, the enum has
    # been restructured under a gate that assumes append-only.
    checks=$((checks + 1))
    if [ "$sentinel_seen" -eq 0 ]; then
        echo "ASSERTION FAILED: exempted sentinel $SENTINEL is not in the enum"
        echo "  The exemption is written against an entry that no longer exists."
        fail=1
    elif [ "$last_name" != "$SENTINEL" ]; then
        echo "ASSERTION FAILED: $SENTINEL is not the last enum entry (found $last_name after it)"
        fail=1
    elif [ "$sentinel_marker" != "-" ]; then
        echo "ASSERTION FAILED: $SENTINEL carries obs:$sentinel_marker but is exempt as a sentinel"
        echo "  It has no opcode number and no handler; there is nothing to classify."
        fail=1
    fi

    # ---- check 6: coverage floor ------------------------------------------
    checks=$((checks + 1))
    if [ "$total" -lt "$OPCODE_FLOOR" ]; then
        echo "GATE ERROR: only $total opcode(s) found, floor is $OPCODE_FLOOR"
        echo "  The population is derived from the enum, so it can SHRINK silently."
        echo "  A decrease is a review event, not a number to adjust."
        fail=1
    fi

    # ---- check 7: the READS set has not collapsed --------------------------
    checks=$((checks + 1))
    if [ "$reads" -lt "$READS_FLOOR" ]; then
        echo "GATE ERROR: obs:READS set has $reads opcode(s), floor is $READS_FLOOR"
        echo "  This set is the liveness scan's input. A collapse here classifies"
        echo "  every program as observer-free and elides bookkeeping everywhere."
        fail=1
    fi

    if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
        echo "GATE ERROR: ran $checks assertion(s), expected $EXPECTED_CHECKS"
        echo "  An assertion was added or removed without updating EXPECTED_CHECKS."
        fail=1
    fi

    [ "$fail" -ne 0 ] && return 1

    echo "PASS: $total opcodes classified (READS=$reads WRITES=$writes DIAG=$diag NONE=$none), $checks checks"
    return 0
}

emit_reads() {
    enum_records | awk -F'\t' '$1 != "ORPHAN" && $2 == "READS" { print $1 }'
}

if [ "${1:-}" = "--reads" ]; then
    emit_reads
    exit 0
fi

if [ "${1:-}" = "--selftest" ]; then
    st_fail=0
    work=$(mktemp -d) || exit 1
    # One trap only: a second `trap ... EXIT` REPLACES the first rather than
    # accumulating (mechanical-gates 7). Guard the expansion under `set -u`.
    trap 'rm -rf "${work:-}"' EXIT

    # Positive control, both halves (mechanical-gates 15): the real tree must
    # PASS, or every "the mutant was caught" result below is meaningless — a
    # check that always fails satisfies every sabotage.
    if ! check_tree >/dev/null 2>&1; then
        echo "SELFTEST FAILED: the real tree does not pass its own marker check"
        check_tree
        st_fail=1
    else
        echo "SELFTEST OK: the unmutated tree passes (positive control)"
    fi

    # Helper: run check_tree against a mutant header, require it to FAIL, and
    # require the failure to name the intended assertion. The attribution
    # matcher is never a bare filename or path — those appear in every
    # unrelated error about the file (mechanical-gates 19/58).
    expect_red() {
        local label="$1" header="$2" needle="$3" out
        if [ ! -s "$header" ]; then
            echo "SELFTEST FAILED: $label — mutant header was not produced"
            st_fail=1; return
        fi
        if cmp -s "$header" "$VM_HEADER"; then
            echo "SELFTEST FAILED: $label — mutation was a no-op (header unchanged)"
            st_fail=1; return
        fi
        if out=$(VM_HEADER="$header" check_tree 2>&1); then
            echo "SELFTEST FAILED: $label — mutant was NOT caught"
            printf '%s\n' "$out"
            st_fail=1; return
        fi
        if ! printf '%s\n' "$out" | grep -qF "$needle"; then
            echo "SELFTEST FAILED: $label — caught, but not at the expected assertion"
            printf '%s\n' "$out"
            st_fail=1; return
        fi
        echo "SELFTEST OK: $label"
    }

    # 1. Remove one marker. REPLACE rather than delete (mechanical-gates 41):
    #    the line keeps its shape, so no length- or count-based check can reject
    #    it on the target assertion behalf. OP_PREDICATE is chosen because it is
    #    a real reader — losing its marker is the mutation that matters.
    awk '
        index($0, "OP_PREDICATE,") == 1 || index($0, "    OP_PREDICATE,") == 1 {
            p = index($0, "/*obs:READS*/")
            if (p > 0 && !done) {
                print substr($0, 1, p - 1) "             " substr($0, p + 13)
                done = 1
                next
            }
        }
        { print }
    ' "$VM_HEADER" > "$work/unmarked.h"
    expect_red "a reader losing its marker is caught by name" "$work/unmarked.h" \
        "ASSERTION FAILED: OP_PREDICATE has no obs: marker"

    # 2. Mis-spell a marker. A typo is not a recorded decision, and a gate that
    #    accepts obs:READ has a vocabulary that is open rather than closed.
    sed 's@/\*obs:READS\*/@/*obs:READ*/@' "$VM_HEADER" > "$work/typo.h"
    expect_red "an unknown marker token is rejected" "$work/typo.h" \
        "has unknown marker obs:READ "

    # 3. Orphan marker: a marker on a line that declares no opcode. This is what
    #    a rename leaves behind, and only the reverse direction sees it.
    awk '
        { print }
        !done && index($0, "    /* Observer system */") == 1 {
            print "    /*obs:READS*/"
            done = 1
        }
    ' "$VM_HEADER" > "$work/orphan.h"
    expect_red "an orphan marker declaring no opcode is caught" "$work/orphan.h" \
        "ASSERTION FAILED: orphan marker at"

    # 4. Two markers on one line — an edit that leaves the old verdict beside
    #    the new one. Either could be the recorded decision, so neither is.
    sed 's@OP_REPORT_SLOT,     /\*obs:READS\*/@OP_REPORT_SLOT,     /*obs:READS*/ /*obs:NONE*/@' \
        "$VM_HEADER" > "$work/dup.h"
    expect_red "two markers on one opcode is caught" "$work/dup.h" \
        "ASSERTION FAILED: OP_REPORT_SLOT carries more than one obs: marker"

    # 5. Collapse the READS set to NONE. Every opcode still carries exactly one
    #    valid marker, the count is unchanged, and the forward/reverse checks
    #    are both satisfied — this mutation is invisible to everything except
    #    the READS floor, and it is the one that would silently elide
    #    bookkeeping for the entire language.
    sed 's@/\*obs:READS\*/@/*obs:NONE*/ @' "$VM_HEADER" > "$work/collapsed.h"
    expect_red "collapsing the READS set trips its non-vacuity floor" "$work/collapsed.h" \
        "GATE ERROR: obs:READS set has 0 opcode(s), floor is"

    # 6. Shrink the enum. A derived population can lose members without any
    #    assertion firing; only the floor sees it (mechanical-gates 43).
    awk '
        index($0, "    OP_TRAJECTORY_SLOT,") == 1 { skipping = 1 }
        index($0, "    OP_COUNT") == 1 { skipping = 0 }
        !skipping { print }
    ' "$VM_HEADER" > "$work/shrunk.h"
    expect_red "a shrinking opcode population trips the coverage floor" "$work/shrunk.h" \
        "GATE ERROR: only "

    # 7. Mark the exempted sentinel. The exemption is a written claim about
    #    OP_COUNT; if OP_COUNT starts carrying a verdict, the claim is stale.
    sed 's@^    OP_COUNT  @    OP_COUNT, /*obs:NONE*/  @' "$VM_HEADER" > "$work/sentinel.h"
    expect_red "marking the exempted sentinel is caught" "$work/sentinel.h" \
        "carries obs:NONE but is exempt as a sentinel"

    # 8. Remove the sentinel entirely. An exemption whose subject is gone must
    #    FAIL rather than pass quietly (mechanical-gates 3).
    grep -v '^    OP_COUNT' "$VM_HEADER" > "$work/nosentinel.h"
    expect_red "losing the exempted sentinel is caught" "$work/nosentinel.h" \
        "ASSERTION FAILED: exempted sentinel OP_COUNT is not in the enum"

    # 8b. Append an opcode AFTER the sentinel. This is the one sub-branch of the
    #     sentinel check with no other fixture: cases 7 and 8 are caught by the
    #     "carries a marker" and "is not in the enum" arms respectively, and
    #     neutering the position arm alone left the suite green until this case
    #     existed (mechanical-gates 38 — witness every alternation, not just the
    #     check). It matters because OP_COUNT == the opcode count is what makes
    #     the enum a closed list; an entry past it is silently uncounted.
    awk '
        !done && index($0, "    OP_COUNT") == 1 {
            print "    OP_COUNT,           /* sentinel */"
            print "    OP_PAST_SENTINEL /*obs:NONE*/"
            done = 1
            next
        }
        { print }
    ' "$VM_HEADER" > "$work/aftersentinel.h"
    expect_red "an opcode appended past the sentinel is caught" "$work/aftersentinel.h" \
        "ASSERTION FAILED: OP_COUNT is not the last enum entry"

    # 9. Break the enum derivation itself. If the parse silently returns
    #    nothing, every check above passes over an empty population.
    sed 's@^} OpCode;@} OpCodeRenamed;@' "$VM_HEADER" > "$work/noenum.h"
    expect_red "an unparseable enum is a GATE ERROR, not a clean pass" "$work/noenum.h" \
        "GATE ERROR: could not locate the OpCode enum"

    # 9b. Mutate the GATE, not the header: delete a whole assertion and require
    #     the check-count pin to notice. Without this, EXPECTED_CHECKS was
    #     unwitnessed — every header fixture above passed with the pin removed,
    #     so the gate advertised a guard against its own silent shrinkage while
    #     enforcing nothing (mechanical-gates 19/37).
    #
    #     The mutant runs from $work, so it cd's somewhere that has no src/;
    #     VM_HEADER is passed as an ABSOLUTE path so the mutant STARTS. An
    #     unstartable mutant is an invalid probe reported as CAUGHT — the first
    #     version of this check failed exactly that way, with all fixtures
    #     erroring identically because none of them could see a header.
    awk '
        index($0, "    # ---- check 7") == 1 { dropping = 1 }
        index($0, "    if [ \"$checks\" -ne \"$EXPECTED_CHECKS\" ]; then") == 1 { dropping = 0 }
        !dropping { print }
    ' "$0" > "$work/gate_mutant.sh"
    abs_header=$(cd "$(dirname "$VM_HEADER")" && pwd)/$(basename "$VM_HEADER")
    if cmp -s "$work/gate_mutant.sh" "$0"; then
        echo "SELFTEST FAILED: check-count pin — gate mutation was a no-op"
        st_fail=1
    elif out=$(VM_HEADER="$abs_header" bash "$work/gate_mutant.sh" 2>&1); then
        echo "SELFTEST FAILED: an assertion was deleted and the gate still passed"
        printf '%s\n' "$out"
        st_fail=1
    elif ! printf '%s\n' "$out" | grep -qF "GATE ERROR: ran 6 assertion(s), expected 7"; then
        # Distinguish "the pin fired" from "the mutant never started" — a
        # missing header, a bad shebang and a deleted assertion all exit
        # nonzero, and only the pin emits this sentence.
        echo "SELFTEST FAILED: deleting an assertion did not trip the check-count pin"
        printf '%s\n' "$out"
        st_fail=1
    else
        echo "SELFTEST OK: deleting an assertion trips the check-count pin"
    fi

    # 10. The --reads consumer contract must be non-vacuous too: it is what the
    #     liveness scan will read, and an empty answer there means "elide
    #     everywhere".
    n_reads=$(emit_reads | grep -c .)
    if [ "$n_reads" -lt "$READS_FLOOR" ]; then
        echo "SELFTEST FAILED: --reads emitted $n_reads opcode(s), floor is $READS_FLOOR"
        st_fail=1
    else
        echo "SELFTEST OK: --reads emits $n_reads reader opcodes"
    fi

    # 11. The gate must not mutate what it checks (mechanical-gates 22/28).
    #     Every mutation above went to a copy in $work; assert the tracked
    #     header is byte-identical to HEAD. Keyed to the tree under test, and
    #     skipped rather than faked when git is unavailable.
    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
        if git diff --quiet -- "$VM_HEADER" 2>/dev/null || \
           [ -z "$(git status --porcelain -- "$VM_HEADER")" ]; then
            echo "SELFTEST OK: the selftest left $VM_HEADER untouched"
        else
            echo "SELFTEST NOTE: $VM_HEADER differs from HEAD (expected while #972 is in flight);"
            echo "  the leavings check cannot distinguish that from selftest damage here."
        fi
    fi

    if [ "$st_fail" -eq 0 ]; then
        echo "SELFTEST PASS: observer-marker gate is non-vacuous"
    fi
    exit "$st_fail"
fi

check_tree
