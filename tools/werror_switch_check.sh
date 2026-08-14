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
#   a compiler command word (gcc/clang/cc/emcc/$CC/${CC}, including the
#   ${CC:-gcc} / ${CC-gcc} default forms with or without the colon, the
#   .exe suffix, quoted or unquoted, and inside either spelling of a
#   command substitution — $( ) or backticks)
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
# the global total plausible. Checked in BOTH directions: a pinned floor with
# no count means the target left TARGETS entirely, dropping 100% of its lines
# while every other assertion still passes. And ENROLLMENT: the three lists
# above (TARGETS, SCRIPT_AUDITS, TARGET_FLOORS) only cross-check each OTHER, so
# a compile surface never added to any of them was invisible to all of them —
# a new Makefile target running an unflagged `gcc -c src/vm.c` left this gate
# printing its clean-tree output and exiting 0. enrollment_check anchors the
# lists to the tree instead: any target emitting a compile line that no audited
# target emits, and any compile-bearing script outside SCRIPT_AUDITS, is a hard
# failure. The examined count is always printed.
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
# Scripts whose apparent compile is not one. Text-level recognition cannot see
# quoting, so these are waived explicitly rather than by loosening the matcher:
#   tools/amalgamate.sh          — an echo STRING telling the user how to build
#                                  the amalgamation by hand; it compiles nothing.
#   tools/werror_switch_check.sh — this gate. Its own header probe runs
#                                  `$CC -Werror=comment -fsyntax-only` on one
#                                  file deliberately, and its matcher patterns
#                                  contain compiler names as DATA.
#   tests/test_lint_linkage.sh   — a LINKAGE probe (#922). It compiles lint.c and
#                                  lint_host.c with `-w` ON PURPOSE: it asserts a
#                                  symbol stays TU-local, and warnings would only
#                                  add noise. Requiring -Werror=switch here would
#                                  test nothing the real build does not.
#   tests/test_amalgamation.sh   — compiles the generated single-file
#                                  amalgamation as a downstream CONSUMER would,
#                                  with a consumer's flags. Pinning our internal
#                                  warning flags onto it would stop it modelling
#                                  the thing it exists to model.
SCRIPT_ENROLL_EXEMPT="tools/amalgamate.sh tools/werror_switch_check.sh tests/test_lint_linkage.sh tests/test_amalgamation.sh"

# An exemption is otherwise an UNBOUNDED waiver: an exempt script can later gain
# a real compile and stay invisible (verified — appending a genuine
# `gcc -O2 -c src/vm.c` to amalgamate.sh kept the gate at exit 0). So exempt
# scripts are content-pinned; changing one fails the gate and forces re-review.
#
# tools/werror_switch_check.sh is deliberately NOT pinned: it is this file, so
# the pin would have to contain a hash of a file containing that hash. Its
# exemption rests on construction instead — it is the auditor, its compiler
# names are matcher DATA, and its one real compile is a deliberate
# -fsyntax-only header probe.
SCRIPT_ENROLL_PINS="tools/amalgamate.sh:254253ab8bb08531 tests/test_lint_linkage.sh:22b5fe736e74cde5 tests/test_amalgamation.sh:6af977a1cb7fb6f9"

# tests/test_leak_guard.sh and tests/run_all_tests.sh joined in #925: widening
# the recognizer made their compiles VISIBLE for the first time. They were
# never exempt — they were unseen, which is worse, because an exemption is a
# decision on record. test_leak_guard.sh:56 compiles the ENTIRE runtime
# ($SRCS, the largest compile surface in the tree) and carried NEITHER
# required flag until this change.
SCRIPT_AUDITS="build.sh tools/freestanding_check.sh tools/freestanding_smoke.sh tools/embed_stack_soak.sh web/build.sh tests/test_leak_guard.sh tests/run_all_tests.sh"

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
ALL_COMPILE_LINES=''  # every audited compile invocation, whitespace-normalised

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
script:tests/test_leak_guard.sh 2
script:tests/run_all_tests.sh 1
'

# Floor for a label, or empty when the label is untracked.
target_floor() {  # $1 = label
    printf '%s\n' "$TARGET_FLOORS" | awk -v t="$1" '$1 == t { print $2; exit }'
}

# TARGETS, SCRIPT_AUDITS and TARGET_FLOORS are three hand-written lists that
# cross-check each other — and NONE of them is anchored to the Makefile. So a
# compile surface that was never enrolled is invisible to every other assertion
# in this script: the forward loop never sees it (no count), the reverse loop
# never sees it (no floor), MIN_LINES does not move, and every pinned floor is
# still met. Measured: adding a `plugin` target that runs
# `gcc -Wall -Wextra -O2 -c src/vm.c` — no -Werror=switch, on the largest switch
# surface in the tree — left the gate printing its clean-tree output and exiting
# 0. The header's claim to dry-run every compiling target was an assertion, not
# an invariant.
#
# The invariant is about LINES, not targets. `all` and `test` depend on `build`,
# so they legitimately emit compile lines that ARE audited under `build`;
# flagging any unenrolled target that emits a compile would be a false positive.
# What must never happen is an unenrolled target emitting a compile line that NO
# enrolled target emits. That is what this checks.
enrollment_check() {
    local failed=0 t dry seg norm all_targets
    local mk="${MAKEFILE_SRC:-Makefile}"
    # Enumerate from MAKE'S OWN DATABASE (post-expansion), not from a grep over
    # Makefile source. A source grep only sees literal names at column 0, so a
    # target named through a variable is invisible — and this Makefile ALREADY
    # declares two that way (`$(LSP_BINARY):`, `$(DAP_BINARY):`). Measured: a
    # `PLUGIN_T := plugin2` / `$(PLUGIN_T):` target compiling src/vm.c with
    # neither required flag was not enumerated at all, so the gate passed. The
    # same blindness covers pattern rules and targets from an `include`d file.
    #
    # Filters: `%` drops pattern rules; `build/` drops per-variant objects
    # (already audited under their variant); and a name that EXISTS as a file is
    # a source/artifact prerequisite echoed by the database, not a goal.
    all_targets=$(make -pqRr -f "$mk" 2>/dev/null \
        | awk '/^[^ \t.#%][^ :=]*:([^=]|$)/ { sub(/:.*/, ""); print }' \
        | sort -u | grep -v '%' | grep -v '^build/')
    for t in $all_targets; do
        case " $TARGETS " in *" $t "*) continue;; esac
        [ -e "$t" ] && continue   # an existing file: a prerequisite, not a goal
        if ! dry=$(make -f "$mk" -n -B --no-print-directory "$t" 2>/dev/null); then
            continue   # a target that cannot even dry-run emits nothing to audit
        fi
        while IFS= read -r line; do
            while IFS= read -r seg; do
                seg="${seg#"${seg%%[![:space:]]*}"}"
                seg="${seg%"${seg##*[![:space:]]}"}"
                [ -z "$seg" ] && continue
                is_compile_invocation "$seg" || continue
                norm=$(printf '%s' "$seg" | tr -s '[:space:]' ' ')
                case "$ALL_COMPILE_LINES" in
                    *"$norm"*) ;;
                    *)
                        echo "GATE ERROR: target '$t' is not in TARGETS and emits a compile"
                        echo "invocation that NO audited target emits, so it is unchecked:"
                        printf '    %s\n' "$norm"
                        echo "Enroll '$t' in TARGETS + TARGET_BATCHES + TARGET_FLOORS, or make it"
                        echo "reuse an audited recipe."
                        failed=1
                        ;;
                esac
            done < <(split_invocations <<< "$line")
        done <<< "$(printf '%s\n' "$dry" | join_continuations)"
    done
    # Same hole on the script side: a compile-bearing shell script that was
    # never added to SCRIPT_AUDITS is audited by nothing. The reverse floor loop
    # catches a script REMOVED from the list; only this catches one never added.
    #
    # Uses the SAME recognizer as the audit (strip_comments -> join -> split ->
    # is_compile_invocation), not a raw grep: a looser grep flagged
    # tools/amalgamate.sh for an echo STRING telling the user how to compile,
    # which is the kind of false positive that gets a check deleted.
    #
    # The recognizer is still text-level, so it cannot tell a compile inside a
    # quoted string from a real one. Two scripts are exempt, each with its
    # reason — this is a CHECKED list, so a new compile-bearing script still
    # fails loudly; only these two are waived.
    # `git ls-files` rather than a `./*.sh tools/*.sh web/*.sh` glob. The glob
    # was an UNBOUNDED, UNDOCUMENTED exemption of every other directory — the
    # exact waiver shape amalgamate.sh is content-pinned to prevent — and it was
    # already false for the tree: five compile-bearing scripts live in tests/
    # and none was audited or waived.
    local sc
    # Same enumeration hazard the coverage check hit: --selftest's fault trees
    # are `git archive HEAD | tar -x` extractions, NOT repositories, so
    # `git ls-files` returns nothing and this whole loop iterated ZERO scripts
    # while reporting success — measured at 0 scripts in a fault tree vs 66 in
    # the real repo, with a planted unenrolled compile going unreported. Fall
    # back to find, and refuse to pass on an empty enumeration.
    local enroll_scripts
    enroll_scripts=$(git ls-files '*.sh' 2>/dev/null | sort -u)
    [ -z "$enroll_scripts" ] && enroll_scripts=$(find . -name '*.sh' -not -path './.git/*' 2>/dev/null | sed 's|^\./||' | sort -u)
    if [ -z "$enroll_scripts" ]; then
        echo "GATE ERROR: script enrollment found NO shell scripts to examine —"
        echo "the assertion would pass vacuously, so it fails instead."
        return 1
    fi
    for sc in $enroll_scripts; do
        case " $SCRIPT_AUDITS " in *" $sc "*) continue;; esac
        case " $SCRIPT_ENROLL_EXEMPT " in *" $sc "*) continue;; esac
        local found=0 sline sseg
        while IFS= read -r sline; do
            while IFS= read -r sseg; do
                sseg="${sseg#"${sseg%%[![:space:]]*}"}"
                [ -z "$sseg" ] && continue
                if is_compile_invocation "$sseg"; then found=1; break; fi
            done < <(split_invocations <<< "$sline")
            [ "$found" -eq 1 ] && break
        done <<< "$(strip_comments < "$sc" | join_continuations)"
        if [ "$found" -eq 1 ]; then
            echo "GATE ERROR: script '$sc' contains compile invocations but is not in"
            echo "SCRIPT_AUDITS, so nothing checks its compile lines for $REQUIRED_FLAGS."
            echo "Add it to SCRIPT_AUDITS (and pin its floor via --print-counts), or add it"
            echo "to SCRIPT_ENROLL_EXEMPT with the reason it emits no real compile."
            failed=1
        fi
    done

    # Exempt scripts are content-pinned so the waiver cannot silently widen.
    local pin pin_path pin_hash now_hash
    for pin in $SCRIPT_ENROLL_PINS; do
        pin_path=${pin%%:*}; pin_hash=${pin##*:}
        [ -f "$pin_path" ] || { echo "GATE ERROR: pinned exempt script '$pin_path' is missing"; failed=1; continue; }
        # sha256sum is GNU; macOS ships `shasum -a 256`, and CI runs this whole
        # suite on macos-latest and macos-15-intel. An UNRUNNABLE instrument must
        # not be reported as a content change — that is a red CI leg pointing at
        # the wrong file.
        if command -v sha256sum >/dev/null 2>&1; then
            now_hash=$(sha256sum "$pin_path" | cut -c1-16)
        elif command -v shasum >/dev/null 2>&1; then
            now_hash=$(shasum -a 256 "$pin_path" | cut -c1-16)
        else
            echo "GATE ERROR: neither sha256sum nor shasum is available, so the exempt-script"
            echo "content pins cannot be checked. Install one; do not weaken the pin."
            failed=1
            continue
        fi
        if [ "$now_hash" != "$pin_hash" ]; then
            echo "GATE ERROR: exempt script '$pin_path' CHANGED ($pin_hash -> $now_hash)."
            echo "Its enrollment exemption was granted for specific content. Re-read it: if it"
            echo "now really compiles, add it to SCRIPT_AUDITS; if not, update the pin."
            failed=1
        fi
    done

    return "$failed"
}

# Assert every audited target met its pinned floor and none is untracked.
# Runs on the main path only; the selftest exercises it through planted
# TARGET_COUNTS streams instead, so synthetic labels need no floors.
enforce_target_floors() {
    local failed=0 label count floor pinned seen

    # BOTH DIRECTIONS, and checking only the first leaves the largest form of
    # #921's own failure wide open. Forward (every counted target is pinned)
    # catches a target that joins a batch unpinned. REVERSE (every pinned
    # target produced a count) catches a target DELETED from TARGETS — which
    # drops 100% of its compile lines, not merely some, while every remaining
    # assertion still passes: the per-target zero-emission check never runs for
    # a target that is no longer dry-run at all, and MIN_LINES=100 is nowhere
    # near the ~338 real total. Measured: removing `http` from TARGETS silently
    # stopped checking 29 invocations — including ext_http.c — and the gate
    # printed "gate OK" and exited 0.
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

    # Reverse: a pinned floor with no corresponding count means that target is
    # no longer being audited at all.
    while read -r pinned _; do
        [ -z "$pinned" ] && continue
        seen=$(printf '%s\n' "$TARGET_COUNTS" | awk -v t="$pinned" '$1 == t { print "y"; exit }')
        if [ -z "$seen" ]; then
            echo "GATE ERROR: target '$pinned' has a pinned floor but produced NO count —"
            echo "it is no longer in TARGETS/TARGET_BATCHES, so 100% of its compile lines"
            echo "stopped being audited while every other assertion still passed."
            echo "Restore the target, or delete its TARGET_FLOORS entry deliberately."
            failed=1
        fi
    done <<< "$(printf '%s\n' "$TARGET_FLOORS" | grep -v '^[[:space:]]*$')"

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
    # Compiler command word. The ${CC:-gcc} / ${CC:=cc} / ${CC:?...} default
    # forms are matched explicitly: the old pattern accepted $CC and ${CC} but
    # not the :-default spelling, which is what tests/run_all_tests.sh and
    # build.sh actually use (#925). Missing the command word does not make a
    # line "unflagged" — it makes it INVISIBLE, so no assertion in this gate can
    # fail on it.
    # The colon is OPTIONAL. POSIX defines ${CC-gcc}, ${CC=cc}, ${CC?msg} and
    # ${CC+alt} alongside their colon forms — they differ only in whether an
    # EMPTY CC counts as unset, which is invisible to a text matcher and
    # irrelevant to whether the line compiles. Fixing only the colon forms in
    # #925 left the rest of the same family unseen, and `-`/`=`/`?` unseen in
    # BOTH matchers: the broad cross-check below shared the `[:}]` anchor, so it
    # could not report the miss either — the two-lists-agreeing-with-each-other
    # mode again. All four operators are matched, so the family is closed rather
    # than extended one operator per drift.
    # The prefix class admits `(` and a BACKTICK as well as whitespace: a
    # compile inside a command substitution — `OUT=$(${CC:-gcc} ... -c foo.c)`,
    # which is exactly how tests/run_all_tests.sh builds the opcode-ABI TU — has
    # the command word preceded by `(`, not by a space. Without this the script
    # enrolls and then yields ZERO compile invocations, which this gate correctly
    # refuses to treat as a pass (#925). Backticks are the OTHER spelling of the
    # same construct and were left out of that fix; `OUT=`gcc -c probe.c`` was
    # invisible to this matcher AND to the broad one below, so the cross-check
    # could not have reported it. Both spellings, or the next `$( )` audit finds
    # nothing while the backtick beside it compiles unflagged.
    # `.exe` is admitted after the optional -VERSION suffix: the Windows Tier-1
    # path invokes `gcc.exe` / `x86_64-w64-mingw32-gcc.exe`, and a trailing
    # `.exe` broke the whole-token anchor in both matchers. No such line is in
    # the tree today — this is covered before the surface lands, not after.
    printf '%s\n' "$1" | grep -qE '(^|[[:space:]]|[(`])("?[^[:space:]"]*[-/}])?"?(gcc|clang|cc|emcc)(-[0-9][0-9.]*)?(\.exe)?"?([[:space:]]|$)|(^|[[:space:]]|[(`])"?\$\{?CC([:]?[-=?+][^}]*)?\}?"?([[:space:]]|$)' || return 1
    printf '%s\n' "$1" | grep -qE '\.c\b' && return 0
    printf '%s\n' "$1" | grep -qE '(^|[[:space:]])-c([[:space:]]|$)' && return 0
    # `-x c -` compiles from stdin: a real compile with no .c anywhere and no
    # standalone -c. tests/test_leak_guard.sh's ASan probe is exactly this shape;
    # the coverage check below is what surfaced it (#925).
    printf '%s\n' "$1" | grep -qE '(^|[[:space:]])-x[[:space:]]+c([[:space:]]|$)' && return 0
    printf '%s\n' "$1" | grep -qE '(\$SOURCES|\$LSP_SOURCES|\$SRCS|\$\{SOURCES\[@\]\})'
}

# ---- #925: assert the RECOGNIZER's own coverage -------------------------
#
# Widening the two patterns above is necessary and not sufficient: they are
# hand-written lists, and this is the third time they have drifted from the tree.
# Every other assertion in this gate — the per-target floors, the reverse loop,
# enrollment_check, MIN_LINES — counts what is_compile_invocation recognises, so
# a miss HERE is invisible to all of them. A compile line the recognizer skips is
# not "unflagged", it is not there.
#
# So: cross-check the strict recognizer against a deliberately OVER-BROAD one
# (a compiler command word appears at all) over every tracked shell script, and
# hard-fail on anything the broad matcher sees and the strict one does not,
# unless it is waived below with a reason. That turns "keep the patterns current
# by convention" into a checked invariant.
#
# The comparison runs through this gate's OWN strip_comments | join_continuations
# | split_invocations pipeline. Comparing raw file lines instead reports every
# backslash continuation as a miss — measured, it produced 13 false alarms
# against 3 real ones, which is how a coverage check gets muted for noise.
recognizer_broad_match() {
    # This MUST be broader than is_compile_invocation on every axis, or the
    # cross-check is blind exactly where the strict matcher is.
    #
    # The first version was broader only in CONTEXT (it admitted more surrounding
    # punctuation) while sharing the strict matcher's hand-written compiler-NAME
    # list and its "no prefix" anchoring. So `x86_64-w64-mingw32-gcc`,
    # `/usr/bin/gcc`, `clang-18` and `${CROSS}gcc` were invisible to BOTH — and a
    # check cannot report a miss its own broad matcher cannot see. That is the
    # same two-lists-validating-each-other failure this gate exists to prevent,
    # reproduced one level up in the fix for it.
    #
    # So: any whitespace-delimited token CONTAINING a compiler name, with any
    # prefix and any suffix. Over-matching here is free — it only adds waiver
    # load, which is visible and reviewable. Under-matching is silent.
    # The compiler name must be a whole COMPONENT of the token: at its start, or
    # immediately after a `/`, `-` or `}` (path, cross-prefix, ${VAR} expansion),
    # with an optional -VERSION suffix. Matching any token merely CONTAINING the
    # name is too broad in a way that destroys the check's usefulness — measured,
    # it fired on `acc`, `accumulate`, `accept` and `accuracy` in ordinary test
    # scripts (8 false alarms), and a check that cries wolf gets muted.
    #
    # Six forms were invisible to BOTH matchers before this change, measured on
    # the shipped patterns at 50de57e: `gcc.exe`, `x86_64-w64-mingw32-gcc.exe`,
    # `OUT=`gcc -c probe.c`` (backtick substitution), and the `${CC+alt}`,
    # `${CC-gcc}`, `${CC?msg}` colon-less operators. Blind TOGETHER is the
    # dangerous shape, not blind unevenly: the cross-check can only report a
    # strict miss that the broad matcher sees, so a form both share is invisible
    # to the very assertion built to catch drift — and the pre-filter (same
    # pattern) skips such a file outright, so its compile lines are never
    # audited at all.
    #
    # The invariant that prevents this is BROAD ⊇ STRICT on every axis: name
    # set, path/cross prefix, version and .exe suffix, ${CC} operator class, and
    # substitution spelling. That is not left to a comment — recognizer_axis_parity
    # below asserts it mechanically over one representative line per axis, and
    # --selftest fails if any widening of the strict matcher lands without the
    # matching widening here.
    # RECOGNIZER_PATTERN broad
    printf '%s\n' "$1" | grep -qE '(^|[[:space:]"'"'"'(={;`])([^[:space:]"'"'"';)`]*[/}-])?(gcc|clang|cc|emcc)(-[0-9][0-9.]*)?(\.exe)?([[:space:]"'"'"';)`]|$)|\$\{?CC[:}=?+-]|\$CC\b'
}

# BROAD >= STRICT, asserted per axis rather than promised in a comment.
#
# The cross-check can only report a strict miss the BROAD matcher sees. So any
# axis where broad is tighter is an axis the coverage check is blind on, and
# blind silently — the pre-filter shares the broad pattern, so a file it skips
# is never audited at all. Six forms were invisible to both matchers at 50de57e
# (.exe, cross-prefixed .exe, backtick substitution, and the colon-less
# ${CC+alt} / ${CC-gcc} / ${CC?msg} operators), which is exactly this failure.
#
# One representative line per axis. A widening of is_compile_invocation that
# does not land here fails --selftest instead of quietly narrowing the gate.
RECOGNIZER_AXIS_LINES='
gcc -Wall -c src/vm.c
cc -c a.c
emcc -c a.c
clang-18 -O2 -c src/vm.c
/usr/bin/gcc -c src/vm.c
x86_64-w64-mingw32-gcc -c src/vm.c
gcc.exe -c src/vm.c
x86_64-w64-mingw32-gcc.exe -c src/vm.c
${CC} -c a.c
${CC:-gcc} -c a.c
${CC-gcc} -c a.c
${CC:=cc} -c a.c
${CC=cc} -c a.c
${CC:?m} -c a.c
${CC?m} -c a.c
${CC:+a} -c a.c
${CC+alt} -c a.c
OUT=$(gcc -c a.c)
OUT=`gcc -c a.c`
'

recognizer_axis_parity() {
    local failed=0 line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if is_compile_invocation "$line" && ! recognizer_broad_match "$line"; then
            echo "GATE ERROR: the broad matcher is TIGHTER than the strict one on:"
            printf '    %s\n' "$line"
            echo "The cross-check can only report a strict miss that broad sees, so this"
            echo "axis is unpoliced. Widen recognizer_broad_match in the same commit."
            failed=1
        fi
    done <<EOF
$RECOGNIZER_AXIS_LINES
EOF
    # The pre-filter must be the broad pattern VERBATIM. A comment claiming so
    # is what hid the earlier blindness — the comment said "a bare substring, no
    # anchoring" long after the code had become the anchored pattern, and a
    # reader trusting it would conclude wrongful exclusion was impossible.
    # Compare the two literals in the file instead of describing them.
    local bp pf self="${BASH_SOURCE[0]:-$0}"
    if [ ! -r "$self" ]; then
        echo "GATE ERROR: axis parity cannot read its own source ($self) to compare"
        echo "the pre-filter against the broad matcher. Refusing to pass on a check"
        echo "that examined nothing."
        return 1
    fi
    # Anchored on an explicit sentinel, not on incidental text shape. The first
    # draft grepped for the literal "grep -qE '...'" and matched its OWN
    # extraction code, so the clean tree reported drift.
    # Line-anchored: the sentinel must be the whole comment line. Without the
    # ^[[:space:]]*# anchor these greps ALSO match the two lines just below,
    # which mention the sentinel as a string literal — the same self-matching
    # that broke the previous draft, one layer down.
    bp=$(grep -A1 '^[[:space:]]*# RECOGNIZER_PATTERN broad$'     "$self" | tail -1 | sed 's/^[[:space:]]*//')
    pf=$(grep -A1 '^[[:space:]]*# RECOGNIZER_PATTERN prefilter$' "$self" | tail -1 | sed 's/^[[:space:]]*//')
    # Normalise the parts that legitimately differ: the prefilter greps a FILE
    # and drops the trailing \b, the matcher greps "$1". Compare only the regex.
    # Strip the wrappers with sed. The previous draft used a parameter
    # expansion referencing "$f" — a loop variable belonging to a DIFFERENT
    # function — which is an unbound-variable fatal under `set -u`, and it
    # aborted the clean run while the planted run still reported correctly.
    bp=$(printf '%s' "$bp" | sed -e 's/^.*grep -qE //' -e 's/[[:space:]]*$//')
    pf=$(printf '%s' "$pf" | sed -e 's/^.*grep -qE //' -e 's/ "[$]f".*$//' -e 's/[[:space:]]*$//')
    # An extraction that finds NOTHING must fail, not skip. Failing open here is
    # the same silent-pass mode this whole gate exists to prevent, and the first
    # draft of this very check did exactly that: it keyed on "$0", which is not
    # the script path when the function is sourced, so both extractions came
    # back empty, the comparison was skipped and the check reported success.
    if [ -z "$bp" ] || [ -z "$pf" ]; then
        echo "GATE ERROR: axis parity could not extract both patterns"
        echo "  broad matcher pattern found: ${bp:+yes}${bp:-NO}"
        echo "  pre-filter pattern found:    ${pf:+yes}${pf:-NO}"
        echo "The comparison would pass vacuously, so it fails instead."
        return 1
    fi
    if [ "${bp#grep -qE }" != "${pf#grep -qE }" ]; then
        echo "GATE ERROR: the coverage pre-filter pattern has drifted from"
        echo "recognizer_broad_match. A pre-filter TIGHTER than the matcher it gates"
        echo "silently excludes files that would have been flagged."
        printf '  broad    : %s\n' "$bp"
        printf '  prefilter: %s\n' "$pf"
        failed=1
    fi
    return $failed
}

# Waivers are SHAPES, not line pins, because a line pin on a log message rots on
# any reword while protecting nothing. Each shape is a structural reason a
# compiler word can appear on a line that is not a compile invocation.
recognizer_waived() {
    local seg="$1" unquoted quoted
    # 1. A variable assignment: `CC="${CC:-gcc}"` names a compiler, runs nothing.
    #    Note an ENV-PREFIXED compile (`FOO=bar gcc -c x.c`) is not swallowed by
    #    this: the strict recognizer already SEES that line, so the waiver is
    #    never consulted for it.
    printf '%s\n' "$seg" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*$' && return 0
    # 3. A relocatable LINK (`-r`), not a compile: no translation unit is
    #    compiled, so no warning flag applies. tests/test_lint_linkage.sh:48.
    printf '%s\n' "$seg" | grep -qE '(^|[[:space:]])-r([[:space:]]|$)' && return 0
    # 2. The compiler word appears only inside a quoted string — a log message or
    #    a usage hint, e.g. amalgamate.sh's "compile: cc host.c ...".
    #
    #    But NOT when the quoted text is itself a compile. `sh -c "gcc -c
    #    src/vm.c"` and `eval "gcc ..."` EXECUTE that string, and `"gcc" -O2 -c
    #    src/vm.c` is an ordinary invocation whose command word merely happens to
    #    be quoted. The first version of this shape waived all three — real,
    #    unflagged compiles of the largest switch surfaces in the tree, exempted
    #    automatically and silently. So inspect the quoted CONTENT first.
    quoted=$(printf '%s\n' "$seg" | grep -oE '"[^"]*"' | tr -d '"')
    if [ -n "$quoted" ] && is_compile_invocation "$quoted"; then
        return 1
    fi
    unquoted=$(printf '%s\n' "$seg" | sed -e 's/"[^"]*"//g')
    recognizer_broad_match "$unquoted" || return 0
    return 1
}

recognizer_coverage_check() {
    local f seg failed=0 waived=0 norm scripts examined_files=0
    # Enumerate from git where possible, but fall back to find: --selftest's
    # fault trees are `git archive HEAD | tar -x` extractions, NOT repositories,
    # so `git ls-files` returns NOTHING there. Measured — this check printed its
    # OK line with "0 waived" inside a fault tree, i.e. it examined zero files
    # and reported success. A coverage check that silently measures nothing is
    # worse than no check, because it reads as evidence.
    scripts=$(git ls-files '*.sh' 2>/dev/null)
    [ -z "$scripts" ] && scripts=$(find . -name '*.sh' -not -path './.git/*' 2>/dev/null | sed 's|^\./||')
    if [ -z "$scripts" ]; then
        echo "GATE ERROR: recognizer coverage found NO shell scripts to examine."
        echo "Neither 'git ls-files' nor 'find' enumerated anything — the check"
        echo "would pass vacuously, so it fails instead."
        return 1
    fi
    # Cheap per-file pre-filter. The expensive path is per-SEGMENT (two greps
    # each, after a three-process normalisation pipeline), and only ~10 of 66
    # scripts mention a compiler at all. One grep per file skips the rest
    # outright — 2m50s to a few seconds, on a gate #923 is already open about.
    # DIRECTION: the pre-filter must be no TIGHTER than recognizer_broad_match,
    # or it silently excludes a file the real matcher would have flagged — the
    # expensive-but-silent half of a pre-filter's two failure modes. It is not,
    # as the comment here once claimed, "a bare substring, no anchoring": it is
    # the broad pattern verbatim (minus the trailing \b, which only loosens it).
    # That false claim is what hid the `.exe`/backtick/`${CC+}` blindness above —
    # a reader trusting it would conclude wrongful exclusion was impossible. Keep
    # this pattern character-identical to recognizer_broad_match; prefilter_axis
    # selftests assert it.
    for f in $scripts; do
        # RECOGNIZER_PATTERN prefilter
        grep -qE '(^|[[:space:]"'"'"'(={;`])([^[:space:]"'"'"';)`]*[/}-])?(gcc|clang|cc|emcc)(-[0-9][0-9.]*)?(\.exe)?([[:space:]"'"'"';)`]|$)|\$\{?CC[:}=?+-]|\$CC\b' "$f" 2>/dev/null \
            || { examined_files=$((examined_files + 1)); continue; }
        # This file is the auditor: its compiler names are matcher DATA, the same
        # construction argument that exempts it from SCRIPT_ENROLL_PINS.
        [ "$f" = "tools/werror_switch_check.sh" ] && continue
        while IFS= read -r seg; do
            seg="${seg#"${seg%%[![:space:]]*}"}"
            seg="${seg%"${seg##*[![:space:]]}"}"
            [ -z "$seg" ] && continue
            recognizer_broad_match "$seg" || continue
            is_compile_invocation "$seg" && continue
            if recognizer_waived "$seg"; then
                waived=$((waived + 1)); continue
            fi
            norm=$(printf '%s' "$seg" | tr -s '[:space:]' ' ')
            echo "GATE ERROR: $f has a line naming a compiler that the recognizer"
            echo "does not classify as a compile invocation, and no waiver covers it:"
            printf '    %s\n' "$norm"
            echo "Either it IS a compile (widen is_compile_invocation) or it is not"
            echo "(add a reasoned shape to recognizer_waived). Do not leave it silent."
            failed=1
        done <<< "$(strip_comments < "$f" | join_continuations | split_invocations)"
        examined_files=$((examined_files + 1))
    done
    if [ "$examined_files" -eq 0 ]; then
        echo "GATE ERROR: recognizer coverage examined 0 files despite a non-empty list."
        return 1
    fi
    if [ "$failed" -eq 0 ]; then
        echo "recognizer coverage OK: $examined_files scripts examined; every" \
             "compiler-naming line is recognised or waived by shape ($waived waived)"
    fi
    return $failed
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
            # Remember the normalised line so enrollment_check can ask whether an
            # UNENROLLED target emits a compile nobody audited (see below).
            ALL_COMPILE_LINES="${ALL_COMPILE_LINES}$(printf '%s' "$seg" | tr -s '[:space:]' ' ')
"
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
    st_work=$(mktemp -d /tmp/werror_selftest_XXXX)
    # NOTE: a later `trap ... EXIT` REPLACES this one rather than adding to it,
    # so $st_work must be cleaned by the FINAL trap below, not here. Leaving it
    # in a trap that gets overwritten leaked one /tmp dir per run — 13 had
    # accumulated on the devbox, one per suite run and one per CI job.
    # audit_stream must run in THIS shell or its EXAMINED/VIOLATIONS
    # increments die in the command-substitution subshell — capture its
    # stdout via a temp file instead of $(...). Streams go through
    # join_continuations first, exactly like the main path.
    st_out=$(mktemp /tmp/werror_switch_selftest_out_XXXX)
    st_joined=$(mktemp /tmp/werror_switch_selftest_joined_XXXX)
    st_scratch=$(mktemp -d /tmp/werror_switch_selftest_tree_XXXX)
    # Every expansion is :-guarded. The script runs under `set -u`, so ONE
    # unbound name anywhere in a trap aborts the whole trap and everything after
    # it leaks — verified: a trap whose first rm names an unset var leaves its
    # later `rm -rf` undone. Guarding is cheap; diagnosing a leak through a dead
    # trap is not.
    trap 'rm -f "${st_out:-}" "${st_joined:-}" 2>/dev/null; rm -rf -- "${st_scratch:-/nonexistent}" "${st_work:-/nonexistent}" 2>/dev/null' EXIT

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

    # ---- #925: the RECOGNIZER's spellings, one case each ----------------
    #
    # These do not test the flag logic; they test that is_compile_invocation
    # SEES the line at all. A spelling it misses is not reported unflagged — it
    # is not examined, so VIOLATIONS stays 0 and expect_caught fails. That is
    # the failure mode that let ${CC:-gcc} and $SRCS sit unrecognised through
    # two previous rounds of "just add the pattern".
    #
    # Every spelling below is one that WAS missed and is now covered. Adding a
    # new accepted spelling to is_compile_invocation without adding its case
    # here leaves the next drift silent again.
    expect_caught "recognizer: \${CC:-gcc} default form" "abi_probe.c" <<'EOF'
${CC:-gcc} -std=c11 -I. -c abi_probe.c -o /tmp/abi_probe.o
EOF
    expect_caught "recognizer: \${CC:=cc} assign-default form" "assign_default.c" <<'EOF'
${CC:=cc} -std=c11 -I. -c assign_default.c -o /tmp/assign_default.o
EOF
    expect_caught "recognizer: \${CC-gcc} colon-less default form" "posix_default.c" <<'EOF'
${CC-gcc} -std=c11 -I. -c posix_default.c -o /tmp/posix_default.o
EOF
    expect_caught "recognizer: \"\${CC?msg}\" colon-less error form, quoted" "posix_error.c" <<'EOF'
"${CC?no compiler}" -std=c11 -I. -c posix_error.c -o /tmp/posix_error.o
EOF
    expect_caught "recognizer: \${CC=cc} colon-less assign form" "posix_assign.c" <<'EOF'
${CC=cc} -std=c11 -I. -c posix_assign.c -o /tmp/posix_assign.o
EOF
    expect_caught "recognizer: \${CC+alt} alternate form" "posix_alt.c" <<'EOF'
${CC+alt} -std=c11 -I. -c posix_alt.c -o /tmp/posix_alt.o
EOF
    expect_caught "recognizer: backtick command substitution" "backtick_probe.c" <<'EOF'
OUT=`gcc -std=c11 -I. -c backtick_probe.c -o /tmp/backtick_probe.o`
EOF
    expect_caught "recognizer: gcc.exe (Windows Tier-1 surface)" "win_probe.c" <<'EOF'
gcc.exe -std=c11 -I. -c win_probe.c -o /tmp/win_probe.o
EOF
    expect_caught "recognizer: cross-prefixed .exe toolchain" "cross_probe.c" <<'EOF'
x86_64-w64-mingw32-gcc.exe -std=c11 -I. -c cross_probe.c -o /tmp/cross_probe.o
EOF
    expect_caught "recognizer: compile inside \$( ) command substitution" "subst_probe.c" <<'EOF'
OUT=$(${CC:-gcc} -std=c11 -I. -c subst_probe.c -o /tmp/subst_probe.o 2>&1)
EOF
    expect_caught "recognizer: \$SRCS whole-source-list build" '$SRCS' <<'EOF'
gcc -O1 -g -fsanitize=address $SRCS -o /tmp/asan_bin -lm -lpthread
EOF
    expect_caught "recognizer: -x c - stdin compile" "-x c" <<'EOF'
gcc -fsanitize=address -x c - -o /tmp/asan_probe
EOF
    expect_caught "recognizer: bare cc command word" "bare_probe.c" <<'EOF'
cc -O2 -c bare_probe.c -o /tmp/bare_probe.o
EOF
    # And the negative direction: a compiler word on a line that is NOT a
    # compile must stay unexamined, or the gate starts demanding warning flags
    # on variable assignments and relocatable links.
    expect_clean "recognizer: CC assignment is not an invocation" <<'EOF'
CC="${CC:-gcc}"
EOF
    expect_clean "recognizer: -r relocatable link is not a compile" <<'EOF'
"$CC" -r -o /tmp/linked.o /tmp/probe.o /tmp/collision.o
EOF

    # ---- POSITIVE CONTROL for recognizer_coverage_check itself --------
    #
    # Every other assertion in this file is pinned to a floor or a count.
    # recognizer_coverage_check was pinned to nothing and ran only on the main
    # path, so a typo in recognizer_broad_match would make it print
    # "OK ... (0 waived)" forever with nothing noticing — the check would have
    # become decoration without ever failing. It has no other caller, so nothing
    # else in the gate exercises those two matchers at all.
    #
    # Plant a script carrying a line the BROAD matcher sees, the strict
    # recognizer does not classify, and no waiver shape covers. The check must
    # fail and must name the file.
    st_cov_dir="$st_scratch/covctl"
    mkdir -p "$st_cov_dir"
    cat > "$st_cov_dir/rogue_build.sh" <<'ROGUE'
#!/bin/sh
gcc -Wall -O2 build/foo.o -o out
ROGUE
    if ( cd "$st_cov_dir" && recognizer_coverage_check ) > "$st_out" 2>&1; then
        echo "SELFTEST FAILED: coverage check passed a line it should have flagged"
        sed 's/^/    /' "$st_out"
        st_fail=1
    elif ! grep -qF 'rogue_build.sh' "$st_out"; then
        echo "SELFTEST FAILED: coverage check fired but did not name the offending script"
        sed 's/^/    /' "$st_out"
        st_fail=1
    fi
    # And the negative half: with the offending line removed, it must PASS —
    # otherwise the control proves only that the check always fails.
    cat > "$st_cov_dir/rogue_build.sh" <<'CLEAN'
#!/bin/sh
gcc -Werror=switch -Werror=comment -Wall -O2 -c src/vm.c -o build/vm.o
CLEAN
    if ! ( cd "$st_cov_dir" && recognizer_coverage_check ) > "$st_out" 2>&1; then
        echo "SELFTEST FAILED: coverage check flagged a clean recognised compile"
        sed 's/^/    /' "$st_out"
        st_fail=1
    fi

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

    # Per-target floors (#921). Both directions are exercised, and every
    # fixture is built from the FULL floor table with exactly one mutation —
    # a 2-entry fixture would now trip the reverse loop for the 25 targets it
    # omits, which is a fixture bug wearing a real failure's clothes.
    # TARGET_COUNTS is planted directly — no dry run, no tree mutation.
    st_saved_counts="$TARGET_COUNTS"

    # "label count" for every pinned target, at exactly its floor.
    st_full_counts() {
        printf '%s\n' "$TARGET_FLOORS" | grep -v '^[[:space:]]*$' | awk '{ print $1, $2 }'
    }
    # Same, with one target's count overridden (or dropped, if count is empty).
    st_counts_with() {  # $1 = target, $2 = replacement count ("" drops the row)
        st_full_counts | awk -v t="$1" -v c="$2" '
            $1 == t { if (c != "") print t, c; next }
            { print }'
    }

    TARGET_COUNTS="$(st_full_counts)
"
    if ! enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: a complete at-floor count set was rejected"
        st_fail=1
    fi

    TARGET_COUNTS="$(st_counts_with asan-http 1000)
"
    if ! enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: an above-floor per-target count was rejected"
        st_fail=1
    fi

    # The #921 shape itself: a batch sibling swallows most of a target's
    # compile lines, leaving it non-zero (so the zero-emission assertion stays
    # silent) but far below its real coverage.
    TARGET_COUNTS="$(st_counts_with asan-http 12)
"
    if enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: partial coverage loss (30 -> 12) did not trip the per-target floor"
        st_fail=1
    fi

    # A target counted but never pinned.
    TARGET_COUNTS="$(st_full_counts)
a_target_with_no_floor 40
"
    if enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: a target with no pinned floor was accepted"
        st_fail=1
    fi

    # The reverse direction: a target DELETED from TARGETS produces no count at
    # all, so 100% of its coverage vanishes while every FORWARD assertion still
    # passes on the survivors. Only the reverse loop can see it. Planted as the
    # real repro's shape — `http` gone, its floor left orphaned in the table.
    TARGET_COUNTS="$(st_counts_with http "")
"
    if enforce_target_floors >/dev/null 2>&1; then
        echo "SELFTEST FAILED: a pinned target that produced no count at all was accepted"
        st_fail=1
    fi

    # Enrollment (#921 round 3): a target the three lists never enrolled is
    # invisible to every OTHER assertion, so only this one can see it. Planted
    # against a synthetic Makefile via MAKEFILE_SRC — the real tree is untouched.
    st_mk="$st_work/Makefile.probe"
    printf '.PHONY: st_plugin\nst_plugin:\n\tgcc -Wall -O2 -c src/vm.c -o /tmp/st_plugin.o\n' > "$st_mk"

    st_saved_lines="$ALL_COMPILE_LINES"

    # Nothing audited emits that line -> must FAIL.
    ALL_COMPILE_LINES="gcc -O2 -c src/lexer.c -o build/lexer.o
"
    if MAKEFILE_SRC="$st_mk" enrollment_check >/dev/null 2>&1; then
        echo "SELFTEST FAILED: an unenrolled target emitting an unaudited compile was accepted"
        st_fail=1
    fi

    # An audited target DOES emit exactly that line -> must PASS (this is the
    # `all`/`test` case: they re-emit `build`'s lines and must not be flagged).
    ALL_COMPILE_LINES="gcc -Wall -O2 -c src/vm.c -o /tmp/st_plugin.o
"
    if ! MAKEFILE_SRC="$st_mk" enrollment_check >/dev/null 2>&1; then
        echo "SELFTEST FAILED: an unenrolled target re-emitting an AUDITED line was rejected"
        st_fail=1
    fi

    ALL_COMPILE_LINES="$st_saved_lines"

    TARGET_COUNTS="$st_saved_counts"

    if [ "$st_fail" -ne 0 ]; then
        exit 1
    fi
    echo "SELFTEST OK: all planted fault shapes caught (incl. target-batch divergence, two-invocation blocks, switch-enum, zero-line targets, partial per-target coverage loss, unpinned targets), clean shapes pass, floors bite in BOTH directions, unenrolled compile surfaces are caught"
    exit 0
fi

# Validate the target partition before any dry run so a hand-edited batch
# cannot silently reduce the gate's coverage.
validate_target_batches "$TARGETS" "${TARGET_BATCHES[@]}" || exit 1

# --print-counts regenerates TARGET_FLOORS. It deliberately drives ONE
# STANDALONE `make -n -B <target>` per target instead of reading the batched
# stream, because the batched stream is exactly what the floors exist to
# police: regenerating from it means that after a batch sibling swallows a
# target's compile lines, following this script's own documented repair
# workflow re-pins the DEGRADED number and launders the bug into the baseline.
# (Measured: under a planted batch-merge fault the batched path printed
# `embed-smoke-gfx 1` and exited 0.) Standalone runs cannot be corrupted that
# way — one goal per make invocation means no shared prerequisite can be
# emitted under a sibling. 22 dry runs cost seconds; correctness of the
# baseline is worth more than that.
if [ "${1:-}" = "--print-counts" ]; then
    echo "# Regenerated TARGET_FLOORS body — paste into TARGET_FLOORS (#921)."
    echo "# Source: STANDALONE 'make -n -B <target>' per target (never the batched stream)."
    pc_failed=0
    for t in $TARGETS; do
        if ! pc_dry=$(make -n -B --no-print-directory "$t" 2>&1); then
            echo "# GATE ERROR: 'make -n -B $t' exited nonzero — cannot count it" >&2
            pc_failed=1
            continue
        fi
        TARGET_EXAMINED=0
        audit_stream "$t" <<< "$(printf '%s\n' "$pc_dry" | join_continuations)" >/dev/null
        if [ "$TARGET_EXAMINED" -eq 0 ]; then
            echo "# GATE ERROR: target '$t' emitted no compile invocations standalone" >&2
            pc_failed=1
            continue
        fi
        echo "$t $TARGET_EXAMINED"
    done
    for sc in $SCRIPT_AUDITS; do
        [ -f "$sc" ] || { echo "# GATE ERROR: script '$sc' not found" >&2; pc_failed=1; continue; }
        TARGET_EXAMINED=0
        audit_stream "script:$sc" <<< "$(strip_comments < "$sc" | join_continuations)" >/dev/null
        # Same zero hard-fail the target leg has: emitting a floor of 0 for a
        # script whose compiles the extractor stopped seeing would pin the
        # blindness into the baseline as if it were the truth.
        if [ "$TARGET_EXAMINED" -eq 0 ]; then
            echo "# GATE ERROR: script '$sc' emitted no compile invocations" >&2
            pc_failed=1
            continue
        fi
        echo "script:$sc $TARGET_EXAMINED"
    done
    exit "$pc_failed"
fi

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

if [ "$make_failed" -ne 0 ] || [ "$empty_failed" -ne 0 ]; then
    exit 1
fi
require_minimum "$EXAMINED" || exit 1
enforce_target_floors || exit 1
recognizer_axis_parity || exit 1
recognizer_coverage_check || exit 1
enrollment_check || exit 1
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
