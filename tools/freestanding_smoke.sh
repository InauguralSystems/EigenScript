#!/usr/bin/env bash
# Hosted smoke of the freestanding profile: build a NORMAL hosted binary
# with -DEIGENSCRIPT_FREESTANDING=1 and prove (a) the core language still
# runs (interpreter-only), (b) the carved surfaces fail loudly, not
# silently. This is the behavioral half of the gate; the symbol half is
# tools/freestanding_check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------- how this gate matches (#1122)
# NO PIPELINE DECIDES A VERDICT HERE. Mechanism, from #1120: under
# `set -o pipefail`, `printf '%s' "$s" | grep -q "$pat"` is a RACE, not a
# test. `grep -q` exits the instant it matches and closes the read end; the
# still-writing `printf` then takes SIGPIPE and exits 141; pipefail reports
# the PIPELINE as 141 — a failed match — while grep's own status was 0,
# MATCHED. `tools/strict_differential.sh --selftest` reproduces it
# deterministically on a capture larger than the pipe buffer.
#
# The matcher below is bash's own: no fork, no pipe, no status to misread.
# The needle is QUOTED inside the pattern, so a glob character in it is a
# literal — the same promise `grep -F` made.
# str_has      <haystack> <needle>      substring, what `grep -qF` meant
# str_has_line <haystack> <whole line>  what `grep -q "^needle$"` meant
#
# The single `grep -q "$want_sub"` this replaced was a BRE, and its callers
# used it two different ways: four passed a plain substring and two passed the
# anchored `^42$` / `^1$` form, which grep answers per LINE. One substring
# matcher would have served both and been silently WIDER on the anchored two —
# `check "..." 0 "42"` would pass on output containing "426". So the two ways
# are now two callees, and each call site says which it means.
str_has()      { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }
str_has_line() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1 ; }

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# The harness main consumes the runtime the way EigenOS will: through
# eigs_embed.h with source strings — main.c (the POSIX CLI) is NOT part
# of the freestanding profile.
# Source list ANCHORED to the Makefile's SOURCES minus CLI_ONLY (the pattern
# tools/amalgamate.sh and tools/freestanding_check.sh use). A hand-written copy
# here is a list nothing ties to the tree: when #744 split three new TUs out of
# vm.c/builtins.c/builtins_host.c, every copy of this list broke at the LINK
# step and only the copies someone remembered to update were fixed.
EMBED_SRC=$(make --no-print-directory print-SOURCES | tr ' ' '\n' | grep '\.c$')
CLI_ONLY=$(make --no-print-directory print-CLI_ONLY | tr ' ' '\n' | grep '\.c$')
for u in $CLI_ONLY; do EMBED_SRC=$(printf '%s\n' $EMBED_SRC | grep -vx "$u"); done
[ -n "$EMBED_SRC" ] || { echo "FAIL: derived an EMPTY source list from the Makefile" >&2; exit 1; }

gcc -Werror=implicit-function-declaration -Werror=switch -Werror=comment -Werror=misleading-indentation -O2 \
    -DEIGENSCRIPT_FREESTANDING=1 \
    -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
    -o "$BUILD/eigs_fs" \
    $EMBED_SRC \
    tools/freestanding_smoke_main.c \
    -lm -lpthread

fail=0
_check() { # label, expected_rc, matcher, wanted, program
    local label="$1" want_rc="$2" how="$3" want="$4" prog="$5"
    set +e
    out=$("$BUILD/eigs_fs" "$prog" 2>&1); rc=$?
    set -e
    if [ "$rc" = "$want_rc" ] && "$how" "$out" "$want"; then
        echo "  PASS: $label"
    else
        # Diagnostic only — the verdict above is already decided, and `head`
        # here cannot mislead it.
        echo "  FAIL: $label (rc=$rc, want $want_rc; output: $(printf '%s' "$out" | head -3))"
        fail=1
    fi
}
# label, expected_rc, expected_SUBSTRING, program
check()      { _check "$1" "$2" str_has      "$3" "$4"; }
# label, expected_rc, expected WHOLE LINE (was the `^...$` form), program
check_line() { _check "$1" "$2" str_has_line "$3" "$4"; }

# Core language still executes (interpreter-only).
check_line "core language runs" 0 "42" '
define square(x) as:
    return x * x
xs is [1, 2, 3]
total is 0
for i in xs:
    total is total + (square of i)
d is {"k": total * 3}
v is d["k"]
print of f"{v}"
'

# Observer semantics intact.
check_line "observer predicates run" 0 "1" '
e is 5
loop while not converged:
    e is e * 0.5
print of converged
'

# Carved builtin fails loudly (undefined variable, nonzero exit).
check "read_text is carved" 1 "read_text" 'x is read_text of "/etc/hostname"'
check "regex is carved (EigenRegex is the route)" 1 "regex_match" 'x is regex_match of ["a", "a"]'
check "exec is carved" 1 "exec_capture" 'x is exec_capture of "ls"'

# import: a provider-served module works with no filesystem; a module the
# provider lacks raises the profile-specific error.
check_line "import resolves via the source provider" 0 "42" 'import tiny
print of (tiny["answer"])'
check "import raises profile error" 1 "no filesystem in the freestanding profile" 'import math'

echo "---"
if [ "$fail" = 0 ]; then echo "freestanding smoke: ALL PASSED"; else echo "freestanding smoke: FAILURES"; exit 1; fi
