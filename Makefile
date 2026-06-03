ARTIARY_DATA_DIR ?= $(HOME)/.local/share/artiary
ARTIARY_VERSIONS ?= $(ARTIARY_DATA_DIR)/versions.yml
ARTIARY_ARTIFACTS ?= $(HOME)/.cache/artiary/artifacts

export ARTIARY_DATA_DIR ARTIARY_VERSIONS ARTIARY_ARTIFACTS

SRC_DIR   := .
TESTS_DIR := tests
QUALITY_MK := /workspace/dashboard/tools/quality.mk
CHECKS_MK  := /workspace/dashboard/tools/checks.mk
TOOL_CONFIG := /workspace/dashboard/tools/pyproject-tool-config.toml
SEEDS_FILE := /workspace/autonomous-capital/harness/seeds/internal/repos.txt
SERVE_DEFINED := 0
include $(QUALITY_MK)
include $(CHECKS_MK)

.PHONY: resolve fetch clean update init test

resolve:
	uv run update-versions.py --resolve

fetch: resolve
	bash ./artifacts.sh

update:
	$(MAKE) resolve

clean:
	rm -rf $(ARTIARY_ARTIFACTS)

init: ## Register project in harness seeds file
	grep -qxF "$(CURDIR)" $(SEEDS_FILE) || echo "$(CURDIR)" >> $(SEEDS_FILE)

test: ## Run test suite
	uv run pytest $(TESTS_DIR) -v
