.PHONY: help serve links shellcheck all

PORT ?= 3009

help:
	@echo "make serve       - serve the docsify site on localhost:$(PORT)"
	@echo "make links       - check internal markdown links resolve"
	@echo "make shellcheck  - run shellcheck on serve.sh"
	@echo "make all         - links"

serve:
	python3 -m http.server $(PORT)

links:
	python3 tools/check_links.py

shellcheck:
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
	shellcheck -S error serve.sh

all: links
