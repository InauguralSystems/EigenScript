#!/usr/bin/env bash
# #1007 round 3: the CONTAINER-SHAPE sweep over ext_gfx.c's guarded surface.
#
# WHY THIS EXISTS, and it is a process finding rather than a code one.
# #1007 landed three times and a blind review found one more silent builtin
# each time, always the SAME axis and never the same builtin:
#
#   round 1 -> 2  the eight audio GENERATORS answered a short argument list
#                 with an empty sample list -- indistinguishable from a
#                 legitimately empty generation.
#   round 2 -> 3  the three audio *_open builtins answered a SHORT or non-list
#                 argument by opening the device at the 44100/1 defaults and
#                 handing back a REAL DEVICE ID, so a caller that asked for
#                 48000 was told it got 48000.
#   round 3       audio_play / audio_stream_push / audio_play_loop answered a
#                 non-list `samples` with the documented "nothing to play" 0,
#                 while a wrong-typed ELEMENT of a list already raised.
#
# Each time the hand-written probe table in tools/strict_differential.sh was
# green, because every row in it held the ARITY right and varied only the
# element TYPE. The table asked the question in the one state where it could
# not fail. Adding a fourth hand-written row would fix the last instance and
# not the pattern, so this asks the question mechanically instead: it derives
# the guarded names AND their required arity from src/ext_gfx.c itself, and
# crosses each with the container shapes a caller actually gets wrong.
#
# THE POPULATION IS DERIVED, NOT LISTED. Every ARG_GUARD / STRICT_REQUIRE in
# the file names a builtin and spells the shape it wanted; the bracketed group
# in that `want` string is the arity. So a builtin added tomorrow with a guard
# is swept tomorrow, and one whose guard is deleted leaves the population and
# trips the floor. What is hand-written is only the ALLOWLIST of pairs that
# are quiet ON PURPOSE, and each entry carries its reason and is checked for
# staleness: an allowlisted pair that starts raising fails this script, so the
# list cannot rot into a blanket waiver.
#
# WHAT THIS DOES NOT COVER, stated so the next reader does not assume it:
#   - It sweeps builtins that HAVE a guard. A builtin with no guard at all has
#     no `want` string, so it is not in the population; that gap is covered by
#     the guarded-name cross-check in tools/strict_differential.sh, which goes
#     red for a guarded name with no probe, and by [135] for guard ORDER.
#   - It probes the TOP-LEVEL argument container (arity and type), not element
#     values and not a NESTED container. `audio_play_loop of [42, 2]` -- a
#     non-list in the samples SLOT -- is the third round's third bug and this
#     sweep does not see it: the top-level argument is a well-formed 2-element
#     list. That row is pinned by hand in tests/test_gfx_argtypes.eigs; a
#     nested-slot sweep would need per-slot types, which the `want` strings do
#     not carry uniformly. Out-of-domain numbers (a negative width, loops == 0)
#     are the differential table's axis and stay there.
#
# VALIDATED BY EXECUTION, not by argument. Pointed at a build of the parent
# commit (no guards at all) it reports raised=0 and trips its own floor;
# pointed at the SECOND round of this same change -- the artifact a blind
# review failed -- it names 18 rows across audio_open, audio_capture_open,
# audio_stream_open, audio_play and audio_stream_push, which is the finding
# that review made by hand plus two builtins it did not reach.
#   - It runs under EIGS_STRICT=1 only. The "byte-identical with the flag off"
#     half is tools/strict_differential.sh's, which needs two binaries.
#
# Usage: bash tools/gfx_strict_sweep.sh [--selftest]
#   EIGS_SWEEP_BIN overrides the binary (default ./src/eigenscript). Pointing
#   it at a build that PREDATES a guard is how this harness is validated: the
#   rows that guard covers go silent and the script fails.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

BIN="${EIGS_SWEEP_BIN:-./src/eigenscript}"
SRC=src/ext_gfx.c
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"

# ---------------------------------------------------------------- allowlist
# name|shape-id|reason. A pair here is quiet ON PURPOSE. Staleness is checked:
# if the pair RAISES, this script fails and the entry must go.
ALLOW=$(cat <<'EOF'
gfx_text_height|scalar|the scale slot is documented as `gfx_text_height of 2`, a bare number
gfx_text_height|list2|[scale] with a numeric first slot is the documented list form; the surplus slot is #989
gfx_text_width|string|`gfx_text_width of "hello"` is the documented one-argument form
audio_pause|scalar|`audio_pause of 1` is the documented flag form
audio_stop|scalar|`audio_stop of 1` is the documented channel form
audio_music_volume|scalar|`audio_music_volume of 96` is the documented form
audio_music_volume|list2|[volume] with a numeric first slot is the documented list form; the surplus slot is #989
gfx_delay|scalar|`gfx_delay of 16` is the documented one-argument form
gfx_title|string|`gfx_title of "name"` is the documented one-argument form
audio_play|list2|a 2-element numeric list IS a sample list -- the valid call
audio_stream_push|list2|a 2-element numeric list IS a sample list -- the valid call
EOF
)

# ------------------------------------------------------------ required names
# The population is DERIVED, which means a deleted guard does not fail a
# derived check -- it leaves the population, and coverage vanishes with it.
# Bought by this tool's own planted fault: removing audio_play's guard took
# the sweep from 35 names to 34 and it still printed OK, which is the exact
# vacuity this file exists to prevent, one level up. So the names that had a
# guard when this landed are PINNED. A new guarded builtin grows the
# population on its own and needs no edit here; a name that disappears fails,
# and removing it from this list is the review event that says so out loud.
REQUIRED_NAMES="audio_capture_open audio_envelope audio_gain audio_mix audio_music_play
audio_music_volume audio_noise audio_open audio_pause audio_play
audio_play_loop audio_saw audio_sine audio_square audio_stop
audio_stream_open audio_stream_push audio_sweep audio_volume gfx_circle
gfx_clear gfx_clip gfx_delay gfx_fb gfx_line
gfx_open gfx_point gfx_read gfx_rect gfx_rrect
gfx_text gfx_text_height gfx_text_width gfx_title ppu_render_frame"

# ------------------------------------------------------------- the population
# Join the file into one stream first: ARG_GUARD/STRICT_REQUIRE invocations
# span lines, so a per-line grep loses the `want` string of every multi-line
# call -- which is most of the drawing surface.
POP="$(tr '\n' ' ' < "$SRC" \
  | grep -oE '(ARG_GUARD|ARG_GUARD_TAPED|ARG_GUARD_PRETAKE|STRICT_REQUIRE)\([^;]*;' \
  | grep -oE '"(gfx|audio|ppu)_[a-z_]+", *"[^"]*"' \
  | sed 's/", *"/|/; s/^"//; s/"$//')"

# One row per name: the SMALLEST bracketed slot count any of its guards asks
# for is its required arity (a guard that wants more slots is describing an
# optional tail). Names whose `want` has no bracketed group are scalar-argument
# builtins and get the scalar-shaped probes instead.
NAMES="$(printf '%s\n' "$POP" | cut -d'|' -f1 | sort -u)"
n_names=$(printf '%s\n' "$NAMES" | sed '/^$/d' | wc -l)
# Pure shell, no subprocess, and that is load-bearing rather than tidy: the
# first version ran `grep -qx` 35 times and, on this shared box, occasionally
# reported `audio_sweep` missing when it was plainly there. A grep that cannot
# be forked exits nonzero, and `|| MISSING=...` reads that as "absent" -- the
# SAME conflation of "the check did not run" with "the check says no" that the
# UNRUN verdict exists for, one level up. A case-glob cannot fail to run.
# ONE matcher, used by the pin loop below and by --selftest's row for it.
# The selftest used to re-implement this as `printf | grep -qx`, which is the
# #1122-banned shape and, worse, meant the row proved a matcher this file does
# not use.
name_in_population() {   # <name> -> 0 when $NAMES carries it as a whole line
    case "
$NAMES
" in *"
$1
"*) return 0 ;; esac
    return 1
}

MISSING=""
for req in $REQUIRED_NAMES; do
    name_in_population "$req" || MISSING="$MISSING $req"
done

arity_of() {  # $1 = name -> smallest bracketed slot count, or 0 for none
    printf '%s\n' "$POP" | awk -F'|' -v n="$1" '
        $1 == n {
            w = $2
            if (match(w, /\[[^]]*\]/)) {
                g = substr(w, RSTART + 1, RLENGTH - 2)
                k = 1
                for (i = 1; i <= length(g); i++) if (substr(g, i, 1) == ",") k++
                if (best == 0 || k < best) best = k
            }
        }
        END { print best + 0 }'
}

# ------------------------------------------------------------------- shapes
# shape-id -> the EigenScript argument text. `short` is filled per name.
#
# `([1])` is parenthesised deliberately: a bare 1-element list is an ARGUMENT
# LIST at every count, so `f of [1]` passes the element 1, not the list. The
# parenthesised form is how a 1-element list is passed whole (#355/#405).
shape_text() {  # $1 = shape-id, $2 = arity
    case "$1" in
        scalar) echo '42' ;;
        string) echo '"zzz"' ;;
        dict)   echo '{"k": 1}' ;;
        list2)  echo '[1, 2]' ;;
        short)  k=$(( $2 - 1 ))
                if [ "$k" -le 0 ]; then echo ''
                elif [ "$k" -eq 1 ]; then echo '([1])'
                else printf '['; for i in $(seq 1 "$k"); do
                         [ "$i" -gt 1 ] && printf ', '; printf '%d' "$i"; done; printf ']\n'
                fi ;;
    esac
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# $1 = name, $2 = argument text -> SILENT | RAISED-OWN | RAISED-OTHER | UNRUN
#
# FOUR verdicts, not three, and the fourth is why: the first version of this
# function had `else echo RAISED-OTHER`, which folded "raised from somebody
# else's guard" together with "did not run at all". On a 4-core box shared
# with eight other agents' suites the second happens: the child is killed and
# exits nonzero having printed no runtime error, and the section reported
# MISATTRIBUTED audio_open — a guard verdict, for a probe that never reached
# a guard. Caught by this tool's own first suite run, and it is #988's rule
# exactly: a child that did not complete must not produce a section verdict.
# So a nonzero exit with NO `Error line` is UNRUN, retried, and if it never
# runs it fails the gate under its own name rather than impersonating a
# finding. The last output is left in $TMP/last.out for the diagnostic.
verdict() {
    printf 'ignore is %s of %s\n' "$1" "$2" > "$TMP/p.eigs"
    tries=0
    while [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        out="$(EIGS_STRICT=1 "$BIN" "$TMP/p.eigs" 2>&1)"; rc=$?
        printf '%s\n' "$out" > "$TMP/last.out"
        if [ "$rc" -eq 0 ]; then echo SILENT; return; fi
        # case-globs, not `grep -q`. Two greps per row x 140 rows is 280 forks
        # on a box shared with eight other suites, and a grep that cannot fork
        # exits nonzero -- which read as "this line is not there" and turned
        # RAISED-OWN into MISATTRIBUTED at about one run in eight (measured).
        # A verdict must not depend on whether a helper process started.
        case "$out" in
            "Error line 1: $1:"*|*"
Error line 1: $1:"*) echo RAISED-OWN; return ;;
        esac
        case "$out" in
            "Error line "*|*"
Error line "*) echo RAISED-OTHER; return ;;
        esac
        echo "retry: $1 of $2 (exit $rc, no runtime error printed)" >> "$TMP/retries"
    done
    echo UNRUN
}

# ----------------------------------------------------------------- selftest
if [ "${1:-}" = "--selftest" ]; then
    # The classifier rows below RUN the binary, so they need the gfx builtins
    # for the same reason the sweep does. Checked here as well as in the sweep
    # because --selftest returns before the sweep's own probe: without this the
    # release lane reported "the sweep's own selftest is red" on a binary that
    # simply has no gfx surface to classify.
    printf 'ignore is gfx_text_height of null\n' > "$TMP/probe.eigs"
    sf_probe="$("$BIN" "$TMP/probe.eigs" 2>&1)" || true
    case "$sf_probe" in
        *"undefined variable"*)
            echo "== gfx_strict_sweep selftest =="
            echo "  SKIP: $BIN was built without EIGENSCRIPT_EXT_GFX"
            exit 0 ;;
    esac
    sf_pass=0; sf_fail=0
    sf() { if [ "$2" = "$3" ]; then echo "  PASS $1"; sf_pass=$((sf_pass+1));
           else echo "  FAIL $1 (got '$2', want '$3')"; sf_fail=$((sf_fail+1)); fi }
    echo "== gfx_strict_sweep selftest =="
    # The arity parser, on shapes taken verbatim from the file.
    p_arity() { printf '%s\n' "$1" | awk '
        { w = $0
          if (match(w, /\[[^]]*\]/)) {
              g = substr(w, RSTART + 1, RLENGTH - 2); k = 1
              for (i = 1; i <= length(g); i++) if (substr(g, i, 1) == ",") k++
              print k } else print 0 }'; }
    sf "arity of a 7-slot want" \
       "$(p_arity '[number x, number y, number w, number h, number r, number g, number b] and an optional number alpha')" 7
    sf "arity of a 2-slot want" "$(p_arity '[number freq, number channels] or null')" 2
    sf "arity of a scalar want" "$(p_arity 'number milliseconds')" 0
    # The short-list builder, including the 1-element spread trap.
    sf "short list at arity 3" "$(shape_text short 3)" '[1, 2]'
    sf "short list at arity 2 is parenthesised" "$(shape_text short 2)" '([1])'
    sf "short list at arity 1 is empty (nothing shorter)" "$(shape_text short 1)" ''
    # The pinned-name check, proven by asking it about a name that is not in
    # the population. Without this row the check could be an empty loop.
    _sweep_miss=""
    for req in $REQUIRED_NAMES eigs_no_such_builtin_1007; do
        name_in_population "$req" || _sweep_miss="$_sweep_miss $req"
    done
    sf "pinned-name check notices a name absent from the population" \
       "$_sweep_miss" " eigs_no_such_builtin_1007"
    sf "every pinned name IS in the population right now" "$MISSING" ""
    # The population must be non-vacuous and must contain the three names each
    # round missed, which is the only reason this file exists.
    for n in audio_sine audio_stream_open audio_play; do
        case "$NAMES" in *"$n"*) sf "population contains $n" yes yes ;;
                         *)      sf "population contains $n" no yes ;; esac
    done
    # The verdict classifier, exercised against the live binary on a call that
    # must raise and one that must not. A classifier that always says RAISED
    # would pass every row in the sweep.
    sf "classifier scores a well-formed gfx_text_height quiet" "$(verdict gfx_text_height 'null')" SILENT
    sf "classifier scores a dict to gfx_rect as its own raise"  "$(verdict gfx_rect '{"k": 1}')" RAISED-OWN
    # The other two branches, both proven rather than assumed. A raise that is
    # not this builtin's must not read as its guard firing; and a child that
    # exits nonzero having printed nothing must not read as a verdict at all
    # -- that conflation is what this tool's own first suite run produced
    # (MISATTRIBUTED audio_open, from a probe killed on a loaded box).
    sf "classifier scores somebody else's raise misattributed" \
       "$(verdict eigs_no_such_builtin_1007 '42')" RAISED-OTHER
    _sweep_savebin="$BIN"; BIN=/bin/false
    sf "classifier scores a killed child UNRUN, not a guard verdict" \
       "$(verdict gfx_rect '42')" UNRUN
    BIN="$_sweep_savebin"
    echo "selftest: $sf_pass passed, $sf_fail failed"
    [ "$sf_fail" -eq 0 ] || exit 1
    exit 0
fi

# --------------------------------------------------------------------- sweep
echo "== #1007 container-shape sweep =="
[ -x "$BIN" ] || { echo "FAIL: no built binary at $BIN"; exit 1; }
# NOT `"$BIN" ... | grep -q`: this script runs under `set -o pipefail`, and the
# probe program EXITS NONZERO on the very build the probe is looking for (the
# undefined-variable error is the signal), so the pipeline's status was 1 even
# when grep matched and the skip never fired. Measured: the release lane ran the
# whole sweep against a binary with no gfx builtins and reported 140
# MISATTRIBUTED rows. Capture, then match with a case-glob -- no pipeline, and
# no subprocess whose failure could decide the answer.
printf 'ignore is gfx_text_height of null\n' > "$TMP/probe.eigs"
probe_out="$("$BIN" "$TMP/probe.eigs" 2>&1)" || true
case "$probe_out" in
    *"undefined variable"*)
        echo "  SKIP: $BIN was built without EIGENSCRIPT_EXT_GFX"
        exit 0 ;;
esac

# One leading newline so the first allowlist row matches the same glob as the
# rest, and so `${ALLOW_NL#*...}` can find it.
ALLOW_NL="
$ALLOW"
PROBED=""
rc=0; n_rows=0; n_raised=0; n_silent=0; n_other=0; n_allowed=0; n_unrun=0
silent_list=""; other_list=""; used_allow=""
for name in $NAMES; do
    ar=$(arity_of "$name")
    case "$ar" in
        ''|*[!0-9]*) echo "  FAIL: could not derive an arity for $name (the awk"
                     echo "        pass produced '$ar'); a missing arity would"
                     echo "        silently pick the wrong probe shapes."
                     rc=1; continue ;;
    esac
    if [ "$ar" -ge 2 ]; then shapes="short scalar string dict"
    else                     shapes="scalar string dict list2"; fi
    for sh in $shapes; do
        txt="$(shape_text "$sh" "$ar")"
        [ -z "$txt" ] && continue
        n_rows=$((n_rows + 1))
        PROBED="$PROBED
$name|$sh"
        v="$(verdict "$name" "$txt")"
        # Same rule as the pinned-name check above: no subprocess, so a fork
        # that fails cannot masquerade as "not allowlisted".
        allowed=""
        case "$ALLOW_NL" in
            *"
$name|$sh|"*) rest="${ALLOW_NL#*"
$name|$sh|"}"; allowed="${rest%%
*}" ;;
        esac
        case "$v" in
            RAISED-OWN)
                n_raised=$((n_raised + 1))
                if [ -n "$allowed" ]; then
                    other_list="$other_list
    STALE ALLOWLIST $name|$sh — it raises now; delete the entry"
                    rc=1
                fi ;;
            RAISED-OTHER)
                n_other=$((n_other + 1))
                other_list="$other_list
    MISATTRIBUTED $name of $txt — raised, but not from $name's own guard"
                rc=1 ;;
            UNRUN)
                n_unrun=$((n_unrun + 1))
                other_list="$other_list
    DID NOT RUN $name of $txt — nonzero exit, no runtime error, 3 attempts; last output:
$(sed -n '1,3p' "$TMP/last.out" | sed 's/^/      /')"
                rc=1 ;;
            SILENT)
                if [ -n "$allowed" ]; then
                    n_allowed=$((n_allowed + 1))
                    used_allow="$used_allow
    allowed $name of $txt — $allowed"
                else
                    n_silent=$((n_silent + 1))
                    silent_list="$silent_list
    SILENT UNDER STRICT: $name of $txt"
                    rc=1
                fi ;;
        esac
    done
done

echo "  guarded names=$n_names  rows=$n_rows"
echo "  raises-under-strict: $n_raised   silent: $n_silent   misattributed: $n_other   did-not-run: $n_unrun"
echo "  quiet on purpose (allowlisted): $n_allowed"
# Retries are not failures, but a box that needed them is a box whose numbers
# deserve a caveat, so they are printed rather than swallowed.
[ -s "$TMP/retries" ] && { echo "  probes retried after a killed child: $(wc -l < "$TMP/retries")"; sed 's/^/    /' "$TMP/retries"; }
[ -n "${SWEEP_VERBOSE:-}" ] && [ -n "$used_allow" ] && echo "$used_allow"
[ -n "$silent_list" ] && echo "$silent_list"
[ -n "$other_list" ]  && echo "$other_list"

# An allowlist entry that nothing PROBES is stale in the other direction, and
# the raises-now check above cannot see it: six such entries shipped in the
# first draft of this file (`audio_open|list2` and friends, for a shape that
# is only probed on arity-1 builtins), each quietly waiving nothing. A waiver
# for a question never asked is the tidiest way to look covered.
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    key="${entry%%|*}"; rest="${entry#*|}"; key="$key|${rest%%|*}"
    case "$PROBED" in
        *"
$key"*) ;;
        *) echo "  DEAD ALLOWLIST $key — no probe ever asks this pair; delete it"
           rc=1 ;;
    esac
done <<EOF
$ALLOW
EOF

# A pinned name that has left the population means its guard is gone, and a
# derived population cannot notice that on its own.
if [ -n "$MISSING" ]; then
    echo "  GUARD REMOVED — pinned builtins no longer carry any guard in $SRC:$MISSING"
    echo "  They are therefore unswept. Restore the guard, or delete the name from"
    echo "  REQUIRED_NAMES in this file and say why in the commit."
    rc=1
fi

# Non-vacuity floors. Without them a broken extractor sweeps nothing and
# reports OK -- the exact failure mode this tool was written to replace.
if [ "$n_names" -lt 25 ] || [ "$n_rows" -lt 90 ] || [ "$n_raised" -lt 70 ]; then
    echo "  VACUOUS: names=$n_names rows=$n_rows raised=$n_raised — below the floor;"
    echo "  the extractor or the binary is wrong, not the guards."
    rc=1
fi

[ "$rc" -eq 0 ] && echo "OK" || echo "FAIL"
exit $rc
