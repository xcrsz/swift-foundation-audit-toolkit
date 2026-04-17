# Makefile - swift-foundation audit orchestration
#
# Usage:
#   make scan           Run static source scan
#   make imports        Audit Foundation imports for right-sizing
#   make json-generate  Generate JSON golden files (run once on trusted build)
#   make json-verify    Verify JSON output matches golden files
#   make fs-probe       Run FileManager BSD probe
#   make url-probe      Run URL parser probe
#   make all            Run scan + imports + fs-probe + url-probe + json-verify
#   make ci             Same as 'all' but exits nonzero on any issue

ROOT          ?= .
GOLDEN_DIR    ?= ./audit-golden/json
SCRIPTS_DIR   := $(dir $(lastword $(MAKEFILE_LIST)))scripts

SWIFT         ?= swift
SH            ?= /bin/sh

.PHONY: all ci scan imports json-generate json-verify fs-probe url-probe clean help

help:
	@echo "swift-foundation audit targets:"
	@echo "  make scan           Static source scan for risk patterns"
	@echo "  make imports        Audit Foundation vs FoundationEssentials"
	@echo "  make json-generate  Generate golden JSON files (trusted env only)"
	@echo "  make json-verify    Verify JSON output against golden files"
	@echo "  make fs-probe       FileManager behavior probe"
	@echo "  make url-probe      URL parser probe"
	@echo "  make all            Everything except json-generate"
	@echo "  make ci             Everything, exit nonzero on any issue"

scan:
	@$(SH) $(SCRIPTS_DIR)scan-sources.sh $(ROOT)

imports:
	@$(SH) $(SCRIPTS_DIR)check-imports.sh $(ROOT)

json-generate:
	@mkdir -p $(GOLDEN_DIR)
	@$(SWIFT) $(SCRIPTS_DIR)json-roundtrip-diff.swift generate $(GOLDEN_DIR)

json-verify:
	@if [ ! -d $(GOLDEN_DIR) ]; then \
	    echo "No golden files in $(GOLDEN_DIR); run 'make json-generate' first"; \
	    exit 2; \
	fi
	@$(SWIFT) $(SCRIPTS_DIR)json-roundtrip-diff.swift verify $(GOLDEN_DIR)

fs-probe:
	@$(SWIFT) $(SCRIPTS_DIR)filemanager-bsd-probe.swift

url-probe:
	@$(SWIFT) $(SCRIPTS_DIR)url-parser-probe.swift

all: scan imports fs-probe url-probe
	@if [ -d $(GOLDEN_DIR) ]; then $(MAKE) json-verify; else \
	    echo "(skipping json-verify; no golden files)"; fi

ci: all

clean:
	@rm -rf $(GOLDEN_DIR)
