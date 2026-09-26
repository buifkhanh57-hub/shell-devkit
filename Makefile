# =============================================================================
# sysops -- Makefile (developer convenience)
#
#   make            help
#   make check      bash -n syntax-check every shell file
#   make test       run tests/run_tests.sh (self-contained, uses only /tmp)
#   make shellcheck run shellcheck when installed
#   make install    install to PREFIX (default /usr/local)
#   make uninstall  remove the installed files
#   make clean      remove local test artifacts
# =============================================================================

SHELL      := /bin/bash
PREFIX     ?= /usr/local
BINDIR     := $(DESTDIR)$(PREFIX)/bin
LIBDIR     := $(DESTDIR)$(PREFIX)/lib/sysops
CONFDIR    := $(DESTDIR)$(PREFIX)/share/sysops

BIN_FILE   := bin/sysops
LIB_FILES  := $(wildcard lib/*.sh)
SH_FILES   := $(BIN_FILE) $(LIB_FILES) tests/run_tests.sh

.PHONY: help check test install uninstall shellcheck clean

help:
	@echo "sysops $(shell sed -n 's/^SYOPS_VERSION=\"\([^\"]*\)\".*/\1/p' lib/common.sh 2>/dev/null)"
	@echo
	@echo "targets:"
	@echo "  check       bash -n syntax check on all shell files"
	@echo "  test        run the test suite (tests/run_tests.sh)"
	@echo "  shellcheck  run shellcheck (optional tool)"
	@echo "  install     install to PREFIX=$(PREFIX) (bin + lib + example conf)"
	@echo "  uninstall   remove installed files"
	@echo "  clean       remove test artifacts"

check:
	@set -e; \
	status=0; \
	for f in $(SH_FILES); do \
		printf '  bash -n  %s\n' "$$f"; \
		bash -n "$$f" || status=1; \
	done; \
	exit $$status

test:
	@bash tests/run_tests.sh

shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is not installed"; exit 1; }
	@shellcheck --shell=bash $(SH_FILES)

install: check
	install -d -m 0755 $(BINDIR) $(LIBDIR) $(CONFDIR)
	install -m 0755 $(BIN_FILE) $(BINDIR)/sysops
	@for f in $(LIB_FILES); do \
		install -m 0644 "$$f" $(LIBDIR)/; \
	done
	install -m 0644 conf/sysops.conf.example $(CONFDIR)/sysops.conf.example
	@echo "installed: $(BINDIR)/sysops (lib in $(LIBDIR))"

uninstall:
	rm -f $(BINDIR)/sysops
	rm -rf $(LIBDIR)
	rm -f $(CONFDIR)/sysops.conf.example
	@echo "uninstalled sysops from $(PREFIX)"

clean:
	rm -rf /tmp/sysops-test* /tmp/sysops.* 2>/dev/null || true
	@echo "cleaned"
