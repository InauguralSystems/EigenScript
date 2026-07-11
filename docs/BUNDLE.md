# `--bundle` — single-file distribution (#413)

```
eigenscript --bundle app.eigs out [--with-tape tape]
./out [args...]          # runs anywhere — no EigenScript checkout needed
./out --replay [args...] # with a tape attached: re-run it EXACTLY
```

`--bundle` copies the running runtime binary and appends an archive:
the script, the adjacent `eigs_modules/` tree (the whole tree —
dependency analysis can't see dynamic imports, and the superset is
cheap), the stdlib `lib/` modules (so `import json` works on a bare
machine), and optionally a trace tape. The result is one executable.

Demo:

```
eigenscript --bundle examples/data_pipeline.eigs pipeline
./pipeline
```

## The tape-carrying variant: an executable bug report

Record a failing run, then ship binary + failure as one file:

```
EIGS_TRACE=fail.tape eigenscript app.eigs      # reproduce once, recorded
eigenscript --bundle app.eigs repro --with-tape fail.tape
./repro --replay                               # replays byte-identically,
                                               # no network, no env, no luck
```

Every nondeterministic input (random, time, env, file reads, HTTP —
see docs/TRACE.md) is served from the tape. The #411 version contract
is pinned *by construction*: the tape names the version that recorded
it, and the bundle carries that exact binary — the pair can't drift.

## How it runs

Startup checks the binary's own tail for the archive trailer. A bundle
extracts to a `mkdtemp` directory and rewrites `argv` to run the
extracted script; the script's directory is the resolve base, so every
existing resolution rule just works (`import name` →
`eigs_modules/name/name.eigs`, `import json` → `lib/json.eigs`). The
tempdir is removed at exit. In bundle mode all arguments belong to the
bundled script — only `--replay` (first argument) is intercepted.

## Format

Appended after the runtime image (little-endian, x86-64 — the same
assumption the JIT makes):

```
entry*:  [u32 path_len][path][u64 size][bytes]     (first entry = the script)
trailer: [u64 archive_off][u32 count][u32 fmt=1]["EIGSBNDL"]
```

A torn archive (misparsing entry headers) refuses with exit 3 rather
than running garbage. There are no per-entry checksums — a flipped bit
inside one file's *data* is out of scope for fmt 1; the attached tape
still self-identifies via its own `V` header. Re-bundling from a bundle
copies only the runtime image, so archives don't accrete.

## The native-speed tier of the same story

`--bundle` ships at VM speed today. The **AOT compiler in the sibling
`ouroboros` repo** (transpile-to-C, the VM as its byte-exact oracle) is
the native-speed tier of the same deliverable: compile the script to a
real native binary instead of carrying the interpreter. Same
single-file story, ~10–60× faster on numeric code — use it when the
bundle's job is performance rather than reproduction.
