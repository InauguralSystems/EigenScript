#!/bin/sh
set -eu

EIGS=${1:-"$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/src/eigenscript"}
TMP=${TMPDIR:-/tmp}/eigs-observer-fix2-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir "$TMP"

# The reviewer's exact alias shape, deliberately written out so assignment
# count/window boundaries cannot be obscured by loop binding observation.
{
    echo 'x is [0]'
    i=1
    while [ "$i" -le 12 ]; do
        echo "x[0] is $i"
        echo 'x is x'
        i=$((i + 1))
    done
    echo 'print of converged of x'
    echo 'print of stable of x'
} >"$TMP/list.eigs"
[ "$("$EIGS" "$TMP/list.eigs")" = "false
false" ]

# Exercise every mutable representation in one recursively mixed snapshot.
{
    printf '%s\n' 'b is buffer of 1' 't is text_builder_new of null' \
        'x is {"list": [0], "dict": {"v": 0}, "buffer": b, "builder": t}'
    i=1
    while [ "$i" -le 12 ]; do
        printf '%s\n' "x[\"list\"][0] is $i" \
            "x[\"dict\"][\"v\"] is $i" "b[0] is $i" \
            'text_builder_append of [t, "x"]' 'x is x'
        i=$((i + 1))
    done
    printf '%s\n' 'print of converged of x' 'print of stable of x'
} >"$TMP/nested.eigs"
[ "$("$EIGS" "$TMP/nested.eigs")" = "false
false" ]

# Values beyond the cap are reported rather than compared by reference.
{
    printf 'x is "'
    i=0
    while [ "$i" -lt 4097 ]; do
        printf 'x'
        i=$((i + 1))
    done
    printf '"\n'
    i=0
    while [ "$i" -lt 12 ]; do echo 'x is x'; i=$((i + 1)); done
    printf '%s\n' 'print of converged of x' 'print of stable of x'
} >"$TMP/oversize.eigs"
[ "$("$EIGS" "$TMP/oversize.eigs")" = "false
false" ]

cat >"$TMP/mixed-on.eigs" <<'EOF'
x is [1]
x is [true]
print of report of x
print of converged of x
print of stable of x
print of "mixed-ok"
EOF
[ "$("$EIGS" "$TMP/mixed-on.eigs")" = "equilibrium
false
false
mixed-ok" ]
printf '%s\n' 'x is [1]' 'x is [true]' 'print of "mixed-ok"' >"$TMP/mixed-off.eigs"
[ "$("$EIGS" "$TMP/mixed-off.eigs")" = "mixed-ok" ]

# A dead predicate read opens the observer gate without retaining the closure.
cat >"$TMP/closure.eigs" <<'EOF'
define outer as:
    define inner as:
        return 1
    f is inner
    if false:
        print of converged of f
    return 0
for i in range of 100:
    outer of null
print of "closure-ok"
EOF
STATS=$(EIGS_ALLOC_STATS=1 "$EIGS" "$TMP/closure.eigs" 2>&1)
printf '%s\n' "$STATS" | grep -q '^closure-ok$'
printf '%s\n' "$STATS" | grep -Eq '^eigs-alloc-stats: cumulative=[0-9]+ live=0 peak=[0-9]+ tracked=0$'

echo observer-snapshot-fix2-ok
