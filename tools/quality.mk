# dashboard/tools/quality.mk — shared Python quality targets
#
# Include from a project Makefile with:
#   QUALITY_MK := $(realpath ../../dashboard/tools/quality.mk)
#   include $(QUALITY_MK)
#
# Override before including:
#   SRC_DIR   ?= src/mypackage
#   TESTS_DIR ?= tests

QUALITY_TOOLS_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))

SRC_DIR   ?= src
TESTS_DIR ?= tests

.PHONY: lint-ruff lint-mypy lint-complexity audit-deps coverage quality dashboard

lint-ruff: ## Lint with ruff → reports/ruff.json
	@mkdir -p reports
	uv run ruff check --output-format json $(SRC_DIR) > reports/ruff.json; true

lint-mypy: ## Type-check with mypy → reports/mypy.json
	@mkdir -p reports
	python3 $(QUALITY_TOOLS_DIR)/mypy_json.py . $(SRC_DIR) || true

lint-complexity: ## Cyclomatic complexity → reports/complexity.json
	@mkdir -p reports
	uv run radon cc $(SRC_DIR) -j > reports/complexity.json
	python3 $(QUALITY_TOOLS_DIR)/check_complexity.py || true

audit-deps: ## Scan dependencies for CVEs → reports/pip-audit.json
	@mkdir -p reports
	uv run pip-audit -f json -o reports/pip-audit.json; true

coverage: ## Produce .coverage for ACIS (exits 0 even if tests fail)
	@if [ -L .venv/bin/python3 ] && [ ! -e .venv/bin/python3 ]; then rm -rf .venv; fi
	uv run pytest $(TESTS_DIR)/ --cov=$(SRC_DIR) -q || true

quality: ## Run all checks → reports/quality.json
	@mkdir -p reports
	@_d=$$(pwd); _label="$$(basename $$(dirname $$_d))/$$(basename $$_d)"; \
	printf "%s [%s] [ruff]\n" "$$(date +%H:%M:%S)" "$$_label" && $(MAKE) lint-ruff; \
	printf "%s [%s] [mypy]\n" "$$(date +%H:%M:%S)" "$$_label" && $(MAKE) lint-mypy; \
	printf "%s [%s] [pytest]\n" "$$(date +%H:%M:%S)" "$$_label" && uv run pytest $(TESTS_DIR)/ \
	    --json-report --json-report-file=reports/pytest.json \
	    --cov=$(SRC_DIR) --cov-report=json:reports/coverage.json \
	    --no-header -q; TEST=$$?; \
	[ $$TEST -eq 5 ] && TEST=0 || true; \
	printf "%s [%s] [radon cc]\n" "$$(date +%H:%M:%S)" "$$_label" && $(MAKE) lint-complexity; \
	printf "%s [%s] [pip-audit]\n" "$$(date +%H:%M:%S)" "$$_label" && $(MAKE) audit-deps; \
	printf "%s [%s] [quality.json]\n" "$$(date +%H:%M:%S)" "$$_label" && python3 $(QUALITY_TOOLS_DIR)/write_quality_json.py .

dashboard: ## View project quality dashboard via HTTP server (make serve)
	@echo "File-served dashboards removed. Run: make serve"

ifndef SERVE_DEFINED
serve: ## Start operator server → http://localhost:7842 (live dashboard + review triage)
	uv run --project $(QUALITY_TOOLS_DIR)/.. python $(QUALITY_TOOLS_DIR)/server.py $(CURDIR) $(notdir $(CURDIR))
endif

auto-fix: ## Classify findings + quality violations, stage validated fixes → reports/auto-fixes/
	python3 $(QUALITY_TOOLS_DIR)/auto_resolver.py .

commit-fix: ## Commit a single staged fix to its branch: make commit-fix ID=<fix-id>
	@test -n "$(ID)" || (echo "Usage: make commit-fix ID=<fix-id>"; exit 1)
	@DIFF=$$(find reports/auto-fixes -name "fix-$(ID).diff" 2>/dev/null | head -1); \
	MSG=$$(find reports/auto-fixes -name "fix-$(ID).msg" 2>/dev/null | head -1); \
	test -n "$$DIFF" || (echo "Fix $(ID) not found in reports/auto-fixes/"; exit 1); \
	TYPE=$$(dirname "$$DIFF" | xargs basename); \
	BRANCH=auto-fix/$$TYPE; \
	CURRENT=$$(git rev-parse --abbrev-ref HEAD); \
	git checkout -b "$$BRANCH" 2>/dev/null || git checkout "$$BRANCH"; \
	git apply "$$DIFF" && git add -A && git commit -F "$$MSG"; \
	git checkout "$$CURRENT"

commit-fixes: ## Commit all staged fixes for a branch: make commit-fixes BRANCH=<type>
	@test -n "$(BRANCH)" || (echo "Usage: make commit-fixes BRANCH=<type>  (lint|type-harden|observability|test-gen)"; exit 1)
	@DIR=reports/auto-fixes/$(BRANCH); \
	test -d "$$DIR" || (echo "No staged fixes for branch $(BRANCH)"; exit 1); \
	CURRENT=$$(git rev-parse --abbrev-ref HEAD); \
	git checkout -b "auto-fix/$(BRANCH)" 2>/dev/null || git checkout "auto-fix/$(BRANCH)"; \
	for JSON in "$$DIR"/fix-*.json; do \
	    ID=$$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$$JSON" 2>/dev/null); \
	    STATUS=$$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['status'])" "$$JSON" 2>/dev/null); \
	    test "$$STATUS" = "staged" || continue; \
	    DIFF="$$DIR/fix-$$ID.diff"; MSG="$$DIR/fix-$$ID.msg"; \
	    test -f "$$DIFF" || continue; \
	    git apply "$$DIFF" && git add -A && git commit -F "$$MSG" && \
	    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); d['status']='committed'; json.dump(d,open(sys.argv[1],'w'),indent=2)" "$$JSON"; \
	done; \
	git checkout "$$CURRENT"
