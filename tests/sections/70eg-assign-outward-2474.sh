section "[70eg] Assignment remains outward whatever a function reads (#2474)"
out=$(python3 ../tests/test_assign_outward_2474.py 2>&1)
rc=$?
printf '%s\n' "$out"
if rc_ok "$rc" "$out" && grep -qxF 'examined=3204 failed=0' <<< "$out"; then
    pass "assignment-outward matrix"
else
    fail "assignment-outward matrix"
fi
