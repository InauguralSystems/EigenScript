#!/usr/bin/env bash
# N14: deterministic header refusal precedes request work and replay TAKE.
set -eu
bin=$1
scratch=$(mktemp -d "${TMPDIR:-/tmp}/eigs-r25-http.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
cat > p.eigs <<'EOF'
try:
    http_post of ["http://127.0.0.1:1", "{\"X\":1e400}", "unused"]
catch e:
    print of e.kind
print of (type of (env_get of "PATH"))
EOF
printf 'value\nstr\n' > want.out
"$bin" p.eigs > live.out
cmp want.out live.out
EIGS_TRACE=one.tape "$bin" p.eigs > one.out
EIGS_TRACE=two.tape "$bin" p.eigs > two.out
cmp live.out one.out
cmp live.out two.out
cmp one.tape two.tape
if grep -q ' http_post=' one.tape; then
    echo 'deterministic refusal incorrectly recorded an HTTP outcome' >&2
    exit 1
fi
grep -q ' env_get=' one.tape
EIGS_REPLAY=one.tape EIGS_REPLAY_STRICT=1 "$bin" p.eigs > replay.out
cmp live.out replay.out
printf 'http-decode-overflow: value; no HTTP outcome; two tapes identical; strict replay aligned\n'
