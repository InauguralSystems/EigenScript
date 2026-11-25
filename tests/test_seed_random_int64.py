#!/usr/bin/env python3
"""Black-box coverage for #1886's full-width seed mapping."""

import os
import random
import subprocess
import tempfile

eigs = os.environ.get("EIGS", os.path.join(os.path.dirname(__file__), "..", "src", "eigenscript"))


def draws(seeds, call="random of null"):
    with tempfile.NamedTemporaryFile("w", suffix=".eigs", delete=False) as source:
        path = source.name
        for seed in seeds:
            source.write(f"seed_random of {seed}\nprint of {call}\n")
    try:
        result = subprocess.run([eigs, path], text=True, capture_output=True, check=True)
    finally:
        os.unlink(path)
    if result.stderr:
        raise RuntimeError(f"candidate wrote stderr: {result.stderr}")
    return result.stdout.splitlines()


def require_pairs_differ(pairs, label, call="random of null"):
    values = draws([seed for pair in pairs for seed in pair], call)
    for index, pair in enumerate(pairs):
        if values[index * 2] == values[index * 2 + 1]:
            raise AssertionError(f"{label}: seeds {pair[0]} and {pair[1]} collided")


fixed = [(1, 4294967297), (2**53, 2**53 + 2**32), (-1, 2**32 - 1)]
require_pairs_differ(fixed, "required pair")
require_pairs_differ(fixed, "required pair, random_int",
                     "[random_int of [0, 1000000], random_int of [0, 1000000], random_int of [0, 1000000]]")
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

# The stream of a seed from 0 to 2^32-1 is POSIX srand48's: the first draw comes
# from the state (seed << 16 | 0x330E) stepped once. Computed here, not by the runtime.
def first(state):
    return ((0x5DEECE66D * state + 0xB) % 2**48) / 2**48


edges = [0, 1, 2, 255, 65535, 65536, 2**31 - 1, 2**31, 2**31 + 1, 2**32 - 2, 2**32 - 1]
edges += [rng.randrange(2**32) for _ in range(500)]
for seed, got in zip(edges, draws(edges)):
    if float(got) != first(seed << 16 | 0x330E):
        raise AssertionError(f"seed {seed} left its POSIX stream: {got}")
print(f"PASS: {len(edges)} seeds up to 2^32-1 keep the POSIX stream")


def mixed(seed):
    z = (seed + 0x9E3779B97F4A7C15) % 2**64
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) % 2**64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) % 2**64
    return (z ^ (z >> 31)) % 2**48


wide = [-1, -2, -2**63, 2**63 - 1, 2**32, 2**32 + 1, 2**53, 2**53 + 1]
wide += [rng.randrange(2**32, 2**63) for _ in range(250)] + [-rng.randrange(1, 2**63) for _ in range(250)]
for seed, got in zip(wide, draws(wide)):
    if float(got) != first(mixed(seed % 2**64)):
        raise AssertionError(f"seed {seed} left its mixed stream: {got}")
print(f"PASS: {len(wide)} seeds outside that range take the mixed state")
