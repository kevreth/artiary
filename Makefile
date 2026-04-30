ARTIARY_DATA_DIR ?= $(HOME)/.local/share/artiary
ARTIARY_VERSIONS ?= $(ARTIARY_DATA_DIR)/versions.yml
ARTIARY_ARTIFACTS ?= $(HOME)/.cache/artiary/artifacts

export ARTIARY_DATA_DIR ARTIARY_VERSIONS ARTIARY_ARTIFACTS

.PHONY: resolve fetch clean update

resolve:
	uv run update-versions.py --resolve

fetch: resolve
	bash ./artifacts.sh

update:
	$(MAKE) resolve

clean:
	rm -rf $(ARTIARY_ARTIFACTS)
