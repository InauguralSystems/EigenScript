# EigenScript Compiler Optimization Guide

## Overview

The EigenScript LLVM compiler supports four optimization levels (-O0 through -O3), each trading off compilation time, code size, and execution speed.

## Optimization Levels

### -O0: No Optimization (Default)
**When to use**: Development, debugging, fast iteration

**Features**:
- No optimization passes
- Fast compilation (~100-200ms)
- Largest binary size
- Slowest execution
- Easy to debug (source mapping preserved)

**Performance**: Baseline (1x)

---

### -O1: Basic Optimizations
**When to use**: Development builds with better performance

**Features**:
- Conservative function inlining (threshold: 75)
  - Only very small functions inlined
  - ~5-10% code size increase
- Basic dead code elimination
- Constant folding
- Algebraic simplifications

**Enabled passes**:
- Inline (conservative)
- Constant propagation
- Dead code elimination
- Mem2reg (promote stack to registers)

**Trade-offs**:
- Compile time: ~200-400ms (+100-200ms vs -O0)
- Code size: +5-10%
- Performance: **~1.5-2x faster** than -O0

---

### -O2: Standard Optimizations **[RECOMMENDED]**
**When to use**: Production builds, benchmarks, general use

**Features**:
- Balanced function inlining (threshold: 225)
  - Most small-to-medium functions inlined
  - ~10-30% code size increase
- **Loop vectorization** (SIMD)
  - Processes multiple iterations in parallel
  - 2-4x speedup for numeric loops
- **SLP vectorization** (straight-line code)
- Loop unrolling and interleaving
- All -O1 passes plus:
  - Global value numbering
  - Loop-invariant code motion
  - Aggressive dead code elimination

**Function attributes optimizations**:
- `nounwind` enables better tail call optimization
- `readonly` allows call reordering and elimination

**Trade-offs**:
- Compile time: ~400-800ms (+200-600ms vs -O1)
- Code size: +15-40%
- Performance: **~2-5x faster** than -O0, **~1.5-3x faster** than -O1

**Why recommended**:
- Best balance of speed and compile time
- Significant performance gains
- Moderate code size increase
- Vectorization crucial for EigenScript's numeric workloads

---

### -O3: Aggressive Optimizations
**When to use**: Maximum performance, benchmarking, long-running programs

**Features**:
- Aggressive function inlining (threshold: 375)
  - Even large functions inlined
  - Can cause 50-100% code size increase
- All -O2 passes with more iterations
- Function cloning and specialization
- More aggressive loop transformations

**Trade-offs**:
- Compile time: ~600-1200ms (+200-400ms vs -O2)
- Code size: +40-100%
- Performance: **~2-10x faster** than -O0, **~1.2-2x faster** than -O2

**Diminishing returns**:
- Much larger binaries
- Slightly longer compile times
- Often only 10-50% faster than -O2
- Can be slower due to instruction cache misses

---

## Function Attributes for Optimization

The compiler automatically adds these attributes to help the optimizer:

### Runtime Functions

| Function | Attributes | Optimization Benefit |
|----------|-----------|---------------------|
| `eigen_get_value()` | `nounwind`, `readonly` | Can be reordered, eliminated if unused, hoisted out of loops |
| `eigen_get_gradient()` | `nounwind`, `readonly` | Same as above |
| `eigen_update()` | `nounwind` | Can't unwind stack (better tail calls) |
| `malloc` | `nounwind` | Enables better code motion |

### User Functions

All EigenScript functions automatically get:
- **`nounwind`**: No exceptions in EigenScript, enables tail call optimization

---

## Inlining Thresholds

Function inlining is the most important optimization for EigenScript because:
1. Frequent runtime function calls (eigen_get_value, etc.)
2. Small user-defined functions
3. Interrogative expressions (`what is x`)

**Inlining thresholds** (in LLVM "cost units"):

| Level | Threshold | Example Functions Inlined |
|-------|-----------|-------------------------|
| O0 | None | None |
| O1 | 75 | Trivial getters (1-3 instructions) |
| O2 | 225 | Small functions (5-15 instructions) |
| O3 | 375 | Medium functions (15-25 instructions) |

**Example**: A simple function like `define double as: return n * 2` compiles to ~8 LLVM instructions, so it's inlined at -O2 and above.

---

## Vectorization (O2+)

EigenScript benefits greatly from vectorization for numeric code:

### Loop Vectorization
```eigenscript
# Before vectorization: 1 iteration per cycle
numbers is [1, 2, 3, 4, 5, 6, 7, 8]
loop for i in numbers:
    result is result + i  # Processes 1 number at a time

# After vectorization (O2+): 4 iterations per cycle (SSE) or 8 (AVX)
# LLVM emits SIMD instructions: addpd, mulpd, etc.
```

**Expected speedup**: 2-4x for arithmetic-heavy loops

### SLP Vectorization (Straight-Line code)
```eigenscript
# Multiple independent operations
a is x + y
b is x * y
c is x - y
d is x / y

# O2+ can vectorize these into a single SIMD operation
```

---

## Recommended Usage

### Development
```bash
eigenscript-compile program.eigs --exec
# Uses -O0 by default, fast iteration
```

### Testing
```bash
eigenscript-compile program.eigs --exec -O1
# Quick optimization pass
```

### Production
```bash
eigenscript-compile program.eigs --exec -O2
# Best balance, recommended for most uses
```

### Benchmarking
```bash
eigenscript-compile program.eigs --exec -O3
# Maximum performance, accept larger binaries
```

---

## Trade-off Summary

| Metric | O0 | O1 | O2 | O3 |
|--------|----|----|----|----|
| **Compile Time** | 100ms | 300ms | 600ms | 1000ms |
| **Code Size** | 1x | 1.1x | 1.3x | 1.7x |
| **Performance** | 1x | 1.7x | 3.5x | 4.5x |
| **Best For** | Debug | Dev | **Production** | Benchmarks |

*Note: Times/sizes are approximate and vary by program*

---

## Measuring Impact

To see the optimization impact:

```bash
# Compile with different levels
eigenscript-compile program.eigs --exec -O0
eigenscript-compile program.eigs --exec -O2

# Check code size
ls -lh program.exe

# Benchmark execution
time ./program.exe
```

Compare LLVM IR to see inlining:
```bash
eigenscript-compile program.eigs -O0  # Generates program.ll
eigenscript-compile program.eigs -O2 -o program_opt.ll
diff program.ll program_opt.ll
```

---

## Technical Details

### LLVM New Pass Manager

The compiler uses LLVM's New Pass Manager (NPM) with `PipelineTuningOptions`:

```python
pto = llvm.create_pipeline_tuning_options()
pto.speed_level = opt_level        # 0-3
pto.size_level = 0                 # Optimize for speed
pto.inline_threshold = 225         # Varies by level
pto.loop_vectorization = True      # O2+
pto.slp_vectorization = True       # O2+
pto.loop_interleaving = True       # O2+
pto.loop_unrolling = True          # O2+
```

### Target Machine

Optimizations are target-aware:
```python
target = llvm.Target.from_default_triple()
target_machine = target.create_target_machine()
```

This enables:
- CPU-specific instruction selection
- Architecture-specific vectorization (SSE, AVX, NEON)
- Register allocation tuned for target

---

## Future Optimizations

Planned improvements:
1. **Link-Time Optimization (LTO)**: Optimize across compilation units
2. **Profile-Guided Optimization (PGO)**: Optimize based on runtime profiles
3. **Lazy geometric tracking**: Only create EigenValue when interrogated
4. **Memoization**: Cache results of pure functions

---

**Last Updated**: 2025-11-21
**Status**: Production ready, all optimization levels tested
