VERSION := $(shell cat VERSION)
CC      := gcc
CFLAGS  := -Wall -Wextra -O2 -fstack-protector-strong
LDFLAGS := -lm -lpthread

SRC_DIR := src
SOURCES := $(SRC_DIR)/eigenscript.c $(SRC_DIR)/lexer.c $(SRC_DIR)/parser.c $(SRC_DIR)/eval.c $(SRC_DIR)/builtins.c $(SRC_DIR)/arena.c $(SRC_DIR)/strbuf.c $(SRC_DIR)/main.c
BINARY  := $(SRC_DIR)/eigenscript

FULL_SOURCES := $(SOURCES) $(SRC_DIR)/ext_http.c $(SRC_DIR)/ext_db.c \
                $(SRC_DIR)/model_io.c $(SRC_DIR)/model_infer.c $(SRC_DIR)/model_train.c

PREFIX  := $(HOME)/.local

.PHONY: all build full http test install clean coverage coverage-clean fuzz fuzz-run

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

test: build
	cd tests && bash run_all_tests.sh

install: build
	mkdir -p $(PREFIX)/bin
	cp $(BINARY) $(PREFIX)/bin/eigenscript
	chmod +x $(PREFIX)/bin/eigenscript
	@echo "Installed: $(PREFIX)/bin/eigenscript (v$(VERSION))"

clean:
	rm -f $(BINARY) $(SRC_DIR)/*.o

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

FUZZ_SOURCES := $(SRC_DIR)/eigenscript.c $(SRC_DIR)/lexer.c $(SRC_DIR)/parser.c $(SRC_DIR)/eval.c $(SRC_DIR)/builtins.c $(SRC_DIR)/arena.c $(SRC_DIR)/strbuf.c

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
