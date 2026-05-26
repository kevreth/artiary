ROOT      := $(realpath ../..)
ARTIFACTS ?= $(HOME)/.cache/artiary/artifacts
VERSIONS  ?= $(HOME)/.local/share/artiary/versions.yml
BUNDLE    := kiro-cli-offline
VERSION   := $(shell yq '.scripts.kiro.version' $(VERSIONS) | tr -d '"')
ARTIFACT  := $(ARTIFACTS)/builders/kiro/$(BUNDLE)-$(VERSION).tar.xz

.PHONY: test clean

# Verify the bundle consumes like a plain binary artifact: extract, copy the
# executables onto PATH, and confirm they run inside the base image — no
# install script, no `kiro-cli setup`.
test:
	@test -f "$(ARTIFACT)" || \
	    (echo "ERROR: artifact not found at $(ARTIFACT) — run 'make fetch' from repo root first" && exit 1)
	docker load -i $(ARTIFACTS)/images/*.tar 2>/dev/null || true
	docker run --rm \
	    -v "$(ARTIFACT):/tmp/bundle.tar.xz:ro" \
	    $$(yq '.image.base' $(VERSIONS) | tr -d '"') \
	    bash -c 'cd /tmp && tar xJf bundle.tar.xz && \
	        cp $(BUNDLE)/kiro-cli* /usr/local/bin/ && \
	        kiro-cli --version && kiro-cli-chat --version'

clean:
	rm -rf $(ARTIFACTS)/builders/kiro/
