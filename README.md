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

## Standard Library

Pure EigenScript libraries under `lib/`:

| Module | Description |
|--------|-------------|
| `lib/math.eigs` | `abs`, `max_val`, `min_val`, `clamp`, `lerp`, `dot` |
| `lib/list.eigs` | `map`, `filter`, `reduce`, `reverse`, `zip`, `flatten` |
| `lib/string.eigs` | `join`, `repeat`, `pad_left` |
| `lib/sanitize.eigs` | `sanitize_text`, `is_garble`, `clean_response`, `check_openai` |
| `lib/auth.eigs` | `auth_login`, `auth_check`, `auth_logout`, `require_auth` |

```eigenscript
load_file of "lib/list.eigs"
doubled is map of [[1,2,3], double]
```

See [docs/STDLIB.md](docs/STDLIB.md) for the full library guide.

## Examples

Ordered as a learning path:

```bash
eigenscript examples/hello.eigs       # printing
eigenscript examples/basics.eigs      # variables, functions, loops, strings
eigenscript examples/fizzbuzz.eigs    # conditionals and modular arithmetic
eigenscript examples/fibonacci.eigs   # recursion
eigenscript examples/sort.eigs        # algorithms with list mutation
eigenscript examples/json_config.eigs # JSON data processing
eigenscript examples/stdlib_demo.eigs  # standard library (map, filter, reduce)
eigenscript examples/data_pipeline.eigs # combining libraries for real work
eigenscript examples/observer.eigs    # observer semantics (entropy, dH)
eigenscript examples/tensors.eigs     # tensor math, gradients, SGD
```

## Test Suite

```bash
cd tests
./run_all_tests.sh    # 121/121
```

## Documentation

- [docs/SYNTAX.md](docs/SYNTAX.md) — language reference
- [docs/BUILTINS.md](docs/BUILTINS.md) — 83 builtin functions
- [docs/STDLIB.md](docs/STDLIB.md) — standard library guide
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) — error format and exit codes

## Build from Source

```bash
./build.sh            # builds src/eigenscript
./install.sh          # builds and installs to ~/.local/bin
```

The binary is a single statically-linked C program with no runtime
dependencies.
