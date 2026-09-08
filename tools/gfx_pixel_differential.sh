#!/usr/bin/env bash
# #1007 round 2: the PIXEL differential — the half tools/strict_differential.sh
# structurally cannot measure.
#
# WHY THIS EXISTS. strict_differential.sh compares the RETURNED VALUE of a
# probe on two binaries. Every drawing builtin in ext_gfx.c returns null on
# every path, and every gfx probe there runs with NO WINDOW OPEN — the guards
# all sit above the SDL load, which is the point of [135]. So its
# `identical-when-off: N differing: 0` line was, for the whole drawing
# surface, measured in the one state where it could not fail: nothing was
# drawn on either side, and null == null.
#
# A blind review found that hole by hand, with a readback oracle, and it was
# right to: `gfx_text of [0, 0, "H", 255, 255, 255, "2"]` draws 17 lit pixels
# on the parent build and 0 on this one, and NOTHING in the change could see
# it. This tool is that oracle, mechanised.
#
# WHAT IT DOES. Each row opens a 32x32 window under the dummy video driver,
# clears it, makes ONE call, and prints a digest of the whole back buffer read
# back through gfx_read. The digest — not the return value — is the observable
# compared between the baseline (a build of the parent commit) and this build.
#
#   valid-*   rows: a CORRECT call. Must be byte-identical on both binaries in
#             BOTH modes. This is the half that catches an over-broad guard:
#             a guard that rejects a legitimate call shows up as a blank
#             canvas here and as nothing at all in a return-value differential.
#   wrong-*   rows: one argument slot given the wrong type. Flag-off must be
#             byte-identical UNLESS the row carries a waiver proof (below),
#             and EIGS_STRICT=1 must raise naming that builtin.
#
# THE WAIVER PROOF, and exactly what it does and does not establish.
#   #1007 type-checks ~89 `items[N]->data.num` reads that had none. Reading a
#   `Value*` union's `.num` when the value is a string is UB, and what the
#   parent DREW came from reinterpreting a pointer — so those rows legitimately
#   change with the flag off, and the issue says so ("an unchecked read is not
#   a behaviour anyone depends on"). A waiver may not be taken on trust, so
#   each waived row carries a ZERO VARIANT: the same program with the
#   wrong-typed value replaced by the number 0. The proof executed here is
#
#       baseline(wrong-typed program) == baseline(zero program)
#
#   i.e. the parent's answer to the wrong-typed argument was not an answer at
#   all — it was, indistinguishably, its answer to 0, which is what a
#   reinterpreted 48-bit pointer truncates to as a double. Plus: the baseline
#   must be stable across two runs (otherwise "the old answer was X" is not a
#   statement about anything), and the NEW binary must raise under strict.
#
#   A proven waiver licenses REJECTING the call and nothing else: the second
#   half requires the new binary's canvas to equal the canvas of the same
#   program with the offending call DELETED. Without it a waiver would excuse
#   any new behaviour at all, including a "helpful" coercion that draws
#   something different from what the program asked for.
#
#   What it does NOT establish: that no COERCION site could ever pass it. A
#   coercion whose default happens to equal its zero-behaviour (a scale
#   clamped `if (scale < 1) scale = 1`) satisfies the equality too. It DOES
#   discriminate every coercion whose default differs from zero — an alpha
#   defaulting to 255, a colour defaulting to white — and it makes the claim
#   being waived explicit and executable instead of asserted. Read the site
#   before adding a waiver; this proves the claim, it does not choose it.
#
# COVERAGE IS DERIVED FROM THE SOURCE, not from this file's own row list.
#   1. Every builtin in ext_gfx.c that carries a guard AND touches g_renderer
#      must have at least one row.
#   2. Every `gfx_nums(arg, A, B)` range in ext_gfx.c must have a wrong-typed
#      row at slot A and at slot B-1 — the FIRST and LAST slot the guard
#      covers. B-1 is normally an OPTIONAL trailing argument (gfx_rect's
#      alpha, gfx_text's scale), which is precisely the slot the hand-written
#      probe table missed. A widened guard with no row for its new boundary
#      fails this script rather than passing quietly.
#
# Usage: bash tools/gfx_pixel_differential.sh <baseline-gfx-binary>
#        bash tools/gfx_pixel_differential.sh --no-baseline
#   The baseline is a `make gfx` build of the PARENT commit:
#     git worktree add --detach DIR <parent-sha> && make -C DIR gfx
#   --no-baseline keeps the halves that need one binary (strict raises,
#   coverage, non-vacuity) and says the identity half was skipped. As with
#   strict_differential.sh, a differential with no reference is not a pass.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"

# THE BINARY UNDER TEST IS src/eigenscript — the hard link to the last `make`
# target — not build/gfx/eigenscript. Defaulting to the gfx objdir would test a
# stale gfx build during a release suite run, i.e. a binary nobody asked about,
# and would report PASS for it. Under `make` the link has no gfx builtins and
# this script SKIPs; under `make gfx` it is the gfx build and the rows run. Same
# probe-gate shape as [132]/[133]. EIGS_GFX_NEW overrides for a two-binary run.
NEW="${EIGS_GFX_NEW:-./src/eigenscript}"
BASE="${1:-}"
NO_BASELINE=0
[ "$BASE" = "--no-baseline" ] && { NO_BASELINE=1; BASE=""; }

[ -x "$NEW" ] || { echo "FAIL: no built binary at $NEW"; exit 1; }
if [ -z "$BASE" ] && [ "$NO_BASELINE" = 0 ]; then
    echo "FAIL: no baseline binary given. Pass a 'make gfx' build of the parent"
    echo "      commit, or --no-baseline to skip the identity half deliberately."
    exit 1
fi

# The gfx builtins must EXIST in this build. A release binary has no gfx_open
# at all, and every row would then 'fail' for a reason that has nothing to do
# with a guard — so this is a clean SKIP, the same shape [132]/[133] use.
probe=$(mktemp); printf 'print of (gfx_text_width of ["m", 1])\n' > "$probe"
probe_out="$("$NEW" "$probe" 2>&1 || true)"; rm -f "$probe"
case "$probe_out" in
    *"undefined variable"*)
        echo "SKIP: $NEW was built without EIGENSCRIPT_EXT_GFX (no gfx builtins)"
        exit 0 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A RENDERER must actually open. libSDL2 is dlopen'd, so the gfx binary builds
# and runs without it — and then every row draws nothing, the valid rows look
# vacuous and this tool would report a defect that is really an absent library.
# Probed by opening a window, because that is the thing the rows need.
# The PIXEL halves need it; the strict-raise and coverage halves do not (every
# guard sits above the SDL load, which is [135]'s rule), so a missing library
# degrades this tool to those instead of switching it off. A whole gate that
# skips is a gate CI never runs.
printf 'print of (gfx_open of [8, 8, "pixdiff-probe"])\n' > "$TMP/open.eigs"
NO_RENDERER=0
if [ "$("$NEW" "$TMP/open.eigs" 2>&1 | tail -1)" != "1" ]; then
    NO_RENDERER=1
    BASE=""   # nothing to compare: neither binary can draw
    echo "  NOTE: no renderer (libSDL2 absent, or no video device for"
    echo "        SDL_VIDEODRIVER=$SDL_VIDEODRIVER) — the pixel halves are OFF."
    echo "        The strict-raise and coverage halves still run: every guard sits"
    echo "        above the SDL load, so they are reachable without a window."
fi

# ------------------------------------------------------------------ fixture
# 32x32 so a scale-2 glyph fits with headroom; the digest is position-weighted
# so a shape drawn in the wrong PLACE is a different number, not just a
# different pixel count.
read -r -d '' HEAD <<'EOF' || true
ignore is gfx_open of [32, 32, "pixdiff"]
ignore is gfx_clear of [0, 0, 0]
EOF
read -r -d '' TAIL <<'EOF' || true
total is 0
lit is 0
for py in range of 32:
    for px in range of 32:
        c is gfx_read of [px, py]
        if c != null:
            total is total + (c[0] * 7 + c[1] * 13 + c[2] * 17) * (px + py * 32 + 1)
            if c[0] + c[1] + c[2] > 0:
                lit is lit + 1
print of f"digest={total} lit={lit}"
EOF

# --------------------------------------------------------------------- rows
# label|builtin|slot|program|zero-variant
#   slot   the argument index given the wrong type ('-' for a valid row)
#   zero   present => this row's default-path divergence is WAIVED, and this
#          is the program that proves it (see the header)
ROWS=$(cat <<'EOF'
valid-rect|gfx_rect|-|ignore is gfx_rect of [4, 4, 10, 10, 255, 0, 0]|
valid-rect-alpha|gfx_rect|-|ignore is gfx_rect of [4, 4, 10, 10, 255, 0, 0, 128]|
valid-rrect|gfx_rrect|-|ignore is gfx_rrect of [4, 4, 12, 12, 3, 0, 255, 0]|
valid-circle|gfx_circle|-|ignore is gfx_circle of [16, 16, 7, 0, 0, 255]|
valid-line|gfx_line|-|ignore is gfx_line of [0, 0, 30, 30, 255, 255, 0]|
valid-point|gfx_point|-|ignore is gfx_point of [5, 5, 255, 0, 255]|
valid-clear|gfx_clear|-|ignore is gfx_clear of [10, 20, 30]|
valid-clip|gfx_clip|-|ignore is gfx_clip of [2, 2, 8, 8]\nignore is gfx_rect of [0, 0, 32, 32, 255, 0, 0]|
valid-clip-null|gfx_clip|-|ignore is gfx_clip of null\nignore is gfx_rect of [0, 0, 8, 8, 255, 0, 0]|
valid-text|gfx_text|-|ignore is gfx_text of [0, 0, "H", 255, 255, 255]|
valid-text-scale|gfx_text|-|ignore is gfx_text of [0, 0, "H", 255, 255, 255, 2]|
valid-fb|gfx_fb|-|fb is buffer of 16\nignore is buf_fill of [fb, 0, 16, 0]\nignore is gfx_fb of [fb, 4, 4, 0, 0, 2]|
valid-read|gfx_read|-|ignore is gfx_rect of [0, 0, 4, 4, 200, 100, 50]\nprint of (gfx_read of [1, 1])|
valid-open-title|gfx_open|-|ignore is gfx_title of "pixdiff2"\nignore is gfx_rect of [1, 1, 3, 3, 9, 9, 9]|
wrong-rect-slot0|gfx_rect|0|ignore is gfx_rect of ["4", 4, 10, 10, 255, 0, 0]|ignore is gfx_rect of [0, 4, 10, 10, 255, 0, 0]
wrong-rect-slot7|gfx_rect|7|ignore is gfx_rect of [4, 4, 10, 10, 255, 0, 0, "128"]|
wrong-rrect-slot0|gfx_rrect|0|ignore is gfx_rrect of ["4", 4, 12, 12, 3, 0, 255, 0]|ignore is gfx_rrect of [0, 4, 12, 12, 3, 0, 255, 0]
wrong-rrect-slot8|gfx_rrect|8|ignore is gfx_rrect of [4, 4, 12, 12, 3, 0, 255, 0, "128"]|
wrong-circle-slot0|gfx_circle|0|ignore is gfx_circle of ["16", 16, 7, 0, 0, 255]|ignore is gfx_circle of [0, 16, 7, 0, 0, 255]
wrong-circle-slot6|gfx_circle|6|ignore is gfx_circle of [16, 16, 7, 0, 0, 255, "128"]|
wrong-line-slot0|gfx_line|0|ignore is gfx_line of ["0", 0, 30, 30, 255, 255, 0]|ignore is gfx_line of [0, 0, 30, 30, 255, 255, 0]
wrong-line-slot6|gfx_line|6|ignore is gfx_line of [0, 0, 30, 30, 255, 255, "0"]|ignore is gfx_line of [0, 0, 30, 30, 255, 255, 0]
wrong-point-slot0|gfx_point|0|ignore is gfx_point of ["5", 5, 255, 0, 255]|ignore is gfx_point of [0, 5, 255, 0, 255]
wrong-point-slot4|gfx_point|4|ignore is gfx_point of [5, 5, 255, 0, "255"]|ignore is gfx_point of [5, 5, 255, 0, 0]
wrong-clear-slot0|gfx_clear|0|ignore is gfx_clear of ["10", 20, 30]|ignore is gfx_clear of [0, 20, 30]
wrong-clear-slot2|gfx_clear|2|ignore is gfx_clear of [10, 20, "30"]|ignore is gfx_clear of [10, 20, 0]
wrong-clip-slot0|gfx_clip|0|ignore is gfx_clip of ["2", 2, 8, 8]\nignore is gfx_rect of [0, 0, 32, 32, 255, 0, 0]|ignore is gfx_clip of [0, 2, 8, 8]\nignore is gfx_rect of [0, 0, 32, 32, 255, 0, 0]
wrong-clip-slot3|gfx_clip|3|ignore is gfx_clip of [2, 2, 8, "8"]\nignore is gfx_rect of [0, 0, 32, 32, 255, 0, 0]|ignore is gfx_clip of [2, 2, 8, 0]\nignore is gfx_rect of [0, 0, 32, 32, 255, 0, 0]
wrong-text-slot0|gfx_text|0|ignore is gfx_text of ["0", 0, "H", 255, 255, 255]|ignore is gfx_text of [0, 0, "H", 255, 255, 255]
wrong-text-slot1|gfx_text|1|ignore is gfx_text of [0, "0", "H", 255, 255, 255]|ignore is gfx_text of [0, 0, "H", 255, 255, 255]
wrong-text-slot3|gfx_text|3|ignore is gfx_text of [0, 0, "H", "255", 255, 255]|ignore is gfx_text of [0, 0, "H", 0, 255, 255]
wrong-text-slot6|gfx_text|6|ignore is gfx_text of [0, 0, "H", 255, 255, 255, "2"]|ignore is gfx_text of [0, 0, "H", 255, 255, 255, 0]
wrong-read-slot0|gfx_read|0|ignore is gfx_rect of [0, 0, 4, 4, 200, 100, 50]\nprint of (gfx_read of ["1", 1])|ignore is gfx_rect of [0, 0, 4, 4, 200, 100, 50]\nprint of (gfx_read of [0, 1])
wrong-read-slot1|gfx_read|1|ignore is gfx_rect of [0, 0, 4, 4, 200, 100, 50]\nprint of (gfx_read of [1, "1"])|ignore is gfx_rect of [0, 0, 4, 4, 200, 100, 50]\nprint of (gfx_read of [1, 0])
wrong-fb-slot1|gfx_fb|1|fb is buffer of 16\nignore is buf_fill of [fb, 0, 16, 0]\nignore is gfx_fb of [fb, "4", 4, 0, 0, 2]|
wrong-fb-slot5|gfx_fb|5|fb is buffer of 16\nignore is buf_fill of [fb, 0, 16, 0]\nignore is gfx_fb of [fb, 4, 4, 0, 0, "2"]|
wrong-open-slot0|gfx_open|0|ignore is gfx_open of ["16", 16, "reopen"]\nignore is gfx_rect of [0, 0, 8, 8, 255, 0, 0]|
EOF
)

mkprog() { printf '%s\n' "$HEAD" > "$1"; printf '%b\n' "$2" >> "$1"; printf '%s\n' "$TAIL" >> "$1"; }
run()    { local bin="$1" strict="$2" f="$3" out rc
           if [ "$strict" = "1" ]; then out="$(EIGS_STRICT=1 "$bin" "$f" 2>&1)"; rc=$?
           else out="$("$bin" "$f" 2>&1)"; rc=$?; fi
           printf '%s\n%s' "$rc" "$out"; }

rc=0
n_row=0 n_valid=0 n_wrong=0 n_ident=0 n_differ=0 n_waived=0 n_raise=0 n_silent=0 n_misattr=0
differ_list="" silent_list="" waiver_list="" misattr_list="" vacuous_list=""
covered_names="" covered_slots=""

# The empty canvas, for the non-vacuity check below.
mkprog "$TMP/blank.eigs" "ignore is gfx_delay of 0"
blank="$(run "$NEW" - "$TMP/blank.eigs")"
blank_digest="${blank#*$'\n'}"

while IFS='|' read -r label who slot prog zero; do
    [ -z "${label:-}" ] && continue
    n_row=$((n_row + 1))
    covered_names="$covered_names $who"
    [ "$slot" != "-" ] && covered_slots="$covered_slots $who:$slot"
    mkprog "$TMP/p.eigs" "$prog"
    b="$(run "$NEW" - "$TMP/p.eigs")"

    if [ "$slot" = "-" ]; then
        n_valid=$((n_valid + 1))
        # A VALID row that draws nothing measures nothing. gfx_read's row
        # prints a colour instead of lighting pixels, so it is exempt by name.
        if [ "$NO_RENDERER" = 0 ] && [ "$who" != "gfx_read" ] && [ "${b#*$'\n'}" = "$blank_digest" ]; then
            vacuous_list="$vacuous_list
    $label — draws nothing: identical to the blank canvas ($blank_digest)"
        fi
        # Strict must leave a correct call completely alone.
        s="$(run "$NEW" 1 "$TMP/p.eigs")"
        if [ "$s" != "$b" ]; then
            differ_list="$differ_list
    $label [strict vs plain, same binary] — a guard rejects a LEGITIMATE call
      plain : $(printf '%s' "$b" | tr '\n' ' ' | cut -c1-80)
      strict: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-80)"
            rc=1
        fi
    else
        n_wrong=$((n_wrong + 1))
        s="$(run "$NEW" 1 "$TMP/p.eigs")"
        if [ "${s%%$'\n'*}" = "0" ]; then
            n_silent=$((n_silent + 1))
            silent_list="$silent_list
    $label — still silent under EIGS_STRICT=1: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
        elif grep -qF "$who: expected" <<<"$s"; then
            n_raise=$((n_raise + 1))
        else
            n_misattr=$((n_misattr + 1))
            misattr_list="$misattr_list
    $label — raised, but not by $who's own guard: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
        fi
    fi

    [ -z "$BASE" ] && continue

    a="$(run "$BASE" - "$TMP/p.eigs")"
    if [ "$a" = "$b" ]; then
        n_ident=$((n_ident + 1))
        # A waiver that no longer diverges is spent paperwork — the same
        # failure mode strict_differential.sh's SPENT WAIVER check exists for.
        if [ -n "${zero:-}" ]; then
            waiver_list="$waiver_list
    SPENT: $label carries a zero-variant waiver but does not diverge. Remove it."
            rc=1
        fi
        continue
    fi
    if [ -z "${zero:-}" ]; then
        n_differ=$((n_differ + 1))
        differ_list="$differ_list
    $label — the default path was NOT preserved, and no waiver claims it
      baseline: $(printf '%s' "$a" | tr '\n' ' ' | cut -c1-80)
      new     : $(printf '%s' "$b" | tr '\n' ' ' | cut -c1-80)"
        rc=1
        continue
    fi
    # ---- the waiver's proof, executed
    a2="$(run "$BASE" - "$TMP/p.eigs")"
    mkprog "$TMP/z.eigs" "$zero"
    z="$(run "$BASE" - "$TMP/z.eigs")"
    if [ "$a" != "$a2" ]; then
        waiver_list="$waiver_list
    UNPROVEN: $label — the baseline is not stable across two runs, so
              'the parent answered X' is not a statement about anything."
        rc=1
    elif [ "$a" != "$z" ]; then
        waiver_list="$waiver_list
    UNPROVEN: $label — the baseline's answer to the WRONG-TYPED argument is
              NOT its answer to 0, so this is not an unchecked union read.
              Treat it as a real behaviour change, not a pun.
      wrong-typed: $(printf '%s' "$a" | tr '\n' ' ' | cut -c1-70)
      literal 0  : $(printf '%s' "$z" | tr '\n' ' ' | cut -c1-70)"
        rc=1
    else
        # SECOND HALF: a proven-laundered baseline licenses REJECTING the call.
        # It licenses nothing else. Without this, a waiver would excuse any new
        # behaviour at all — including the "helpful" coercion that would make a
        # wrong-typed argument draw something DIFFERENT but still not what the
        # program asked for. So the new binary's canvas must equal the canvas of
        # the same program with the offending call DELETED (mechanically: the
        # first line naming this builtin). gfx_read draws nothing and is judged
        # on its documented rejection stand-in instead, named here rather than
        # implied.
        noeffect="$(printf '%b\n' "$prog" | awk -v w="$who of" 'index($0, w) && !done { done = 1; next } { print }')"
        mkprog "$TMP/n.eigs" "$noeffect"
        ne="$(run "$NEW" - "$TMP/n.eigs")"
        if [ "$who" = "gfx_read" ]; then
            if ! grep -q "null" <<<"$b"; then
                waiver_list="$waiver_list
    UNPROVEN: $label — the parent's answer was laundered, but the new answer is
              not gfx_read's documented rejection stand-in (null):
              $(printf '%s' "$b" | tr '\n' ' ' | cut -c1-70)"
                rc=1
                continue
            fi
        elif [ "$b" != "$ne" ]; then
            waiver_list="$waiver_list
    UNPROVEN: $label — the rejected call did not draw NOTHING. A waiver licenses
              rejecting the argument, never drawing something else instead.
      with the call   : $(printf '%s' "$b" | tr '\n' ' ' | cut -c1-70)
      call deleted    : $(printf '%s' "$ne" | tr '\n' ' ' | cut -c1-70)"
            rc=1
            continue
        fi
        n_waived=$((n_waived + 1))
        waiver_list="$waiver_list
    proven: $label — parent answered $(printf '%s' "$a" | tr '\n' ' ' | cut -c1-46)
            for the wrong-typed value AND for a literal 0 (an unchecked
            \`items[$slot]->data.num\` read: the drawing came from the
            reinterpreted pointer, not from the argument), and this build
            draws exactly what deleting the call draws"
    fi
done <<<"$ROWS"

# ------------------------------------------------- coverage, from the source
guarded_renderer="$(awk '
    /^Value\* builtin_/ { name = $0; sub(/.*builtin_/, "", name); sub(/\(.*/, "", name); has = 0; g = 0 }
    /g_renderer/        { if (name != "") has = 1 }
    /(ARG_GUARD|STRICT_REQUIRE)\(/ { if (name != "") g = 1 }
    /^}/                { if (name != "" && has && g) print name; name = "" }
' src/ext_gfx.c | sort -u)"
missing_names=""
for nm in $guarded_renderer; do
    case " $covered_names " in *" $nm "*) ;; *) missing_names="$missing_names $nm" ;; esac
done
missing_slots=""
while read -r nm a b; do
    [ -z "${nm:-}" ] && continue
    last=$((b - 1))
    for want in "$a" "$last"; do
        case " $covered_slots " in *" $nm:$want "*) ;; *) missing_slots="$missing_slots $nm:$want" ;; esac
    done
done < <(awk '
    /^Value\* builtin_/ { name = $0; sub(/.*builtin_/, "", name); sub(/\(.*/, "", name) }
    match($0, /gfx_nums\(arg, [0-9]+, [0-9]+\)/) {
        s = substr($0, RSTART, RLENGTH); gsub(/[^0-9 ]/, " ", s)
        n = split(s, f, " "); lo = ""; hi = ""
        for (i = 1; i <= n; i++) if (f[i] != "") { if (lo == "") lo = f[i]; else hi = f[i] }
        if (name != "" && lo != "" && hi != "") print name, lo, hi
    }
' src/ext_gfx.c | sort -u)

echo "== #1007 gfx pixel differential =="
echo "  rows=$n_row (valid=$n_valid wrong=$n_wrong)"
if [ -n "$BASE" ]; then
    echo "  identical-when-off: $n_ident   differing: $n_differ   waived (proven): $n_waived"
elif [ "$NO_RENDERER" = 1 ]; then
    echo "  identical-when-off: SKIPPED (no renderer — nothing to draw on either side)"
else
    echo "  identical-when-off: SKIPPED (--no-baseline)"
fi
echo "  raises-under-strict: $n_raise   silent: $n_silent   misattributed: $n_misattr"
[ "$NO_RENDERER" = 0 ] && echo "  blank canvas: $blank_digest"

[ -n "$waiver_list" ]  && echo "  WAIVERS:$waiver_list"
[ -n "$differ_list" ]  && { echo "  DIFFERING:$differ_list"; rc=1; }
[ -n "$silent_list" ]  && { echo "  SILENT UNDER STRICT:$silent_list"; rc=1; }
[ -n "$misattr_list" ] && { echo "  RAISED BY THE WRONG GUARD:$misattr_list"; rc=1; }
[ -n "$vacuous_list" ] && { echo "  VACUOUS ROW (a valid call that draws nothing proves nothing):$vacuous_list"; rc=1; }
[ -n "$missing_names" ] && {
    echo "  GUARDED, TOUCHES THE RENDERER, NO PIXEL ROW:"
    printf '    %s\n' $missing_names
    echo "    (population derived from src/ext_gfx.c, not from this file's rows)"
    rc=1; }
[ -n "$missing_slots" ] && {
    echo "  GUARDED SLOT WITH NO WRONG-TYPED ROW (first/last of a gfx_nums range):"
    printf '    %s\n' $missing_slots
    echo "    The LAST slot of a range is normally the OPTIONAL trailing argument"
    echo "    — the slot a hand-written probe table forgets, and the one that hid"
    echo "    gfx_text's wrong-typed scale from #1007's first pass."
    rc=1; }

[ "$rc" = 0 ] && echo "  OK" || echo "  FAIL"
exit $rc
