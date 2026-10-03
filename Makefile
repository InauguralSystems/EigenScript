VERSION := $(shell cat VERSION)
CC      := gcc
override WERROR_FLAGS := $(shell cat tools/werror_flags.txt)
ifeq ($(strip $(WERROR_FLAGS)),)
$(error missing, unreadable or empty tools/werror_flags.txt)
endif
# -Werror=implicit-function-declaration: an implicitly-declared function is
# assumed to return int, so on 64-bit a pointer-returning libc/GNU function
# (e.g. strcasestr without _GNU_SOURCE) has its return truncated to 32 bits —
# a corrupted pointer that segfaults at runtime, layout-dependently (this hid
# a remote-DoS in ext_http through CI; see #239). Make the whole class a hard
# build error instead of an ignorable warning.
CFLAGS  := -Wall -Wextra -Werror=implicit-function-declaration $(WERROR_FLAGS) -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE

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
SOURCES := $(SRC_DIR)/eigenscript.c $(SRC_DIR)/lexer.c $(SRC_DIR)/parser.c $(SRC_DIR)/builtins.c $(SRC_DIR)/builtins_buf.c $(SRC_DIR)/builtins_host.c $(SRC_DIR)/builtins_tensor.c $(SRC_DIR)/fsutil.c $(SRC_DIR)/hash.c $(SRC_DIR)/arena.c $(SRC_DIR)/state.c $(SRC_DIR)/strbuf.c $(SRC_DIR)/ext_store.c $(SRC_DIR)/fmt.c $(SRC_DIR)/lint.c $(SRC_DIR)/lint_host.c $(SRC_DIR)/chunk.c $(SRC_DIR)/compiler.c $(SRC_DIR)/vm.c $(SRC_DIR)/task.c $(SRC_DIR)/jit.c $(SRC_DIR)/trace.c $(SRC_DIR)/eigs_embed.c $(SRC_DIR)/repl.c $(SRC_DIR)/step.c $(SRC_DIR)/tape_read.c $(SRC_DIR)/bundle.c $(SRC_DIR)/main.c
HOSTED_SOURCES := $(SOURCES) $(SRC_DIR)/ext_gfx.c
MODEL_SRC := $(SRC_DIR)/model_io.c $(SRC_DIR)/model_infer.c $(SRC_DIR)/model_train.c
BINARY  := $(SRC_DIR)/eigenscript

# CLI-only translation units: linked into the binary, never into the
# runtime library (repl.c pulls termios/isatty — banned in the
# freestanding/embed profile, same footing as main.c; step.c is the
# --step tape-stepper, stdio+isatty, same footing).
CLI_ONLY := $(SRC_DIR)/main.c $(SRC_DIR)/repl.c $(SRC_DIR)/step.c $(SRC_DIR)/tape_read.c $(SRC_DIR)/bundle.c

SERVER_SOURCES := $(HOSTED_SOURCES) $(SRC_DIR)/ext_http.c $(SRC_DIR)/ext_net.c $(MODEL_SRC)
SERVER_DB_SOURCES := $(SERVER_SOURCES) $(SRC_DIR)/ext_db.c

PREFIX  := $(HOME)/.local

# The LSP links the whole runtime (minus main.c): eigenscript.c calls into
# the VM/compiler/trace layers, so a hand-picked subset bitrots every time
# the runtime grows (it had, silently — nothing built this target in CI).
LSP_SOURCES := $(SRC_DIR)/eigenlsp.c $(filter-out $(CLI_ONLY),$(SOURCES))
LSP_BINARY  := $(SRC_DIR)/eigenlsp
LSP_ASAN_BINARY := build/asan/lsp/eigenlsp

# The DAP server (#539 v3): the tape model TU plus the runtime it needs
# (observer_slot classification, trace_name_is_internal). Same link
# shape as the LSP — the whole runtime minus the CLI-only units, so it
# cannot bitrot against a hand-picked subset.
DAP_SOURCES := $(SRC_DIR)/eigsdap.c $(SRC_DIR)/tape_read.c $(filter-out $(CLI_ONLY),$(SOURCES))
DAP_BINARY  := $(SRC_DIR)/eigsdap

# Aux binaries that ALREADY exist on disk are version-checked by `make`/
# `make test` and relinked on skew (#825): after a VERSION bump a stale
# eigsdap records/reads tapes under the old version string and the #411
# gate correctly refuses them — reported as 18 unexplained DAP behavioral
# failures on every release cut. The refresh triggers ONLY on version
# skew (`--version` vs VERSION; a pre-#825 binary prints nothing and so
# also refreshes) — NOT on source drift, which would tax every dev-loop
# `make` with two full aux recompiles; an explicit `make dap`/`make lsp`
# tracks full source/header staleness via the real file targets below.
# Fresh checkouts (CI) have no aux binaries and build nothing extra.
AUX_PRESENT := $(wildcard $(LSP_BINARY) $(DAP_BINARY))
define AUX_REFRESH
	@for b in $(AUX_PRESENT); do \
		v="$$($$b --version </dev/null 2>/dev/null)"; \
		if [ "$$v" != "$(VERSION)" ]; then \
			echo "refreshing $$b ($${v:-pre-#825} -> $(VERSION))"; \
			case $$b in \
				*eigsdap) $(MAKE) --no-print-directory dap ;; \
				*eigenlsp) $(MAKE) --no-print-directory lsp ;; \
			esac; \
		fi; \
	done
endef

.PHONY: all build server server-db full http net gfx zlib lib amalgamation tsan test test-changed precheck sandbox-intern-test install install-gfx clean coverage coverage-clean fuzz fuzz-run lsp lsp-asan dap jit-smoke embed-smoke embed-smoke-gfx embed-concurrent asan asan-server valgrind pgo poison freestanding-check freestanding-libc-diff asan-http asan-gfx tsan-server tsan-http nativefn-test arming-mt-test embed-roads print-% sigpipe-contract-test sigpipe-partial-test

# ---- Per-variant objdir engine (#740) -------------------------------------
# The engine's rules are defined before `all`, so pin the default goal.
.DEFAULT_GOAL := all
# Every runtime variant compiles into its own build/<variant>/ objdir with
# -MMD/-MP header-dependency tracking, links build/<variant>/eigenscript,
# and the phony target re-points src/eigenscript at it (hard link — see
# RELINK below for why not a symlink). So: variants COEXIST (make asan no
# longer destroys the release binary — and switching back is an instant
# relink, not a 22-TU rebuild), and rebuilds within a variant are
# incremental. The alias keeps every existing consumer of src/eigenscript
# working unchanged. The suite's fingerprint guard (#681) still applies:
# re-pointing the alias or relinking the same variant mid-suite is caught
# at the next section seam.
VERDEF   := -DEIGENSCRIPT_VERSION='"$(VERSION)"'
DEFS_OFF := -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0
# EIGS_STR_LEN_CHECK (#1183): re-derive every cached VAL_STR length at every
# read and abort on a mismatch. A wrong cached length is a silent
# out-of-bounds read, strictly worse than the strlen it replaced, so the
# invariant is CHECKED in every debug variant rather than trusted — the full
# suite runs under asan, so every string the suite touches is validated.
STRLEN_CHECK := -DEIGS_STR_LEN_CHECK
ASAN_FLAGS := -fsanitize=address,undefined,float-cast-overflow $(WERROR_FLAGS) -g -O1 $(STRLEN_CHECK)

SRC_V_release := $(HOSTED_SOURCES)
FLAGS_release := $(CFLAGS) $(DEFS_OFF) -DEIGENSCRIPT_EXT_GFX=1 $(VERDEF)
LIBS_release  := $(LDFLAGS) -ldl

SRC_V_server := $(SERVER_SOURCES)
FLAGS_server := $(CFLAGS) -DEIGENSCRIPT_EXT_HTTP=1 -DEIGENSCRIPT_EXT_MODEL=1 -DEIGENSCRIPT_EXT_DB=0 -DEIGENSCRIPT_EXT_NET=1 -DEIGENSCRIPT_EXT_GFX=1 $(VERDEF)
LIBS_server  := $(LDFLAGS) -ldl

SRC_V_server-db := $(SERVER_DB_SOURCES)
FLAGS_server-db := $(CFLAGS) -I/usr/include/postgresql -DEIGENSCRIPT_EXT_HTTP=1 -DEIGENSCRIPT_EXT_MODEL=1 -DEIGENSCRIPT_EXT_DB=1 -DEIGENSCRIPT_EXT_NET=1 -DEIGENSCRIPT_EXT_GFX=1 $(VERDEF)
LIBS_server-db  := $(LDFLAGS) -ldl -lpq

SRC_V_zlib := $(HOSTED_SOURCES)
FLAGS_zlib := $(CFLAGS) $(DEFS_OFF) -DEIGENSCRIPT_EXT_GFX=1 -DEIGENSCRIPT_EXT_ZLIB=1 $(VERDEF)
LIBS_zlib  := $(LDFLAGS) -ldl -lz

SRC_V_asan := $(HOSTED_SOURCES)
FLAGS_asan := $(ASAN_FLAGS) $(DEFS_OFF) -DEIGENSCRIPT_EXT_GFX=1 $(VERDEF)
LIBS_asan  := -lm -lpthread -ldl
# Compatibility introspection for tests/tools that derive the former gfx
# sanitizer source set. The artifact itself is now build/asan/eigenscript.
SRC_V_asan-gfx := $(SRC_V_asan)
FLAGS_asan-gfx := $(FLAGS_asan)
LIBS_asan-gfx := $(LIBS_asan)

SRC_V_asan-server := $(SERVER_SOURCES)
FLAGS_asan-server := $(ASAN_FLAGS) -DEIGENSCRIPT_EXT_HTTP=1 -DEIGENSCRIPT_EXT_MODEL=1 -DEIGENSCRIPT_EXT_DB=0 -DEIGENSCRIPT_EXT_NET=1 -DEIGENSCRIPT_EXT_GFX=1 $(VERDEF)
LIBS_asan-server  := -lm -lpthread -ldl

SRC_V_tsan := $(SOURCES)
FLAGS_tsan := -fsanitize=thread $(WERROR_FLAGS) -g -O1 $(DEFS_OFF) $(VERDEF)
LIBS_tsan  := -lm -lpthread

SRC_V_tsan-server := $(SERVER_SOURCES)
FLAGS_tsan-server := -fsanitize=thread $(WERROR_FLAGS) -g -O1 -DEIGENSCRIPT_EXT_HTTP=1 -DEIGENSCRIPT_EXT_MODEL=1 -DEIGENSCRIPT_EXT_DB=0 -DEIGENSCRIPT_EXT_NET=1 -DEIGENSCRIPT_EXT_GFX=1 $(VERDEF)
LIBS_tsan-server  := -lm -lpthread -ldl

SRC_V_valgrind := $(HOSTED_SOURCES)
FLAGS_valgrind := $(WERROR_FLAGS) -g -O1 -DEIGS_VALGRIND $(STRLEN_CHECK) $(DEFS_OFF) -DEIGENSCRIPT_EXT_GFX=1 $(VERDEF)
LIBS_valgrind  := -lm -lpthread -ldl

SRC_V_poison := $(HOSTED_SOURCES)
FLAGS_poison := $(WERROR_FLAGS) -g -O1 -DEIGS_POISON $(STRLEN_CHECK) $(DEFS_OFF) -DEIGENSCRIPT_EXT_GFX=1 $(VERDEF)
LIBS_poison  := -lm -lpthread -ldl

VARIANTS := release server server-db zlib asan asan-server tsan tsan-server valgrind poison

# Objects depend on Makefile+VERSION so a flag or version-string change
# rebuilds; header edits are covered by the generated .d files.
define VARIANT_RULES
OBJ_$(1) := $$(patsubst $(SRC_DIR)/%.c,build/$(1)/%.o,$$(SRC_V_$(1)))
build/$(1)/%.o: $(SRC_DIR)/%.c Makefile VERSION tools/werror_flags.txt | build/$(1)
	$$(CC) $$(FLAGS_$(1)) -MMD -MP -c $$< -o $$@
build/$(1)/eigenscript: $$(OBJ_$(1))
	$$(CC) $$(FLAGS_$(1)) -o $$@ $$(OBJ_$(1)) $$(LIBS_$(1))
build/$(1):
	@mkdir -p $$@
-include $$(OBJ_$(1):.o=.d)
endef
$(foreach V,$(VARIANTS),$(eval $(call VARIANT_RULES,$(V))))

# The retarget lives in the phony targets below (not the link recipe) so
# `make <variant>` always points src/eigenscript at that variant, even
# when its binary was already up to date. HARD link, not symlink: the
# runtime resolves lib/ relative to /proc/self/exe, which dereferences a
# symlink to build/<variant>/ and would lose the executable-relative
# stdlib; a hard link keeps the exec'd path at src/eigenscript.
define RELINK
@ln -f build/$(1)/eigenscript $(BINARY)
endef

# Introspection helper: `make print-SOURCES` echoes a variable's value.
# tests/test_leak_guard.sh derives its ASan build source list from the
# canonical SOURCES via this target rather than hardcoding it (which drifted
# silently across the 0.15.0 multi-state refactor — see #223).
print-%:
	@echo '$($*)'

all: build
	$(AUX_REFRESH)

build: build/release/eigenscript
	$(call RELINK,release)
	@echo "EigenScript $(VERSION) built. Binary: $$(du -sh build/release/eigenscript | cut -f1)"

# Focused lifetime regression for sandbox descriptor interns (#964). Link the
# public embedding/runtime surface without CLI-only translation units so the
# C test can inspect the internal thread-local intern accounting directly.
SANDBOX_INTERN_TEST := build/release/test_sandbox_intern_lifetime
SANDBOX_INTERN_TEST_OBJ := build/release/test_sandbox_intern_lifetime.o
$(SANDBOX_INTERN_TEST_OBJ): tests/test_sandbox_intern_lifetime.c Makefile VERSION tools/werror_flags.txt $(wildcard $(SRC_DIR)/*.h) | build/release
	$(CC) $(FLAGS_release) -I$(SRC_DIR) -MMD -MP -c $< -o $@
$(SANDBOX_INTERN_TEST): $(SANDBOX_INTERN_TEST_OBJ) $(filter-out build/release/main.o build/release/repl.o build/release/step.o build/release/tape_read.o build/release/bundle.o,$(OBJ_release))
	$(CC) $(FLAGS_release) -o $@ $^ $(LIBS_release)
sandbox-intern-test: $(SANDBOX_INTERN_TEST)
	@echo "Sandbox intern lifetime test built: $(SANDBOX_INTERN_TEST)"

# #1082: a builtin's line-0 raise with no live VM frame reports the trace stamp
ERRLINE_TEST := build/release/test_error_line_fallback
ERRLINE_TEST_OBJ := build/release/test_error_line_fallback.o
$(ERRLINE_TEST_OBJ): tests/test_error_line_fallback.c Makefile VERSION tools/werror_flags.txt $(wildcard $(SRC_DIR)/*.h) | build/release
	$(CC) $(FLAGS_release) -I$(SRC_DIR) -MMD -MP -c $< -o $@
$(ERRLINE_TEST): $(ERRLINE_TEST_OBJ) $(filter-out build/release/main.o build/release/repl.o build/release/step.o build/release/tape_read.o build/release/bundle.o,$(OBJ_release))
	$(CC) $(FLAGS_release) -o $@ $^ $(LIBS_release)
errline-test: $(ERRLINE_TEST)
	@echo "Error-line fallback test built: $(ERRLINE_TEST)"

# #1060: a native function registered with a name reports as a user fn
# (`type of` -> "fn", printing -> `<fn NAME>`); C-level because only a linked
# runtime (the AOT) can make one.
NATIVEFN_TEST := build/release/test_native_fn
NATIVEFN_TEST_OBJ := build/release/test_native_fn.o
$(NATIVEFN_TEST_OBJ): tests/test_native_fn.c Makefile VERSION tools/werror_flags.txt $(wildcard $(SRC_DIR)/*.h) | build/release
	$(CC) $(FLAGS_release) -I$(SRC_DIR) -MMD -MP -c $< -o $@
$(NATIVEFN_TEST): $(NATIVEFN_TEST_OBJ) $(filter-out build/release/main.o build/release/repl.o build/release/step.o build/release/tape_read.o build/release/bundle.o,$(OBJ_release))
	$(CC) $(FLAGS_release) -o $@ $^ $(LIBS_release)
nativefn-test: $(NATIVEFN_TEST)
	@echo "Native-fn identity test built: $(NATIVEFN_TEST)"

# #1145(b): two EigsStates on two OS threads with no spawn — the shape where
# the per-STATE `multithreaded` flag is 0 on both sides and nothing widens the
# process-global observer arming sets. Same variant discipline as
# embed-observer-test: build against the variant the suite is running, and
# never repoint the CLI alias.
ARMING_MT_VARIANT ?= release
ARMING_MT_OBJ := $(filter-out build/$(ARMING_MT_VARIANT)/main.o,$(OBJ_$(ARMING_MT_VARIANT)))
build/$(ARMING_MT_VARIANT)/test_arming_two_states: tests/test_arming_two_states.c $(ARMING_MT_OBJ) $(wildcard $(SRC_DIR)/*.h) Makefile tools/werror_flags.txt
	$(CC) $(FLAGS_$(ARMING_MT_VARIANT)) -I$(SRC_DIR) -o $@ $< $(ARMING_MT_OBJ) $(LIBS_$(ARMING_MT_VARIANT))
.PHONY: arming-mt-test
arming-mt-test: build/$(ARMING_MT_VARIANT)/test_arming_two_states
	@echo "Arming two-state test built: build/$(ARMING_MT_VARIANT)/test_arming_two_states"

# #1151: host signal dispositions survive proc and HTTP entry points. Build
# against the selected runtime variant without repointing the CLI alias.
SIGPIPE_VARIANT ?= release
SIGPIPE_OBJ := $(filter-out build/$(SIGPIPE_VARIANT)/main.o,$(OBJ_$(SIGPIPE_VARIANT)))
build/$(SIGPIPE_VARIANT)/test_sigpipe_contract: tests/test_sigpipe_contract.c $(SIGPIPE_OBJ) $(wildcard $(SRC_DIR)/*.h) Makefile tools/werror_flags.txt
	$(CC) $(FLAGS_$(SIGPIPE_VARIANT)) -I$(SRC_DIR) -o $@ $< $(SIGPIPE_OBJ) $(LIBS_$(SIGPIPE_VARIANT))
sigpipe-contract-test: build/$(SIGPIPE_VARIANT)/test_sigpipe_contract
	@echo "SIGPIPE contract test built: $<"

# Exercise the real helper with a finite partial-write observation. Only this
# test object's write call is renamed; production objects have no test hook.
SIGPIPE_PARTIAL_FSUTIL := build/$(SIGPIPE_VARIANT)/test_sigpipe_partial_fsutil.o
SIGPIPE_PARTIAL_OBJ := $(filter-out build/$(SIGPIPE_VARIANT)/main.o build/$(SIGPIPE_VARIANT)/fsutil.o,$(OBJ_$(SIGPIPE_VARIANT)))
$(SIGPIPE_PARTIAL_FSUTIL): $(SRC_DIR)/fsutil.c $(wildcard $(SRC_DIR)/*.h) Makefile VERSION tools/werror_flags.txt | build/$(SIGPIPE_VARIANT)
	$(CC) $(FLAGS_$(SIGPIPE_VARIANT)) -I$(SRC_DIR) -Dwrite=eigs_sigpipe_test_write -MMD -MP -c $< -o $@
build/$(SIGPIPE_VARIANT)/test_sigpipe_partial: tests/test_sigpipe_partial.c $(SIGPIPE_PARTIAL_FSUTIL) $(SIGPIPE_PARTIAL_OBJ) $(wildcard $(SRC_DIR)/*.h) Makefile VERSION tools/werror_flags.txt
	$(CC) $(FLAGS_$(SIGPIPE_VARIANT)) -I$(SRC_DIR) -o $@ $< $(SIGPIPE_PARTIAL_FSUTIL) $(SIGPIPE_PARTIAL_OBJ) $(LIBS_$(SIGPIPE_VARIANT))
sigpipe-partial-test: build/$(SIGPIPE_VARIANT)/test_sigpipe_partial
	@echo "SIGPIPE partial test built: $<"

# #1038/#1028: same runtime variant as the suite; never repoint the CLI alias.
EMBED_OBSERVER_VARIANT ?= release
EMBED_OBSERVER_OBJ := $(filter-out build/$(EMBED_OBSERVER_VARIANT)/main.o,$(OBJ_$(EMBED_OBSERVER_VARIANT)))
build/$(EMBED_OBSERVER_VARIANT)/test_embed_observer: tests/test_embed_observer.c $(EMBED_OBSERVER_OBJ) $(wildcard $(SRC_DIR)/*.h) Makefile tools/werror_flags.txt
	$(CC) $(FLAGS_$(EMBED_OBSERVER_VARIANT)) -I$(SRC_DIR) -o $@ $< $(EMBED_OBSERVER_OBJ) $(LIBS_$(EMBED_OBSERVER_VARIANT))
.PHONY: embed-observer-test
embed-observer-test: build/$(EMBED_OBSERVER_VARIANT)/test_embed_observer
	@echo "Embed observer test built: $<"

# #1463: structural intern ownership against the owning runtime variant.
# No CLI relink; the fixture holds test references throughout teardown.
INTERN_OWNER_VARIANT ?= release
INTERN_OWNER_OBJ := $(filter-out build/$(INTERN_OWNER_VARIANT)/main.o,$(OBJ_$(INTERN_OWNER_VARIANT)))
build/$(INTERN_OWNER_VARIANT)/test_intern_owners: tests/test_intern_owners.c $(INTERN_OWNER_OBJ) $(wildcard $(SRC_DIR)/*.h) Makefile tools/werror_flags.txt
	$(CC) $(FLAGS_$(INTERN_OWNER_VARIANT)) -I$(SRC_DIR) -o $@ $< $(INTERN_OWNER_OBJ) $(LIBS_$(INTERN_OWNER_VARIANT))
.PHONY: intern-owner-test
intern-owner-test: build/$(INTERN_OWNER_VARIANT)/test_intern_owners
	@echo "Intern owner structural oracle built: $<"

# #1056: use the same variant as the CLI under test, without relinking it.
ROAD_VARIANT ?= release
EMBED_ROADS_OBJ := $(filter-out build/$(ROAD_VARIANT)/main.o,$(OBJ_$(ROAD_VARIANT)))
build/$(ROAD_VARIANT)/embed_roads: $(SRC_DIR)/embed_roads.c $(EMBED_ROADS_OBJ) $(wildcard $(SRC_DIR)/*.h) Makefile tools/werror_flags.txt
	$(CC) $(FLAGS_$(ROAD_VARIANT)) -I$(SRC_DIR) -o $@ $< $(EMBED_ROADS_OBJ) $(LIBS_$(ROAD_VARIANT))
embed-roads: build/$(ROAD_VARIANT)/embed_roads
	@echo "Embed road test built: $<"

server-db: build/server-db/eigenscript
	$(call RELINK,server-db)
	@echo "EigenScript $(VERSION) (server: http+net+model+db) built. Binary: $$(du -sh build/server-db/eigenscript | cut -f1)"

server: build/server/eigenscript
	$(call RELINK,server)
	@echo "EigenScript $(VERSION) (server: http+net+model) built. Binary: $$(du -sh build/server/eigenscript | cut -f1)"

# Compatibility target names; release artifacts are now release/server/server-db.
full: server-db
	@echo "NOTE: 'make full' is a compatibility alias for 'make server-db'."
http: server
	@echo "NOTE: 'make http' is a compatibility alias for 'make server'."
net: server
	@echo "NOTE: 'make net' is a compatibility alias for 'make server'."

# Build with the DEFLATE codecs (inflate/deflate builtins, #684) linked
# against the system zlib. Same opt-in pattern as `make http`: the
# default build stays zero-dependency and the four builtins raise
# "compiled without zlib support" there.
zlib: build/zlib/eigenscript
	$(call RELINK,zlib)
	@echo "EigenScript $(VERSION) (zlib) built. Binary: $$(du -sh build/zlib/eigenscript | cut -f1)"

# gfx is part of every hosted release. Keep the old target as a source-compatible
# alias, but do not produce a separate gfx distribution identity.
gfx: build
	@echo "NOTE: 'make gfx' is a compatibility alias for 'make'."

# The label floor first (#1379): a runner overwritten by a generated plan has no
# sections and no epilogue, so it ran nothing and exited 0.
test: build sandbox-intern-test
	$(AUX_REFRESH)
	bash tools/suite_label_check.sh
	cd tests && bash run_all_tests.sh

# Contributor fast local gate (#1347): only the suite sections the diff against
# BASE touches (working tree + untracked). CI still runs the whole suite.
BASE ?= origin/main
test-changed: export EIGS_SUITE_CHANGED := $(value BASE)
test-changed: build
	$(AUX_REFRESH)
	bash tools/suite_label_check.sh
	cd tests && bash run_all_tests.sh

# Contributor precheck (#1264): the repo's static gates in well under a minute,
# one line per gate. Needs no build (gates that need a binary SKIP without one).
precheck:
	bash tools/precheck.sh

install-gfx: install
	@echo "NOTE: 'make install-gfx' is a compatibility alias for 'make install'."

install: build lsp dap
	mkdir -p $(PREFIX)/bin
	mkdir -p $(PREFIX)/lib/eigenscript
	cp $(BINARY) $(PREFIX)/bin/eigenscript
	cp $(LSP_BINARY) $(PREFIX)/bin/eigenlsp
	cp $(DAP_BINARY) $(PREFIX)/bin/eigsdap
	chmod +x $(PREFIX)/bin/eigenscript $(PREFIX)/bin/eigenlsp $(PREFIX)/bin/eigsdap
	cp lib/*.eigs $(PREFIX)/lib/eigenscript/
	@echo "Installed: $(PREFIX)/bin/eigenscript (v$(VERSION))"
	@echo "Installed: $(PREFIX)/bin/eigenlsp (v$(VERSION))"
	@echo "Installed: $(PREFIX)/bin/eigsdap (v$(VERSION))"
	@echo "Stdlib:    $(PREFIX)/lib/eigenscript/"

# Generated stdlib index for the LSP (#590): public define/signature-comment
# table scraped from lib/*.eigs. A build artifact, not committed (the build/
# amalgamation precedent, #397) — regenerated whenever lib/ or the script
# changes, before eigenlsp compiles. build.sh's lsp branch does the same.
$(SRC_DIR)/lsp_stdlib_index.h: $(wildcard lib/*.eigs) tools/gen_lsp_stdlib_index.sh
	bash tools/gen_lsp_stdlib_index.sh

# Builtin half of the same idea (#742): names from the registration seams +
# ext_names.h, hover detail from the signature comments. Reserved report
# forms are excluded using lexer.c. Commit the generated header for review.
$(SRC_DIR)/lsp_builtin_index.h: $(SRC_DIR)/builtins.c $(SRC_DIR)/builtins_host.c \
		$(SRC_DIR)/hash.c $(SRC_DIR)/ext_store.c $(SRC_DIR)/ext_names.h \
		$(SRC_DIR)/lexer.c tools/gen_lsp_builtin_index.sh
	bash tools/gen_lsp_builtin_index.sh

# Real file targets (#825): rebuilt when their sources, any header, the
# Makefile, or VERSION change — so `make` after a VERSION bump relinks
# them instead of leaving version-skewed binaries for the #411 tape gate
# to refuse. `lsp`/`dap` stay as the phony entry points.
$(LSP_BINARY): $(LSP_SOURCES) $(SRC_DIR)/lsp_stdlib_index.h $(SRC_DIR)/lsp_builtin_index.h $(wildcard $(SRC_DIR)/*.h) Makefile VERSION tools/werror_flags.txt
	$(CC) $(CFLAGS) -o $(LSP_BINARY) $(LSP_SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS)
	@echo "EigenScript LSP $(VERSION) built. Binary: $$(du -sh $(LSP_BINARY) | cut -f1)"

lsp: $(LSP_BINARY)

# Keep the sanitizer LSP separate from src/eigenlsp. CFLAGS is not a make
# dependency, so rebuilding that shared path with an override can silently run
# a newer release binary instead (#1365), and a real rebuild leaves local
# release tests pointing at the instrumented executable.
LSP_ASAN_RUNTIME_OBJ := $(filter-out $(patsubst $(SRC_DIR)/%.c,build/asan/%.o,$(CLI_ONLY)),$(OBJ_asan))
build/asan/lsp/eigenlsp.o: $(SRC_DIR)/eigenlsp.c $(SRC_DIR)/lsp_stdlib_index.h $(SRC_DIR)/lsp_builtin_index.h $(wildcard $(SRC_DIR)/*.h) Makefile VERSION tools/werror_flags.txt | build/asan/lsp
	$(CC) $(FLAGS_asan) -MMD -MP -c $< -o $@
build/asan/lsp:
	@mkdir -p $@
-include build/asan/lsp/eigenlsp.d

$(LSP_ASAN_BINARY): build/asan/lsp/eigenlsp.o $(LSP_ASAN_RUNTIME_OBJ)
	$(CC) $(FLAGS_asan) -o $@ $^ $(LIBS_asan)
	@echo "EigenScript LSP $(VERSION) (ASan+UBSan) built. Binary: $$(du -sh $@ | cut -f1)"

lsp-asan: $(LSP_ASAN_BINARY)

# Bounded diagnostic-state witness: compile the actual LSP/trace sources in
# the test TU, against the requested runtime variant, without production hooks.
LSP_ARMING_VARIANT ?= release
LSP_ARMING_OBJ := $(filter-out $(patsubst $(SRC_DIR)/%.c,build/$(LSP_ARMING_VARIANT)/%.o,$(CLI_ONLY)) build/$(LSP_ARMING_VARIANT)/trace.o,$(OBJ_$(LSP_ARMING_VARIANT)))
build/$(LSP_ARMING_VARIANT)/test_lsp_arming: tests/test_lsp_arming.c $(SRC_DIR)/eigenlsp.c $(SRC_DIR)/trace.c $(LSP_ARMING_OBJ) $(SRC_DIR)/lsp_stdlib_index.h $(SRC_DIR)/lsp_builtin_index.h $(wildcard $(SRC_DIR)/*.h) Makefile tools/werror_flags.txt
	$(CC) $(FLAGS_$(LSP_ARMING_VARIANT)) -I$(SRC_DIR) -o $@ $< $(LSP_ARMING_OBJ) $(LIBS_$(LSP_ARMING_VARIANT))
.PHONY: lsp-arming-test
lsp-arming-test: build/$(LSP_ARMING_VARIANT)/test_lsp_arming

$(DAP_BINARY): $(DAP_SOURCES) $(wildcard $(SRC_DIR)/*.h) Makefile VERSION tools/werror_flags.txt
	$(CC) $(CFLAGS) -o $(DAP_BINARY) $(DAP_SOURCES) \
		-DEIGENSCRIPT_EXT_HTTP=0 \
		-DEIGENSCRIPT_EXT_MODEL=0 \
		-DEIGENSCRIPT_EXT_DB=0 \
		-DEIGENSCRIPT_VERSION='"$(VERSION)"' \
		$(LDFLAGS)
	@echo "EigenScript DAP $(VERSION) built. Binary: $$(du -sh $(DAP_BINARY) | cut -f1)"

dap: $(DAP_BINARY)

jit-smoke:
	$(CC) -Wall -Wextra $(WERROR_FLAGS) -O2 -o /tmp/jit_smoke $(SRC_DIR)/jit.c $(SRC_DIR)/jit_smoke.c -lm
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
# #885: the CONCURRENT half of the multi-state embedding promise. Sibling of
# embed-smoke, which covers multi-state SWITCHING on one thread; nothing
# covered two states running at the same time, and `pthread_create` appeared
# nowhere in src/embed_smoke.c or any tests/*.sh. Carries its own planted
# fault — a shared file-scope global — so three green rows cannot mean "the
# harness never raced".
embed-concurrent: amalgamation
	$(CC) $(CFLAGS) -Ibuild -o /tmp/embed_concurrent $(SRC_DIR)/embed_concurrent.c build/eigenscript_all.c \
		-lm -lpthread
	/tmp/embed_concurrent

embed-smoke: amalgamation
	$(CC) $(CFLAGS) -Ibuild -o /tmp/embed_smoke $(SRC_DIR)/embed_smoke.c build/eigenscript_all.c \
		-lm -lpthread
	/tmp/embed_smoke

# Same smoke against the gfx variant's objects: pins that the embed API's
# env is composed by the ONE registration seam (#742 — pre-fix, only the
# CLI registered gfx, so this exact link had no gfx builtins). Registration
# needs no SDL init, so this runs headless.
embed-smoke-gfx: build
	$(CC) $(FLAGS_release) -o /tmp/embed_smoke_gfx $(SRC_DIR)/embed_smoke.c \
		$(filter-out build/release/main.o,$(OBJ_release)) \
		-lm -lpthread $(LIBS_release)
	/tmp/embed_smoke_gfx

# AddressSanitizer + UndefinedBehaviorSanitizer build. Catches
# use-after-free, buffer overflow, leaks, and undefined behavior that
# the normal -O2 build silently tolerates. ~2x slower; for testing only.
# The full suite runs leak-clean, so leave leak detection on:
#   make asan && cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh
asan: build/asan/eigenscript
	$(call RELINK,asan)
	@echo "EigenScript $(VERSION) (asan+ubsan) built. Binary: $(BINARY)"

# ASan+UBSan over the server profile. The ordinary asan target now owns gfx.
asan-server: build/asan-server/eigenscript
	$(call RELINK,asan-server)
	@echo "EigenScript $(VERSION) (asan+ubsan, server) built. Binary: $(BINARY)"
asan-http: asan-server
	@echo "NOTE: 'make asan-http' is a compatibility alias for 'make asan-server'."
asan-gfx: asan
	@echo "NOTE: 'make asan-gfx' is a compatibility alias for 'make asan'."

# ThreadSanitizer build for the concurrency race gate (tests/test_tsan.sh).
# Complements ASan (which is not run with the thread checker). Run the tests
# under `setarch -R` — ThreadSanitizer needs ASLR disabled here (CLAUDE.md).
tsan: build/tsan/eigenscript
	$(call RELINK,tsan)
	@echo "EigenScript $(VERSION) (tsan) built. Binary: $(BINARY)"

# ThreadSanitizer over the server profile (#1139).
tsan-server: build/tsan-server/eigenscript
	$(call RELINK,tsan-server)
	@echo "EigenScript $(VERSION) (tsan, server) built. Binary: $(BINARY)"
tsan-http: tsan-server
	@echo "NOTE: 'make tsan-http' is a compatibility alias for 'make tsan-server'."

# Plain -O1 -g minimal build for Valgrind/Memcheck (tests/valgrind_smoke.sh).
# No sanitizers — Valgrind shadows the uninstrumented binary at runtime, so it
# complements ASan/UBSan/TSan (uninit reads, UAF, definite/indirect leaks) on a
# system without instrumented libs. -O1 keeps optimizer-induced false positives
# down while giving usable stacks. Same minimal extension surface as asan.
valgrind: build/valgrind/eigenscript
	$(call RELINK,valgrind)
	@echo "EigenScript $(VERSION) (valgrind -O1 -g) built. Binary: $(BINARY)"

# Uninitialized-read hunter (the EigenOS #UD heisenbug class, see
# eigenscript.h EIGS_POISON). Fills xmalloc blocks, xrealloc grown tails and
# parked env-freelist arrays with 0xAA so a read of never-initialized memory
# fails deterministically on every link layout instead of reading glibc's
# benign zero pages. Run the suite against it, with the raw-malloc boundary
# poisoned too:
#   make poison && cd tests && MALLOC_PERTURB_=170 bash run_all_tests.sh
poison: build/poison/eigenscript
	$(call RELINK,poison)
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
	@rm -f $(BINARY)   # may be a variant symlink — never write through it
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
		$(CC) -O0 -g --coverage -Wall -Wextra $(WERROR_FLAGS) -c $$src -o $$obj \
			-DEIGENSCRIPT_EXT_HTTP=0 \
			-DEIGENSCRIPT_EXT_MODEL=0 \
			-DEIGENSCRIPT_EXT_DB=0 \
			-DEIGENSCRIPT_VERSION='"$(VERSION)"' || exit 1; \
	done
	@rm -f $(BINARY)   # may be a variant symlink — never write through it
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
	$(CC) -g -fsanitize=address,undefined $(WERROR_FLAGS) -o fuzz/fuzz_stdin \
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
	clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all $(WERROR_FLAGS) \
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
	$(CC) -O2 -fno-builtin -ffp-contract=off -Wall -Wextra $(WERROR_FLAGS) \
		-o /tmp/eigs_libc_diff tests/freestanding_libc_diff.c \
		src/freestanding/mini_libc.c src/freestanding/mini_libm.c \
		src/freestanding/mini_fmt.c src/freestanding/mini_strtod.c -lm
	/tmp/eigs_libc_diff
