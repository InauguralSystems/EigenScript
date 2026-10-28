#!/usr/bin/env python3
"""Shared native-tier witness from EIGS_JIT_HOT and EIGS_DUMP_BC."""
from __future__ import annotations

from dataclasses import dataclass
import re


@dataclass(frozen=True)
class NativeWitness:
    witnessed: bool
    detail: str
    at: int
    back_edge: int
    back_edge_exits: int
    ops: dict[int, tuple[str, str]]


def native_witness(tier: str, function: str, dump: str, hot: str) -> NativeWitness:
    """Prove the named function's JIT/OSR thunk exited past its sole loop.

    Raises ValueError when the diagnostics do not contain exactly the shape
    needed by the predicate.  An OSR success witnesses its last iteration
    only; callers are responsible for retaining that #1768 qualification.
    """
    if tier not in ("jit", "osr"):
        raise ValueError(f"unsupported native tier {tier!r}")
    hrow = next((fields for fields in (line.split() for line in hot.splitlines())
                 if fields[:1] == [function]), None)
    section = re.search(rf"^=== [^\n]*\({re.escape(function)}, [^\n]*\n"
                        r"((?:\d{4,} [^\n]*\n?)*)", dump, re.M)
    ops = ({int(offset): (opcode, argument) for offset, opcode, argument in
            re.findall(r"^(\d{4,}) \[L\d+\] (\S+) *(\S*)", section.group(1), re.M)}
           if section else {})
    back_edges = [offset for offset, (opcode, _argument) in ops.items()
                  if opcode == "JUMP_BACK"]
    # The final three aggregate OSR-slot columns were appended in #1606.
    # Keep accepting historical 12-field captures: they remain useful as
    # saved differential/oracle evidence and the fields used below retain
    # their positions in both shapes.
    if hrow is None or len(hrow) not in (12, 15) or len(back_edges) != 1:
        raise ValueError(f"no EIGS_JIT_HOT row for {function}, or not exactly one loop "
                         "in its EIGS_DUMP_BC listing; cannot witness the tier")
    back_edge = back_edges[0]
    try:
        back_edge_exits = int(hrow[7])
        if tier == "jit":
            advance = hrow[4] if hrow[2] == "yes" else "-1"
            at = int(hrow[5]) if advance == "RET" else int(advance) if advance.isdigit() else -1
            witnessed = at > back_edge and back_edge_exits == 0
        else:
            head = back_edge + 3 - int(ops[back_edge][1])
            at = (int(hrow[10]) + int(hrow[9])
                  if hrow[8] == "yes" and int(hrow[10]) == head else -1)
            witnessed = at > back_edge
    except (KeyError, ValueError) as error:
        raise ValueError(f"malformed EIGS_JIT_HOT/bytecode row for {function}: {error}") from error
    stop = (f"{ops[at][0]}@{at}" if at in ops else
            f"the end of {function} ({at})" if at >= 0 else "no thunk")
    if witnessed:
        detail = f"exits at {stop}, past the back-edge at {back_edge}"
    else:
        detail = f"stops at {stop} (bked={back_edge_exits}), before the back-edge at {back_edge}"
    return NativeWitness(witnessed, detail, at, back_edge, back_edge_exits, ops)
