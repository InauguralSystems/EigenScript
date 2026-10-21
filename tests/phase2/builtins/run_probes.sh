#!/usr/bin/env bash
# run_probes.sh [case...]: record builtins/<case>.pre and builtins/<case>.tag by
# RUNNING builtins/<case>.eigs on the pre (R1.5 tip) and tag (v0.46.0) binaries.
# Each record is the probe's stdout plus a last line rc=<N> (rc=124 is a
# timeout). stderr is kept beside the scratch copy, never compared. .branch
# files are NEVER written here. No argument: every case in cases.tsv.
#   cases.tsv  case, builtin, hook, stdin   rowmeta.tsv  builtin, closed_in, profile
# A non-release row (profile server|db|zlib) records PENDING-PROFILE unless
# PRE_BIN_<PROFILE> and TAG_BIN_<PROFILE> name matched builds (ruling A3); each
# such binary must first print profile-ok from builtins/_profiles/<profile>.eigs.
# DATABASE_URL (db rows) and R16_HTTP_CAPTURE_URL (http_post's capture fixture,
# ruling B6) pass through when set.
# A hook case runs with builtins/_hooks/observation_hooks.c, built here, as
# LD_PRELOAD, and must log "hook-loaded <hook>" (ruling A4).
# Exit 2 on any instrument failure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PRE=${PRE_BIN:-/home/jon/src/wt/r15-critic/build/release/eigenscript}
TAG=${TAG_BIN:-/tmp/claude-1000/-home-jon-src/d657c999-ca9c-4702-a0c1-37e0efc092c4/scratchpad/rel046/eigenscript-linux-x86_64}
WORK=${TMPDIR:-/tmp}
ERRDIR=${PROBE_STDERR_DIR:-$WORK/r16bar-stderr}
for b in "$PRE" "$TAG"; do [ -x "$b" ] || { echo "FAIL: binary not executable: $b"; exit 2; }; done
mkdir -p "$ERRDIR" || exit 2
SHIM="$WORK/r16bar-observation-hooks.$$.so"
trap 'rm -f "$SHIM"' EXIT
gcc -shared -fPIC -O0 -Wall -Wextra -Werror "$HERE/builtins/_hooks/observation_hooks.c" -ldl -o "$SHIM" \
    || { echo "FAIL: the observation shim did not build"; exit 2; }
declare -A HOOK STDIN BUILTIN PROFILE
while IFS=$'\t' read -r c b h s; do BUILTIN[$c]=$b; HOOK[$c]=$h; STDIN[$c]=$s; done < <(tail -n +2 "$HERE/cases.tsv")
while IFS=$'\t' read -r b ci p; do PROFILE[$b]=$p; done < <(tail -n +2 "$HERE/rowmeta.tsv")
[ ${#BUILTIN[@]} -gt 0 ] && [ ${#PROFILE[@]} -gt 0 ] || { echo "FAIL: empty cases.tsv or rowmeta.tsv"; exit 2; }
cd "$HERE/builtins" || exit 2
names=("$@")
[ ${#names[@]} -gt 0 ] || names=($(printf '%s\n' "${!BUILTIN[@]}" | LC_ALL=C sort))
bad=0; pending=0; hooked=0
FIXENV=()
[ -z "${DATABASE_URL:-}" ] || FIXENV+=("DATABASE_URL=$DATABASE_URL")
[ -z "${R16_HTTP_CAPTURE_URL:-}" ] || FIXENV+=("R16_HTTP_CAPTURE_URL=$R16_HTTP_CAPTURE_URL")
profile_ok() {  # profile_ok <binary> <profile>: the binary carries the profile's capabilities
    local tmp out
    tmp=$(mktemp -d "$WORK/r16profile.XXXXXX") || exit 2
    out=$( ( ulimit -v 1500000; cd "$tmp" && exec env -i PATH=/usr/bin:/bin HOME="$tmp" "${FIXENV[@]}" \
        timeout 60 "$1" "$HERE/builtins/_profiles/$2.eigs" </dev/null 2>/dev/null ) )
    rm -rf "$tmp"
    grep -qx 'profile-ok' <<<"$out"
}
run_one() {  # run_one <binary> <case> <kind: pre|tag>
    local c=$2 kind=$3 out="$HERE/builtins/$2.$3" tmp rc hook=${HOOK[$2]} in=/dev/null
    rm -f "$out"   # a stale record must never survive a run that did not write one
    tmp=$(mktemp -d "$WORK/r16probe.XXXXXX") || exit 2
    [ "${STDIN[$c]}" = "-" ] || in="$HERE/builtins/_stdin/${STDIN[$c]}"
    [ -r "$in" ] || { echo "FAIL: $c: no stdin fixture $in"; bad=$((bad + 1)); }
    local -a hookenv=()   # set after timeout, so only the probed binary loads the shim
    [ "$hook" = "-" ] || hookenv=(LD_PRELOAD="$SHIM" R16_HOOK="$hook" R16_HOOK_LOG="$tmp/hook.log")
    # The suite's headless gfx/audio conditions (SDL dummy drivers), the local
    # display, the bitmap font for deterministic text metrics, a memory cap.
    ( ulimit -v 1500000; cd "$tmp" && exec env -i PATH=/usr/bin:/bin HOME="$tmp" \
        DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        EIGS_GFX_FONT=/nonexistent/eigs-no-font.ttf EIGS_PROBE_TMP="$tmp" "${FIXENV[@]}" \
        timeout 60 env "${hookenv[@]}" "$1" "$HERE/builtins/$c.eigs" <"$in" >"$out" 2>"$ERRDIR/$c.$kind.stderr" )
    rc=$?
    # Every probe prints at least one line, so an empty stdout with rc 0 is an
    # instrument failure (it was one: a relative path written after the cd).
    if [ ! -s "$out" ] && [ "$rc" -eq 0 ]; then echo "FAIL: $c.$kind printed nothing with rc 0"; bad=$((bad + 1)); fi
    # No probe may block on any binary (values are queued first), so a timeout is a named failure.
    if [ "$rc" -eq 124 ]; then echo "FAIL: $c.$kind timed out (rc 124)"; bad=$((bad + 1)); fi
    if [ "$hook" != "-" ]; then
        if head -1 "$tmp/hook.log" 2>/dev/null | grep -qx "hook-loaded $hook"; then hooked=$((hooked + 1))
        else echo "FAIL: $c.$kind ran without its hook $hook (no hook-loaded line)"; bad=$((bad + 1)); fi
    fi
    echo "rc=$rc" >> "$out"
    rm -rf "$tmp"
}
ran=0
for c in "${names[@]}"; do
    [ -n "${BUILTIN[$c]:-}" ] || { echo "FAIL: $c is not a case in cases.tsv"; exit 2; }
    [ -f "$c.eigs" ] || { echo "FAIL: no probe builtins/$c.eigs"; exit 2; }
    p=${PROFILE[${BUILTIN[$c]}]:-}
    case "$p" in
        release) run_one "$PRE" "$c" pre; run_one "$TAG" "$c" tag ;;
        server|db|zlib)
            u=${p^^}; pb=PRE_BIN_$u; tb=TAG_BIN_$u
            if [ -n "${!pb:-}" ] && [ -n "${!tb:-}" ]; then
                for x in "${!pb}" "${!tb}"; do
                    profile_ok "$x" "$p" || { echo "FAIL: $x is not a $p build (builtins/_profiles/$p.eigs did not print profile-ok)"; exit 2; }
                done
                run_one "${!pb}" "$c" pre; run_one "${!tb}" "$c" tag
            else for k in pre tag; do printf 'PENDING-PROFILE %s\n' "$p" > "$c.$k"; done; pending=$((pending + 1)); fi ;;
        *) echo "FAIL: $c: unknown profile '$p'"; exit 2 ;;
    esac
    ran=$((ran + 1))
done
echo "ran=$ran requested=${#names[@]} empty_or_hookless=$bad hook_runs=$hooked pending_profile=$pending"
[ "$ran" -eq "${#names[@]}" ] && [ "$bad" -eq 0 ] || exit 2
