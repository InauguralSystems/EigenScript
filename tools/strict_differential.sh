#!/usr/bin/env bash
# #971 Phase B: the differential that backs the safety claim.
#
# The claim this change makes is narrow and total: converting a fail-soft
# guard to ARG_GUARD changes NOTHING when EIGS_STRICT is unset, and makes
# the same mistake LOUD when it is set. Both halves need an oracle, and
# the first half's oracle is the previous binary.
#
#   identical-when-off   baseline vs new, EIGS_STRICT unset, byte-for-byte
#                        over stdout+stderr+exit code
#   raises-under-strict  new binary, EIGS_STRICT=1, must exit nonzero and
#                        name the builtin
#   pins                 fs:ANSWER sites must NOT raise under strict — the
#                        half that stops the reform overshooting into the
#                        documented answers
#
# The probe table below is hand-written (a call needs the right arity, and
# `--api` does not carry arity), which makes it exactly the sibling list
# §1 of mechanical-gates warns about. So it is CROSS-CHECKED: the set of
# builtin names appearing in an ARG_GUARD is derived from the source, and
# any guarded builtin with no probe FAILS this script. Adding a guard
# without a probe goes red rather than passing quietly.
#
# Usage: bash tools/strict_differential.sh <baseline-binary>
#   <baseline-binary> is a build of the PARENT commit. Build one with:
#     git worktree add --detach /tmp/base <sha> && make -C /tmp/base
#   Without it, the identical-when-off half is skipped and the script says
#   so and exits 1 — a differential with no reference is not a pass.
#   --no-baseline accepts that deliberately (what CI runs).
#
# WHAT THIS DOES NOT COVER, stated so the next reader does not assume it:
#   - UNPROBEABLE is an escape hatch. A name added there leaves the
#     "guarded but unprobed" set with no proof of unreachability; the only
#     thing bounding it is the staleness check, which fires if the guard it
#     excuses disappears entirely. Adding a name is a review event.
#   - The probe table is hand-written. The cross-check makes an UNPROBED
#     guard fail, but it cannot make a BADLY CHOSEN probe fail beyond the
#     attribution check — and that check only proves the raise came from
#     the named guard, not that the probe exercises the interesting branch.
#   - --sweep is discovery, not a gate: it has no allowlist, so nothing
#     fails when a new laundering builtin appears. Making it a gate needs a
#     pinned expected-quiet list, which nobody has written.

set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

# EIGS_DIFF_NEW lets the harness be pointed at another build, which is how
# it is validated: run it with NEW := the BASELINE binary and both
# detectors must fire (the baseline lacks these guards, so probes go
# silent under strict; and the waived divergence vanishes, so the
# stale-waiver check speaks). A harness that has never failed has not been
# shown to work.
NEW="${EIGS_DIFF_NEW:-./src/eigenscript}"
BASE="${1:-}"

# --no-baseline runs every half EXCEPT identical-when-off, and passes on those.
# It exists so CI has something: without it this tool only ever runs on a dev
# box that happens to have built the parent commit, and a harness nobody runs
# rots. The half it drops is the one that needs two binaries; the halves it
# keeps (does every guard still raise, does it raise from its OWN guard, do the
# documented answers stay quiet, is every guard probed) catch a removed guard,
# a broken pin and an unprobed guard on their own.
NO_BASELINE=0
if [ "$BASE" = "--no-baseline" ]; then NO_BASELINE=1; BASE=""; fi

[ -x "$NEW" ] || { echo "FAIL: no built binary at $NEW"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- probes
# name|program
# Each program calls the builtin with a WRONG-TYPED argument at the right
# arity, so the guard under test is the one that fires. `who` is the name
# ARG_GUARD reports, which is what the cross-check below matches on.
PROBES=$(cat <<'EOF'
abs|print of (abs of "x")
acos|print of (acos of "x")
asin|print of (asin of "x")
atan|print of (atan of "x")
atan2|print of (atan2 of ["y", 1])
buf_len|print of (buf_len of "x")
ceil|print of (ceil of "x")
chdir|print of (chdir of 42)
char_at|print of (char_at of [42, 0])
contains|print of (contains of [[1, 2, 3], 2])
cos|print of (cos of "hello")
dot|print of (dot of [1, 2])
ends_with|print of (ends_with of [42, "x"])
f64_from_bytes|print of (f64_from_bytes of "x")
floor|print of (floor of "x")
has_key|print of (has_key of [42, "k"])
join|print of (join of [42, ","])
json_path|print of (json_path of 42)
list_contains|print of (list_contains of [42, 1])
max|print of (max of [1, "x", 3])
path_base|print of (path_base of 42)
path_dir|print of (path_dir of 42)
path_ext|print of (path_ext of 42)
path_join|print of (path_join of [42, "b"])
remove_file|print of (remove_file of 42)
rm|print of (rm of 42)
round|print of (round of "x")
secure_equals|print of (secure_equals of [42, "x"])
seed_random|print of (seed_random of "x")
sign_extend|print of (sign_extend of ["x", 8])
sin|print of (sin of "x")
sqrt/exp/log/negative|print of (sqrt of "x")
starts_with|print of (starts_with of [42, "x"])
store_delete|print of (store_delete of [42, "col", "k"])
str_from_bytes|print of (str_from_bytes of 42)
str_lower|print of (str_lower of 42)
str_replace|print of (str_replace of [42, "a", "b"])
str_upper|print of (str_upper of 42)
stream_write|print of (stream_write of "x")
substr|print of (substr of [42, 0, 1])
tan|print of (tan of "x")
task_alive|print of (task_alive of "x")
task_kill|print of (task_kill of "x")
task_send|print of (task_send of ["x", 1])
tensor_save|print of (tensor_save of 42)
text_builder_part_count|print of (text_builder_part_count of 42)
text_builder_to_string|print of (text_builder_to_string of 42)
trim|print of (trim of 42)
try_parse|print of (try_parse of 42)
write_bytes|print of (write_bytes of 42)
zeros_like|print of (zeros_like of "x")
sum|print of (sum of "hello")
mean|print of (mean of "hello")
norm|print of (norm of "hello")
join|print of (join of [["a", "b"], 42])
rename|print of (rename of [42, "b"])
store_count|print of (store_count of [42, "col"])
store_drop|print of (store_drop of [42, "col"])
store_update|print of (store_update of [42, "col", "k", {"a": 1}])
store_update|print of (store_update of [(store_open of "@TMP@/probe.db"), "col", ([1, 2]), {"a": 1}])
stream_open|print of (stream_open of [42, 1])
write_text|print of (write_text of [42, "x"])
add/subtract/multiply/divide/pow|print of (add of ["x", 1])
EOF
)
# A probe that needs a real resource must build it under this run's own $TMP,
# which the EXIT trap removes. The heredoc above is quoted (so a program can
# contain a literal $ safely), hence the placeholder rather than direct
# expansion. Bought by the store_update key probe: pointed at a fixed
# /tmp path it left a database behind, and a leftover unreadable file there
# wedged the gate for every later run — `store_open` refused it, the probe
# raised from the wrong place, and the tool reported `misattributed: 1`
# forever with nothing to do with the code under test.
PROBES="${PROBES//@TMP@/$TMP}"

# fs:ANSWER pins — a 0/"" that is the documented RESULT. Strict must leave
# these alone. Without this half the reform has no failure mode: converting
# everything would score a perfect "raises-under-strict".
PINS=$(cat <<'EOF'
task_alive of an unknown id is 0, not an error|print of (task_alive of 999)
list_contains that finds nothing is 0|print of (list_contains of [[1, 2], 9])
ends_with with a suffix longer than the string is 0|print of (ends_with of ["ab", "abc"])
char_at past the end is ""|print of (char_at of ["ab", 9])
substr starting past the end is ""|print of (substr of ["ab", 9, 1])
join of an empty list is ""|print of (join of [[], ","])
num coerces a list to 0 (documented)|print of (num of ([1, 2]))
try_parse of invalid syntax is 0|print of (try_parse of "!!!")
max of an empty list is 0|print of (max of ([]))
sum of an empty list is 0 (the identity, not a type mistake)|print of (sum of ([]))
mean of an empty list is 0|print of (mean of ([]))
norm of a real vector still computes|print of (norm of [3, 4])
sum of a bare number is that number|print of (sum of 7)
join with a real separator still joins|print of (join of [["a", "b"], "-"])
json false decodes to 0|print of (json_path of ["{\"a\": false}", "a"])
EOF
)

# VALID-input rows. Every probe above hands a builtin a WRONG argument, so the
# whole harness was structurally blind to a regression on CORRECT input: a
# guard whose condition is too broad, a split that reordered a real branch, an
# off-by-one in a hoisted check would all pass every row above. These run the
# same program on BOTH binaries in BOTH modes and require byte-identical
# output — including under strict, which is where an over-broad guard shows up
# as a raise on a legitimate call. Found missing by a blind review.
VALID=$(cat <<'EOF'
print of (sum of [1, 2, 3.5])
print of (mean of [2, 4, 6])
print of (norm of [3, 4])
print of (sum of 7)
print of (max of [1, 5, 3])
print of (min of [1, 5, 3])
print of (max of 9)
print of (contains of ["hello", "ell"])
print of (starts_with of ["hello", "he"])
print of (ends_with of ["hello", "lo"])
print of (char_at of ["hello", 1])
print of (char_at of ["hello", 0 - 1])
print of (substr of ["hello", 1, 3])
print of (join of [["a", "b", "c"], "-"])
print of (join of [[], ","])
print of (has_key of [{"k": 1}, "k"])
print of (path_join of ["a", "b"])
print of (atan2 of [1, 1])
print of (list_contains of [[1, 2, 3], 2])
print of (str_replace of ["banana", "an", "X"])
print of (add of [[1, 2], [3, 4]])
print of (sqrt of [4, 9])
print of (sign_extend of [255, 8])
print of (seed_random of 42)
print of (try_parse of "x is 1")
print of (num of "42")
print of (num of "0x1f")
print of (json_path of ["{\"a\": {\"b\": 7}}", "a.b"])
print of (task_alive of 1)
print of (str_upper of "abc")
print of (cos of 0)
print of (len of [1, 2, 3])
EOF
)

# The ONE probe whose default-path result legitimately changes, with the
# reason, pinned by name (a waiver must be visible and bounded — an
# unnamed tolerance would absorb every future regression too).
#
#   sign_extend: both operands were read as `.data.num` with no VAL_NUM
#   check, so `sign_extend of ["x", 8]` reinterpreted a `char *` as a
#   `double`. The baseline prints a pointer-derived denormal
#   (4.70323982918157e-310 on this box, and a DIFFERENT value on any run
#   with ASLR). There is no previous behaviour to preserve: it was
#   undefined, and its output was not even stable across runs. Filed
#   separately; the guard makes it 0 like every sibling.
EXPECTED_DIVERGE="sign_extend"

# Guards that CANNOT be probed, named with the reason. Without this list they
# would sit in "GUARDED BUT UNPROBED" forever and train the reader to ignore
# that section — which is how a real gap gets missed.
#
#   (currently empty)
#
#   store_update was waived here until #1006. The waiver's reason was that its
#   key-type guard was unreachable — store_update called store_delete first
#   with the same [handle, collection, key] triple, so a bad key was rejected
#   there and the raise named store_delete. #1006 removed that delegation (the
#   delete had to be split so a failed replace could be undone), which made
#   both of store_update's guards reachable and self-naming. The waiver named
#   its own trigger — "if it is ever made reachable it must gain a probe here"
#   — and this is that: two probes below, no waiver.
UNPROBEABLE=""

run_capture() {   # <binary> <env-strict|-> <file>  -> prints "rc\nstdout+stderr"
    local bin="$1" strict="$2" f="$3" out rc
    if [ "$strict" = "-" ]; then
        out="$("$bin" "$f" 2>&1)"; rc=$?
    else
        out="$(EIGS_STRICT="$strict" "$bin" "$f" 2>&1)"; rc=$?
    fi
    printf '%s\n%s' "$rc" "$out"
}

# rc is initialised ONCE, here, before any check can run. It used to be
# assigned rc=0 down in the summary block — AFTER the cross-check section had
# already set rc=1 — so a STALE UNPROBEABLE WAIVER finding printed and the
# script still exited 0. A check that fires and returns success is the exact
# false green this repo keeps a hook for, and it was living in the tool built
# to prevent them. Do not reset rc anywhere below.
rc=0
n_probe=0 n_ident=0 n_differ=0 n_raise=0 n_silent=0 n_waived=0
waived_seen=""
n_pin=0 n_pin_ok=0 n_pin_broke=0 n_misattr=0
differ_list="" silent_list="" pin_list="" misattr_list=""

while IFS='|' read -r who prog; do
    [ -z "${who:-}" ] && continue
    n_probe=$((n_probe + 1))
    f="$TMP/p.eigs"; printf '%b\n' "$prog" > "$f"

    if [ -n "$BASE" ]; then
        a="$(run_capture "$BASE" - "$f")"
        b="$(run_capture "$NEW" - "$f")"
        if [ "$a" = "$b" ]; then
            n_ident=$((n_ident + 1))
        else
            # A waived divergence still gets its strict half measured
            # below — waiving the default-path comparison must not quietly
            # drop the probe from the loudness count too.
            if printf '%s\n' "$EXPECTED_DIVERGE" | grep -qxF "$who"; then
                n_waived=$((n_waived + 1))
                waived_seen="$waived_seen $who"
            else
                n_differ=$((n_differ + 1))
                differ_list="$differ_list
    $who
      baseline: $(printf '%s' "$a" | tr '\n' ' ' | cut -c1-90)
      new     : $(printf '%s' "$b" | tr '\n' ' ' | cut -c1-90)"
            fi
        fi
    fi

    s="$(run_capture "$NEW" 1 "$f")"
    s_rc="${s%%$'\n'*}"
    if [ "$s_rc" != "0" ]; then
        # A nonzero exit is NOT enough. A probe that raises somewhere else
        # entirely — an arity error before the type guard, an unconditional
        # rt_error higher up — scores as coverage while testing nothing. So
        # the message must NAME this guard: the builtin, and the word the
        # ARG_GUARD macro emits. (For the shared tensor helpers, `who` is a
        # slash-joined set like "sqrt/exp/log/negative", so the first
        # component is matched.)
        # Match "<name>: expected", the exact shape ARG_GUARD emits. Bare
        # `grep -F "$name"` was VACUOUS: the runtime echoes the offending
        # source line under the error, and that line always contains the
        # builtin being called — so a probe rewritten to call something else
        # entirely still matched. Demonstrated by a blind review: probe `abs`
        # rewritten as `cos of "abs"` scored as coverage.
        # The FULL who, not its first component: the shared tensor helpers
        # are registered as "sqrt/exp/log/negative" and emit that verbatim,
        # so trimming at the slash made the matcher miss its own message.
        if printf '%s' "$s" | grep -qF "$who: expected"; then
            n_raise=$((n_raise + 1))
        else
            n_misattr=$((n_misattr + 1))
            misattr_list="$misattr_list
    $who — raised, but not by its own guard: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
        fi
    else
        n_silent=$((n_silent + 1))
        silent_list="$silent_list
    $who — still silent under EIGS_STRICT=1: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
    fi
done <<<"$PROBES"

while IFS='|' read -r label prog; do
    [ -z "${label:-}" ] && continue
    n_pin=$((n_pin + 1))
    f="$TMP/pin.eigs"; printf '%s\n' "$prog" > "$f"
    s="$(run_capture "$NEW" 1 "$f")"
    if [ "${s%%$'\n'*}" = "0" ]; then
        n_pin_ok=$((n_pin_ok + 1))
    else
        n_pin_broke=$((n_pin_broke + 1))
        pin_list="$pin_list
    $label — strict RAISED on a documented answer: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
    fi
done <<<"$PINS"

# ------------------------------------------------------------------- sweep
# A DISCOVERY instrument, not a gate — and it exists because of a structural
# hole a blind review found in the cross-check below.
#
# That cross-check derives its expected probe set from the names appearing in
# an `ARG_GUARD(` call. So it can only ever measure builtins that were ALREADY
# converted: a builtin that launders a wrong-typed argument and was never
# touched is invisible to it BY CONSTRUCTION. That is the sibling-list disease
# one level up — the check shares the very assumption that is drifting.
#
# It cost real coverage. `sum of "hello"` was 0 under strict while
# `sqrt of "hello"` raised — same file, same commit — and nothing here could
# say so, because `sum` had no guard and therefore no probe.
#
# This sweep asks the opposite question: hand EVERY builtin a wrong-typed
# argument and list the ones that answer QUIETLY under strict. Its output is a
# list for a human to read, not a pass/fail — most entries are legitimate
# (a builtin that genuinely takes a string, a documented coercion). It is the
# instrument that finds candidates; classification still happens by reading.
#
# Side-effecting and blocking builtins are skipped by name, listed here so the
# exclusion is visible rather than implied.
if [ "${1:-}" = "--sweep" ] || [ "${2:-}" = "--sweep" ]; then
    SKIP='^(exit|throw|usleep|sleep|task_sleep|screen_end|screen_clear|screen_render|input|read_line|raw_key|http_serve|serve|listen|gfx_.*|audio_.*|spawn|task_spawn|task_yield|task_recv|proc_.*|exec|system|rm|rmdir|remove_file|rename|chdir|mkdir|write.*|store_.*|db_.*|stream_.*|tensor_save|flush|assert)$'
    echo "== wrong-typed-argument sweep (discovery, not a gate) =="
    quiet=0; loud=0; skipped=0
    for b in $("$NEW" --api --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(d.get("builtins",[])))'); do
        if printf '%s' "$b" | grep -qE "$SKIP"; then skipped=$((skipped+1)); continue; fi
        # A DICT is the probe value: it is a wrong argument for very nearly
        # every builtin in the surface, where a string is the RIGHT argument
        # for dozens (sha256, read_text, file_exists...) and those all read as
        # false "quiet" rows. Picking the probe type is most of this
        # instrument's precision.
        printf 'print of (%s of ({"eigs_sweep_probe": 1}))\n' "$b" > "$TMP/sw.eigs"
        out="$(EIGS_STRICT=1 timeout 5 "$NEW" "$TMP/sw.eigs" 2>&1)"; src=$?
        if [ "$src" = "0" ]; then
            quiet=$((quiet+1))
            printf '  QUIET  %-24s -> %s\n' "$b" "$(printf '%s' "$out" | head -1 | cut -c1-40)"
        else
            loud=$((loud+1))
        fi
    done
    echo "  quiet=$quiet loud=$loud skipped=$skipped (skipped = side-effecting/blocking, see SKIP above)"
    echo "  A QUIET row is a CANDIDATE, not a defect: read the function before acting."
    exit 0
fi

# --------------------------------------------------- valid-input differential
n_valid=0 n_valid_same=0 valid_list=""
if [ -n "$BASE" ]; then
    while IFS= read -r prog; do
        [ -z "$prog" ] && continue
        n_valid=$((n_valid + 1))
        printf '%b\n' "$prog" > "$TMP/v.eigs"
        for mode in - 1; do
            a="$(run_capture "$BASE" "$mode" "$TMP/v.eigs")"
            b="$(run_capture "$NEW"  "$mode" "$TMP/v.eigs")"
            if [ "$a" != "$b" ]; then
                valid_list="$valid_list
    [strict=${mode}] $prog
      baseline: $(printf '%s' "$a" | tr '\n' ' ' | cut -c1-80)
      new     : $(printf '%s' "$b" | tr '\n' ' ' | cut -c1-80)"
            fi
        done
        [ -z "$valid_list" ] && n_valid_same=$((n_valid_same + 1))
    done <<<"$VALID"
fi

# ------------------------------------------------ cross-check the probe list
# The guarded-name set is DERIVED from the source. A guard whose builtin has
# no probe is unmeasured, and an unmeasured guard is indistinguishable from
# one that does not fire.
# The name extractor JOINS continuation lines. Its first version read one
# physical line, so a guard wrapped across two — condition on the first line,
# strings on the second, which is how the long ones are formatted — yielded no
# name at all and vanished from the expected-probe set. That is precisely the
# "guarded but unprobed" hole this cross-check exists to detect, living inside
# the cross-check. Caught when three freshly added guards reported as STALE
# PROBES rather than as newly covered ones.
guarded="$(awk '
    /ARG_GUARD\(/ { acc = ""; collecting = 1 }
    collecting { acc = acc $0; if (acc ~ /\);[ \t]*$/ || $0 ~ /\);/) {
        collecting = 0
        n = split(acc, parts, "\"")
        if (n >= 2) print parts[2]
    } }
' src/*.c | sed '/^$/d' | sort -u)"
probed="$(printf '%s\n' "$PROBES" | cut -d'|' -f1 | sed '/^$/d' | sort -u)"
missing="$(comm -23 <(printf '%s\n' "$guarded") <(printf '%s\n' "$probed") | grep -vxF -f <(printf '%s\n' $UNPROBEABLE) || true)"
stale="$(comm -13 <(printf '%s\n' "$guarded") <(printf '%s\n' "$probed"))"
# A waived-as-unprobeable name that is no longer guarded at all is a stale
# waiver: the guard it excused is gone.
for u in $UNPROBEABLE; do
    printf '%s\n' "$guarded" | grep -qxF "$u" || {
        echo "  STALE UNPROBEABLE WAIVER: $u is waived but carries no guard"; rc=1; }
done

echo "== #971 strict differential =="
echo "  probes=$n_probe pins=$n_pin"
if [ -n "$BASE" ]; then
    echo "  identical-when-off: $n_ident   differing: $n_differ   waived: $n_waived"
else
    echo "  identical-when-off: SKIPPED (no baseline binary given)"
fi
echo "  raises-under-strict: $n_raise   silent: $n_silent   misattributed: $n_misattr"
echo "  answer-pins held: $n_pin_ok   broken: $n_pin_broke"
if [ -n "$BASE" ]; then
    echo "  valid-input rows unchanged in BOTH modes: $((n_valid * 2 - $(printf '%s' "$valid_list" | grep -c '\[strict=' || true))) / $((n_valid * 2))"
fi

# NOTE: rc is NOT reset here. It is initialised once above, because the
# cross-check section runs BEFORE this block and can already have set it.
[ -n "$differ_list" ] && { echo "  DIFFERING (the default path was NOT preserved):$differ_list"; rc=1; }
[ -n "$silent_list" ] && { echo "  SILENT UNDER STRICT:$silent_list"; rc=1; }
[ -n "$misattr_list" ] && { echo "  RAISED BY THE WRONG GUARD (probe does not reach its target):$misattr_list"; rc=1; }
[ -n "$valid_list" ]  && { echo "  VALID INPUT CHANGED (a guard is too broad, or a split reordered a real branch):$valid_list"; rc=1; }
[ -n "$pin_list" ]    && { echo "  PIN BROKEN (the reform overshot into a documented answer):$pin_list"; rc=1; }
[ -n "$missing" ]     && { echo "  GUARDED BUT UNPROBED:"; printf '    %s\n' $missing; rc=1; }
[ -n "$stale" ]       && { echo "  PROBED BUT NO LONGER GUARDED (stale probe):"; printf '    %s\n' $stale; rc=1; }

# The waiver is ASSERTED, not asserted-about. sign_extend's justification is
# "the baseline behaviour was undefined, and not even stable across runs", so
# the harness proves that half rather than asking to be believed: run the
# BASELINE twice on the same probe and require the two results to differ. If
# they ever stop differing, the UB claim is wrong and the waiver must be
# re-argued. (This probe is therefore deliberately kept OUT of the identity
# comparison — a nondeterministic fixture does not belong in a differential
# as an ordinary row.)
if [ -n "$BASE" ]; then
    for w in $EXPECTED_DIVERGE; do
        wprog="$(printf '%s\n' "$PROBES" | grep -F "$w|" | head -1 | cut -d'|' -f2-)"
        if [ -n "$wprog" ]; then
            printf '%b\n' "$wprog" > "$TMP/w.eigs"
            r1="$(run_capture "$BASE" - "$TMP/w.eigs")"
            r2="$(run_capture "$BASE" - "$TMP/w.eigs")"
            if [ "$r1" = "$r2" ]; then
                echo "  WAIVER UNPROVEN: $w — two baseline runs agreed"
                echo "                   ($(printf '%s' "$r1" | tr '\n' ' ')),"
                echo "                   so the 'undefined, unstable' justification"
                echo "                   for waiving it does not hold. Re-argue it."
                rc=1
            else
                echo "  waiver proven: $w baseline is run-to-run unstable"
                echo "    run 1: $(printf '%s' "$r1" | tr '\n' ' ' | cut -c1-60)"
                echo "    run 2: $(printf '%s' "$r2" | tr '\n' ' ' | cut -c1-60)"
            fi
        fi
    done
fi

# An exemption that no longer fires must FAIL, not pass quietly: it means
# the thing it waived changed shape, which is exactly when a stale waiver
# starts covering something nobody agreed to.
if [ -n "$BASE" ]; then
    for w in $EXPECTED_DIVERGE; do
        if ! printf '%s' "$waived_seen" | grep -qw "$w"; then
            echo "  NOTE: $w did not differ on this run. For a waiver proven"
            echo "        run-to-run unstable above, that is a coin landing the"
            echo "        same way twice, not a stale waiver — the instability"
            echo "        assertion is the binding check."
        fi
    done
fi

# Vacuity: this script cannot be green having measured nothing.
if [ "$n_probe" -lt 55 ] || [ "$n_pin" -lt 14 ] || { [ -n "$BASE" ] && [ "$n_valid" -lt 25 ]; }; then
    echo "  VACUOUS: probes=$n_probe pins=$n_pin valid=$n_valid — below a floor; the tables"
    echo "           or the reader broke."
    rc=1
fi
if [ -z "$BASE" ] && [ "$NO_BASELINE" = 0 ]; then
    echo "  INCOMPLETE: no baseline binary, so the load-bearing half of this"
    echo "              differential did not run. Not a pass. (Pass"
    echo "              --no-baseline to accept that deliberately.)"
    rc=1
fi
if [ "$NO_BASELINE" = 1 ]; then
    echo "  NOTE: identical-when-off was NOT measured (no baseline binary)."
    echo "        Before landing a change to any guard, run this with a build"
    echo "        of the parent commit — that half is the safety claim."
fi

[ "$rc" = 0 ] && echo "OK" || echo "FAIL"
exit $rc
