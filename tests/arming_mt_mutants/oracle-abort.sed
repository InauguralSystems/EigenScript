# file: tests/test_arming_mt.sh
# Abort control: an oracle that dies must be KILLED-by-crash (§18).
s|^set -u$|set -u\nkill -ABRT $$|
