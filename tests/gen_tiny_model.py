#!/usr/bin/env python3
"""
Generate a tiny v2-format transformer model for smoke testing.
Produces a JSON model file the full-build eigenscript runtime can load.

Usage:
  python3 tests/gen_tiny_model.py > /tmp/tiny_model.json

Model shape: vocab=8, d_model=4, n_layers=1, d_ff=8, max_seq_len=16
Weights are deterministic (seeded) small random values.
"""

import random
import json
import sys

random.seed(42)

def rand_2d(rows, cols, scale=0.1):
    return [[random.gauss(0, scale) for _ in range(cols)] for _ in range(rows)]

def rand_1d(n, scale=1.0):
    return [random.gauss(0, scale) if scale < 0.9 else 1.0 for _ in range(n)]

def ones_1d(n):
    return [1.0 for _ in range(n)]

def zeros_1d(n):
    return [0.0 for _ in range(n)]

VOCAB = 8
D_MODEL = 4
N_LAYERS = 1
D_FF = 8
MAX_SEQ = 16

model = {
    "format_version": 2,
    "weight_format": "ternary_weight_only",
    "config": {
        "vocab_size": VOCAB,
        "d_model": D_MODEL,
        "n_layers": N_LAYERS,
        "d_ff": D_FF,
        "max_seq_len": MAX_SEQ,
    },
    "token_embeddings": rand_2d(VOCAB, D_MODEL, 0.1),
    "output_proj": rand_2d(D_MODEL, VOCAB, 0.1),
    "layers": [
        {
            "w_q": rand_2d(D_MODEL, D_MODEL, 0.1),
            "w_k": rand_2d(D_MODEL, D_MODEL, 0.1),
            "w_v": rand_2d(D_MODEL, D_MODEL, 0.1),
            "w_o": rand_2d(D_MODEL, D_MODEL, 0.1),
            "w_ff1": rand_2d(D_MODEL, D_FF, 0.1),
            "w_ff2": rand_2d(D_FF, D_MODEL, 0.1),
            "ln1_gamma": ones_1d(D_MODEL),
            "ln1_beta": zeros_1d(D_MODEL),
            "ln2_gamma": ones_1d(D_MODEL),
            "ln2_beta": zeros_1d(D_MODEL),
        }
        for _ in range(N_LAYERS)
    ],
}

json.dump(model, sys.stdout, indent=2)
