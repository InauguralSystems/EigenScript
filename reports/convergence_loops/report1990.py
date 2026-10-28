#!/usr/bin/env python3
"""Render the checked-in #1990 measurements used by the documentation."""
import json
from pathlib import Path

p = Path(__file__).resolve().parent / "results" / "summary.json"
s = json.loads(p.read_text())
print("arm,W,exhausted_converging,W_ignored,median_iteration_ratio")
for arm, row in s["arms"].items():
    print("%s,%.6f,%.6f,%.6f,%s" % (arm, row["W"], row["exhausted_converging"],
          row["W_ignored"], row.get("median_iteration_ratio_to_STD-py", "")))
print("verdict," + s["verdict"])
