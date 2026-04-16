#!/usr/bin/env python3
"""
Tiny mutation fuzzer for eigenscript.

Approach: take each valid .eigs file in examples/ and tests/, apply
a handful of random byte-level mutations, run the interpreter under
a short timeout, record:
  - normal exit / normal parse-error (expected)
  - signal (SIGSEGV, SIGABRT) — crash
  - timeout — potential infinite loop

Usage: python3 tools/fuzz.py <iterations>
"""
import os, sys, random, subprocess, tempfile, glob, signal

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "src", "eigenscript")
SEEDS = glob.glob(os.path.join(ROOT, "examples", "*.eigs")) + \
        glob.glob(os.path.join(ROOT, "tests", "*.eigs"))
TIMEOUT_S = 3
ITERS = int(sys.argv[1]) if len(sys.argv) > 1 else 200

OPS = ("flip", "delete", "insert", "dup", "swap", "chunk_repeat", "chunk_zero")

def mutate(data: bytes) -> bytes:
    b = bytearray(data)
    if not b:
        return b
    # Heavy-tailed mutation count: most are light, some aggressive
    r = random.random()
    if r < 0.6:
        n_mutations = random.randint(1, 4)
    elif r < 0.95:
        n_mutations = random.randint(5, 20)
    else:
        n_mutations = random.randint(50, 150)
    for _ in range(n_mutations):
        op = random.choice(OPS)
        i = random.randint(0, len(b) - 1)
        if op == "flip":
            b[i] = b[i] ^ (1 << random.randint(0, 7))
        elif op == "delete" and len(b) > 1:
            del b[i]
        elif op == "insert":
            b.insert(i, random.randint(0, 255))
        elif op == "dup":
            b.insert(i, b[i])
        elif op == "swap" and i + 1 < len(b):
            b[i], b[i+1] = b[i+1], b[i]
        elif op == "chunk_repeat":
            j = min(i + random.randint(4, 64), len(b))
            b[i:i] = b[i:j] * random.randint(2, 8)
        elif op == "chunk_zero":
            j = min(i + random.randint(4, 32), len(b))
            for k in range(i, j):
                b[k] = 0
    # Optional: truncate to a random prefix occasionally
    if random.random() < 0.1 and len(b) > 8:
        b = b[:random.randint(1, len(b))]
    return bytes(b)

def run_once(src: bytes):
    with tempfile.NamedTemporaryFile(suffix=".eigs", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        p = subprocess.run(
            [BIN, path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=TIMEOUT_S,
        )
        return p.returncode, p.stderr[:400]
    except subprocess.TimeoutExpired:
        return "TIMEOUT", b""
    finally:
        os.unlink(path)

def main():
    random.seed(0xE1E)
    crashes = []
    timeouts = []
    normal = 0
    errors = 0
    for i in range(ITERS):
        seed_path = random.choice(SEEDS)
        with open(seed_path, "rb") as f:
            orig = f.read()
        mutated = mutate(orig)
        rc, stderr = run_once(mutated)
        if rc == "TIMEOUT":
            timeouts.append((seed_path, mutated))
        elif isinstance(rc, int) and rc < 0:
            # negative rc means killed by signal N = -rc
            sig = -rc
            name = signal.Signals(sig).name if sig in signal.Signals._value2member_map_ else f"sig{sig}"
            crashes.append((seed_path, mutated, name, stderr))
        elif rc == 0:
            normal += 1
        else:
            errors += 1
        if (i + 1) % 50 == 0:
            print(f"  [{i+1}/{ITERS}] crashes={len(crashes)} timeouts={len(timeouts)} normal={normal} err={errors}")

    print()
    print(f"FUZZ DONE: {ITERS} iterations")
    print(f"  normal exit:     {normal}")
    print(f"  parse/runtime:   {errors}")
    print(f"  timeouts (>{TIMEOUT_S}s): {len(timeouts)}")
    print(f"  crashes (signal): {len(crashes)}")
    print()

    if crashes:
        print("=== CRASHES ===")
        for path, src, sig, stderr in crashes[:5]:
            print(f"\n-- from seed: {os.path.basename(path)} | signal: {sig}")
            print("--- mutated source (first 200 bytes) ---")
            try:
                print(src[:200].decode("utf-8", errors="replace"))
            except Exception:
                print(repr(src[:200]))
            print("--- stderr ---")
            print(stderr.decode("utf-8", errors="replace")[:300])
        if len(crashes) > 5:
            print(f"\n... {len(crashes) - 5} more crashes elided")
        # Save all crashing inputs
        outdir = os.path.join(ROOT, "tools", "fuzz-crashes")
        os.makedirs(outdir, exist_ok=True)
        for idx, (path, src, sig, _) in enumerate(crashes):
            with open(os.path.join(outdir, f"crash_{idx:04d}_{sig}.eigs"), "wb") as f:
                f.write(src)
        print(f"\nAll {len(crashes)} crashing inputs written to tools/fuzz-crashes/")

    return 1 if crashes else 0

if __name__ == "__main__":
    sys.exit(main())
