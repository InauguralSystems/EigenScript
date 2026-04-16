<p align="center">
  <img src="logo.png" alt="EigenScript" width="300">
</p>

<p align="center">
  <a href="https://github.com/InauguralSystems/EigenScript/actions/workflows/ci.yml"><img src="https://github.com/InauguralSystems/EigenScript/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/InauguralSystems/EigenScript/releases/latest"><img src="https://img.shields.io/github/v/release/InauguralSystems/EigenScript" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/InauguralSystems/EigenScript" alt="License"></a>
  <a href="https://github.com/InauguralSystems/EigenScript/stargazers"><img src="https://img.shields.io/github/stars/InauguralSystems/EigenScript" alt="Stars"></a>
</p>

# EigenScript

A programming language with native observer semantics, tensor math, and
selective-observation training.

## Install

```bash
git clone https://github.com/InauguralPhysicist/EigenScript.git
cd EigenScript
./install.sh
```

This builds a 96K binary and installs it to `~/.local/bin/eigenscript`.

Requires only `gcc` — no external dependencies.

## Run

```bash
eigenscript program.eigs    # run a script
eigenscript                 # interactive REPL
eigenscript --version
```

## The Language

```eigenscript
# Variables
x is 42
name is "hello"

# Functions with named parameters
define add(a, b) as:
    return a + b

print of (add of [3, 4])

# Single-argument functions (classic style)
define double as:
    return n * 2

print of (double of 21)

# String interpolation
print of f"Hello {name}, {x} doubled is {double of x}"

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
| `lib/observer.eigs` | `is_converged`, `is_stable`, `entropy_of`, `track_regimes`, `snapshot` |
| `lib/tensor.eigs` | `xavier_init`, `he_init`, `linear`, `mse_loss`, `cross_entropy_loss`, `accuracy` |
| `lib/io.eigs` | `read_lines`, `write_lines`, `read_csv`, `write_csv`, `slurp` |
| `lib/json.eigs` | `json_get`, `json_has`, `json_merge`, `json_from_pairs`, `json_pretty` |
| `lib/test.eigs` | `assert_eq`, `assert_near`, `assert_true`, `test_summary` |
| `lib/format.eigs` | `fmt_num`, `fmt_percent`, `fmt_bar`, `fmt_table`, `fmt_padded` |
| `lib/sort.eigs` | `sort_asc`, `sort_desc`, `sort_by`, `sorted_indices`, `unique` |
| `lib/map.eigs` | `map_new`, `map_get`, `map_set`, `map_has`, `map_keys`, `map_merge` |
| `lib/functional.eigs` | `chain`, `apply_all`, `complement`, `when`, `iterate`, `times` |
| `lib/args.eigs` | `parse_args`, `get_flag`, `get_opt`, `get_positional`, `require_opt` |
| `lib/datetime.eigs` | `now`, `today`, `timestamp`, `elapsed`, `timer_start`, `sleep_ms` |
| `lib/config.eigs` | `load_env_file`, `load_ini`, `config_get`, `env_or`, `config_section` |
| `lib/set.eigs` | `set_from`, `union`, `intersect`, `difference`, `is_subset`, `set_equal` |
| `lib/log.eigs` | `log_debug`, `log_info`, `log_warn`, `log_error`, `log_level` |
| `lib/validate.eigs` | `is_number`, `is_email`, `in_range`, `is_one_of`, `validate_all` |
| `lib/http.eigs` | `http_get`, `http_post_json`, `route_get`, `parse_query`, `json_response` |
| `lib/queue.eigs` | `enqueue`, `dequeue`, `push`, `pop`, `pq_push`, `pq_pop` |
| `lib/state.eigs` | `sm_new`, `sm_add_transition`, `sm_send`, `sm_state`, `sm_history` |
| `lib/template.eigs` | `render`, `render_file`, `render_each`, `fill` |
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
