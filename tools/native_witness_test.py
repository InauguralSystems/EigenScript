#!/usr/bin/env python3
"""Regression tests for the shared native-tier diagnostic parser."""

from native_witness import native_witness


DUMP = """=== fixture (run_row, test)
1000 [L1] CONSTANT 0
1003 [L2] JUMP_BACK 3
1020 [L3] RETURN
"""


def check(row: str) -> None:
    proof = native_witness("jit", "run_row", DUMP, row)
    assert proof.witnessed, proof.detail
    assert proof.at == 1020


# Current shape: the oslots/ocomp/ofull aggregates append three fields.
check("run_row 1 yes 100.0% RET 1020 100.0% 0 no 0 0 RETURN 1 1 0")
# Saved pre-#1606 diagnostics remain valid evidence.
check("run_row 1 yes 100.0% RET 1020 100.0% 0 no 0 0 RETURN")
print("PASS: native witness accepts 15-field rows and legacy 12-field rows")
