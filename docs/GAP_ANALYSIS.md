# EigenScript Gap Analysis

Version surveyed: **0.8.0**

EigenScript is a general-purpose language, but some program classes stress
capabilities that the current runtime and standard library do not provide.
This document catalogs those gaps so authors can decide when EigenScript fits
and when to reach for another language.

The survey is grounded in the current state of `src/`, `lib/`, `docs/`, and
`examples/`, and cross-referenced against the plans in `ROADMAP.md`.

## Current Capability Baseline

**Runtime**
- Tree-walking interpreter in C, dynamically typed
- Single-threaded, synchronous evaluation
- Reference-counted GC plus arena allocator (`arena_mark` / `arena_reset`)
- Native binary, zero runtime dependencies

**Standard library highlights** (25 modules, all pure EigenScript)
- File I/O and path manipulation
- JSON encode/decode, CSV, INI, `.env`
- List / set / queue / map / state-machine / template / format helpers
- Math, tensor math (autograd via `numerical_grad`, SGD, save/load)
- Testing (`lib/test`), logging (`lib/log`), validation

**Optional extensions (full build)**
- HTTP server and client
- PostgreSQL driver
- Transformer inference/training

## Gaps by Program Class

Each section names the concrete capability gap, the kinds of programs it
blocks, and a reasonable alternative language to reach for.

### Concurrent / Parallel Programs

**Gap.** No threads, no async/await, no coroutines, no channels or spawn.
Execution is strictly single-threaded and synchronous. Listed as
medium-term on the roadmap.

**Affected programs.**
- Real-time servers with many connections (WebSockets, chat, SSE)
- Map-reduce pipelines that need to split work across cores
- UI event loops that must also do background I/O
- Any workload that wants to overlap compute with I/O

**Reach for.** Go, Rust (with tokio), Elixir, Java.

### Cryptography and Signed Protocols

**Gap.** No hashing primitives (SHA-1/2/3, MD5), no HMAC, no AEAD, no
public-key primitives, no TLS. `random_hex` is sourced from
`/dev/urandom` and is the only crypto-adjacent primitive. HTTPS has to
be delegated to a subprocess (`curl` via `exec_capture`).

**Affected programs.**
- OAuth / JWT servers and verifiers
- Webhook signature validation
- Password hashing (bcrypt / argon2)
- Content-addressed stores, Merkle trees, signed-update tooling
- Anything that must originate HTTPS requests in-process

**Reach for.** Any language with a vetted crypto stack (Go, Rust, Python,
Node.js).

### Text-Heavy Parsing

**Partial.** POSIX ERE regex is available via `regex_match`,
`regex_find`, and `regex_replace`. Basic string operations cover
`contains`, `starts_with`, `index_of`, `str_replace`, `split`. Unicode
handling is basic — no grapheme clusters, no normalization. No PCRE
features (lookahead, named groups, lazy quantifiers).

**Affected programs.**
- HTML / Markdown sanitizers (need more than ERE)
- Scrapers that pull structured data out of messy input
- Unicode-heavy text processing (normalization, collation)

**Reach for.** Python, Perl, Go, Rust (for complex regex or Unicode).

### Network Protocol Implementations

**Gap.** No TCP/UDP sockets, no TLS, no DNS resolver. The only network
surface is the optional HTTP server/client extension.

**Affected programs.**
- SMTP / IMAP / POP mail clients
- MQTT, AMQP, Redis, Memcached clients
- Custom TCP proxies or game servers
- gRPC services (also needs protobuf and HTTP/2)

**Reach for.** Go, Rust, Node.js, Python.

### Streaming or Long-Running Subprocess Work

**Gap.** `exec_capture` fully buffers stdout (10 MB cap), has no stdin,
no streaming, no signal control, and no pipeline composition.

**Affected programs.**
- `ffmpeg` / ML inference pipelines that consume a stream
- `tail -f` style monitors
- Shells or REPL wrappers that must feed stdin
- `docker exec` / SSH harness programs

**Reach for.** Python (`subprocess`), Go (`os/exec`), Node.js.

### Binary Formats, Precision, and Compression

**Gap.** Numbers are IEEE-754 doubles — no arbitrary-precision
integers, no decimal type. Serialization is limited to JSON plus a
bespoke tensor binary format. No protobuf / msgpack / CBOR / Avro, no
gzip / zlib / brotli / zstd.

**Affected programs.**
- Money and accounting (needs exact decimal)
- Cryptographic math, large-prime work (needs bigint)
- Parquet / protobuf / Arrow readers
- Tools that must read or write compressed archives

**Reach for.** Python, Java, Rust, Go.

### Persistence Beyond PostgreSQL

**Gap.** Only the optional PostgreSQL driver is available. No SQLite,
MySQL, or any NoSQL / embedded KV driver.

**Affected programs.**
- Desktop apps backed by SQLite
- Services targeting MySQL / MariaDB
- Anything that expects Redis, Mongo, DynamoDB, or similar

**Reach for.** Python, Go, Rust, Node.js.

### Foreign Function Interface

**Gap.** No runtime FFI. Integration with an existing C library requires
compiling a new built-in into the interpreter itself. Roadmap long-term.

**Affected programs.**
- Wrappers around OpenCV, llama.cpp, sqlite3, libcurl
- Games extending SDL2 beyond what the bundled extension exposes
- Any reuse of an existing native library without a C shim rebuild

**Reach for.** Python (`ctypes`/`cffi`), Lua, JavaScript (`node-ffi`).

### Low-Level / Systems Programs

**Gap.** Interpreted execution, GC, and dynamic typing preclude the
shape of program that demands AOT compilation, manual memory control,
or predictable latency.

**Affected programs.**
- Kernel modules, device drivers, allocators
- Real-time audio or control loops
- Anything with strict static-typing or zero-GC requirements

**Reach for.** Rust, C, C++, Zig.

## Where EigenScript Fits Well Today

The same survey highlights the program classes that EigenScript handles
cleanly with what ships today:

- Numerical and ML prototypes using the tensor builtins and
  `numerical_grad` / SGD helpers
- Single-threaded automation scripts and data pipelines over JSON / CSV
- Small HTTP toys using the optional server/client extension
- Observer-driven analytics that exploit the built-in entropy, dH, and
  trajectory tracking on every variable (`unobserved:` blocks for
  performance-critical paths)
- SDL2 graphical applications using the `gfx_*` extension
  (see [Tidepool](https://github.com/InauguralSystems/Tidepool))
- Physics, game-logic, and simulation demos (see `examples/`: rope,
  orbital, PID control, ray marching, Sokoban, Game of Life)

## Relationship to the Roadmap

Many of the gaps above have corresponding roadmap entries:

- Concurrency primitives — medium-term
- WASM target — medium-term
- Pattern matching / destructuring — medium-term
- Debugger and source maps — near-term
- Package manager / module registry — near-term
- LSP — long-term
- FFI — long-term
- JIT — long-term

Gaps without roadmap entries (notably crypto, sockets, additional
database drivers, compression, decimal/bigint, streaming subprocess I/O)
are candidates for future proposals. Regex was added in 0.7.0 (POSIX ERE).
