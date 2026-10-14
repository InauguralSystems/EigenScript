"""What a corpus row MEANS: its generator (#1746).

A certificate carries the sha256 of this file and of certify.py
(derive.code_hash), so changing how a row is generated, ENV included, makes
every certificate stale until certify.py is re-run.
"""
import math
import random

INT64_MIN = -2 ** 63
RANDOM_KINDS = ("noise", "walk")        # realizations of random processes
IN_PROGRAM = ("affine", "pieces")       # the runtime computes x * a + b itself


class HarnessError(Exception):
    pass


# Corpus expressions are checked-in repo data (not user input), evaluated
# with no builtins, compiled once into a function of n (closed) or x, n (recur).
ENV = {"__builtins__": {}, "math": math,
       "step": lambda n, c: 1.0 if n >= c else 0.0}    # certify.py: Heaviside(n - c + 1/2)


def fn(gen):
    args = "n" if gen["kind"] == "closed" else "x, n"
    return eval(f"lambda {args}: ({gen['expr']})", ENV)


def pieces(gen):
    """affine is one piece; a pieces row lists them. A piece with x0 starts
    by assigning it; every piece but the last runs `steps` steps."""
    if gen["kind"] == "affine":
        return [{k: gen[k] for k in ("x0", "a", "b")}]
    return gen["pieces"]


def program(gen, n):
    """An in-program row's assignments x_0..x_n as the runtime runs them:
    ("set", v) assigns the literal v, ("aff", a, b) computes x * a + b."""
    steps = []
    for p in pieces(gen):
        if "x0" in p:
            steps.append(("set", p["x0"]))
        steps += [("aff", p["a"], p["b"])] * p.get("steps", n + 1)
        if len(steps) > n:
            break
    return steps[:n + 1]


def generate(gen, n):
    """The row's values x_0..x_n: floats (IEEE: they may overflow to inf or
    become NaN), or exact Python ints for an int row."""
    k, num = gen["kind"], (int if gen.get("int") else float)
    if k in IN_PROGRAM:
        xs = []
        for s in program(gen, n):
            xs.append(num(s[1]) if s[0] == "set" else xs[-1] * s[1] + s[2])
    elif k == "closed":
        f = fn(gen)
        xs = [f(i) for i in range(n + 1)]
    elif k == "recur":
        f = fn(gen)
        xs = [gen["x0"]]
        for i in range(1, n + 1):
            xs.append(float(f(xs[-1], i)))
    elif k == "cycle":
        vs = gen["values"]
        xs = [vs[i % len(vs)] for i in range(n + 1)]
    elif k == "noise":
        rng = random.Random(gen["seed"])
        xs = [gen["center"] + gen["amp"] * rng.uniform(-1.0, 1.0) for _ in range(n + 1)]
    elif k == "walk":
        rng = random.Random(gen["seed"])
        xs = [gen["x0"]]
        for _ in range(n):
            xs.append(xs[-1] + (gen["step"] if rng.random() < 0.5 else -gen["step"]))
    else:
        raise HarnessError(f"unknown generator kind {k!r}")
    if num is int and any(not isinstance(v, int) or not INT64_MIN <= v < 2 ** 63 for v in xs):
        raise HarnessError(f"an int row must generate int64 values: {gen}")
    return [num(v) for v in xs]
