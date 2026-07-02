#!/usr/bin/env bash
# Hosted smoke of the freestanding profile: build a NORMAL hosted binary
# with -DEIGENSCRIPT_FREESTANDING=1 and prove (a) the core language still
# runs (interpreter-only), (b) the carved surfaces fail loudly, not
# silently. This is the behavioral half of the gate; the symbol half is
# tools/freestanding_check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# The harness main consumes the runtime the way EigenOS will: through
# eigs_embed.h with source strings — main.c (the POSIX CLI) is NOT part
# of the freestanding profile.
gcc -Werror=implicit-function-declaration -O2 \
    -DEIGENSCRIPT_FREESTANDING=1 \
    -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
    -o "$BUILD/eigs_fs" \
    src/eigenscript.c src/lexer.c src/parser.c src/builtins.c \
    src/builtins_tensor.c src/hash.c src/arena.c src/state.c src/strbuf.c \
    src/ext_store.c src/fmt.c src/lint.c src/chunk.c src/compiler.c \
    src/vm.c src/jit.c src/trace.c src/eigs_embed.c \
    tools/freestanding_smoke_main.c \
    -lm -lpthread

fail=0
check() { # label, expected_rc, expected_substring, program
    local label="$1" want_rc="$2" want_sub="$3" prog="$4"
    set +e
    out=$("$BUILD/eigs_fs" "$prog" 2>&1); rc=$?
    set -e
    if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q "$want_sub"; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (rc=$rc, want $want_rc; output: $(printf '%s' "$out" | head -3))"
        fail=1
    fi
}

# Core language still executes (interpreter-only).
check "core language runs" 0 "^42$" '
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
check "observer predicates run" 0 "^1$" '
e is 5
loop while not converged:
    e is e * 0.5
print of converged
'

# Carved builtin fails loudly (undefined variable, nonzero exit).
check "read_text is carved" 1 "read_text" 'x is read_text of "/etc/hostname"'
check "regex is carved (EigenRegex is the route)" 1 "regex_match" 'x is regex_match of ["a", "a"]'
check "exec is carved" 1 "exec_capture" 'x is exec_capture of "ls"'

# import raises the profile-specific error.
check "import raises profile error" 1 "no filesystem in the freestanding profile" 'import math'

echo "---"
if [ "$fail" = 0 ]; then echo "freestanding smoke: ALL PASSED"; else echo "freestanding smoke: FAILURES"; exit 1; fi
