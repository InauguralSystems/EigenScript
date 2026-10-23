# ROW: N5.http-port-before-config
# ITEMS: N5
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS:
# C6: invalid effective port refuses before changing configuration state.
set -eu
binary=$1
case "$binary" in */build/release/eigenscript) binary="${binary%/release/eigenscript}/server/eigenscript" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/port.eigs" <<'EIGS'
for name in ["http_early_bind", "http_serve"]:
    try:
        if name == "http_serve":
            http_serve of 0
        else:
            http_early_bind of 0
        print of "accepted-invalid-port"
        exit of 0
    catch e:
        print of [name, e.kind]
    print of (http_route of ["GET", "/" + name, "ok"])
EIGS
PORT=65536 "$binary" "$tmp/port.eigs"
