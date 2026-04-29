ARTIFACTS := artifacts

.PHONY: fetch clean update

fetch:
	bash ./artifacts.sh

update:
	uv run update-versions.py -u

clean:
	rm -rf $(ARTIFACTS)
