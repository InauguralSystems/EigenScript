# file: tests/test_handles_mt.sh
# Abort control: an oracle that dies must be KILLED-by-crash, never reported
# as a survivor (mechanical-gates §18).
s|^set -u$|set -u\nkill -ABRT $$|
