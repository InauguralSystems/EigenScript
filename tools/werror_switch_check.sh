#!/bin/bash
# Uniform -Werror=switch gate (the #817 follow-up from PR #817 discussion).
#
# #738 made every ASTType/ValType/opcode switch exhaustive so the flag has
# teeth; #786/#817 then put `-Werror=switch` on every compile line in the
# tree (the last six hand-written flag lists were FLAGS_poison, jit-smoke,
# coverage, fuzz, fuzz-libfuzzer, freestanding-libc-diff). This gate keeps
# that invariant holding: it dry-runs every Makefile target that compiles C
# (`make -n -B`) and asserts the UNIFORM invariant — every emitted compile
# line carries the flag. Uniform, not variants-vs-auxiliary: a gate that
# classifies targets into "real" and "auxiliary" legs encodes a judgement
# that would need re-litigating at every audit; asserting the flag on every
# compile line is simpler and cannot be argued out of a leg.
#
# What counts as a compile line (the recognition rule):
#   a dry-run recipe line that invokes a C compiler — gcc, clang, or cc as a
#   command word (start of line or after whitespace/;/|/&) — AND names at
#   least one .c source file. Backslash-continued recipes are joined first,
#   so multi-line invocations (lsp, fuzz-libfuzzer, the `lib`/`coverage`
#   for-loops) are classified as one logical line.
#   This covers both compile mechanisms in the Makefile: the per-variant
#   objdir engine's `-c` lines (#740) and the hand-written single-command
#   compile+link legs. Pure link lines (coverage's `gcc --coverage -o ...`
#   over .o files) name no .c, compile nothing, and are excluded by
#   definition — the flag is a compile-time option.
#
# Blind spots, stated honestly: compiles hidden INSIDE shell scripts
# (tools/freestanding_check.sh, build.sh) are invisible to `make -n` and out
# of scope here; build.sh's three lines are armed and verified by #786.
#
# A gate that silently matches nothing is worse than no gate — it passes
# forever. So the gate prints how many compile lines it examined and hard-
# fails below a sanity floor (100): the 11 VARIANTS alone emit >200 `-c`
# lines on a `-B` dry run, so a count under the floor means the matcher
# broke, not that the Makefile is clean.
#
# Usage: tools/werror_switch_check.sh [--selftest]
#   --selftest : feed synthetic dry-run streams (each fault shape planted
#                in-memory, no tree mutation) through the classifier and
#                confirm every one is classified correctly — proves the
#                checker isn't vacuously green.
# Exit 0 = every emitted compile line carries the flag; 1 = a violation, a
# make error, an under-floor count, or a selftest failure.

set -u
cd "$(dirname "$0")/.." || exit 1

FLAG='-Werror=switch'
# Sanity floor, not a spec: VARIANTS (release full http zlib net gfx asan
# asan-http tsan valgrind poison) emit >= 19 `-c` lines each under -B.
MIN_LINES=100

# Every Makefile target whose dry run emits compile lines. Excluded:
# amalgamation/freestanding-check (recipes are `bash tools/...`, the compiles
# live inside those scripts), install* (cp; the lsp/dap compiles are covered
# by their own targets), test/clean/version/print-%/coverage-clean/fuzz-run
# (no compiles).
TARGETS="build full http zlib net gfx asan asan-http tsan valgrind poison \
         lsp dap jit-smoke lib embed-smoke embed-smoke-gfx pgo coverage \
         fuzz fuzz-libfuzzer freestanding-libc-diff"

EXAMINED=0
VIOLATIONS=0

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

# Compile-line recognition rule (see header). Command word gcc/clang/cc,
# at least one .c named.
is_compile_line() {
    printf '%s\n' "$1" | grep -qE '(^|[[:space:];|&])(gcc|clang|cc)([[:space:]]|$)' \
        && printf '%s\n' "$1" | grep -qE '\.c\b'
}

# Read a (continuation-joined) dry-run stream on stdin; print and count every
# compile line missing the flag. $1 = label used in violation output.
audit_stream() {
    local label="$1" line
    while IFS= read -r line; do
        if is_compile_line "$line"; then
            EXAMINED=$((EXAMINED + 1))
            case "$line" in
                *"$FLAG"*) ;;
                *)
                    VIOLATIONS=$((VIOLATIONS + 1))
                    echo "MISSING $FLAG [$label]:"
                    printf '%s\n' "$line" | sed 's/^/    /'
                    ;;
            esac
        fi
    done
}

# Hard fail when the examined count says the matcher saw nothing real.
require_minimum() {  # $1 = count
    if [ "$1" -lt "$MIN_LINES" ]; then
        echo "GATE ERROR: only $1 compile line(s) examined (floor $MIN_LINES) —"
        echo "the matcher matched nothing real; this gate would pass forever."
        return 1
    fi
    return 0
}

# --- selftest: every planted fault shape must be caught, every clean shape
# --- must pass, and the zero-count floor must bite. In-memory streams only;
# --- the tree is never mutated.
if [ "${1:-}" = "--selftest" ]; then
    st_fail=0
    # audit_stream must run in THIS shell or its EXAMINED/VIOLATIONS
    # increments die in the command-substitution subshell — capture its
    # stdout via a temp file instead of $(...). Streams go through
    # join_continuations first, exactly like the main path.
    st_out=$(mktemp /tmp/werror_switch_selftest_out_XXXX)
    st_joined=$(mktemp /tmp/werror_switch_selftest_joined_XXXX)
    trap 'rm -f "$st_out" "$st_joined"' EXIT

    # expect_clean <name>: stream on stdin must yield 0 violations.
    expect_clean() {
        local name="$1" out
        EXAMINED=0; VIOLATIONS=0
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
        EXAMINED=0; VIOLATIONS=0
        join_continuations > "$st_joined"
        audit_stream "selftest:$name" > "$st_out" < "$st_joined"
        out=$(cat "$st_out")
        if [ "$VIOLATIONS" -ne 1 ]; then
            echo "SELFTEST FAILED: $name — expected 1 violation, got $VIOLATIONS"
            st_fail=1
        elif ! printf '%s\n' "$out" | grep -qF "$needle"; then
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

    # Mechanism 3: shell for-loop over sources (lib/coverage shape), and its
    # backslash-continuation is joined before classification.
    expect_caught "for-loop compile, flag dropped" "basename" <<'EOF'
for f in src/vm.c src/jit.c; do \
	gcc -Wall -Wextra -O2 \
		-c $f -o build/obj/$(basename $f .c).o || exit 1; \
done
EOF

    # clang legs (fuzz-libfuzzer shape): caught when bare, clean when armed.
    expect_caught "clang compile+link, flag dropped" "fuzz_eigenscript" <<'EOF'
clang -g -O1 -fsanitize=fuzzer,address,undefined -o fuzz/fuzz_eigenscript fuzz/fuzz_eigenscript.c src/vm.c -lm
EOF
    expect_clean "clang compile+link, flag present" <<'EOF'
clang -g -O1 -fsanitize=fuzzer,address,undefined -Werror=switch -o fuzz/fuzz_eigenscript fuzz/fuzz_eigenscript.c src/vm.c -lm
EOF

    # Non-compile lines must be IGNORED: a pure link (coverage link shape,
    # .o files only), mkdir/echo/ln, and a bash-script recipe. None of these
    # may be examined, let alone flagged.
    EXAMINED=0; VIOLATIONS=0
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

    # The floor must bite: an empty audit is a hard failure, never a pass.
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
    echo "SELFTEST OK: all planted fault shapes caught, clean shapes pass, zero-count floor bites"
    exit 0
fi

# --- main: dry-run every compiling target and audit what it WOULD run ---
make_failed=0
for t in $TARGETS; do
    if ! dry=$(make -n -B "$t" 2>&1); then
        echo "GATE ERROR: 'make -n -B $t' exited nonzero — cannot audit $t"
        make_failed=1
        continue
    fi
    audit_stream "$t" <<< "$(printf '%s\n' "$dry" | join_continuations)"
done

if [ "$make_failed" -ne 0 ]; then
    exit 1
fi
require_minimum "$EXAMINED" || exit 1
if [ "$VIOLATIONS" -gt 0 ]; then
    echo "werror-switch gate FAILED: $VIOLATIONS of $EXAMINED compile lines lack $FLAG"
    exit 1
fi
echo "werror-switch gate OK: all $EXAMINED compile lines across $(echo $TARGETS | wc -w | tr -d ' ') dry-run targets carry $FLAG"
exit 0
