ARTIFACTS := artifacts
MANIFEST := $(ARTIFACTS)/manifest/versions.yml
NODE_TAR := $(ARTIFACTS)/images/node.tar

.PHONY: fetch freeze thaw clean manifest test-kimi test-mistral export

fetch:
	bash ./artifacts.sh

manifest:
	@mkdir -p $(dir $(MANIFEST))
	cp versions.yml $(MANIFEST)

freeze:
	@test -f $(NODE_TAR) || \
	    (echo "ERROR: artifact image missing - run 'make fetch' in artiary first" && exit 1)
	docker load -i $(NODE_TAR)
	bash ./freeze.sh

thaw:
	yq -i '.image.node |= sub("@sha256:[a-f0-9]+", "")' versions.yml
	yq -i '.apt[] |= sub("=.*", "")' versions.yml
	$(MAKE) manifest

clean:
	rm -rf $(ARTIFACTS)

test-kimi:
	$(MAKE) -C builders/kimi test

test-mistral:
	$(MAKE) -C builders/mistral test

export:
	@if [ -z "$(DEST)" ]; then \
		echo "ERROR: DEST is required. Usage: make export DEST=../docker/artifacts"; \
		exit 1; \
	fi
	@mkdir -p "$(DEST)"
	@cp -r $(ARTIFACTS)/* "$(DEST)/"
	@echo "Artifacts exported to $(DEST)"
