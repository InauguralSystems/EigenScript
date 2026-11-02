# ROW: N11.strict-opt-in
# ITEMS: N11
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS:
# The same source must yield inf by default and a caught value error when
# strict arithmetic is explicitly enabled. The row's visible transcript is
# the strict run; the default run is compared exactly before it.
set -eu
binary=$1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/overflow.eigs" <<'EIGS'
try:
    print of (1e308 * 10)
catch e:
    print of e.kind
EIGS
(unset EIGS_STRICT; "$binary" "$tmp/overflow.eigs") > "$tmp/default.out"
printf 'inf\n' > "$tmp/default.expected"
if ! cmp -s "$tmp/default.expected" "$tmp/default.out"; then
    echo 'N11.strict-opt-in: default arithmetic did not print exactly inf' >&2
    cat "$tmp/default.out" >&2
    exit 1
fi
EIGS_STRICT=1 "$binary" "$tmp/overflow.eigs"
