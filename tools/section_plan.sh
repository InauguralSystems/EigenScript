#!/bin/bash
# tools/section_plan.sh — derive a per-variant SECTION PLAN for the suite (#1160)
#
# WHY THIS EXISTS
# ---------------
# Ten CI jobs run the SAME ~240-section suite (tests/run_all_tests.sh),
# differing only in the extension surface of the binary they built. Measured on
# PR #1158: 35 min wall, ~200 machine-minutes, 26 checks. A zlib build has
# exactly one section the gcc build does not ([124]); it paid for 240.
#
# So a variant job should run its OWN sections plus a small core smoke. The
# list of "its own sections" must NOT be hand-written: a hand list is a sibling
# list that drifts from the tree and validates nothing (mechanical-gates §1).
#
# WHAT IT IS DERIVED FROM
# -----------------------
# The suite already answers the question itself. Eleven sections are
# PROBE-GATED: the suite writes a tiny .eigs program that names an extension
# builtin, runs it against the binary under test, and skips the section when
# the output says the name is undefined (or, for zlib, when the stub message
# appears). That probe is THE authority on "does this binary have this
# capability", and it is the same code the suite runs.
#
# This tool therefore:
#   1. splits tests/run_all_tests.sh into top-level CHUNKS, asking bash itself
#      where a top-level statement ends (`bash -n` on each candidate prefix) —
#      never a hand-written line table;
#   2. finds every probe site by its STRUCTURE (the <NAME>_PROBE_FILE heredoc,
#      the <NAME>_PROBE_OUT=$(./eigenscript ...) capture, and the `if ! echo
#      ... grep -q "<pattern>"` guard), and refuses to run if a chunk contains
#      a *_PROBE_OUT it cannot parse;
#   3. RUNS each probe program against the binary under test and applies the
#      suite's own predicate;
#   4. emits a filtered runner containing the preamble, the chunks whose
#      capability is present, the fixed core smoke, and the epilogue.
#
# Every count is printed and floored the way [99i] floors its per-target
# examined counts: a plan that SHRINKS is a review event, and a plan of zero
# sections is a hard failure (a job that measured nothing must not be green).
#
# Usage:
#   tools/section_plan.sh --chunks [--runner F]
#       print the derived chunk table (line ranges + section ids)
#   tools/section_plan.sh --probes [--runner F]
#       print the derived probe table (no binary needed)
#   tools/section_plan.sh --print-section-plan <variant> [--binary B]
#       print the plan for <variant>: capabilities, sections, counts, floors
#   tools/section_plan.sh --emit <variant> <outfile> [--binary B]
#       write the filtered runner for <variant>
#   tools/section_plan.sh --skip-audit [--runner F]
#       every SKIP-emitting line in the runner is routed through section_skip()
#       or carries a reviewed reason (the RESULTS line's `N skipped` is a claim)
#   tools/section_plan.sh --selftest
#       planted-fault mutation train (runs against COPIES, never the tree)
#
# Exit 0 = derived and within floors. 1 = a structural failure, an unparsable
# probe, an empty plan, an under-floor plan, or a selftest failure.

set -u

SP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$SP_ROOT/tests/run_all_tests.sh"
BINARY=""
VERBOSE=1

# ---------------------------------------------------------------------------
# Pinned floors. These are the mechanical half of "nothing silently measures
# less": the plan for a variant is DERIVED, and a derived population shrinks
# without anything failing unless a floor watches it (mechanical-gates §43).
#
# ROUND 2 (#1160): the round-1 parser recognised ONE gate spelling — the
# `<X>_PROBE_FILE` / `<X>_PROBE_OUT=$(...)` / `grep -q` block — found 11 of
# them, and pinned a floor of 11. That floor pinned WHAT THE PARSER FOUND, not
# WHAT EXISTS: four more capability gates are spelled differently and were
# dropped from every plan.
#     [97]  an inline `EX_HAS_GFX=0; if ! ./eigenscript "$EX_GFX_PROBE" … ; fi`
#     [138] tools/gfx_pixel_differential.sh self-skips "built without …EXT_GFX"
#     [139] tools/gfx_strict_sweep.sh self-skips the same way
#     [80]  tests/test_replay.sh gates its audio-capture replay checks the same
# A blind critic proved the consequence: plant an undefined builtin in
# examples/ui_dock.eigs, and `EIGS_SUITE_SECTIONS=gfx` was 173/173 GREEN while
# the pre-change gfx job would have failed [97].
#
# So the gates are now DECLARED at the site with a normalised marker,
#     # EIGS-CAP-GATE: <capability>
# and the population is pinned against an INDEPENDENT enumeration (see
# gate_audit below) rather than against the parser's own yield.
CAP_MARKER_FLOOR=15        # markers that must be found in the runner
GATE_HIT_FLOOR=40          # lines the independent enumeration must still find

# Per-variant floors. TWO of them, because each catches a different shrink:
#   caps   - distinct capabilities the binary must actually present. This is
#            what a broken registration trips: `make http` with http_route
#            unregistered still builds and its plan collapses to the smoke.
#   chunks - marked chunks selected. Catches a marker being deleted or a gate
#            losing its marker while the capability is still present.
variant_caps_floor() {
    case "$1" in
        http|asan-http) echo 2 ;;   # http + model
        full)           echo 4 ;;   # http + model + db + net
        db)             echo 1 ;;
        zlib)           echo 1 ;;
        net)            echo 1 ;;
        gfx|asan-gfx)   echo 1 ;;   # gfx is one capability behind nine sections
        core|release)   echo 0 ;;
        *)              echo "" ;;  # unknown variant -> hard error
    esac
}
variant_chunks_floor() {
    case "$1" in
        http|asan-http) echo 3 ;;   # [17] transformer, [44-45] http, [47] model
        full)           echo 5 ;;   # those three + [46] db + [125] net
        db)             echo 1 ;;
        zlib)           echo 1 ;;
        net)            echo 1 ;;
        gfx|asan-gfx)   echo 9 ;;   # [62] [80] [97] [120b] [132] [133] [134] [138] [139]
        core|release)   echo 0 ;;
        *)              echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# The INDEPENDENT enumeration that the marker population is pinned against.
#
# This is the critics' own grep, not the parser's: every line in the runner or
# in a child script the runner dispatches that reads like a capability gate.
# It is deliberately OVER-BROAD (mechanical-gates §12: a cross-check must be
# looser on the axis it polices — here, the SPELLING). Every hit must be either
#   * inside a chunk that carries an EIGS-CAP-GATE marker, or
#   * dispatched from such a chunk (for a child script), or
#   * named in GATE_WAIVERS below, with a reason.
# Anything else is a hard failure: a new gate spelling cannot enter the tree
# without either a marker or a reviewed waiver.
# Round 4 widened this with the SANITIZER axis. A blind critic pointed out that
# section [119] Part B skips on a non-sanitizer binary — a BUILD-VARIANT skip,
# just not an extension one — and the audit could not see it, so its waiver
# carried a reason ("an env flag, not a build variant") that was false. The
# added alternatives are the two SKIP phrasings only, not the words "sanitizer
# build" anywhere: a matcher that fires on prose gets muted (mechanical-gates
# §13). Each hit is classified by WHICH LANE carries it — the ASan shards for
# sanitizer-only sections, the release lane for the ones that skip UNDER a
# sanitizer.
GATE_ENUM_RE='ndefined variable|compiled without zlib|built without|no gfx build|SKIP: non-sanitizer build|SKIP: sanitizer build'

# Each waiver is "<path>|<16-hex sha256 of the EXACT line>|<reason, with an
# excerpt so a reader can see what was waived>". The hash is the pin: edit the
# line, or add another matching line to the same file, and the waiver stops
# matching and the audit refuses. A waiver that matches nothing is also a hard
# failure. Regenerate candidates with `--gate-audit --print-waivers`, which
# prints paste-ready rows for the UNACCOUNTED lines and writes nothing — the
# reason is a human's to write, never the tool's.
GATE_WAIVERS='
tests/run_all_tests.sh|21a0668fa22c22ae|an ERROR-MESSAGE assertion in [16/16] (EM7), not a capability gate
tests/run_all_tests.sh|ffca76c3b2f07310|the EXPECTED TEXT of that same EM7 assertion
tests/run_all_tests.sh|271a756702672bf6|the expected text of the undefined-name error example
tests/run_all_tests.sh|c29802447b0bdd10|prose in the [124b] header comment, above the marked chunk
tests/run_all_tests.sh|b1537f40d9908ca7|prose in the bytecode-verifier comment about a past wrong answer
tests/run_all_tests.sh|96ebb19b3051ac95|prose in the [99s] header comment describing what must stay quiet
tests/run_all_tests.sh|7412a7c777df1655|[99t] treats an undefined name as a REFUSAL it asserts on, not a skip
tests/run_all_tests.sh|afa1df2cc3c846e7|same section, the token half; still a refusal assertion, not a skip
tests/run_all_tests.sh|caf3ea70e21715df|same section, the closure half; still a refusal assertion, not a skip
tests/test_asan_gfx.sh|898c996c43648e4b|the comment above that same OWN-binary probe in the child
tests/test_asan_gfx.sh|eb3773f2d6a0382a|the child BUILDS its own asan-gfx binary and gates on that, not on the suite binary
tests/test_borrow_guard.sh|f17115887aeaf7e5|the BUILD-TYPE probe for section [119] Part B. The opt-in env var IS set on this line, so an undefined name means the borrow guard was compiled OUT, i.e. a non-sanitizer build. It is a build-variant skip on the SANITIZER axis, and its PR-lane coverage is the asan shards, whose union is the full chunk list
tests/test_borrow_guard.sh|2c7e3d903f4f6f5d|case 4 ASSERTS the selftest builtin is absent WITHOUT the opt-in env var. An assertion, not a skip: nothing is gated on it
tests/test_borrow_guard.sh|9a5a23a57e0237b7|the SKIP line that probe reaches on a release build. Section [119] Part B is sanitizer-only; on the PR lane it runs inside the asan shards
tests/run_all_tests.sh|dd8de89ad5db519e|the OBS_G43 witness note: that row SKIPS under a sanitizer because the ASan allocator aborts inside the window. Its PR-lane coverage is the RELEASE lane (the release Linux full-suite job), stated on the line itself
tests/test_temporal_memory.sh|639145631af4d091|skips UNDER a sanitizer because ASan overhead swamps peak RSS. The inverse of a sanitizer-only gate: its PR-lane coverage is the RELEASE lane (the release Linux full-suite job)
tests/test_dict_keys_mt.sh|b74f84cd4e3496fc|prose in a comment about where the captured fixtures came from
tests/test_lint.sh|f2d9b89115c7dd5b|a lint-MESSAGE assertion (W023), not a skip
tests/test_lint.sh|c42c8f00a9515b79|prose in a comment about what the runtime rejects
tests/test_lint.sh|3e6408ca18e23d87|prose in a comment about scope behaviour
tests/test_repl.sh|54a49b9b9630a18f|a REPL behaviour assertion, not a skip
tests/test_strict_math.sh|4f694e51cff1082a|prose about rc=1 being ambiguous, not a skip
tools/strict_differential.sh|1e2356c877a74dfc|prose explaining why variant-only names probe as undefined
tools/strict_differential.sh|b859e99b63f3b7bb|prose in the same comment about --api vs runtime
tools/strict_differential.sh|21747d00883ebb9a|prose about the sentinel that keeps the probe honest
tools/strict_differential.sh|2d366ac396e7a318|CLASSIFIES variant-only names as absent and still reports; it never skips its section
tools/suite_label_check.sh|4b33c19d8075f5f6|prose describing the twin-label phrasing that check allows
tools/suite_label_check.sh|2cc9024e404127f3|prose listing those twin phrasings
tools/docs_claims_check.sh|fd05073ec7e4e3b8|prose in the docs-claims gate QUOTING the SKIPPED-twin wording used by the runner, to explain why the runner has more labelled echo lines (267) than distinct sections (258). A comment about the label grammar, not a capability gate; same class as the two tools/suite_label_check.sh rows above. No apostrophe in this reason: GATE_WAIVERS is a single-quoted string and one would close it
'

# ---------------------------------------------------------------------------
# SKIP ACCOUNTING (#1225 round 7). The suite's RESULTS line prints
# `N skipped`, and the runner's own comment at the counter says "a zero that is
# printed is a claim". Round 6 incremented that counter at exactly ONE site
# ([99i3]) while the runner had ~40 lines that put a SKIP marker on stdout, so
# `linux / gcc` printed `0 skipped` beneath nine of them — including [99i]'s
# `SKIP: NOT MEASURED HERE`, which ci.yml forces on all ten suite jobs
# (measured by a blind critic on the pushed head 1b5c64d, 2026-09-21). The
# claim was false on every lane.
#
# The runner now routes every SECTION-LEVEL skip through one `section_skip`
# helper that prints AND counts. This audit is the structural half: it
# enumerates every line of the runner that can put a SKIP marker on stdout,
# subtracts the ones routed through the helper (they do not match — the helper
# is the only place the literal is written), and requires each remaining line
# to carry a reviewed reason here. A new bare `SKIP:` echo therefore fails BY
# NAME instead of silently joining the uncounted.
#
# The matcher is deliberately OVER-BROAD on the axis it polices, the SPELLING
# (mechanical-gates §12): any `echo`/`printf` whose arguments mention SKIP at
# all, including the section-header twins that say `SKIPPED (binary built
# without ...)` and the relays that grep a child's SKIP line out. It is
# anchored to a command word so it does not fire on prose in comments
# (mechanical-gates §13).
SKIP_EMIT_RE='^[[:space:]]*(echo|printf)[[:space:]].*SKIP'
SKIP_ROUTE_RE='^[[:space:]]*section_skip[[:space:]]'
# Floors, not exact pins, on the two populations — a floor moves only when
# coverage is REMOVED (mechanical-gates §5), and both failure modes here are
# removals: un-routing a section-level skip drops the routed count AND adds an
# unaccounted emitter, so the two halves catch it independently.
SKIP_ROUTED_FLOOR=26
SKIP_EMIT_FLOOR=20
# Each row is "<16-hex sha256 of the EXACT line>|<reason>". The hash is the
# pin: edit the line and the row stops matching, so the reason gets re-read.
# A row that matches nothing is a hard failure (mechanical-gates §3: an
# exemption that no longer fires must fail, not pass quietly). Regenerate
# candidates with `--skip-audit --print-waivers`, which prints paste-ready rows
# for the UNACCOUNTED lines and writes nothing; the reason is a human's.
#
# THE INVENTORY, classified. Three kinds live here and nothing else may:
#   (a) the helper's own print — it IS the counter;
#   (b) lines that mention SKIP without emitting a section verdict: a FAIL
#       line quoting a skip tally, a section TITLE, a PASS line, the RESULTS
#       line itself;
#   (c) SUB-CHECK skips: one line inside a section that still PASSes on its
#       other checks on the same lane. Ten of these remain. They are NOT
#       counted in `skipped`, because `skipped` answers "how many sections
#       measured nothing"; each states which section keeps measuring.
SKIP_WAIVERS='
6ef6a1325edf0172|(a) the section_skip helper own print — this IS the counter the audit polices
d8bbaacdbda76484|(b) the [99n] classifier-gate FAIL line, which QUOTES its own skipped tally; that section fails on any skip
e52b3a5c670b2434|(b) prose inside that same FAIL, explaining why a skipped check there is coverage loss
69614d3ef6dc2f30|(c) sub-check: [17] TR6/TR7 have no old model to reject; the rest of the transformer section still asserts
3f50de963077a3a2|(b) the [119] section TITLE, which names the sanitizer-only half in its own heading
86e12c645c5ad672|(c) sub-check: [119] Part B (the #548 borrow guard) is compiled out on a release build; Part A runs on every build and its PASS/FAIL lines are tallied
ae2397a52e6bf606|(b) the [44] HTTP-readiness FAIL line, which quotes skipped= in its verdict; two skips are the expected witnesses and any other count is already a FAIL there
a3800f950b3f48eb|(b) a diagnostic inside that FAIL branch, printed only when the section is already red
4f08061db27787e7|(b) the [44-45/47] twin section LABEL; the skip beneath it is counted by section_skip
1a610a50ab85b616|(b) the [46/47] twin section LABEL; the skip beneath it is counted by section_skip
b9479b955a96ec10|(b) the [47/47] twin section LABEL; the skip beneath it is counted by section_skip
fab55a18d8a45227|(b) the [62] twin section LABEL; the skip beneath it is counted by section_skip
5ab04254fb943d66|(b) the [120b] twin section LABEL; the skip beneath it is counted by section_skip
8daea9a26364c262|(b) the [133] twin section LABEL; the skip beneath it is counted by section_skip
114496ab68d516e9|(b) the [134] twin section LABEL; the skip beneath it is counted by section_skip
512ecfac87c5101b|(b) the [132] twin section LABEL; the skip beneath it is counted by section_skip
2b1cec4b6df93886|(c) sub-check: [70d] relays the child rows verbatim, one of which SKIPs when GNU time -f is absent; the section still asserts its other two checks
cc548685179a777b|(c) sub-check: the JIT thunk gate on a non-x86_64 host; the JIT section asserts its fast-path checks on every host
00fd233b835a1ddb|(c) sub-check: the EIGS_JIT_HOT gate on a non-x86_64 host; same section, same reason
1d4789fa9df25921|(c) sub-check: --api --json validation needs python3; the --api section asserts its other rows without it
4fd0c1454b26ae7a|(b) an examples-section PASS line that reports how many demos were skipped for want of a gfx build
62be8333b50e395a|(b) the same PASS line on the no-gfx-build arm
89b7a01ff1a79ece|(b) the continuation line of [99i] own skip message; the first line went through section_skip and was counted
27cfdaf9128456df|(b) the RESULTS line itself, which PRINTS the skipped count
43af9bdd1c5e1f94|(c) sub-check: [99zb] relays the portability tool own population/oracle line (widened by #1226 to include NO OLD BASH and other arm wordings); the section fails unless the tool reports OK or one of those named arms — supersedes the pre-#1226 row for this same relay
3291768189ac4afa|(c) sub-check: [99zd] GitHub-live arms (roadmap-check, issue-labels-check) skip by name without gh credentials on this lane; arm (a), the structural check, still asserts on every lane
6a218178486c9285|(b) a [99zd] FAIL-branch diagnostic ("THE GATE SKIPPED ANYWAY") for the roadmap population-line count; printed only when that check is already red
3130e30d76d78869|(c) sub-check: [99zd] relays the roadmap-check own three arm lines by name, one of which may read SKIPPED BY NAME; the section still asserts the other arms and the exact-one-hit count
57a371d78afdfb95|(b) a [99zd] FAIL-branch diagnostic ("THE GATE SKIPPED ANYWAY") for the issue-labels population-line count; printed only when that check is already red
1975191690c57c25|(c) sub-check: [99zd] relays the workflow-yaml-check own OK/SKIPPED BY NAME line on the PASS path; the section still asserts the caller-pinned population regex
3e698b2765ba444e|(c) sub-check: the [99zd] workflow-yaml selftest PASS line reports its own planted skipped-by-name count, probed against this caller own PyYAML import; the section still asserts the pinned expected count
8805589172535e06|(c) sub-check: [99zd] relays the workflow-yaml selftest own SKIPPED BY NAME lines (its planted faults); the section still asserts the pinned pass/skip counts above
'

# ---------------------------------------------------------------------------
# The fixed core smoke. Each entry is a WAIVER (mechanical-gates §3): it states
# why it is in every plan, and an entry that matches no chunk is a hard failure
# — an exemption that no longer fires must fail, not pass quietly.
#
# Kept deliberately small: its job is "this variant's binary is not broken in a
# way that makes the variant sections meaningless", not "retest the language".
# The gcc full-suite job on the same PR is what covers the core.
CORE_SMOKE_IDS="[0]|[1/15]|[19/19]|[99p]"
core_smoke_reason() {
    case "$1" in
        "[0]")     echo "opcode ABI guard - a variant built against a drifted opcode table invalidates every later section" ;;
        "[1/15]")  echo "Gen 0 baseline - the language itself runs on this binary" ;;
        "[19/19]") echo "string & math builtins (75 checks) - the widest cheap core assertion" ;;
        "[99p]")   echo "child-script exit ledger - the vacuity roster; without it a skipped child is invisible" ;;
        *)         echo "" ;;
    esac
}

# ONE work root for the whole process, removed by ONE EXIT trap. Round 3 made
# a temp dir per mode and every `die` path skipped the `rm -rf`, so a box that
# ran the selftest a few times accumulated 129 stale /tmp/eigs_section_plan.*
# dirs. `trap ... EXIT` REPLACES rather than accumulates (mechanical-gates §7),
# so this is the only EXIT trap in this file; anything else that needs cleanup
# puts its directory under $SP_TMPROOT.
SP_TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/eigs_section_plan.XXXXXX") || {
    echo "section_plan: ERROR: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$SP_TMPROOT"' EXIT
sp_workdir() {   # <name> -> a fresh dir under the one root
    local d="$SP_TMPROOT/$1"
    rm -rf "$d"; mkdir -p "$d" || { echo "section_plan: ERROR: cannot create $d" >&2; exit 1; }
    printf '%s\n' "$d"
}

die() { echo "section_plan: ERROR: $*" >&2; exit 1; }

# The ASan shard count has FOUR homes in ci.yml, because GitHub will not
# expand `env` inside `strategy.matrix`: the `ASAN_SHARDS` env, the matrix
# list, the `EIGS_SUITE_SHARD: …/N` literal and the JOB NAME's `(shard …/N)`.
# Prints one line and returns 0 only if all four agree.
# How many `matrix.shard }}/N` homes ci.yml declares: the job name, the step
# name and the EIGS_SUITE_SHARD env value. Pinned, not a floor — a floor let
# one of them be deleted (#1160 round 6). Changing this number is a deliberate
# act and should come with a reason, exactly like CAP_MARKER_FLOOR.
SHARD_LITERAL_HOMES=3

shard_count_sync() {
    local ci="$1" n_env n_matrix n_lit n_name
    n_env=$(sed -n 's/^  ASAN_SHARDS: \([0-9][0-9]*\)$/\1/p' "$ci" | head -1)
    n_matrix=$(sed -n 's/^        shard: \[\(.*\)\]$/\1/p' "$ci" | head -1 | tr -cd ',' | wc -c)
    n_matrix=$((n_matrix + 1))
    # ONE RULE FOR ALL HOMES, rather than a row per known spelling: EVERY
    # `matrix.shard }}/<N>` in the file — job name, step name, env value, any
    # future one — must end in /$n_env. A per-spelling list is the thing that
    # missed the job name in the first place.
    #
    # ROUND 6: "all of them agree" is not enough on its own, because `>= 2`
    # let any ONE of the three be DELETED. Deleting the env-value one was the
    # dangerous case — `EIGS_SUITE_SHARD: ${{ matrix.shard }}` makes a job
    # still named "shard 1/3" run the WHOLE suite, with this check, the
    # aggregator and the receipts all still green. So the POPULATION is pinned
    # the way CAP_MARKER_FLOOR pins its own (a count that may only be changed
    # deliberately), and the load-bearing spelling — the env value the runner
    # actually parses — is required by name.
    n_lit=$(grep -coE 'matrix\.shard \}\}/[0-9]+' "$ci")
    n_bad=$(grep -oE 'matrix\.shard \}\}/[0-9]+' "$ci" | grep -vc "/$n_env\$")
    n_envval=$(grep -c "EIGS_SUITE_SHARD: \${{ matrix.shard }}/$n_env\$" "$ci")
    if [ -n "$n_env" ] && [ "$n_env" = "$n_matrix" ] \
       && [ "$n_lit" -eq "$SHARD_LITERAL_HOMES" ] && [ "$n_bad" -eq 0 ] && [ "$n_envval" -eq 1 ]; then
        echo "the ASan shard count agrees everywhere in ci.yml (ASAN_SHARDS=$n_env, matrix legs=$n_matrix, all $n_lit of $SHARD_LITERAL_HOMES 'matrix.shard }}/N' homes say /$n_env, EIGS_SUITE_SHARD among them)"
        return 0
    fi
    echo "ci.yml shard count disagrees (ASAN_SHARDS=${n_env:-unset}, matrix legs=$n_matrix, 'matrix.shard }}/N' occurrences=$n_lit of $SHARD_LITERAL_HOMES expected, $n_bad not saying /$n_env, EIGS_SUITE_SHARD:/$n_env present=$n_envval)"
    return 1
}


# Waivers are pinned to EXACT LINE CONTENT, by hash. Round 2 pinned them by
# SUBSTRING, and a blind critic walked straight through it: the entry
# `tests/test_lint.sh|undefined|lint-message assertions, not a skip` matched
# ANY line in that file containing "undefined", so a real capability gate
# planted into that file inherited a reason that is false for it and the audit
# printed unaccounted=0. A waiver must name the line a human actually reviewed
# (mechanical-gates §3: a named exemption is unbounded unless pinned), so a
# waived FILE gaining a NEW matching line is unaccounted and refused.
if command -v sha256sum >/dev/null 2>&1; then SP_HASHER="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SP_HASHER="shasum -a 256"
else die "no sha256sum and no shasum on PATH — waivers cannot be content-pinned"; fi
sp_line_hash() { printf '%s' "$1" | $SP_HASHER | cut -c1-16; }
note() { [ "$VERBOSE" = "1" ] && echo "$*" >&2; return 0; }

# ---------------------------------------------------------------------------
# Chunk derivation.
#
# A chunk is a whole number of TOP-LEVEL statements. We do not parse shell —
# we ask bash where a top-level statement boundary is: a prefix of the file
# that ends on a boundary parses with `bash -n`; one that ends inside an
# `if`/heredoc/loop does not. Candidates are column-0 section headers, column-0
# `# [nn]` section comments, and column-0 probe-file assignments (the probe
# setup sits BEFORE the header, which is indented inside the probe's `if`).
#
# Outputs, to stdout, one chunk per line:  <start> <end> <ids...>
# Sets globals: SP_PREAMBLE_END, SP_EPILOGUE_START, SP_TOTAL_LINES
derive_chunks() {
    local f="$1"
    SP_TOTAL_LINES=$(wc -l < "$f" | tr -d ' ')

    # Epilogue anchor. Pinned and required to be UNIQUE: if it moves or is
    # duplicated the tool stops rather than guessing (a gate that guesses its
    # own boundary is the gate that silently measures less).
    local anchors
    anchors=$(grep -n '^# Final guard (#681)' "$f" | cut -d: -f1)
    local n_anchor
    n_anchor=$(printf '%s\n' "$anchors" | grep -c '[0-9]')
    [ "$n_anchor" = "1" ] || die "epilogue anchor '# Final guard (#681)' matched $n_anchor times in $f (need exactly 1)"
    SP_EPILOGUE_START="$anchors"

    # The prefix test is incremental, and that is a correctness argument, not
    # only a speed one: once PREV is known to be a top-level boundary, the file
    # up to L-1 parses iff the SEGMENT [PREV, L-1] parses on its own (a valid
    # prefix followed by a complete script is a valid prefix). Testing the
    # segment instead of the whole prefix turns 600 parses of a 7,000-line file
    # into 600 parses of ~15 lines.
    local cand boundaries="" L prev=""
    cand=$(grep -nE '^(echo "\[|# \[[0-9]|[A-Za-z_][A-Za-z0-9_]*_FILE=)' "$f" | cut -d: -f1)
    for L in $cand; do
        [ "$L" -lt "$SP_EPILOGUE_START" ] || continue
        [ "$L" -gt 1 ] || continue
        if [ -z "$prev" ]; then
            # First boundary only: the whole prefix has to be tested, because
            # there is no known-good anchor to measure a segment from.
            if head -n $((L - 1)) "$f" | bash -n 2>/dev/null; then
                boundaries="$L"; prev="$L"
            fi
            continue
        fi
        [ "$L" -gt "$prev" ] || continue
        if sed -n "${prev},$((L - 1))p" "$f" | bash -n 2>/dev/null; then
            boundaries="$boundaries $L"; prev="$L"
        fi
    done
    [ -n "$boundaries" ] || die "no top-level chunk boundary found in $f"

    # shellcheck disable=SC2086
    set -- $boundaries
    SP_PREAMBLE_END=$(( $1 - 1 ))

    local start end ids
    while [ "$#" -gt 0 ]; do
        start="$1"; shift
        if [ "$#" -gt 0 ]; then end=$(( $1 - 1 )); else end=$(( SP_EPILOGUE_START - 1 )); fi
        ids=$(sed -n "${start},${end}p" "$f" \
              | grep -oE 'echo "\[[^]]*\]' \
              | sed 's/^echo "//' \
              | tr '\n' ' ')
        printf '%s %s %s\n' "$start" "$end" "$ids"
    done
}

# Partition control: preamble + every chunk + epilogue must reconstruct the
# file byte-for-byte. Without it a boundary bug silently DROPS sections and
# every surviving assertion still passes.
verify_partition() {
    local f="$1" table="$2" tmp
    tmp=$(mktemp)
    [ "$SP_PREAMBLE_END" -ge 1 ] && sed -n "1,${SP_PREAMBLE_END}p" "$f" > "$tmp"
    local s e
    while read -r s e _rest; do
        [ -n "$s" ] || continue
        sed -n "${s},${e}p" "$f" >> "$tmp"
    done < "$table"
    sed -n "${SP_EPILOGUE_START},\$p" "$f" >> "$tmp"
    if ! cmp -s "$tmp" "$f"; then
        rm -f "$tmp"
        die "chunk table is not a partition of $f (preamble+chunks+epilogue != file)"
    fi
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# SHARDING (#1160 round 4).
#
# Measured on the real PR run (34962403732, head 25ade7e): 21.1 min wall, and
# the ENTIRE critical path was one job — `asan + ubsan / core and LSP`, 19.0
# min, of which 13.9 min was the suite step. That job stays FULL on purpose
# (it is the leak-tally gate), so the only way under 15 min is to run it as
# parallel shards.
#
# A shard is a SUBSET OF THE CHUNK LIST — the same chunks the capability plans
# select from — so "the shards cover the suite" is checkable as a set identity
# rather than believed: `--shards N --check` asserts the union equals the full
# chunk list and that the shards are pairwise disjoint.
#
# Balance is by MEASURED WEIGHT, never by count: section costs span three
# orders of magnitude, so equal counts would leave one shard carrying most of
# the time. Weights come from tests/section_weights.txt (regenerate with
# `--print-weights <suite-log>` from a run's SECTION_TIME lines). A section
# missing from the table gets SHARD_DEFAULT_CS and is REPORTED, so a new
# section cannot silently unbalance a shard.
#
# The split is deterministic — longest-processing-time greedy over
# (weight desc, chunk start asc) — so CI never depends on runner timing.
WEIGHTS_FILE_DEFAULT="tests/section_weights.txt"
SHARD_DEFAULT_CS=50          # centiseconds for an unmeasured section (0.5 s)

# chunk weights -> "<centiseconds> <chunk-start>" per line, plus the roster of
# section labels that had no measurement.
derive_chunk_weights() {
    local table="$1" out="$2" missing="$3"
    local wf="${WEIGHTS_FILE:-$WEIGHTS_FILE_DEFAULT}"
    # `: ;;` not `;;` — bash 3.2 cannot parse an empty inline arm (see
    # tools/docs_claims_check.sh and .claude/rules/test-suite.md). Pre-existing
    # here and never hit, because this tool runs on the linux lane only.
    case "$wf" in /*) : ;; *) wf="$SP_ROOT/$wf" ;; esac
    : > "$missing"
    if [ ! -f "$wf" ]; then
        SP_WEIGHTS_SOURCE="(none: $wf missing — every section takes the default)"
        awk -v def="$SHARD_DEFAULT_CS" '{ print def, $1 }' "$table" > "$out"
        awk '{ rest = $0; sub(/^[0-9]+[ \t]+[0-9]+[ \t]*/, "", rest)
               while (match(rest, /\[[^]]*\]/)) { print substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH) } }' \
            "$table" | sort -u > "$missing"
    else
        SP_WEIGHTS_SOURCE="$wf"
        awk -v def="$SHARD_DEFAULT_CS" -v missfile="$missing" '
            FNR == NR {
                if ($0 ~ /^\[/) {
                    j = index($0, "]")
                    if (j > 0) { lbl = substr($0, 1, j); w[lbl] += int($NF * 100 + 0.5) }
                }
                next
            }
            {
                # The ids field is space-separated and a label may itself
                # contain spaces, so walk the bracketed tokens with a regex
                # rather than by field index.
                start = $1; total = 0; seen = ""
                rest = $0
                sub(/^[0-9]+[ \t]+[0-9]+[ \t]*/, "", rest)
                while (match(rest, /\[[^]]*\]/)) {
                    id = substr(rest, RSTART, RLENGTH)
                    rest = substr(rest, RSTART + RLENGTH)
                    if (index(seen, "|" id "|") > 0) continue
                    seen = seen "|" id "|"
                    if (id in w) total += w[id]
                    else { total += def; print id > missfile }
                }
                print total, start
            }
        ' "$wf" "$table" > "$out"
    fi
    sort -u "$missing" -o "$missing"
    SP_WEIGHT_MISSING=$(grep -c . "$missing")
}

# Chunks are NOT independent: a few read a variable a NEIGHBOUR assigned.
# Measured by running the shards (round 4): section [115b] reads $BIN_ABS, which
# [115]'s chunk assigns, and in a shard that held [115b] without [115] the
# emitted runner ran `"" main.eigs` — "command not found" on stderr, which
# [115b] then reported as two real failures. `bash -n` cannot see that; only
# executing the shards did.
#
# So chunks are grouped into shard-ATOMIC units before the split: if a chunk
# references a name that no preamble line assigns and some EARLIER chunk does,
# the two are merged (nearest preceding assigner — that is the runtime
# semantics, and it also kills the obvious false positive, a loop variable
# `i` assigned only in LATER chunks). The count of merges is printed, because a
# grouping nobody sees is a grouping nobody can review.
# Emits "<chunk-start> <group-leader-start>".
derive_chunk_groups() {
    local table="$1" out="$2"
    awk -v pre_end="$SP_PREAMBLE_END" '
        FNR == NR { n++; cs[n] = $1; ce[n] = $2; next }
        {
            line = FNR
            if (line <= pre_end) { scope = 0 }
            else {
                scope = 0
                while (cur < n && line > ce[cur]) cur++
                if (cur >= 1 && cur <= n && line >= cs[cur] && line <= ce[cur]) scope = cur
                else if (cur < n && line >= cs[cur + 1]) { cur++; if (line <= ce[cur]) scope = cur }
            }
            body = $0
            # ---- assignments, with the POSITION they happen at -------------
            # Round 5 (Astra): position matters. Round 4 recorded only
            # (name, chunk) and treated ANY same-chunk assignment as satisfying
            # EVERY read in that chunk — so a read that PRECEDES a later
            # same-chunk reassignment lost its producer in an earlier chunk,
            # the chunks were not merged, and the consumer shard printed an
            # empty value and exited 0. Assignments and reads now carry
            # (line, column) and a read is satisfied only by an assignment
            # EARLIER IN PROGRAM ORDER.
            if (match(body, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
                nm = substr(body, RSTART, RLENGTH - 1); gsub(/^[ \t]+/, "", nm)
                if (scope == 0) pre[nm] = 1
                else record_asg(nm, scope, line, RSTART)
            }
            # Mid-line assignments (`cmd; NAME=v`, `a && NAME=v`) — the dual of
            # the same bug: a producer the scanner cannot see is a merge it
            # cannot make.
            rest2 = body; off2 = 0
            while (match(rest2, /[;&|(][ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
                t = substr(rest2, RSTART, RLENGTH); col = off2 + RSTART
                off2 += RSTART + RLENGTH - 1
                rest2 = substr(rest2, RSTART + RLENGTH)
                sub(/^[;&|(][ \t]*/, "", t); sub(/=$/, "", t)
                if (scope == 0) pre[t] = 1; else record_asg(t, scope, line, col)
            }
            if (match(body, /^[ \t]*(local|export|declare)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
                t = substr(body, RSTART, RLENGTH); sub(/^[ \t]*(local|export|declare)[ \t]+/, "", t)
                if (scope == 0) pre[t] = 1; else record_asg(t, scope, line, RSTART)
            }
            if (match(body, /for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in/)) {
                t = substr(body, RSTART, RLENGTH); sub(/^for[ \t]+/, "", t); sub(/[ \t]+in$/, "", t)
                if (scope == 0) pre[t] = 1; else record_asg(t, scope, line, RSTART)
            }
            # ---- reads, with their position --------------------------------
            if (scope > 0) {
                rest = body; off = 0
                while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
                    v = substr(rest, RSTART, RLENGTH); col = off + RSTART
                    off += RSTART + RLENGTH - 1
                    rest = substr(rest, RSTART + RLENGTH)
                    gsub(/[$\{]/, "", v)
                    nr++; rv[nr] = v; rc[nr] = scope; rl[nr] = line; rk[nr] = col
                }
            }
        }
        END {
            for (i = 1; i <= n; i++) parent[i] = i
            for (j = 1; j <= nr; j++) {
                v = rv[j]; c = rc[j] + 0
                if (v in pre) continue
                if (!(v in names)) continue
                if (satisfied_before(v, c, rl[j], rk[j])) continue
                best = 0
                for (i = 1; i < c; i++) if ((v SUBSEP i) in A) best = i
                if (best == 0) continue
                ra = find(c); rb = find(best)
                if (ra != rb) {
                    if (ra < rb) parent[rb] = ra; else parent[ra] = rb
                    merges++
                    printf "MERGE %s %d %d\n", v, cs[best], cs[c] > "/dev/stderr"
                }
            }
            for (i = 1; i <= n; i++) printf "%d %d\n", cs[i], cs[find(i)]
            printf "MERGES %d\n", merges + 0 > "/dev/stderr"
        }
        # Only the EARLIEST assignment of a name in a chunk can matter: if that
        # one is not before the read, none is. Keeping just the minimum keeps
        # the lookup O(1) — scanning every assignment per read was O(reads x
        # assignments) and took the selftest from minutes to over ten.
        function record_asg(nm, sc, ln, col,   k) {
            na++
            k = nm SUBSEP sc
            if (!(k in A) || ln < minl[k] || (ln == minl[k] && col < minc[k])) {
                minl[k] = ln; minc[k] = col
            }
            A[k] = 1; names[nm] = 1
        }
        # A same-chunk assignment counts only if it happens BEFORE the read in
        # program order: an earlier line, or the same line at an earlier column.
        function satisfied_before(v, c, ln, col,   k) {
            k = v SUBSEP c
            if (!(k in A)) return 0
            if (minl[k] < ln) return 1
            if (minl[k] == ln && minc[k] < col) return 1
            return 0
        }
        function find(x) { while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x] } return x }
    ' "$table" "$RUNNER" > "$out" 2> "$out.merges"
    SP_GROUP_MERGES=$(sed -n 's/^MERGES \([0-9]*\)$/\1/p' "$out.merges")
    : "${SP_GROUP_MERGES:=0}"
    SP_GROUP_MERGE_LIST=$(sed -n 's/^MERGE /  merged: /p' "$out.merges")
    SP_GROUPS=$(cut -d' ' -f2 "$out" | sort -u | grep -c .)
}


# Deterministic longest-processing-time greedy. Emits "<chunk-start> <shard>".
derive_shard_assignment() {
    local n="$1" weights="$2" out="$3" groups="${4:-}"
    if [ -n "$groups" ]; then
        # Aggregate each group's weight onto its leader, split the LEADERS, then
        # expand back: a group is indivisible, so the balance is over groups.
        local W2="$SP_TMPROOT/grp"
        mkdir -p "$W2"
        awk 'FNR == NR { g[$1] = $2; next } { lead = ($2 in g) ? g[$2] : $2; t[lead] += $1 }
             END { for (k in t) print t[k], k }' "$groups" "$weights" > "$W2/gw"
        sort -k1,1nr -k2,2n "$W2/gw" \
          | awk -v n="$n" '
                BEGIN { for (i = 1; i <= n; i++) { load[i] = 0; cnt[i] = 0 } }
                {
                    best = 1
                    for (i = 2; i <= n; i++)
                        if (load[i] < load[best] || (load[i] == load[best] && cnt[i] < cnt[best])) best = i
                    load[best] += $1; cnt[best]++
                    print $2, best
                }
            ' > "$W2/ga"
        awk 'FNR == NR { sh[$1] = $2; next } { print $1, sh[$2] }' "$W2/ga" "$groups" | sort -n > "$out"
        return 0
    fi
    sort -k1,1nr -k2,2n "$weights" \
      | awk -v n="$n" '
            BEGIN { for (i = 1; i <= n; i++) { load[i] = 0; cnt[i] = 0 } }
            {
                # Ties break on chunk COUNT, then on index, so a table of equal
                # weights round-robins instead of piling every chunk into
                # bucket 1 (which is what an unmeasured tree does).
                best = 1
                for (i = 2; i <= n; i++)
                    if (load[i] < load[best] || (load[i] == load[best] && cnt[i] < cnt[best])) best = i
                load[best] += $1; cnt[best]++
                print $2, best
            }
        ' | sort -n > "$out"
}

shard_loads() {   # "<shard> <chunks> <seconds>" per shard
    local weights="$1" assign="$2" n="$3"
    awk -v n="$n" '
        FNR == NR { w[$2] = $1; next }
        { c[$2]++; t[$2] += w[$1] }
        END { for (i = 1; i <= n; i++) printf "%d %d %d.%02d\n", i, c[i] + 0, t[i] / 100, t[i] % 100 }
    ' "$weights" "$assign"
}

# The pin: union == the full chunk list, and pairwise disjoint. Both directions
# (mechanical-gates §2) — "every chunk is in a shard" and "no chunk is in two"
# fail differently, and only the second catches a duplicated chunk.
shard_check() {
    local n="$1"
    validate_shards "$n"
    local W; W=$(sp_workdir shards)
    derive_chunks "$RUNNER" > "$W/chunks"
    verify_partition "$RUNNER" "$W/chunks"
    derive_chunk_weights "$W/chunks" "$W/weights" "$W/missing"
    derive_chunk_groups "$W/chunks" "$W/groups"
    derive_shard_assignment "$n" "$W/weights" "$W/assign" "$W/groups"

    # TEST-ONLY mutation seam, used by --selftest to prove this check fires.
    # It can only REMOVE or DUPLICATE an assignment — never add coverage — so
    # the worst it can do is turn the check red, and it announces itself.
    case "${SP_SHARD_MUTATE:-}" in
        drop) echo "section_plan: WARNING: SP_SHARD_MUTATE=drop — one chunk removed from every shard (selftest seam)" >&2
              sed -i '1d' "$W/assign" ;;
        dup)  echo "section_plan: WARNING: SP_SHARD_MUTATE=dup — one chunk placed in two shards (selftest seam)" >&2
              head -1 "$W/assign" | awk -v n="$n" '{ print $1, ($2 % n) + 1 }' >> "$W/assign"
              sort -n -o "$W/assign" "$W/assign" ;;
    esac

    local total assigned uniq
    total=$(grep -c '[0-9]' "$W/chunks")
    assigned=$(grep -c '[0-9]' "$W/assign")
    cut -d' ' -f1 "$W/assign" | sort -n -u > "$W/assigned_uniq"
    uniq=$(grep -c '[0-9]' "$W/assigned_uniq")
    cut -d' ' -f1 "$W/chunks" | sort -n > "$W/all_chunks"

    [ "$assigned" = "$uniq" ] || die "shards OVERLAP: $assigned assignments over $uniq distinct chunks — a chunk in two shards is counted twice and its failures are reported twice"
    if ! cmp -s "$W/all_chunks" "$W/assigned_uniq"; then
        echo "section_plan: ERROR: the shard union is not the full chunk list:" >&2
        diff "$W/all_chunks" "$W/assigned_uniq" | head -20 >&2
        die "union != full — a chunk in no shard is a section that silently left CI"
    fi
    [ "$uniq" = "$total" ] || die "shard union covers $uniq of $total chunks"
    # More shards than chunks cannot produce N non-empty shards, and the
    # per-shard loop below would report the shortfall one shard at a time.
    [ "$n" -le "$total" ] || die "asked for $n shards over $total chunks — at least one shard would be empty"

    local i cnt
    for i in $(seq 1 "$n"); do
        cnt=$(awk -v k="$i" '$2 == k' "$W/assign" | grep -c .)
        [ "$cnt" -gt 0 ] || die "shard $i/$n got ZERO chunks — a job that measures nothing must not be green"
    done

    if [ "$VERBOSE" = "1" ]; then
        echo "weights: $SP_WEIGHTS_SOURCE"
        if [ "$SP_WEIGHT_MISSING" -gt 0 ]; then
            echo "UNMEASURED sections (default ${SHARD_DEFAULT_CS}cs each) — refresh the weights table:"
            sed 's/^/  /' "$W/missing"
        fi
        if [ -n "$SP_GROUP_MERGE_LIST" ]; then
            echo "chunk groups merged for a cross-chunk variable dependency:"
            printf '%s\n' "$SP_GROUP_MERGE_LIST"
        fi
        shard_loads "$W/weights" "$W/assign" "$n" \
          | while read -r k c t; do echo "  shard $k/$n: chunks=$c weight=${t}s"; done
    fi
    echo "SHARDS: n=$n chunks=$total groups=$SP_GROUPS (merges=$SP_GROUP_MERGES) union=full disjoint=yes zero-section-shards=0 unmeasured-sections=$SP_WEIGHT_MISSING"
}

# WHICH SHARD OWNS A JOB-LEVEL EXTRA (#1160 round 6).
#
# The ASan job has two steps that are not suite sections: the collector
# traversal check and the LSP behaviour test. Round 4 hard-wired both to shard
# 1 — and shard 1 is, by construction, the HEAVIEST shard, so the extras land
# on the critical path every time. Measured: on run 35036548663 shard 1 was
# 14.1 min end to end of a 15.0 min lane, 4.5 min of it the LSP step.
#
# Worse, that step's cost is not even a constant. On run 35020270020 the same
# step took 1.5 s, because shard 1 happened to carry section [88], which builds
# eigenlsp under ASan through tests/aux_binary.sh — the step's own build was
# then a no-op. When the CI-measured weights moved [88] to shard 3, the step
# had to build eigenlsp from scratch: 267 s. So the owner is DERIVED:
#
#   --shard-owner N --section '[88]'   the shard running that section (the one
#                                      that has already paid for the build)
#   --shard-owner N                    the LIGHTEST shard by predicted weight
#
# Always prints exactly one integer in 1..N, so a step can compare it with its
# own matrix index; the aggregator then requires exactly one shard to claim
# each extra, which is what stops "derived" from becoming "nobody ran it".
shard_owner() {
    local n="$1" section="${2:-}"
    validate_shards "$n"
    SP_WORK="${SP_WORK:-$(sp_workdir owner)}"
    derive_chunks "$RUNNER" > "$SP_WORK/chunks"
    derive_chunk_weights "$SP_WORK/chunks" "$SP_WORK/weights" "$SP_WORK/missing"
    derive_chunk_groups "$SP_WORK/chunks" "$SP_WORK/groups"
    derive_shard_assignment "$n" "$SP_WORK/weights" "$SP_WORK/assign" "$SP_WORK/groups"

    if [ -n "$section" ]; then
        local start owner
        start=$(awk -v id="$section" '{ for (i = 3; i <= NF; i++) if ($i == id) { print $1; exit } }' "$SP_WORK/chunks")
        [ -n "$start" ] || die "no chunk carries section '$section' — the extra it owns has no home"
        owner=$(awk -v s="$start" '$1 == s { print $2 }' "$SP_WORK/assign")
        [ -n "$owner" ] || die "section '$section' is in chunk @$start, which no shard claimed"
        echo "$owner"
        return 0
    fi
    shard_loads "$SP_WORK/weights" "$SP_WORK/assign" "$n" \
      | sort -k3,3g -k1,1n | head -1 | cut -d' ' -f1
}

# The plan for ONE shard. Sets SP_WORK/selected like build_plan does.
build_shard_plan() {
    local k="$1" n="$2"
    validate_shards "$n"
    validate_shards "$k"
    [ "$k" -ge 1 ] && [ "$k" -le "$n" ] || die "shard index $k is outside 1..$n"
    SP_WORK="${SP_WORK:-$(sp_workdir plan)}"
    derive_chunks "$RUNNER" > "$SP_WORK/chunks"
    verify_partition "$RUNNER" "$SP_WORK/chunks"
    derive_markers "$RUNNER" "$SP_WORK/chunks" > "$SP_WORK/markers"
    derive_probes "$RUNNER" "$SP_WORK/chunks" "$SP_WORK" > "$SP_WORK/probes"
    verify_probe_coverage "$SP_WORK/markers" "$SP_WORK/probes"
    derive_chunk_weights "$SP_WORK/chunks" "$SP_WORK/weights" "$SP_WORK/missing"
    derive_chunk_groups "$SP_WORK/chunks" "$SP_WORK/groups"
    derive_shard_assignment "$n" "$SP_WORK/weights" "$SP_WORK/assign" "$SP_WORK/groups"

    # A shard carries capability-gated chunks too, and on a binary without that
    # capability the chunk takes its else branch — which sometimes prints NOTHING.
    # The promised section count has to know that, or the runner's own
    # plan-vs-printed check fires on a correct run.
    resolve_binary "shard"
    compute_capabilities

    SP_SECTION_TOTAL=$(grep -coE 'echo "\[[^]]*\]' "$RUNNER")
    awk -v k="$k" '$2 == k { print $1 }' "$SP_WORK/assign" | sort -n > "$SP_WORK/selected"
    SP_SEL_CHUNKS=$(grep -c '[0-9]' "$SP_WORK/selected")
    [ "$SP_SEL_CHUNKS" -gt 0 ] || die "shard $k/$n selected ZERO chunks"

    local s e nsec mcap mv branch
    SP_SEL_SECTIONS=0
    while read -r s; do
        [ -n "$s" ] || continue
        e=$(awk -v ss="$s" '$1==ss {print $2}' "$SP_WORK/chunks")
        mcap=$(awk -F'\t' -v ss="$s" '$1==ss {print $2}' "$SP_WORK/markers")
        branch=present
        if [ -n "$mcap" ]; then
            mv=$(awk -F'\t' -v c="$mcap" '$1==c {print $2}' "$SP_WORK/caps")
            [ "$mv" = "present" ] || branch=absent
        fi
        nsec=$(chunk_executed_headers "$s" "$e" "$branch")
        SP_SEL_SECTIONS=$((SP_SEL_SECTIONS + nsec))
    done < "$SP_WORK/selected"
    [ "$SP_SEL_SECTIONS" -gt 0 ] || die "shard $k/$n selected ZERO sections — a job that measures nothing must not be green"

    local wsec
    wsec=$(shard_loads "$SP_WORK/weights" "$SP_WORK/assign" "$n" | awk -v k="$k" '$1 == k {print $3}')
    if [ "$VERBOSE" = "1" ]; then
        note "shard $k/$n sections:"
        while read -r s; do
            [ -n "$s" ] || continue
            e=$(awk -v ss="$s" '$1==ss {print $2}' "$SP_WORK/chunks")
            note "  chunk @$s  $(awk -v ss="$s" '$1==ss {$1="";$2="";print}' "$SP_WORK/chunks" | sed 's/^  *//')"
        done < "$SP_WORK/selected"
    fi
    note "shard=$k/$n  weights: $SP_WEIGHTS_SOURCE  unmeasured sections: $SP_WEIGHT_MISSING"
    [ "$SP_WEIGHT_MISSING" -gt 0 ] && note "UNMEASURED (default ${SHARD_DEFAULT_CS}cs each): $(tr '\n' ' ' < "$SP_WORK/missing")"
    echo "PLAN: shard=$k/$n sections=$SP_SEL_SECTIONS (of $SP_SECTION_TOTAL) chunks=$SP_SEL_CHUNKS predicted=${wsec}s unmeasured=$SP_WEIGHT_MISSING"
}

# Regenerate the weights table from a suite log's SECTION_TIME lines. Duplicate
# labels are SUMMED — a section whose header is echoed twice in one run (the
# [45a] live/selftest loop) really does cost both.
print_weights() {
    local log="$1"
    [ -f "$log" ] || die "no such log: $log"
    # A raw CI job log (`gh api .../jobs/<id>/logs`) prefixes every line with an
    # ISO timestamp, so the pattern tolerates one rather than making the caller
    # strip it by hand — a manual pre-step is a step someone does differently.
    # The floor is the RUNNER'S OWN label population, not a magic 50. A single
    # shard log has ~78 rows and sailed through the old floor, which would have
    # produced a table with ~160 sections silently taking the default weight —
    # and a default-weighted section is exactly what the table exists to stop.
    # The input for a sharded lane is the shard logs CONCATENATED.
    local n distinct want
    n=$(grep -cE '^([0-9-]+T[0-9:.]+Z )?SECTION_TIME: ' "$log")
    distinct=$(grep -oE 'SECTION_TIME: \[[^]]*\]' "$log" | sort -u | grep -c .)
    want=$(grep -oE 'echo "\[[^]]*\]' "$RUNNER" | sort -u | grep -c .)
    # 85%, not 100%: on any one binary some capability-gated sections never
    # print at all (the http/model/net ones do not exist in an ASan build), so
    # requiring every label would refuse every real log.
    want=$(( want * 85 / 100 ))
    [ "$n" -ge 50 ] || die "only $n SECTION_TIME lines in $log — that log is not a suite run at all"
    [ "$distinct" -ge "$want" ] || die "only $distinct distinct sections in $log, need >= $want (85% of the $(grep -oE 'echo "\[[^]]*\]' "$RUNNER" | sort -u | grep -c .) labels in the runner) — this looks like ONE shard's log; concatenate every shard's log, or the table would default the sections it cannot see"
    # PROVENANCE COMES FROM THE ARGS, so the documented recipe reproduces the
    # committed file byte-for-byte (#1160 round 6). Round 5 hand-wrote a
    # 14-line header that the very recipe printed next to it would have ERASED
    # — a regeneration step that silently drops the answer to "where did these
    # numbers come from" is how a table becomes unverifiable.
    local rows
    rows=$(grep -oE 'SECTION_TIME: \[[^]]*\]' "$log" | sort -u | grep -c .)
    echo "# tests/section_weights.txt — per-section wall seconds, summed per label."
    echo "#"
    if [ -n "${WEIGHTS_RUN:-}" ] || [ -n "${WEIGHTS_HEAD:-}" ]; then
        echo "# MEASURED ON THE CI RUNNER, not on the dev box: run ${WEIGHTS_RUN:-unstated},"
        echo "# head ${WEIGHTS_HEAD:-unstated}, the \`asan + ubsan / core and LSP (shard k/N)\`"
        echo "# job logs, concatenated and fed to \`--print-weights\`."
    else
        echo "# PROVENANCE NOT STATED: this table was generated without --run/--head."
        echo "# Measure on the CI RUNNER and pass them, or the numbers cannot be traced."
    fi
    echo "# $n SECTION_TIME lines, $rows distinct sections."
    echo "#"
    echo "# A dev-box measurement is a BOOTSTRAP for the first split, never the table:"
    echo "# per-section ratios between the dev box and the runner reach 35x in BOTH"
    echo "# directions ([0a] 0.75 s dev -> 26.12 CI, but [124] 94.87 -> 13.30), and the"
    echo "# shards a dev-box table predicted at 590/590/590 s actually took 411/249/196."
    echo "#"
    echo "# Refresh — see docs/CI.md for the gh api recipe:"
    echo "#   tools/section_plan.sh --print-weights <ci-shard-logs> \\"
    echo "#       --run ${WEIGHTS_RUN:-<run id>} --head ${WEIGHTS_HEAD:-<head sha>} > tests/section_weights.txt"
    # A section label may contain spaces ("[JSON Depth / DoS guard]"), so the
    # label is everything from the first [ to the first ] and the seconds are
    # the LAST field — splitting on whitespace produced rows like "[Structural"
    # and a weights table with 21 phantom entries.
    awk '/^([0-9-]+T[0-9:.]+Z )?SECTION_TIME: / {
             i = index($0, "["); j = index($0, "]")
             if (i == 0 || j <= i) next
             lbl = substr($0, i, j - i + 1)
             cs[lbl] += int($NF * 100 + 0.5)
         }
         END { for (k in cs) printf "%s %d.%02d\n", k, cs[k] / 100, cs[k] % 100 }' "$log" | sort
}

# ---------------------------------------------------------------------------
# Marker derivation: which chunks DECLARE a capability gate.
# Emits: <start>\t<capability>
derive_markers() {
    local f="$1" table="$2"
    local s e caps
    while read -r s e _rest; do
        [ -n "$s" ] || continue
        caps=$(sed -n "${s},${e}p" "$f" \
               | sed -nE 's/^[[:space:]]*#[[:space:]]*EIGS-CAP-GATE:[[:space:]]*([a-z][a-z0-9_]*).*/\1/p' \
               | sort -u)
        [ -n "$caps" ] || continue
        # One chunk, one capability. Two would make "is this chunk in the plan"
        # ambiguous, and the ambiguity would resolve silently.
        if [ "$(printf '%s\n' "$caps" | grep -c .)" -ne 1 ]; then
            die "chunk at line $s declares more than one EIGS-CAP-GATE capability ($(printf '%s' "$caps" | tr '\n' ' ')) — split the section or pick one"
        fi
        printf '%s\t%s\n' "$s" "$caps"
    done < "$table"
}

# ---------------------------------------------------------------------------
# The gate audit: the marker population, pinned against an INDEPENDENT
# enumeration (mechanical-gates §1 and §12). Writes its findings to stdout and
# dies on anything unaccounted for.
#
# The enumeration deliberately scans the runner AND every child script the
# runner dispatches, because three of the gates the round-1 parser missed live
# in children (gfx_pixel_differential.sh, gfx_strict_sweep.sh, test_replay.sh).
# The child list itself is derived from the runner, never hand-written.
gate_audit() {
    local f="$1" table="$2" markers="$3" work="$4"
    local hits="$work/gate_hits" acct="$work/gate_accounted" unacct="$work/gate_unaccounted"
    : > "$hits"; : > "$acct"; : > "$unacct"

    # (a) hits in the runner itself
    grep -nE "$GATE_ENUM_RE" "$f" | sed "s|^|tests/run_all_tests.sh:|" >> "$hits"

    # (b) the child scripts the runner dispatches, derived from the runner
    local child rel path
    grep -oE 'bash "\$TESTS_DIR/(\.\./tools/)?[A-Za-z0-9_]+\.sh"' "$f" \
        | sed 's|bash "\$TESTS_DIR/||; s|"$||' | sort -u > "$work/children"
    SP_CHILD_COUNT=$(grep -c . "$work/children")
    [ "$SP_CHILD_COUNT" -ge 50 ] || \
        die "only $SP_CHILD_COUNT dispatched child scripts enumerated from the runner (floor 50) — the dispatch spelling changed and the audit would scan almost nothing"
    while read -r child; do
        [ -n "$child" ] || continue
        case "$child" in
            ../tools/*) rel="tools/${child#../tools/}" ;;
            *)          rel="tests/$child" ;;
        esac
        # SELF-EXCLUSION, and it is load-bearing: this file's own waiver table
        # and documentation necessarily QUOTE the patterns being enumerated, so
        # scanning itself makes the detector read its own reflection
        # (mechanical-gates §24). It declares no capability gate of the suite.
        [ "$rel" = "tools/section_plan.sh" ] && continue
        path="$SP_ROOT/$rel"
        [ -f "$path" ] || continue
        grep -nE "$GATE_ENUM_RE" "$path" | sed "s|^|$rel:|" >> "$hits"
    done < "$work/children"

    SP_GATE_HITS=$(grep -c . "$hits")
    [ "$SP_GATE_HITS" -ge "$GATE_HIT_FLOOR" ] || \
        die "the independent gate enumeration found only $SP_GATE_HITS lines (floor $GATE_HIT_FLOOR) — the scan is vacuous, not the tree clean"

    # Which child scripts are dispatched from a MARKED chunk? Those children's
    # own gates are accounted for by that marker.
    : > "$work/marked_children"
    local ms me mc
    while IFS=$'\t' read -r ms mc; do
        [ -n "$ms" ] || continue
        me=$(awk -v s="$ms" '$1==s {print $2}' "$table")
        sed -n "${ms},${me}p" "$f" \
            | grep -oE 'bash "\$TESTS_DIR/(\.\./tools/)?[A-Za-z0-9_]+\.sh"' \
            | sed 's|bash "\$TESTS_DIR/||; s|"$||' >> "$work/marked_children"
    done < "$markers"
    sort -u "$work/marked_children" -o "$work/marked_children"

    # Classify every hit.
    : > "$work/waivers_used"
    local hit file rest lineno text ok wpath wtext wreason
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        file=${hit%%:*}; rest=${hit#*:}
        lineno=${rest%%:*}; text=${rest#*:}
        ok=""
        if [ "$file" = "tests/run_all_tests.sh" ]; then
            # Inside a marked chunk?
            while IFS=$'\t' read -r ms mc; do
                [ -n "$ms" ] || continue
                me=$(awk -v s="$ms" '$1==s {print $2}' "$table")
                if [ "$lineno" -ge "$ms" ] && [ "$lineno" -le "$me" ]; then ok="marker:$mc@$ms"; break; fi
            done < "$markers"
        else
            # A child dispatched from a marked chunk.
            local base="${file#tests/}"; base="${base#tools/}"
            if grep -qx "$base" "$work/marked_children" || grep -qx "../tools/$base" "$work/marked_children"; then
                ok="marked-dispatcher"
            fi
        fi
        if [ -z "$ok" ]; then
            # Waivers.
            local IFS_SAVE="$IFS" thash
            thash=$(sp_line_hash "$text")
            while IFS='|' read -r wpath wtext wreason; do
                [ -n "${wpath:-}" ] || continue
                [ "$wpath" = "$file" ] || continue
                if [ "$wtext" = "$thash" ]; then
                    ok="waiver"; printf '%s|%s\n' "$wpath" "$wtext" >> "$work/waivers_used"; break
                fi
            done <<EOF
$GATE_WAIVERS
EOF
            IFS="$IFS_SAVE"
        fi
        if [ -n "$ok" ]; then
            printf '%s\t%s\n' "$ok" "$hit" >> "$acct"
        else
            printf '%s\n' "$hit" >> "$unacct"
        fi
    done < "$hits"

    if [ -s "$unacct" ] && [ "${SP_PRINT_WAIVERS:-0}" = "1" ]; then
        echo "# Paste-ready waiver rows for the UNACCOUNTED lines below."
        echo "# Each needs a REASON written by a reviewer; a bare path is not a waiver."
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            file=${hit%%:*}; rest=${hit#*:}; lineno=${rest%%:*}; text=${rest#*:}
            printf '%s|%s|REASON HERE — line %s: %.70s\n' "$file" "$(sp_line_hash "$text")" "$lineno" "$text"
        done < "$unacct"
        die "$(grep -c . "$unacct") unaccounted line(s); rows printed above, nothing was written"
    fi
    if [ -s "$unacct" ]; then
        echo "section_plan: ERROR: capability-gate line(s) that no EIGS-CAP-GATE marker and no waiver accounts for:" >&2
        sed 's/^/    /' "$unacct" >&2
        die "a gate spelled in a way the section plan does not know about would be silently dropped from every variant plan — add an 'EIGS-CAP-GATE: <cap>' marker at that gate, or a GATE_WAIVERS entry with a reason"
    fi

    # An exemption that no longer fires is a review event, not a quiet pass.
    local unused=""
    while IFS='|' read -r wpath wtext wreason; do
        [ -n "${wpath:-}" ] || continue
        grep -qxF "$wpath|$wtext" "$work/waivers_used" || unused="$unused
    $wpath|$wtext"
    done <<EOF
$GATE_WAIVERS
EOF
    if [ -n "$unused" ]; then
        echo "section_plan: ERROR: GATE_WAIVERS entries that matched nothing:$unused" >&2
        die "an unused waiver means the line it waived changed shape — re-review it instead of leaving it in place (mechanical-gates §3)"
    fi
    SP_WAIVERS_USED=$(sort -u "$work/waivers_used" | grep -c .)
}

# Enumerate every SKIP-emitting line in the runner and require each one to be
# either routed through section_skip() or named in SKIP_WAIVERS with a reason.
# Sets SP_SKIP_EMITS, SP_SKIP_ROUTED, SP_SKIP_WAIVERS_USED. Dies on anything
# unaccounted, on an unused waiver, and on either population falling through
# its floor (a scan that found almost nothing is vacuous, not clean).
skip_audit() {
    local f="$1" work="$2"
    local hits="$work/skip_hits" unacct="$work/skip_unaccounted" used="$work/skip_waivers_used"
    : > "$hits"; : > "$unacct"; : > "$used"

    grep -nE "$SKIP_EMIT_RE" "$f" >> "$hits"
    SP_SKIP_EMITS=$(grep -c . "$hits")
    [ "$SP_SKIP_EMITS" -ge "$SKIP_EMIT_FLOOR" ] || \
        die "the skip enumeration found only $SP_SKIP_EMITS SKIP-emitting lines in $f (floor $SKIP_EMIT_FLOOR) — the scan is vacuous, not the runner clean"

    SP_SKIP_ROUTED=$(grep -cE "$SKIP_ROUTE_RE" "$f")
    [ "$SP_SKIP_ROUTED" -ge "$SKIP_ROUTED_FLOOR" ] || \
        die "only $SP_SKIP_ROUTED section-level skip(s) are routed through section_skip() (floor $SKIP_ROUTED_FLOOR) — a section whose verdict is a skip and which does not go through the helper is invisible on the RESULTS line, which is the defect this floor exists for"

    local hit lineno text thash whash wreason ok
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        lineno=${hit%%:*}; text=${hit#*:}
        thash=$(sp_line_hash "$text")
        ok=""
        while IFS='|' read -r whash wreason; do
            [ -n "${whash:-}" ] || continue
            if [ "$whash" = "$thash" ]; then
                ok="waiver"; printf '%s\n' "$whash" >> "$used"; break
            fi
        done <<EOF
$SKIP_WAIVERS
EOF
        [ -n "$ok" ] || printf '%s:%s\n' "$lineno" "$text" >> "$unacct"
    done < "$hits"

    if [ -s "$unacct" ] && [ "${SP_PRINT_WAIVERS:-0}" = "1" ]; then
        echo "# Paste-ready SKIP_WAIVERS rows for the UNACCOUNTED lines below."
        echo "# Each needs a REASON written by a reviewer; a bare hash is not a waiver."
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            lineno=${hit%%:*}; text=${hit#*:}
            printf '%s|REASON HERE — line %s: %.70s\n' "$(sp_line_hash "$text")" "$lineno" "$text"
        done < "$unacct"
        die "$(grep -c . "$unacct") unaccounted SKIP line(s); rows printed above, nothing was written"
    fi
    if [ -s "$unacct" ]; then
        echo "section_plan: ERROR: SKIP-emitting line(s) in $f that neither go through section_skip() nor carry a reviewed reason:" >&2
        sed 's/^/    /' "$unacct" >&2
        die "a section whose verdict is a skip must call section_skip (it prints AND counts, so the RESULTS line's 'N skipped' is true); a sub-check skip must be listed in SKIP_WAIVERS with the section that still measures"
    fi

    local unused=""
    while IFS='|' read -r whash wreason; do
        [ -n "${whash:-}" ] || continue
        grep -qxF "$whash" "$used" || unused="$unused
    $whash|$wreason"
    done <<EOF
$SKIP_WAIVERS
EOF
    if [ -n "$unused" ]; then
        echo "section_plan: ERROR: SKIP_WAIVERS entries that matched nothing:$unused" >&2
        die "an unused skip waiver means the line it described changed shape — re-read it and decide again whether that skip is section-level (route it) or a sub-check (re-pin it)"
    fi
    SP_SKIP_WAIVERS_USED=$(sort -u "$used" | grep -c .)
}

# ---------------------------------------------------------------------------
# Probe derivation. Structure, not guesswork: a chunk that mentions a
# *_PROBE_OUT must yield all three parts or the tool fails loudly.
# Emits: <start> <outvar> <pattern>\t<program-file>
derive_probes() {
    local f="$1" table="$2" outdir="$3"
    local s e outvar filevar pattern hstart hend
    while read -r s e _rest; do
        [ -n "$s" ] || continue
        local block; block=$(sed -n "${s},${e}p" "$f")
        # The capture line is the anchor: <VAR>=$(./eigenscript "$<VAR2>" 2>&1)
        local capline
        capline=$(printf '%s\n' "$block" | grep -E '^[A-Za-z0-9_]*PROBE_OUT=\$\(\./eigenscript "\$[A-Za-z0-9_]*PROBE_FILE" 2>&1\)$' | head -1)
        if [ -z "$capline" ]; then
            # No capture line. If the chunk still mentions a _PROBE_OUT, the
            # idiom changed shape and this tool would silently under-report.
            # Comments are stripped first: a COMMENT that merely names the
            # idiom (a marker explaining why a gate is spelled differently) is
            # not a probe, and a detector that reads its own documentation is
            # the §24 self-reflection trap.
            if printf '%s\n' "$block" | grep -vE '^[[:space:]]*#' | grep -q 'PROBE_OUT'; then
                die "chunk at line $s mentions a *_PROBE_OUT but has no recognizable '<VAR>=\$(./eigenscript \"\$<VAR>_FILE\" 2>&1)' capture — the probe idiom changed and the derivation would silently under-report"
            fi
            continue
        fi
        outvar=${capline%%=*}
        filevar=$(printf '%s\n' "$capline" | sed 's/.*"\$\([A-Za-z_][A-Za-z0-9_]*\)".*/\1/')
        pattern=$(printf '%s\n' "$block" \
                  | grep -E "^if ! echo \"\\\$$outvar\" \| grep -q \"" \
                  | head -1 | sed 's/.*grep -q "\(.*\)".*/\1/')
        [ -n "$pattern" ] || die "chunk at line $s has $outvar but no 'if ! echo \"\$$outvar\" | grep -q \"...\"' guard"
        hstart=$(printf '%s\n' "$block" | grep -n "^cat > \"\\\$$filevar\" <<'PROBE'$" | head -1 | cut -d: -f1)
        [ -n "$hstart" ] || die "chunk at line $s has $filevar but no \"cat > \\\"\$$filevar\\\" <<'PROBE'\" heredoc"
        hend=$(printf '%s\n' "$block" | awk -v st="$hstart" 'NR>st && $0=="PROBE" {print NR; exit}')
        [ -n "$hend" ] || die "chunk at line $s has an unterminated PROBE heredoc"
        printf '%s\n' "$block" | sed -n "$((hstart + 1)),$((hend - 1))p" > "$outdir/probe_$s.eigs"
        printf '%s\t%s\t%s\t%s\n' "$s" "$outvar" "$pattern" "$outdir/probe_$s.eigs"
    done < "$table"
}

# Run one probe program against the binary, exactly the way the suite does
# (cwd src/, stderr folded in), and apply the suite's own predicate.
# Returns 0 = capability PRESENT, 1 = ABSENT.
probe_present() {
    local prog="$1" pattern="$2" out
    out=$(cd "$SP_ROOT/src" && "$SP_BIN_ABS" "$prog" 2>&1)
    if printf '%s\n' "$out" | grep -q "$pattern"; then return 1; fi
    return 0
}

# The plan must be derived from the binary the SUITE WILL RUN, not from a
# same-named one sitting elsewhere. run_all_tests.sh runs ./eigenscript from
# src/, so that is the artifact probed here; when build/<variant>/eigenscript
# also exists it is cross-checked by INODE (src/eigenscript is a hard link to
# the last `make` goal, #740). A mismatch means the alias points at some other
# variant, and deriving a plan from the variant build while the suite executes
# the alias is the exact shape of "the gate and the work resolved to different
# artifacts" (mechanical-gates §32) — so it is a hard error, not a NOTE.
resolve_binary() {
    local variant="$1"
    if [ -n "$BINARY" ]; then
        SP_BIN_ABS=$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")
        SP_BIN_LABEL="$BINARY (explicit --binary)"
        [ -x "$SP_BIN_ABS" ] || die "probe binary is not executable: $SP_BIN_ABS"
        return 0
    fi
    [ -x "$SP_ROOT/src/eigenscript" ] || die "src/eigenscript is missing — build the variant first"
    SP_BIN_ABS="$SP_ROOT/src/eigenscript"
    SP_BIN_LABEL="src/eigenscript"
    # "shard" is not a build variant, so there is nothing to inode-check it
    # against; the binary the suite will run is the alias, which is what we probe.
    [ "$variant" != "shard" ] || { SP_BIN_LABEL="src/eigenscript (shard mode)"; return 0; }
    local vb="$SP_ROOT/build/$variant/eigenscript"
    if [ -x "$vb" ]; then
        local a b
        a=$(stat -c %i "$SP_BIN_ABS" 2>/dev/null || stat -f %i "$SP_BIN_ABS" 2>/dev/null)
        b=$(stat -c %i "$vb" 2>/dev/null || stat -f %i "$vb" 2>/dev/null)
        if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
            die "src/eigenscript is NOT the '$variant' build (inode $a vs build/$variant/eigenscript inode $b) — the suite would run one binary while this plan was derived from another; run 'make $variant' first"
        fi
        SP_BIN_LABEL="src/eigenscript (hard-linked to build/$variant/eigenscript)"
    fi
}

# ---------------------------------------------------------------------------
# The plan. Sets SP_SELECTED (chunk start lines, newline separated) and the
# counters; prints the human-readable table when VERBOSE=1.

# N must be an integer >= 1 before ANY of it is used. Round 4 validated it
# nowhere, and a blind critic found both failure modes: `--shards 0 --check`
# and `--shards -1 --check` exited 0 printing "n=0 … zero-section-shards=0",
# because the per-shard loop was `seq 1 0` and examined ZERO shards — a check
# that examined nothing reporting success (mechanical-gates: the vacuity rule);
# and `--shards abc --check` HUNG in the LPT awk, where `for (i = 2; i <= n;
# i++)` compares against a string. A bad N dies here with a message.
validate_shards() {
    local n="$1"
    case "$n" in
        ''|*[!0-9]*) die "shard count must be a positive integer, got '$n'" ;;
    esac
    [ "$n" -ge 1 ] || die "shard count must be >= 1, got '$n'"
}

# The probe/marker population invariant, in BOTH directions (§2) — shared by
# the plan and by `--probes`, so the public mode cannot drift into checking
# something weaker (or, as in round 2, into reading a constant that no longer
# exists). There is no standalone "probe count floor": the number of probe
# providers is not an independent fact, it is "every marked capability has one".
#   forward  every probe-idiom chunk carries a marker — otherwise the probe
#            exists and nothing can use it;
#   reverse  every capability a marker declares has at least one provider —
#            otherwise the plan cannot decide whether a binary has it.
# Sets SP_CAPS_DECLARED and SP_PROVIDERS.
verify_probe_coverage() {
    local markers="$1" probes="$2"
    local ps pcap cap found
    while IFS=$'\t' read -r ps _pout _ppat _pprog; do
        [ -n "$ps" ] || continue
        pcap=$(awk -F'\t' -v s="$ps" '$1==s {print $2}' "$markers")
        [ -n "$pcap" ] || die "the probe-gated chunk at line $ps has no 'EIGS-CAP-GATE: <cap>' marker — add one naming the capability it gates on"
    done < "$probes"
    SP_PROVIDERS=$(grep -c '[0-9]' "$probes")
    SP_CAPS_DECLARED=0
    for cap in $(cut -f2 "$markers" | sort -u); do
        SP_CAPS_DECLARED=$((SP_CAPS_DECLARED + 1))
        found=0
        while IFS=$'\t' read -r ps _pout _ppat _pprog; do
            [ -n "$ps" ] || continue
            [ "$(awk -F'\t' -v s="$ps" '$1==s {print $2}' "$markers")" = "$cap" ] && found=1
        done < "$probes"
        [ "$found" = "1" ] || die "capability '$cap' is declared by a marker but no chunk provides a probe for it — the plan cannot decide whether this binary has it"
    done
}

# Headers a chunk will ACTUALLY PRINT when its capability is present. A
# probe-gated chunk carries its own else-branch twin ("… SKIPPED (binary built
# without …)"), which never executes on a binary that HAS the capability — so
# counting both branches over-reported (the http plan said 18 and the run
# printed 16). The twin phrasing is not invented here: it is the same rule
# tools/suite_label_check.sh already uses to allow one label to appear twice.
# How many section headers a chunk will actually PRINT.
#
# Two facts, both measured against a real run rather than assumed:
#   * A header at COLUMN 0 is not inside the chunk's capability `if`, so it
#     prints whatever the binary is. [138], [139] and [42a/47] are exactly
#     that shape — the header prints and the CHILD then self-skips — and a
#     rule that ignored indentation predicted 239 headers for a run that
#     printed 242.
#   * An INDENTED header is in the `if`/`else`: the non-twin one prints when
#     the capability is present, the twin ("… SKIPPED (binary built without …)")
#     when it is absent, and some chunks have no twin and so print nothing.
#     [17/17] is that case: the plan promised 79 and the run printed 78.
# Every twin in the runner is indented (checked: zero column-0 twins), so the
# two rules do not overlap.
chunk_executed_headers() {
    local s="$1" e="$2" branch="${3:-present}" body top cond
    body=$(sed -n "${s},${e}p" "$RUNNER")
    top=$(printf '%s\n' "$body" | grep -cE '^echo "\[[^]]*\]')
    if [ "$branch" = "absent" ]; then
        cond=$(printf '%s\n' "$body" | grep -E '^[[:space:]]+echo "\[[^]]*\]' \
               | grep -cE 'SKIPPED \(|skipped — |stub check|minimal build')
    else
        cond=$(printf '%s\n' "$body" | grep -E '^[[:space:]]+echo "\[[^]]*\]' \
               | grep -cvE 'SKIPPED \(|skipped — |stub check|minimal build')
    fi
    echo $(( top + cond ))
}

compute_capabilities() {
    note "capabilities (each probe is the suite's OWN gate, run against this binary):"
    : > "$SP_WORK/caps"
    local caps_all cap verdict agree ppat pprog pout ps pcap
    caps_all=$(cut -f2 "$SP_WORK/markers" | sort -u)
    for cap in $caps_all; do
        verdict=""; agree=1
        while IFS=$'\t' read -r ps _pout ppat pprog; do
            [ -n "$ps" ] || continue
            pcap=$(awk -F'\t' -v s="$ps" '$1==s {print $2}' "$SP_WORK/markers")
            [ "$pcap" = "$cap" ] || continue
            if probe_present "$pprog" "$ppat"; then pout=present; else pout=absent; fi
            if [ -z "$verdict" ]; then verdict="$pout"
            elif [ "$verdict" != "$pout" ]; then agree=0; fi
        done < "$SP_WORK/probes"
        [ -n "$verdict" ] || die "capability '$cap' is declared by a marker but no chunk provides a probe for it — the plan cannot decide whether this binary has it"
        [ "$agree" = "1" ] || die "the probes for capability '$cap' DISAGREE on this binary — one of them is measuring something else"
        printf '%s\t%s\n' "$cap" "$verdict" >> "$SP_WORK/caps"
        note "  $verdict  $cap"
    done
}

build_plan() {
    local variant="$1"
    local caps_floor chunks_floor
    caps_floor=$(variant_caps_floor "$variant")
    chunks_floor=$(variant_chunks_floor "$variant")
    [ -n "$caps_floor" ] || die "unknown variant '$variant' (known: release core http full db zlib net gfx asan-http asan-gfx)"

    SP_WORK="${SP_WORK:-$(sp_workdir plan)}"
    derive_chunks "$RUNNER" > "$SP_WORK/chunks"
    verify_partition "$RUNNER" "$SP_WORK/chunks"
    derive_markers "$RUNNER" "$SP_WORK/chunks" > "$SP_WORK/markers"
    derive_probes "$RUNNER" "$SP_WORK/chunks" "$SP_WORK" > "$SP_WORK/probes"

    SP_CHUNK_TOTAL=$(grep -c '[0-9]' "$SP_WORK/chunks")
    SP_SECTION_TOTAL=$(grep -coE 'echo "\[[^]]*\]' "$RUNNER")
    SP_PROBE_SITES=$(grep -c '[0-9]' "$SP_WORK/probes")
    SP_MARKERS=$(grep -c '[0-9]' "$SP_WORK/markers")

    [ "$SP_MARKERS" -ge "$CAP_MARKER_FLOOR" ] || \
        die "EIGS-CAP-GATE markers derived=$SP_MARKERS < floor=$CAP_MARKER_FLOOR — a capability gate lost its marker and its sections would silently leave every variant plan"

    # The pin: the marker population against the independent enumeration.
    gate_audit "$RUNNER" "$SP_WORK/chunks" "$SP_WORK/markers" "$SP_WORK"

    verify_probe_coverage "$SP_WORK/markers" "$SP_WORK/probes"

    resolve_binary "$variant"

    note "plan=$variant  binary=$SP_BIN_LABEL"
    note "runner=tests/run_all_tests.sh  lines=$SP_TOTAL_LINES  preamble=1-$SP_PREAMBLE_END  epilogue=$SP_EPILOGUE_START-$SP_TOTAL_LINES"
    note "chunks=$SP_CHUNK_TOTAL  section-headers=$SP_SECTION_TOTAL"
    note "cap-gate markers=$SP_MARKERS (floor $CAP_MARKER_FLOOR)  probe providers=$SP_PROBE_SITES"
    note "gate audit: $SP_GATE_HITS enumerated gate lines over the runner + $SP_CHILD_COUNT dispatched children; all accounted for ($SP_WAIVERS_USED waiver(s) used)"
    note ""

    # --- capability presence, one decision per capability -----------------
    # Every probe provider for a capability is RUN and they must AGREE. gfx has
    # five providers; a disagreement means one probe is measuring something
    # else, and silently taking the first would hide it.
    compute_capabilities
    note ""
    : > "$SP_WORK/selected"

    # --- core smoke -------------------------------------------------------
    note "core smoke (fixed; each entry states why, and an entry matching no chunk is a hard failure):"
    local id matched s e ids
    local IFS_SAVE="$IFS"
    IFS='|'
    for id in $CORE_SMOKE_IDS; do
        IFS="$IFS_SAVE"
        matched=""
        while read -r s e ids; do
            [ -n "$s" ] || continue
            case " $ids " in
                *" $id "*) matched="$s"; break ;;
            esac
        done < "$SP_WORK/chunks"
        [ -n "$matched" ] || die "core-smoke entry '$id' matches no chunk in the runner — the section was renamed or removed; re-review the smoke list"
        echo "$matched" >> "$SP_WORK/selected"
        note "  $id  (chunk @$matched)  — $(core_smoke_reason "$id")"
        IFS='|'
    done
    IFS="$IFS_SAVE"
    note ""

    # --- marker-derived variant sections ----------------------------------
    note "capability-gated sections (every chunk carrying an EIGS-CAP-GATE marker):"
    SP_PRESENT=0
    SP_ABSENT=0
    local ms mc mv
    while IFS=$'\t' read -r ms mc; do
        [ -n "$ms" ] || continue
        ids=$(awk -v s="$ms" '$1==s {$1="";$2="";print}' "$SP_WORK/chunks" | sed 's/^  *//')
        mv=$(awk -F'\t' -v c="$mc" '$1==c {print $2}' "$SP_WORK/caps")
        if [ "$mv" = "present" ]; then
            SP_PRESENT=$((SP_PRESENT + 1))
            echo "$ms" >> "$SP_WORK/selected"
            note "  IN   chunk @$ms  cap=$mc  sections: $ids"
        else
            SP_ABSENT=$((SP_ABSENT + 1))
            note "  out  chunk @$ms  cap=$mc  sections: $ids"
        fi
    done < "$SP_WORK/markers"
    note ""

    sort -n -u "$SP_WORK/selected" > "$SP_WORK/selected.sorted"
    mv "$SP_WORK/selected.sorted" "$SP_WORK/selected"

    SP_SEL_CHUNKS=$(grep -c '[0-9]' "$SP_WORK/selected")
    SP_SEL_SECTIONS=0
    while read -r s; do
        [ -n "$s" ] || continue
        e=$(awk -v ss="$s" '$1==ss {print $2}' "$SP_WORK/chunks")
        n=$(chunk_executed_headers "$s" "$e")
        SP_SEL_SECTIONS=$((SP_SEL_SECTIONS + n))
    done < "$SP_WORK/selected"

    SP_CAPS_PRESENT=$(awk -F'\t' '$2=="present"' "$SP_WORK/caps" | grep -c . || true)

    # --- floors and vacuity ----------------------------------------------
    if [ "$SP_CAPS_PRESENT" -lt "$caps_floor" ]; then
        echo "PLAN: sections=$SP_SEL_SECTIONS (of $SP_SECTION_TOTAL) chunks=$SP_SEL_CHUNKS plan=$variant capabilities=$SP_CAPS_PRESENT"
        die "variant '$variant' presents $SP_CAPS_PRESENT capability(ies), floor is $caps_floor — this binary is not the variant it claims (a broken registration collapses the plan to the core smoke and would otherwise go GREEN)"
    fi
    if [ "$SP_PRESENT" -lt "$chunks_floor" ]; then
        echo "PLAN: sections=$SP_SEL_SECTIONS (of $SP_SECTION_TOTAL) chunks=$SP_SEL_CHUNKS plan=$variant capabilities=$SP_CAPS_PRESENT"
        die "variant '$variant' selected $SP_PRESENT capability-gated chunk(s), floor is $chunks_floor — a marker was lost, or a gated section left the runner"
    fi
    if [ "$SP_SEL_SECTIONS" -le 0 ]; then
        die "plan for '$variant' selected ZERO sections — a job that measures nothing must not be green"
    fi

    echo "PLAN: sections=$SP_SEL_SECTIONS (of $SP_SECTION_TOTAL) chunks=$SP_SEL_CHUNKS plan=$variant capabilities=$SP_CAPS_PRESENT (floor $caps_floor) gated-chunks=$SP_PRESENT (floor $chunks_floor)"
}


# ---------------------------------------------------------------------------
# Emit the filtered runner for one shard.
emit_shard() {
    local k="$1" n="$2" out="$3"
    VERBOSE=${EMIT_VERBOSE:-1}
    SP_WORK=$(sp_workdir emit)
    build_shard_plan "$k" "$n" > "$SP_WORK/plan.line"
    local planline; planline=$(cat "$SP_WORK/plan.line")
    write_filtered_runner "$out" "$planline" "shard $k/$n"
    echo "$planline"
}

# The one place a filtered runner is written, shared by the capability plans
# and the shards — two copies would drift and only one of them is exercised.
write_filtered_runner() {
    local out="$1" planline="$2" label="$3"
    {
        echo "#!/bin/bash"
        echo "# GENERATED by tools/section_plan.sh — DO NOT EDIT, DO NOT COMMIT (#1160)."
        echo "# $planline"
        echo "# Source: tests/run_all_tests.sh   selection: $label   binary: ${SP_BIN_LABEL:-src/eigenscript}"
        echo "EIGS_PLAN_ACTIVE=1; export EIGS_PLAN_ACTIVE"
        echo "EIGS_PLAN_TESTS_DIR='$SP_ROOT/tests'; export EIGS_PLAN_TESTS_DIR"
        echo "EIGS_PLAN_LABEL='$planline'; export EIGS_PLAN_LABEL"
        sed -n "1,${SP_PREAMBLE_END}p" "$RUNNER"
        echo "echo \"  SECTION PLAN: $planline\""
        echo "echo \"\""
        local s e
        while read -r s; do
            [ -n "$s" ] || continue
            e=$(awk -v ss="$s" '$1==ss {print $2}' "$SP_WORK/chunks")
            sed -n "${s},${e}p" "$RUNNER"
        done < "$SP_WORK/selected"
        echo "echo \"  SECTION PLAN: $planline\""
        sed -n "${SP_EPILOGUE_START},\$p" "$RUNNER"
    } > "$out"
    bash -n "$out" || die "the emitted runner $out is not syntactically valid — the chunk boundaries are wrong"
}

# ---------------------------------------------------------------------------
# Emit the filtered runner.
emit_plan() {
    local variant="$1" out="$2"
    VERBOSE=${EMIT_VERBOSE:-1}
    SP_WORK=$(sp_workdir emit)
    build_plan "$variant" > "$SP_WORK/plan.line"
    local planline; planline=$(cat "$SP_WORK/plan.line")
    write_filtered_runner "$out" "$planline" "variant $variant"
    echo "$planline"
}


# ---------------------------------------------------------------------------
# Selftest. Every fault is planted in a COPY (mechanical-gates §22: a gate must
# not mutate what it checks), and every case names the check it must turn red.
selftest() {
    local rc=0 pass=0 fail=0 dir out
    dir=$(sp_workdir selftest)

    expect_ok() {   # <label> <command...>
        local label="$1"; shift
        if out=$("$@" 2>&1); then
            echo "  PASS: $label"; pass=$((pass + 1))
        else
            echo "  FAIL: $label (expected exit 0, got $?)"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
        fi
    }
    expect_red() {  # <label> <must-match> <command...>
        local label="$1" want="$2"; shift 2
        if out=$("$@" 2>&1); then
            echo "  FAIL: $label — the planted fault did NOT turn the check red"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
        elif printf '%s\n' "$out" | grep -qF "$want"; then
            echo "  PASS: $label"; pass=$((pass + 1))
        else
            echo "  FAIL: $label — it went red for the WRONG reason (no '$want' in the output)"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
        fi
    }

    echo "section_plan selftest (faults are planted in copies; the tree is never touched)"

    # Control: the real runner derives cleanly. Both halves of a control
    # (mechanical-gates §15): a clean input MUST pass.
    expect_ok "control: the real runner partitions and parses" \
        "$0" --chunks --quiet

    # 1. Epilogue anchor lost -> must fail loudly, not guess.
    cp "$RUNNER" "$dir/no_anchor.sh"
    sed -i 's/^# Final guard (#681)/# Final guard/' "$dir/no_anchor.sh"
    expect_red "planted: epilogue anchor removed -> derive_chunks" \
        "epilogue anchor" "$0" --chunks --quiet --runner "$dir/no_anchor.sh"

    # 2. Epilogue anchor duplicated -> must fail (unique or stop).
    cp "$RUNNER" "$dir/dup_anchor.sh"
    printf '# Final guard (#681)\n' >> "$dir/dup_anchor.sh"
    expect_red "planted: epilogue anchor duplicated -> derive_chunks" \
        "epilogue anchor" "$0" --chunks --quiet --runner "$dir/dup_anchor.sh"

    # 3. Probe idiom mangled (the capture line renamed) -> the derivation must
    #    refuse, not silently return one probe fewer.
    cp "$RUNNER" "$dir/bad_probe.sh"
    sed -i 's/^ZLIB_PROBE_OUT=\$(\.\/eigenscript "\$ZLIB_PROBE_FILE" 2>&1)$/ZLIB_PROBE_OUT=$(.\/eigenscript "$ZLIB_PROBE_FILE" 2>\&1 )/' "$dir/bad_probe.sh"
    expect_red "planted: a probe capture line reshaped -> derive_probes refuses" \
        "probe idiom changed" "$0" --probes --quiet --runner "$dir/bad_probe.sh"

    # 4. Probe guard removed -> must fail.
    cp "$RUNNER" "$dir/no_guard.sh"
    sed -i 's/^if ! echo "\$NET_PROBE_OUT" | grep -q "ndefined variable"; then$/if true; then/' "$dir/no_guard.sh"
    expect_red "planted: a probe guard removed -> derive_probes refuses" \
        "no 'if ! echo" "$0" --probes --quiet --runner "$dir/no_guard.sh"

    # 5. A core-smoke section renamed -> the waiver must fail, not pass quietly.
    cp "$RUNNER" "$dir/no_smoke.sh"
    sed -i 's/^echo "\[19\/19\] String & Math Builtins (75 checks)"$/echo "[19\/19x] String \& Math Builtins (75 checks)"/' "$dir/no_smoke.sh"
    expect_red "planted: a core-smoke section renamed -> the fixed smoke list fails" \
        "matches no chunk" "$0" --print-section-plan core --quiet --runner "$dir/no_smoke.sh"

    # --- capability stubs -------------------------------------------------
    # ROUND 2 (#1160): these replace a case that probed src/eigenscript and so
    # depended on which variant was last built — it was a FALSE RED right after
    # `make http`, which is exactly what docs/CI.md tells a contributor to run.
    # A stub answers the probes the way a binary would, and nothing in the tree
    # can change its answer.
    # The no-capabilities stub must answer EVERY gate's pattern, not just the
    # common one: the zlib gate is inverted (present iff the stub message is
    # ABSENT), so a stub that printed only "undefined variable" reported zlib
    # PRESENT — the first version of this control did exactly that.
    printf '#!/bin/sh\necho "undefined variable"\necho "deflate: compiled without zlib support"\nexit 1\n' > "$dir/nocaps"
    printf '#!/bin/sh\nexit 0\n' > "$dir/allcaps"
    chmod +x "$dir/nocaps" "$dir/allcaps"

    # 6. A capability-less binary presented as `http` -> the variant floor must
    #    fire. This is the planted variant-only regression in miniature: a
    #    broken http_route registration produces exactly this binary.
    expect_red "planted: a capability-less binary labelled 'http' -> the caps floor fires" \
        "floor is 2" "$0" --print-section-plan http --quiet --binary "$dir/nocaps"

    # 6b. THE ROUND-1 REGRESSION, as a control. The gfx-gated sections spelled
    #     outside the probe idiom — [97] (inline EX_HAS_GFX), [138] and [139]
    #     (children that self-skip) — were dropped from every gfx plan. A blind
    #     critic proved it: an undefined builtin planted in examples/ui_dock.eigs
    #     left `EIGS_SUITE_SECTIONS=gfx` 173/173 GREEN. They must now be IN.
    if out=$("$0" --print-section-plan gfx --binary "$dir/allcaps" 2>&1); then
        missing=""
        for want in "[97]" "[138]" "[139]" "[62]" "[132]"; do
            printf '%s\n' "$out" | grep -q -- "IN .*sections:.*$want" || missing="$missing $want"
        done
        if [ -z "$missing" ]; then
            echo "  PASS: control: a gfx-capable binary puts [97] [138] [139] [62] [132] IN the plan"; pass=$((pass + 1))
        else
            echo "  FAIL: control: the gfx plan is missing$missing — the round-1 blind spot is back"; fail=$((fail + 1))
        fi
    else
        echo "  FAIL: control: the gfx plan could not be derived from the all-capabilities stub"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
    fi

    # 6c. The other half of that control: with NO capabilities, those same
    #     sections must be OUT. A check satisfied by "always in" is not a check.
    if out=$("$0" --print-section-plan core --binary "$dir/nocaps" 2>&1); then
        if printf '%s\n' "$out" | grep -q -- "IN .*sections:"; then
            echo "  FAIL: control: a capability-less binary still selected a gated chunk"; fail=$((fail + 1))
        else
            echo "  PASS: control: a capability-less binary selects NO gated chunk"; pass=$((pass + 1))
        fi
    else
        echo "  FAIL: control: the core plan could not be derived from the no-capabilities stub"; fail=$((fail + 1))
    fi

    # 6d. A gate that loses its marker must be a HARD FAILURE, not a silent
    #     shrink — this is the pin that round 1 did not have.
    #     The marker is MOVED, not deleted, so the marker COUNT stays at 15 and
    #     the floor cannot answer on the audit's behalf (mechanical-gates §41:
    #     a negative case must fail for its own reason, not a neighbour's).
    cp "$RUNNER" "$dir/no_marker.sh"
    sed -i 's/^# EIGS-CAP-GATE: gfx — \[97\]/# (marker moved away by the selftest) [97]/' "$dir/no_marker.sh"
    sed -i 's|^echo "\[0\] Opcode ABI Guard"$|echo "[0] Opcode ABI Guard"\n# EIGS-CAP-GATE: gfx — a marker parked where no gate is|' "$dir/no_marker.sh"
    expect_red "planted: the [97] gate loses its marker -> the gate audit refuses" \
        "no EIGS-CAP-GATE marker and no waiver accounts for" \
        "$0" --gate-audit --quiet --runner "$dir/no_marker.sh"

    # 6e. A NEW gate spelling entering the tree must be a hard failure too —
    #     "a new spelling is a hard failure, not a silent shrink".
    cp "$RUNNER" "$dir/new_spelling.sh"
    sed -i 's|^echo "\[0\] Opcode ABI Guard"$|if ./eigenscript /dev/null 2>\&1 \| grep -q "built without EIGENSCRIPT_EXT_ZZZ"; then :; fi\necho "[0] Opcode ABI Guard"|' "$dir/new_spelling.sh"
    expect_red "planted: a NEW capability-gate spelling -> the gate audit refuses" \
        "no EIGS-CAP-GATE marker and no waiver accounts for" \
        "$0" --gate-audit --quiet --runner "$dir/new_spelling.sh"

    # 6h. SKIP ACCOUNTING (#1225 round 7). Three arms, each transverse to a
    #     different half of the mechanism, plus the control. Round 6's counter
    #     was incremented at ONE site while nine other SKIP lines printed on
    #     the same lane, so `0 skipped` was false on every job.
    expect_ok "control: the real runner's SKIP lines are all routed or reasoned" \
        "$0" --skip-audit --quiet

    #     (i) a NEW bare `SKIP:` echo entering a section: unaccounted, by name.
    cp "$RUNNER" "$dir/bare_skip.sh"
    sed -i 's|^echo "\[0\] Opcode ABI Guard"$|echo "[0] Opcode ABI Guard"\necho "  SKIP: planted bare skip that nothing counts"|' "$dir/bare_skip.sh"
    if cmp -s "$RUNNER" "$dir/bare_skip.sh"; then
        echo "  FAIL: planted: a bare SKIP: echo — the plant was a no-op, the anchor did not match"; fail=$((fail + 1))
    else
        expect_red "planted: a NEW bare SKIP: echo -> the skip audit refuses" \
            "neither go through section_skip() nor carry a reviewed reason" \
            "$0" --skip-audit --quiet --runner "$dir/bare_skip.sh"
    fi

    #     (ii) a section-level skip UN-ROUTED back to a bare echo: the routed
    #          floor answers even before the waiver table does. Both halves
    #          fire on this one input; the floor is checked first, so that is
    #          the message pinned here.
    cp "$RUNNER" "$dir/unrouted_skip.sh"
    sed -i 's|^    section_skip "binary built without EIGENSCRIPT_EXT_HTTP"$|    echo "  SKIP: binary built without EIGENSCRIPT_EXT_HTTP"|' "$dir/unrouted_skip.sh"
    if cmp -s "$RUNNER" "$dir/unrouted_skip.sh"; then
        echo "  FAIL: planted: an un-routed section skip — the plant was a no-op"; fail=$((fail + 1))
    else
        expect_red "planted: a section-level skip un-routed -> the routed floor refuses" \
            "routed through section_skip() (floor" \
            "$0" --skip-audit --quiet --runner "$dir/unrouted_skip.sh"
    fi

    #     (iii) a waived sub-check line deleted: the waiver stops matching, and
    #           an exemption that no longer fires must FAIL, not pass quietly
    #           (mechanical-gates §3).
    cp "$RUNNER" "$dir/stale_waiver.sh"
    sed -i '/^echo "\$BG_OUTPUT" | grep "SKIP:" || true$/d' "$dir/stale_waiver.sh"
    if cmp -s "$RUNNER" "$dir/stale_waiver.sh"; then
        echo "  FAIL: planted: a stale skip waiver — the plant was a no-op"; fail=$((fail + 1))
    else
        expect_red "planted: a waived sub-check skip deleted -> the stale waiver refuses" \
            "SKIP_WAIVERS entries that matched nothing" \
            "$0" --skip-audit --quiet --runner "$dir/stale_waiver.sh"
    fi

    # 6f. The run-level vacuity hole (round 2, G4): preamble + epilogue with no
    #     sections at all used to print "RESULTS: 0/0 passed, 0 failed" and exit
    #     0. Built here directly, because no legal plan can produce it.
    # Boundaries come from the tool, never from a hardcoded line number.
    local pre_end
    pre_end=$("$0" --chunks --quiet --runner "$RUNNER" | sed -n 's/.*preamble=1-\([0-9][0-9]*\).*/\1/p')
    {
        printf 'EIGS_PLAN_ACTIVE=1; export EIGS_PLAN_ACTIVE\n'
        printf "EIGS_PLAN_TESTS_DIR='%s/tests'; export EIGS_PLAN_TESTS_DIR\n" "$SP_ROOT"
        awk -v n="$pre_end" 'NR<=n' "$RUNNER"
        awk '/^# Final guard \(#681\)/,0' "$RUNNER"
    } > "$dir/empty_run.sh"
    expect_red "planted: a run with zero assertions -> the epilogue refuses to report it" \
        "executed ZERO assertions" bash "$dir/empty_run.sh"

    # 6g. The COUNT itself (round 2, G5). Round 1 counted both branches of a
    #     probe gate's if/else, so the http plan promised 18 for a run that
    #     printed 16. The twin ("… SKIPPED (binary built without …)") never
    #     executes on a binary that HAS the capability. Pinned on the http
    #     chunk, which carries six header echoes of which exactly one is a twin.
    local http_chunk http_end raw exec_n
    http_chunk=$("$0" --markers --quiet --runner "$RUNNER" >/dev/null 2>&1; true)
    W2=$(sp_workdir count)
    derive_chunks "$RUNNER" > "$W2/chunks"
    http_chunk=$(awk '$0 ~ /\[44-45\/47\]/ {print $1; exit}' "$W2/chunks")
    http_end=$(awk -v s="$http_chunk" '$1==s {print $2}' "$W2/chunks")
    raw=$(sed -n "${http_chunk},${http_end}p" "$RUNNER" | grep -cE 'echo "\[[^]]*\]')
    exec_n=$(chunk_executed_headers "$http_chunk" "$http_end")
    rm -rf "$W2"
    if [ "$raw" = "6" ] && [ "$exec_n" = "5" ]; then
        echo "  PASS: header counting excludes the skip TWIN (http chunk: 6 echoes, 5 executed)"; pass=$((pass + 1))
    else
        echo "  FAIL: header counting is wrong (http chunk: $raw echoes, $exec_n counted as executed; expected 6 and 5)"; fail=$((fail + 1))
    fi

    # 6h. ROUND 3, G2 (Astra, executed): a waiver used to be a SUBSTRING, so a
    #     real capability gate planted into an already-waived FILE inherited a
    #     reason that is false for it and the audit printed unaccounted=0.
    #     Waivers are content-pinned now; this plants Astra's exact line into a
    #     symlink farm so the real tree is never touched.
    mkdir -p "$dir/root/tests" "$dir/root/tools"
    ln -s "$SP_ROOT"/tests/* "$dir/root/tests/" 2>/dev/null
    ln -s "$SP_ROOT"/tools/* "$dir/root/tools/" 2>/dev/null
    if [ -e "$dir/root/tests/run_all_tests.sh" ] && [ -e "$dir/root/tests/test_lint.sh" ]; then
        rm -f "$dir/root/tests/test_lint.sh"
        {
            head -1 "$SP_ROOT/tests/test_lint.sh"
            printf 'if ./eigenscript "$P" 2>&1 | grep -q "undefined variable"; then echo "SKIP: planted no gfx build"; exit 0; fi\n'
            tail -n +2 "$SP_ROOT/tests/test_lint.sh"
        } > "$dir/root/tests/test_lint.sh"
        # Control half: the farm with NO plant must still audit clean, or the
        # red below would be the farm failing rather than the plant landing.
        mkdir -p "$dir/clean/tests" "$dir/clean/tools"
        ln -s "$SP_ROOT"/tests/* "$dir/clean/tests/" 2>/dev/null
        ln -s "$SP_ROOT"/tools/* "$dir/clean/tools/" 2>/dev/null
        expect_ok "control: the symlink farm with no plant audits clean" \
            "$0" --gate-audit --quiet --root "$dir/clean"
        expect_red "planted: a REAL gate added to an already-waived file -> the audit refuses" \
            "no EIGS-CAP-GATE marker and no waiver accounts for" \
            "$0" --gate-audit --quiet --root "$dir/root"
    else
        echo "  FAIL: could not build the symlink farm for the waiver-pin control"; fail=$((fail + 1))
    fi

    # 6i. ROUND 3, G1: every public mode a WORKFLOW or docs/CI.md names must be
    #     invocable. `--probes` died on an unbound variable while --selftest
    #     passed 14/14, and ci.yml's gate-selftests job calls it, so every code
    #     PR would have gone red. The mode list is DERIVED from those two files,
    #     so a mode added to a workflow is covered without editing this test.
    local modes m modefile mode_n=0 mode_bad=0
    modefile="$dir/modes"
    { grep -ohE 'section_plan\.sh --[a-z-]+' "$SP_ROOT/.github/workflows/"*.yml 2>/dev/null
      grep -ohE 'section_plan\.sh --[a-z-]+' "$SP_ROOT/docs/CI.md" 2>/dev/null
      grep -ohE 'run_all_tests\.sh --[a-z-]+' "$SP_ROOT/docs/CI.md" 2>/dev/null
    } | sed 's/.*--/--/' | sort -u > "$modefile"
    # rc is NOT enough: a mode that prints NOTHING and exits 0 would pass an
    # rc-only check, and the round-3 version was exactly that — `--probes`
    # was caught by a neighbouring case, not by this one. Each mode must also
    # produce output, and the FAILING mode's output is what gets printed
    # (round 3 printed whichever mode happened to run last).
    local mode_out mode_rc mode_why=""
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        mode_n=$((mode_n + 1))
        mode_rc=0
        case "$m" in
            --emit)                mode_out=$("$0" --emit core "$dir/mode_emit.sh" 2>&1) || mode_rc=$? ;;
            --print-section-plan)  mode_out=$("$0" --print-section-plan core 2>&1) || mode_rc=$? ;;
            --selftest)            continue ;;   # we are inside it
            --shards)              mode_out=$("$0" --shards 3 --check 2>&1) || mode_rc=$? ;;
            --shard-owner)         mode_out=$("$0" --shard-owner 3 --quiet 2>&1) || mode_rc=$? ;;
            --section)             continue ;;   # a modifier of --shard-owner, not a mode
            --emit-shard)          mode_out=$("$0" --emit-shard 1 3 "$dir/mode_shard.sh" 2>&1) || mode_rc=$? ;;
            --print-weights)       # The synthetic log must COVER the runner's labels, or the
                                   # partial-log floor (T6) refuses it — which is the floor
                                   # working, not the mode being broken.
                                   grep -oE 'echo "\[[^]]*\]' "$RUNNER" | sed 's/echo "//' | sort -u \
                                     | awk '{ printf "SECTION_TIME: %s 0.10\n", $0 }' > "$dir/synth.log"
                                   mode_out=$("$0" --print-weights "$dir/synth.log" 2>&1) || mode_rc=$? ;;
            *)                     mode_out=$("$0" "$m" 2>&1) || mode_rc=$? ;;
        esac
        if [ "$mode_rc" -ne 0 ]; then
            mode_bad="$mode_bad $m(rc=$mode_rc)"
            [ -n "$mode_why" ] || mode_why="$m exited $mode_rc:
$mode_out"
        elif [ -z "$mode_out" ]; then
            mode_bad="$mode_bad $m(silent)"
            [ -n "$mode_why" ] || mode_why="$m exited 0 but printed nothing — a mode a workflow calls must say something"
        fi
    done < "$modefile"
    if [ "$mode_n" -lt 3 ]; then
        echo "  FAIL: only $mode_n public mode(s) enumerated from the workflows and docs (floor 3) — the enumeration is vacuous"; fail=$((fail + 1))
    elif [ "$mode_bad" = "0" ]; then
        echo "  PASS: every public mode named by a workflow or docs/CI.md runs clean ($mode_n: $(tr '\n' ' ' < "$modefile"))"; pass=$((pass + 1))
    else
        echo "  FAIL: public mode(s) a workflow or docs calls are broken:${mode_bad#0}"
        printf '%s\n' "$mode_why" | sed 's/^/      /'
        fail=$((fail + 1))
    fi

    # 6j. ROUND 4: the shard count lives in three places in ci.yml because
    #     GitHub will not expand `env` inside `strategy.matrix`. Gate the sync
    #     instead of hand-syncing it (mechanical-gates §26): read BOTH homes
    #     and require agreement.
    #     ROUND 5 (T3): the JOB NAME's `/3` was a FOURTH home and was not
    #     pinned — changing only that literal left the check green while the
    #     board said "shard 1/4" for a 3-way split. It is checked now, and the
    #     whole comparison moved into a function so the selftest can run it
    #     against a mutated COPY instead of needing an env seam.
    local ci="$SP_ROOT/.github/workflows/ci.yml"
    if [ -f "$ci" ]; then
        if out=$(shard_count_sync "$ci"); then
            echo "  PASS: $out"; pass=$((pass + 1))
        else
            echo "  FAIL: $out"; fail=$((fail + 1))
        fi
        # ROUND 6: deleting any ONE of the three `matrix.shard }}/N` homes used
        # to pass as "all agree". Each deletion gets its own plant, because
        # they fail differently — the env-value one is the dangerous one (the
        # runner then parses a bare `1` and ran the whole suite), and a single
        # combined case would be satisfied by whichever one happened to fire.
        for home_line in $(grep -n 'matrix\.shard }}/' "$ci" | cut -d: -f1); do
            sed -e "${home_line}s#\${{ matrix.shard }}/3#\${{ matrix.shard }}#" "$ci" > "$dir/ci_del.yml"
            home_what=$(sed -n "${home_line}p" "$ci" | sed 's/^ *//' | cut -c1-40)
            if cmp -s "$ci" "$dir/ci_del.yml"; then
                echo "  FAIL: could not delete the shard literal at ci.yml:$home_line"; fail=$((fail + 1))
            elif out=$(shard_count_sync "$dir/ci_del.yml"); then
                echo "  FAIL: deleting the /N at ci.yml:$home_line ($home_what) left the check green — $out"; fail=$((fail + 1))
            else
                echo "  PASS: planted: deleting ONLY the /N at ci.yml:$home_line -> the shard-count check refuses"; pass=$((pass + 1))
            fi
        done

        # Both halves: the same check must go RED when ONLY the job-name
        # literal is changed, which is exactly what round 4 missed.
        sed 's#core and LSP (shard ${{ matrix.shard }}/3)#core and LSP (shard ${{ matrix.shard }}/4)#' "$ci" > "$dir/ci_jobname.yml"
        if cmp -s "$ci" "$dir/ci_jobname.yml"; then
            echo "  FAIL: could not plant the job-name mutation (the name line changed shape)"; fail=$((fail + 1))
        elif out=$(shard_count_sync "$dir/ci_jobname.yml"); then
            echo "  FAIL: changing ONLY the job name's /N left the shard-count check green — $out"; fail=$((fail + 1))
        else
            echo "  PASS: planted: the job name alone says /4 -> the shard-count check refuses"; pass=$((pass + 1))
        fi
        if grep -q 'section_plan.sh --shards ${{ env.ASAN_SHARDS }} --check' "$ci"; then
            echo "  PASS: the aggregator runs the union/disjointness check"; pass=$((pass + 1))
        else
            echo "  FAIL: the aggregator no longer runs --shards N --check — the shards could cover less than the suite and still be green"; fail=$((fail + 1))
        fi
    else
        echo "  FAIL: ci.yml not found; the shard-count sync cannot be verified"; fail=$((fail + 1))
    fi

    # 6k. Union and disjointness, and both halves of that control: the real
    #     split must pass, a chunk DROPPED from every shard must fail, and a
    #     chunk in TWO shards must fail. The mutations run against a stub
    #     assignment so no real chunk table is disturbed.
    expect_ok "control: the real 3-way split is union==full and disjoint" \
        "$0" --shards 3 --check --quiet

    # NOT in a subshell: `( export X=1; expect_red ... )` ran the case but its
    # pass/fail counters died with the subshell — the two rows printed and the
    # total said 21 while 23 rows existed, and a FAILURE there would have been
    # invisible to the tally. `env VAR=v` keeps it in this shell.
    expect_red "planted: one chunk in NO shard -> the union check refuses" \
        "union != full" env SP_SHARD_MUTATE=drop "$0" --shards 3 --check --quiet
    expect_red "planted: one chunk in TWO shards -> the disjointness check refuses" \
        "shards OVERLAP" env SP_SHARD_MUTATE=dup "$0" --shards 3 --check --quiet

    # 6l. A section missing from the weights table must take the default AND be
    #     REPORTED, so a new section cannot silently unbalance a shard.
    printf '[0] 1.00\n[1/15] 2.00\n' > "$dir/thin_weights.txt"
    if out=$(WEIGHTS_FILE="$dir/thin_weights.txt" "$0" --shards 3 --check 2>&1); then
        if printf '%s\n' "$out" | grep -q 'UNMEASURED sections' \
           && printf '%s\n' "$out" | grep -qE 'unmeasured-sections=[0-9]+'; then
            echo "  PASS: a weights table missing sections reports them and falls back to the default"; pass=$((pass + 1))
        else
            echo "  FAIL: unmeasured sections were not reported"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
        fi
    else
        echo "  FAIL: --shards 3 --check failed against a thin weights table"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
    fi

    # 6m. ROUND 5, T2 (Astra, executed): the dependency scan treated ANY
    #     same-chunk assignment as satisfying every read in that chunk, so a
    #     read that PRECEDES a later same-chunk reassignment lost its producer
    #     in an earlier chunk — the chunks were not merged and the consumer
    #     shard printed an empty value and exited 0. This is Astra's miniature,
    #     driven through the real --shards/--emit-shard path.
    {
        printf '#!/bin/bash\n'
        printf 'TESTS_DIR="${EIGS_PLAN_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"\n'
        printf 'PASS=0\nFAIL=0\nTOTAL=0\nLEAKED=0\n'
        printf 'echo "[c1] producer"\n'
        printf 'ASTRA_CROSS=previous\n'
        printf 'echo "[c2] consumer"\n'
        printf "printf 'ASTRA_READ=<%%s>\\n' \"\$ASTRA_CROSS\"\n"
        printf 'ASTRA_CROSS=next\n'
        printf 'echo "[c3] filler"\n'
        printf 'TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))\n'
        printf '# Final guard (#681)\n'
        printf 'echo "  RESULTS: $PASS/$TOTAL passed, $FAIL failed"\n'
    } > "$dir/mini.sh"
    if out=$("$0" --shards 2 --check --runner "$dir/mini.sh" 2>&1); then
        if printf '%s\n' "$out" | grep -q 'merged: ASTRA_CROSS'; then
            echo "  PASS: a read BEFORE a same-chunk reassignment still merges with its earlier producer"; pass=$((pass + 1))
        else
            echo "  FAIL: the cross-chunk read was treated as satisfied by the LATER same-chunk assignment"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
        fi
    else
        echo "  FAIL: --shards 2 --check failed on the dependency miniature"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
    fi
    # And the consequence, end to end: whichever shard carries the consumer
    # must print the producer's value, not an empty one.
    mini_seen=""
    for mk in 1 2; do
        "$0" --emit-shard "$mk" 2 "$dir/mini_$mk.sh" --runner "$dir/mini.sh" >/dev/null 2>&1
        mini_out=$(bash "$dir/mini_$mk.sh" 2>&1 | grep -o 'ASTRA_READ=<[^>]*>' | head -1)
        [ -n "$mini_out" ] && mini_seen="$mini_out"
    done
    if [ "$mini_seen" = "ASTRA_READ=<previous>" ]; then
        echo "  PASS: the emitted consumer shard reads the producer value ($mini_seen)"; pass=$((pass + 1))
    else
        echo "  FAIL: the emitted consumer shard read '${mini_seen:-nothing}', expected ASTRA_READ=<previous>"; fail=$((fail + 1))
    fi

    # 6q. ROUND 6, T3: the AGGREGATOR's receipt check, driven with stub
    #     receipts. It lives in ci.yml as shell, so the control extracts that
    #     exact text and runs it — a copy here would be a second implementation
    #     that agrees with itself.
    if [ -f "$SP_ROOT/.github/workflows/ci.yml" ]; then
        mkdir -p "$dir/agg/shard-receipts"
        sed -n '/Require one receipt per shard/,/Sanitizer coverage complete/p' "$SP_ROOT/.github/workflows/ci.yml" \
          | sed -n '/^          set -/,$p' \
          | sed 's/\${{ env.ASAN_SHARDS }}/3/; s/\${{ needs.scope.outputs.code }}/true/' > "$dir/agg/agg.sh"
        agg_write() {   # <k> <plan-n> <leaked> [gc] [lsp]
            printf 'PLAN: shard=%s/%s sections=1 (of 263) chunks=1 predicted=1.00s unmeasured=0\nleaked=%s\ngc_traversal=%s\nlsp_asan=%s\n' \
                "$1" "$2" "$3" "${4:-no}" "${5:-no}" > "$dir/agg/shard-receipts/shard-$1.txt"
        }
        agg_run() { ( cd "$dir/agg" && bash agg.sh 2>&1 ); }
        if [ ! -s "$dir/agg/agg.sh" ]; then
            echo "  FAIL: could not extract the aggregator receipt check from ci.yml"; fail=$((fail + 1))
        else
            agg_write 1 3 0; agg_write 2 3 0 yes; agg_write 3 3 0 no yes
            if out=$(agg_run); then
                echo "  PASS: control: three well-formed receipts with a zero tally pass the aggregator"; pass=$((pass + 1))
            else
                echo "  FAIL: the aggregator rejected three well-formed receipts"; printf '%s\n' "$out" | tail -2 | sed 's/^/      /'; fail=$((fail + 1))
            fi
            agg_write 2 2 0 yes                  # the shape a shard prints when EIGS_SUITE_SHARD lost its /N
            if out=$(agg_run); then
                echo "  FAIL: a receipt saying shard=2/2 passed an ASAN_SHARDS=3 lane"; fail=$((fail + 1))
            elif printf '%s\n' "$out" | grep -q "expected 'PLAN: shard=2/3'"; then
                echo "  PASS: planted: a receipt whose N differs from ASAN_SHARDS is refused, and named"; pass=$((pass + 1))
            else
                echo "  FAIL: the shard=2/2 receipt was refused for the wrong reason"; printf '%s\n' "$out" | tail -2 | sed 's/^/      /'; fail=$((fail + 1))
            fi
            agg_write 2 3 0 yes; agg_write 3 3 1 no yes   # a leak in one shard must sink the SUM
            if out=$(agg_run); then
                echo "  FAIL: a summed leak tally of 1 passed the aggregator"; fail=$((fail + 1))
            elif printf '%s\n' "$out" | grep -q 'leak tally is 1'; then
                echo "  PASS: planted: a leak tally of 1 in one shard fails the summed check"; pass=$((pass + 1))
            else
                echo "  FAIL: the leak tally was refused for the wrong reason"; printf '%s\n' "$out" | tail -2 | sed 's/^/      /'; fail=$((fail + 1))
            fi

            # ROUND 6 T6: each job-level extra must have EXACTLY ONE claimant.
            # A derived owner nobody turns out to be is how "it runs somewhere"
            # becomes "it runs nowhere" — the failure that hard-wiring at least
            # could not have.
            agg_write 1 3 0; agg_write 2 3 0 yes; agg_write 3 3 0    # nobody claims lsp_asan
            if out=$(agg_run); then
                echo "  FAIL: an unclaimed job-level extra passed the aggregator"; fail=$((fail + 1))
            elif printf '%s\n' "$out" | grep -q 'lsp_asan was claimed by 0 shard'; then
                echo "  PASS: planted: an extra no shard claimed is refused"; pass=$((pass + 1))
            else
                echo "  FAIL: the unclaimed extra was refused for the wrong reason"; printf '%s\n' "$out" | tail -2 | sed 's/^/      /'; fail=$((fail + 1))
            fi
            agg_write 1 3 0 no yes; agg_write 3 3 0 no yes           # two shards claim lsp_asan
            if out=$(agg_run); then
                echo "  FAIL: an extra claimed twice passed the aggregator"; fail=$((fail + 1))
            elif printf '%s\n' "$out" | grep -q 'lsp_asan was claimed by 2 shard'; then
                echo "  PASS: planted: an extra claimed by two shards is refused"; pass=$((pass + 1))
            else
                echo "  FAIL: the double-claimed extra was refused for the wrong reason"; printf '%s\n' "$out" | tail -2 | sed 's/^/      /'; fail=$((fail + 1))
            fi
        fi
    else
        echo "  FAIL: ci.yml not found; the aggregator receipt check cannot be driven"; fail=$((fail + 1))
    fi

    # 6s. ROUND 6 T6: the extras' OWNER is derived, and both questions must
    #     answer with a shard index in range. The LSP one must land on the
    #     shard that runs [88] — that is the 1.5 s vs 267 s difference.
    own_light=$("$0" --shard-owner 3 --quiet 2>/dev/null)
    own_lsp=$("$0" --shard-owner 3 --section '[88]' --quiet 2>/dev/null)
    own_lsp_real=""
    for ok in 1 2 3; do
        if "$0" --shards 3 --shard "$ok" 2>&1 | grep -q '\[88\]'; then own_lsp_real="$ok"; fi
    done
    if [ "$own_light" -ge 1 ] 2>/dev/null && [ "$own_light" -le 3 ] \
       && [ "$own_lsp" = "$own_lsp_real" ]; then
        echo "  PASS: the extras' owners are derived (lightest=$own_light; [88] and the LSP test both on shard $own_lsp)"; pass=$((pass + 1))
    else
        echo "  FAIL: extras ownership is wrong (lightest='$own_light', LSP owner='$own_lsp', shard actually running [88]='$own_lsp_real')"; fail=$((fail + 1))
    fi
    if out=$("$0" --shard-owner 3 --section '[no-such-section]' --quiet 2>&1); then
        echo "  FAIL: --shard-owner accepted a section no chunk carries"; fail=$((fail + 1))
    else
        echo "  PASS: planted: --shard-owner refuses a section no chunk carries"; pass=$((pass + 1))
    fi

    # 6r. ROUND 6, T1: the runner must never INFER a shard number. A bare
    #     `EIGS_SUITE_SHARD=1` used to parse as k=1,n=1, so a job still named
    #     "shard 1/3" ran the whole suite while every check stayed green.
    for bad_s in 1 0/3 4/3 a/3; do
        if out=$(cd "$SP_ROOT/tests" && EIGS_SUITE_SHARD="$bad_s" timeout 120 bash run_all_tests.sh 2>&1); then
            echo "  FAIL: EIGS_SUITE_SHARD=$bad_s was accepted — a shard number must never be inferred"; fail=$((fail + 1))
        elif printf '%s\n' "$out" | grep -q "^ERROR: EIGS_SUITE_SHARD="; then
            echo "  PASS: planted: EIGS_SUITE_SHARD=$bad_s is refused before anything runs"; pass=$((pass + 1))
        else
            echo "  FAIL: EIGS_SUITE_SHARD=$bad_s went red for the wrong reason"; printf '%s\n' "$out" | tail -2 | sed 's/^/      /'; fail=$((fail + 1))
        fi
    done

    # 6n. ROUND 5, T6(1): N is validated at entry. Round 4 validated it nowhere:
    #     `--shards 0` and `--shards -1` exited 0 having examined ZERO shards,
    #     and `--shards abc` HUNG in the LPT awk. The `abc` case is bounded so a
    #     regression is a failure, never a hung selftest.
    for bad_n in 0 -1 abc; do
        if out=$(timeout 60 "$0" --shards "$bad_n" --check --quiet 2>&1); then
            echo "  FAIL: --shards $bad_n --check exited 0 — a run that examined zero shards must not be green"; fail=$((fail + 1))
        elif printf '%s\n' "$out" | grep -q 'shard count must be'; then
            echo "  PASS: planted: --shards $bad_n is refused at entry"; pass=$((pass + 1))
        else
            echo "  FAIL: --shards $bad_n went red for the wrong reason: $out"; fail=$((fail + 1))
        fi
    done

    # 6o. ROUND 5, T6(2): --print-weights must refuse a PARTIAL log. A single
    #     shard log has ~78 of the runner's 254 labels and used to sail through
    #     a floor of 50, producing a table in which ~160 sections silently took
    #     the default weight. Both halves, built from the runner's own labels.
    grep -oE 'echo "\[[^]]*\]' "$RUNNER" | sed 's/echo "//' | sort -u > "$dir/all_labels"
    awk 'NR<=60  { printf "SECTION_TIME: %s 0.10\n", $0 }' "$dir/all_labels" > "$dir/w_partial.log"
    awk 'NR<=230 { printf "SECTION_TIME: %s 0.10\n", $0 }' "$dir/all_labels" > "$dir/w_full.log"
    if out=$("$0" --print-weights "$dir/w_partial.log" 2>&1); then
        echo "  FAIL: --print-weights accepted a partial log; the table would default what it cannot see"; fail=$((fail + 1))
    elif printf '%s\n' "$out" | grep -q 'distinct sections'; then
        echo "  PASS: planted: --print-weights refuses a partial (one-shard) log"; pass=$((pass + 1))
    else
        echo "  FAIL: --print-weights refused a partial log for the wrong reason: $out"; fail=$((fail + 1))
    fi
    if out=$("$0" --print-weights "$dir/w_full.log" 2>&1) && [ "$(printf '%s\n' "$out" | grep -c '^\[')" -ge 200 ]; then
        echo "  PASS: control: --print-weights still accepts a log covering the runner"; pass=$((pass + 1))
    else
        echo "  FAIL: --print-weights refused a log that covers the runner"; printf '%s\n' "$out" | head -3 | sed 's/^/      /'; fail=$((fail + 1))
    fi

    # 6p. ROUND 5, T6(3): the smoke spread's size is derived, so no document may
    #     carry a literal count of it. It drifted twice (28 vs 27).
    # --exclude this file: the pin's own pattern lives here, so scanning it
    # makes the detector read its own reflection — the same §24 trap the gate
    # audit self-excludes for. This file declares no valgrind spread.
    if out=$(grep -rn --exclude=section_plan.sh '28-name\|28-program\|those 28' \
                 "$SP_ROOT/.github" "$SP_ROOT/tests" "$SP_ROOT/tools" "$SP_ROOT/docs" \
                 "$SP_ROOT/CHANGELOG.md" 2>/dev/null); then
        echo "  FAIL: a hard-coded valgrind smoke count is back:"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
    else
        echo "  PASS: no document carries a literal valgrind smoke count (the job prints programs=N)"; pass=$((pass + 1))
    fi

    # 7. The emitted runner for a real variant must parse.
    expect_ok "control: the emitted core runner is syntactically valid" \
        "$0" --emit core "$dir/emitted.sh"

    echo "section_plan selftest: checks=$((pass + fail)) failures=$fail"
    [ "$fail" -eq 0 ] || rc=1
    return $rc
}

# ---------------------------------------------------------------------------
MODE=""
ARG1=""
ARG2=""
ARG3=""
SP_SHARDS=""
SP_SHARD_K=""
SP_ROOT_RUNNER_SET=0
case " $* " in *" --runner "*) SP_ROOT_RUNNER_SET=1 ;; esac
while [ "$#" -gt 0 ]; do
    case "$1" in
        --runner) RUNNER="$2"; shift 2 ;;
        # --root re-points the tree the audit reads (the runner and the child
        # scripts it dispatches). The selftest uses it to plant a fault into a
        # CHILD without touching the real tree (mechanical-gates §22).
        --root) SP_ROOT=$(cd "$2" && pwd); [ "$SP_ROOT_RUNNER_SET" = "1" ] || RUNNER="$SP_ROOT/tests/run_all_tests.sh"; shift 2 ;;
        --binary) BINARY="$2"; shift 2 ;;
        --quiet)  VERBOSE=0; shift ;;
        --chunks|--probes|--markers|--gate-audit|--skip-audit|--selftest) MODE="$1"; shift ;;
        --shards) SP_SHARDS="$2"; shift 2 ;;
        --shard) SP_SHARD_K="$2"; shift 2 ;;
        --check) MODE="--shard-check"; shift ;;
        --weights-file) WEIGHTS_FILE="$2"; shift 2 ;;
        --print-weights) MODE="$1"; ARG1="$2"; shift 2 ;;
        --shard-owner) MODE="$1"; ARG1="$2"; shift 2 ;;
        --section) ARG2="$2"; shift 2 ;;
        --run) WEIGHTS_RUN="$2"; shift 2 ;;
        --head) WEIGHTS_HEAD="$2"; shift 2 ;;
        --emit-shard) MODE="$1"; ARG1="$2"; ARG2="$3"; ARG3="$4"; shift 4 ;;
        --print-waivers) SP_PRINT_WAIVERS=1; export SP_PRINT_WAIVERS; shift ;;
        --print-section-plan) MODE="$1"; ARG1="$2"; shift 2 ;;
        --emit) MODE="$1"; ARG1="$2"; ARG2="$3"; shift 3 ;;
        *) die "unknown argument '$1'" ;;
    esac
done
if [ -z "$MODE" ] && [ -n "$SP_SHARDS" ] && [ -n "$SP_SHARD_K" ]; then MODE="--shard-plan"; fi
[ -n "$MODE" ] || die "no mode given (see the header for usage)"
[ -f "$RUNNER" ] || die "runner not found: $RUNNER"

case "$MODE" in
    --chunks)
        W=$(sp_workdir mode)
        derive_chunks "$RUNNER" > "$W/chunks"
        verify_partition "$RUNNER" "$W/chunks"
        n=$(grep -c '[0-9]' "$W/chunks")
        [ "$VERBOSE" = "1" ] && cat "$W/chunks"
        echo "CHUNKS: $n  preamble=1-$SP_PREAMBLE_END  epilogue=$SP_EPILOGUE_START-$SP_TOTAL_LINES  partition=verified"
        ;;
    --markers|--gate-audit)
        W=$(sp_workdir mode)
        derive_chunks "$RUNNER" > "$W/chunks"
        verify_partition "$RUNNER" "$W/chunks"
        derive_markers "$RUNNER" "$W/chunks" > "$W/markers"
        n=$(grep -c '[0-9]' "$W/markers")
        if [ "$VERBOSE" = "1" ]; then
            while IFS=$'\t' read -r ms mc; do
                [ -n "$ms" ] || continue
                me=$(awk -v s="$ms" '$1==s {print $2}' "$W/chunks")
                ids=$(awk -v s="$ms" '$1==s {$1="";$2="";print}' "$W/chunks" | sed 's/^  *//')
                echo "marker  cap=$mc  chunk @$ms-$me  sections: $ids"
            done < "$W/markers"
        fi
        [ "$n" -ge "$CAP_MARKER_FLOOR" ] || { die "EIGS-CAP-GATE markers=$n < floor=$CAP_MARKER_FLOOR"; }
        if [ "$MODE" = "--gate-audit" ]; then
            gate_audit "$RUNNER" "$W/chunks" "$W/markers" "$W"
            echo "GATE AUDIT: markers=$n (floor $CAP_MARKER_FLOOR)  enumerated gate lines=$SP_GATE_HITS (floor $GATE_HIT_FLOOR) over the runner + $SP_CHILD_COUNT dispatched children  waivers used=$SP_WAIVERS_USED  unaccounted=0"
        else
            echo "MARKERS: $n (floor $CAP_MARKER_FLOOR)"
        fi
        ;;
    --skip-audit)
        W=$(sp_workdir mode)
        skip_audit "$RUNNER" "$W"
        echo "SKIP AUDIT: $SP_SKIP_EMITS SKIP-emitting line(s) enumerated (floor $SKIP_EMIT_FLOOR); $SP_SKIP_ROUTED section-level skip(s) routed through section_skip() (floor $SKIP_ROUTED_FLOOR); $SP_SKIP_WAIVERS_USED reviewed reason(s) used; unaccounted=0"
        ;;
    --probes)
        W=$(sp_workdir mode)
        derive_chunks "$RUNNER" > "$W/chunks"
        verify_partition "$RUNNER" "$W/chunks"
        derive_probes "$RUNNER" "$W/chunks" "$W" > "$W/probes"
        n=$(grep -c '[0-9]' "$W/probes")
        if [ "$VERBOSE" = "1" ]; then
            while IFS=$'\t' read -r ps pout ppat _pprog; do
                [ -n "$ps" ] || continue
                ids=$(awk -v s="$ps" '$1==s {$1="";$2="";print}' "$W/chunks" | sed 's/^  *//')
                echo "chunk @$ps  probe=$pout  guard=\"$ppat\"  sections: $ids"
            done < "$W/probes"
        fi
        derive_markers "$RUNNER" "$W/chunks" > "$W/markers"
        m=$(grep -c '[0-9]' "$W/markers")
        [ "$m" -ge "$CAP_MARKER_FLOOR" ] || { die "EIGS-CAP-GATE markers=$m < floor=$CAP_MARKER_FLOOR"; }
        verify_probe_coverage "$W/markers" "$W/probes"
        echo "PROBES: $n provider(s) for $SP_CAPS_DECLARED declared capability(ies); every probe chunk carries a marker and every capability has a provider (markers=$m, floor $CAP_MARKER_FLOOR)"
        ;;
    --print-section-plan)
        build_plan "$ARG1"
        ;;
    --emit)
        emit_plan "$ARG1" "$ARG2"
        ;;
    --shard-check)
        [ -n "$SP_SHARDS" ] || die "--check needs --shards N"
        shard_check "$SP_SHARDS"
        ;;
    --print-weights)
        print_weights "$ARG1"
        ;;
    --shard-owner)
        shard_owner "$ARG1" "$ARG2"
        ;;
    --emit-shard)
        emit_shard "$ARG1" "$ARG2" "$ARG3"
        ;;
    --shard-plan)
        build_shard_plan "$SP_SHARD_K" "$SP_SHARDS"
        ;;
    --selftest)
        selftest
        ;;
esac

