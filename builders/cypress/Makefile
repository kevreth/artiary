ROOT      := $(realpath ../..)
ARTIFACTS ?= $(HOME)/.cache/artiary/artifacts
VERSIONS  ?= $(HOME)/.local/share/artiary/versions.yml
BUNDLE    := cypress-offline
VERSION   := $(shell yq '.scripts.cypress.version' $(VERSIONS) | tr -d '"')
ARTIFACT  := $(ARTIFACTS)/builders/cypress/$(BUNDLE)-$(VERSION).tar.gz

.PHONY: test clean

# Verify the bundled binary works without re-downloading: restore the cache via
# install.sh, install the cypress npm CLI with the binary download disabled
# (CYPRESS_INSTALL_BINARY=0), then confirm `cypress verify` finds and accepts
# the cached binary inside the base image.
test:
	@test -f "$(ARTIFACT)" || \
	    (echo "ERROR: artifact not found at $(ARTIFACT) — run 'make fetch' from repo root first" && exit 1)
	docker load -i $(ARTIFACTS)/images/*.tar 2>/dev/null || true
	docker run --rm \
	    -v "$(ARTIFACT):/tmp/bundle.tar.gz:ro" \
	    -e CYPRESS_CACHE_FOLDER=/root/.cache/Cypress \
	    -e CYPRESS_INSTALL_BINARY=0 \
	    $$(yq '.image.base' $(VERSIONS) | tr -d '"') \
	    bash -c 'cd /tmp && tar xzf bundle.tar.gz && \
	        bash $(BUNDLE)/install.sh && \
	        npm install -g cypress@$(VERSION) && \
	        cypress verify'

clean:
	rm -rf $(ARTIFACTS)/builders/cypress/
