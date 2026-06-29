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
| **BUILD** | ship our own freestanding implementation (the real new code) |
| **HAL** | route through a platform interface the kernel implements (`print`, `read_char`, `clock`, `spawn`, exec-pages…) |
| **DROP** | compile out — not present in the freestanding profile |
| **ELIM** | disappears under freestanding build flags / our own `_start` |
| **HARDEN** | exists but is young; firm it up *before* it's load-bearing |

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

### Regex — `DROP` → reuse the ecosystem
`regcomp` `regexec` `regfree`
The regex builtins use glibc ERE. Freestanding: drop them, or route to
**EigenRegex** (the pure-EigenScript Pike-VM regex already in the portfolio) —
the ecosystem feeding its own substrate.

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

In rough order, the real freestanding work — far less than 134 symbols once
`DROP`/`ELIM`/`HAL` are accounted for, probably **~40 functions of genuine new
implementation**:

1. **Page + heap allocator** from physical memory (the root; gates everything).
2. **Tiny libc**: `string.h`, ctype tables, `qsort`, a PRNG, number parsing
   (`strtod`/`strtol`), `snprintf`.
3. **Tiny libm subset**, `log2`/`fabs` first (the observer needs them).
4. **The platform HAL seam** — the architectural change: a thin interface
   (`console_write`, `read_char`, `clock_ns`, `spawn`/`yield`, `map_exec`) that
   POSIX satisfies when hosted and the EigenOS kernel satisfies on bare metal.
   Today the runtime talks to POSIX directly; there is no seam.
5. **Harden threading** before it's load-bearing.
6. Defer: the JIT (interpreter-only first), a filesystem, networking.

## Build profile

A fourth profile beside `minimal` / `full` / `wasm`: **`freestanding`** —
`-ffreestanding -nostdlib -U_FORTIFY_SOURCE -fno-stack-protector`, links the tiny
libc/libm + the HAL, compiles out subprocess/fs/net/regex/JIT. The WASM build
(net/subprocess/JIT already carved out) and the embedding API (`eigs_embed.h`)
are the precedent; the new requirement is abstracting **core I/O**, which WASM
still gets from its host and freestanding cannot.

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
