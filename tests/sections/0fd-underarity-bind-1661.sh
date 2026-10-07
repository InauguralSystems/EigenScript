echo "[0fd] Under-arity parameter binding (#1661)"
# Every call entry null-fills an unsent parameter by name, with or without
# defaults. Before #1661 a defaults-free callee left it unbound: the JIT's
# unchecked GET_LOCAL read a stale freelist slot (heap-use-after-free, a
# malloc abort in release), and a closure resolved the name in an outer
# scope. Each program runs at the default tier, the interpreter tier and the
# forced-JIT tier (every chunk compiled on first entry).
for __u1661 in repro:"^ok$" \
               depth:"underarity depth: all passed" \
               trycatch:"underarity try/catch: all passed" \
               bind:"underarity bind: all passed" \
               jitcall:"underarity jit call: all passed" \
               dispatch_eval:"underarity dispatch fallback: all passed"; do
    __u1661_f="test_underarity_1661_${__u1661%%:*}.eigs"
    __u1661_m="${__u1661#*:}"
    check_eigs_suite "under-arity ${__u1661%%:*}: default tier" "$__u1661_f" "$__u1661_m"
    EIGS_JIT_OFF=1 check_eigs_suite "under-arity ${__u1661%%:*}: interpreter tier" "$__u1661_f" "$__u1661_m"
    EIGS_JIT_ENTRY_THRESHOLD=1 check_eigs_suite "under-arity ${__u1661%%:*}: forced-JIT tier" "$__u1661_f" "$__u1661_m"
done
unset __u1661 __u1661_f __u1661_m
echo ""
