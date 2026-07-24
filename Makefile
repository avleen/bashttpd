# bashttpd -- developer Makefile (GNU make).
#
#   make build   build the self-contained single file into dist/bashttpd
#   make test    run the bats test suite (./tests/run)
#   make lint    run shellcheck over every shell source
#   make check   lint + test
#   make clean   remove dist/

SHELL := /bin/bash

LIB_SOURCES := $(wildcard lib/bashttpd/*.sh)
DIST        := dist/bashttpd

SHELL_SOURCES := bashttpd bin/bashttpd $(LIB_SOURCES) $(wildcard scripts/*.sh)

.PHONY: build test lint check clean

build: $(DIST)

$(DIST): bin/bashttpd $(LIB_SOURCES) scripts/build-single.sh
	./scripts/build-single.sh

test:
	./tests/run

lint:
	shellcheck $(SHELL_SOURCES)

check: lint test

clean:
	rm -rf dist
