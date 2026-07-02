# Freestanding dependency ledger

What the EigenScript runtime borrows from the host OS, and what it must do
instead to run **freestanding** — no libc, no kernel underneath — as the userland
of [EigenOS](https://github.com/InauguralSystems/EigenOS). This is a planning
ledger (like EigenGauntlet's `GAPS.md`), not a build that exists yet: it turns
"port EigenScript to bare metal" from a vibe into a finite checklist.

The guiding idea: freestanding doesn't *add features*, it forces the runtime to
**own its substrate** (heap, math, the I/O seam) instead of inheriting it from
Linux. Most of the surface either gets built once, dropped, or evaporates under
the right build flags.

## How this was measured

The minimal build (`make` → `src/eigenscript`, **v0.21.2**) imports **134**
external symbols from `libc`/`libm`/`pthread`. Regenerate:

```bash
make
nm -D -u src/eigenscript | awk '{print $2}' | sed 's/@.*//' | sort -u
```

Shared libs: `libc.so.6`, `libm.so.6` (and the dynamic loader). No `libpthread`
split (glibc 2.34+ folds it into libc); no networking symbols in the minimal
build (those live in the optional HTTP extension).

## Disposition legend

| | meaning |
|---|---|
| **ROOT** | an *irreducible* primitive — touches hardware or the kernel seam (or is a libm kernel). The real per-platform substrate; implement once per platform. |
| **ORDINARY** | a *derived* form, pure portable composition over the roots — a write-once mini-libc/libm, the *same* code hosted or bare-metal. **Not** per-platform work. |
| **HAL** | the named seam the ROOT primitives are reached through (the kernel implements it). |
| **DROP** | compile out — not present in the freestanding profile |
| **ELIM** | disappears under freestanding build flags / our own `_start` |
| **HARDEN** | exists but is young; firm it up *before* it's load-bearing |

**The key distinction (and the correction to a flat reading of this ledger):**
the 134 symbols are *not* 134 things to build. They reduce to ~10 **ROOT**
families — the substrate that genuinely differs per platform — and a large body
of **ORDINARY** derived forms that are portable C written once. Below, each
subsystem names its root(s); the rest of its symbols are ordinary forms over
them.

## The roots (the real freestanding substrate)

| root | reached via | the ordinary forms it generates |
|---|---|---|
| `page_alloc` / `page_free` | HAL (physical pages) | `malloc` `calloc` `realloc` `free` (a heap over pages) |
| `console_write(bytes)` | HAL (VGA/serial) | the whole `printf`/`fputs`/`puts`/`putc`/`fwrite`/`write` family + `vsnprintf` formatter |
| `read_char` | HAL (PS/2) | `fgets` `fgetc` `read` |
| `clock_ns` | HAL (TSC/PIT) | `clock_gettime` `time` `usleep` |
| `spawn` / `yield` / `park`+`unpark` + atomic CAS | HAL (scheduler) | `pthread_mutex_*` `pthread_cond_*` `pthread_once` |
| `map_exec` (RX pages) | HAL (deferrable) | `mmap` `mprotect` `munmap` |
| entropy (`RDRAND`/TSC) | HAL/hardware | `rand` `srand` `drand48` `lrand48` `srand48` |
| `halt` / `panic` | HAL | `exit` `_exit` `abort` `atexit` |
| `memcpy` `memset` `memcmp` | compiler/hardware intrinsic (near-root) | the rest of `mem*`/`str*` byte ops |
| libm kernels: `exp` `log` `sin`/`cos` core `atan` core | BUILD (~4 fns) | `pow`=exp(y·log x), `log2`=log/log2, `tan`, `atan2`, `sqrt`, `acos`/`asin` |

Everything not in this table — `strlen`/`strcmp`/`strstr`/…, `strtod`/`strtol`
(parsers), `qsort`, ctype tables, the printf family, the pthread sync types, the
PRNG, the non-kernel libm — is **ORDINARY**: portable, platform-agnostic, write
once.

## Ledger

### Memory — `BUILD` (the root expansion)
`malloc` `calloc` `realloc` `free`
The whole refcount + arena + cycle-collector machinery bottoms out here. Bare
metal has no `malloc`: ship an allocator backed by physical pages the kernel
hands us. The arena is already a bump allocator (half done); the general heap is
the new piece, and everything else allocates through it. **Highest priority —
nothing else runs without it.**

### Math (libm) — `BUILD` subset (load-bearing, not optional)
`log` `log2` `pow` `sqrt` `exp` `sin` `cos` `tan` `asin` `acos` `atan` `atan2`
`fmod` `round`
`log2` is called by the **observer entropy formula** (`entropy_of_num`), so the
language's *defining feature* depends on libm — freestanding cannot just drop
math. Minimum for the core: `log2`, `fabs`. The rest back the STEM stdlib;
vendor a small libm or implement on demand.

### String / mem — `BUILD` tiny
`memcpy` `memmove` `memset` `memcmp` `strlen` `strcmp` `strncmp` `strchr`
`strrchr` `strstr` `strdup` `strncpy` `strtod` `strtol` `strtoul` `strtok_r`
`strerror`
A freestanding `string.h` is ~100 lines (gcc may inline some). `strtod`/`strtol`
(number parsing) are the only non-trivial ones. `strdup` allocates → routes
through the new heap.

### I/O: stdio + filesystem — `HAL` (output) + `DROP` (most of fs)
`open` `read` `write` `close` `lseek` `fopen` `fdopen` `fclose` `fread` `fwrite`
`fgets` `fgetc` `fputs` `fputc` `fflush` `fseek` `ftell` `setvbuf` `putc`
`putchar` `puts` `snprintf` `stat` `opendir` `readdir` `closedir` `mkdir`
`rmdir`-class `unlink` `remove` `rename` `access` `getcwd` `chdir` `readlink`
`mkstemp` `dup` `dup2` `pipe` `fcntl` `poll` `tcgetattr` `tcsetattr` `isatty`
The bulk of the surface, but mostly *not* reimplemented:
- **`HAL`**: `print`/console output → VGA + COM1 serial; `read_char` → PS/2
  keyboard. `snprintf` (string formatting) is `BUILD` (used internally).
- **`DROP`**: real filesystem ops, `pipe`/`dup`/`fcntl` (subprocess plumbing),
  `tcgetattr`/`poll` (terminal/multiplexing) — gone in the freestanding profile
  until there's a kernel FS to back them.

### Threading — `HAL` + `HARDEN`
`pthread_create` `pthread_join` `pthread_once` `pthread_mutex_*`
`pthread_cond_*` `pthread_condattr_*`
Route onto the kernel's own scheduler + sync primitives via the HAL. **But
harden first**: the threading/channel layer is the youngest part of the runtime
(#293 cross-thread channel UAF; the cycle collector is disabled once
multithreaded; spawn-thread programs leak — the ASan floor). Freestanding
threading on a custom scheduler will lean hardest on exactly this code, so it
should be solid before EigenOS depends on it. (EigenGauntlet's `concurrent` lab
is the standing pressure here.)

### Time — `HAL`
`clock_gettime` `time` `usleep` `pthread_condattr_setclock`
`monotonic_*`, the observer dH timing, deterministic-replay timestamps, and
`usleep` → PIT/TSC/HPET via the HAL.

### Executable memory (JIT) — `HAL`, deferrable
`mmap` `mprotect` `munmap`
The copy-and-patch JIT emits machine code and needs executable pages (W^X). On
bare metal the kernel must map RX pages on request. **Deferrable**: run
interpreter-only first (the WASM build already compiles the JIT out), add
exec-page support later. (`mmap` may also back large allocations — fold into the
heap/HAL.)

### Randomness — `BUILD` tiny
`rand` `srand` `random` `drand48` `lrand48` `srand48`
A small PRNG seeded from a hardware entropy source (`RDRAND`/`RDSEED` or TSC
jitter). Used by `random_int`/`randn`/stdlib.

### Process / signals — mostly `DROP`, a little `BUILD`
`fork` `vfork` `execvp` `waitpid` `kill` `signal` `getpid` `sysconf` `system`
`getenv` `exit` `_exit` `abort` `atexit`
- **`DROP`**: subprocess (`fork`/`execvp`/`waitpid`) and POSIX signals — no
  child processes on bare metal (yet).
- **`BUILD`/`ELIM`**: `exit`/`_exit`/`abort` → halt the CPU / panic; `getenv` →
  empty stub or a kernel config table; `atexit` → no-op.

### Regex — `DROP` → route to EigenRegex (the route now exists)
`regcomp` `regexec` `regfree`
The regex builtins use glibc ERE. Freestanding: drop the C builtins and load
**EigenRegex**'s `lib/regex_compat.eigs` (ERE-parity as of its S8, 2026-07-01) —
builtin-shaped drop-ins for `regex_match`/`regex_find`/`regex_replace` over the
pure-EigenScript Pike VM, differential-tested against these builtins as the
oracle. Documented divergences: POSIX leftmost-longest vs Pike-VM
leftmost-first, and no `\b`. The ecosystem feeding its own substrate.

### ctype / sort — `BUILD` tiny
`__ctype_b_loc` `__ctype_tolower_loc` `__ctype_toupper_loc` (`isalpha`/`toupper`
table accessors) · `qsort`
A static ctype table and a ~20-line `qsort` are trivial freestanding additions.

### C-runtime glue — `ELIM` (build flags / our own `_start`)
`__libc_start_main` `__errno_location` `__stack_chk_fail` `__cxa_atexit`
`__cxa_finalize` `__gmon_start__` `_ITM_registerTMCloneTable`
`_ITM_deregisterTMCloneTable` `__fprintf_chk` `__printf_chk` `__snprintf_chk`
`__vsnprintf_chk` `__realpath_chk` `__memcpy_chk`
None of these are real work — they vanish in a freestanding build:
- `__libc_start_main` — we provide our own `_start` (EigenOS already does).
- `*_chk` (the `__*printf_chk`/`__memcpy_chk` fortify wrappers) — disappear with
  `-U_FORTIFY_SOURCE` (or `-D_FORTIFY_SOURCE=0`).
- `__stack_chk_fail` — `-fno-stack-protector` (or a 2-line stub + a `__stack_chk_guard`).
- `__errno_location` — a single thread-local `errno`.
- `__cxa_atexit`/`__cxa_finalize`/`__gmon_start__`/`_ITM_*` — toolchain/profiling
  glue, weak and eliminable.

## Critical path (what's actually new code)

The real per-platform work is the **~10 roots above**, not the 134 symbols. In
rough order:

1. **The HAL seam itself** — the architectural change. A thin interface
   (`page_alloc`, `console_write`, `read_char`, `clock_ns`, `spawn`/`yield`,
   `map_exec`, entropy, `halt`) that POSIX satisfies when hosted and the EigenOS
   kernel satisfies on bare metal. Today the runtime talks to POSIX directly;
   there is no seam. Cutting it is the load-bearing move — every other root
   plugs into it.
2. **Page + heap allocator** over the `page_alloc` root (gates all allocation;
   the arena is already a bump allocator, the general heap is the new piece).
3. **~4 libm kernels** (`exp`, `log`, `sin`/`cos`, `atan`); `log2`/`fabs` first
   — the observer needs them.
4. **The ordinary mini-libc/libm** over the roots — string ops, `strtod`/
   `strtol`, `qsort`, ctype, PRNG, the printf family, pthread sync, derived math.
   Portable, **write once**, not per-platform; the bulk of the symbol count but
   the smaller share of the genuinely-hard work.
5. **Harden threading** (the scheduler roots) before it's load-bearing.
6. Defer: `map_exec`/the JIT (interpreter-only first), a filesystem, networking.

## Build profile (EXISTS since 2026-07-02)

The fourth profile beside `minimal` / `full` / `wasm`: **`freestanding`** —
compile with `-DEIGENSCRIPT_FREESTANDING=1`. It compiles out everything the
DROP rows above name: the filesystem builtins (incl. `load_file`/`import`,
which raise a profile-specific error), subprocess, terminal raw mode, libc
regex (route: EigenRegex's `regex_compat`), the page store, the trace-tape
file sinks, and the JIT (`EIGS_JIT_ENABLED` gates every arch check;
interpreter-only until the `map_exec` root exists). The entry point is
`eigs_embed.h` with **source strings** — `main.c` (the POSIX CLI) is not part
of the profile.

Two CI gates keep it honest:

- **`make freestanding-check`** (`tools/freestanding_check.sh`) — compiles the
  profile with `-ffreestanding -fno-stack-protector -U_FORTIFY_SOURCE`, links
  it relocatable, and fails if the undefined-symbol set contains anything
  outside `tools/freestanding_allowlist.txt` (the roots + mini-libc/libm
  table above, as machine-checked truth). Currently ~75 symbols, all within
  the allowlist.
- **`tools/freestanding_smoke.sh`** — builds a hosted binary of the profile
  behind an embed-API harness and proves the core language (functions, lists,
  dicts, f-strings, observer predicates) still runs while the carved surfaces
  fail loudly (undefined variable / profile-specific import error).

What remains before it links on bare metal is exactly the allowlist: the ~8
HAL roots implemented by the EigenOS kernel plus the write-once portable
mini-libc/libm — both testable hosted with glibc as the differential oracle.

## Standout findings

- **The observer depends on libm.** `entropy_of_num` → `log2`. The one place the
  *core language* (not a stdlib extension) couples to the host — only bare metal
  exposed it.
- **No net in minimal** — confirms the HTTP/DB surface is cleanly optional; the
  freestanding profile starts from `minimal`, not `full`.
- **Threading is the soft spot**, not by symbol count but by maturity — and it's
  precisely what a custom scheduler will exercise first.
- **The portfolio can feed its own substrate** — EigenRegex for regex; the same
  pattern (the consumer projects forging the language) applied at the metal.
