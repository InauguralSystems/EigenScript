#!/bin/bash
# Uniform -Werror=switch gate (the #817 follow-up from PR #817 discussion).
#
# #738 made every ASTType/ValType/opcode switch exhaustive so the flag has
# teeth; #786/#817 then put `-Werror=switch` on every compile line in the
# tree (the last six hand-written flag lists were FLAGS_poison, jit-smoke,
# coverage, fuzz, fuzz-libfuzzer, freestanding-libc-diff). This gate keeps
# that invariant holding: it dry-runs every Makefile target that compiles C
# (`make -n -B`) and asserts the UNIFORM invariant — every emitted compile
# invocation carries the flag. Uniform, not variants-vs-auxiliary: a gate
# that classifies targets into "real" and "auxiliary" legs encodes a
# judgement that would need re-litigating at every audit; asserting the
# flag on every compile invocation is simpler and cannot be argued out of
# a leg.
#
# What counts as a compile invocation (the recognition rule):
#   dry-run recipes are joined at backslash continuations, then SPLIT into
#   individual invocations at shell separators (; && || |) — one logical
#   recipe line can hold several compiler calls, and each call must carry
#   the flag on its own: a test over the merged text would let the first
#   invocation's flag cover an unguarded second one. Each invocation with
#   a compiler command word (gcc/clang/cc) that COMPILES — it names a .c
#   source, or (for-loop bodies over a $var, like the coverage leg) it
#   carries -c — is one examined unit, counted and checked separately.
#   Pure link invocations (coverage's `gcc --coverage -o ...` over .o
#   files) name no .c and carry no -c: they compile nothing and are
#   excluded by definition — the flag is a compile-time option.
#   The flag is matched as a whole argument, never a substring:
#   `-Werror=switch-enum` is a different warning and must NOT satisfy
#   this gate.
#
# Compiles hidden INSIDE shell scripts are invisible to `make -n`, so the
# scripts whose compile lines the classifier can recognize are audited
# DIRECTLY (#835): comment lines stripped, then the script text goes
# through the same join/split/classify pipeline as a dry-run stream, with
# the same per-script zero-line hard failure. Today that list is
# tools/freestanding_check.sh — its gcc lines name "src/$f.c" literally.
# Blind spot, stated honestly: build.sh stays out of scope — its three
# compile lines are armed (#786) but name their sources via
# $SOURCES/$LSP_SOURCES variables, which the recognizer cannot tell from
# a pure link line, so auditing it would assert nothing (and the lsp/
# minimal lines would trip the zero-line assertion spuriously).
#
# A gate that silently matches nothing is worse than no gate — it passes
# forever. Two assertions prevent that. PER TARGET: a dry run yielding
# zero compile invocations is a hard failure naming the target — each of
# the 22 targets emits at least one today, and the one-line auxiliary
# legs (jit-smoke, fuzz, freestanding-libc-diff, ...) are exactly where
# #817's fixes live; a global total cannot see one of those die. And
# GLOBALLY: an examined count under the floor (100) hard-fails as a
# matcher-broke signal (the 11 VARIANTS alone emit >200 `-c` invocations
# under -B). The examined count is always printed.
#
# Usage: tools/werror_switch_check.sh [--selftest]
#   --selftest : feed synthetic dry-run streams (each fault shape planted
#                in-memory, no tree mutation) through the classifier and
#                confirm every one is classified correctly — proves the
#                checker isn't vacuously green.
# Exit 0 = every emitted compile invocation carries the flag; 1 = a
# violation, a make error, a target emitting no compile lines, an
# under-floor count, or a selftest failure.

set -u
cd "$(dirname "$0")/.." || exit 1

FLAG='-Werror=switch'
# Global sanity floor, secondary to the per-target zero-line assertion:
# VARIANTS (release full http zlib net gfx asan asan-http tsan valgrind
# poison) emit >= 19 `-c` invocations each under -B.
MIN_LINES=100

# Every Makefile target whose dry run emits compile invocations. Excluded:
# amalgamation/freestanding-check (recipes are `bash tools/...`, the
# compiles live inside those scripts), install* (cp; the lsp/dap compiles
# are covered by their own targets), test/clean/version/print-%/
# coverage-clean/fuzz-run (no compiles).
TARGETS="build full http zlib net gfx asan asan-http tsan valgrind poison \
         lsp dap jit-smoke lib embed-smoke embed-smoke-gfx pgo coverage \
         fuzz fuzz-libfuzzer freestanding-libc-diff"

# GNU make emits a shared prerequisite only once when several goals are in
# one invocation. `embed-smoke-gfx` depends on `gfx`, so keeping that goal in
# its own batch preserves the per-target counts that separate dry runs gave us
# while still reducing 22 make parses to two. If a future compile-bearing
# target gains a shared prerequisite, keep that dependent goal in its own
# batch as well.
TARGET_BATCHES=(
    "build full http zlib net gfx asan asan-http tsan valgrind poison lsp dap jit-smoke lib embed-smoke pgo coverage fuzz fuzz-libfuzzer freestanding-libc-diff"
    "embed-smoke-gfx"
)

# TARGET_BATCHES must cover TARGETS exactly.  Keep the hand-written batches
# loud if a target is ever omitted, added, or listed twice.
validate_target_batches() {
    local expected_targets="$1" batch target expected_target seen_target found
    shift
    local -a seen=() missing=() extras=() duplicates=()

    for batch in "$@"; do
        for target in $batch; do
            found=0
            for expected_target in $expected_targets; do
                if [ "$target" = "$expected_target" ]; then
                    found=1
                    break
                fi
            done
            if [ "$found" -eq 0 ]; then
                extras+=("$target")
            else
                found=0
                if [ "${#seen[@]}" -gt 0 ]; then
                    for seen_target in "${seen[@]}"; do
                        if [ "$target" = "$seen_target" ]; then
                            found=1
                            break
                        fi
                    done
                fi
                if [ "$found" -ne 0 ]; then
                    duplicates+=("$target")
                else
                    seen+=("$target")
                fi
            fi
        done
    done
    for target in $expected_targets; do
        found=0
        if [ "${#seen[@]}" -gt 0 ]; then
            for seen_target in "${seen[@]}"; do
                if [ "$target" = "$seen_target" ]; then
                    found=1
                    break
                fi
            done
        fi
        if [ "$found" -eq 0 ]; then
            missing+=("$target")
        fi
    done

    if [ "${#missing[@]}" -ne 0 ] || [ "${#extras[@]}" -ne 0 ] \
       || [ "${#duplicates[@]}" -ne 0 ]; then
        echo "GATE ERROR: TARGET_BATCHES diverges from TARGETS"
        [ "${#missing[@]}" -eq 0 ] || echo "  missing target(s): ${missing[*]}"
        [ "${#extras[@]}" -eq 0 ] || echo "  extra target(s): ${extras[*]}"
        [ "${#duplicates[@]}" -eq 0 ] || echo "  duplicate target(s): ${duplicates[*]}"
        return 1
    fi
    return 0
}

# Compile-bearing shell scripts audited directly (#835) — see header.
SCRIPT_AUDITS="tools/freestanding_check.sh"

# Comment lines must not be examined: a script comment QUOTING a bare
# compile line is not a compile.
strip_comments() {
    grep -vE '^[[:space:]]*#'
}

EXAMINED=0          # compile invocations examined, all targets
VIOLATIONS=0        # examined invocations missing the flag
TARGET_EXAMINED=0   # examined within the current target (reset per target)
TARGETS_AUDITED=0   # target segments with at least one compile invocation

# Join backslash-continued recipe lines into single logical lines.
join_continuations() {
    awk '{
        line = $0
        while (line ~ /\\[ \t]*$/) {
            sub(/\\[ \t]*$/, "", line)
            if ((getline cont) > 0) {
                sub(/^[ \t]+/, "", cont)
                line = line " " cont
            } else {
                break
            }
        }
        print line
    }'
}

# Split a logical line into individual command invocations at shell
# separators. `||` before `|` so the two-char operator isn't halved.
split_invocations() {
    sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g'
}

# Compile-invocation recognition rule (see header): compiler command word,
# and it compiles (names a .c, or carries -c over a $var in a loop body).
is_compile_invocation() {
    printf '%s\n' "$1" | grep -qE '(^|[[:space:]])(gcc|clang|cc)([[:space:]]|$)' || return 1
    printf '%s\n' "$1" | grep -qE '\.c\b' && return 0
    printf '%s\n' "$1" | grep -qE '(^|[[:space:]])-c([[:space:]]|$)'
}

# Whole-argument flag match: `-Werror=switch-enum` must not satisfy this.
carries_flag() {
    printf '%s\n' "$1" | grep -qE "(^|[[:space:]])$FLAG([[:space:]]|$)"
}

# Read a (continuation-joined) dry-run stream on stdin; split every logical
# line into invocations; print and count every compile invocation missing
# the flag. $1 = label used in violation output.
audit_stream() {
    local label="$1" line seg
    while IFS= read -r line; do
        while IFS= read -r seg; do
            # trim surrounding whitespace; skip empty segments
            seg="${seg#"${seg%%[![:space:]]*}"}"
            seg="${seg%"${seg##*[![:space:]]}"}"
            [ -z "$seg" ] && continue
            is_compile_invocation "$seg" || continue
            EXAMINED=$((EXAMINED + 1))
            TARGET_EXAMINED=$((TARGET_EXAMINED + 1))
            if ! carries_flag "$seg"; then
                VIOLATIONS=$((VIOLATIONS + 1))
                echo "MISSING $FLAG [$label]:"
                printf '%s\n' "$seg" | sed 's/^/    /'
            fi
        done < <(split_invocations <<< "$line")
    done
}

# Audit one target's joined dry-run stream (stdin). A target that emits no
# compile invocations at all is a hard failure NAMING the target — never a
# silent pass.
audit_target() {
    local label="$1"
    TARGET_EXAMINED=0
    audit_stream "$label"
    if [ "$TARGET_EXAMINED" -eq 0 ]; then
        echo "GATE ERROR: target '$label' emitted no compile invocations in its dry run —"
        echo "nothing there to assert the invariant against; refusing to pass silently."
        return 1
    fi
    return 0
}

# Marker and wrapper names used to attribute one multi-goal make dry run back
# to the individual targets. The wrapper recipe is printed by `make -n` after
# its prerequisite target has emitted all of its recipes, so each marker closes
# exactly one target segment without executing anything.
BATCH_MARKER='__WERROR_TARGET_END__'
BATCH_PREFIX='__werror_audit_'

# Emit an extra makefile on stdout. It adds one phony wrapper per real target;
# each wrapper depends on that target and prints an end marker as its recipe.
# The caller feeds this stream to `make -f -`, keeping the dry run to one make
# parser/spawn while preserving a deterministic target order.
emit_batch_makefile() {
    local target_list="$1" t
    printf '.PHONY:'
    for t in $target_list; do
        printf ' %s%s' "$BATCH_PREFIX" "$t"
    done
    printf '\n'
    for t in $target_list; do
        printf '%s%s: %s\n' "$BATCH_PREFIX" "$t" "$t"
        printf '\t@echo %s%s\n' "$BATCH_MARKER" "$t"
    done
}

# Audit a marker-delimited, continuation-joined stream produced by the
# wrapper goals above. The segment is handed to audit_target before advancing
# to the next marker, so EXAMINED/VIOLATIONS remain global while
# TARGET_EXAMINED and the zero-emission assertion remain per target.
audit_batch() {
    local target_list="$1" line marker_target segment_file
    local target_index=0 batch_failed=0
    local -a batch_targets=()
    read -r -a batch_targets <<< "$target_list"
    segment_file=$(mktemp /tmp/werror_switch_batch_XXXX)
    : > "$segment_file"

    while IFS= read -r line; do
        if [[ "$line" =~ ^echo[[:space:]]+${BATCH_MARKER}([[:alnum:]_-]+)$ ]]; then
            marker_target="${BASH_REMATCH[1]}"
            if [ "$target_index" -ge "${#batch_targets[@]}" ]; then
                echo "GATE ERROR: batched dry run emitted an unexpected target marker '$marker_target'"
                batch_failed=1
                continue
            fi
            if [ "$marker_target" != "${batch_targets[$target_index]}" ]; then
                echo "GATE ERROR: batched dry run marker '$marker_target' arrived while auditing target '${batch_targets[$target_index]}'"
                batch_failed=1
            fi
            if ! audit_target "${batch_targets[$target_index]}" < "$segment_file"; then
                batch_failed=1
            else
                TARGETS_AUDITED=$((TARGETS_AUDITED + 1))
            fi
            : > "$segment_file"
            target_index=$((target_index + 1))
        else
            printf '%s\n' "$line" >> "$segment_file"
        fi
    done

    if [ "$target_index" -lt "${#batch_targets[@]}" ]; then
        echo "GATE ERROR: batched dry run ended before target '${batch_targets[$target_index]}' marker — cannot audit it"
        batch_failed=1
    elif [ -s "$segment_file" ]; then
        echo "GATE ERROR: batched dry run emitted un-attributed lines after its final target marker"
        batch_failed=1
    fi

    rm -f "$segment_file"
    return "$batch_failed"
}

# Global backstop: hard fail when the total examined count says the matcher
# saw nothing real.
require_minimum() {  # $1 = count
    if [ "$1" -lt "$MIN_LINES" ]; then
        echo "GATE ERROR: only $1 compile invocation(s) examined (floor $MIN_LINES) —"
        echo "the matcher matched nothing real; this gate would pass forever."
        return 1
    fi
    return 0
}

# --- selftest: every planted fault shape must be caught, every clean shape
# --- must pass, and the empty-audit assertions must bite. In-memory
# --- streams only; the tree is never mutated.
if [ "${1:-}" = "--selftest" ]; then
    st_fail=0
    # audit_stream must run in THIS shell or its EXAMINED/VIOLATIONS
    # increments die in the command-substitution subshell — capture its
    # stdout via a temp file instead of $(...). Streams go through
    # join_continuations first, exactly like the main path.
    st_out=$(mktemp /tmp/werror_switch_selftest_out_XXXX)
    st_joined=$(mktemp /tmp/werror_switch_selftest_joined_XXXX)
    trap 'rm -f "$st_out" "$st_joined"' EXIT

    # TARGET_BATCHES must cover TARGETS exactly.  Omitting a target is a hard
    # failure naming the missing target, rather than a silently smaller gate.
    if validate_target_batches "build jit-smoke" "build" > "$st_out" 2>&1; then
        echo "SELFTEST FAILED: divergent target batches were accepted"
        st_fail=1
    elif ! grep -qF 'jit-smoke' "$st_out"; then
        echo "SELFTEST FAILED: divergent target-batch failure did not name 'jit-smoke'"
        sed 's/^/    /' "$st_out"
        st_fail=1
    fi

    # expect_clean <name>: stream on stdin must yield 0 violations.
    expect_clean() {
        local name="$1" out
        EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
        join_continuations > "$st_joined"
        audit_stream "selftest:$name" > "$st_out" < "$st_joined"
        out=$(cat "$st_out")
        if [ "$VIOLATIONS" -ne 0 ]; then
            echo "SELFTEST FAILED: $name — expected clean, got $VIOLATIONS violation(s)"
            printf '%s\n' "$out" | sed 's/^/    /'
            st_fail=1
        fi
    }

    # expect_caught <name> <needle>: stream on stdin must yield exactly 1
    # violation, and the violation output must name <needle>.
    expect_caught() {
        local name="$1" needle="$2" out
        EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
        join_continuations > "$st_joined"
        audit_stream "selftest:$name" > "$st_out" < "$st_joined"
        out=$(cat "$st_out")
        if [ "$VIOLATIONS" -ne 1 ]; then
            echo "SELFTEST FAILED: $name — expected 1 violation, got $VIOLATIONS"
            st_fail=1
        elif ! printf '%s\n' "$out" | grep -qF -e "$needle"; then
            echo "SELFTEST FAILED: $name — violation output does not name '$needle'"
            printf '%s\n' "$out" | sed 's/^/    /'
            st_fail=1
        fi
    }

    # Mechanism 1: the variant engine's -c lines (#740).
    expect_caught "variant -c line, flag dropped" "src/vm.c" <<'EOF'
gcc -Wall -Wextra -O2 -MMD -MP -c src/vm.c -o build/asan/vm.o
EOF
    expect_clean "variant -c line, flag present" <<'EOF'
gcc -Wall -Wextra -Werror=switch -O2 -MMD -MP -c src/vm.c -o build/asan/vm.o
EOF

    # Mechanism 2: hand-written single-command compile+link (jit-smoke shape).
    expect_caught "single-command compile+link, flag dropped" "jit_smoke" <<'EOF'
gcc -Wall -Wextra -O2 -o /tmp/jit_smoke src/jit.c src/jit_smoke.c -lm
EOF

    # Mechanism 3a: shell for-loop over sources (lib shape — the gcc segment
    # names a .c via the basename call), continuations joined first.
    expect_caught "for-loop compile, flag dropped" "basename" <<'EOF'
for f in src/vm.c src/jit.c; do \
	gcc -Wall -Wextra -O2 \
		-c $f -o build/obj/$(basename $f .c).o || exit 1; \
done
EOF

    # Mechanism 3b: the coverage for-loop shape — the gcc segment names NO
    # .c at all; `-c` alone must still recognize it as a compile.
    expect_caught "coverage for-loop (no .c in the gcc segment), flag dropped" "--coverage" <<'EOF'
for src in src/vm.c src/jit.c; do \
	obj=${src%.c}.o; \
	gcc -O0 -g --coverage -Wall -Wextra -c $src -o $obj \
		-DEIGENSCRIPT_EXT_HTTP=0 || exit 1; \
done
EOF

    # clang legs (fuzz-libfuzzer shape): caught when bare, clean when armed.
    expect_caught "clang compile+link, flag dropped" "fuzz_eigenscript" <<'EOF'
clang -g -O1 -fsanitize=fuzzer,address,undefined -o fuzz/fuzz_eigenscript fuzz/fuzz_eigenscript.c src/vm.c -lm
EOF
    expect_clean "clang compile+link, flag present" <<'EOF'
clang -g -O1 -fsanitize=fuzzer,address,undefined -Werror=switch -o fuzz/fuzz_eigenscript fuzz/fuzz_eigenscript.c src/vm.c -lm
EOF

    # TWO compiler invocations in ONE continuation block: the first
    # invocation's flag must not satisfy the check for the second. Each
    # invocation is its own examined unit (examined=2, violations=1), and
    # the violation names the unguarded invocation's source.
    EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
    join_continuations > "$st_joined" <<'EOF'
gcc -Werror=switch -c src/vm.c -o build/vm.o; \
gcc -c src/jit.c -o build/jit.o
EOF
    audit_stream "selftest:two-invocations-one-block" > "$st_out" < "$st_joined"
    out=$(cat "$st_out")
    if [ "$EXAMINED" -ne 2 ] || [ "$VIOLATIONS" -ne 1 ] \
       || ! printf '%s\n' "$out" | grep -qF 'src/jit.c'; then
        echo "SELFTEST FAILED: two invocations one block — expected examined=2 violations=1 naming src/jit.c, got examined=$EXAMINED violations=$VIOLATIONS"
        printf '%s\n' "$out" | sed 's/^/    /'
        st_fail=1
    fi

    # The batched path must retain target attribution after one make stream is
    # split at its target-end markers: a fault in target B must be reported as
    # target B, not merely as an unarmed compiler line in the merged stream.
    EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
    join_continuations > "$st_joined" <<'EOF'
gcc -Werror=switch -c src/vm.c -o build/a.o
echo __WERROR_TARGET_END__selftest-target-a
gcc -c src/jit.c -o build/b.o
echo __WERROR_TARGET_END__selftest-target-b
EOF
    if ! audit_batch "selftest-target-a selftest-target-b" > "$st_out" < "$st_joined"; then
        echo "SELFTEST FAILED: merged-stream attribution audit failed to pass"
        st_fail=1
    else
        out=$(cat "$st_out")
        if [ "$EXAMINED" -ne 2 ] || [ "$VIOLATIONS" -ne 1 ] \
           || ! printf '%s\n' "$out" | grep -qF 'selftest-target-b' \
           || ! printf '%s\n' "$out" | grep -qF 'src/jit.c'; then
            echo "SELFTEST FAILED: merged-stream fault was not attributed to target B (examined=$EXAMINED violations=$VIOLATIONS)"
            printf '%s\n' "$out" | sed 's/^/    /'
            st_fail=1
        fi
    fi

    # The same marker path must also preserve the anti-vacuity guard: an empty
    # segment is a hard failure naming the target that emitted no compiles.
    EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
    join_continuations > "$st_joined" <<'EOF'
echo __WERROR_TARGET_END__selftest-batched-zero
gcc -Werror=switch -c src/vm.c -o build/nonzero.o
echo __WERROR_TARGET_END__selftest-batched-nonzero
EOF
    if audit_batch "selftest-batched-zero selftest-batched-nonzero" > "$st_out" < "$st_joined"; then
        echo "SELFTEST FAILED: batched zero-compile target did not fail"
        st_fail=1
    elif ! grep -qF 'selftest-batched-zero' "$st_out"; then
        echo "SELFTEST FAILED: batched zero-compile failure did not name its target"
        sed 's/^/    /' "$st_out"
        st_fail=1
    fi

    # Script-audit shapes (#835): a compile line inside a shell script is
    # classified exactly like a dry-run line once comments are stripped.
    expect_caught "script compile line, flag dropped" 'src/$f.c' <<'EOF'
gcc -O2 -ffreestanding -fno-stack-protector -U_FORTIFY_SOURCE -Werror=implicit-function-declaration -c "src/$f.c" -o "$BUILD/$f.o"
EOF
    expect_clean "script compile line, flag present" <<'EOF'
gcc -O2 -ffreestanding -Werror=implicit-function-declaration -Werror=switch -c "src/$f.c" -o "$BUILD/$f.o"
EOF

    # A comment quoting a bare compile must not be examined at all.
    EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
    strip_comments <<'EOF' | join_continuations > "$st_joined"
# gcc -O2 -c src/vm.c -o vm.o   (quoted in a comment; not a compile)
    # indented comment: gcc -c src/jit.c
echo hello
EOF
    audit_stream "selftest:script-comment" < "$st_joined"
    if [ "$EXAMINED" -ne 0 ] || [ "$VIOLATIONS" -ne 0 ]; then
        echo "SELFTEST FAILED: commented compile lines were examined ($EXAMINED/$VIOLATIONS)"
        st_fail=1
    fi

    # `-Werror=switch-enum` is a DIFFERENT warning: it must not satisfy the
    # check, and the real flag alongside it must.
    expect_caught "switch-enum is not switch" "src/vm.c" <<'EOF'
gcc -Wall -Wextra -Werror=switch-enum -O2 -c src/vm.c -o build/vm.o
EOF
    expect_clean "real flag alongside switch-enum" <<'EOF'
gcc -Wall -Wextra -Werror=switch-enum -Werror=switch -O2 -c src/vm.c -o build/vm.o
EOF

    # Non-compile lines must be IGNORED: a pure link (coverage link shape,
    # .o files only), mkdir/echo/ln, and a bash-script recipe. None of these
    # may be examined, let alone flagged.
    EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
    join_continuations > "$st_joined" <<'EOF'
gcc --coverage -o src/eigenscript src/eigenscript.o src/vm.o -pie -Wl,-z,relro,-z,now -lm -lpthread
mkdir -p build/release
ln -f build/release/eigenscript src/eigenscript
echo "EigenScript 0.35.2 built"
bash tools/amalgamate.sh build
EOF
    audit_stream "selftest:non-compile" < "$st_joined"
    if [ "$EXAMINED" -ne 0 ] || [ "$VIOLATIONS" -ne 0 ]; then
        echo "SELFTEST FAILED: non-compile lines — expected 0 examined / 0 violations, got $EXAMINED/$VIOLATIONS"
        st_fail=1
    fi

    # A target whose dry run emits ZERO compile invocations is a hard
    # failure naming that target.
    EXAMINED=0; VIOLATIONS=0
    join_continuations > "$st_joined" <<'EOF'
mkdir -p build/release
echo "nothing compiled here"
EOF
    if audit_target "selftest-zero-target" > "$st_out" < "$st_joined"; then
        echo "SELFTEST FAILED: zero-compile-line target did not fail"
        st_fail=1
    elif ! grep -qF "selftest-zero-target" "$st_out"; then
        echo "SELFTEST FAILED: zero-compile-line failure did not name its target"
        sed 's/^/    /' "$st_out"
        st_fail=1
    fi

    # The global floor must bite: an empty audit is a hard failure, never a
    # pass.
    if require_minimum 0 >/dev/null 2>&1; then
        echo "SELFTEST FAILED: zero examined lines did not trip the floor"
        st_fail=1
    fi
    if ! require_minimum "$MIN_LINES" >/dev/null 2>&1; then
        echo "SELFTEST FAILED: at-floor count was rejected"
        st_fail=1
    fi

    if [ "$st_fail" -ne 0 ]; then
        exit 1
    fi
    echo "SELFTEST OK: all planted fault shapes caught (incl. target-batch divergence, two-invocation blocks, switch-enum, zero-line targets), clean shapes pass, floors bite"
    exit 0
fi

# Validate the target partition before any dry run so a hand-edited batch
# cannot silently reduce the gate's coverage.
validate_target_batches "$TARGETS" "${TARGET_BATCHES[@]}" || exit 1

# --- main: dry-run every compiling target and audit what it WOULD run ---
make_failed=0
empty_failed=0
for target_list in "${TARGET_BATCHES[@]}"; do
    batch_goals=()
    for t in $target_list; do
        batch_goals+=("$BATCH_PREFIX$t")
    done
    if ! dry=$(set -o pipefail; emit_batch_makefile "$target_list" | make -n -B -f Makefile -f - "${batch_goals[@]}" 2>&1); then
        echo "GATE ERROR: 'make -n -B $target_list' exited nonzero — cannot audit the target batch"
        make_failed=1
        continue
    fi
    joined=$(printf '%s\n' "$dry" | join_continuations)
    audit_batch "$target_list" <<< "$joined" || empty_failed=1
done

# Compile-bearing scripts (#835): same classifier, same zero-line
# assertion, comment lines stripped first.
for s in $SCRIPT_AUDITS; do
    if [ ! -f "$s" ]; then
        echo "GATE ERROR: script '$s' not found — cannot audit it"
        make_failed=1
        continue
    fi
    audit_target "script:$s" <<< "$(strip_comments < "$s" | join_continuations)" || empty_failed=1
done

if [ "$make_failed" -ne 0 ] || [ "$empty_failed" -ne 0 ]; then
    exit 1
fi
require_minimum "$EXAMINED" || exit 1
if [ "$VIOLATIONS" -gt 0 ]; then
    echo "werror-switch gate FAILED: $VIOLATIONS of $EXAMINED compile invocations lack $FLAG"
    exit 1
fi
echo "werror-switch gate OK: all $EXAMINED compile invocations across $TARGETS_AUDITED dry-run targets + $(echo $SCRIPT_AUDITS | wc -w | tr -d ' ') script(s) carry $FLAG"
exit 0
