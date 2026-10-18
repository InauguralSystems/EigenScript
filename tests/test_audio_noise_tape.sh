#!/bin/bash
# audio_noise on the trace tape (#1803).
#
# audio_noise drew its samples from libc rand(), which main seeds with
# srand(time(NULL)), and wrote no N record. A run recorded under EIGS_TRACE and
# replayed under EIGS_REPLAY drew new samples at rc 0, and seed_random could not
# pin them. It now draws from the shared drand48 stream behind `random` and
# records its samples as `N audio_noise=[...]` records of at most 2048 samples
# each; the first record shorter than a full chunk ends the call.
#
# time(NULL) has one-second resolution, so a clock-seeded rand() replayed in the
# same second as its recording repeats itself by accident (measured: a 4410-
# sample record/replay pair run back to back passed on the unfixed builtin).
# So every recording runs in the first of three phases one second apart, and
# every run it is compared with runs in a later phase.
#
#   AN01 record, then replay twice across one-second boundaries: all three
#        transcripts are byte-identical
#   AN02 that tape holds exactly one audio_noise record
#   AN03 replay serves the tape: a hand-edited first sample comes back
#   AN04 a call longer than one record (4410 samples, lib/audio.eigs's snare),
#        an exact multiple of the record size (4096) and an empty call replay
#        byte-identically on both tiers, with EIGS_REPLAY_STRICT=1 on the second
#        replay, and a `random` call between them stays aligned
#   AN05 that tape's record sizes are exactly 2048 2048 314 / 2048 2048 0 / 0 / 8
#   AN06 seed_random pins audio_noise across processes
#   AN07 a different seed moves it (AN06 is not vacuous)
#   AN08 after the same seed, sample i is ((random * 2) - 1) * amplitude for the
#        i-th draw: the same stream as `random`, and the uniform [-amp, amp)
#        formula
#   AN09 a rejected argument consumes no record (#1007): capture == replay
#   AN10 a refused duration (#1767, over 30 s) raises and consumes no record, so
#        its replay refuses it again and the next call keeps its own records:
#        capture == replay
#
# Run directly or from run_all_tests.sh ([138]). Prints
#   AUDIO_NOISE_TAPE: N passed, M failed
# and exits 0 only when every check passes.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS:-$TESTS_DIR/../src/eigenscript}"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: no eigenscript binary at $EIGS"
    echo "AUDIO_NOISE_TAPE: 0 passed, 1 failed"
    exit 1
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/eigs_audio_noise_tape.XXXXXX") || {
    echo "  FAIL: mktemp -d"; echo "AUDIO_NOISE_TAPE: 0 passed, 1 failed"; exit 1; }
trap 'rm -rf "$W"' EXIT

# macOS runners ship no coreutils timeout; unbounded is a hang, not a verdict.
TMO=""
if command -v timeout >/dev/null 2>&1; then TMO="timeout 120"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 120"; fi
# audio_noise opens no device. The dummy drivers keep any SDL use a change
# might add away from real hardware.
export SDL_AUDIODRIVER=dummy SDL_VIDEODRIVER=dummy

# eig OUT PROGRAM [VAR=value ...]: stdout+stderr to OUT, then `rc=N`, so every
# comparison below covers the exit status too. ${@+"$@"}: bash 3.2 calls an
# empty "$@" unbound under set -u.
eig() {
    local out="$1" prog="$2"; shift 2
    env ${@+"$@"} $TMO "$EIGS" "$prog" > "$out" 2>&1 < /dev/null
    echo "rc=$?" >> "$out"
}
# first_line FILE: the printed sample list (line 1 of a transcript)
first_line() { sed -n '1p' "$1"; }
# n_items "[a, b, c]" -> 3; "[]" -> 0
n_items() { LIST="$1" awk 'BEGIN { s = ENVIRON["LIST"]; if (s == "[]") { print 0; exit }
                                   print gsub(/, /, "", s) + 1 }'; }
# one_line FILE: a transcript on one line, for a FAIL message
one_line() { tr '\n' ' ' < "$1" | cut -c1-300; }

# ---- the programs ----------------------------------------------------------------
printf 'n is audio_noise of [0.0002, 0.5]\nprint of n\n' > "$W/noise.eigs"
cat > "$W/multi.eigs" <<'EIGS'
a is audio_noise of [0.1, 0.5]
b is audio_noise of [0.09288, 0.25]
c is audio_noise of [0, 0.5]
r is random of null
d is audio_noise of [0.0002, 1.0]
print of [len of a, len of b, len of c, len of d]
print of a
print of b
print of c
print of r
print of d
EIGS
cat > "$W/reject.eigs" <<'EIGS'
try:
    x is audio_noise of ["0.01", 0.5]
catch e:
    print of "rejected"
print of (audio_noise of [0.0002, 0.5])
EIGS
cat > "$W/refuse.eigs" <<'EIGS'
try:
    x is audio_noise of [31, 0.5]
catch e:
    print of "refused"
print of (audio_noise of [0.0002, 0.5])
EIGS
printf 'seed_random of 42\nprint of (audio_noise of [0.0002, 0.5])\n' > "$W/seed42.eigs"
printf 'seed_random of 43\nprint of (audio_noise of [0.0002, 0.5])\n' > "$W/seed43.eigs"
cat > "$W/stream.eigs" <<'EIGS'
seed_random of 7
noise is audio_noise of [0.0002, 0.5]
seed_random of 7
expect is [((random of null) * 2.0 - 1.0) * 0.5 for v in noise]
print of noise
print of expect
EIGS

# ---- three phases, one second apart --------------------------------------------
eig "$W/rec"  "$W/noise.eigs"  EIGS_TRACE="$W/noise.tape"
eig "$W/mrec" "$W/multi.eigs"  EIGS_TRACE="$W/multi.tape"
eig "$W/jrec" "$W/reject.eigs" EIGS_TRACE="$W/reject.tape"
eig "$W/frec" "$W/refuse.eigs" EIGS_TRACE="$W/refuse.tape"
eig "$W/s42a" "$W/seed42.eigs"
sleep 1
eig "$W/rep1"  "$W/noise.eigs"  EIGS_REPLAY="$W/noise.tape"
eig "$W/mrep1" "$W/multi.eigs"  EIGS_REPLAY="$W/multi.tape"
eig "$W/jrep"  "$W/reject.eigs" EIGS_REPLAY="$W/reject.tape"
eig "$W/frep"  "$W/refuse.eigs" EIGS_REPLAY="$W/refuse.tape"
sleep 1
eig "$W/rep2"  "$W/noise.eigs"  EIGS_REPLAY="$W/noise.tape"
eig "$W/mrep2" "$W/multi.eigs"  EIGS_REPLAY="$W/multi.tape" EIGS_JIT_OFF=1 EIGS_REPLAY_STRICT=1
eig "$W/s42b" "$W/seed42.eigs"
eig "$W/s43"  "$W/seed43.eigs"
eig "$W/stream" "$W/stream.eigs"
sed 's/^\(N [0-9][0-9]* audio_noise=\[\)[^,]*/\10.25/' "$W/noise.tape" > "$W/edited.tape"
eig "$W/rep_ed" "$W/noise.eigs" EIGS_REPLAY="$W/edited.tape"

# ---- the issue's program ----------------------------------------------------------
REC=$(first_line "$W/rec")
if [ "$(tail -n 1 "$W/rec")" = "rc=0" ] && [ "$(n_items "$REC")" = 8 ] &&
   cmp -s "$W/rec" "$W/rep1" && cmp -s "$W/rec" "$W/rep2"; then
    ok "AN01 record, replay, replay (one second apart): byte-identical, 8 samples"
else
    fail "AN01 replay does not reproduce the recording" \
         "rec='$(one_line "$W/rec")' rep1='$(one_line "$W/rep1")' rep2='$(one_line "$W/rep2")'"
fi

N_REC=$(grep -c '^N [0-9][0-9]* audio_noise=' "$W/noise.tape")
if [ "$N_REC" = 1 ]; then
    ok "AN02 the tape holds exactly one audio_noise record"
else
    fail "AN02 audio_noise records on the tape" "got $N_REC, want 1"
fi

ED=$(first_line "$W/rep_ed")
if ! cmp -s "$W/noise.tape" "$W/edited.tape" && [ "${ED%%,*}" = "[0.25" ] &&
   [ "${ED#*,}" = "${REC#*,}" ] && [ "$(tail -n 1 "$W/rep_ed")" = "rc=0" ]; then
    ok "AN03 replay serves the tape: a hand-edited first sample comes back"
else
    fail "AN03 replay does not read the samples off the tape" "recorded='$REC' replayed='$ED'"
fi

# ---- longer than one record -----------------------------------------------------
if [ "$(first_line "$W/mrec")" = "[4410, 4096, 0, 8]" ] && [ "$(tail -n 1 "$W/mrec")" = "rc=0" ] &&
   cmp -s "$W/mrec" "$W/mrep1" && cmp -s "$W/mrec" "$W/mrep2"; then
    ok "AN04 4410, 4096 and 0 samples replay byte-identically, both tiers, strict; random stays aligned"
else
    fail "AN04 a multi-record call does not replay" \
         "rec='$(first_line "$W/mrec") $(tail -n 1 "$W/mrec")' rep1='$(one_line "$W/mrep1")' rep2='$(one_line "$W/mrep2")'"
fi

SIZES=$(awk '/^N [0-9][0-9]* audio_noise=/ {
                 v = $0; sub(/^[^=]*=/, "", v)
                 n = (v == "[]") ? 0 : gsub(/, /, "", v) + 1
                 printf "%s%d", sep, n; sep = " "
             }
             END { print "" }' "$W/multi.tape")
if [ "$SIZES" = "2048 2048 314 2048 2048 0 0 8" ] && ! grep -q 'truncated' "$W/multi.tape"; then
    ok "AN05 record sizes 2048 2048 314 / 2048 2048 0 / 0 / 8, none truncated"
else
    fail "AN05 the samples are not chunked as recorded" \
         "sizes='$SIZES' truncated=$(grep -c 'truncated' "$W/multi.tape")"
fi

# ---- the shared stream ----------------------------------------------------------
S42=$(first_line "$W/s42a")
if [ "$(n_items "$S42")" = 8 ] && cmp -s "$W/s42a" "$W/s42b"; then
    ok "AN06 seed_random pins audio_noise across processes"
else
    fail "AN06 seed_random does not pin audio_noise" "first='$S42' second='$(first_line "$W/s42b")'"
fi
if [ "$(n_items "$S42")" = 8 ] && [ "$(first_line "$W/s43")" != "$(first_line "$W/s42b")" ]; then
    ok "AN07 a different seed moves audio_noise (AN06 is not vacuous)"
else
    fail "AN07 audio_noise ignores the seed" "seed 42='$(first_line "$W/s42b")' seed 43='$(first_line "$W/s43")'"
fi

NOISE=$(sed -n '1p' "$W/stream"); EXPECT=$(sed -n '2p' "$W/stream")
if [ "$(n_items "$NOISE")" = 8 ] && [ "$NOISE" = "$EXPECT" ] && [ "$(tail -n 1 "$W/stream")" = "rc=0" ]; then
    ok "AN08 after the same seed, the samples are ((random * 2) - 1) * amp draw for draw"
else
    fail "AN08 audio_noise does not draw from random's stream" "noise='$NOISE' expect='$EXPECT'"
fi

# ---- a rejected argument consumes no record (#1007) ------------------------------
N_REJ=$(grep -c '^N [0-9][0-9]* audio_noise=' "$W/reject.tape")
if [ "$(first_line "$W/jrec")" = "rejected" ] && [ "$N_REJ" = 1 ] && cmp -s "$W/jrec" "$W/jrep"; then
    ok "AN09 a rejected argument raises, consumes no record; capture == replay"
else
    fail "AN09 a rejected argument moved the tape" \
         "records=$N_REJ rec='$(one_line "$W/jrec")' rep='$(one_line "$W/jrep")'"
fi

# ---- a refused duration consumes no record (#1767) ------------------------------
# The refusal runs before the tape seam. Refused after a replay take, the replay
# of the 31 s call would take the valid call's record and the valid call would
# find the tape empty: its replay raises, so the transcripts differ.
N_REF=$(grep -c '^N [0-9][0-9]* audio_noise=' "$W/refuse.tape")
if [ "$(first_line "$W/frec")" = "refused" ] && [ "$(n_items "$(sed -n '2p' "$W/frec")")" = 8 ] &&
   [ "$(tail -n 1 "$W/frec")" = "rc=0" ] && [ "$N_REF" = 1 ] && cmp -s "$W/frec" "$W/frep"; then
    ok "AN10 a refused duration raises, consumes no record; capture == replay"
else
    fail "AN10 a refused duration moved the tape" \
         "records=$N_REF rec='$(one_line "$W/frec")' rep='$(one_line "$W/frep")'"
fi

echo "AUDIO_NOISE_TAPE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
