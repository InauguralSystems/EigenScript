#!/usr/bin/env python3
"""Black-box coverage for #1886's full-width seed mapping."""

import os
import random
import subprocess
import tempfile

eigs = os.environ.get("EIGS", os.path.join(os.path.dirname(__file__), "..", "src", "eigenscript"))


def draws(seeds):
    with tempfile.NamedTemporaryFile("w", suffix=".eigs", delete=False) as source:
        path = source.name
        for seed in seeds:
            source.write(f"seed_random of {seed}\nprint of random of null\n")
    try:
        result = subprocess.run([eigs, path], text=True, capture_output=True, check=True)
    finally:
        os.unlink(path)
    if result.stderr:
        raise RuntimeError(f"candidate wrote stderr: {result.stderr}")
    return result.stdout.splitlines()


def require_pairs_differ(pairs, label):
    values = draws([seed for pair in pairs for seed in pair])
    for index, pair in enumerate(pairs):
        if values[index * 2] == values[index * 2 + 1]:
            raise AssertionError(f"{label}: seeds {pair[0]} and {pair[1]} collided")


fixed = [(1, 4294967297), (2**53, 2**53 + 2**32), (-1, 2**32 - 1)]
require_pairs_differ(fixed, "required pair")
print("PASS: seeds differing only above bit 31 select different streams")

rng = random.Random(1886)
random_pairs = []
for _ in range(5000):
    low = rng.randrange(2**32)
    high_a, high_b = rng.sample(range(-(2**31), 2**31), 2)
    random_pairs.append(((high_a << 32) | low, (high_b << 32) | low))
require_pairs_differ(random_pairs, "random upper-half pair")
print("PASS: 5000 random upper-half seed pairs select different streams")

bit_pairs = []
for bit in range(64):
    for _ in range(20):
        bits = rng.randrange(2**64)
        other = bits ^ (1 << bit)
        signed = lambda value: value if value < 2**63 else value - 2**64
        bit_pairs.append((signed(bits), signed(other)))
require_pairs_differ(bit_pairs, "bit influence")
print("PASS: every one of 64 seed bits changes 20 random streams")
