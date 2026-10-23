# ROW: N5.net-send-byte-raises
# ITEMS: N5
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS:
# R1.6d-D1 / RULINGS C7: invalid byte payloads send no prefix.
# R1.6f-D2: the raw stored-byte socketpair fixture is the mechanical gate
# gate.N5.net-byte-boundary (tools/phase2_readers.sh), built once outside
# this row's per-tier 30 s timeout.
set -eu
binary=$1
case "$binary" in */build/release/eigenscript) binary="${binary%/release/eigenscript}/server/eigenscript" ;; esac
[ -x "$binary" ] || { echo "missing matched server binary: $binary" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/bytes.eigs" <<'EIGS'
listener is net_listen of 0
client is net_dial of ["127.0.0.1", net_port of listener]
peer is net_accept of [listener, 2000]
for bad in [256, 1.5]:
    b is buffer of 2
    b[0] is 65
    b[1] is bad
    try:
        answer is net_send of [client, b]
        print of ["buffer", bad, "accepted"]
    catch e:
        print of ["buffer", bad, e.kind]
    try:
        answer is net_send of [client, [65, bad]]
        print of ["list", bad, "accepted"]
    catch e:
        print of ["list", bad, e.kind]
n is net_send of [client, [111.0, 107.0]]
print of [n, num_type of n]
print of (str_from_bytes of (net_recv of [peer, 64, 2000]))
net_close of client
net_close of peer
net_close of listener
EIGS
"$binary" "$tmp/bytes.eigs"
