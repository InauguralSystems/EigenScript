# Embedding EigenScript in a C/C++ host

EigenScript runs as a CLI by default (`src/main.c` wires up `EigsState`
and feeds it a script). The same runtime is also embeddable: the public
C API in `src/eigs_embed.h` lets a host application open an interpreter
instance, eval source, exchange values, and register host functions
that script code can call.

This document is the reference. The minimum working example is
[`src/embed_smoke.c`](../src/embed_smoke.c), built and run by
`make embed-smoke`.

## Drop-in: the two-file amalgamation

The fastest path to embedded — no build system, no source list. From the repo:

```
make amalgamation      # writes build/eigenscript_all.c + build/eigs_embed.h
```

Copy those **two files** into your project and compile them with your host —
`cc` alone, no `-I`, no `-D`, no dependency beyond libm/libpthread:

```c
/* host.c */
#include <stdio.h>
#include "eigs_embed.h"

int main(void) {
    EigsState *st = eigs_open();
    eigs_eval_string("print of (6 * 7)\n");    /* prints 42 */
    if (eigs_has_error()) { printf("%s\n", eigs_last_error_message()); return 1; }
    eigs_close(st);
    return 0;
}
```

```
cc -O2 host.c eigenscript_all.c -lm -lpthread -o host
```

`eigenscript_all.c` inlines every runtime source and header into one
self-contained translation unit; the optional extensions (HTTP, model, DB, gfx)
default **off**, so the drop-in is the minimal zero-dependency build. Everything
below — multi-state, value handles, the abort flag, and the trace-sink /
record-replay seam — is available through the same `eigs_embed.h`.

Prefer a static library? `make lib` produces `libeigenscript.a`; link it with
`-Ibuild` (for `eigs_embed.h`) and `-lm -lpthread`.

## Overview

A host application talks to the runtime through three opaque types:

| type | what it represents |
|---|---|
| `EigsState` | One interpreter instance: global env, JIT cache, module cache, observer thresholds, handle table. |
| `EigsThread` | The execution context for one OS thread attached to a state: arena, error state, VM, freelists. |
| `EigsValue` | A ref-counted runtime value (number, string, list, dict, etc.). Same underlying object as the script's values. |

The runtime is **multi-state**. A single process can hold multiple
`EigsState` instances concurrently; each one is independent. Inside a
state, multiple OS threads can attach (one `EigsThread` each) and share
the state's global env, but only one of them executes script code at a
time per state (the VM is not internally re-entrant per state).

## Lifecycle

The one-shot form covers the common case — single state, single thread:

```c
#include "eigs_embed.h"

int main(void) {
    EigsState *st = eigs_open();   /* state + attach + register builtins */
    if (!st) return 1;

    EigsValue *r = eigs_eval_string("1 + 2 * 3");
    /* r is a counted ref; release when done */
    eigs_value_release(r);

    eigs_close(st);                /* detach + destroy */
    return 0;
}
```

The finer-grained form is for hosts that need to attach more than one OS
thread to the same state, or build the state in stages:

```c
EigsState *st = eigs_state_new();
eigs_thread_attach(st);
eigs_state_init_runtime(st);       /* register builtins; idempotent */
/* ...use the state... */
eigs_thread_detach();
eigs_state_destroy(st);
```

`eigs_thread_attach` is called once per OS thread that needs to enter
the state; `eigs_thread_detach` is called from the same thread before
the state is destroyed or the thread exits.

## Source eval

```c
EigsValue *eigs_eval_string(const char *src);
EigsValue *eigs_eval_file(const char *path);
```

Both forms tokenize, parse, compile, and execute in the attached state's
global env, REPL-style: top-level names land in the global env so they
accumulate across calls and are visible to `eigs_get_global`.

Returns a counted ref to the script's last expression value, or `NULL`
on parse / runtime error. On error, `eigs_last_error_message()` returns
the most recent message. `eigs_eval_file` also updates `script_dir` so
`import` / `load_file` inside the source resolves relative paths against
the file's directory.

```c
EigsValue *r = eigs_eval_string("greeting is \"hi\"\n3 * 14");
if (!r) {
    fprintf(stderr, "eval failed: %s\n", eigs_last_error_message());
    eigs_clear_error();
}
```

## Error retrieval

```c
const char *eigs_last_error_message(void);  /* NULL when no error */
int         eigs_has_error(void);
void        eigs_clear_error(void);
```

The returned message pointer is owned by the thread state — copy it if
you need to keep it past the next API call.

## Aborting a running eval

```c
void eigs_set_abort_flag(volatile int *flag);   /* NULL unregisters */
```

`eigs_eval_string` is synchronous, so a runaway `loop while 1:` would
otherwise own the thread. Register a flag once; setting it from an
interrupt/signal context (a SIGINT handler, a timeout timer, a keyboard
IRQ on bare metal) makes the interpreter raise an ordinary runtime error
(`aborted`) at the next loop back-edge. The flag is consumed when
honored — one set aborts exactly one eval — and the state stays usable
afterward. The host side is async-signal-safe by construction: it is a
plain store into the host's own `int`; the runtime only reads it.
Caveats: the error is catchable like any runtime error (a `try` around
the loop observes it — set the flag again if needed), and JIT/OSR-native
hot loops don't poll (the abort lands at the next interpreted back-edge;
run `EIGS_JIT_OFF=1` for hard timeouts — the freestanding profile
compiles the JIT out, so coverage there is total).

## Globals

```c
void       eigs_set_global(const char *name, EigsValue *val);
EigsValue *eigs_get_global(const char *name);  /* counted ref or NULL */
```

`eigs_set_global` retains its own reference to `val`; the caller's ref
is left untouched. A common pattern:

```c
EigsValue *forty = eigs_value_new_num(40.0);
eigs_set_global("z", forty);
eigs_value_release(forty);          /* drop caller's ref; the global keeps its own */
```

`eigs_get_global` returns a counted ref the caller must release; `NULL`
if the name isn't bound.

## Value handles

`EigsValue` is opaque. Construction:

```c
EigsValue *eigs_value_new_num(double n);
EigsValue *eigs_value_new_string(const char *s);
EigsValue *eigs_value_new_null(void);
EigsValue *eigs_value_new_list(int capacity);
EigsValue *eigs_value_new_dict(int capacity);
EigsValue *eigs_value_new_buffer(int count);   /* zeroed, 1-D; the binary carrier */
```

Ref-count management — every value the host owns must eventually be
released:

```c
void eigs_value_retain(EigsValue *v);
void eigs_value_release(EigsValue *v);
```

Inspection:

```c
EigsValueType eigs_value_type(EigsValue *v);   /* EIGS_TYPE_NUM, _STR, _LIST, _DICT, _NULL, _FN, _BUFFER, _OTHER */
double        eigs_value_as_num(EigsValue *v);     /* 0.0 if wrong type */
const char   *eigs_value_as_string(EigsValue *v);  /* NULL if wrong type; borrowed pointer */
int           eigs_value_list_len(EigsValue *v);
EigsValue    *eigs_value_list_get(EigsValue *v, int i);    /* counted ref */
void          eigs_value_list_append(EigsValue *v, EigsValue *item);
EigsValue    *eigs_value_dict_get(EigsValue *v, const char *k);
void          eigs_value_dict_set(EigsValue *v, const char *k, EigsValue *val);
int           eigs_value_buffer_len(EigsValue *v);          /* 0 if not a buffer */
double        eigs_value_buffer_get(EigsValue *v, int i);   /* 0.0 out of range */
void          eigs_value_buffer_set(EigsValue *v, int i, double x); /* OOB: no-op */
```

`_list_get` / `_dict_get` return counted refs (caller releases). `_list_append`
/ `_dict_set` retain their own ref on `item`/`val`, so the caller still
owns the ref it passed in (release it after the call if it was freshly
constructed).

Buffers are the binary carrier across the host boundary: the script-side
`buffer of n` value (a flat mutable array of nums), NUL-safe end to end —
strings are C-terminated and cannot carry a 0x00 byte. A host moving raw
bytes stores 0..255 per element. There is no copy at the boundary: pass a
host-built buffer to script (`eigs_set_global`) and the script's
`buf_set` mutations are visible back through `eigs_value_buffer_get` —
it is the same object. This is the seam a block-device embedder (EigenOS
M10) moves sectors through.

## Trace tape: record and replay without a filesystem

Hosted, the replay tape is `EIGS_TRACE`/`EIGS_REPLAY` files. The embed
API reaches the same machinery as bytes, so a freestanding embedder
(EigenOS M11's machine journal) can record and replay with no files:

```c
typedef void (*EigsTraceSink)(const char *bytes, size_t len, void *ud);
void eigs_set_trace_sink(EigsTraceSink cb, void *ud);  /* non-NULL enables recording */
int  eigs_set_replay_tape(const char *bytes, size_t len, int strict); /* copied; NULL clears */
int  eigs_replay_take(const char *name, EigsValue **out);   /* 1 = served from tape */
void eigs_trace_record_nondet(const char *name, EigsValue *v);
```

The sink receives complete newline-terminated record lines (an
oversized record arrives in ordered chunks). It fires from inside
evaluation — do not re-enter the runtime from it; buffer the bytes and
act between evals. While a replay tape is set, nondet builtins return
the recorded `N` values in order instead of consulting their live
sources; when the tape runs out they fall back to live.

Host builtins participate with the take/record pair, the same contract
the runtime's own nondet builtins use:

```c
static EigsValue *my_sensor(EigsValue *arg) {
    EigsValue *v;
    if (eigs_replay_take("my_sensor", &v)) return v;   /* from the tape */
    v = eigs_value_new_num(read_hw());
    eigs_trace_record_nondet("my_sensor", v);          /* onto the tape */
    return v;
}
```

## FFI: calling host functions from script

```c
typedef EigsValue *(*EigsHostFn)(EigsValue *arg);
void eigs_register_function(const char *name, EigsHostFn fn);
```

The argument shape mirrors EigenScript's built-in calling convention:

- 1-arg call (`host_fn of x`): `arg` is the raw value.
- N-arg call (`host_fn of [a, b, c]`): `arg` is a `VAL_LIST` of length N.
- 0-arg call (`host_fn of null`): `arg` is `null`.

The return value's reference is **adopted** by the runtime — return a
fresh `eigs_value_new_*` (or any other `make_*`-equivalent), and do
**not** release it yourself.

```c
static EigsValue *host_add(EigsValue *arg) {
    if (eigs_value_type(arg) != EIGS_TYPE_LIST) return eigs_value_new_null();
    if (eigs_value_list_len(arg) != 2)          return eigs_value_new_null();
    EigsValue *a = eigs_value_list_get(arg, 0);
    EigsValue *b = eigs_value_list_get(arg, 1);
    double sum = eigs_value_as_num(a) + eigs_value_as_num(b);
    eigs_value_release(a);
    eigs_value_release(b);
    return eigs_value_new_num(sum);
}

eigs_register_function("host_add", host_add);
```

After registration, the script side calls it the same way as any
builtin: `host_add of [3, 4]`.

## Linking

The embedding API is part of the standard runtime build — no separate
library. A host links against the runtime sources minus `main.c` (the
same set `make lsp` and `make fuzz` use). The Makefile target
`embed-smoke` is the worked example:

```make
EMBED_SOURCES := $(filter-out $(SRC_DIR)/main.c,$(SOURCES))
embed-smoke:
	$(CC) $(CFLAGS) -o /tmp/embed_smoke $(SRC_DIR)/embed_smoke.c $(EMBED_SOURCES) \
	    -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
	    -DEIGENSCRIPT_VERSION='"$(VERSION)"' \
	    -lm -lpthread
	/tmp/embed_smoke
```

A host application copies that source set into its own build and
includes `src/eigs_embed.h`. Public headers needed at build time:
`src/eigs_embed.h` is sufficient — the internal `eigenscript.h`,
`vm.h`, etc. are *not* part of the embedding contract and may change
between minor releases.

## Threading and re-entrancy

- Inside a single `EigsState`, the VM is not internally re-entrant.
  Don't call `eigs_eval_string` from a host function that was called by
  the VM — return to the VM first.
- Multiple `EigsState` instances are fully independent. Two host
  threads each with their own state can run script concurrently.
- One `EigsState` accessed by multiple OS threads: each thread must
  `eigs_thread_attach`, and the host must serialize eval calls (a
  mutex around `eigs_eval_string` per state is sufficient). The shared
  global env, JIT cache, and module cache are visible to all attached
  threads.

## Stability

The embedding API is stable in shape — names, signatures, and ownership
semantics in `eigs_embed.h` will not change incompatibly without a
CHANGELOG entry. The opaque types (`EigsState`, `EigsThread`,
`EigsValue`) intentionally hide their layout: those structs change
between releases and the only safe way to touch them is through the
documented accessors.
