# EigenScript

A programming language with native observer semantics, tensor math, and
selective-observation training.

## Install

```bash
git clone <repo-url> EigenScript
cd EigenScript
./install.sh
```

This builds a 96K binary and installs it to `~/.local/bin/eigenscript`.

Requires only `gcc` — no external dependencies.

## Run

```bash
eigenscript program.eigs
eigenscript --version
```

## The Language

```eigenscript
# Variables
x is 42
name is "hello"

# Functions take one argument (n)
define double as:
    return n * 2

print of (double of 21)

# Loops
for i in range of 10:
    print of i

# Lists
items is [1, 2, 3, 4, 5]
print of (len of items)

# Conditionals
if x > 0:
    print of "positive"
```

### Observer Semantics

Every value in EigenScript tracks its own change history:

```eigenscript
x is 10.0
x is 8.0
x is 6.0

status is report of x     # "improving"
state is observe of x     # [status, entropy, dH, prev_dH]
```

The runtime classifies value trajectories as: `improving`, `diverging`,
`stable`, `equilibrium`, `oscillating`, or `converged`.

### Tensor Math

```eigenscript
w is random_normal of [8, 32, 0.1]
h is matmul of [input, w]
h is leaky_relu of h
probs is softmax of h
```

Builtins: `matmul`, `add`, `subtract`, `multiply`, `divide`, `softmax`,
`log_softmax`, `relu`, `leaky_relu`, `zeros`, `random_normal`, `shape`,
`numerical_grad`, `sgd_update`, `tensor_save`, `tensor_load`.

### Arena Memory

```eigenscript
arena_mark of null       # save allocation point
# ... compute gradients, intermediates ...
arena_reset of null      # reclaim all transient allocations
```

Bounded computation for constrained environments.

## Examples

```bash
eigenscript examples/hello.eigs
eigenscript examples/basics.eigs
eigenscript examples/observer.eigs
eigenscript examples/tensors.eigs
```

## Test Suite

```bash
cd tests
./run_all_tests.sh    # 106/106
```

## Documentation

- [docs/SYNTAX.md](docs/SYNTAX.md) — full language reference

## Build from Source

```bash
./build.sh            # builds src/eigenscript
./install.sh          # builds and installs to ~/.local/bin
```

The binary is a single statically-linked C program with no runtime
dependencies.
