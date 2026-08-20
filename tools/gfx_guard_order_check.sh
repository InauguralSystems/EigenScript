#!/usr/bin/env bash
# #1007: every ARG_GUARD in ext_gfx.c must precede that function's SDL load.
#
# WHY THIS IS A GATE AND NOT A CONVENTION. The non-strict stand-in for these
# guards is 0 — which is ALSO what every one of them answers when libSDL2 is
# absent. So on a machine WITH SDL a mis-ordered guard is indistinguishable
# from a correct one: it is reached, and it raises. On a machine WITHOUT SDL
# the function returns at `load_sdl2()` and the guard never runs.
#
# Bought in CI (2026-08-20, PR #1018). Three guards were deliberately hoisted
# above the load and the fourth, `audio_stream_open`, was not. Every local
# suite passed — this box has libSDL2 — and the CI extensions lane, which has
# none, failed with exactly one row: "#1007 strict: audio_stream_open raises
# on string freq/channels — expected type_mismatch, got none".
#
# WHAT THIS DOES NOT COVER: it checks ORDER within a function, not whether a
# guard exists at all, and it only knows the SDL entry points named in
# SDL_ENTRY below. A new way to reach SDL that is not named there is invisible
# to it. The population it scans is printed so a drop to zero is visible.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
SRC=src/ext_gfx.c

rc=0
# STRIP COMMENTS AND STRING LITERALS FIRST. Without this the scanner reads
# prose ABOUT its own subject: the comment added above `audio_stream_open`'s
# guard explains that it must precede `load_sdl2()`, and the mention alone
# made the check report the guard as mis-ordered. A per-line regex cannot do
# this — both constructs span lines — so it is a real state machine, and it
# also skips string literals so a `"...load_sdl2..."` cannot trip it either.
STRIPPED="$(awk '
    { line = ""; i = 1; n = length($0)
      while (i <= n) {
        c = substr($0, i, 1); c2 = substr($0, i, 2)
        if (incomment)      { if (c2 == "*/") { incomment = 0; i += 2 } else i++ ; continue }
        if (instr)          { if (c == "\\") { i += 2; continue }
                              if (c == q) instr = 0
                              i++; continue }
        if (c2 == "/*")     { incomment = 1; i += 2; continue }
        if (c2 == "//")     { break }
        if (c == "\"" || c == "'"'"'") { instr = 1; q = c; i++; continue }
        line = line c; i++
      }
      print line
    }
' "$SRC")"

# NO REGEX in the scanner, by design. `$0 ~ entry` with a dynamic pattern and
# `/^Value\* builtin_[a-z_0-9]+\(/` are both dialect-dependent: measured, mawk
# resolves them, busybox awk silently reports sdl=0 for every function, and
# macOS's awk found ZERO functions at all — which the vacuity floor caught in
# CI rather than letting it pass as a clean scan. index() is exact-substring
# and behaves identically everywhere, so the check no longer has an awk
# dialect as an input.
report="$(printf '%s\n' "$STRIPPED" | awk '
    index($0, "Value* builtin_") == 1 {
        fn = $2; k = index(fn, "("); if (k > 0) fn = substr(fn, 1, k - 1)
        guard = 0; sdl = 0; next
    }
    fn == "" { next }
    index($0, "ARG_GUARD(") > 0 && guard == 0 { guard = NR }
    (index($0, "load_sdl2(") > 0 || index($0, "p_SDL_") > 0) && sdl == 0 { sdl = NR }
    index($0, "}") == 1 {
        if (guard > 0) {
            if (sdl > 0 && sdl < guard) printf "BAD %s guard@%d after sdl@%d\n", fn, guard, sdl
            else                        printf "OK  %s\n", fn
        }
        fn = ""
    }
')"

n_ok=$(printf '%s\n' "$report"  | grep -c '^OK ' || true)
n_bad=$(printf '%s\n' "$report" | grep -c '^BAD' || true)

echo "== ext_gfx guard-order (#1007) =="
echo "  guarded builtins scanned: $((n_ok + n_bad))"
if [ "$n_bad" -gt 0 ]; then
    printf '%s\n' "$report" | grep '^BAD' | sed 's/^/    /'
    echo "  FAIL: a guard sits behind its own SDL load, so it does not exist on a"
    echo "        machine without libSDL2 — which is what CI runs."
    rc=1
fi
# Vacuity: a scan that found no guarded builtin has measured nothing. The
# floor is the count at the time #1007 landed; it may only be RAISED.
if [ "$((n_ok + n_bad))" -lt 11 ]; then
    echo "  VACUOUS: found $((n_ok + n_bad)) guarded builtins, floor is 11 — the"
    echo "           extractor broke, or guards were removed."
    rc=1
fi
[ "$rc" = "0" ] && echo "OK" || echo "FAIL"
exit $rc
