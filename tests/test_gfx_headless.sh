#!/usr/bin/env bash
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-gfx-headless.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Keeping every row visible when the launcher is absent makes the parent
# comparison honest: every claimed protection must be RED, not merely skipped.
if [ ! -f "$HERE/gfx_headless.sh" ]; then
    bad "stub receives SDL dummy and no live display variables"
    bad "stub observes the per-launch address-space cap"
    bad "hung gfx launch is terminated by timeout"
    bad "planted live-driver fault is detected by the stub oracle"
    bad "planted Darwin cap is detected"
    bad "planted Linux cap omission is detected"
    echo "GFX HEADLESS: $pass passed, $fail failed"
    exit 1
fi
. "$HERE/gfx_headless.sh"
. "$HERE/timeout_select.sh"
eigs_timeout_select 180

cat >"$TMP/record-env" <<'EOF'
#!/usr/bin/env bash
printf 'SDL=%s\nDISPLAY=%s\nWAYLAND=%s\nCAP=%s\n' \
    "${SDL_VIDEODRIVER-unset}" "${DISPLAY-unset}" "${WAYLAND_DISPLAY-unset}" "$(ulimit -v)"
EOF
chmod +x "$TMP/record-env"

out=$(DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 EIGS_GFX_MEMORY_KIB=123456 \
    gfx_headless_run 5 "$TMP/record-env" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'SDL=dummy' <<<"$out" &&
   grep -qx 'DISPLAY=unset' <<<"$out" && grep -qx 'WAYLAND=unset' <<<"$out"; then
    ok "stub receives SDL dummy and no live display variables"
else
    bad "stub received a live-display environment (rc=$rc: $out)"
fi

platform=$(uname -s)
parent_cap=$(ulimit -v)
if { [ "$platform" = Linux ] && grep -qx 'CAP=123456' <<<"$out"; } ||
   { [ "$platform" = Darwin ] && grep -qx "CAP=$parent_cap" <<<"$out"; }; then
    ok "stub observes the platform address-space policy"
else
    bad "stub did not observe the $platform address-space policy (parent=$parent_cap: $out)"
fi

start=$SECONDS
gfx_headless_run 1 bash -c 'sleep 5' >/dev/null 2>&1; timeout_rc=$?
elapsed=$((SECONDS - start))
if [ "$timeout_rc" -eq 124 ] && [ "$elapsed" -lt 5 ]; then
    ok "hung gfx launch is terminated by timeout"
else
    bad "timeout did not terminate the stub (rc=$timeout_rc elapsed=$elapsed)"
fi

# Plant the original fault in a private copy.  The same stub is the oracle:
# it must reject a launcher which selects a live/non-headless video driver.
sed 's/export SDL_VIDEODRIVER=dummy/export SDL_VIDEODRIVER=system/' \
    "$HERE/gfx_headless.sh" >"$TMP/mutant.sh"
unset -f gfx_headless_run
. "$TMP/mutant.sh"
mutant=$(DISPLAY=:0 gfx_headless_run 5 "$TMP/record-env" 2>&1); mutant_rc=$?
if [ "$mutant_rc" -eq 0 ] && ! grep -qx 'SDL=dummy' <<<"$mutant"; then
    ok "planted live-driver fault is detected by the stub oracle"
else
    bad "planted live-driver fault escaped the stub oracle"
fi

# Plant both sides of the platform policy. These are independent of the host:
# overriding uname selects the branch while the record stub remains the oracle.
sed 's/\[ "$platform" != Linux \] || ulimit -v "$cap_kib"/ulimit -v "$cap_kib"/' \
    "$HERE/../tools/gfx_address_space.sh" >"$TMP/cap-darwin.sh"
unset -f gfx_headless_run gfx_address_space_apply gfx_binary_instrumentation gfx_asan_symbols
. "$TMP/cap-darwin.sh"
. "$HERE/gfx_headless.sh"
uname() { printf '%s\n' Darwin; }
darwin_parent=$(ulimit -v)
darwin_mutant=$(EIGS_GFX_MEMORY_KIB=123456 gfx_headless_run 5 "$TMP/record-env" 2>&1)
if ! grep -qx "CAP=$darwin_parent" <<<"$darwin_mutant"; then
    ok "planted Darwin cap is detected"
else
    bad "planted Darwin cap escaped the stub oracle"
fi

sed 's/\[ "$platform" != Linux \] || ulimit -v "$cap_kib"/:/' \
    "$HERE/../tools/gfx_address_space.sh" >"$TMP/no-cap-linux.sh"
unset -f gfx_headless_run gfx_address_space_apply gfx_binary_instrumentation gfx_asan_symbols uname
. "$TMP/no-cap-linux.sh"
. "$HERE/gfx_headless.sh"
linux_mutant=$(EIGS_GFX_MEMORY_KIB=123456 gfx_headless_run 5 "$TMP/record-env" 2>&1)
if ! grep -qx 'CAP=123456' <<<"$linux_mutant"; then
    ok "planted Linux cap omission is detected"
else
    bad "planted Linux cap omission escaped the stub oracle"
fi

echo "GFX HEADLESS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
