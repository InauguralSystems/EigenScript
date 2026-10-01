#!/usr/bin/env bash
# UI public-surface and real SDL input gate (#1263).
set -u
WERROR_FLAGS_FILE="$(dirname "$0")/werror_flags.txt"
. "$(dirname "$0")/read_werror_flags.sh" || exit 1
cd "$(dirname "$0")/.." || exit 2

exports() {
  awk '/^define [A-Za-z][A-Za-z0-9_]*\(/ { n=$2; sub(/\(.*/, "", n); print n }' lib/ui*.eigs | sort -u
}

check_static() {
  local bad=0 name
  while IFS= read -r name; do
    if ! grep -Eq "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|$)" tests/test_ui.eigs; then
      echo "UNTESTED UI EXPORT: $name"; bad=1
    fi
    if ! grep -Eq "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|$)" docs/STDLIB.md; then
      echo "UNDOCUMENTED UI EXPORT: $name"; bad=1
    fi
  done < <(exports)
  [ "$bad" -eq 0 ] || return 1
  echo "ui surface static OK: $(exports | wc -l | tr -d ' ') public exports tested and documented"
}

case "${1:-}" in
  "") check_static ;;
  --gfx-input)
    check_static || exit 1
    ulimit -v 1500000
    make --no-print-directory ui-sdl-input-gfx
    ;;
  --selftest)
    check_static || exit 1
    probe="zz_ui_surface_selftest_probe"
    cp lib/ui.eigs "lib/ui.eigs.selftest.$$"
    trap 'mv "lib/ui.eigs.selftest.$$" lib/ui.eigs' EXIT HUP INT TERM
    printf '\ndefine %s() as:\n    return null\n' "$probe" >> lib/ui.eigs
    out=$(check_static 2>&1); rc=$?
    mv "lib/ui.eigs.selftest.$$" lib/ui.eigs; trap - EXIT HUP INT TERM
    if [ "$rc" -eq 0 ] || ! printf '%s\n' "$out" | grep -q "UNTESTED UI EXPORT: $probe" ||
       ! printf '%s\n' "$out" | grep -q "UNDOCUMENTED UI EXPORT: $probe"; then
      echo "SELFTEST FAILED: planted export was not named"; exit 1
    fi
    echo "SELFTEST RED: named untested and undocumented export $probe"
    # The ABI plant is compile-time mechanical: removing the field must make
    # the offsetof assertion fail before a corrupt event can reach a caller.
    tmp=$(mktemp "${TMPDIR:-/tmp}/ui_input_plant.XXXXXX.c") || exit 2
    sed 's/Uint32 state; Sint32 x/\/\* planted deletion *\/ Sint32 x/' src/ext_gfx.c > "$tmp"
    if ${CC:-cc} $WERROR_FLAGS \
         -Isrc -DEIGENSCRIPT_EXT_GFX=1 -fsyntax-only "$tmp" >"$tmp.out" 2>&1; then
      echo "SELFTEST FAILED: deleting SDL_MouseMotionEvent.state compiled"; rm -f "$tmp" "$tmp.out"; exit 1
    fi
    if ! grep -q 'SDL_MouseMotionEvent ABI' "$tmp.out"; then
      cat "$tmp.out"; echo "SELFTEST FAILED: ABI plant failed for an unrelated reason"; rm -f "$tmp" "$tmp.out"; exit 1
    fi
    rm -f "$tmp" "$tmp.out"
    echo "SELFTEST RED: deleting SDL_MouseMotionEvent.state trips the ABI assertion"
    echo "ui surface selftest OK"
    ;;
  *) echo "usage: tools/ui_surface_check.sh [--gfx-input|--selftest]" >&2; exit 2 ;;
esac
