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
# forever, and a gate that silently matches LESS is the same failure wearing
# a green badge. Three assertions prevent that. PER TARGET: a dry run
# yielding zero compile invocations is a hard failure naming the target —
# each of the 22 targets emits at least one today, and the one-line auxiliary
# legs (jit-smoke, fuzz, freestanding-libc-diff, ...) are exactly where
# #817's fixes live; a global total cannot see one of those die. GLOBALLY:
# an examined count under the floor (100) hard-fails as a matcher-broke
# signal (the 11 VARIANTS alone emit >200 `-c` invocations under -B). And
# PER-TARGET COVERAGE (#921): every target's examined count must meet a
# committed floor (TARGET_FLOORS), because the first two assertions only see
# TOTAL loss and global collapse — a target that loses most of its compile
# lines to a batch sibling sharing a prerequisite stays non-zero and keeps
# the global total plausible. The examined count is always printed.
#
# Usage: tools/werror_switch_check.sh [--selftest | --print-counts]
#   --selftest : feed synthetic dry-run streams (each fault shape planted
#                in-memory, no tree mutation) through the classifier and
#                confirm every one is classified correctly — proves the
#                checker isn't vacuously green.
#   --print-counts : run the real dry runs and print the per-target examined
#                counts in TARGET_FLOORS format, for pasting back after an
#                intentional coverage change.
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
SCRIPT_AUDITS="build.sh tools/freestanding_check.sh tools/freestanding_smoke.sh tools/embed_stack_soak.sh web/build.sh"

# Comment lines must not be examined: a script comment QUOTING a bare
# compile line is not a compile.
strip_comments() {
    grep -vE '^[[:space:]]*#'
}

EXAMINED=0          # compile invocations examined, all targets
VIOLATIONS=0        # examined invocations missing one or more required flags
TARGET_EXAMINED=0   # examined within the current target (reset per target)
TARGETS_AUDITED=0   # target segments with at least one compile invocation
TARGET_COUNTS=''    # "label count" lines, appended by audit_target

# Per-target compile-invocation FLOORS (#921). The per-target zero-emission
# assertion only fires on TOTAL loss and MIN_LINES only on global collapse, so
# PARTIAL loss was invisible: GNU make emits a shared prerequisite once per
# invocation, so a future target added to a batch alongside a sibling it shares
# a prerequisite with silently loses those compile lines — coverage could fall
# from 332 to 180 and the gate would still print OK. That is precisely the
# "a gate that silently matches less is worse than no gate" mode this script's
# own header warns about.
#
# FLOORS, not exact counts, and that choice is the whole maintenance story:
# adding a source file or a variant only ever RAISES these numbers, so routine
# growth needs no edit here. A floor is bumped only when coverage is
# intentionally removed. An untracked target is itself a hard failure, so a new
# compile-bearing target cannot join a batch without pinning its coverage.
#
# Regenerate after an intentional change with:  tools/werror_switch_check.sh --print-counts
# A floor of 1 is not a weak floor: `lsp`, `dap`, `lib`, `embed-smoke`,
# `coverage`, `fuzz`, `fuzz-libfuzzer` and `freestanding-libc-diff` each emit a
# single compile invocation that names a whole source LIST ($LSP_SOURCES,
# $SOURCES), so one line IS their full coverage. Verified against standalone
# `make -n -B <target>` runs when these were pinned: standalone and batched
# counts agree, so batching is not currently eating any target's lines.
TARGET_FLOORS='
build 25
full 31
http 29
zlib 25
net 26
gfx 26
asan 25
asan-http 30
tsan 25
valgrind 25
poison 25
lsp 1
dap 1
jit-smoke 1
lib 1
embed-smoke 1
embed-smoke-gfx 27
pgo 2
coverage 1
fuzz 1
fuzz-libfuzzer 1
freestanding-libc-diff 1
script:build.sh 3
script:tools/freestanding_check.sh 2
script:tools/freestanding_smoke.sh 1
script:tools/embed_stack_soak.sh 1
script:web/build.sh 1
'

# Floor for a label, or empty when the label is untracked.
target_floor() {  # $1 = label
    printf '%s\n' "$TARGET_FLOORS" | awk -v t="$1" '$1 == t { print $2; exit }'
}

# Assert every audited target met its pinned floor and none is untracked.
# Runs on the main path only; the selftest exercises it through planted
# TARGET_COUNTS streams instead, so synthetic labels need no floors.
enforce_target_floors() {
    local failed=0 label count floor
    while read -r label count; do
        [ -z "$label" ] && continue
        floor=$(target_floor "$label")
        if [ -z "$floor" ]; then
            echo "GATE ERROR: target '$label' has no entry in TARGET_FLOORS —"
            echo "an unpinned target can lose compile lines to a batch sibling silently."
            echo "Add its floor (tools/werror_switch_check.sh --print-counts)."
            failed=1
        elif [ "$count" -lt "$floor" ]; then
            echo "GATE ERROR: target '$label' examined $count compile invocation(s), below its"
            echo "pinned floor of $floor — this target's coverage SHRANK. The usual cause is a"
            echo "batch sibling that now shares a prerequisite with it, so make emitted those"
            echo "compile lines under the sibling instead. Give this goal its own TARGET_BATCHES"
            echo "entry, or bump the floor if the removal was intentional."
            failed=1
        fi
    done <<< "$TARGET_COUNTS"
    return "$failed"
}

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
    TARGET_COUNTS="${TARGET_COUNTS}${label} ${TARGET_EXAMINED}
"
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

# The one place the batched dry run is spawned. Both the main path and the
# nested-make selftest guard call THIS, so the guard cannot pass while the
# real invocation regresses.
#
# --no-print-directory is load-bearing, not cosmetic: `make test` runs this
# gate from a recipe, so the nested make sees MAKELEVEL>0 and brackets its
# output with `make[1]: Entering/Leaving directory`. The Leaving line lands
# AFTER the final target marker, and audit_batch's un-attributed-lines
# assertion correctly refuses to ignore it. The per-target dry runs this
# replaced tolerated that noise because they asserted nothing about stream
# shape; batching is stricter, so the noise is turned off at source.
batch_dry_run() {  # $1 = space-separated target list; prints the raw stream
    local target_list="$1" t
    local -a goals=()
    for t in $target_list; do
        goals+=("$BATCH_PREFIX$t")
    done
    (
        set -o pipefail
        emit_batch_makefile "$target_list" \
            | make -n -B --no-print-directory -f Makefile -f - "${goals[@]}" 2>&1
    )
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

    # The batched path must retain target attribution after one make stream is
    # split at its target-end markers: a fault in target B must be reported as
    # target B, not merely as an unarmed compiler line in the merged stream.
    EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
    join_continuations > "$st_joined" <<'EOF'
gcc -Werror=switch -Werror=comment -c src/vm.c -o build/a.o
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
gcc -Werror=switch -Werror=comment -c src/vm.c -o build/nonzero.o
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

    # The batched dry run must survive being invoked FROM a make recipe, which
    # is how `make test` runs this gate. Uses batch_dry_run, so dropping
    # --no-print-directory from the real invocation fails HERE.
    EXAMINED=0; VIOLATIONS=0; TARGET_EXAMINED=0
    if ! st_dry=$(MAKELEVEL=1 batch_dry_run "jit-smoke"); then
        echo "SELFTEST FAILED: nested-make batch dry run exited nonzero"
        st_fail=1
    elif ! audit_batch "jit-smoke" > "$st_out" \
         <<< "$(printf '%s\n' "$st_dry" | join_continuations)"; then
        echo "SELFTEST FAILED: batched dry run is not clean under a nested make (MAKELEVEL>0)"
        sed 's/^/    /' "$st_out"
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

    # Per-target floors (#921): partial coverage loss must be caught, an
    # untracked target must be caught, and an at-or-above count must pass.
    # TARGET_COUNTS is planted directly — no dry run, no tree mutation.
    st_saved_counts="$TARGET_COUNTS"

    TARGET_COUNTS="asan-http 30
build 25
"
    if ! enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: at-floor per-target counts were rejected"
        st_fail=1
    fi

    TARGET_COUNTS="asan-http 1000
build 25
"
    if ! enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: an above-floor per-target count was rejected"
        st_fail=1
    fi

    # The #921 shape itself: a batch sibling swallows most of a target's
    # compile lines, leaving it non-zero (so the zero-emission assertion stays
    # silent) but far below its real coverage.
    TARGET_COUNTS="asan-http 12
build 25
"
    if enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: partial coverage loss (30 -> 12) did not trip the per-target floor"
        st_fail=1
    fi

    TARGET_COUNTS="a_target_with_no_floor 40
"
    if enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: a target with no pinned floor was accepted"
        st_fail=1
    fi

    TARGET_COUNTS="$st_saved_counts"

    if [ "$st_fail" -ne 0 ]; then
        exit 1
    fi
    echo "SELFTEST OK: all planted fault shapes caught (incl. target-batch divergence, two-invocation blocks, switch-enum, zero-line targets, partial per-target coverage loss, unpinned targets), clean shapes pass, floors bite"
    exit 0
fi

# Validate the target partition before any dry run so a hand-edited batch
# cannot silently reduce the gate's coverage.
validate_target_batches "$TARGETS" "${TARGET_BATCHES[@]}" || exit 1

# --- main: dry-run every compiling target and audit what it WOULD run ---
make_failed=0
empty_failed=0
for target_list in "${TARGET_BATCHES[@]}"; do
    if ! dry=$(batch_dry_run "$target_list"); then
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

if [ "${1:-}" = "--print-counts" ]; then
    echo "# Regenerated TARGET_FLOORS body — paste into TARGET_FLOORS (#921)."
    printf '%s' "$TARGET_COUNTS"
    exit 0
fi

if [ "$make_failed" -ne 0 ] || [ "$empty_failed" -ne 0 ]; then
    exit 1
fi
require_minimum "$EXAMINED" || exit 1
enforce_target_floors || exit 1
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
echo "werror warning gate OK: all $EXAMINED compile invocations across $TARGETS_AUDITED dry-run targets + $(echo $SCRIPT_AUDITS | wc -w | tr -d ' ') script(s) carry: $REQUIRED_FLAGS"
exit 0
