# ROW: N14.store-exact-digits
# ITEMS: N14
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS: 
set -eu
bin=$1
scratch=$(mktemp -d /tmp/eigs-r17-store.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
rm -rf "$scratch/db"
cat > "$scratch/p.eigs" <<'EOF'
s is store_open of (env_get of "R17_STORE_PATH")
k is store_put of [s, "c", {"v": 1234567890123456, "f": 0.1 + 0.2, "t": 9007199254740991}]
r is store_get of [s, "c", 1]
print of [r["v"] == 1234567890123456, r["f"] == 0.1 + 0.2, r["t"] == 9007199254740991]
store_close of s
EOF
R17_STORE_PATH="$scratch/db" "$bin" "$scratch/p.eigs"
