# dashboard/tools/checks.mk — developer-facing check and fix targets
#
# Human-readable output; no JSON artifacts. Complements quality.mk (machine-readable pipeline).
#
# Include from a project Makefile with:
#   CHECKS_MK := /workspace/dashboard/tools/checks.mk
#   include $(CHECKS_MK)
#
# Override before including:
#   SRC_DIR   ?= src/mypackage
#   TESTS_DIR ?= tests

SRC_DIR   ?= src
TESTS_DIR ?= tests

.PHONY: lint typecheck coverage check fix fix-lint fix-lint-unsafe fix-format fix-types

# ---------------------------------------------------------------------------
# Check targets (read-only, human-readable output)
# ---------------------------------------------------------------------------

lint: ## Lint with ruff (text output)
	uv run ruff check $(SRC_DIR)

typecheck: ## Type-check with mypy (text output)
	uv run python -m mypy --show-column-numbers --show-error-codes $(SRC_DIR)

coverage: ## Run tests with coverage summary
	uv run pytest $(TESTS_DIR)/ --cov=$(SRC_DIR) --cov-report=term-missing -q

check: lint typecheck coverage ## Run all checks

# ---------------------------------------------------------------------------
# Fix targets (mutate source files)
# ---------------------------------------------------------------------------

fix-format: ## Auto-format with ruff format
	uv run ruff format $(SRC_DIR)

fix-lint: ## Apply safe ruff fixes
	uv run ruff check --fix $(SRC_DIR)

fix-lint-unsafe: ## Apply ruff fixes including unsafe ones
	uv run ruff check --fix --unsafe-fixes $(SRC_DIR)

fix-types: ## Stage AI-assisted type fixes via auto_resolver (typecheck scope)
	python3 $(dir $(lastword $(MAKEFILE_LIST)))auto_resolver.py . --scope typecheck

fix: fix-format fix-lint ## Apply safe automated fixes (format + lint)

# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------

CHECKS_MK_URL ?= https://raw.githubusercontent.com/kevreth/kev-labs/main/dashboard/tools/checks.mk

sync-checks: ## Pull latest checks.mk from GitHub
	curl -fsSL $(CHECKS_MK_URL) -o $(lastword $(MAKEFILE_LIST))
