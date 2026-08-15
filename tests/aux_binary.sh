#!/bin/bash
# Freshness gate for the suite's AUXILIARY binaries — src/eigenlsp (section
# [88]) and src/eigsdap (section [126]). Sourced by test_lsp.sh and
# test_dap.sh; not executable on its own.
#
# Why this exists: plain `make` does not build either binary — only `make
# lsp` / `make dap` do. So `make && cd tests && ./run_all_tests.sh`, the
# documented local loop, happily drives whatever eigenlsp/eigsdap an earlier
# build left on disk, against tests from the current tree. The wrappers used
# to build them only when ABSENT, which is presence, not freshness.
#
# Bought twice:
#   #825 — a version-skewed eigsdap made the #411 tape gate refuse every
#          tape, and the 18 downstream failures blamed DAP behaviour.
#   2026-08-15, clearing #942/#944/#947 — an eigenlsp built the previous day
#          failed exactly the five new #935 assertions and passed the other
#          87. A full extra suite run went into proving the code was fine.
#
# The version string is NOT a sufficient check. That is what #825 added, and
# it only discriminates across a release bump: in the 2026-08-15 case the
# binary and the runtime both said 0.39.0 while their sources differed by a
# day. It is kept in test_dap.sh as a second, coarser net (it still catches a
# binary carried in from outside the tree, which mtimes cannot see).
#
# And the expensive direction is not the phantom FAILURE — that merely costs
# time. It is the phantom PASS: a stale binary predating a regression reports
# its whole section green, which is the gate-measures-less failure mode.
#
# ---- Why `make -q` and not an mtime scan -------------------------------
# The first version of this file globbed `src/*.c src/*.h` and compared
# mtimes. That is a hand-maintained prerequisite list standing in for the
# real one, and it was already wrong: `src/freestanding/mini_libc.h` sits a
# directory down and was invisible to it, as would be the Makefile itself and
# every generated header (build/eigs_embed.h, lsp_stdlib_index.h).
# `make -q <target>` answers the same question from the build system's own
# post-expansion dependency graph — the `-MMD -MP` .d files included — so it
# cannot drift from what an actual build would do.
#
# ---- Residuals (what this does NOT cover) ------------------------------
#  * A binary copied in from another tree with a mtime NEWER than every
#    prerequisite reads as fresh. Only the version check in test_dap.sh sees
#    that class, and only across a release bump.
#  * CI never exercises this gate: every job builds from a clean checkout, so
#    the target is always out of date on the first call and always fresh
#    after. This gate exists for the LOCAL loop, and a green CI run is not
#    evidence that it works — the planted-fault runs recorded in the commit
#    message are.
#  * It says nothing about whether the binary is CORRECT, only that it was
#    built from the sources now in the tree.
#
# Contract: aux_binary_fresh <binary> <make-target> <display-name> <suite-label>
#   0 → fresh (rebuilt first if it had to be); caller proceeds
#   1 → printed a FAIL line; caller must exit 1
#   2 → printed a SKIP line; caller must exit 0

aux_binary_fresh() {
    local bin="$1" target="$2" name="$3" label="$4"
    local root; root="$(cd "$(dirname "$bin")/.." && pwd)"
    local q why=""

    ( cd "$root" && make -q "$target" ) >/dev/null 2>&1
    q=$?
    if [ ! -x "$bin" ]; then
        why="not built"
    elif [ "$q" -eq 1 ]; then
        why="older than its sources"
    elif [ "$q" -gt 1 ]; then
        # The oracle itself is broken (bad target, makefile error). Never
        # silently fall through to testing an unverified binary.
        echo "  FAIL: cannot determine whether $name is current — 'make -q $target' exited $q"
        return 1
    fi

    if [ -n "$why" ]; then
        # Say so rather than rebuilding silently — a section that suddenly
        # takes 90s should explain itself. run_all_tests.sh greps this line
        # out so it survives a green run.
        echo "  NOTE: $name $why — rebuilding (make $target)"
        ( cd "$root" && make "$target" ) >/dev/null 2>&1
    fi

    if [ ! -x "$bin" ]; then
        echo "  SKIP: $name not built — $label tests skipped"
        return 2
    fi
    ( cd "$root" && make -q "$target" ) >/dev/null 2>&1 || {
        # A rebuild ran and the target is still out of date: the build
        # failed. Testing against this binary would report on code that is
        # not in the tree. Refuse instead.
        echo "  FAIL: $name is still out of date after 'make $target' — refusing to test a stale binary"
        return 1
    }
    return 0
}
