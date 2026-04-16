VERSION := $(shell cat VERSION)
CC      := gcc
CFLAGS  := -Wall -Wextra -O2
LDFLAGS := -lm -lpthread

SRC_DIR := src
SOURCES := $(SRC_DIR)/eigenscript.c $(SRC_DIR)/arena.c $(SRC_DIR)/main.c
BINARY  := $(SRC_DIR)/eigenscript

FULL_SOURCES := $(SOURCES) $(SRC_DIR)/ext_http.c $(SRC_DIR)/ext_db.c \
                $(SRC_DIR)/model_io.c $(SRC_DIR)/model_infer.c $(SRC_DIR)/model_train.c

PREFIX  := $(HOME)/.local

.PHONY: all build full test install clean

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

test: build
	cd tests && bash run_all_tests.sh

install: build
	mkdir -p $(PREFIX)/bin
	cp $(BINARY) $(PREFIX)/bin/eigenscript
	chmod +x $(PREFIX)/bin/eigenscript
	@echo "Installed: $(PREFIX)/bin/eigenscript (v$(VERSION))"

clean:
	rm -f $(BINARY) $(SRC_DIR)/*.o

version:
	@echo $(VERSION)
