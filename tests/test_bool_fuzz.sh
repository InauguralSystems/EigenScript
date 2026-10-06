#!/usr/bin/env bash
# test_bool_fuzz.sh -- #1637: a bool is not a number, and not any other type
# a builtin did not declare. `true`, then `false`, goes into every argument
# slot of every builtin and extension name `--api --json` lists (slot kinds:
# tests/bool_fuzz_gen.eigs), and into the VM operand positions (index, slice
# bounds, range, for-in, arithmetic, list/string repetition), under
# EIGS_STRICT=1 and EIGS_STRICT=0.
#
# A call that RETURNS -- in either mode -- is a violation, unless its
# name|slot is on the reviewed any-value list tests/bool_fuzz_anyvalue.txt
# (print, type of, container elements, JSON, ...; every entry carries a
# reason and must be USED: a listed slot whose calls all raise is stale). A probe program that crashes, times out or does
# not reach its end marker is broken, and broken is a FAIL. A name the binary
# was built without (an extension that is off) is counted absent, never as a
# raise; every core builtin must be present.
#
# Prints `BOOL_FUZZ: examined=N/D ...` and exits 0 iff violations=0,
# broken=0, unused_anyvalue=0 and examined == present > 0.
# usage: test_bool_fuzz.sh [BINARY]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$(dirname "${1:-$HERE/../src/eigenscript}")" && pwd)/$(basename "${1:-eigenscript}")"
ANY="${BOOL_FUZZ_ANYVALUE:-$HERE/bool_fuzz_anyvalue.txt}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_bool_fuzz.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/gen" "$WORK/run"
# A tiny mono 16-bit WAV for the audio rows (44-byte header + 32 samples).
printf 'RIFF\x64\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00data\x40\x00\x00\x00' > "$WORK/t.wav"
head -c 64 /dev/zero >> "$WORK/t.wav"

# A bound per program: coreutils timeout, or gtimeout (macOS), or none.
if command -v timeout >/dev/null 2>&1; then TMO="timeout 20"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 20"
else TMO="env"; echo "BOOL_FUZZ: NOTE no timeout(1); programs run unbounded"; fi

"$BIN" --api --json > "$WORK/api.json" || { echo "BOOL_FUZZ: FAIL (--api --json)"; exit 1; }
GEN_OUT=$("$BIN" "$HERE/bool_fuzz_gen.eigs" "$WORK/api.json" "$HERE/strict_shape_cases.json" \
          "$WORK/run" "$WORK/t.wav" "$WORK/gen" 2>&1)
echo "$GEN_OUT" | grep -q '^GEN: ' || { echo "BOOL_FUZZ: FAIL (generator)"; echo "$GEN_OUT"; exit 1; }
DECLARED=$(echo "$GEN_OUT" | sed -n 's/^GEN: names=\([0-9]*\).*/\1/p')
"$BIN" --api | awk '$1 == "builtin" {print $2}' > "$WORK/core.txt"
CORE=$(grep -c . "$WORK/core.txt")

# Run every program in both modes, headless, memory-capped, under a deadline.
: > "$WORK/marks"
: > "$WORK/broken"
for p in "$WORK"/gen/p*.eigs; do
    id=$(basename "$p" .eigs)
    for strict in 1 0; do
        out=$(cd "$WORK/run" && env -u DISPLAY -u WAYLAND_DISPLAY SDL_VIDEODRIVER=dummy \
              SDL_AUDIODRIVER=dummy EIGS_STRICT=$strict \
              bash -c 'ulimit -v 1500000; exec $0 "$1" "$2"' "$TMO" "$BIN" "$p" \
              </dev/null 2>/dev/null)
        rc=$?
        # Markers may follow a builtin's own unterminated output on a line
        # (`write`, the screen_* escapes), so they are matched anywhere.
        if ! grep -q '@END$' <<< "$out"; then
            echo "$id|$strict|rc=$rc" >> "$WORK/broken"
            continue
        fi
        awk -v P="$id|$strict|" '{ if (match($0, /@(P:[a-z]+|[0-9]+:(V|R:[a-z_]+))$/)) print P substr($0, RSTART + 1) }' <<< "$out" >> "$WORK/marks"
    done
done

# Join the manifest with the marks: one verdict per (call, mode).
awk -F'|' -v ANY="$ANY" -v BROKEN="$WORK/broken" -v CORE="$CORE" -v DECLARED="$DECLARED" \
    -v CORELIST="$WORK/core.txt" '
BEGIN {
    while ((getline l < CORELIST) > 0) core[l] = 1
    while ((getline l < ANY) > 0) {
        if (l ~ /^#/ || l == "") continue
        split(l, f, "|")
        if (f[3] == "") { printf "  FAIL: any-value entry without a reason: %s|%s\n", f[1], f[2]; bad_any++ }
        anyv[f[1] "|" f[2]] = 1
    }
    while ((getline l < BROKEN) > 0) { split(l, f, "|"); broken[f[1]] = 1; brokenl[++nb] = l }
}
FNR == NR {                      # marks: prog|strict|P:type  or  prog|strict|k:V / k:R:kind
    if ($3 ~ /^P:/) { pres[$1 "|" $2] = substr($3, 3); next }
    split($3, m, ":"); mark[$1 "|" $2 "|" m[1]] = m[2] (m[3] != "" ? ":" m[3] : ""); next
}
{                                # manifest: prog|k|name|slot|value
    prog = $1; k = $2; name = $3; slot = $4; val = $5
    if (prog == "skip") { skipped[name] = slot; next }
    calls++
    if (!(prog in seenprog)) { seenprog[prog] = name; nprog++ }
    for (s = 1; s >= 0; s--) {
        if (prog in broken) continue
        if (name != "@vm") {
            t = pres[prog "|" s]
            if (t == "absent") { absent[name] = 1; continue }
            if (t != "builtin" && t != "extension") { printf "  FAIL: %s: presence marker %s\n", name, t; badpres++; continue }
        }
        examined_name[name] = 1
        v = mark[prog "|" s "|" k]
        probes++
        if (v == "") { printf "  FAIL: %s %s=%s (EIGS_STRICT=%d): no marker\n", name, slot, val, s; nomark++; continue }
        if (v == "V") {
            if ((name "|" slot) in anyv) { anyok++; usedany[name "|" slot] = 1; continue }
            printf "  VIOLATION: %s slot %s given %s returned without raising (EIGS_STRICT=%d)\n", name, slot, val, s
            viol++
        } else {
            raised++; kinds[substr(v, 3)]++
        }
    }
}
END {
    for (key in anyv) if (!(key in usedany)) { printf "  FAIL: unused any-value entry %s\n", key; bad_any++ }
    for (i = 1; i <= nb; i++) printf "  FAIL: broken probe program %s (%s)\n", brokenl[i], seenprog[substr(brokenl[i], 1, index(brokenl[i], "|") - 1)]
    nex = 0; for (n in examined_name) if (n != "@vm") nex++
    nab = 0; for (n in absent) if (!(n in examined_name)) nab++
    nsk = 0; for (n in skipped) { nsk++; printf "  SKIP: %s (%s)\n", n, skipped[n] }
    for (n in core) if (!(n in examined_name) && !(n in skipped)) { printf "  FAIL: core builtin %s was not examined\n", n; badpres++ }
    kstr = ""; for (kk in kinds) kstr = kstr kk "=" kinds[kk] " "
    ok = (viol == 0 && nb == 0 && nomark == 0 && badpres == 0 && bad_any == 0 && \
          nex + nab + nsk == DECLARED && nex + nsk >= CORE && nex > 0 && ("@vm" in examined_name))
    printf "BOOL_FUZZ: raise kinds: %s\n", kstr
    printf "BOOL_FUZZ: examined=%d/%d absent=%d skipped=%d core=%d programs=%d calls=%d probes=%d raised=%d anyvalue=%d violations=%d broken=%d unused_anyvalue=%d %s\n", \
        nex, DECLARED, nab, nsk, CORE, nprog, calls, probes, raised, anyok, viol + nomark + badpres, nb, bad_any, ok ? "PASS" : "FAIL"
    exit ok ? 0 : 1
}' "$WORK/marks" "$WORK/gen/manifest.txt"
