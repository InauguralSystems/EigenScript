VERSION := $(shell cat VERSION)
CC      := gcc
# -Werror=implicit-function-declaration: an implicitly-declared function is
# assumed to return int, so on 64-bit a pointer-returning libc/GNU function
# (e.g. strcasestr without _GNU_SOURCE) has its return truncated to 32 bits —
# a corrupted pointer that segfaults at runtime, layout-dependently (this hid
# a remote-DoS in ext_http through CI; see #239). Make the whole class a hard
# build error instead of an ignorable warning.
CFLAGS  := -Wall -Wextra -Werror=implicit-function-declaration -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE

# RELRO/BIND_NOW are ELF concepts; macOS's ld64 rejects -z, and PIE is
# already the default there. Without this split every Makefile link target
# (notably `make lsp`) fails on macOS even though build.sh works.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS := -lm -lpthread
else
LDFLAGS := -pie -Wl,-z,relro,-z,now -lm -lpthread
endif

SRC_DIR := src
SOURCES := $(SRC_DIR)/eigenscript.c $(SRC_DIR)/lexer.c $(SRC_DIR)/parser.c $(SRC_DIR)/builtins.c $(SRC_DIR)/builtins_tensor.c $(SRC_DIR)/hash.c $(SRC_DIR)/arena.c $(SRC_DIR)/state.c $(SRC_DIR)/strbuf.c $(SRC_DIR)/ext_store.c $(SRC_DIR)/fmt.c $(SRC_DIR)/lint.c $(SRC_DIR)/chunk.c $(SRC_DIR)/compiler.c $(SRC_DIR)/vm.c $(SRC_DIR)/jit.c $(SRC_DIR)/trace.c $(SRC_DIR)/eigs_embed.c $(SRC_DIR)/repl.c $(SRC_DIR)/step.c $(SRC_DIR)/bundle.c $(SRC_DIR)/main.c
BINARY  := $(SRC_DIR)/eigenscript

# CLI-only translation units: linked into the binary, never into the
# runtime library (repl.c pulls termios/isatty — banned in the
# freestanding/embed profile, same footing as main.c; step.c is the
# --step tape-stepper, stdio+isatty, same footing).
CLI_ONLY := $(SRC_DIR)/main.c $(SRC_DIR)/repl.c $(SRC_DIR)/step.c $(SRC_DIR)/bundle.c

FULL_SOURCES := $(SOURCES) $(SRC_DIR)/ext_http.c $(SRC_DIR)/ext_db.c \
                $(SRC_DIR)/model_io.c $(SRC_DIR)/model_infer.c $(SRC_DIR)/model_train.c

PREFIX  := $(HOME)/.local

# The LSP links the whole runtime (minus main.c): eigenscript.c calls into
# the VM/compiler/trace layers, so a hand-picked subset bitrots every time
# the runtime grows (it had, silently — nothing built this target in CI).
LSP_SOURCES := $(SRC_DIR)/eigenlsp.c $(filter-out $(CLI_ONLY),$(SOURCES))
LSP_BINARY  := $(SRC_DIR)/eigenlsp

.PHONY: all build full http gfx zlib lib amalgamation tsan test install install-gfx clean coverage coverage-clean fuzz fuzz-run lsp jit-smoke embed-smoke asan valgrind pgo freestanding-check freestanding-libc-diff print-%

# Introspection helper: `make print-SOURCES` echoes a variable's value.
# tests/test_leak_guard.sh derives its ASan build source list from the
# canonical SOURCES via this target rather than hardcoding it (which drifted
# silently across the 0.15.0 multi-state refactor — see #223).
print-%:
	@echo '$($*)'

all: build

build:
	$(CC) $(CFLAGS) -o $(BINARY) $(SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS)
	@echo "EigenScript $(VERSION) built. Binary: $$(du -sh $(BINARY) | cut -f1)"

full:
	$(CC) $(CFLAGS) -o $(BINARY) $(FULL_SOURCES) \
		-I/usr/include/postgresql \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS) -lpq
	@echo "EigenScript $(VERSION) (full) built. Binary: $$(du -sh $(BINARY) | cut -f1)"

# Build with HTTP + model extensions but without DB (no libpq-dev required).
# Useful for running HTTP test suites on systems without PostgreSQL headers.
http:
	$(CC) $(CFLAGS) -o $(BINARY) $(SOURCES) \
		$(SRC_DIR)/ext_http.c \
		$(SRC_DIR)/model_io.c $(SRC_DIR)/model_infer.c $(SRC_DIR)/model_train.c \
		-DEIGENSCRIPT_EXT_HTTP=1 \
		-DEIGENSCRIPT_EXT_MODEL=1 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS)
	@echo "EigenScript $(VERSION) (http+model, no db) built. Binary: $$(du -sh $(BINARY) | cut -f1)"

# Build with the DEFLATE codecs (inflate/deflate builtins, #684) linked
# against the system zlib. Same opt-in pattern as `make http`: the
# default build stays zero-dependency and the four builtins raise
# "compiled without zlib support" there.
zlib:
	$(CC) $(CFLAGS) -o $(BINARY) $(SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_EXT_ZLIB=1 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS) -lz
	@echo "EigenScript $(VERSION) (zlib) built. Binary: $$(du -sh $(BINARY) | cut -f1)"

gfx:
	$(CC) $(CFLAGS) -o $(BINARY) $(SOURCES) $(SRC_DIR)/ext_gfx.c \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_EXT_GFX=1 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS) -ldl
	@echo "EigenScript $(VERSION) (gfx) built. Binary: $$(du -sh $(BINARY) | cut -f1)"

test: build
	cd tests && bash run_all_tests.sh

install-gfx: gfx lsp
	mkdir -p $(PREFIX)/bin
	mkdir -p $(PREFIX)/lib/eigenscript
	cp $(BINARY) $(PREFIX)/bin/eigenscript
	cp $(LSP_BINARY) $(PREFIX)/bin/eigenlsp
	chmod +x $(PREFIX)/bin/eigenscript $(PREFIX)/bin/eigenlsp
	cp lib/*.eigs $(PREFIX)/lib/eigenscript/
	@echo "Installed: $(PREFIX)/bin/eigenscript (v$(VERSION), gfx)"
	@echo "Installed: $(PREFIX)/bin/eigenlsp (v$(VERSION))"
	@echo "Stdlib:    $(PREFIX)/lib/eigenscript/"

install: build lsp
	mkdir -p $(PREFIX)/bin
	mkdir -p $(PREFIX)/lib/eigenscript
	cp $(BINARY) $(PREFIX)/bin/eigenscript
	cp $(LSP_BINARY) $(PREFIX)/bin/eigenlsp
	chmod +x $(PREFIX)/bin/eigenscript $(PREFIX)/bin/eigenlsp
	cp lib/*.eigs $(PREFIX)/lib/eigenscript/
	@echo "Installed: $(PREFIX)/bin/eigenscript (v$(VERSION))"
	@echo "Installed: $(PREFIX)/bin/eigenlsp (v$(VERSION))"
	@echo "Stdlib:    $(PREFIX)/lib/eigenscript/"

# Generated stdlib index for the LSP (#590): public define/signature-comment
# table scraped from lib/*.eigs. A build artifact, not committed (the build/
# amalgamation precedent, #397) — regenerated whenever lib/ or the script
# changes, before eigenlsp compiles. build.sh's lsp branch does the same.
$(SRC_DIR)/lsp_stdlib_index.h: $(wildcard lib/*.eigs) tools/gen_lsp_stdlib_index.sh
	bash tools/gen_lsp_stdlib_index.sh

lsp: $(SRC_DIR)/lsp_stdlib_index.h
	$(CC) $(CFLAGS) -o $(LSP_BINARY) $(LSP_SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS)
	@echo "EigenScript LSP $(VERSION) built. Binary: $$(du -sh $(LSP_BINARY) | cut -f1)"

jit-smoke:
	$(CC) -Wall -Wextra -O2 -o /tmp/jit_smoke $(SRC_DIR)/jit.c $(SRC_DIR)/jit_smoke.c -lm
	/tmp/jit_smoke

EMBED_SOURCES := $(filter-out $(CLI_ONLY),$(SOURCES))

# Single-file amalgamation (#397): "copy two files, call eigs_open".
# build/eigenscript_all.c (self-contained, system headers only) + the public
# build/eigs_embed.h. Source list is read from SOURCES above — no second list.
amalgamation:
	bash tools/amalgamate.sh build

# Static library for embedding — the minimal (zero-dependency) build; optional
# extensions stay opt-in.
lib:
	@mkdir -p build/obj
	@for f in $(EMBED_SOURCES); do \
		$(CC) $(CFLAGS) -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 \
			-DEIGENSCRIPT_EXT_DB=0 -DEIGENSCRIPT_VERSION='"$(VERSION)"' \
			-c $$f -o build/obj/$$(basename $$f .c).o || exit 1; \
	done
	ar rcs libeigenscript.a build/obj/*.o
	@echo "libeigenscript.a built ($$(du -sh libeigenscript.a | cut -f1))"

# Phase 10 embedding API smoke test — the host harness linked against the
# AMALGAMATION (not the raw source list), so the two-file artifact can never
# silently rot: if amalgamate.sh drifts, this fails in CI.
embed-smoke: amalgamation
	$(CC) $(CFLAGS) -Ibuild -o /tmp/embed_smoke $(SRC_DIR)/embed_smoke.c build/eigenscript_all.c \
		-lm -lpthread
	/tmp/embed_smoke

# AddressSanitizer + UndefinedBehaviorSanitizer build. Catches
# use-after-free, buffer overflow, leaks, and undefined behavior that
# the normal -O2 build silently tolerates. ~2x slower; for testing only.
# The full suite runs leak-clean, so leave leak detection on:
#   make asan && cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh
asan:
	$(CC) -fsanitize=address,undefined -g -O1 -o $(BINARY) $(SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		-lm -lpthread
	@echo "EigenScript $(VERSION) (asan+ubsan) built. Binary: $(BINARY)"

# ThreadSanitizer build for the concurrency race gate (tests/test_tsan.sh).
# Complements ASan (which is not run with the thread checker). Run the tests
# under `setarch -R` — ThreadSanitizer needs ASLR disabled here (CLAUDE.md).
tsan:
	$(CC) -fsanitize=thread -g -O1 -o $(BINARY) $(SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		-lm -lpthread
	@echo "EigenScript $(VERSION) (tsan) built. Binary: $(BINARY)"

# Plain -O1 -g minimal build for Valgrind/Memcheck (tests/valgrind_smoke.sh).
# No sanitizers — Valgrind shadows the uninstrumented binary at runtime, so it
# complements ASan/UBSan/TSan (uninit reads, UAF, definite/indirect leaks) on a
# system without instrumented libs. -O1 keeps optimizer-induced false positives
# down while giving usable stacks. Same minimal extension surface as asan.
valgrind:
	$(CC) -g -O1 -o $(BINARY) $(SOURCES) \
		-DEIGS_VALGRIND \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		-lm -lpthread
	@echo "EigenScript $(VERSION) (valgrind -O1 -g) built. Binary: $(BINARY)"

# Uninitialized-read hunter (the EigenOS #UD heisenbug class, see
# eigenscript.h EIGS_POISON). Fills xmalloc blocks, xrealloc grown tails and
# parked env-freelist arrays with 0xAA so a read of never-initialized memory
# fails deterministically on every link layout instead of reading glibc's
# benign zero pages. Run the suite against it, with the raw-malloc boundary
# poisoned too:
#   make poison && cd tests && MALLOC_PERTURB_=170 bash run_all_tests.sh
poison:
	$(CC) -g -O1 -o $(BINARY) $(SOURCES) \
		-DEIGS_POISON \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		-lm -lpthread
	@echo "EigenScript $(VERSION) (poison 0xAA -O1 -g) built. Binary: $(BINARY)"

# Profile-guided optimization. Builds an instrumented binary, runs the
# DMG cpu_instrs workload to collect branch/edge counters, then rebuilds
# with -fprofile-use. Net win on cpu_instrs has been ~8%, mostly in the
# vm_run dispatch loop's branch layout. Override PGO_RUN to use a
# different workload (e.g. PGO_RUN="$(BINARY) myscript.eigs").
PGO_DIR ?= /tmp/eigs-pgo
PGO_RUN ?= cd $(HOME)/DMG && $(CURDIR)/$(BINARY) dmg.eigs roms/cpu_instrs.gb --cycles 200000 >/dev/null
pgo:
	@rm -rf $(PGO_DIR) && mkdir -p $(PGO_DIR)
	$(CC) $(CFLAGS) -fprofile-generate=$(PGO_DIR) -o $(BINARY) $(SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS)
	@echo "Instrumented binary built; running PGO workload..."
	@sh -c '$(PGO_RUN)'
	$(CC) $(CFLAGS) -fprofile-use=$(PGO_DIR) -fprofile-correction -o $(BINARY) $(SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS)
	@echo "EigenScript $(VERSION) (PGO) built. Binary: $$(du -sh $(BINARY) | cut -f1)"

clean:
	rm -f $(BINARY) $(LSP_BINARY) $(SRC_DIR)/*.o /tmp/jit_smoke libeigenscript.a
	rm -rf build

coverage-clean:
	rm -f $(SRC_DIR)/*.gcda $(SRC_DIR)/*.gcno $(SRC_DIR)/*.gcov coverage.txt

coverage: coverage-clean
	@for src in $(SOURCES); do \
		obj=$${src%.c}.o; \
		$(CC) -O0 -g --coverage -Wall -Wextra -c $$src -o $$obj \
			-DEIGENSCRIPT_EXT_HTTP=0 \
			-DEIGENSCRIPT_EXT_MODEL=0 \
			-DEIGENSCRIPT_EXT_DB=0 \
			-DEIGENSCRIPT_VERSION='"$(VERSION)"' || exit 1; \
	done
	$(CC) --coverage -o $(BINARY) $(SOURCES:.c=.o) $(LDFLAGS)
	-cd tests && bash run_all_tests.sh > /dev/null 2>&1 || true
	@cd $(SRC_DIR) && gcov -n -b $(notdir $(SOURCES)) > ../coverage.txt 2>&1 || true
	@echo ""
	@echo "=== Coverage Summary (line % | branches taken at least once) ==="
	@echo "    Line coverage in the 80s routinely hides far weaker branch"
	@echo "    coverage (error/edge paths) — both numbers are shown so the"
	@echo "    gap is visible. The bug classes that bit before (#239 HTTP"
	@echo "    DoS, #231 JIT POP peephole) lived in untaken branches."
	@echo ""
	@sed "s/'//g" coverage.txt | awk '/^File/{f=$$2; next} /^Lines executed/&&f{ll=$$0; sub(/.*:/,"",ll); sub(/% of.*/,"",ll)} /^Taken at least once/&&f{tt=$$0; sub(/.*:/,"",tt); sub(/% of.*/,"",tt); printf "  %-24s lines %6s%%   branches %6s%%\n", f, ll, tt; f=""} /^No branches/&&f{printf "  %-24s lines %6s%%   branches    n/a\n", f, ll; f=""}'
	@echo ""
	@echo "Per-file .gcov reports written to $(SRC_DIR)/*.gcov"
	@echo "Run 'make coverage-clean' to remove coverage artifacts."

# Like the LSP, the fuzz harness links the whole runtime minus main.c —
# the old hand-picked subset bitrotted when the bytecode VM replaced the
# tree-walking evaluator (eval_node), leaving `make fuzz` unbuildable.
FUZZ_SOURCES := $(filter-out $(CLI_ONLY),$(SOURCES))

fuzz: fuzz/fuzz_stdin.c $(FUZZ_SOURCES)
	$(CC) -g -fsanitize=address,undefined -o fuzz/fuzz_stdin \
		fuzz/fuzz_stdin.c $(FUZZ_SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"fuzz"' \
		-lm -lpthread
	@echo "Fuzz binary built. Usage: echo 'code' | ./fuzz/fuzz_stdin"

fuzz-run: fuzz
	@bash fuzz/run_fuzz.sh

# libFuzzer harness — what OSS-Fuzz drives. The build flags here mirror
# the OSS-Fuzz contract: $$CC=clang, $$CFLAGS gets the sanitizer choice,
# $$LIB_FUZZING_ENGINE provides main(). Locally we just pass everything
# explicitly so a clean clone can reproduce the OSS-Fuzz build.
fuzz-libfuzzer: fuzz/fuzz_eigenscript.c $(FUZZ_SOURCES)
	clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all \
		-o fuzz/fuzz_eigenscript \
		fuzz/fuzz_eigenscript.c $(FUZZ_SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"fuzz"' \
		-lm -lpthread
	@echo "libFuzzer binary built. Run: ./fuzz/fuzz_eigenscript fuzz/corpus/ -max_len=4096 -timeout=5"

version:
	@echo $(VERSION)

# Freestanding symbol gate (docs/FREESTANDING.md as an assertion). Stage 1:
# compile the runtime with -DEIGENSCRIPT_FREESTANDING=1 and fail if it
# imports any symbol outside tools/freestanding_allowlist.txt. Stage 2: link
# the mini-libc/libm (src/freestanding/) in and fail unless the residue is
# exactly the kernel-owed HAL roots (tools/freestanding_hal_roots.txt).
freestanding-check:
	bash tools/freestanding_check.sh

# Mini-libc/libm differential vs glibc as the oracle (hosted). Bit/byte-exact
# for mem/str/ctype/strtol/strtod/qsort/rand48/snprintf and the exact libm
# subset; ulp-bounded for the transcendentals (bounds pinned in the harness).
freestanding-libc-diff:
	$(CC) -O2 -fno-builtin -ffp-contract=off -Wall -Wextra \
		-o /tmp/eigs_libc_diff tests/freestanding_libc_diff.c \
		src/freestanding/mini_libc.c src/freestanding/mini_libm.c \
		src/freestanding/mini_fmt.c src/freestanding/mini_strtod.c -lm
	/tmp/eigs_libc_diff
