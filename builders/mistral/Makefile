ROOT      := $(realpath ../..)
ARTIFACTS := $(ROOT)/artifacts
VERSIONS  := $(ROOT)/versions.yml
BUNDLE    := mistral-vibe-offline

.PHONY: test clean

test:
	@test -f $(ARTIFACTS)/builders/mistral/$(BUNDLE).tar.gz || \
	    (echo "ERROR: artifact not found — run 'make artifacts' from repo root first" && exit 1)
	docker load -i $(ARTIFACTS)/images/node.tar
	docker run --rm \
	    -v "$(ARTIFACTS)/builders/mistral/$(BUNDLE).tar.gz:/tmp/bundle.tar.gz:ro" \
	    $$(yq '.image.node' $(VERSIONS)) \
	    bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends python3.13 && \
	        cd /tmp && tar xzf bundle.tar.gz && \
	        su node -s /bin/bash -c "cd /tmp && bash $(BUNDLE)/install.sh"'

clean:
	rm -rf $(ARTIFACTS)/builders/mistral/
