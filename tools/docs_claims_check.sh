#!/usr/bin/env bash
# docs_claims_check.sh — no hand-typed number, no dangling reference.
#
# THE RULE THIS ENFORCES: a number, path, flag, `make` target or `name of`
# call that appears in a front-door document is DERIVED FROM THE TREE, or it
# is waived by its exact line content with a reason. Nothing is believed
# because somebody typed it.
#
# Why it exists (measured on main f532c8d, 2026-09-16): README.md's first
# paragraph claimed a "~620K minimal binary" (built: 943K, the claim written
# 2026-04-24), a "44-widget GUI toolkit" (the registry registers 47), a
# "52-module standard library" (78 files in lib/) and "14 STEM" (a category
# with no definition anywhere in the tree). docs/llms.txt — the file every
# agent primes on — said "~255 builtins" against an index of 261, and
# CLAUDE.md called that file 190 lines long when it is 253. In the same
# window 643 commits touched src/ and 56 touched README.md; 114 commit
# subjects contain the word "drift", every one of them a hand sweep. Hand
# sweeps are the failure, not the fix.
#
# THE THREE CLASSES OF ANSWER, per claim:
#   DERIVED   the tool computed the number/path/name from the tree and it matches
#   WAIVED    an exact reviewed LINE, with a reason (mechanical-gates §125:
#             never a substring, or the waiver silently covers future lines)
#   RED       anything else, including a class whose population came back 0
#
# Enumeration discipline (mechanical-gates §121): every class asserts
# `examined == len(table) > 0` and prints both numbers, so a class that
# quietly stopped finding anything is a failure and not a silent pass.
#
# Cross-derivation (mechanical-gates §122): where a number could be derived
# from the same mechanism that consumes it, a SECOND independent route is
# computed and the two must agree — the widget count from the source grep AND
# from the runtime registry; the STEM tag set from the `# stdlib-tag: stem`
# headers AND from docs/STDLIB.md's own section membership; the path
# population's top-level segment list from a pinned table AND from
# `git ls-files`.
#
# Usage:
#   bash tools/docs_claims_check.sh              # the real doc set
#   bash tools/docs_claims_check.sh --selftest   # planted faults, each must go red
#   DOCS_CLAIMS_DOCS="a.md b.md" bash tools/docs_claims_check.sh
#                                                # override the doc set (the selftest's seam)
set -u

# Resolve BOTH paths before the cd: $0 may be relative to the caller's cwd, and
# the selftest re-invokes this script. The suite calls it by absolute path, so
# this never bit there — it bit the moment round 5 ran the selftest by hand
# from the runner's own cwd (`src/`), where every child exited 127.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "docs-claims: ABORTED: cannot cd to ROOT '$ROOT'" >&2; exit 1; }

# ---------------------------------------------------------------------------
# ROUND 8 — A FAILING GATE MUST SAY WHY, ON A MACHINE WE CANNOT RUN.
# macOS CI sat at rc=2 with 28 of 30 plants "ABSENT" for two rounds and the
# REASON WAS NEVER IN THE LOG: the tool died before printing anything, and the
# suite section grepped the captured output for "^RED", which a parse error or
# an early die matches neither. Two mechanisms now make that impossible:
#
#   * this banner, printed FIRST on every run — one line, cheap, and it lands
#     in the CI log. It names every fact a round-6-style guess needed;
#   * the EXIT trap below: if the script ends without having printed its
#     verdict line, it says so, with the exit code and the last command the
#     shell was running. An unexplained death is now a named death.
#
# ---------------------------------------------------------------------------
# THIS GATE NEVER READS STDIN, AND SAYS SO IN THE ONLY WAY THAT BINDS.
#
# Bought 2026-09-18, on main, by an enrolment round for a different gate. Five
# sites here were written as `x=$(grep -c .) <<< "$LIST"` -- the here-string is
# applied to the ASSIGNMENT, and the command substitution is expanded BEFORE
# any redirection, so `grep` read the SCRIPT's stdin instead of the list. Two
# faces, both silent:
#   * stdin is an open stream (a background job, a pipeline, a CI runner that
#     leaves it attached) -> `grep` blocks on a pipe that never closes and the
#     whole gate HANGS. Measured: 20 minutes, no output after the NUMBERS
#     class summary, and the portability audit that drives this gate under
#     bash 3.2 hung with it.
#   * stdin is /dev/null -> instant EOF, the count is 0, and the §121 guard
#     built on those counts compared 0 against 0 and PASSED. It had never been
#     able to fire.
# The sites are fixed. This line closes the CLASS rather than the instances:
# no future spelling of the same mistake can hang, because there is nothing on
# this script's stdin to block on -- it degrades to the zero, and the
# nonzero-population assertions below are what turn that zero red.
exec 0</dev/null

DC_VERDICT_PRINTED=0
dc_on_exit() {
    local rc=$?
    [ -n "${DC_ERRFILE:-}" ] && rm -f "$DC_ERRFILE"
    [ -n "${DC_FEEDFILE:-}" ] && rm -f "$DC_FEEDFILE"
    if [ "$DC_VERDICT_PRINTED" -eq 0 ]; then
        echo "docs-claims: ABORTED before printing a verdict (rc=$rc); last command: ${BASH_COMMAND:-<none>}" >&2
        echo "docs-claims: if this is a portability failure, the banner above names the shell and platform" >&2
    fi
    return $rc
}
trap 'dc_on_exit' EXIT

printf 'docs-claims env: bash %s, %s, %s, EIGS=%s, %s=%s\n' \
       "${BASH_VERSION:-unknown}" \
       "$(make --version 2>/dev/null | head -1 || echo 'make: unknown')" \
       "$(uname -s 2>/dev/null || echo 'uname: unknown') $(uname -r 2>/dev/null)" \
       "${EIGS:-<unset until probed>}" \
       "build/release/eigenscript" \
       "$([ -f build/release/eigenscript ] && echo present || echo ABSENT)"

# ROUND 7 — docs/CI.md IS A FRONT DOOR TOO. It is the page a contributor is
# sent to in order to learn what runs on their PR, and it was outside this
# gate entirely: four hand-typed numbers in it were already stale in the very
# diff that added them (third critic, `/code-review 1226 medium`, finding 7).
DOC_FILES_DEFAULT="README.md docs/llms.txt CLAUDE.md docs/ARCHITECTURE.md docs/BUILTINS.md docs/CONCURRENCY.md ROADMAP.md docs/CI.md"
DOC_FILES="${DOCS_CLAIMS_DOCS:-$DOC_FILES_DEFAULT}"

# THE ONE CLASS docs/CI.md IS EXEMPT FROM, AND WHY. The FLAGS class asks
# `eigenscript --help` about every `--flag` token it finds. That is the right
# question for a document ABOUT EIGENSCRIPT; docs/CI.md is a document about
# this repository's SHELL GATES, and 45 of its 50 flag tokens belong to other
# programs (`--selftest`, `--contract`, `--print-section-plan`, `--paginate`,
# `--without-bash-malloc`, ...). Enrolling it there would mean forty-five
# waivers whose reason is the same sentence, and a gate whose failures are
# mostly noise stops being read (mechanical-gates §13). So the exemption is
# NAMED here, it is one class wide, and the audit below asserts every entry is
# real, is enrolled for the other four classes, and actually fired — an
# exemption nothing uses is a waiver covering something nobody agreed to
# (§3). The other four classes DO walk it: PATHS, NUMBERS, MAKE TARGETS and
# NAMES all ask questions that are true of any document in this tree.
# The exemption is a property of the DOCUMENT, not of the run: it fires
# whenever the named document is in the set being walked, including the
# selftest's `DOCS_CLAIMS_DOCS="$DOC_FILES_DEFAULT"` control. Keying it on
# "DOCS_CLAIMS_DOCS is unset" took that control red on forty-five flags in
# this round's own first selftest — a gate whose own control cannot pass is
# not a gate yet.
DOC_FILES_FLAGS_EXEMPT_DEFAULT="docs/CI.md"
DOC_FILES_FLAGS_EXEMPT=""
for __x in $DOC_FILES_FLAGS_EXEMPT_DEFAULT; do
    case " $DOC_FILES " in
        *" $__x "*) DOC_FILES_FLAGS_EXEMPT="$DOC_FILES_FLAGS_EXEMPT $__x" ;;
    esac
done
DOC_FILES_FLAGS=""
for __d in $DOC_FILES; do
    __skip=0
    for __x in $DOC_FILES_FLAGS_EXEMPT; do
        [ "$__d" = "$__x" ] && __skip=1
    done
    [ "$__skip" -eq 1 ] || DOC_FILES_FLAGS="$DOC_FILES_FLAGS $__d"
done
unset __d __x __skip
# Whether this run covers the real doc set. The "a declared row was never
# visited" half of the declaration audit only means something then; the
# selftest drives copies of ONE document at a time and would otherwise drown
# every planted fault in unrelated reds (mechanical-gates §41 — a row must go
# red for ITS reason).
DOCSET_IS_DEFAULT=0
[ -z "${DOCS_CLAIMS_DOCS:-}" ] && DOCSET_IS_DEFAULT=1

# ---------------------------------------------------------------------------
# --selftest: plant each fault this gate exists to catch, through the REAL
# entry point (mechanical-gates §124 — driving the internals proves nothing
# about the command CI runs), and require RED plus the message that NAMES the
# offending line. Plus the control both directions: the real doc set must pass,
# and an EMPTY doc set must fail on the zero-population guard of every class
# (§121 — "some check ran" is what a gutted enumeration also prints).
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
    st_rc=0; st_cases=0; st_failed=0
    # ---------------------------------------------------------------------
    # ROUND 15 — THE SIZE ROWS ASSERT WHAT THIS PLATFORM ACTUALLY DOES.
    # Round 11 made the binary-size claim DEFER off Linux on purpose: the
    # README's number is a Linux minimal build and a Mach-O of the same source
    # is a different object format, not documentation drift. Four rows then
    # went on asserting MEASURED behaviour — "a wrong number is red", "it
    # measured, it did not defer" — and failed on macOS FOR BEING RIGHT, which
    # is the same shape round 12 fixed one level down when a row depended on
    # the lane's build state instead of building its own premise.
    #
    # So each of those rows now asserts the platform's real behaviour:
    #   Linux      measured; a wrong number is RED
    #   not Linux  deferred, the message NAMES the platform, and a planted
    #              wrong number does NOT red
    # Both are real properties. Neither branch is a skip: every row still RUNS,
    # still counts toward the pinned 36, and prints which branch it took — a
    # row that vanishes on a platform makes the pinned count a lie (§121, and
    # round 4's lesson that a count which changes meaning under failure is not
    # a count).
    st_uname=$(uname -s 2>/dev/null || echo unknown)
    st_linux=0
    [ "$st_uname" = "Linux" ] && st_linux=1
    printf '  selftest platform: uname=%s → the binary-size claim is %s here\n' \
           "$st_uname" \
           "$([ "$st_linux" -eq 1 ] && echo 'MEASURED (rows assert measurement)' || echo 'DEFERRED (rows assert the deferral)')"
    # ROUND 5 — WHERE THE SCRATCH LIVES IS PART OF THE TEST.
    # r4 put it in /tmp (`mktemp -d -t`) and hard-linked the repo into it. On
    # this box /tmp and the worktree are both /dev/sda6, so it worked; in the
    # CI container the workspace and /tmp are different mounts and a hard link
    # cannot cross a filesystem, so `cp -al` failed, `plant_tree` returned
    # early and the state-independence block was SKIPPED — 23 of 26 cases ran
    # on 13 CI jobs while the local ring was green (PR #1175).
    #
    # Two independent fixes, because either alone would have left a hole:
    #   1. put the scratch NEXT TO the repo, so it is normally the same
    #      filesystem (never INSIDE $ROOT — `cp -al $ROOT` into its own subtree
    #      recurses);
    #   2. if the hard-link copy fails anyway, make a REAL copy and SAY SO.
    #      A gate may be slower on a strange filesystem; it may not run fewer
    #      cases.
    st_scratch_root() {
        local cand
        for cand in "${EIGS_DOCS_SCRATCH_DIR:-}" "$(dirname "$ROOT")" "${TMPDIR:-/tmp}"; do
            [ -z "$cand" ] && continue
            [ -d "$cand" ] && [ -w "$cand" ] || continue
            case "$cand" in "$ROOT"|"$ROOT"/*) continue ;; esac
            printf '%s' "$cand"; return 0
        done
        printf '%s' "${TMPDIR:-/tmp}"
    }

    # The ONE place a scratch copy is made. Both call sites use it, so there is
    # a single place this can be wrong.
    st_copy_tree() { # src dst
        rm -rf "$2"
        if cp -al "$1" "$2" 2>/dev/null; then return 0; fi
        rm -rf "$2"
        # STDERR, not stdout: plant_tree returns its directory on stdout, so a
        # NOTE printed there is captured into the caller's `d=$(plant_tree …)`
        # and the next `cd "$d"` fails. Found by the /dev/shm run — the only
        # shape where this line is ever printed, which is precisely why the
        # cross-filesystem row and the forced run both exist.
        printf '  NOTE: hard-link copy of %s failed (different filesystem?); falling back to a real cp -a\n' "$1" >&2
        # NO 2>/dev/null: when the real copy fails too, its message is the
        # only thing that can explain why every later row read "ABSENT".
        cp -a "$1" "$2"
    }

    # `mktemp -d -p DIR TEMPLATE` is GNU-only: BSD mktemp has no -p, and its -t
    # takes a PREFIX rather than a template. A full path template is what both
    # accept, and it is what POSIX describes. (macOS CI, round 6: the tool died
    # here with rc 2 before doing anything, and 25 of 27 plants read "ABSENT".)
    st_dir="$(mktemp -d "$(st_scratch_root)/eigs_docs_claims_selftest.XXXXXX")"
    # No `stat -c %d` here: that flag is GNU-only (BSD spells it -f %d), and the
    # device numbers were only ever decoration. The design already DETECTS the
    # cross-filesystem case by DOING it — attempt the hard-link copy, fall back
    # when it fails — which is a behaviour test rather than a platform quiz.
    printf '  selftest scratch: %s\n' "$st_dir"
    # INT/TERM as well as EXIT: the scratch now lives beside the repo, so a
    # killed run must not leave a 24 MB copy next to the worktrees.
    trap 'rm -rf "$st_dir"' EXIT INT TERM

    st_case() { # name  doc-set  want-rc  want-substring
        st_cases=$((st_cases + 1))
        local name="$1" docs="$2" want_rc="$3" want_txt="$4" out got_rc
        out=$(DOCS_CLAIMS_DOCS="$docs" bash "$SELF" 2>&1); got_rc=$?
        if [ "$got_rc" -eq "$want_rc" ] && grep -qF -- "$want_txt" <<< "$out"; then
            printf '  selftest ok: %s\n' "$name"
        else
            printf '  SELFTEST FAIL: %s -- rc=%d (want %d), %s\n' \
                   "$name" "$got_rc" "$want_rc" \
                   "$(grep -qF -- "$want_txt" <<< "$out" && echo 'text present' || echo "text $want_txt ABSENT")"
            grep -E '^(RED|docs-claims:)' <<< "$out" | head -6 | sed 's/^/        /'
            st_rc=1; st_failed=$((st_failed + 1))
        fi
    }

    # Plant inside a hard-linked COPY of the whole tree, so relative Markdown
    # links resolve the way they do in the real repository. The bare-tempdir
    # `plant` below cannot host a link case: `dirname` is then the temp dir and
    # EVERY link in the document is dangling, which drowns the planted one.
    # The replaced file is UNLINKED first and rewritten, never edited in place —
    # the copy shares inodes with the tree.
    plant_tree() { # relpath  sed-expr   -> echoes the copy dir
        local rel="$1" expr="$2" dir="$st_dir/t$st_cases"
        if ! st_copy_tree "$ROOT" "$dir"; then
            printf '  SELFTEST FAIL: could not make a scratch copy of the tree for %s\n' "$rel" >&2
            st_rc=1; st_failed=$((st_failed + 1))
        fi
        local tmp="$dir/.plant.tmp"
        sed "$expr" "$ROOT/$rel" > "$tmp"
        if cmp -s "$tmp" "$ROOT/$rel"; then
            printf '  SELFTEST FAIL: plant_tree %s did not change %s\n' "$expr" "$rel" >&2
            st_rc=1; st_failed=$((st_failed + 1))
        fi
        rm -f "$dir/$rel"
        mv "$tmp" "$dir/$rel"
        printf '%s' "$dir"
    }

    st_case_tree() { # name  dir  want-rc  want-substring
        st_cases=$((st_cases + 1))
        local name="$1" dir="$2" want_rc="$3" want_txt="$4" out got_rc
        out=$(cd "$dir" && bash tools/docs_claims_check.sh 2>&1); got_rc=$?
        if [ "$got_rc" -eq "$want_rc" ] && grep -qF -- "$want_txt" <<< "$out"; then
            printf '  selftest ok: %s\n' "$name"
        else
            printf '  SELFTEST FAIL: %s -- rc=%d (want %d)\n' "$name" "$got_rc" "$want_rc"
            grep -E '^(RED|docs-claims:)' <<< "$out" | head -4 | sed 's/^/        /'
            st_rc=1; st_failed=$((st_failed + 1))
        fi
        rm -rf "$dir"
    }

    plant() { # outfile  sed-expr  [source]
        local out="$st_dir/$1" src="${3:-README.md}"
        sed "$2" "$src" > "$out"
        # A plant that changed nothing proves nothing (mechanical-gates §20).
        if cmp -s "$out" "$src"; then
            printf '  SELFTEST FAIL: plant %s did not change %s -- the fault was never planted\n' "$1" "$src" >&2
            st_rc=1
        fi
        printf '%s' "$out"
    }

    # Control FIRST: the real doc set is green. Without it every row below
    # would also pass against a gate that always failed.
    st_case "control: the real doc set passes" "$DOC_FILES_DEFAULT" 0 "docs-claims: OK"

    p=$(plant "README.md" 's/47-widget GUI toolkit, embedded/44-widget GUI toolkit, embedded/')
    st_case "planted wrong number goes red and names the line" \
            "$p" 1 "claims '44-widget' but D_WIDGETS derives 47"

    # docs/CI.md IS WALKED — the enrolment of round 7, proven rather than
    # declared. Until then the page a contributor is sent to for "what runs on
    # my PR" was outside the gate, and four of its hand-typed numbers were
    # stale in the diff that wrote them (third critic, `/code-review 1226
    # medium`, finding 7). The planted number sits on the one line of that
    # page the gate now DERIVES, so a doc set that quietly drops docs/CI.md
    # takes this case green.
    # The pattern matches the NUMBER, not one value of it: a plant that
    # hardcodes today's count breaks the moment a PR adds a test section, and
    # then reports "the fault was never planted" — which is what happened to
    # the next PR that added one (261 -> 262). A plant may not hand-type a
    # number the gate derives, for the same reason a doc may not.
    p=$(plant "CI.md" 's/All [0-9][0-9]* test sections\./All 999 test sections./' "docs/CI.md")
    st_case "planted wrong number in the enrolled docs/CI.md goes red" \
            "$p" 1 "claims '999 test sections' but D_SECTIONS derives"

    p=$(plant "README.md" 's|`src/embed_smoke.c`|`src/no_such_source.c`|')
    st_case "planted dangling path goes red and names the path" \
            "$p" 1 "references src/no_such_source.c, which git does not track and no Makefile rule produces"

    p=$(plant "README.md" 's/eigenscript --version/eigenscript --no-such-flag/')
    st_case "planted unknown CLI flag goes red" \
            "$p" 1 "documents '--no-such-flag'"

    p=$(plant "README.md" 's/^make test  /make nosuchtarget /')
    st_case "planted unknown make target goes red" \
            "$p" 1 "documents 'make nosuchtarget'"

    p=$(plant "README.md" 's/`sort_by of \[items, key_fn\]`/`no_such_builtin of [items, key_fn]`/' docs/llms.txt)
    st_case "planted unresolvable \`name of\` call goes red" \
            "$p" 1 "calls \`no_such_builtin of ...\`"

    # BUILTIN FAMILIES (#1227). docs/BUILTINS.md's UDP sentence is a NEGATIVE
    # claim and is waived by its exact line. Turn it into a shipping claim —
    # the shape ROADMAP.md carried at 5213ba3 — and the waiver stops matching,
    # so the family claim is judged and goes red by name against `--api`.
    p=$(plant "BUILTINS.md" 's/UDP is not yet exposed/UDP datagram sockets are exposed and shipped/' docs/BUILTINS.md)
    st_case "planted 'UDP shipped' family claim goes red" \
            "$p" 1 "names the builtin family udp"

    # Zero population, one class at a time is not enough: a doc with NOTHING in
    # it must trip every class's guard, and each message is asserted by name.
    : > "$st_dir/EMPTY.md"
    printf 'nothing to see here\n' >> "$st_dir/EMPTY.md"
    for cls in \
        "class NUMBERS examined 0" \
        "class PATHS examined 0" \
        "class FLAGS examined 0" \
        "class MAKE TARGETS examined 0" \
        "class NAMES examined 0"
    do
        st_case "zero population is red: $cls" "$st_dir/EMPTY.md" 1 "$cls"
    done

    # ---- ROUND 2 (Astra G1): the population must not be able to SHRINK ----
    # The r1 gate asserted "everything found is accounted for" and never "the
    # count is the DECLARED one", so deleting a waived line took NUMBERS from
    # 24 to 23 and the gate still exited 0. Four plants, one per direction.
    p=$(plant "README.md" '/a 47-widget GUI toolkit, embedded database, tensor math,/d')
    st_case "DELETING a derived claim goes red (the population shrank)" \
            "$p" 1 "NUMBERS/README.md found 12 but 13 is declared"

    p=$(plant "CLAUDE.md" '/^DMG is 3,288 lines, of which 818 are compiled/d' CLAUDE.md)
    st_case "DELETING a waived claim goes red (the population shrank)" \
            "$p" 1 "NUMBERS/CLAUDE.md found 2 but 3 is declared"
    st_case "...and the now-unmatched waiver is named with its line" \
            "$p" 1 "matched NOTHING — the reviewed line is gone or edited"

    p=$(plant "README.md" 's|^This builds a ~940K minimal binary|It ships 4 widgets extra. This builds a ~940K minimal binary|')
    st_case "ADDING a number is red until it is declared" \
            "$p" 1 "NUMBERS/README.md found 14 but 13 is declared"

    # ---- ROUND 2 (Astra G6): the two widened populations ----
    p=$(plant "README.md" '/^## Install$/a\'$'\n''Pass --ver to print the version.')
    st_case "a bare unknown --flag in prose goes red (G6a: not only the backticked form)" \
            "$p" 1 "documents '--ver'"

    d=$(plant_tree "README.md" 's|(docs/CONCURRENCY.md)|(docs/NOPE.md)|')
    st_case_tree "a dangling Markdown LINK target goes red (G6b)" \
            "$d" 1 "references docs/NOPE.md, which git does not track and no Makefile rule produces"

    # ---- ROUND 4 (H2): the verdict must not depend on BUILD STATE ----
    # This is the defect the exit ring caught and no standalone run could: the
    # gate was rc 0 from a clean tree and rc 1 inside the suite, because suite
    # section [88] builds src/eigenlsp and the old PATHS class asked the
    # FILESYSTEM. The copy below is made by st_copy_tree: hard-linked when the
    # scratch is on the repo's own filesystem (~1 s, no data copied), a real
    # `cp -a` otherwise, announced either way. Only CREATE and UNLINK happen in
    # it, never an edit — under the hard-link path the files ARE the tree's
    # inodes.
    st_copy="$st_dir/tree"
    if ! st_copy_tree "$ROOT" "$st_copy"; then
        printf '  SELFTEST FAIL: could not make a scratch copy of the tree; the build-state rows CANNOT be skipped\n'
        st_rc=1; st_failed=$((st_failed + 1))
    fi
    if [ -d "$st_copy" ]; then
        rm -f "$st_copy/src/eigenlsp" "$st_copy/src/eigsdap"
        absent_out=$(cd "$st_copy" && bash tools/docs_claims_check.sh 2>&1)
        absent_rc=$?
        : > "$st_copy/src/eigenlsp"; : > "$st_copy/src/eigsdap"
        present_out=$(cd "$st_copy" && bash tools/docs_claims_check.sh 2>&1)
        present_rc=$?

        st_cases=$((st_cases + 1))
        if [ "$absent_rc" -eq 0 ]; then
            printf '  selftest ok: the real doc set is green with build products ABSENT\n'
        else
            printf '  SELFTEST FAIL: green expected with build products absent, rc=%d\n' "$absent_rc"
            grep '^RED' <<< "$absent_out" | head -4 | sed 's/^/        /'
            st_rc=1; st_failed=$((st_failed + 1))
        fi

        st_cases=$((st_cases + 1))
        if [ "$present_rc" -eq 0 ]; then
            printf '  selftest ok: the real doc set is green with build products PRESENT\n'
        else
            printf '  SELFTEST FAIL: green expected with build products present, rc=%d\n' "$present_rc"
            grep '^RED' <<< "$present_out" | head -4 | sed 's/^/        /'
            st_rc=1; st_failed=$((st_failed + 1))
        fi

        # Same rc is not enough: the OUTPUT must be identical, or some line is
        # still reading the filesystem and only happens not to fail yet.
        #
        # ROUND 15: this property holds on EVERY platform — off Linux both
        # states defer, so the two runs should be identical for that reason
        # instead of for the measured one. It is the one row of the four that
        # needs no platform branch; what it needed was to carry its evidence.
        # The diff was capped at 8 lines and the size lines were not quoted, so
        # a macOS failure said only that something differed. Both are fixed:
        # the WHOLE diff goes out, and each run's size verdict is named.
        st_cases=$((st_cases + 1))
        if [ "$absent_out" = "$present_out" ]; then
            printf '  selftest ok: both build states produce byte-identical output (size claim %s on %s)\n' \
                   "$([ "$st_linux" -eq 1 ] && echo measured || echo deferred)" "$st_uname"
        else
            printf '  SELFTEST FAIL: build state changed the gate output (uname=%s)\n' "$st_uname"
            printf '        absent  size line: %s\n' "$(grep 'minimal binary' <<< "$absent_out" | head -1)"
            printf '        present size line: %s\n' "$(grep 'minimal binary' <<< "$present_out" | head -1)"
            printf '        the complete diff follows (absent < , present > ):\n'
            diff <(printf '%s\n' "$absent_out") <(printf '%s\n' "$present_out") \
                 | sed 's/^/        /'
            st_rc=1; st_failed=$((st_failed + 1))
        fi

        # A tracked SOURCE path that is missing from the working tree is still
        # red — the build-product carve-out must not have widened into one.
        rm -f "$st_copy/src/embed_smoke.c"
        st_cases=$((st_cases + 1))
        miss_out=$(cd "$st_copy" && bash tools/docs_claims_check.sh 2>&1)
        if [ $? -ne 0 ] && grep -qF "git tracks but is missing from the working tree" <<< "$miss_out"; then
            printf '  selftest ok: a tracked source path missing from the tree is still red\n'
        else
            printf '  SELFTEST FAIL: a missing tracked source path did NOT go red\n'
            st_rc=1; st_failed=$((st_failed + 1))
        fi
        rm -rf "$st_copy"
    fi

    # ---- ROUND 7 (H1): the size claim is release-only, and DEFERRING is pinned --
    # The ASan shard measured the ASan binary through src/eigenscript (a hard
    # link to the last-built variant) and reported 28721K against a 940K claim.
    # Three rows: the claim is CHECKED where release exists, DEFERRED exactly
    # once where it does not, and a second deferral is red.
    #
    # ROUND 11 (H3): three binary STATES, one row each, because round 7's
    # deferral turned out to cover every lane there is.
    #   build.sh product  src/eigenscript, sharing no build/*/eigenscript inode
    #                     -> MEASURED. This is what every CI lane has.
    #   release objdir    build/release/eigenscript present -> MEASURED.
    #   variant alias     src/eigenscript hard-linked to build/<v>/eigenscript
    #                     -> DEFERRED, naming the variant. A sanitizer build is
    #                     a legitimate lane state, not a documentation error;
    #                     reddening the ASan shard for it would be §13.
    st_rel="$st_dir/norelease"
    if st_copy_tree "$ROOT" "$st_rel"; then
        # The variant-alias state: no release objdir, and src/eigenscript IS
        # the asan variant's binary. `ln` (not cp) is the point — the whole
        # decision is an inode identity.
        rm -rf "$st_rel/build/release"
        mkdir -p "$st_rel/build/asan"
        rm -f "$st_rel/build/asan/eigenscript"
        ln "$st_rel/src/eigenscript" "$st_rel/build/asan/eigenscript"

        st_cases=$((st_cases + 1))
        out=$(cd "$st_rel" && bash tools/docs_claims_check.sh 2>&1); rc=$?
        if [ "$rc" -eq 0 ] \
           && grep -qF "DEFERRALS: 1 claim(s) need an install-shaped binary, 1 declared" <<< "$out" \
           && grep -qF "hard link to build/asan/eigenscript" <<< "$out"; then
            printf '  selftest ok: a src/eigenscript that is a VARIANT alias defers exactly 1 claim and names the variant\n'
        else
            printf '  SELFTEST FAIL: a variant-alias lane did not defer exactly 1 claim naming the variant (rc=%d)\n' "$rc"
            grep -E '^RED|DEFERRAL|minimal binary|NUMBERS:' <<< "$out" | head -5 | sed 's/^/        /'
            st_rc=1; st_failed=$((st_failed + 1))
        fi

        # A SECOND deferral must be red: bump the declared count and the pin
        # fires in the other direction (mechanical-gates §129, both ways).
        sed 's|^RELEASE_ONLY_DECLARED=1|RELEASE_ONLY_DECLARED=2|' \
            "$ROOT/tools/docs_claims_check.sh" > "$st_rel/tools/docs_claims_check.sh.new"
        mv "$st_rel/tools/docs_claims_check.sh.new" "$st_rel/tools/docs_claims_check.sh"
        st_cases=$((st_cases + 1))
        out=$(cd "$st_rel" && bash tools/docs_claims_check.sh 2>&1); rc=$?
        if [ "$rc" -ne 0 ] && grep -qF "but 2 binary-size claim(s) are declared" <<< "$out"; then
            printf '  selftest ok: a deferral count that does not match its declaration is red\n'
        else
            printf '  SELFTEST FAIL: an over-declared deferral count did NOT go red (rc=%d)\n' "$rc"
            st_rc=1; st_failed=$((st_failed + 1))
        fi
        rm -rf "$st_rel"
    else
        printf '  SELFTEST FAIL: could not make a scratch copy for the release-binary rows\n'
        st_rc=1; st_failed=$((st_failed + 2)); st_cases=$((st_cases + 2))
    fi

    # And WITH a release binary present, a wrong size number is still red.
    #
    # ROUND 8: this row USED TO LIE. It planted the wrong number but ran against
    # whatever ROOT happened to hold, and on the gcc runner build/release was
    # absent — so the claim DEFERRED, the red came from the deferral count, and
    # the row asserted a size-mismatch message it could not produce
    # ("text claims '300K' but D_BIN_K derives ABSENT"). The exit code was
    # right and the reason was wrong, which is the worst kind of green.
    # The row now BRINGS its own release binary, so it tests what it names on
    # every lane. A 900 KiB stub is enough: the derivation only stats the file.
    d=$(plant_tree "README.md" 's|This builds a ~940K minimal binary|This builds a ~300K minimal binary|')
    if [ -n "$d" ] && [ -d "$d" ]; then
        mkdir -p "$d/build/release"
        # UNLINK first: the copy is hard-linked to the real tree, so writing
        # through this name without removing it would truncate the REAL binary.
        rm -f "$d/build/release/eigenscript"
        dd if=/dev/zero of="$d/build/release/eigenscript" bs=1024 count=900 2>/dev/null
        chmod +x "$d/build/release/eigenscript"
    fi
    if [ "$st_linux" -eq 1 ]; then
        st_case_tree "with a release binary present, a wrong size number is red" \
                "$d" 1 "claims '300K' but D_BIN_K derives 900"
    else
        # Off Linux the same planted 300K must NOT red, and the gate must say
        # why in its own words. That is the assertion, not a skip: it proves
        # the deferral is REACHED and NAMED even when a release binary is
        # sitting right there to be measured.
        st_case_tree "with a release binary present, off Linux the wrong size number DEFERS and names the platform" \
                "$d" 0 "the claim is a Linux minimal build and this is $st_uname"
    fi

    # STATE: the ./build.sh product — no build/ objdirs at all, src/eigenscript
    # standing alone. THIS IS WHAT EVERY CI LANE HAS, and until this round it
    # was the state in which the claim silently deferred.
    st_bsh="$st_dir/buildsh"
    if st_copy_tree "$ROOT" "$st_bsh"; then
        rm -rf "$st_bsh/build"
        # ROUND 12 (H2): THE ROW BUILDS ITS OWN PREMISE.
        # The first cut asserted rc 0 against the tree's real README, whose
        # "~940K" describes a RELEASE binary. On the ASan shard src/eigenscript
        # is the 28 MB sanitizer build, so the gate measured it, disagreed with
        # the document — correctly — and the row failed for being right. That
        # is the same mistake the size claim itself made one level up: depend
        # on the lane's build state instead of constructing the state under
        # test. The row now derives the number it plants FROM THE BINARY THIS
        # LANE ACTUALLY HAS, so what it tests is the RESOLUTION (is this the
        # build.sh product?) on every lane, which is what it claims to test.
        st_cases=$((st_cases + 1))
        bsh_k=0
        if [ ! -f "$st_bsh/src/eigenscript" ]; then
            printf '  SELFTEST FAIL: the build.sh-product row has no src/eigenscript to construct its premise from\n'
            st_rc=1; st_failed=$((st_failed + 1))
        else
            bsh_bytes=$(wc -c < "$st_bsh/src/eigenscript" | tr -d ' ')
            bsh_k=$(( (bsh_bytes + 1023) / 1024 ))
            sed "s|This builds a ~940K minimal binary|This builds a ~${bsh_k}K minimal binary|" \
                "$ROOT/README.md" > "$st_bsh/.plant.tmp"
            rm -f "$st_bsh/README.md"; mv "$st_bsh/.plant.tmp" "$st_bsh/README.md"
            out=$(cd "$st_bsh" && bash tools/docs_claims_check.sh 2>&1); rc=$?
            # ROUND 15: on Linux the claim is MEASURED, so the row asserts the
            # measurement. Off Linux it DEFERS by design, so the row asserts
            # the deferral and that the deferral NAMES the platform. Same row,
            # same count, the assertion the platform actually supports.
            if [ "$st_linux" -eq 1 ]; then
                if [ "$rc" -eq 0 ] \
                   && grep -qF "DEFERRALS: 0 — this lane measured src/eigenscript" <<< "$out" \
                   && grep -qF "it is the ./build.sh product" <<< "$out"; then
                    printf '  selftest ok: a bare src/eigenscript is MEASURED as the build.sh product, not deferred (premise built here: %sK)\n' "$bsh_k"
                else
                    printf '  SELFTEST FAIL: the build.sh-product state did not measure src/eigenscript (rc=%d, planted %sK)\n' "$rc" "$bsh_k"
                    grep -E '^RED|DEFERRAL|minimal binary' <<< "$out" | head -5 | sed 's/^/        /'
                    st_rc=1; st_failed=$((st_failed + 1))
                fi
            else
                if [ "$rc" -eq 0 ] \
                   && grep -qF "DEFERRALS: 1 claim(s) need an install-shaped binary, 1 declared" <<< "$out" \
                   && grep -qF "the claim is a Linux minimal build and this is $st_uname" <<< "$out"; then
                    printf '  selftest ok: off %s a bare src/eigenscript DEFERS exactly 1 claim and names the platform (premise built here: %sK)\n' "$st_uname" "$bsh_k"
                else
                    printf '  SELFTEST FAIL: off %s the build.sh-product state did not defer exactly 1 claim naming the platform (rc=%d, planted %sK)\n' "$st_uname" "$rc" "$bsh_k"
                    grep -E '^RED|DEFERRAL|minimal binary' <<< "$out" | head -5 | sed 's/^/        /'
                    st_rc=1; st_failed=$((st_failed + 1))
                fi
            fi
        fi

        # ...and the measurement BITES there. A row that only checks "it did
        # not defer" would pass for a lane that measured and then ignored the
        # answer (mechanical-gates §20). The WRONG number is derived from the
        # right one for the same reason the right one is derived from the
        # binary: a fixed 300 would be a silent pass on a lane whose binary
        # happens to be ~300K.
        st_cases=$((st_cases + 1))
        if [ "$bsh_k" -gt 0 ]; then wrong_k=$((bsh_k * 3 + 7)); else wrong_k=300; fi
        sed "s|This builds a ~940K minimal binary|This builds a ~${wrong_k}K minimal binary|" \
            "$ROOT/README.md" > "$st_bsh/.plant.tmp"
        rm -f "$st_bsh/README.md"; mv "$st_bsh/.plant.tmp" "$st_bsh/README.md"
        out=$(cd "$st_bsh" && bash tools/docs_claims_check.sh 2>&1); rc=$?
        # ROUND 15: on Linux the wrong number must RED. Off Linux it must NOT —
        # and that is the stronger half of the deferral's contract, because a
        # deferral that still reddened a wrong number would not be a deferral.
        # The row asserts the absence of the size RED specifically, not merely
        # rc 0, so an unrelated red cannot pass it off (§41).
        if [ "$st_linux" -eq 1 ]; then
            if [ "$rc" -ne 0 ] && grep -qF "claims '${wrong_k}K' but D_BIN_K derives" <<< "$out"; then
                printf '  selftest ok: a wrong size number is RED against the build.sh product (planted %sK against %sK)\n' "$wrong_k" "$bsh_k"
            else
                printf '  SELFTEST FAIL: the build.sh-product state did not red a wrong size number (rc=%d, planted %sK)\n' "$rc" "$wrong_k"
                grep -E '^RED|DEFERRAL|minimal binary' <<< "$out" | head -5 | sed 's/^/        /'
                st_rc=1; st_failed=$((st_failed + 1))
            fi
        else
            if [ "$rc" -eq 0 ] \
               && ! grep -qF "claims '${wrong_k}K' but D_BIN_K derives" <<< "$out" \
               && grep -qF "the claim is a Linux minimal build and this is $st_uname" <<< "$out"; then
                printf '  selftest ok: off %s a wrong size number does NOT red — the deferral holds against a planted %sK (binary is %sK)\n' "$st_uname" "$wrong_k" "$bsh_k"
            else
                printf '  SELFTEST FAIL: off %s a planted wrong size number was not deferred cleanly (rc=%d, planted %sK)\n' "$st_uname" "$rc" "$wrong_k"
                grep -E '^RED|DEFERRAL|minimal binary' <<< "$out" | head -5 | sed 's/^/        /'
                st_rc=1; st_failed=$((st_failed + 1))
            fi
        fi

        # STATE: not Linux. The claim is a Linux minimal build; a Mach-O of the
        # same source is a different object format, not drift. This box cannot
        # boot macOS, so the row substitutes `uname` on PATH rather than adding
        # a production seam that could switch the check off.
        st_cases=$((st_cases + 1))
        mkdir -p "$st_dir/fakebin"
        printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -r) echo 24.0.0 ;; *) echo Darwin ;; esac\n' \
            > "$st_dir/fakebin/uname"
        chmod +x "$st_dir/fakebin/uname"
        out=$(cd "$st_bsh" && PATH="$st_dir/fakebin:$PATH" bash tools/docs_claims_check.sh 2>&1); rc=$?
        if [ "$rc" -eq 0 ] \
           && grep -qF "the claim is a Linux minimal build and this is Darwin" <<< "$out"; then
            printf '  selftest ok: off Linux the size claim DEFERS and says so (the planted wrong size does not red there)\n'
        else
            printf '  SELFTEST FAIL: a non-Linux lane did not defer the size claim (rc=%d)\n' "$rc"
            grep -E '^RED|DEFERRAL|minimal binary' <<< "$out" | head -5 | sed 's/^/        /'
            st_rc=1; st_failed=$((st_failed + 1))
        fi
        rm -rf "$st_bsh"
    else
        printf '  SELFTEST FAIL: could not make a scratch copy for the build.sh-product rows\n'
        st_rc=1; st_failed=$((st_failed + 3)); st_cases=$((st_cases + 3))
    fi

    # ---- ROUND 5 (H2): the scratch copy must survive a DIFFERENT filesystem --
    # This is the regression test for PR #1175's 13 red CI jobs. /dev/shm is
    # tmpfs and is on every runner, so it gives a second filesystem locally;
    # the row requires st_copy_tree to SUCCEED across it and to ANNOUNCE the
    # fallback. A gate is allowed to be slower somewhere strange. It is not
    # allowed to run fewer cases there.
    st_cases=$((st_cases + 1))
    st_shm="/dev/shm/eigs_docs_xdev.$$"
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
        # Whether /dev/shm is a DIFFERENT filesystem is decided by doing the
        # copy, not by comparing device numbers (`stat -c %d` is GNU-only).
        # If it turns out to be the same device the hard link succeeds, no
        # fallback is announced, and the row says so — it still COUNTS.
        xdev_out=$(st_copy_tree "$ROOT/docs" "$st_shm" 2>&1)
        xdev_rc=$?
        if [ "$xdev_rc" -ne 0 ] || [ ! -f "$st_shm/CI.md" ]; then
            printf '  SELFTEST FAIL: scratch copy onto /dev/shm failed outright (rc=%d, file present=%s)\n' \
                   "$xdev_rc" "$([ -f "$st_shm/CI.md" ] && echo yes || echo NO)"
            st_rc=1; st_failed=$((st_failed + 1))
        elif grep -qF "falling back to a real cp -a" <<< "$xdev_out"; then
            printf '  selftest ok: a scratch copy onto a DIFFERENT filesystem falls back and is announced\n'
        else
            printf '  selftest ok: /dev/shm is the same filesystem here, so the hard link succeeded — st_copy_tree still delivered the copy\n'
        fi
        rm -rf "$st_shm"
    else
        # Not a skip: the case still counts, and says why it could not run the
        # hard version. A row that vanishes is what round 4 made impossible.
        printf '  selftest ok: cross-filesystem row: /dev/shm absent or unwritable — st_copy_tree unchanged\n'
    fi

    # A path that LOOKS like a build product but that no rule produces is red.
    p=$(plant "README.md" 's|`src/embed_smoke.c`|`src/no_such_product`|')
    st_case "a build-product-shaped path no Makefile rule produces is red" \
            "$p" 1 "which git does not track and no Makefile rule produces"

    # ---- ROUND 3 (Astra H1): the critic's own mutant ----
    # A link that resolves ONLY at the repo root is a broken link. The round-2
    # cut tried the root as a fallback and passed it.
    d=$(plant_tree "docs/BUILTINS.md" '11s|](STDLIB.md)|](docs/STDLIB.md)|')
    st_case_tree "wrong-relative-base: a link that resolves only at the ROOT is red" \
            "$d" 1 "docs/docs/STDLIB.md, which git does not track"

    # ---- ROUND 3 (Astra H2): the enrolment class must pin BOTH directions ----
    # A declared row matching nothing used to pass here (the fence checker
    # caught it separately, but the class that DECLARES the population has to
    # catch its own — mechanical-gates §129).
    sed 's|^    "docs/BUILTINS.md":|    "docs/GRAMMAR.md":          (  1,    1,     0,      0,      0),\n    "docs/BUILTINS.md":|' \
        tests/test_doc_examples.py > "$st_dir/poptable13.py"
    if cmp -s "$st_dir/poptable13.py" tests/test_doc_examples.py; then
        printf '  SELFTEST FAIL: the 13th-POPULATION-row plant changed nothing\n' >&2
        st_rc=1
    fi
    st_cases=$((st_cases + 1))
    st_out=$(DOCS_CLAIMS_POPTABLE="$st_dir/poptable13.py" bash "$SELF" 2>&1)
    if [ $? -ne 0 ] && grep -qF "carries NO eigenscript fence" <<< "$st_out"; then
        printf '  selftest ok: a declared POPULATION row matching nothing is red (H2)\n'
    else
        printf '  SELFTEST FAIL: a POPULATION row for a fence-less document did NOT go red\n'
        grep -E '^RED|ENROLMENT' <<< "$st_out" | head -4 | sed 's/^/        /'
        st_rc=1; st_failed=$((st_failed + 1))
    fi

    # A document with fences and no pinned row must be red. The fault is
    # planted in the TABLE rather than in the tree: writing a doc/*.md into the
    # repository to test a gate would make the gate mutate what it checks
    # (mechanical-gates §22).
    sed '/"docs\/SYNTAX.md":/d' tests/test_doc_examples.py > "$st_dir/poptable.py"
    if cmp -s "$st_dir/poptable.py" tests/test_doc_examples.py; then
        printf '  SELFTEST FAIL: the POPULATION-row plant changed nothing\n' >&2
        st_rc=1
    fi
    st_cases=$((st_cases + 1))
    st_out=$(DOCS_CLAIMS_POPTABLE="$st_dir/poptable.py" bash "$SELF" 2>&1)
    if [ $? -ne 0 ] && grep -qF "has no row in" <<< "$st_out"; then
        printf '  selftest ok: an unenrolled document goes red\n'
    else
        printf '  SELFTEST FAIL: an unenrolled document did NOT go red\n'
        st_rc=1; st_failed=$((st_failed + 1))
    fi

    # ---- ROUND 11 (H1): a scan that FAILS must not read as "nothing found" --
    # The macOS break was a fence scan whose grep rejected the pattern with
    # `2>/dev/null` on it: zero fences everywhere, and the reason discarded.
    # The plant breaks the counter itself and requires the RED to QUOTE the
    # counter's own diagnostic — not merely to notice an empty population.
    sed '1i\
import sys; raise SystemExit("planted: this counter cannot run")' \
        tests/test_doc_examples.py > "$st_dir/badcounter.py"
    if cmp -s "$st_dir/badcounter.py" tests/test_doc_examples.py; then
        printf '  SELFTEST FAIL: the broken-fence-counter plant changed nothing\n' >&2
        st_rc=1
    fi
    st_cases=$((st_cases + 1))
    st_out=$(DOCS_CLAIMS_POPTABLE="$st_dir/badcounter.py" bash "$SELF" 2>&1)
    if [ $? -ne 0 ] \
       && grep -qF "the scan itself failed" <<< "$st_out" \
       && grep -qF "planted: this counter cannot run" <<< "$st_out"; then
        printf '  selftest ok: a fence counter that cannot run is RED and the message is QUOTED, not discarded\n'
    else
        printf '  SELFTEST FAIL: a broken fence counter did not produce a red naming its own diagnostic\n'
        grep -E '^RED|ENROLMENT|fence counter' <<< "$st_out" | head -4 | sed 's/^/        /'
        st_rc=1; st_failed=$((st_failed + 1))
    fi

    # ---- ROUND 13 (H1): a class that DOES NOT RUN is named in ONE line -------
    # Three CI rounds, one macOS red, and all the log ever showed was six
    # "declared population PATHS/... was never visited" consequence-REDs from
    # an audit far below the class, inside a 20-line tail. The plant makes the
    # PATHS class examine normally and RECORD NOTHING — the exact shape the
    # declaration audit was reporting second-hand — and requires the summary
    # block, which is printed LAST and therefore survives any window, to say so
    # in its own sentence.
    st_norecord="$st_dir/norecord"
    st_cases=$((st_cases + 1))
    if st_copy_tree "$ROOT" "$st_norecord"; then
        sed 's|^    record_found PATHS "$f" "$per"$|    :|' \
            "$ROOT/tools/docs_claims_check.sh" > "$st_norecord/tools/docs_claims_check.sh.new"
        if cmp -s "$st_norecord/tools/docs_claims_check.sh.new" "$ROOT/tools/docs_claims_check.sh"; then
            printf '  SELFTEST FAIL: the class-does-not-record plant changed nothing — the PATHS record line moved\n' >&2
            st_rc=1; st_failed=$((st_failed + 1))
        else
            rm -f "$st_norecord/tools/docs_claims_check.sh"
            mv "$st_norecord/tools/docs_claims_check.sh.new" "$st_norecord/tools/docs_claims_check.sh"
            out=$(cd "$st_norecord" && bash tools/docs_claims_check.sh 2>&1); rc=$?
            # The doc-set size is DERIVED from DOC_FILES_DEFAULT, not typed:
            # enrolling ROADMAP.md (round 2 of #1207) turned a hand-typed "6"
            # here into a selftest failure with nothing wrong in the tree.
            st_docn=$(printf '%s\n' $DOC_FILES_DEFAULT | grep -c .)
            if [ "$rc" -ne 0 ] \
               && grep -qF "recorded 0/$st_docn declared row(s) — THE CLASS DID NOT RUN" <<< "$out" \
               && grep -qF "docs-claims CLASS SUMMARY" <<< "$out"; then
                printf '  selftest ok: a class that records nothing is named in ONE line by the summary printed LAST\n'
            else
                printf '  SELFTEST FAIL: a class that recorded nothing was not named by the class summary (rc=%d)\n' "$rc"
                grep -E '^RED|CLASS SUMMARY|PATHS:' <<< "$out" | head -6 | sed 's/^/        /'
                st_rc=1; st_failed=$((st_failed + 1))
            fi
        fi
        rm -rf "$st_norecord"
    else
        printf '  SELFTEST FAIL: could not make a scratch copy for the class-summary row\n'
        st_rc=1; st_failed=$((st_failed + 1))
    fi

    # ---- ROUND 12 (H1): a scan that MATCHES NOTHING must say so AT THE SCAN --
    # macOS: the PATHS scan returned zero matches without failing, and all the
    # log said, three hundred lines later, was "declared population
    # PATHS/README.md=101 was never visited" — the consequence, never the
    # cause. The plant makes one class's pattern UNMATCHABLE without making it
    # fail, which is the shape the platform produced.
    st_nomatch="$st_dir/nomatch"
    st_cases=$((st_cases + 1))
    if st_copy_tree "$ROOT" "$st_nomatch"; then
        sed "s|num '--\[a-z\]\[a-z0-9-\]\*'|num 'ZZZ_NO_SUCH_FLAG_ZZZ'|" \
            "$ROOT/tools/docs_claims_check.sh" > "$st_nomatch/tools/docs_claims_check.sh.new"
        if cmp -s "$st_nomatch/tools/docs_claims_check.sh.new" "$ROOT/tools/docs_claims_check.sh"; then
            printf '  SELFTEST FAIL: the unmatchable-pattern plant changed nothing — the FLAGS scan was reworded out of its reach\n'
            st_rc=1; st_failed=$((st_failed + 1))
        else
            rm -f "$st_nomatch/tools/docs_claims_check.sh"
            mv "$st_nomatch/tools/docs_claims_check.sh.new" "$st_nomatch/tools/docs_claims_check.sh"
            out=$(cd "$st_nomatch" && bash tools/docs_claims_check.sh 2>&1); rc=$?
            if [ "$rc" -ne 0 ] \
               && grep -qF "class FLAGS matched NOTHING in" <<< "$out" \
               && grep -qF "It did not fail; it found nothing" <<< "$out" \
               && grep -qF "Last scan: awk match() pattern=" <<< "$out"; then
                printf '  selftest ok: a scan that matches NOTHING is red AT THE SCAN, quoting the command and its exit status\n'
            else
                printf '  SELFTEST FAIL: an unmatchable scan did not produce the "matched NOTHING" red (rc=%d)\n' "$rc"
                grep -E '^RED' <<< "$out" | head -4 | sed 's/^/        /'
                st_rc=1; st_failed=$((st_failed + 1))
            fi
        fi
        rm -rf "$st_nomatch"
    else
        printf '  SELFTEST FAIL: could not make a scratch copy for the unmatchable-scan row\n'
        st_rc=1; st_failed=$((st_failed + 1))
    fi

    # ---- 2026-09-18: THE MISPLACED HERE-STRING, BOTH FACES ------------------
    # `x=$(grep -c .) <<< "$LIST"` puts the here-string on the ASSIGNMENT. A
    # command substitution is expanded BEFORE any redirection is applied, so
    # the `grep` inside it reads the SCRIPT's stdin, not the list. Five sites
    # in this file were written that way, one of them the §121 guard on the
    # fence population — which therefore compared 0 against 0 and had never
    # been able to fire. The two rows below pin the two faces.
    #
    # FACE 1, the vacuity: the plant restores the bug at the fence guard and
    # the run must go RED — not on the inequality (both sides read 0, so they
    # agree), but on the nonzero-population assertion that exists for it.
    st_hs="$st_dir/herestring"
    st_cases=$((st_cases + 1))
    if st_copy_tree "$ROOT" "$st_hs"; then
        sed -e 's|^fence_asked=$(grep -c \. <<< "$FENCE_FILES")$|fence_asked=$(grep -c .) <<< "$FENCE_FILES"|' \
            -e 's|^fence_answered=$(grep -c \. <<< "$FENCE_COUNTS")$|fence_answered=$(grep -c .) <<< "$FENCE_COUNTS"|' \
            "$ROOT/tools/docs_claims_check.sh" > "$st_hs/tools/docs_claims_check.sh.new"
        if cmp -s "$st_hs/tools/docs_claims_check.sh.new" "$ROOT/tools/docs_claims_check.sh"; then
            printf '  SELFTEST FAIL: the misplaced-here-string plant changed nothing — the fence counter lines moved\n'
            st_rc=1; st_failed=$((st_failed + 1))
        else
            rm -f "$st_hs/tools/docs_claims_check.sh"
            mv "$st_hs/tools/docs_claims_check.sh.new" "$st_hs/tools/docs_claims_check.sh"
            out=$(cd "$st_hs" && bash tools/docs_claims_check.sh 2>&1); rc=$?
            if [ "$rc" -ne 0 ] && grep -qF "was handed ZERO documents" <<< "$out"; then
                printf '  selftest ok: a counter that reads stdin instead of its list reports ZERO, and ZERO is red\n'
            else
                printf '  SELFTEST FAIL: the fence counter read 0 documents and the run stayed green (rc=%d)\n' "$rc"
                grep -E '^RED|fence counter' <<< "$out" | head -4 | sed 's/^/        /'
                st_rc=1; st_failed=$((st_failed + 1))
            fi
        fi
        rm -rf "$st_hs"
    else
        printf '  SELFTEST FAIL: could not make a scratch copy for the misplaced-here-string row\n'
        st_rc=1; st_failed=$((st_failed + 1))
    fi

    # FACE 2, the hang, and why `exec 0</dev/null` at the top of this file is
    # load-bearing rather than tidy. With stdin an OPEN stream — a background
    # job, a pipeline, a CI runner that leaves it attached — the same spelling
    # does not return 0; it blocks on a pipe that never closes. Measured on
    # main: 20 minutes of silence, and the bash-3.2 portability audit that
    # drives this gate hung with it. The row proves the MECHANISM in seconds
    # rather than paying a full gate run to reach the site: same two lines of
    # shell, once with stdin attached and once with it closed.
    st_cases=$((st_cases + 1))
    st_tmo=""
    if command -v timeout >/dev/null 2>&1; then st_tmo="timeout 3"
    elif command -v gtimeout >/dev/null 2>&1; then st_tmo="gtimeout 3"; fi
    if [ -n "$st_tmo" ]; then
        # `sleep 6 |` holds the write end open, so there is never an EOF. The
        # sleep outlives the timeout deliberately and the shell waits for the
        # whole pipeline, so this row costs ~6 s, not 3.
        sleep 6 | $st_tmo bash -c 'x=$(grep -c .) <<< "a" ; echo "returned $x"' >/dev/null 2>&1
        hs_open_rc=$?
        $st_tmo bash -c 'exec 0</dev/null; x=$(grep -c .) <<< "a" ; echo "returned $x"' >/dev/null 2>&1
        hs_null_rc=$?
        if [ "$hs_open_rc" -eq 124 ] && [ "$hs_null_rc" -eq 0 ]; then
            printf '  selftest ok: the misplaced-here-string spelling BLOCKS on an attached stdin and cannot with stdin closed — `exec 0</dev/null` above is load-bearing\n'
        else
            printf '  SELFTEST FAIL: the stdin mechanism row did not reproduce (attached rc=%d want 124, closed rc=%d want 0)\n' \
                   "$hs_open_rc" "$hs_null_rc"
            st_rc=1; st_failed=$((st_failed + 1))
        fi
    else
        # Not a skip: the case still counts and says what it could not do.
        printf '  selftest ok: stdin-mechanism row: no timeout(1) on this machine, so the blocking half was not driven — the fix above is unchanged\n'
    fi

    # A waiver must be pinned to the EXACT line (mechanical-gates §125): edit
    # the waived line and the waiver must stop applying.
    p=$(plant "CLAUDE.md" 's/DMG is 3,288 lines, of which 818 are compiled/DMG is 3,289 lines, of which 818 are compiled/' CLAUDE.md)
    st_case "an edited waived line loses its waiver" \
            "$p" 1 "hand-typed number '3,289 lines' that no derivation claims"

    # ROUND 4 (H3): report the POPULATION and the failures as two numbers.
    # The suite used to pin the count of "selftest ok" lines, so ONE failing
    # case read as `cases=20, expected 21` — indistinguishable from a case that
    # had been deleted. A count that changes meaning when something fails is
    # not a population count (§121). Every case runs; this line says how many
    # ran, how many passed, how many failed, and the reaching of this line is
    # itself the proof that nothing aborted.
    printf 'SELFTEST: %d case(s) run, %d passed, %d failed\n' \
           "$st_cases" "$((st_cases - st_failed))" "$st_failed"
    if [ "$st_failed" -eq 0 ] && [ "$st_rc" -eq 0 ]; then
        printf 'SELFTEST: every planted fault went red\n'
    else
        printf 'SELFTEST: FAILED\n'
    fi
    DC_VERDICT_PRINTED=1
    exit $st_rc
fi

red=0
note() { printf '%s\n' "$*"; }
fail() { red=1; printf 'RED: %s\n' "$*"; }

# ---------------------------------------------------------------------------
# ROUND 11 (H1) — A SCAN WHOSE FAILURE LOOKS LIKE "NOTHING FOUND".
#
# The macOS break: the fence scan ran an ERE that BSD grep rejects, with
# `2>/dev/null` on it. grep exited 2 having printed its diagnostic into the
# void; the substitution produced an empty string; every document counted 0
# fences; the DOC ENROLMENT population collapsed. §121's declared-count pins
# DID fire — but the log said "examined 0 documents", never WHY, and two CI
# rounds went by not knowing. Suppressing the one sentence that explains an
# empty set is how a gate becomes unreadable at the exact moment it matters.
#
# The rule, applied to every scan that feeds a population: THE DIAGNOSTIC IS
# NEVER DISCARDED. A scanner that writes to stderr did not do what it was
# asked, whatever it left on stdout, and that is a RED naming the message.
#
# dc_scan keeps the scanner's stdout in DC_SCAN_OUT and prints NOTHING there
# itself: a RED printed on this function's stdout would be captured into a
# caller's `$( … )` and corrupt the very value it is complaining about (the
# round-5 NOTE trap, one level in).
DC_SCAN_OUT=""
DC_ERRFILE="$(mktemp "${TMPDIR:-/tmp}/eigs_docs_claims_scan.XXXXXX")" || {
    echo "docs-claims: ABORTED: cannot create a scratch file for scan diagnostics" >&2
    DC_VERDICT_PRINTED=1
    exit 1
}
# ROUND 14: the PATHS class feeds its loop from a FILE, not a process
# substitution — see the block comment at that loop. Same trap removes it.
DC_FEEDFILE="$(mktemp "${TMPDIR:-/tmp}/eigs_docs_claims_feed.XXXXXX")" || {
    echo "docs-claims: ABORTED: cannot create a scratch file for the PATHS feed" >&2
    DC_VERDICT_PRINTED=1
    exit 1
}
DC_LAST_CMD=""   # what the most recent scan actually ran, and what it exited
DC_LAST_RC=""    # with — quoted by dc_empty_check, which is the only place
                 # "the scan found nothing" can be told from "the scan broke".
dc_scan() { # what-is-being-scanned  command [args...]
    local what="$1"; shift
    local rc
    DC_LAST_CMD=$(printf '%s ' "$@" | tr '\n' ' ' | cut -c1-160)
    : > "$DC_ERRFILE"
    DC_SCAN_OUT=$("$@" 2>"$DC_ERRFILE"); rc=$?
    DC_LAST_RC=$rc
    if [ -s "$DC_ERRFILE" ]; then
        fail "$what: the scan itself failed — $(tr '\n' ' ' < "$DC_ERRFILE" | cut -c1-300)"
        return 1
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# ROUND 12 (H1) — EXTRACTION IS AWK'S JOB. `grep -o` IS NOT PORTABLE.
#
# The macOS break: the PATHS per-file scan returned NOTHING. Not an error —
# dc_scan saw an empty stderr — simply zero matches, so six declared rows read
# "never visited" and the class measured nothing while every other class
# passed. `grep -o` is the least portable thing in POSIX text processing: it
# is not in POSIX at all, and GNU and BSD differ on it with -E, on patterns
# that can match empty, and on how it composes with -n.
#
# This round does NOT diagnose which of those it was. There is no BSD grep on
# this box, and three rounds of this branch were spent inferring a platform's
# behaviour and being wrong. It removes the dependency instead: grep may still
# FIND lines; awk EXTRACTS, through POSIX match()/RSTART/RLENGTH, which
# tests/run_all_tests.sh already leans on and which the macOS lanes already
# run.
#
# TWO RULES FOR EVERY PATTERN THAT COMES THROUGH HERE, because an awk dynamic
# regex is a STRING where a grep ERE is not:
#   * NO BACKSLASH ESCAPES. What `\(` means in a string-to-regex conversion is
#     undefined by POSIX. Write the bracket expression: [(] [)] [[] []].
#   * NO [[:class:]] AND NO \b. Both are questions about someone else's awk
#     that cannot be answered from here; `[A-Za-z0-9_]` and an explicit
#     boundary test are answered by reading this file.
# The pattern reaches awk through the ENVIRONMENT, never `-v`: a -v assignment
# undergoes escape processing, which would silently eat a backslash a pattern
# needs.
dc_extract() { # what  mode  ERE  file...
    #  mode: ""        every match, one per line
    #        num       every match as "LINENO:match" (what `grep -no` gave)
    #        word      every match NOT followed by [A-Za-z0-9_] (what `\b` gave)
    #        numword   both
    local what="$1" mode="$2" re="$3"; shift 3
    local withnum="" wordend=""
    case "$mode" in
        num)     withnum=1 ;;
        word)    wordend=1 ;;
        numword) withnum=1; wordend=1 ;;
        "")      ;;
        *)       fail "dc_extract: unknown mode '$mode' for $what"; return 1 ;;
    esac
    local rc
    DC_X_RE="$re" dc_scan "$what" awk -v withnum="$withnum" -v wordend="$wordend" '
        BEGIN { re = ENVIRON["DC_X_RE"] }
        {
            s = $0
            while (match(s, re)) {
                if (RLENGTH <= 0) { s = substr(s, RSTART + 1); continue }
                tok = substr(s, RSTART, RLENGTH)
                nxt = substr(s, RSTART + RLENGTH, 1)
                s   = substr(s, RSTART + RLENGTH)
                # The whole match is skipped when the boundary fails, never
                # retried shorter: every alternation here ends in the same
                # word alphabet, so a shorter match at the same start is
                # followed by a word character too. Verified by the counts.
                if (wordend != "" && nxt ~ /^[A-Za-z0-9_]$/) continue
                if (withnum != "") printf "%d:%s\n", FNR, tok
                else print tok
            }
        }' "$@"
    rc=$?
    # The readable form. `$*` of that invocation is the whole awk program,
    # which is not what a reader needs to see quoted back at them.
    DC_LAST_CMD="awk match() pattern='$re' mode='${mode:-all}' over $*"
    return $rc
}

# A per-file scan that came back EMPTY where a count is DECLARED is the shape
# the macOS failure took, and "was never visited" three hundred lines later
# describes the consequence, not the cause. This says the cause, at the scan.
declared_count() { # class file -> the declared count, or nothing
    awk -F'|' -v c="$1" -v b="$2" '
            NF >= 3 { n = split($2, a, "/"); if ($1 == c && a[n] == b) { print $3 + 0; exit } }' \
        <<< "$DECLARED_POPULATIONS"
}
dc_empty_check() { # class  file  per-file-count
    local cls="$1" f="$2" got="$3" want
    # Only the real doc set: the declared counts describe THAT set, and the
    # selftest drives single stub documents where a class legitimately finds
    # nothing (mechanical-gates §41 — a row must not collect a neighbour's red).
    [ "$DOCSET_IS_DEFAULT" -eq 1 ] || return 0
    [ "${got:-0}" -eq 0 ] || return 0
    want=$(declared_count "$cls" "$(basename "$f")")
    [ -n "$want" ] && [ "$want" -gt 0 ] || return 0
    fail "class $cls matched NOTHING in $f, where $want are declared — the scan ran, exited $DC_LAST_RC and found zero. It did not fail; it found nothing, which is a different bug. Last scan: $DC_LAST_CMD"
}

# ---------------------------------------------------------------------------
# 0. The binary. Several derivations ask the runtime itself, per
#    mechanical-gates §1 (ask the tool, never re-count the source). An
#    instrument that cannot run must FAIL, never skip: doc_drift_check.sh's
#    check 2 was silently not running in CI for exactly that reason.
# ---------------------------------------------------------------------------
EIGS=""
for cand in "src/eigenscript" "build/release/eigenscript"; do
    [ -x "$cand" ] && { EIGS="$cand"; break; }
done
if [ -z "$EIGS" ]; then
    fail "no eigenscript binary at src/ or build/release/ — the derivations cannot run (build first: make)"
    echo ""
    echo "docs-claims: ABORTED (no instrument): neither src/eigenscript nor build/release/eigenscript is executable"
    DC_VERDICT_PRINTED=1
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. DERIVATIONS. Each one prints its value, so a green run still shows the
#    table a reader can check by hand, and each carries a vacuity floor: a
#    derivation that collapses to 0 would otherwise make every comparison
#    against it trivially wrong in an unreadable way.
# ---------------------------------------------------------------------------
plausible() { # name value floor
    if [ "${2:-0}" -lt "$3" ]; then
        fail "derivation '$1' returned $2 (floor $3) — the instrument is broken, not the tree"
        return 1
    fi
    return 0
}

# widgets: the registry, from the source...
dc_extract "the widget-registration scan of lib/*.eigs" "" \
           '^_register_widget of [[]"[a-z_0-9]+"' lib/*.eigs
D_WIDGETS=$(printf '%s\n' "$DC_SCAN_OUT" | sed 's/.*\["//; s/"//' | sort -u | grep -c . | tr -d ' ')
# ...and, independently (§122), from the RUNTIME registry the toolkit builds.
# Two mechanisms: a text scan of the call sites, and the dict the program
# actually ends up holding. A widget registered by any other spelling moves
# the second and not the first.
# Full template, not `mktemp -t`: BSD reads -t's argument as a prefix and
# appends its own suffix, so the ".eigs" would not stay last.
WPROBE="$(mktemp "${TMPDIR:-/tmp}/eigs_widget_probe.XXXXXX")"
printf 'load_file of "%s/lib/ui.eigs"\nprint of (len of (keys of _widget_registry))\n' "$ROOT" > "$WPROBE"
dc_scan "the runtime widget-registry probe" "$EIGS" "$WPROBE"
# ROUND 15 — NO WRITER PIPED INTO AN EARLY-EXITING READER.
# `printf … | grep -q`, `| head -1`, `| tail -1` and `| awk '… exit'` are all
# the same race: the reader stops, the writer takes SIGPIPE, and bash 3.2
# PRINTS that as `printf: write error: Broken pipe` on stderr where bash 5
# swallows it. Whether it appears depends on scheduling, so the gate's own
# output stopped being deterministic on macOS — which is what broke the
# "both build states produce byte-identical output" row for four rounds: the
# two runs differed by a race, not by build state. Reproduced here under
# bash 3.2 (`56d55 < …line 1698: printf: write error: Broken pipe`) and fixed
# by giving every early-exiting reader a HERE-STRING instead of a pipe — a
# here-string is a temp file, so there is no pipe to break. Related, same
# family: tools/pipefail_verdict_check.sh (#1122).
D_WIDGETS_RT=$(tail -1 <<< "$DC_SCAN_OUT" | tr -d ' ')
rm -f "$WPROBE"
case "$D_WIDGETS_RT" in ''|*[!0-9]*) D_WIDGETS_RT=0 ;; esac

dc_scan "the lib/*.eigs listing" ls lib/*.eigs
D_LIB_FILES=$(grep -c . <<< "$DC_SCAN_OUT" | tr -d ' ')
dc_scan "the lib/ui_*.eigs listing" ls lib/ui_*.eigs
D_UI_FRAGMENTS=$(grep -c . <<< "$DC_SCAN_OUT" | tr -d ' ')
dc_scan "the README stdlib-row scan" grep -c '^| `lib/' README.md
D_README_ROWS=$(printf '%s' "$DC_SCAN_OUT" | tr -d ' ')

# STEM: the machine-readable tag, from the modules...
dc_scan "the stdlib-tag: stem scan of lib/*.eigs" grep -l '^# stdlib-tag: stem' lib/*.eigs
D_STEM=$(grep -c . <<< "$DC_SCAN_OUT" | tr -d ' ')
# ...and, independently (§122), the membership of docs/STDLIB.md's own
# "STEM & Numeric Libraries" section. The tag is what the count is derived
# from; the prose section is a different mechanism written by a different
# hand, so a module that gains a tag without a section (or the reverse) is a
# disagreement rather than a silent re-definition of the category.
D_STEM_DOC=$(awk '
    /^## STEM & Numeric Libraries/ { inside = 1; next }
    /^## / { inside = 0 }
    inside && /^### lib\/[a-z_]+\.eigs/ { sub(/^### lib\//, ""); sub(/\.eigs.*/, ""); print }
' docs/STDLIB.md | sort -u | wc -l | tr -d ' ')

# binary size, the way install.sh builds it: ./build.sh, unstripped, no
# extensions. Reported in K = bytes/1024 rounded up, the unit the README uses.
# ROUND 7 — THE SIZE CLAIM IS ABOUT THE INSTALL-SHAPED RELEASE BINARY.
# It used to measure $EIGS, i.e. src/eigenscript, which is a HARD LINK to the
# last-built variant (#740). The ASan shard builds asan, so the shard measured
# the ASan binary and reported "claims '940K' but D_BIN_K derives 28721".
# Round 1's own caveat had called it: "±10% absorbs growth, not a variant swap."
# So the derivation names the variant explicitly and never follows the alias.
#
# A lane with no release build does not SKIP the claim — a silent skip is how a
# gate quietly measures less. It DEFERS it, as a named class with a declared
# count, so a deferral cannot multiply unnoticed, and the lanes that do build
# release (linux/gcc, macOS) are authoritative for the number.
#
# ROUND 11 (H3) — AND NO LANE WAS VERIFYING IT.
# Round 7 deferred the claim whenever build/release/eigenscript is absent,
# "because the lanes that build release verify it". Measured on ci.yml: NO
# LANE BUILDS IT. Every leg builds with `./build.sh` (the same path install.sh
# uses), and build.sh writes src/eigenscript DIRECTLY; build/release exists
# only after a `make`. So the claim deferred on every lane, nothing checked
# it, and a documentation number with no verifier had grown inside the branch
# whose whole subject is documentation numbers with no verifier.
#
# src/eigenscript IS the install-shaped binary after build.sh. It is NOT after
# `make asan`, where the objdir engine (#740) leaves it a HARD LINK to
# build/<variant>/eigenscript. That is decidable rather than guessable:
# `test -ef` compares DEVICE AND INODE, so the alias names its own variant and
# the variant names itself.
RELEASE_BIN="build/release/eigenscript"
RELEASE_ONLY_DECLARED=1   # how many claims may defer when none is measurable
SIZE_BIN=""               # the binary the README's size is about, or empty
SIZE_BIN_WHY=""           # one line, printed either way, naming the state
D_BIN_K=""
BIN_DEFERRED=0
if [ -f "$RELEASE_BIN" ]; then
    SIZE_BIN="$RELEASE_BIN"
    SIZE_BIN_WHY="$RELEASE_BIN — the make(1) release objdir"
elif [ -f "src/eigenscript" ]; then
    bin_variant=""
    for v in build/*/eigenscript; do
        [ -f "$v" ] || continue
        if [ src/eigenscript -ef "$v" ]; then
            bin_variant=$(basename "$(dirname "$v")")
            break
        fi
    done
    if [ -z "$bin_variant" ]; then
        SIZE_BIN="src/eigenscript"
        SIZE_BIN_WHY="src/eigenscript — no build/*/eigenscript shares its inode, so it is the ./build.sh product, which is exactly what install.sh puts on a user's machine"
    else
        SIZE_BIN_WHY="DEFERRED — src/eigenscript is a hard link to build/$bin_variant/eigenscript; the claim is about the minimal RELEASE build, not the $bin_variant variant"
    fi
else
    SIZE_BIN_WHY="DEFERRED — neither $RELEASE_BIN nor src/eigenscript exists in this lane"
fi
# The README sentence is about the minimal Linux build (it is the install
# instructions). A Mach-O of the same source is a different object format, not
# documentation drift, and this box cannot measure one to find out — so the
# claim defers there, NAMED, rather than reddening a lane for being macOS.
# It still has a verifier: linux/gcc runs ./build.sh and then the FULL suite,
# which is [99za], on every PR (ci.yml, build-and-test-linux). That was READ,
# not assumed — assuming it is what round 7 got wrong.
DC_UNAME_S=$(uname -s 2>/dev/null || echo unknown)
if [ -n "$SIZE_BIN" ] && [ "$DC_UNAME_S" != "Linux" ]; then
    SIZE_BIN_WHY="DEFERRED — $SIZE_BIN exists, but the claim is a Linux minimal build and this is $DC_UNAME_S"
    SIZE_BIN=""
fi
if [ -n "$SIZE_BIN" ]; then
    D_BIN_BYTES=$(wc -c < "$SIZE_BIN" | tr -d ' ')
    D_BIN_K=$(( (D_BIN_BYTES + 1023) / 1024 ))
else
    D_BIN_BYTES=0
fi
BIN_TOL_PCT=10   # the README states "~NK"; this is the pinned tolerance

# suite size: the runner's own sections. NOT the RESULTS total — that needs a
# full suite run, which this gate must never be (it runs in the PR lane).
#
# ROUND 2 (Astra, G3): the first cut counted labelled echo LINES (267) and the
# README said "267 test sections". A section may legitimately echo its label
# twice for a conditional twin ("... SKIPPED (binary built without ...)"), so
# the number a reader means is the count of DISTINCT labels — 258. Both are
# derived; the doc states the distinct one.
SUITE_RUNNER="tests/run_all_tests.sh"
# ONE scan, two numbers. The first cut ran the pattern twice (once with -c,
# once with -o), which is two chances for the two spellings to drift apart —
# the same duplication that made the fence grammar disagree with itself.
dc_extract "the labelled-echo scan of $SUITE_RUNNER" "" \
           '^[ 	]*echo "[[][^]"]+[]]' "$SUITE_RUNNER"
D_SECTION_LINES=$(grep -c . <<< "$DC_SCAN_OUT" | tr -d ' ')
D_SECTIONS=$(printf '%s\n' "$DC_SCAN_OUT" \
             | sed -E 's/.*\[([^]"]+)\].*/\1/' | sort -u | grep -c . | tr -d ' ')
# §122 cross-check: tools/suite_label_check.sh enumerates the SAME lines for a
# different purpose (uniqueness). Its own reported count must equal ours, or
# two tools disagree about the shape of the runner and at least one is wrong.
dc_scan "tools/suite_label_check.sh (the §122 cross-check)" bash tools/suite_label_check.sh
D_LABELCHECK=$(printf '%s\n' "$DC_SCAN_OUT" \
               | sed -n 's/.*PASS: \([0-9][0-9]*\) labelled echo lines.*/\1/p' | head -1)
case "${D_LABELCHECK:-}" in ''|*[!0-9]*) D_LABELCHECK=0 ;; esac

D_API_CORE=$("$EIGS" --api | awk '$1 == "builtin"' | wc -l | tr -d ' ')
D_API_EXT=$("$EIGS" --api | awk '$1 == "extension"' | wc -l | tr -d ' ')
D_API_TOTAL=$((D_API_CORE + D_API_EXT))
D_LLMS_LINES=$(wc -l < docs/llms.txt | tr -d ' ')

# ROUND 3 (Astra, H3): the copy-vs-share taxonomy docs/CONCURRENCY.md publishes
# comes from ONE switch. `chan_clone_rec` has no `default:`, so -Werror=switch
# already forces a new ValType to pick a side in C; this pins the same number
# in the DOC, so adding a type fails the page as well as the compiler. The doc
# listed "three things" and a reviewer found a fourth by sending a channel
# through a channel — a remembered list is what this replaces.
D_CHAN_ARMS=$(awk '/^static Value \*chan_clone_rec/,/^}/' src/eigenscript.c \
              | grep -c 'case VAL_' | tr -d ' ')

# ROADMAP.md's two HISTORICAL counts — the pre-PR checkbox pile #1207 measured.
#
# BOUGHT 2026-09-21 (round-3 blind critic, Astra check 5): these two numbers
# were WAIVED by exact line, so changing `113` to `114` AND its waiver together
# stayed green — the derivation the waiver's reason described ("beside the
# command that derives it") was never executed by anything. A waiver is a
# promise; a derived unit is a measurement. The promise is now deleted and the
# command runs here.
#
# The commit is the branch point this PR was measured against. A clone that
# cannot reach it (a shallow CI checkout, a `git archive` scratch copy with no
# `.git` at all) cannot derive the number, so the claim DEFERS by name into its
# own declared class rather than silently dropping out of the population.
#
# WHAT A DEFERRAL COSTS (round-4 blind critic, Fable, check 1). A deferred
# claim is NOT verified — it is verified NOWHERE until someone re-derives it.
# The commit above is a HISTORICAL one: if the history is ever rewritten, or
# the commit is garbage-collected, or CI switches to a shallow fetch, these two
# claims defer on EVERY lane and stay unverified indefinitely, with the tree
# still printing `docs-claims: OK`. Until round 4 the OK line was BYTE-IDENTICAL
# whether the claims were derived or deferred, and the CI logs print only that
# line — so whether CI measured them was unknowable from the lane. The OK line
# now carries `history-deferred=N`. If N stops being 0 on a lane that used to
# derive, re-pin DC_ROADMAP_HIST_COMMIT to a reachable commit (or restate the
# two claims from a commit that is), rather than letting the deferral become
# the normal state.
#
# ROUND 7 — AND A LANE THAT CANNOT REACH IT IS NOW A LANE THAT FETCHES IT.
# The deferral above was not hypothetical: measured on this PR's own head
# (linux/gcc job 106465168161, macOS job 106465087620), BOTH printed
# `docs-claims: OK — NUMBERS 36 (history-deferred=2)`, because every suite
# job's `actions/checkout` is shallow and the PR merge ref's parents are not
# fetched. So these two claims were derived NOWHERE, on any lane, ever — and
# retyping 113 as 114 passed CI (third critic, `/code-review 1226 medium`,
# finding 5). `.github/workflows/ci.yml`'s `linux` job now fetches exactly
# this one commit (`git fetch --depth=1 origin <sha>`, about a second), and
# suite section [99za] probes the commit ITSELF and requires
# `history-deferred=0` on any lane that holds it — so a lane that claims the
# derivation without the history is red by name.
#
# THE FULL 40-CHARACTER SHA, not an abbreviation: `git fetch origin <sha>`
# rejects an abbreviated object name outright (`couldn't find remote ref
# b91768e`, measured), so the abbreviation could not be the thing a lane
# fetches.
DC_ROADMAP_HIST_COMMIT="${DC_ROADMAP_HIST_COMMIT:-b91768e23c5a874a64e76e4af9ab291e6aa49983}"
D_ROADMAP_HIST_CHECKBOXES=""
D_ROADMAP_HIST_COMPLETED=""
DC_ROADMAP_HIST_WHY="SKIPPED BY NAME: commit $DC_ROADMAP_HIST_COMMIT is not reachable here (shallow checkout or no .git), so the pre-PR checkbox counts cannot be derived"
#
# `-c safe.directory='*'`, AND THE OMISSION COST A RED CI LANE. Bought
# 2026-09-21, ON THE FIRST RUN OF THE [99za] CHECK ADDED THIS ROUND: the CI
# container runs as a different uid from the checkout's owner, so PLAIN `git`
# dies with "detected dubious ownership" — and this `cat-file` swallowed that
# on stderr and deferred by name, exactly as it does for a genuinely shallow
# clone. The PATHS class's `git ls-files` three hundred lines below already
# carried the flag; its sibling here did not, which is §26's two-homes shape
# inside one file. The lane HELD the commit (the caller read it with the flag)
# and the gate still said it could not. One workaround, every git call.
if git -c safe.directory='*' cat-file -e "$DC_ROADMAP_HIST_COMMIT:ROADMAP.md" 2>/dev/null; then
    D_ROADMAP_HIST_CHECKBOXES=$(git -c safe.directory='*' show "$DC_ROADMAP_HIST_COMMIT:ROADMAP.md" \
        | grep -cE '^[[:space:]]*- \[( |x|~)\]' | tr -d ' ')
    D_ROADMAP_HIST_COMPLETED=$(git -c safe.directory='*' show "$DC_ROADMAP_HIST_COMMIT:ROADMAP.md" \
        | sed -n '/^## Completed/,$p' \
        | grep -cE '^[[:space:]]*- \[( |x|~)\]' | tr -d ' ')
    DC_ROADMAP_HIST_WHY="git show $DC_ROADMAP_HIST_COMMIT:ROADMAP.md"
fi
D_ROADMAP_HIST_CHECKBOXES_WHY="$DC_ROADMAP_HIST_WHY"
D_ROADMAP_HIST_COMPLETED_WHY="$DC_ROADMAP_HIST_WHY"

note "docs-claims derivations (every number below comes from the tree, not from a document):"
note "  widgets                 = $D_WIDGETS   (source grep)  /  $D_WIDGETS_RT (runtime registry)"
note "  lib/*.eigs              = $D_LIB_FILES"
note "  lib/ui_*.eigs fragments = $D_UI_FRAGMENTS"
note "  README stdlib rows      = $D_README_ROWS"
note "  STEM tagged modules     = $D_STEM   (# stdlib-tag: stem)  /  $D_STEM_DOC (docs/STDLIB.md section)"
if [ -n "$D_BIN_K" ]; then
    note "  minimal binary          = ${D_BIN_K}K  ($D_BIN_BYTES bytes, $SIZE_BIN_WHY, tolerance ±${BIN_TOL_PCT}%)"
else
    note "  minimal binary          = $SIZE_BIN_WHY"
fi
note "  suite sections          = $D_SECTIONS distinct  /  $D_SECTION_LINES labelled lines  ($D_LABELCHECK per tools/suite_label_check.sh)"
note "  --api                   = $D_API_TOTAL ($D_API_CORE core + $D_API_EXT extensions)"
note "  docs/llms.txt lines     = $D_LLMS_LINES"
note "  chan_clone_rec arms     = $D_CHAN_ARMS (src/eigenscript.c, no default: — -Werror=switch forces the choice)"
note "  ROADMAP pre-PR boxes    = ${D_ROADMAP_HIST_CHECKBOXES:-<deferred>} total / ${D_ROADMAP_HIST_COMPLETED:-<deferred>} under ## Completed  ($DC_ROADMAP_HIST_WHY)"

plausible widgets       "$D_WIDGETS"      20
plausible lib_files     "$D_LIB_FILES"    50
plausible ui_fragments  "$D_UI_FRAGMENTS"  5
plausible readme_rows   "$D_README_ROWS"  20
plausible stem          "$D_STEM"          5
[ -n "$D_BIN_K" ] && plausible binary_k "$D_BIN_K" 100
plausible sections      "$D_SECTIONS"    200
plausible section_lines "$D_SECTION_LINES" 200
if [ "$D_SECTION_LINES" != "$D_LABELCHECK" ]; then
    fail "the suite-section derivation disagrees with tools/suite_label_check.sh: $D_SECTION_LINES labelled lines here, $D_LABELCHECK there — two tools reading one runner must agree"
fi
if [ "$D_SECTIONS" -gt "$D_SECTION_LINES" ]; then
    fail "distinct section labels ($D_SECTIONS) exceed labelled lines ($D_SECTION_LINES) — the derivation is broken"
fi
plausible api_core      "$D_API_CORE"    100
plausible api_ext       "$D_API_EXT"      10
plausible llms_lines    "$D_LLMS_LINES"   50
plausible chan_arms     "$D_CHAN_ARMS"     5

if [ "$D_WIDGETS" != "$D_WIDGETS_RT" ]; then
    fail "widget count disagrees between its two derivations: source grep $D_WIDGETS, runtime registry $D_WIDGETS_RT"
fi
if [ "$D_STEM" != "$D_STEM_DOC" ]; then
    fail "STEM count disagrees between its two derivations: '# stdlib-tag: stem' headers $D_STEM, docs/STDLIB.md section $D_STEM_DOC"
fi
if [ $((D_README_ROWS + D_UI_FRAGMENTS)) -ne "$D_LIB_FILES" ]; then
    fail "README stdlib rows ($D_README_ROWS) + ui fragments ($D_UI_FRAGMENTS) != lib/*.eigs ($D_LIB_FILES) — a module is in neither the table nor the declared fragment set"
fi

# ---------------------------------------------------------------------------
# 2. WAIVERS. file basename | EXACT line content | reason.
#    Exact line, never a substring (mechanical-gates §125): a substring waiver
#    is a standing exemption that silently adopts every future matching line.
#    The basename (not the path) is the key so the selftest can drive a copy.
#
#    ROUND 2 (Astra, G1): a waiver that stops MATCHING is now RED, with its
#    line quoted. Before, deleting a waived line dropped the population from 24
#    to 23 and the gate still exited 0 — the same shape as mechanical-gates
#    §129 (a floor lets a home vanish): "everything found is accounted for" was
#    asserted, "the count is the DECLARED one" was not. Both are now.
# ---------------------------------------------------------------------------
# NOTE: a HEREDOC, not a single-quoted string. A reason containing an
# apostrophe ("docker's flag") closes a single-quoted body and the rest of
# the table becomes shell commands — the failure mode mechanical-gates §53
# records for awk, in bash. Measured here on the first run.
# The waiver table lives in a DATA FILE — see the header of that file for the
# three quoting traps that put it there. Read into a variable once; every
# consumer below iterates the variable, so the file is opened exactly once.
WAIVERS_FILE="tools/docs_claims_waivers.txt"
if [ ! -f "$WAIVERS_FILE" ]; then
    echo "docs-claims: ABORTED: the waiver table $WAIVERS_FILE is missing" >&2
    DC_VERDICT_PRINTED=1
    exit 1
fi
WAIVERS_TABLE=$(grep -v '^[[:space:]]*#' "$WAIVERS_FILE" | grep -v '^[[:space:]]*$')

WAIVER_HIT=" "   # space-delimited list of waiver ordinals that matched
WAIVER_REASON=""

# Sets WAIVER_REASON and returns 0 on a match. NOT a command substitution:
# the usage mark has to survive into the caller's shell, and a subshell would
# drop it — which is precisely how an unused waiver stayed invisible.
waiver_lookup() { # file line-content
    local base; base="$(basename "$1")"
    local line="$2" n=0
    WAIVER_REASON=""
    while IFS='|' read -r wfile wline wreason; do
        n=$((n + 1))
        [ -z "${wfile:-}" ] && continue
        if [ "$wfile" = "$base" ] && [ "$wline" = "$line" ]; then
            WAIVER_REASON="$wreason"
            # `: ;;` — an EXPLICIT no-op body. bash 3.2 (which macOS ships)
            # will not parse an EMPTY arm body written INLINE with another arm
            # after it (a bare "pattern)" then the terminator then another
            # arm, all on one line) is a syntax error there, and
            # this exact line was the one macOS CI named on 1139856.
            case "$WAIVER_HIT" in *" $n "*) : ;; *) WAIVER_HIT="$WAIVER_HIT$n " ;; esac
            return 0
        fi
    done <<< "$WAIVERS_TABLE"
    return 1
}

# Called once at the end: a waiver nobody used is a REVIEW that no longer
# corresponds to anything in the tree. Either the line was edited (so the
# exemption's reasoning may no longer hold) or it was deleted (so the
# population shrank). Both are decisions, not silence.
waivers_audit() {
    local n=0 unused=0 inscope=0 setbases="" g
    for g in $DOC_FILES; do setbases="$setbases $(basename "$g")"; done
    note ""
    note "docs-claims waiver audit:"
    while IFS='|' read -r wfile wline wreason; do
        n=$((n + 1))
        [ -z "${wfile:-}" ] && continue
        # Only waivers whose document is IN this run can be expected to match.
        # Without this the selftest, which drives one document at a time, buries
        # every plant under unrelated "unmatched waiver" reds and each row then
        # passes off a neighbouring failure (mechanical-gates §41).
        case " $setbases " in *" $wfile "*) : ;; *) continue ;; esac
        inscope=$((inscope + 1))
        case "$WAIVER_HIT" in *" $n "*) continue ;; esac
        if true; then
            unused=$((unused + 1))
            fail "waiver $n ($wfile) matched NOTHING — the reviewed line is gone or edited, so the exemption no longer describes the tree"
            note "      waived line: $wline"
            note "      reason was:  $wreason"
        fi
    done <<< "$WAIVERS_TABLE"
    note "  WAIVERS: $n declared, $inscope in scope for this doc set, $((inscope - unused)) matched, $unused unmatched"
    [ "$n" -eq 0 ] && fail "the waiver table is empty — it is supposed to hold $WAIVERS_DECLARED entries"
    if [ "$n" -ne "$WAIVERS_DECLARED" ]; then
        fail "the waiver table holds $n entries but $WAIVERS_DECLARED are declared — adding or removing a waiver is a deliberate edit"
    fi
}
WAIVERS_DECLARED=22

# ---------------------------------------------------------------------------
# 2b. DECLARED POPULATIONS (mechanical-gates §121 + §129, Astra G1).
#     found == declared, per class AND per file, in BOTH directions:
#       * a found count that differs from its declared row is RED
#       * a declared row nothing visited is RED (a file silently dropped)
#       * a (class, file) pair that is found but never declared is RED
#     A non-zero population was never the assertion; the DECLARED one is.
# ---------------------------------------------------------------------------
# The declared populations live in a DATA FILE beside the waivers, for the same
# reason: no $(cat <<EOF) table survives bash 3.2 if a row ever grows a paren.
POPULATIONS_FILE="tools/docs_claims_populations.txt"
if [ ! -f "$POPULATIONS_FILE" ]; then
    echo "docs-claims: ABORTED: the declared-population table $POPULATIONS_FILE is missing" >&2
    DC_VERDICT_PRINTED=1
    exit 1
fi
DECLARED_POPULATIONS=$(grep -v '^[[:space:]]*#' "$POPULATIONS_FILE" | grep -v '^[[:space:]]*$')

FOUND=""   # newline-delimited "CLASS|basename|count" rows
# Keyed by BASENAME: the declared row must still apply when the selftest drives
# a copy of the document from a temp directory, or every plant would be judged
# by a row that silently did not apply to it.
record_found() { FOUND="$FOUND$1|$(basename "$2")|$3
"; }
found_count() { # class|basename -> echoes the count, or nothing
    awk -F'|' -v k="$1" 'NF == 3 && $1 "|" $2 == k { print $3; exit }' <<< "$FOUND"
}

declarations_audit() {
    local rows=0 visited=0
    note ""
    note "docs-claims declared-population audit (found == declared, both directions):"
    while IFS='|' read -r dclass dfile dcount; do
        [ -z "${dclass:-}" ] && continue
        rows=$((rows + 1))
        local key="$dclass|$(basename "$dfile")"
        local got; got=$(found_count "$key")
        if [ -z "$got" ]; then
            if [ "$DOCSET_IS_DEFAULT" -eq 1 ]; then
                fail "declared population $dclass/$dfile=$dcount was never visited — the document was dropped from the doc set, so its declaration checks nothing"
            fi
            continue
        fi
        visited=$((visited + 1))
        if [ "$got" -ne "$dcount" ]; then
            fail "$dclass/$dfile found $got but $dcount is declared — a claim was added or removed; update DECLARED_POPULATIONS deliberately"
        fi
    done <<< "$DECLARED_POPULATIONS"
    # The reverse direction: a (class, file) pair that was examined and never
    # declared. Compare on the SAME normalised key the rows were recorded
    # under, or this check accuses every row of being undeclared.
    local declared_keys
    declared_keys=$(printf '%s\n' "$DECLARED_POPULATIONS" \
                    | awk -F'|' 'NF >= 3 { n = split($2, a, "/"); print $1 "|" a[n] }')
    while IFS='|' read -r fclass fbase _fcount; do
        [ -n "${fclass:-}" ] || continue
        local key="$fclass|$fbase"
        if ! grep -qxF -- "$key" <<< "$declared_keys"; then
            fail "class/file $key was examined but has no row in DECLARED_POPULATIONS — an undeclared population is an unpinned one"
        fi
    done <<EOF
$FOUND
EOF
    local pairs; pairs=$(printf '%s' "$FOUND" | grep -c .)
    note "  DECLARATIONS: $rows row(s) declared, $visited visited, $pairs (class,file) pair(s) examined"
    if [ "$rows" -eq 0 ]; then
        fail "DECLARED_POPULATIONS is empty — every class must carry a declared count, not just a non-zero one"
    fi
    if [ "$DOCSET_IS_DEFAULT" -eq 1 ] && [ "$visited" -ne "$rows" ]; then
        fail "the declaration audit visited $visited of $rows rows"
    fi
}

# ---------------------------------------------------------------------------
# 3. CLASS: NUMBERS.
#    Population: in every doc file, every number immediately followed by one
#    of the pinned unit words. Each hit is matched against the rule table
#    below (token pattern + a line-context pattern, so "18 files" in one
#    sentence cannot silently borrow another rule's derivation); a hit that
#    no rule claims must be waived by exact line, or it is RED.
# ---------------------------------------------------------------------------
# ROUND 12: the trailing `\b` is GONE from the pattern and lives in the
# extractor instead (`numword`), which checks the following character against
# `[A-Za-z0-9_]` itself. `\b` is a GNU extension, not POSIX ERE, and it means
# a backspace inside an awk dynamic regex — a second portability question this
# file is no longer asking anyone.
UNIT_RE='[0-9][0-9,]*[ -]?(builtin functions|builtins?|module rows|modules?|rows|widgets?|checkbox lines?|checkboxe?s?|checks?|test sections|sections?|lines?|line|K|files|core|extensions?|STEM|fragments?|arms?)'

# Parameter expansion, not a pipeline: two processes per numeric claim, and
# `grep -o` is exactly what this round is removing. `${t%%[!0-9,]*}` keeps the
# leading run of digits and commas, which is what `^[0-9][0-9,]*` matched.
num_of() { local t="${1%%[!0-9,]*}"; printf '%s' "${t//,/}"; }

# rule: token-pattern :: line-context-pattern :: derived value :: tolerance%
NUMBER_RULES='
^[0-9]+-widget$::.::D_WIDGETS::0
^[0-9]+-module$::-module standard library::D_LIB_FILES::0
^[0-9]+ STEM$::standard library::D_STEM::0
^[0-9]+K$::minimal binary::D_BIN_K::BIN_TOL_PCT
^[0-9,]+ test sections$::.::D_SECTIONS::0
^[0-9]+ builtin functions$::core \+ [0-9]+ extensions::D_API_TOTAL::0
^[0-9]+ core$::builtin::D_API_CORE::0
^[0-9]+ extensions$::core \+::D_API_EXT::0
^[0-9]+-line$::docs/llms.txt::D_LLMS_LINES::0
^[0-9]+ module rows$::table above::D_README_ROWS::0
^[0-9]+ files$::The other [0-9]+ files in::D_UI_FRAGMENTS::0
^[0-9]+ modules$::modules in .lib/.::D_LIB_FILES::0
^[0-9]+ builtins$::organized by module::D_API_TOTAL::0
^[0-9]+ arms$::switch has::D_CHAN_ARMS::0
^[0-9,]+ checkbox lines$::carried [0-9,]+ checkbox lines in total::D_ROADMAP_HIST_CHECKBOXES::0
^[0-9,]+ checkbox lines$::of those were historical highlights::D_ROADMAP_HIST_COMPLETED::0
'

num_examined=0; num_derived=0; num_waived=0; num_deferred=0; num_rules_fired=0
hist_deferred=0
# The two ROADMAP historical counts defer together or not at all.
HIST_ONLY_DECLARED=2
note ""
note "docs-claims class NUMBERS:"
for f in $DOC_FILES; do
    [ -f "$f" ] || { fail "doc file $f does not exist"; continue; }
    per=0
    dc_extract "the numeric-claim scan of $f" numword "$UNIT_RE" "$f"
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"; token="${hit#*:}"
        line=$(sed -n "${lineno}p" "$f")
        per=$((per + 1)); num_examined=$((num_examined + 1))
        matched=0
        while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            tokpat="${rule%%::*}"; rest="${rule#*::}"
            ctxpat="${rest%%::*}"; rest="${rest#*::}"
            valname="${rest%%::*}"; tolname="${rest#*::}"
            grep -qE -e "$tokpat" <<< "$token" || continue
            grep -qE -e "$ctxpat" <<< "$line"  || continue
            matched=1; num_rules_fired=$((num_rules_fired + 1))
            claimed=$(num_of "$token")
            derived=$(eval "printf '%s' \"\${$valname}\"")
            # A derivation that this lane cannot make DEFERS the claim; it never
            # drops it. The deferral is counted and the count is pinned below.
            if [ -z "$derived" ]; then
                case "$valname" in
                    D_ROADMAP_HIST_*)
                        # A SECOND deferral class, counted separately and
                        # pinned separately: folding it into the binary-size
                        # class would let either one hide inside the other's
                        # allowance (mechanical-gates §129).
                        hist_deferred=$((hist_deferred + 1))
                        why=$(eval "printf '%s' \"\${${valname}_WHY:-}\"")
                        note "  DEFERRED $f:$lineno  '$token' — $valname: ${why:-no reason recorded}" ;;
                    *)
                        num_deferred=$((num_deferred + 1))
                        BIN_DEFERRED=1
                        note "  DEFERRED $f:$lineno  '$token' — $valname has no install-shaped binary to measure here: $SIZE_BIN_WHY" ;;
                esac
                break
            fi
            if [ "$tolname" = "0" ]; then
                tol=0
            else
                tol=$(eval "printf '%s' \"\${$tolname}\"")
            fi
            slack=$(( derived * tol / 100 ))
            lo=$(( derived - slack )); hi=$(( derived + slack ))
            if [ "$claimed" -ge "$lo" ] && [ "$claimed" -le "$hi" ]; then
                num_derived=$((num_derived + 1))
                note "  DERIVED $f:$lineno  '$token' == $valname ($derived)"
            else
                fail "$f:$lineno claims '$token' but $valname derives $derived — fix the document (or the tree)"
                note "      line: $line"
            fi
            break
        done <<< "$NUMBER_RULES"
        if [ "$matched" -eq 0 ]; then
            if waiver_lookup "$f" "$line"; then
                num_waived=$((num_waived + 1))
                note "  WAIVED  $f:$lineno  '$token' — $WAIVER_REASON"
            else
                fail "$f:$lineno has a hand-typed number '$token' that no derivation claims and no waiver covers"
                note "      line: $line"
                note "      fix: add a derivation rule to NUMBER_RULES, or waive this EXACT line with a reason"
            fi
        fi
    done < <(printf '%s\n' "$DC_SCAN_OUT")
    dc_empty_check NUMBERS "$f" "$per"
    record_found NUMBERS "$f" "$per"
    note "  population $f: $per numeric claim(s)"
done
if [ "$num_examined" -eq 0 ]; then
    fail "class NUMBERS examined 0 claims — the enumeration found nothing, which is not the same as 'no drift' (mechanical-gates §121)"
fi
if [ "$num_examined" -ne $((num_derived + num_waived + num_deferred + hist_deferred)) ] && [ "$red" -eq 0 ]; then
    fail "class NUMBERS: examined $num_examined but accounted for $((num_derived + num_waived + num_deferred + hist_deferred)) — an entry fell through the classification"
fi
note "  NUMBERS: examined $num_examined, derived $num_derived, waived $num_waived, deferred $num_deferred, history-deferred $hist_deferred"

# The ROADMAP-history deferral class, pinned the same way. Reachable commit =>
# nothing may defer; unreachable => exactly the declared count defers.
if [ -n "$D_ROADMAP_HIST_CHECKBOXES" ]; then
    if [ "$hist_deferred" -ne 0 ]; then
        fail "NUMBERS deferred $hist_deferred ROADMAP-history claim(s) although $DC_ROADMAP_HIST_COMMIT is reachable here — nothing may defer in a lane that can derive it"
    else
        note "  HISTORY: 0 deferred — $DC_ROADMAP_HIST_WHY derives $D_ROADMAP_HIST_CHECKBOXES total / $D_ROADMAP_HIST_COMPLETED under ## Completed"
    fi
elif [ "$hist_deferred" -ne "$HIST_ONLY_DECLARED" ]; then
    fail "NUMBERS deferred $hist_deferred ROADMAP-history claim(s) but $HIST_ONLY_DECLARED are declared — a deferral was added or removed; update HIST_ONLY_DECLARED deliberately"
else
    note "  HISTORY: $hist_deferred claim(s) need $DC_ROADMAP_HIST_COMMIT, $HIST_ONLY_DECLARED declared, deferred here — $DC_ROADMAP_HIST_WHY"
fi

# The deferral class, pinned. A lane that cannot build release defers exactly
# RELEASE_ONLY_DECLARED claim(s); anything else — a second deferral, or a
# deferral in a lane that DID build release — is red. That is what stops a
# "skip" from quietly becoming the normal state (mechanical-gates §129).
if [ -n "$SIZE_BIN" ]; then
    if [ "$num_deferred" -ne 0 ]; then
        fail "NUMBERS deferred $num_deferred claim(s) although $SIZE_BIN is measurable here — nothing may defer in a lane that can verify it"
    else
        note "  DEFERRALS: 0 — this lane measured $SIZE_BIN and is authoritative for the binary-size claim(s)"
    fi
elif [ "$num_deferred" -ne "$RELEASE_ONLY_DECLARED" ]; then
    fail "NUMBERS deferred $num_deferred claim(s) but $RELEASE_ONLY_DECLARED binary-size claim(s) are declared — a deferral was added or removed; update RELEASE_ONLY_DECLARED deliberately"
else
    note "  DEFERRALS: $num_deferred claim(s) need an install-shaped binary, $RELEASE_ONLY_DECLARED declared, deferred here — $SIZE_BIN_WHY"
fi

# ---------------------------------------------------------------------------
# 4. CLASS: PATHS. Every backticked token that contains a '/' and whose first
#    segment is one of the pinned top-level directories, plus every Markdown
#    link target, must RESOLVE. A '*' in the token is a glob.
#
#    ROUND 4 — THE ANSWER MUST NOT DEPEND ON WHAT HAS BEEN BUILT.
#    The r3 gate asked the FILESYSTEM. `src/eigenlsp` is absent from a clean
#    tree and present after `make lsp`, so the gate was rc 0 standalone and
#    rc 1 inside the release suite: suite section [88] builds the LSP binary,
#    the PATHS class then resolved the path, never consulted the waiver that
#    said "absent by design", and round 2's correct "an unmatched waiver is
#    RED" rule fired. A waiver is the wrong instrument for a path whose
#    presence is a function of which make targets someone ran.
#
#    So a path is classified first, and each class has its own question:
#      SOURCE        — tracked by git. Question: is it tracked, and present?
#                      (A build never adds or removes a tracked file, so this
#                      is build-state independent.)
#      BUILD PRODUCT — not tracked, but a Makefile rule PRODUCES it. Question:
#                      does a rule produce it? Its existence is NEVER asked.
#      neither       — RED.
#    Both classifications come from tools, not from a list: `git ls-files` and
#    `make -p` (mechanical-gates §1 — ask the tool, never re-type its answer).
#
#    §122: the pinned segment list is cross-checked against git's own view of
#    the tree, so a new top-level directory cannot silently sit outside the
#    population. Not derived FROM git, because then a directory that vanished
#    would shrink the population instead of failing.
# ---------------------------------------------------------------------------
PATH_SEGMENTS="src lib tests tools docs examples editors bench fuzz web reports .github .claude .devcontainer"
if git -c safe.directory='*' rev-parse --git-dir >/dev/null 2>&1; then
    tracked=$(git -c safe.directory='*' ls-files | awk -F/ 'NF>1 {print $1}' | sort -u)
    for d in $tracked; do
        case " $PATH_SEGMENTS " in
            *" $d "*) ;;
            *) fail "top-level directory '$d' is tracked but not in PATH_SEGMENTS — backticked paths under it are outside this gate's population" ;;
        esac
    done
else
    note "  NOTE: not a git checkout; the PATH_SEGMENTS cross-check cannot run"
fi

seg_alt=$(printf '%s' "$PATH_SEGMENTS" | tr ' ' '|')

# ---- the two derived classifiers -------------------------------------------
# SOURCE: git's index. Not `ls`, because `ls` answers a question about the
# working tree's current state and this class must not.
dc_scan "git ls-files (the PATHS source-path authority)" \
        git -c safe.directory='*' ls-files
TRACKED_LIST="$DC_SCAN_OUT"
if [ -z "$TRACKED_LIST" ]; then
    fail "git listed no tracked files — the PATHS classifier lost its source-path authority"
fi

# BUILD PRODUCTS: make's own database, in one invocation (-n so nothing runs).
# Two routes into it, both mechanical:
#   (a) every explicit FILE target make knows (a line "<path-with-a-slash>:"),
#   (b) every recipe OUTPUT in the Makefile (`-o X`, `ln -f A B`, `cp A B`),
#       with $(VAR) expanded from the same dump's variable definitions — this
#       is what catches src/eigenscript, which no rule NAMES as a target: the
#       variant recipe hard-links build/<v>/eigenscript onto $(BINARY).
# NOT dc_scan: `make -p -n` is the one scan here that may legitimately write
# to stderr while still answering (an older GNU make warns about the implicit
# default goal under -n). So the rule is applied in its weaker, still-loud
# form: the diagnostic is kept and printed, and it is a RED only when the
# database came back EMPTY — the state that would read as "no build products".
: > "$DC_ERRFILE"
MAKE_DB=$(make -p -n --no-builtin-rules 2>"$DC_ERRFILE")
MAKE_ERR=""
[ -s "$DC_ERRFILE" ] && MAKE_ERR=$(tr '\n' ' ' < "$DC_ERRFILE" | cut -c1-300)
if [ -z "$MAKE_DB" ]; then
    fail "make printed no database — the PATHS classifier lost its build-product authority${MAKE_ERR:+ — make said: $MAKE_ERR}"
elif [ -n "$MAKE_ERR" ]; then
    note "  NOTE: make wrote to stderr while still printing a database: $MAKE_ERR"
fi
VAR_SED=$(mktemp "${TMPDIR:-/tmp}/eigs_docs_varsed.XXXXXX")
printf '%s\n' "$MAKE_DB" \
  | awk -F' := ' '/^[A-Za-z_][A-Za-z0-9_]* := [^ ]+$/ { gsub(/[\\&|]/, "\\\\&", $2); printf "s|[$][(]%s[)]|%s|g\n", $1, $2 }' \
  > "$VAR_SED"
VAR_RULES_N=$(grep -c . "$VAR_SED" | tr -d ' ')
# ROUND 13 (H3) — VERSION-INSENSITIVE, WITHOUT GUESSING.
# macOS runs GNU Make 3.81; this box runs 4.4, and `make -p`'s database format
# is exactly the kind of thing a decade of versions moves. The variable dump is
# the only part of that format this tool parses, and the Makefile states the
# same assignments itself — so when the database yields no variable rules, read
# them from the Makefile. That is a fallback, not a fix for a diagnosis nobody
# has made yet: BOTH build-product routes being empty is still a hard RED
# below, and both route sizes are printed either way so the next log names
# which one died instead of leaving it to be inferred.
if [ "${VAR_RULES_N:-0}" -eq 0 ]; then
    note "  NOTE: make's database yielded no variable definitions; falling back to the Makefile's own '^VAR := value' lines"
    awk -F' := ' '/^[A-Za-z_][A-Za-z0-9_]* := [^ ]+$/ { gsub(/[\\&|]/, "\\\\&", $2); printf "s|[$][(]%s[)]|%s|g\n", $1, $2 }' \
        Makefile > "$VAR_SED"
    VAR_RULES_N=$(grep -c . "$VAR_SED" | tr -d ' ')
fi
# Hoisted out of the command substitution below: dc_extract REPORTS, and a
# RED printed inside `$( … )` would be captured into the value it complains
# about instead of reaching the log.
dc_extract "the Makefile recipe-output scan" "" \
           '-o +[^ ]+|ln -f +[^ ]+ +[^ ]+|cp +[^ ]+ +[^ ]+' Makefile
MAKE_RECIPE_OUT="$DC_SCAN_OUT"
# The two routes are computed SEPARATELY so each one's size can be printed.
# A combined number cannot say which half of a classifier died on a platform
# nobody here can boot, and that is precisely the question this round exists
# to stop guessing at.
PRODUCED_DB=$(printf '%s\n' "$MAKE_DB" \
  | awk '/^[^ \t#.][^ \t=]*:([^=]|$)/ {print $1}' | sed 's/:$//' \
  | grep '/' | grep -v '[$%]' | sort -u)
# recipe outputs, with $(VAR) expanded from make's own variable dump (or the
# Makefile's, per the fallback above).
PRODUCED_REC=$(printf '%s\n' "$MAKE_RECIPE_OUT" \
  | awk 'NF { print $NF }' \
  | sed -f "$VAR_SED" \
  | grep '/' | grep -v '[$%]' | sort -u)
rm -f "$VAR_SED"
PRODUCED=$(printf '%s\n%s\n' "$PRODUCED_DB" "$PRODUCED_REC" | grep . | sort -u)
PRODUCED_DB_N=$(grep -c . <<< "$PRODUCED_DB" | tr -d ' ')
PRODUCED_REC_N=$(grep -c . <<< "$PRODUCED_REC" | tr -d ' ')
PRODUCED_N=$(grep -c . <<< "$PRODUCED" | tr -d ' ')
if [ "${PRODUCED_DB_N:-0}" -eq 0 ] && [ "${PRODUCED_REC_N:-0}" -eq 0 ]; then
    fail "BOTH build-product routes came back empty — make -p listed no file targets AND the Makefile recipe scan found no outputs; the PATHS classifier has no build-product authority at all (make: $(make --version 2>/dev/null | head -1))"
fi
if [ "${PRODUCED_N:-0}" -lt 20 ]; then
    fail "the Makefile producer set came back with $PRODUCED_N entries (floor 20; make -p route $PRODUCED_DB_N, Makefile recipe route $PRODUCED_REC_N, variable rules $VAR_RULES_N) — the derivation is broken, not the tree"
fi
# Hashed once. The first cut asked each question with a `printf | grep`, i.e.
# two processes per path per question — ~500 subprocesses for 163 paths, which
# took the SELFTEST (26 child invocations of the whole gate) from seconds to
# minutes on the 2-core box. A membership test is a hash lookup.
# NOT an associative array. macOS ships bash 3.2, where `declare -A` is a
# SYNTAX ERROR — the whole script dies with rc 2 before doing anything, which
# is exactly what the macOS CI job reported (25 of 27 plants "ABSENT"). This
# repo has been bitten here before; tools/failsoft_classify_check.sh carries
# the same note. A newline-delimited string plus a `case` substring test is
# bash-3.2 clean AND still spawns no subprocess per lookup, which was the point
# of hashing them in round 4.
IS_TRACKED="
$TRACKED_LIST
"
IS_PRODUCED="
$PRODUCED
"
# in_set <set> <key> — true when the key is one whole line of the set.
in_set() { case "$1" in *"
$2
"*) return 0 ;; esac; return 1; }

note ""
note "docs-claims PATHS classifiers: $(grep -c . <<< "$TRACKED_LIST") tracked file(s) (git ls-files), $PRODUCED_N build product(s) (make -p)"

# ---------------------------------------------------------------------------
# ROUND 13 (H2) — THE CLASS SAYS WHAT IT IS ABOUT TO DO, AND HOW FAR IT GOT.
# Three CI rounds running, this is the only class that fails on macOS, and
# three rounds running the log has said only what happened AFTERWARDS: six
# "declared population PATHS/... was never visited" lines, printed three
# hundred lines below the class, inside a 20-line tail. Round 12's
# "matched NOTHING" red did not fire either — so the class is not scanning and
# finding nothing, it is not reaching the record at all, and nothing in the log
# distinguishes "the loop never started" from "the loop never finished".
# So the class now states its inputs before it walks, and names each document
# as it reaches it. Six extra lines, and the next failing run is readable.
# ---------------------------------------------------------------------------
path_docs_n=0
for f in $DOC_FILES; do [ -f "$f" ] && path_docs_n=$((path_docs_n + 1)); done
note ""
note "docs-claims class PATHS:"
note "  PATHS: about to walk $path_docs_n document(s) of $(printf '%s\n' $DOC_FILES | grep -c .) named: $DOC_FILES"
note "  PATHS: classifiers — TRACKED_LIST=$(grep -c . <<< "$TRACKED_LIST") entries, PRODUCED=$PRODUCED_N entries (make -p route $PRODUCED_DB_N, Makefile recipe route $PRODUCED_REC_N, variable rules $VAR_RULES_N)"
note "  PATHS: segment alternation = '$seg_alt'"
if [ "$path_docs_n" -eq 0 ]; then
    fail "class PATHS is about to walk ZERO documents — \$DOC_FILES is '$DOC_FILES' and none of them is a file from $(pwd)"
fi

path_examined=0; path_ok=0; path_waived=0; path_product=0
for f in $DOC_FILES; do
    [ -f "$f" ] || continue
    per=0
    note "  PATHS: scanning $f"
    dc_extract "the backticked-path scan of $f" num \
               '`('"$seg_alt"')/[A-Za-z0-9_.*/-]*`' "$f"
    pp_backtick="$DC_SCAN_OUT"
    dc_extract "the inline-link scan of $f" num '[]][(][A-Za-z0-9_./#-]+[)]' "$f"
    pp_inline="$DC_SCAN_OUT"
    dc_extract "the reference-link scan of $f" num \
               '^[[][A-Za-z0-9_.-]+[]]: +[A-Za-z0-9_./#-]+' "$f"
    pp_ref="$DC_SCAN_OUT"
    # The three scans are merged into ONE feed here, ahead of the loop.
    #
    # ROUND 2 (Astra, G6b): Markdown LINK targets are references too, and a
    # dangling [text](docs/NOPE.md) used to pass. Inline and reference-style
    # both; http(s) and bare anchors are not repo paths. A link target resolves
    # relative to its own file's directory, which a backticked path does not.
    #
    # ROUND 14 — WHY A FILE AND NOT `done < <( { … } )`.
    # That is where the macOS failure lived for four rounds. bash 3.2 scans a
    # process substitution for its closing `)` WITHOUT honouring comments, so
    # the apostrophe in "its own file's directory" — in the comment now sitting
    # safely above this line — opened a quote that never closed, and 3.2
    # reported `bad substitution: no closing ')'` at RUNTIME. The whole PATHS
    # class then silently did not run. `bash -n` cannot see it; only RUNNING
    # the file under 3.2 can, which is what [99zb] now does.
    # Removing the apostrophe would have worked and would have left the trap
    # armed for the next person who writes a comment in there. A redirect from
    # a temp file has no closing delimiter for a scanner to lose, and the
    # comments live in ordinary shell text where every bash honours them.
    # This is the FOURTH apostrophe-class bug in this gate (r2 a backtick
    # closed a heredoc, r6 an apostrophe closed a single-quoted table, r10 an
    # unbalanced paren broke $(cat <<EOF), r14 this) — so the rule is now the
    # construct, not the character: NO `<( … )` OR `$( … )` AROUND A
    # MULTI-LINE BLOCK THAT CAN CONTAIN A COMMENT.
    {
        printf '%s\n' "$pp_backtick"
        printf '%s\n' "$pp_inline" | sed -E 's/\]\(/LINK:/; s/\)$//'
        printf '%s\n' "$pp_ref"    | sed -E 's/\[[^]]*\]: +/LINK:/'
    } > "$DC_FEEDFILE"
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"; p="${hit#*:}"
        islink=0
        case "$p" in
            LINK:*) islink=1; p="${p#LINK:}"; p="${p%%#*}" ;;
            *) p="${p%\`}"; p="${p#\`}" ;;
        esac
        # A pure anchor ("#modules") names a heading, not a file.
        [ -z "$p" ] && continue
        case "$p" in http://*|https://*|mailto:*) continue ;; esac
        per=$((per + 1)); path_examined=$((path_examined + 1))
        # ROUND 3 (Astra, H1): a link resolves against the LINKING FILE's
        # directory and NOTHING ELSE. The r2 cut also tried the repo root, so
        # `](docs/STDLIB.md)` written inside docs/BUILTINS.md — which means
        # docs/docs/STDLIB.md — passed. Markdown has one rule; so does this.
        rp="$p"
        [ "$islink" -eq 1 ] && rp="$(dirname "$f")/$p"
        rp="${rp#./}"
        verdict=""
        case "$rp" in
            *'*'*)
                # A glob is matched against the INDEX, not the working tree.
                if grep -qE "^$(sed 's/[.]/[.]/g; s/[*]/[^\/]*/g' <<< "$rp")$" <<< "$TRACKED_LIST"; then
                    verdict="source-glob"
                fi
                ;;
            *)
                if in_set "$IS_TRACKED" "$rp"; then
                    verdict="source"
                elif in_set "$IS_PRODUCED" "$rp"; then
                    verdict="product"
                elif grep -q "^${rp%/}/" <<< "$TRACKED_LIST"; then
                    verdict="source-dir"
                fi
                ;;
        esac
        if [ "$verdict" = "product" ]; then
            # Its EXISTENCE is deliberately not consulted. That is the whole
            # point: `make lsp` must not change this gate's verdict.
            path_product=$((path_product + 1))
            path_ok=$((path_ok + 1))
        elif [ -n "$verdict" ]; then
            # A tracked path must also be on disk. Building never adds or
            # removes a tracked file, so this stays build-state independent.
            if [ "$verdict" != "source" ] || [ -e "$rp" ]; then
                path_ok=$((path_ok + 1))
            else
                fail "$f:$lineno references $rp, which git tracks but is missing from the working tree"
                note "      line: $(sed -n "${lineno}p" "$f")"
            fi
        elif line=$(sed -n "${lineno}p" "$f") && waiver_lookup "$f" "$line"; then
            path_waived=$((path_waived + 1))
            note "  WAIVED  $f:$lineno  \`$p\` — $WAIVER_REASON"
        else
            fail "$f:$lineno references $rp, which git does not track and no Makefile rule produces"
            note "      line: $(sed -n "${lineno}p" "$f")"
        fi
    done < "$DC_FEEDFILE"
    dc_empty_check PATHS "$f" "$per"
    record_found PATHS "$f" "$per"
    note "  population $f: $per repo path(s) (scans: backtick $(grep -c . <<< "$pp_backtick"), inline-link $(grep -c . <<< "$pp_inline"), ref-link $(grep -c . <<< "$pp_ref"))"
done
[ "$path_examined" -eq 0 ] && fail "class PATHS examined 0 paths — a zero population is a broken enumeration, not a clean tree (§121)"
note "  PATHS: examined $path_examined, resolved $path_ok (of which $path_product are build products, verified against the Makefile and NEVER against the filesystem), waived $path_waived"

# ---------------------------------------------------------------------------
# 5. CLASS: FLAGS. EVERY `--flag` token in the enrolled docs must be in
#    `eigenscript --help`, or be waived by its exact line as another tool's
#    flag (docker, make, gh, valgrind...).
#
#    ROUND 2 (Astra, G6a): the first cut matched only `eigenscript --flag`, so
#    a bare `--ver` in prose and a second unknown flag elsewhere both passed.
#    A population defined by the one spelling its author had in mind is the
#    §60 blind spot; the token is the population now.
# ---------------------------------------------------------------------------
#
#    ROUND 7: this class, alone, walks $DOC_FILES_FLAGS rather than
#    $DOC_FILES — see DOC_FILES_FLAGS_EXEMPT at the top of this file for the
#    one document it does not ask about and why. The audit at the end of the
#    class is what stops that exemption from silently widening.
HELP_TXT=$("$EIGS" --help 2>&1)
flag_examined=0; flag_ok=0; flag_waived=0
note ""
note "docs-claims class FLAGS:"
for f in $DOC_FILES_FLAGS; do
    [ -f "$f" ] || continue
    per=0
    dc_extract "the --flag scan of $f" num '--[a-z][a-z0-9-]*' "$f"
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"; flag="--${hit##*--}"
        per=$((per + 1)); flag_examined=$((flag_examined + 1))
        # WHOLE-TOKEN match. A substring match passes every PREFIX of a real
        # flag: `--ver` was accepted because `--version` contains it, which is
        # exactly the false negative Astra planted (G6a).
        if grep -qE -- "(^|[^a-z0-9-])$flag([^a-z0-9-]|\$)" <<< "$HELP_TXT"; then
            flag_ok=$((flag_ok + 1))
        elif waiver_lookup "$f" "$(sed -n "${lineno}p" "$f")"; then
            flag_waived=$((flag_waived + 1))
            note "  WAIVED  $f:$lineno  $flag — $WAIVER_REASON"
        else
            fail "$f:$lineno documents '$flag', which \`eigenscript --help\` does not mention (another tool's flag? waive the exact line with a reason)"
        fi
    done < <(printf '%s\n' "$DC_SCAN_OUT")
    dc_empty_check FLAGS "$f" "$per"
    record_found FLAGS "$f" "$per"
    note "  population $f: $per flag mention(s)"
done
[ "$flag_examined" -eq 0 ] && fail "class FLAGS examined 0 flags — zero population (§121)"
# THE EXEMPTION AUDIT (mechanical-gates §3). Every exempt entry must be a real
# document, must be enrolled for the OTHER classes, and must actually have
# been held out of this one — an exemption naming a file nobody walks, or a
# file that is not in the doc set at all, waives something nobody agreed to.
# And the arithmetic is checked in both directions, so adding a name here
# cannot quietly shrink the class.
# First, the DECLARATION, independently of which doc set this run walks: every
# name in it must be a real file AND must be enrolled by the default doc set.
# An exemption for a document no class walks holds nothing out of anything.
flag_exempt_declared=0
for f in $DOC_FILES_FLAGS_EXEMPT_DEFAULT; do
    flag_exempt_declared=$((flag_exempt_declared + 1))
    [ -f "$f" ] || fail "DOC_FILES_FLAGS_EXEMPT_DEFAULT names '$f', which is not a file — an exemption for a document that does not exist covers nothing and hides the next one"
    case " $DOC_FILES_DEFAULT " in
        *" $f "*) : ;;
        *) fail "DOC_FILES_FLAGS_EXEMPT_DEFAULT names '$f', which DOC_FILES_DEFAULT does not enrol — this list holds a document out of ONE class, it is not a way to leave a document unenrolled" ;;
    esac
done
[ "$flag_exempt_declared" -eq 0 ] && fail "DOC_FILES_FLAGS_EXEMPT_DEFAULT is empty while this class still advertises an exemption — delete the mechanism or name what it covers"
# Then this run: every entry that applied must actually have been held out.
flag_exempt_n=0
for f in $DOC_FILES_FLAGS_EXEMPT; do
    flag_exempt_n=$((flag_exempt_n + 1))
    case " $DOC_FILES_FLAGS " in
        *" $f "*) fail "DOC_FILES_FLAGS_EXEMPT names '$f' and the FLAGS class walked it anyway — the exemption did not fire, so it is a comment, not a waiver" ;;
    esac
done
if [ "$DOCSET_IS_DEFAULT" -eq 1 ] && [ "$flag_exempt_n" -ne "$flag_exempt_declared" ]; then
    fail "the FLAGS class held out $flag_exempt_n document(s) but $flag_exempt_declared are declared exempt — an exemption that no longer fires must be red, not quiet"
fi
flag_docs_n=$(printf '%s\n' $DOC_FILES | grep -c .)
flag_walked_n=$(printf '%s\n' $DOC_FILES_FLAGS | grep -c .)
if [ "$DOCSET_IS_DEFAULT" -eq 1 ] && [ "$flag_walked_n" -ne $((flag_docs_n - flag_exempt_n)) ]; then
    fail "class FLAGS walked $flag_walked_n document(s) of $flag_docs_n with $flag_exempt_n exempt — the arithmetic does not close, so the class is narrower than this file declares"
fi
note "  FLAGS: examined $flag_examined, in --help $flag_ok, waived $flag_waived (walked $flag_walked_n of $flag_docs_n document(s); $flag_exempt_n held out by name:${DOC_FILES_FLAGS_EXEMPT:- none})"

# ---------------------------------------------------------------------------
# 6. CLASS: MAKE TARGETS. Every `make <target>` must be a Makefile rule.
# ---------------------------------------------------------------------------
tgt_examined=0; tgt_ok=0
note ""
note "docs-claims class MAKE TARGETS:"
for f in $DOC_FILES; do
    [ -f "$f" ] || continue
    per=0
    dc_extract "the \`make <target>\` scan of $f" num 'make [a-z][a-z0-9-]*' "$f"
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"; t="${hit##* }"
        per=$((per + 1)); tgt_examined=$((tgt_examined + 1))
        if grep -qE "^${t}:" Makefile; then
            tgt_ok=$((tgt_ok + 1))
        else
            fail "$f:$lineno documents 'make $t', which is not a rule in the Makefile"
        fi
    done < <(printf '%s\n' "$DC_SCAN_OUT" \
             | grep -vE ':make (sure|it|them|the|a|an|this|that|your|no|sense|one|more|up|do|for|use|room|them)$')
    dc_empty_check TARGETS "$f" "$per"
    record_found TARGETS "$f" "$per"
    note "  population $f: $per make target mention(s)"
done
[ "$tgt_examined" -eq 0 ] && fail "class MAKE TARGETS examined 0 targets — zero population (§121)"
note "  MAKE TARGETS: examined $tgt_examined, real rules $tgt_ok"

# ---------------------------------------------------------------------------
# 7. CLASS: NAMES. Every backticked `name of ...` call must resolve.
#    Resolution sources, all derived:
#      - eigenscript --api (builtin / extension / lib, bare and dotted)
#      - the predicate vocabulary, from src/eigenscript.c's EIGS_PREDICATE_NAMES
#      - the lexer's keyword table, from src/lexer.c's strcmp() ladder
#      - a name DEFINED in the same document (define X / X is ...)
#      - an exact-line waiver
# ---------------------------------------------------------------------------
NAMES_API=$("$EIGS" --api | awk '
    $1 == "builtin"   { print $2 }
    $1 == "extension" { print $3 }
    $1 == "lib"       { n = $2; sub(/\(.*/, "", n); print n;
                        m = n; sub(/^[^.]*\./, "", m); print m }' | sort -u)
NAMES_PRED=$(awk '/EIGS_PREDICATE_NAMES[[]/,/[}];/ {
                      s = $0
                      while (match(s, /"[a-z_]+"/)) {
                          t = substr(s, RSTART + 1, RLENGTH - 2); print t
                          s = substr(s, RSTART + RLENGTH)
                      }
                  }' src/eigenscript.c | sort -u)
dc_extract "the lexer keyword-table scan of src/lexer.c" "" \
           'strcmp[(]word, "[a-z_]+"[)]' src/lexer.c
NAMES_KW=$(printf '%s\n' "$DC_SCAN_OUT" | sed -n 's/.*"\(.*\)".*/\1/p' | sort -u)
if [ -z "$NAMES_PRED" ]; then
    fail "the predicate vocabulary could not be read from src/eigenscript.c — the NAMES resolver lost a source"
fi
if [ "$(grep -c . <<< "$NAMES_KW")" -lt 10 ]; then
    fail "the lexer keyword table read back $(grep -c . <<< "$NAMES_KW") entries (< 10) — the NAMES resolver lost a source"
fi

NAME_WAIVERS="host_add host_fn __borrow_guard_selftest fn"
# host_add/host_fn are registered by an EMBEDDING host at runtime (docs/EMBEDDING.md),
# so they are absent from --api by construction; __borrow_guard_selftest is an
# internal debug entry point deliberately kept out of the public index; `fn` is the
# documented metavariable for "the callable you passed" in higher-order signatures
# (`must_not_yield of fn` runs `fn of null`), never a function name.

# Hashed for the same reason as the PATHS classifiers above: 441 names against
# three lists was three processes per name.
IS_NAME="
$NAMES_API
$NAMES_PRED
$NAMES_KW
"

name_examined=0; name_ok=0; name_local=0; name_waived=0
note ""
note "docs-claims class NAMES:"
for f in $DOC_FILES; do
    [ -f "$f" ] || continue
    # Names the document itself introduces. DELIBERATELY NARROW: an earlier
    # cut also accepted `NAME of`, which made every call site define its own
    # callee and the whole class vacuous — 16 "locally defined" names, none of
    # them defined anywhere (mechanical-gates §121, one level down).
    dc_extract "the \`define NAME\` scan of $f" "" 'define [a-z_][a-z_0-9]*' "$f"
    ld_define="$DC_SCAN_OUT"
    dc_extract "the \`NAME is\` scan of $f"     "" '^ *[a-z_][a-z_0-9]* is ' "$f"
    ld_is="$DC_SCAN_OUT"
    dc_extract "the \`NAME(\` scan of $f"       "" '[a-z_][a-z_0-9]*[(]' "$f"
    ld_paren="$DC_SCAN_OUT"
    LOCAL_DEFS=$( { printf '%s\n' "$ld_define" | awk 'NF {print $2}'
                    printf '%s\n' "$ld_is"     | awk 'NF {print $1}'
                    printf '%s\n' "$ld_paren"  | tr -d '(' ; } | sort -u)
    per=0
    dc_extract "the \`name of\` scan of $f" num '`[a-z_][a-z_0-9.]* of[ `]' "$f"
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"; raw="${hit#*:}"
        # Parameter expansion, not printf|sed: two processes per name over a
        # 394-name document was 3 of the gate's 9 seconds.
        n="${raw#\`}"; n="${n%% of*}"; n="${n%\`}"
        [ -z "$n" ] && continue
        per=$((per + 1)); name_examined=$((name_examined + 1))
        if in_set "$IS_NAME" "$n"; then
            name_ok=$((name_ok + 1))
        elif grep -qx -- "$n" <<< "$LOCAL_DEFS"; then
            name_local=$((name_local + 1))
        elif grep -q -- " $n " <<< "$(printf '%s ' $NAME_WAIVERS)"; then
            name_waived=$((name_waived + 1))
        elif waiver_lookup "$f" "$(sed -n "${lineno}p" "$f")"; then
            name_waived=$((name_waived + 1))
            note "  WAIVED  $f:$lineno  \`$n of\` — $WAIVER_REASON"
        else
            fail "$f:$lineno calls \`$n of ...\`, which resolves in neither --api, the predicate vocabulary, the keyword table, nor this document"
        fi
    done < <(printf '%s\n' "$DC_SCAN_OUT")
    dc_empty_check NAMES "$f" "$per"
    record_found NAMES "$f" "$per"
    note "  population $f: $per \`name of\` call(s)"
done
[ "$name_examined" -eq 0 ] && fail "class NAMES examined 0 calls — zero population (§121)"
note "  NAMES: examined $name_examined, in the index $name_ok, defined locally $name_local, waived $name_waived"

# ---------------------------------------------------------------------------
# 7b. CLASS NAMES, subclass BUILTIN FAMILIES. A doc line that NAMES a builtin
#     family claims a family of builtins exists; the index says whether it
#     does.
#
#     BOUGHT 2026-09-21 (#1227, round-4 blind critic Fable's cold read):
#     ROADMAP.md carried "**Raw TCP/UDP sockets** (#414) — shipped" under
#     "### Shipped since this file last claimed them". Measured against the
#     built binary: `--api` lists net_accept/close/dial/listen/port/recv/send
#     and nothing else, `grep -i udp src/*.c src/*.h` is empty, and
#     docs/BUILTINS.md says in prose that UDP is not exposed. The NAMES class
#     could not see it, because the claim is not a `name of` call — it is a
#     family name in English, and #414's title (TCP/UDP) is what the roadmap
#     line was copied from.
#
#     THE RULE: a doc line naming a declared family keyword must find that
#     family's MARKER among the names `eigenscript --api` prints, or carry an
#     exact-line waiver. A line that states the family does NOT exist is the
#     waived shape, and because a waiver is pinned to the EXACT line
#     (mechanical-gates §125), re-asserting the family — putting "UDP" back
#     into a shipped-claim sentence — drops the waiver and goes red by name.
#
#     Each row is `keyword|ERE|marker|what the family is`. The ERE is
#     deliberately looser on its LEFT edge than the thing it polices (§12): the
#     trailing word boundary is enforced, the leading one is not, so
#     `SomethingUDP` is examined rather than missed.
FAMILY_CLAIMS='udp|[Uu][Dd][Pp]|udp|UDP datagram sockets
tcp|[Tt][Cc][Pp]|net_|TCP stream sockets'
# Population, pinned like every other in this gate (§129) and counted in
# MENTIONS, not lines: one sentence naming a family twice is two claims. A
# keyword that stops appearing anywhere makes the class vacuous, so any
# movement in either direction is a review event.
FAMILY_CLAIMS_DECLARED=12

family_examined=0; family_ok=0; family_waived=0
note ""
note "docs-claims class NAMES/BUILTIN FAMILIES:"
FAMILY_API_NAMES=$(printf '%s\n' "$NAMES_API")
while IFS='|' read -r fkw fre fmarker fwhat; do
    [ -n "${fkw:-}" ] || continue
    if grep -qi -- "$fmarker" <<< "$FAMILY_API_NAMES"; then
        fpresent=1
    else
        fpresent=0
    fi
    note "  family $fkw ($fwhat): marker '$fmarker' is $([ "$fpresent" -eq 1 ] && echo 'IN' || echo 'NOT IN') the --api index"
    for f in $DOC_FILES; do
        [ -f "$f" ] || continue
        dc_extract "the '$fkw' family scan of $f" numword "$fre" "$f"
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            lineno="${hit%%:*}"
            fline=$(sed -n "${lineno}p" "$f")
            family_examined=$((family_examined + 1))
            if [ "$fpresent" -eq 1 ]; then
                family_ok=$((family_ok + 1))
            elif waiver_lookup "$f" "$fline"; then
                family_waived=$((family_waived + 1))
                note "  WAIVED  $f:$lineno  names the builtin family $fkw — $WAIVER_REASON"
            else
                fail "$f:$lineno names the builtin family $fkw ($fwhat), and no name in \`eigenscript --api\` carries '$fmarker' — the document claims a family of builtins this tree does not have"
            fi
        done < <(printf '%s\n' "$DC_SCAN_OUT")
    done
done <<EOF
$FAMILY_CLAIMS
EOF
[ "$family_examined" -eq 0 ] && fail "class NAMES/BUILTIN FAMILIES examined 0 family mentions — zero population (§121)"
if [ "$DOCSET_IS_DEFAULT" -eq 1 ] && [ "$family_examined" -ne "$FAMILY_CLAIMS_DECLARED" ]; then
    fail "class NAMES/BUILTIN FAMILIES examined $family_examined family mention(s) but $FAMILY_CLAIMS_DECLARED are declared — a family claim was added or removed; update FAMILY_CLAIMS_DECLARED deliberately after reviewing which"
fi
note "  BUILTIN FAMILIES: examined $family_examined mention(s), family present $family_ok, waived $family_waived"

# ---------------------------------------------------------------------------
# 8. CLASS: DOC ENROLMENT (mechanical-gates §119 — a gate is only as wide as
#    its derivation's REACH). Section [89] executes the documents it is HANDED.
#    A new docs/*.md full of eigenscript fences that nobody added to that list
#    is invisible to it, and invisibly unchecked is the exact failure this
#    round exists to end. So the population is derived HERE, from the tree, and
#    every such file must carry a pinned row in the checker's POPULATION table.
# ---------------------------------------------------------------------------
ENROLMENT_DECLARED=12
enrol_examined=0; enrol_ok=0
note ""
note "docs-claims class DOC ENROLMENT:"
POPTABLE="${DOCS_CLAIMS_POPTABLE:-tests/test_doc_examples.py}"

# ROUND 11 (H1) — ONE AUTHORITY FOR "WHAT IS A FENCE".
# This class used to re-implement the fence grammar as an ERE, right here, so
# it could count fences per document. tests/test_doc_examples.py implements
# the same grammar — and is the gate that EXECUTES the fences, so it is the
# one whose answer matters. Two implementations of one grammar is how they
# disagree, and they did: BSD grep REJECTED the ERE outright, every document
# counted 0, and this whole class measured nothing on macOS while printing a
# number. The count now comes from that file, over a documented interface
# (`--count`, printing `path<TAB>n`), in ONE call; Python is portable where a
# platform's grep is not.
DECLARED_ROWS=$(awk '/^POPULATION = [{]/,/^[}]/ {
                         if (match($0, /^ *"[^"]+":/)) {
                             t = substr($0, RSTART, RLENGTH); gsub(/[ ":]/, "", t); print t
                         }
                     }' "$POPTABLE")
FENCE_FILES=$(
    { for f in README.md docs/*.md docs/llms.txt; do
          [ -f "$f" ] && printf '%s\n' "$f"
      done
      printf '%s\n' "$DECLARED_ROWS" | while IFS= read -r r; do
          [ -n "$r" ] && [ -f "$r" ] && printf '%s\n' "$r"
      done
    } | sort -u)
if [ -z "$FENCE_FILES" ]; then
    fail "DOC ENROLMENT: not one candidate document exists — the tree walk and the declared table both came back empty"
fi
dc_scan "the fence count (python3 $POPTABLE --count)" \
        python3 "$POPTABLE" --count $FENCE_FILES
FENCE_COUNTS="$DC_SCAN_OUT"
# §121 on the new seam: the counter must have answered for every file it was
# handed. A short answer is a scan that stopped early, which would otherwise
# read as "those documents have no examples".
fence_asked=$(grep -c . <<< "$FENCE_FILES")
fence_answered=$(grep -c . <<< "$FENCE_COUNTS")
if [ "$fence_answered" -ne "$fence_asked" ]; then
    fail "the fence counter was handed $fence_asked document(s) and answered for $fence_answered — the count is incomplete, not empty"
fi
# ...and a count of ZERO on BOTH sides is not agreement, it is two broken
# scans agreeing (§121). This is the assertion the misplaced-here-string bug
# above defeated: asked 0, answered 0, 0 -ne 0 is false, green. An equality
# between two derived numbers is only evidence when the numbers exist.
if [ "$fence_asked" -eq 0 ]; then
    fail "the fence counter was handed ZERO documents — \$FENCE_FILES is empty, so the DOC ENROLMENT population is vacuous, not clean"
fi
note "  fence counter: $POPTABLE --count, asked $fence_asked document(s), answered $fence_answered"
fence_count_of() { # file -> its fence count, or the empty string if unanswered
    awk -F'\t' -v f="$1" '$1 == f { print $2; exit }' <<< "$FENCE_COUNTS"
}

for f in README.md docs/*.md docs/llms.txt; do
    [ -f "$f" ] || continue
    n=$(fence_count_of "$f")
    if [ -z "$n" ]; then
        fail "DOC ENROLMENT: the fence counter returned nothing for $f, a file it was handed"
        continue
    fi
    [ "$n" -eq 0 ] && continue
    enrol_examined=$((enrol_examined + 1))
    if grep -qF "\"$f\":" "$POPTABLE"; then
        enrol_ok=$((enrol_ok + 1))
    else
        fail "$f carries $n eigenscript fence(s) but has no row in $POPTABLE's POPULATION table — suite [89] will never execute it"
    fi
done
# ROUND 3 (Astra, H2): the OTHER direction. The loop above walks the tree and
# asks "is this document declared?"; nothing asked "does this declaration name a
# document that actually carries fences?". A 13th POPULATION row for a
# fence-less document left this class at examined 12 / enrolled 12 / declared 12
# and rc 0 — the class that DECLARES the population has to catch its own, not
# rely on the fence checker noticing separately (mechanical-gates §129).
enrol_declared_rows=0
while IFS= read -r row; do
    [ -z "$row" ] && continue
    enrol_declared_rows=$((enrol_declared_rows + 1))
    if [ ! -f "$row" ]; then
        fail "$POPTABLE declares a POPULATION row for '$row', which is not a file"
        continue
    fi
    rn=$(fence_count_of "$row")
    if [ -z "$rn" ]; then
        fail "DOC ENROLMENT: the fence counter returned nothing for the declared row '$row'"
        continue
    fi
    if [ "$rn" -eq 0 ]; then
        fail "$POPTABLE declares a POPULATION row for '$row', which carries NO eigenscript fence — a declaration that matches nothing pins nothing"
    fi
done <<EOF
$DECLARED_ROWS
EOF
if [ "$DOCSET_IS_DEFAULT" -eq 1 ] && [ "$enrol_declared_rows" -ne "$ENROLMENT_DECLARED" ]; then
    fail "$POPTABLE holds $enrol_declared_rows POPULATION rows but $ENROLMENT_DECLARED are declared here — the two tables disagree about how many documents are enrolled"
fi
note "  DOC ENROLMENT: examined $enrol_examined document(s) with eigenscript fences, enrolled $enrol_ok, $enrol_declared_rows POPULATION row(s) (declared $ENROLMENT_DECLARED)"
if [ "$DOCSET_IS_DEFAULT" -eq 1 ] && [ "$enrol_examined" -ne "$ENROLMENT_DECLARED" ]; then
    fail "DOC ENROLMENT examined $enrol_examined documents but $ENROLMENT_DECLARED are declared — a document with eigenscript fences was added or removed"
fi
[ "$enrol_examined" -eq 0 ] && fail "class DOC ENROLMENT examined 0 documents — zero population (§121)"

waivers_audit
declarations_audit

# ---------------------------------------------------------------------------
# ROUND 13 (H1) — THE CLASS SUMMARY, PRINTED LAST.
#
# This is the structural half of this round's fix; the runner printing more
# lines is the tactical half. For three rounds a class that did not run showed
# up only as SIX consequence-REDs ("declared population PATHS/... was never
# visited"), emitted by an audit three hundred lines below the class, while the
# class's own work sat above whatever window the reader had. Whatever the
# window, the LAST lines survive it — so the last lines are now the ones that
# answer "did every class actually run?".
#
# EXAMINED is not the test. A class can examine claims and still record
# nothing; recording is what the declaration audit reads, so recording is what
# this asserts, per class, against the number of rows declared for it.
class_summary() {
    local cls ex noun files declared
    note ""
    note "docs-claims CLASS SUMMARY (printed LAST, so a truncated log still says whether a class ran):"
    while IFS='|' read -r cls ex noun; do
        [ -n "${cls:-}" ] || continue
        files=$(printf '%s\n' "$FOUND" | awk -F'|' -v c="$cls" 'NF >= 3 && $1 == c { n++ } END { print n + 0 }')
        declared=$(printf '%s\n' "$DECLARED_POPULATIONS" | awk -F'|' -v c="$cls" 'NF >= 3 && $1 == c { n++ } END { print n + 0 }')
        if [ "$files" -eq 0 ] && [ "$declared" -gt 0 ] && [ "$DOCSET_IS_DEFAULT" -eq 1 ]; then
            fail "$cls: examined $ex $noun over 0 file(s), recorded 0/$declared declared row(s) — THE CLASS DID NOT RUN. Its per-file loop recorded no document at all, so every '$cls/... was never visited' line ABOVE is a consequence of this one, not a separate fault."
        else
            note "  $cls: examined $ex $noun over $files file(s), recorded $files/$declared declared row(s)"
        fi
    done <<EOF
NUMBERS|$num_examined|numeric claim(s)
PATHS|$path_examined|repo path(s)
FLAGS|$flag_examined|flag mention(s)
TARGETS|$tgt_examined|make target mention(s)
NAMES|$name_examined|\`name of\` call(s)
EOF
    # DOC ENROLMENT keeps no per-file rows — it IS the population check — so it
    # reports its own two numbers rather than borrowing this shape.
    note "  DOC ENROLMENT: examined $enrol_examined document(s) with fences, enrolled $enrol_ok, $ENROLMENT_DECLARED declared"
    note "  (a class that ran prints examined > 0 AND recorded N/N; anything else is the first thing to read)"
}
class_summary

note ""
if [ "$red" -eq 0 ]; then
    note "docs-claims: OK — NUMBERS $num_examined (history-deferred=$hist_deferred), PATHS $path_examined, FLAGS $flag_examined, MAKE TARGETS $tgt_examined, NAMES $name_examined (families $family_examined), DOC ENROLMENT $enrol_examined (every class non-empty)"
else
    note "docs-claims: FAILED (see RED lines above)"
fi
DC_VERDICT_PRINTED=1
exit $red
