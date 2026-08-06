#!/bin/bash
# --bundle tests (#413): single-file distribution — runtime + script +
# eigs_modules + stdlib in one executable, with an optional attached
# trace tape (`out --replay` = a self-replaying reproducer).
#
# Run directly or from run_all_tests.sh. Prints PASS:/FAIL: lines and a
# summary. Exit code: 0 if all pass, 1 if any fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
EIGS="$ROOT/src/eigenscript"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_bundle.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "BUNDLE: 0 passed, 1 failed"
    exit 1
fi

# ---- fixture: script + an eigs_modules package + a stdlib import + one
# nondet call (so the tape variant proves replay determinism).
APP="$TMPDIR/app"
mkdir -p "$APP/eigs_modules/greeter"
cat > "$APP/eigs_modules/greeter/greeter.eigs" <<'EOF'
define greet(n) as:
    return f"hello {n}"
EOF
cat > "$APP/app.eigs" <<'EOF'
import greeter
import json
r is random of null
print of greeter.greet of "bundle"
print of json.json_from_pairs of ([["k", 1]])
print of r
EOF

# ---- 1. bundle builds
"$EIGS" --bundle "$APP/app.eigs" "$APP/out" > /dev/null 2>&1 \
    && [ -x "$APP/out" ] \
    && ok "bundle builds an executable" \
    || fail "bundle builds an executable"

# ---- 2. runs away from any checkout: cwd=/ so no eigs_modules, no lib/,
# no eigs.json is reachable except through the bundle's own extraction
OUT=$(cd / && "$APP/out" 2>&1); RC=$?
echo "$OUT" | grep -q "hello bundle" \
    && echo "$OUT" | grep -q '{"k": 1}' \
    && [ "$RC" -eq 0 ] \
    && ok "bundled script + eigs_modules + stdlib run from bare cwd" \
    || fail "bundled script + eigs_modules + stdlib run from bare cwd" "rc=$RC: $(echo "$OUT" | head -2)"

# ---- 3. script args pass through to `args of null`
cat > "$APP/argy.eigs" <<'EOF'
print of (args of null)
EOF
"$EIGS" --bundle "$APP/argy.eigs" "$APP/outargs" > /dev/null 2>&1
OUT=$(cd / && "$APP/outargs" alpha beta 2>&1)
echo "$OUT" | grep -q "alpha" && echo "$OUT" | grep -q "beta" \
    && ok "bundle passes script args through" \
    || fail "bundle passes script args through" "$OUT"

# ---- 4. tape-attached bundle replays byte-identically, without the
# original environment (nondet served from the tape, not live). The
# oracle is the RECORDED run's own stdout: replay must reproduce it
# exactly (comparing against the tape's %.17g serialization would trip
# on print's shorter float formatting).
REC_OUT=$(EIGS_TRACE="$APP/app.tape" "$APP/out" 2>/dev/null)
"$EIGS" --bundle "$APP/app.eigs" "$APP/out2" --with-tape "$APP/app.tape" > /dev/null 2>&1
A=$(cd / && "$APP/out2" --replay 2>&1); RA=$?
B=$(cd / && "$APP/out2" --replay 2>&1); RB=$?
[ "$RA" -eq 0 ] && [ "$RB" -eq 0 ] && [ "$A" = "$B" ] \
    && ok "bundle-with-tape replays byte-identically" \
    || fail "bundle-with-tape replays byte-identically" "rc=$RA/$RB"
[ "$A" = "$REC_OUT" ] \
    && ok "replay reproduces the recorded run's exact output" \
    || fail "replay reproduces the recorded run's exact output" "recorded: $REC_OUT / replayed: $A"

# ---- 5. --replay without a tape refuses loudly (exit 3, replay policy)
(cd / && "$APP/out" --replay > /dev/null 2>&1); RC=$?
[ "$RC" -eq 3 ] \
    && ok "--replay without an attached tape refuses with exit 3" \
    || fail "--replay without an attached tape refuses with exit 3" "rc=$RC"

# ---- 6. a torn archive refuses instead of running garbage: drop a byte
# EARLY in the archive (inside the first entry), so every later entry
# header misparses — the structural tear the reader must catch. (A byte
# lost in the LAST entry's data is undetectable without checksums; the
# format trades that for simplicity — the tape inside carries its own
# version header.)
OFF=$(tail -c 24 "$APP/out" | od -A n -t u8 -N 8 | tr -d ' ')
# +24 skips the #882 head magic, so this stays an ENTRY-level tear (a byte
# lost inside the first entry) rather than a head-magic mismatch.
head -c $((OFF + 24 + 20)) "$APP/out" > "$APP/torn"
tail -c +$((OFF + 24 + 22)) "$APP/out" >> "$APP/torn"
chmod +x "$APP/torn"
(cd / && "$APP/torn" > /dev/null 2>&1); RC=$?
[ "$RC" -eq 3 ] \
    && ok "torn archive refuses with exit 3" \
    || fail "torn archive refuses with exit 3" "rc=$RC"

# ---- 7. re-bundling FROM a bundle copies only the runtime image (the
# new bundle must not grow by the old archive's size)
"$EIGS" --bundle "$APP/app.eigs" "$APP/out3" > /dev/null 2>&1
# portable sizes (GNU stat -c vs BSD stat -f): wc -c works on both.
# out3 must stay in the same ballpark as the runtime image + ~77 small
# files, far below 2x the image — i.e. the old archive did not accrete.
S3=$(wc -c < "$APP/out3" | tr -d ' ')
BASE=$(wc -c < "$EIGS" | tr -d ' ')
[ "$S3" -lt $((BASE * 2)) ] \
    && ok "re-bundle stays runtime-sized (no archive accretion)" \
    || fail "re-bundle stays runtime-sized (no archive accretion)" "base=$BASE out3=$S3"

# ---- 8. #882: a TRUNCATED bundle refuses instead of silently starting the
# REPL at exit 0. This is the normal failure mode for the one artifact of
# this project designed to be copied and downloaded, and the exit code is
# what every automated consumer keys on:
#     ./myapp && echo "deployed"      # used to print "deployed"
cp "$APP/out" "$APP/trunc"
SZ=$(wc -c < "$APP/trunc" | tr -d ' ')
head -c $((SZ - 50)) "$APP/out" > "$APP/trunc"
chmod +x "$APP/trunc"
TOUT=$(cd / && "$APP/trunc" < /dev/null 2>&1); RC=$?
[ "$RC" -eq 3 ] \
    && ok "truncated bundle refuses with exit 3 (was: REPL, exit 0)" \
    || fail "truncated bundle refuses with exit 3" "rc=$RC out=$TOUT"
case "$TOUT" in
    *"truncated or damaged"*) ok "truncated bundle names the cause" ;;
    *) fail "truncated bundle names the cause" "out=$TOUT" ;;
esac

# ---- 9. a bundle whose trailer survived but was corrupted in place
cp "$APP/out" "$APP/zeroed"
SZ=$(wc -c < "$APP/zeroed" | tr -d ' ')
printf '\0\0\0\0\0\0\0\0' | dd of="$APP/zeroed" bs=1 seek=$((SZ - 8)) conv=notrunc status=none
chmod +x "$APP/zeroed"
(cd / && "$APP/zeroed" < /dev/null > /dev/null 2>&1); RC=$?
[ "$RC" -eq 3 ] \
    && ok "bundle with a zeroed trailer magic refuses with exit 3" \
    || fail "bundle with a zeroed trailer magic refuses with exit 3" "rc=$RC"

# ---- 10. the plain interpreter must NOT be misdetected as a damaged bundle.
# The head magic is stored XOR-obfuscated precisely so its plaintext is not
# in the runtime image; without that, every `eigenscript` start would find
# this constant inside itself and refuse. Both entry paths:
echo 'print of "plain-ok"' > "$APP/plain.eigs"
POUT=$("$EIGS" "$APP/plain.eigs" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$POUT" = "plain-ok" ] \
    && ok "plain interpreter runs a script normally" \
    || fail "plain interpreter runs a script normally" "rc=$RC out=$POUT"

# ---- 10b. THE regression gate for the above. The head magic is stored
# XOR-obfuscated so its plaintext is never in the runtime image; if a compiler
# constant-folds that obfuscation away, the plaintext lands in rodata and every
# plain `eigenscript` start finds the magic inside itself and refuses with
# exit 3. That is not hypothetical: gcc -O2 did not fold it, clang did, and
# CI's macOS job went red with "plain interpreter still starts the REPL"
# failing. The key is `volatile` now, but assert the OUTCOME rather than trust
# the compiler — this catches it at test time on any toolchain.
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "
import sys
plain = b'\\x7fEIGS-BUNDLE-ARCHIVE-v2\\x00'
sys.exit(0 if plain not in open('$EIGS','rb').read() else 1)
"; then
        ok "head magic plaintext is NOT in the interpreter image (fold guard)"
    else
        fail "head magic plaintext is NOT in the interpreter image (fold guard)" \
             "the obfuscation was constant-folded — every plain start will refuse itself"
    fi
fi

ROUT=$(echo 'print of "repl-ok"' | "$EIGS" 2>&1); RC=$?
case "$ROUT" in
    *repl-ok*) ok "plain interpreter still starts the REPL (no false refusal)" ;;
    *) fail "plain interpreter still starts the REPL" "rc=$RC out=$ROUT" ;;
esac

echo "BUNDLE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
