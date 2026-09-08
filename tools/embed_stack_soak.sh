#!/usr/bin/env bash
# Embedded-stack soak gate: build the freestanding-profile runtime hosted
# (as freestanding_smoke.sh does) with the REPL-soak harness, then run it
# twice — once with the stack rlimit clamped to 64 KiB, once roomier.
#
# Hosted 8 MiB stacks hide per-AST-level C stack cost completely; this gate
# is what catches a regression like the by-value Compiler in
# compile_node_inner (~12.7 KiB of stack PER AST LEVEL — a 5-deep AST
# overflowed the 64 KiB boot stack EigenOS used at the time and silently
# trampled .bss, the mn-repl "#UD heisenbug"). Under the rlimit, an overflow
# is an instant SIGSEGV instead of a layout-dependent delayed fault.
#
# Run 1 — 64 KiB, the REPL soak. That 64 KiB is a deliberately tight
# PER-LEVEL REGRESSION BUDGET, not a measured EigenOS stack size (#758):
# per that issue EigenOS raised its boot stack as part of the #361 fix, and
# this number was left where it was on purpose. A budget below the real
# target is the right design for the job this gate does — detect a jump in
# stack cost per AST level, the way it caught #361 — but it is NOT a
# worst-case bound, and the depth guards are not sized against it (that
# policy: docs/FREESTANDING.md). Measured on this harness: the soak
# passes 20/20 down to a 32 KiB rlimit, is flaky at 28 and dead at 20, so
# roughly half the 64 KiB budget goes to startup + parse + VM before any
# recursive descent, and the rest survives only because a REPL soak runs
# shallow programs.
#
# Run 2 — 256 KiB, the depth-guard probe (#758). Deeply nested source, at a
# stack where the guard is genuinely the binding constraint, asserting the
# guard's clean diagnostic instead of a SIGSEGV. At 64 KiB the same input is
# SIGSEGV 20/20 — the guard cannot be reached there at all, which is why
# "the guard fires cleanly" was assumed and never tested. 256 KiB is chosen
# with margin: measured on this harness the guard trips cleanly 20/20 from
# 144 KiB, 18/20 at 128 KiB, and 0/20 at 112 KiB.
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------- how this gate matches (#1122)
# NO PIPELINE DECIDES A VERDICT HERE. Mechanism, from #1120: under
# `set -o pipefail`, `printf '%s' "$s" | grep -q "$pat"` is a RACE, not a
# test. `grep -q` exits the instant it matches and closes the read end; the
# still-writing `printf` then takes SIGPIPE and exits 141; pipefail reports
# the PIPELINE as 141 — a failed match — while grep's own status was 0,
# MATCHED. The verdict then contradicts the evidence printed beside it.
# Measured there: 21 false no-matches in 20,000 evaluations on a 157-byte
# capture, and CERTAIN once the capture exceeds the pipe buffer, because the
# writer must block and is therefore still writing when the reader exits.
# `tools/strict_differential.sh --selftest` reproduces that deterministically.
#
# So the three verdict sites below match with bash's own matcher: no fork, no
# pipe, no status to misread. The needle is QUOTED inside the pattern, so a
# glob character in it is a literal — the same promise `grep -F` made.
# All three needles are plain substrings; none was using a regex.
str_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

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
    -o "$BUILD/embed_stack_soak" \
    $EMBED_SRC \
    tools/embed_stack_soak_main.c \
    -lm -lpthread

set +e
out=$(bash -c "ulimit -s 64; '$BUILD/embed_stack_soak'" 2>&1); rc=$?
set -e

if [ "$rc" = 0 ] && str_has "$out" "embed_stack_soak: OK"; then
    echo "  PASS: REPL soak completes in a 64 KiB stack ($out)"
else
    echo "  FAIL: soak under 64 KiB stack (rc=$rc)"
    printf '%s\n' "$out" | tail -5
    exit 1
fi

set +e
gout=$(bash -c "ulimit -s 256; '$BUILD/embed_stack_soak' depth-guard" 2>&1); grc=$?
set -e

# All three conditions matter: rc 0 rules out the SIGSEGV (139) this is here to
# distinguish from; the diagnostic proves it was the depth guard that rejected
# the source and not some unrelated parse failure; the marker proves the
# runtime was still usable afterwards.
if [ "$grc" = 0 ] \
   && str_has "$gout" "nesting too deep" \
   && str_has "$gout" "embed_stack_soak: depth-guard OK"; then
    echo "  PASS: parse-depth guard rejects cleanly in a 256 KiB stack"
else
    echo "  FAIL: depth-guard probe under 256 KiB stack (rc=$grc)"
    # Drop the cascade of follow-on "expected ')'" lines the rejected source
    # produces, so the tail shows the diagnostic that matters.
    # This pipeline is NOT a verdict and is NOT exposed to #1122: `grep -v` and
    # `tail` both read to EOF, so neither can SIGPIPE the writer, and the
    # branch it prints in has already decided. Same for the `| tail -5` above.
    printf '%s\n' "$gout" | grep -v "expected ')'" | tail -5
    exit 1
fi
