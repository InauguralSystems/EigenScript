VERSION := $(shell cat VERSION)
CC      := gcc
CFLAGS  := -Wall -Wextra -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
LDFLAGS := -pie -Wl,-z,relro,-z,now -lm -lpthread

SRC_DIR := src
SOURCES := $(SRC_DIR)/eigenscript.c $(SRC_DIR)/lexer.c $(SRC_DIR)/parser.c $(SRC_DIR)/builtins.c $(SRC_DIR)/builtins_tensor.c $(SRC_DIR)/hash.c $(SRC_DIR)/arena.c $(SRC_DIR)/strbuf.c $(SRC_DIR)/ext_store.c $(SRC_DIR)/fmt.c $(SRC_DIR)/lint.c $(SRC_DIR)/chunk.c $(SRC_DIR)/compiler.c $(SRC_DIR)/vm.c $(SRC_DIR)/jit.c $(SRC_DIR)/trace.c $(SRC_DIR)/main.c
BINARY  := $(SRC_DIR)/eigenscript

FULL_SOURCES := $(SOURCES) $(SRC_DIR)/ext_http.c $(SRC_DIR)/ext_db.c \
                $(SRC_DIR)/model_io.c $(SRC_DIR)/model_infer.c $(SRC_DIR)/model_train.c

PREFIX  := $(HOME)/.local

# The LSP links the whole runtime (minus main.c): eigenscript.c calls into
# the VM/compiler/trace layers, so a hand-picked subset bitrots every time
# the runtime grows (it had, silently — nothing built this target in CI).
LSP_SOURCES := $(SRC_DIR)/eigenlsp.c $(filter-out $(SRC_DIR)/main.c,$(SOURCES))
LSP_BINARY  := $(SRC_DIR)/eigenlsp

.PHONY: all build full http gfx test install install-gfx clean coverage coverage-clean fuzz fuzz-run lsp jit-smoke asan pgo

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

lsp:
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
	rm -f $(BINARY) $(LSP_BINARY) $(SRC_DIR)/*.o /tmp/jit_smoke

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
	@cd $(SRC_DIR) && gcov -n $(notdir $(SOURCES)) > ../coverage.txt 2>&1 || true
	@echo ""
	@echo "=== Coverage Summary ==="
	@awk '/^File/{f=$$2; next} /^Lines executed/ && f {gsub(/:/," ",$$0); print "  " f ": " $$3 " of " $$5 " lines"; f=""}' coverage.txt | sed "s/'//g"
	@echo ""
	@echo "Per-file .gcov reports written to $(SRC_DIR)/*.gcov"
	@echo "Run 'make coverage-clean' to remove coverage artifacts."

FUZZ_SOURCES := $(SRC_DIR)/eigenscript.c $(SRC_DIR)/lexer.c $(SRC_DIR)/parser.c $(SRC_DIR)/builtins.c $(SRC_DIR)/builtins_tensor.c $(SRC_DIR)/hash.c $(SRC_DIR)/arena.c $(SRC_DIR)/strbuf.c

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

version:
	@echo $(VERSION)
