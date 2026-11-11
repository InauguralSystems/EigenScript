#!/usr/bin/env python3
"""Direct R33 port checks on handwritten windows only; no data files read."""
import math
import r33_port as P


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print(f"PORT UNIT {name}: ok")


def main():
    check("eleven policies", len(P.POLICIES) == 11 and len(set(P.POLICIES)) == 11)
    slot = P.Slot()
    slot.record(5.0)
    first = slot.reading()
    check("first observation", first["report"] == "equilibrium" and first["why"] is None and
          first["how"] is None and not first["quiet"] and first["count"] == 1)
    for _ in range(10):
        slot.record(5.0)
    reading = slot.reading()
    check("constant float", reading["converged"] and reading["stable"] and reading["equilibrium"] and
          reading["quiet"] and reading["how"] == 1.0 and reading["why_kind"] == "float")
    bits = []
    for policy in P.POLICIES:
        counter = P.Slot(policy)
        for i in range(11):
            counter.record(2**53 + i)
        answer = counter.reading()
        bits.append(tuple(answer[p] for p in ("converged", "stable", "diverging")))
        if policy == "F0":
            check("exact boxed scalar", answer["where"] == 2**53 + 10 and answer["why"] == 1 and
                  answer["where_kind"] == answer["why_kind"] == "int")
    check("exact rules in every arm", all(bit == (False, False, True) for bit in bits))
    overflow = P.Slot()
    overflow.record(-(2**63)).record(2**63 - 1)
    check("subtraction overflow is inexact", not overflow.all_exact() and
          overflow.reading()["why_kind"] == "float" and overflow.reading()["why"] == float(2**64 - 1))
    zeros = P.Slot("STD-rel")
    zeros.record(-0.0).record(0.0).record(1.0).record(0.0)
    check("STD zero rule", zeros.steps() == [0.0, 1.0, -1.0])
    zero_c = P.Slot("C_1e-6^hist")
    zero_c.record(0.0).record(-0.0)
    check("C zero guard", zero_c.steps() == [-0.0] and math.copysign(1.0, zero_c.steps()[0]) < 0.0)
    query = P.Slot("C_1e-2^win")
    query.record(1000.0).record(0.001).record(0.002)
    temporal = query.snapshot()
    for i in range(3, 13):
        query.record(i / 1000.0)
    check("C query peak", query.peak() == 0.012 and query.steps()[0] > 0.3)
    check("temporal snapshot", temporal["where"] == 0.002 and temporal["how"] > 0.9 and
          query.reading()["how"] < 0.02)
    hist = P.Slot("C_1e-2^hist")
    for value in [1000.0] + [i / 1000.0 for i in range(1, 13)]:
        hist.record(value)
    check("historical peak survives eviction", hist.peak() == 1000.0 and hist.steps()[0] < 0.001)
    exported = query.trajectory()
    exported["rel"] = [123.0] * len(exported["rel"])
    restored = P.Slot.from_trajectory(exported, "C_1e-2^win")
    check("C import ignores stored relatives", restored.steps() == query.steps())
    restored_hist = P.Slot.from_trajectory(hist.trajectory(), "C_1e-2^hist")
    check("historical peak carried on import", restored_hist.peak() == 1000.0 and
          restored_hist.steps() == hist.steps())
    ieee = P.Slot()
    ieee.record(math.inf)
    check("initial infinity", ieee.reading()["diverging"] and ieee.reading()["how"] is None)
    ieee.record(-math.inf)
    check("opposite infinity", ieee.reading()["oscillating"] and not ieee.reading()["diverging"] and
          ieee.reading()["how"] == 0.0)
    ieee.record(math.nan)
    check("NaN position", ieee.reading()["report"] == "undefined" and
          not any(ieee.reading()[p] for p in P.PREDS) and math.isnan(ieee.reading()["how"]))
    for _ in range(11):
        ieee.record(1.0)
    check("IEEE recovery", ieee.reading()["converged"] and ieee.reading()["stable"])
    print("PORT UNIT: 17 checks passed")


if __name__ == "__main__":
    main()
