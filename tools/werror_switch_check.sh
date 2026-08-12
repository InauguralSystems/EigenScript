#!/bin/bash
# Uniform warning-error gate (the #817 follow-up from PR #817 discussion).
#
# #738 made every ASTType/ValType/opcode switch exhaustive so the flag has
# teeth; #786/#817 then put `-Werror=switch` on every compile line in the
# tree. #826 adds `-Werror=comment`: a warning in the public header reaches
# every translation unit, so treating the class as an error keeps future
# header comments from training contributors to ignore build output. This
# gate keeps both invariants holding: it dry-runs every Makefile target that
# compiles C (`make -n -B`) and asserts the UNIFORM invariant — every emitted
# compile invocation carries every required warning-error flag. Uniform, not
# variants-vs-auxiliary: a gate that classifies targets into "real" and
# "auxiliary" legs encodes a judgement that would need re-litigating at every
# audit; asserting the flags on every compile invocation is simpler and cannot
# be argued out of a leg.
#
# What counts as a compile invocation (the recognition rule):
#   dry-run recipes are joined at backslash continuations, then SPLIT into
#   individual invocations at shell separators (; && || |) — one logical
#   recipe line can hold several compiler calls, and each call must carry
#   the flag on its own: a test over the merged text would let the first
#   invocation's flag cover an unguarded second one. Each invocation with
#   a compiler command word (gcc/clang/cc/emcc/$CC/${CC}, quoted or unquoted)
#   that COMPILES — it names a .c
#   source, or (for-loop bodies over a $var, like the coverage leg) it
#   carries -c — is one examined unit, counted and checked separately.
#   Pure link invocations (coverage's `gcc --coverage -o ...` over .o
#   files) name no .c and carry no -c: they compile nothing and are
#   excluded by definition — the flag is a compile-time option.
#   The flag is matched as a whole argument, never a substring:
#   `-Werror=switch-enum` is a different warning and must NOT satisfy
#   this gate. The same whole-argument rule applies to every required flag.
#
# Compiles hidden INSIDE shell scripts are invisible to `make -n`, so the
# scripts whose compile lines the classifier can recognize are audited
# DIRECTLY (#835): comment lines stripped, then the script text goes
# through the same join/split/classify pipeline as a dry-run stream, with
# the same per-script zero-line hard failure. The six compiler surfaces in
# the issue are all covered: build.sh's `$SOURCES`/`$LSP_SOURCES`, the two
# freestanding scripts, the stack soak, and web/build.sh's `${SOURCES[@]}`.
# The recognizer treats those source-list variables as compile evidence, so
# an audit cannot pass merely because a script hides its sources in a shell
# array. The final probes regenerate both LSP public index headers and
# pre-include each in the public-header translation unit, covering generated
# block comments compiled by the LSP path but absent from a fresh checkout.
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
# Exit 0 = every emitted compile invocation carries every required flag; 1 = a
# violation, a make error, a target emitting no compile lines, an
# under-floor count, or a selftest failure.

set -u
cd "$(dirname "$0")/.." || exit 1

REQUIRED_FLAGS='-Werror=switch -Werror=comment'
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

# Compile-bearing shell scripts audited directly (#835) — see header.
SCRIPT_AUDITS="build.sh tools/freestanding_check.sh tools/freestanding_smoke.sh tools/embed_stack_soak.sh web/build.sh"

# Comment lines must not be examined: a script comment QUOTING a bare
# compile line is not a compile.
strip_comments() {
    grep -vE '^[[:space:]]*#'
}

EXAMINED=0          # compile invocations examined, all targets
VIOLATIONS=0        # examined invocations missing one or more required flags
TARGET_EXAMINED=0   # examined within the current target (reset per target)

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
    printf '%s\n' "$1" | grep -qE '(^|[[:space:]])(gcc|clang|cc|emcc|"?\$\{?CC\}?"?)([[:space:]]|$)' || return 1
    printf '%s\n' "$1" | grep -qE '\.c\b' && return 0
    printf '%s\n' "$1" | grep -qE '(^|[[:space:]])-c([[:space:]]|$)' && return 0
    printf '%s\n' "$1" | grep -qE '(\$SOURCES|\$LSP_SOURCES|\$\{SOURCES\[@\]\})'
}

# Whole-argument flag match: `-Werror=switch-enum` must not satisfy this.
carries_flag() {
    local line="$1" flag="$2"
    printf '%s\n' "$line" | grep -qE "(^|[[:space:]])$flag([[:space:]]|$)"
}

missing_flags() {
    local line="$1" flag
    for flag in $REQUIRED_FLAGS; do
        carries_flag "$line" "$flag" || printf '%s\n' "$flag"
    done
}

# Read a (continuation-joined) dry-run stream on stdin; split every logical
# line into invocations; print and count every compile invocation missing
# one or more required flags. $1 = label used in violation output.
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
            missing=$(missing_flags "$seg")
            if [ -n "$missing" ]; then
                VIOLATIONS=$((VIOLATIONS + 1))
                echo "MISSING required flag(s) [$label]:"
                printf '%s\n' "$missing" | sed 's/^/    /'
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
    st_scratch=$(mktemp -d /tmp/werror_switch_selftest_tree_XXXX)
    trap 'rm -f "$st_out" "$st_joined"; rm -rf -- "$st_scratch"' EXIT

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

    # Build a tracked-file scratch tree for integration mutations. The gate
    # itself is copied from the current worktree after archiving HEAD, so this
    # exercises the real main path without ever mutating the shipping clone.
    prepare_fault_tree() {
        local root="$1"
        mkdir -p "$root"
        # Actions may check the repository out as a different UID from the
        # container user.  Pass the path-scoped safe-directory override to
        # archive instead of mutating global git configuration.
        git -c safe.directory="$PWD" archive HEAD | tar -x -C "$root"
        cp tools/werror_switch_check.sh "$root/tools/werror_switch_check.sh"
        cp build.sh "$root/build.sh"
        cp tools/gen_lsp_builtin_index.sh "$root/tools/gen_lsp_builtin_index.sh"
    }

    # Generated-header family: a fault in the builtin generator must make the
    # gate fail, just like the public-header control fault does. This is an
    # integration assertion, not a direct compiler-only probe: it catches a
    # missing generated-header consumer in the gate itself.
    st_builtin_tree="$st_scratch/builtin"
    prepare_fault_tree "$st_builtin_tree"
    sed 's|ext_names.h; hover text|lib/*.eigs; hover text|' \
        "$st_builtin_tree/tools/gen_lsp_builtin_index.sh" \
        > "$st_builtin_tree/tools/gen_lsp_builtin_index.sh.planted"
    mv "$st_builtin_tree/tools/gen_lsp_builtin_index.sh.planted" \
        "$st_builtin_tree/tools/gen_lsp_builtin_index.sh"
    if ! grep -qF 'Names come from the registration seams + lib/*.eigs; hover text' \
        "$st_builtin_tree/tools/gen_lsp_builtin_index.sh"; then
        echo "SELFTEST FAILED: builtin-generator mutation was not planted"
        st_fail=1
    elif bash "$st_builtin_tree/tools/werror_switch_check.sh" > "$st_out" 2>&1; then
        echo "SELFTEST FAILED: builtin-generated nested comment was accepted"
        sed 's/^/    /' "$st_out"
        st_fail=1
    elif ! grep -qF 'lsp_builtin_index' "$st_out"; then
        echo "SELFTEST FAILED: builtin-generated rejection did not identify the generated header"
        sed 's/^/    /' "$st_out"
        st_fail=1
    fi

    # Compiler-variable spelling: retain the other bare $CC calls so the
    # script audit has a nonzero count, then hide one real compile behind the
    # ordinary quoted/braced spelling and remove only its comment flag.
    st_parser_tree="$st_scratch/parser"
    prepare_fault_tree "$st_parser_tree"
    sed 's|^    \$CC -Wall -Wextra -Werror=implicit-function-declaration -Werror=switch -Werror=comment|    "${CC}" -Wall -Wextra -Werror=implicit-function-declaration -Werror=switch|' \
        "$st_parser_tree/build.sh" > "$st_parser_tree/build.sh.planted"
    mv "$st_parser_tree/build.sh.planted" "$st_parser_tree/build.sh"
    if ! grep -qF '"${CC}" -Wall -Wextra -Werror=implicit-function-declaration -Werror=switch -O2' \
        "$st_parser_tree/build.sh"; then
        echo "SELFTEST FAILED: quoted/braced compiler mutation was not planted"
        st_fail=1
    elif bash "$st_parser_tree/tools/werror_switch_check.sh" > "$st_out" 2>&1; then
        echo "SELFTEST FAILED: quoted/braced compiler invocation was accepted"
        sed 's/^/    /' "$st_out"
        st_fail=1
    elif ! grep -qF '"${CC}"' "$st_out"; then
        echo "SELFTEST FAILED: quoted/braced rejection did not identify the compiler invocation"
        sed 's/^/    /' "$st_out"
        st_fail=1
    fi

    # Mechanism 1: the variant engine's -c lines (#740).
    expect_caught "variant -c line, flag dropped" "src/vm.c" <<'EOF'
gcc -Wall -Wextra -O2 -MMD -MP -c src/vm.c -o build/asan/vm.o
EOF
    expect_clean "variant -c line, flag present" <<'EOF'
gcc -Wall -Wextra -Werror=switch -Werror=comment -O2 -MMD -MP -c src/vm.c -o build/asan/vm.o
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
clang -g -O1 -fsanitize=fuzzer,address,undefined -Werror=switch -Werror=comment -o fuzz/fuzz_eigenscript fuzz/fuzz_eigenscript.c src/vm.c -lm
EOF

    # TWO compiler invocations in ONE continuation block: the first
    # invocation's flag must not satisfy the check for the second. Each
    # invocation is its own examined unit (examined=2, violations=1), and
    # the violation names the unguarded invocation's source.
    EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
    join_continuations > "$st_joined" <<'EOF'
    gcc -Werror=switch -Werror=comment -c src/vm.c -o build/vm.o; \
    gcc -Werror=switch -c src/jit.c -o build/jit.o
EOF
    audit_stream "selftest:two-invocations-one-block" > "$st_out" < "$st_joined"
    out=$(cat "$st_out")
    if [ "$EXAMINED" -ne 2 ] || [ "$VIOLATIONS" -ne 1 ] \
       || ! printf '%s\n' "$out" | grep -qF 'src/jit.c'; then
        echo "SELFTEST FAILED: two invocations one block — expected examined=2 violations=1 naming src/jit.c, got examined=$EXAMINED violations=$VIOLATIONS"
        printf '%s\n' "$out" | sed 's/^/    /'
        st_fail=1
    fi

    # Script-audit shapes (#835): a compile line inside a shell script is
    # classified exactly like a dry-run line once comments are stripped.
    expect_caught "script compile line, flag dropped" 'src/$f.c' <<'EOF'
gcc -O2 -ffreestanding -fno-stack-protector -U_FORTIFY_SOURCE -Werror=implicit-function-declaration -c "src/$f.c" -o "$BUILD/$f.o"
EOF
    expect_clean "script compile line, flag present" <<'EOF'
gcc -O2 -ffreestanding -Werror=implicit-function-declaration -Werror=switch -Werror=comment -c "src/$f.c" -o "$BUILD/$f.o"
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
gcc -Wall -Wextra -Werror=switch-enum -Werror=switch -Werror=comment -O2 -c src/vm.c -o build/vm.o
EOF

    # The two required warning classes are independent: a line carrying
    # switch but not comment is still a violation, and vice versa.
    expect_caught "comment flag missing" "-Werror=comment" <<'EOF'
gcc -Wall -Wextra -Werror=switch -O2 -c src/vm.c -o build/vm.o
EOF
    expect_caught "switch flag missing" "-Werror=switch" <<'EOF'
gcc -Wall -Wextra -Werror=comment -O2 -c src/vm.c -o build/vm.o
EOF

    # Source-list variables and emcc are compile-bearing script shapes too.
    expect_caught "shell source-list variable, flag dropped" "SOURCES" <<'EOF'
$CC -Wall -Wextra -Werror=switch -O2 -o eigenscript $SOURCES
EOF
    expect_clean "shell source-list variable, flags present" <<'EOF'
$CC -Wall -Wextra -Werror=switch -Werror=comment -O2 -o eigenscript $SOURCES
EOF
    expect_caught "quoted compiler variable, flag dropped" '"$CC"' <<'EOF'
"$CC" -Wall -Wextra -Werror=switch -O2 -c src/vm.c -o build/vm.o
EOF
    expect_clean "quoted compiler variable, flags present" <<'EOF'
"$CC" -Wall -Wextra -Werror=switch -Werror=comment -O2 -c src/vm.c -o build/vm.o
EOF
    expect_caught "braced compiler variable, flag dropped" '"${CC}"' <<'EOF'
"${CC}" -Wall -Wextra -Werror=switch -O2 -c src/vm.c -o build/vm.o
EOF
    expect_clean "braced compiler variable, flags present" <<'EOF'
"${CC}" -Wall -Wextra -Werror=switch -Werror=comment -O2 -c src/vm.c -o build/vm.o
EOF
    expect_caught "emcc source-list array, flag dropped" "SOURCES" <<'EOF'
emcc -O2 "${SOURCES[@]}" -o web/dist/eigs.js
EOF
    expect_clean "emcc source-list array, flag present" <<'EOF'
emcc -Werror=switch -Werror=comment -O2 "${SOURCES[@]}" -o web/dist/eigs.js
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
    echo "SELFTEST OK: all planted fault shapes caught (incl. two-invocation blocks, switch-enum, zero-line targets), clean shapes pass, floors bite"
    exit 0
fi

# --- main: dry-run every compiling target and audit what it WOULD run ---
make_failed=0
empty_failed=0
for t in $TARGETS; do
    if ! dry=$(make -n -B "$t" 2>&1); then
        echo "GATE ERROR: 'make -n -B $t' exited nonzero — cannot audit $t"
        make_failed=1
        continue
    fi
    audit_target "$t" <<< "$(printf '%s\n' "$dry" | join_continuations)" || empty_failed=1
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
    echo "werror warning gate FAILED: $VIOLATIONS of $EXAMINED compile invocations lack one or more of: $REQUIRED_FLAGS"
    exit 1
fi

# The flag-coverage audit proves that every compile line is armed; these
# one-file probes prove the public header and both generated LSP indexes are
# clean under the newly required comment warning. Keeping the probes here
# makes a planted nested comment fail this same gate in a scratch copy,
# rather than letting a flag-presence-only audit pass vacuously.
CC_BIN="${CC:-gcc}"
probe_dir=$(mktemp -d /tmp/eigenscript_werror_headers_XXXXXX)
trap 'rm -rf -- "$probe_dir"' EXIT
probe_generated_header() {
    local generator="$1" output="$2" label="$3"
    if ! "$generator" "$output" >/dev/null; then
        echo "werror comment gate FAILED: could not regenerate $label LSP index"
        return 1
    fi
    if ! "$CC_BIN" -Werror=comment -fsyntax-only -include "$output" src/main.c; then
        echo "werror comment gate FAILED: generated $label LSP header emits -Wcomment"
        return 1
    fi
}
if ! probe_generated_header tools/gen_lsp_stdlib_index.sh \
    "$probe_dir/lsp_stdlib_index.h" stdlib; then
    exit 1
fi
if ! probe_generated_header tools/gen_lsp_builtin_index.sh \
    "$probe_dir/lsp_builtin_index.h" builtin; then
    exit 1
fi
echo "werror warning gate OK: all $EXAMINED compile invocations across $(echo $TARGETS | wc -w | tr -d ' ') dry-run targets + $(echo $SCRIPT_AUDITS | wc -w | tr -d ' ') script(s) carry: $REQUIRED_FLAGS"
exit 0
