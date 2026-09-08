#!/usr/bin/env bash
# core_ext_boundary_check.sh — the core must not include an extension's
# private header (#744 item 1).
#
# WHY THIS IS A GATE AND NOT A COMMENT. `ext_db_internal.h` says "Only
# included by ext_db.c" and pulls <libpq-fe.h>. A core translation unit that
# includes it for one function declaration makes the CORE unbuildable without
# PostgreSQL headers in every variant that sets EIGENSCRIPT_EXT_DB=1 —
# measured on a box without libpq-dev, `gcc -DEIGENSCRIPT_EXT_DB=1 -c
# src/builtins.c` died on `libpq-fe.h: No such file or directory`. Nothing in
# the tree noticed, because the only target that compiles that combination is
# `make full`, which needs libpq to build at all. The entry points now live in
# src/ext_register.h — declarations, no extension types.
#
# TWO LEGS, because either alone can pass while the invariant is broken:
#
#   A. STRUCTURAL. Every core TU (enumerated from the Makefile's SOURCES —
#      the authoritative list, not a copy of it) is scanned for an #include of
#      any extension private header (enumerated from the tree, not a list).
#      Exemptions are pinned by name and CHECKED IN BOTH DIRECTIONS: a pinned
#      exemption that no longer matches anything is a hard failure, so a
#      waiver cannot outlive the code it waives.
#
#   B. EXECUTABLE. `-fsyntax-only` over every core TU with EVERY extension
#      switched ON, with a POISONED <libpq-fe.h> first on the include path.
#      The poison is what makes this leg non-vacuous on a machine that HAS
#      libpq: without it the probe would compile happily on a dev box and only
#      fail on the machines that lack the header — the failure mode this gate
#      exists to prevent. Leg A cannot replace leg B (an include can arrive
#      transitively through another project header); leg B cannot replace leg
#      A (only the libpq edge has a system header to poison).
#
# Usage: tools/core_ext_boundary_check.sh [--selftest]
#   --selftest : plant the removed include back into a COPY of the tree and
#                confirm BOTH legs go red — separately, so neither is coasting
#                on the other.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$(pwd)"

SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

# Every extension private header, from the tree. A new ext_*_internal.h is in
# scope the moment it is committed — no list to update.
ext_headers() {
    local tree="$1"
    ( cd "$tree" && ls src/ext_*_internal.h src/model_internal.h 2>/dev/null ) \
        | sed 's#^src/##' | sort -u
}

# Core TUs = the Makefile's SOURCES. Ask make, don't parse the file: SOURCES
# is a variable and its expansion is the only honest answer.
core_tus() {
    local tree="$1"
    make -C "$tree" --no-print-directory print-SOURCES 2>/dev/null \
        | tr ' ' '\n' | sed -n 's#^src/##p' | grep '\.c$' | sort -u
}

# Pinned exemptions: "<tu>:<header>  # reason". Each must MATCH something.
EXEMPT=(
  # handle_table_drain's HANDLE_NET teardown pass reads EigsNetSock.fd, and
  # that header is deliberately free of socket headers for exactly this use
  # (it says so). A type, not a declaration — ext_register.h cannot carry it.
  "builtins.c:ext_net_internal.h"
)

leg_a() {
    local tree="$1" rc=0 hdrs tus
    hdrs=$(ext_headers "$tree")
    tus=$(core_tus "$tree")
    if [ -z "$hdrs" ] || [ -z "$tus" ]; then
        echo "FAIL[A]: enumerated 0 headers or 0 core TUs (matcher broke)" >&2
        return 1
    fi
    local n_scanned=0 n_hits=0
    local -a seen_exempt=()
    for tu in $tus; do
        [ -f "$tree/src/$tu" ] || continue
        n_scanned=$((n_scanned + 1))
        for h in $hdrs; do
            # A TU including its OWN private header is the pattern working,
            # not a violation (ext_store.c is in SOURCES — always compiled —
            # and owns ext_store_internal.h).
            [ "$h" = "${tu%.c}_internal.h" ] && continue
            grep -qE "^[[:space:]]*#[[:space:]]*include[[:space:]]+\"$h\"" "$tree/src/$tu" || continue
            n_hits=$((n_hits + 1))
            local pair="$tu:$h" ok=0
            for e in "${EXEMPT[@]}"; do
                [ "$e" = "$pair" ] && { ok=1; seen_exempt+=("$e"); }
            done
            if [ "$ok" = 0 ]; then
                echo "FAIL[A]: core TU src/$tu includes extension private header \"$h\"" >&2
                echo "         declare the entry point in src/ext_register.h instead" >&2
                rc=1
            fi
        done
    done
    # Reverse direction: a pinned exemption that matches nothing is stale.
    for e in "${EXEMPT[@]}"; do
        local found=0
        for s in ${seen_exempt[@]+"${seen_exempt[@]}"}; do [ "$s" = "$e" ] && found=1; done
        if [ "$found" = 0 ]; then
            echo "FAIL[A]: pinned exemption '$e' matches nothing — drop it" >&2
            rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "leg A: $n_scanned core TUs scanned, $n_hits ext-private include(s), all pinned"
    return $rc
}

# leg_b <tree> [only_tu]
# `only_tu` narrows the probe to ONE translation unit and is used by --selftest
# alone (a planted fault lives in one file; probing 28 to see it is 20 seconds
# of nothing). The REAL run never passes it — the population is every core TU.
leg_b() {
    local tree="$1" only="${2:-}" rc=0
    local poison; poison=$(mktemp -d)
    cat > "$poison/libpq-fe.h" <<'POISON'
#error "core TU reached <libpq-fe.h> (#744): the core must not include ext_db_internal.h"
POISON
    local tus; tus=$(core_tus "$tree")
    local n=0
    for tu in $tus; do
        [ -f "$tree/src/$tu" ] || continue
        [ -n "$only" ] && [ "$tu" != "$only" ] && continue
        n=$((n + 1))
        # Capture the status DIRECTLY. `$?`/PIPESTATUS after a pipeline (or
        # after any simple command run in between, `:` included) is not the
        # compiler's status — that mistake reads as "the probe is green".
        local out st
        out=$( cd "$tree" && gcc -c -o /dev/null -I"$poison" -Isrc \
                 -Wall -Werror=switch -Werror=comment -Werror=misleading-indentation \
                 -Werror=implicit-function-declaration \
                 -DEIGENSCRIPT_EXT_HTTP=1 -DEIGENSCRIPT_EXT_MODEL=1 \
                 -DEIGENSCRIPT_EXT_DB=1 -DEIGENSCRIPT_EXT_NET=1 \
                 -DEIGENSCRIPT_VERSION='"gate"' "src/$tu" 2>&1 )
        st=$?
        if [ "$st" != 0 ]; then
            echo "FAIL[B]: src/$tu does not compile with every extension ON and libpq poisoned" >&2
            printf '%s\n' "$out" | head -6 >&2
            rc=1
        fi
    done
    rm -rf "$poison"
    if [ -z "$only" ] && [ "$n" -lt 10 ]; then
        echo "FAIL[B]: only $n core TUs probed (matcher broke)" >&2
        rc=1
    fi
    if [ -n "$only" ] && [ "$n" != 1 ]; then
        echo "FAIL[B]: selftest asked for src/$only and probed $n TUs" >&2
        rc=1
    fi
    [ "$rc" = 0 ] && echo "leg B: $n core TUs compile with EXT_{HTTP,MODEL,DB,NET}=1 and <libpq-fe.h> poisoned"
    return $rc
}

if [ "$SELFTEST" = 0 ]; then
    a=0; b=0
    leg_a "$REPO" || a=1
    leg_b "$REPO" || b=1
    if [ "$a" = 0 ] && [ "$b" = 0 ]; then
        echo "OK: no core -> extension-private include edge"
        exit 0
    fi
    exit 1
fi

# ---- selftest: plant the fault, prove each leg fires on its own ----------
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cp -r "$REPO/src" "$REPO/Makefile" "$REPO/VERSION" "$WORK/" 2>/dev/null
mkdir -p "$WORK/lib" && : > "$WORK/lib/.keep"
fails=0

# Control: the pristine copy must be GREEN in both legs, or the selftest is
# measuring the copy and not the fault.
leg_a "$WORK" >/dev/null 2>&1 || { echo "selftest FAIL: leg A red on a clean copy"; fails=1; }
leg_b "$WORK" builtins.c >/dev/null 2>&1 || { echo "selftest FAIL: leg B red on a clean copy"; fails=1; }

# Fault 1: the exact include #744 removed, back in builtins.c. Both legs see it.
python3 - "$WORK" <<'PY'
import sys
p = sys.argv[1] + "/src/builtins.c"
s = open(p).read()
old = '#include "ext_register.h"'
assert old in s
s = s.replace(old, old + '\n#if EIGENSCRIPT_EXT_DB\n#include "ext_db_internal.h"\n#endif', 1)
open(p, 'w').write(s)
PY
leg_a "$WORK" >/dev/null 2>&1 && { echo "selftest FAIL: leg A green with ext_db_internal.h back in builtins.c"; fails=1; } \
                              || echo "selftest ok: leg A catches a planted core->ext include"
leg_b "$WORK" builtins.c >/dev/null 2>&1 && { echo "selftest FAIL: leg B green with libpq reachable from builtins.c"; fails=1; } \
                              || echo "selftest ok: leg B catches the poisoned libpq edge"

# Fault 2: a stale exemption. Remove the include the waiver covers and the
# reverse check must fire — a waiver must not outlive its subject.
rm -rf "$WORK/src"; cp -r "$REPO/src" "$WORK/"
python3 - "$WORK" <<'PY'
import sys, re
p = sys.argv[1] + "/src/builtins.c"
s = open(p).read()
s2 = re.sub(r'^[ \t]*#[ \t]*include[ \t]+"ext_net_internal\.h"[ \t]*\n', '', s, count=1, flags=re.M)
assert s2 != s
open(p, 'w').write(s2)
PY
leg_a "$WORK" >/dev/null 2>&1 && { echo "selftest FAIL: leg A green with a stale pinned exemption"; fails=1; } \
                              || echo "selftest ok: leg A catches a stale exemption (reverse direction)"

[ "$fails" = 0 ] && { echo "selftest: all planted faults caught"; exit 0; }
exit 1
