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

A complete, standalone programming language with native observer semantics,
real concurrency, a 44-widget GUI toolkit, embedded database, tensor math,
and a 49-module standard library (14 STEM) — all in a single zero-dependency C binary.

## Install

```bash
git clone https://github.com/InauguralSystems/EigenScript.git
cd EigenScript
./install.sh
```

This builds a ~420K minimal binary and installs it to `~/.local/bin/eigenscript`.

Requires only `gcc` — no external dependencies.
Run `./install.sh full` to also build the optional HTTP/DB/model binary
(`eigenscript-full`); that path requires PostgreSQL development headers.

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

# String interpolation
print of f"Hello {name}, x is {x}"

# Loops
for i in range of 10:
    print of i

# Lists
items is [1, 2, 3, 4, 5]
print of (len of items)

# Conditionals
if x > 0:
    print of "positive"

# Dictionaries
person is {"name": "Alice", "age": 30}
print of person.name

# Closures
define make_adder(n) as:
    define inner(x) as:
        return x + n
    return inner

add5 is make_adder of 5
print of (add5 of 10)    # 15

# Error handling
try:
    result is risky_operation of data
catch e:
    print of f"Error: {e}"
```

### Ask Your Code

Every value quietly remembers how it has been changing — and you don't pay
for it until you ask. Six questions, in plain English:

```eigenscript
signal is 10
signal is 14
signal is 15

what is signal     # 15        — the value now
who is signal      # "signal"  — the name you gave it
when is signal     # 3         — how many times it has been set
where is signal    # ~0.34     — how much information it carries
why is signal      # ~-0.016   — how fast that information is changing
```

(`how` is the sixth interrogative; see the observer guide for its current
semantics.)

The runtime also classifies each value's trajectory, so a value can tell
you when it has settled instead of you writing epsilon checks by hand:

```eigenscript
loss is 50.0
loop while not converged:     # exits on its own once loss settles
    loss is loss * 0.5
report of loss                # "converged"  (after 20 steps, loss ~ 0)
```

```eigenscript
reading is 5.0
reading is 2.0
reading is 5.0
reading is 2.0
report of reading             # "oscillating"
```

Trajectory states: `converged`, `stable`, `equilibrium`, `oscillating`,
`improving`, `diverging` — handy for convergence detection, instability
alerts, or debugging without writing logging code.

> **What `improving` and the rest actually mean.** EigenScript's observer
> rests on a specific idea — a value locating itself *from the inside*,
> with no external goal — so the trajectory words don't always match a
> naive "smaller is better" reading. The full model, including the
> resolution knob (`set_observer_thresholds`), is in
> [docs/OBSERVER.md](docs/OBSERVER.md).

### Don't Ask — `unobserved`

The observer runs on every assignment so interrogations are always
cheap. When you know a hot region won't be interrogated, opt out:

```eigenscript
unobserved:
    game.px is game.px + game.vx * DT
    game.py is game.py + game.vy * DT
```

Inside the block, numeric assignments mutate the existing `Value` in
place (identity preserved) and the observer is skipped. Outside,
normal behavior resumes. ~22% faster on a mutation-heavy hot loop.

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

EigenScript numbers are finite by construction. Operations that would create
`NaN` return `0`; operations that would overflow to infinity saturate at
`+/-1e308`; domain-limited functions clamp their inputs where appropriate
(`asin`, `acos`) or return a boundary value (`sqrt of -1` -> `0`).

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
| `lib/text_builder.eigs` | `text_builder_new`, `text_builder_append`, `text_builder_append_line`, `text_builder_to_string` |
| `lib/int_vector.eigs` | `int_vector_new`, `int_vector_filled`, `int_vector_from_list`, `int_vector_copy` |
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
| `lib/data.eigs` | `df_from_csv`, `df_select`, `df_where`, `df_sort_by`, `df_join`, `df_group_by` |
| `lib/stats.eigs` | `mean`, `median`, `std_dev`, `variance`, `histogram`, `correlation`, `describe` |
| `lib/concurrent.eigs` | `future`, `await_all`, `parallel_map`, `parallel_each`, `worker_pool` |
| `lib/store.eigs` | `open`, `put`, `get`, `find`, `upsert`, `bulk_put`, `to_dataframe` |
| `lib/ui.eigs` | 44-widget GUI toolkit (buttons, sliders, tables, charts, trees, etc.) |
| `lib/physics.eigs` | Kinematics, forces, waves, thermodynamics, EM, optics, relativity, quantum |
| `lib/chemistry.eigs` | Periodic table, molecular weight, stoichiometry, gas laws, pH, Gibbs |
| `lib/biology.eigs` | Population dynamics, genetics, DNA/RNA/codons, enzyme kinetics, ecology |
| `lib/engineering.eigs` | Unit conversion, DFT/signal processing, PID, structural, electrical |
| `lib/earth_science.eigs` | Atmosphere, seismology, oceanography, astronomy, climate |
| `lib/linalg.eigs` | Matrices, vectors, determinant, inverse, linear solve, eigenvalues |
| `lib/calculus.eigs` | Derivatives, integrals, root finding, ODEs (Euler, RK4), Taylor series |
| `lib/probability.eigs` | Binomial, Poisson, normal, exponential distributions, Bayesian inference |
| `lib/optimize.eigs` | Observer-aware gradient descent, simulated annealing, genetic algorithm |
| `lib/simulation.eigs` | Observer-aware spring-mass, Lotka-Volterra, heat equation, equilibrium detection |
| `lib/numerics.eigs` | Jacobi/Gauss-Seidel solvers, power iteration — observer convergence |
| `lib/experiment.eigs` | Measurement stability, entropy spike detection, regime classification |
| `lib/geometry.eigs` | Points, vectors, triangles, polygons, convex hull, circles, transforms |
| `lib/lab.eigs` | Experiment management, data collection with observer feedback, CSV export |
| `lib/audio.eigs` | `play_note`, `note_freq`, `play_chord`, drum synthesis |
| `lib/eigen.eigs` | Meta-circular interpreter — full language parity, debug hooks |

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

# STEM simulations
eigenscript examples/stem/orbital_mechanics.eigs   # Kepler orbits via RK4
eigenscript examples/stem/climate_model.eigs       # energy balance, CO2 sensitivity
eigenscript examples/stem/genetic_drift.eigs       # Wright-Fisher population genetics
eigenscript examples/stem/signal_analysis.eigs     # DFT frequency detection
eigenscript examples/stem/greenhouse_controller.eigs # closed-loop STEM controller
```

## Test Suite

```bash
cd tests
./run_all_tests.sh    # 1257/1257 (minimal build; full build adds HTTP/DB/model suites)
```

## Documentation

- [docs/SYNTAX.md](docs/SYNTAX.md) — language reference
- [docs/GRAMMAR.md](docs/GRAMMAR.md) — formal EBNF grammar
- [docs/BUILTINS.md](docs/BUILTINS.md) — 150+ builtin functions (130 core + 20 extensions)
- [docs/STDLIB.md](docs/STDLIB.md) — standard library guide
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) — error format and exit codes
- [docs/TRACE.md](docs/TRACE.md) — execution trace, deterministic replay, temporal interrogatives

## Build from Source

```bash
make                  # build
make test             # build and run 1257 tests
make gfx              # build with SDL2 graphics (UI toolkit, games)
make install          # install to ~/.local/bin
make clean            # remove build artifacts
```

Or use the shell scripts directly: `./build.sh` and `./install.sh`.

The minimal binary is a single C program with no runtime dependencies.
