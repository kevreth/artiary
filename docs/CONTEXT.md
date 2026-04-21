# Artiary

> **Docs Convention**: Read `docs/PROTOCOL.md` if you haven't already in this session.

## Purpose

Artifact management system. Downloads, builds, and freezes external dependencies (Docker images, apt packages, npm packages, builder tarballs) so the Docker environment can be built entirely offline.

## Files

| File | Purpose |
|------|---------|
| `versions.yml` | Canonical manifest of all dependency versions (apt, npm, images, install scripts) |
| `artifacts.sh` | Fetches all artifacts defined in `versions.yml` into `artifacts/` |
| `freeze.sh` | Pins Docker image to specific digest and locks apt package versions |
| `Makefile` | Targets: `fetch`, `freeze`, `thaw`, `clean`, `manifest`, `test-mistral` |
| `artifacts/` | Downloaded/cached artifacts (images, apt lists, npm tarballs, builders) |
| `builders/` | Custom builder definitions (e.g., `mistral/`) |

## Commands

```bash
make fetch        # Download all artifacts per versions.yml
make freeze       # Pin image digest and apt versions; requires fetched artifacts
make thaw         # Remove version pins (revert to floating versions)
make clean        # Remove all artifacts/
make manifest     # Copy versions.yml into artifacts/manifest/
make test-mistral # Test the Mistral offline builder
```

## Key Details

- `artifacts/` is gitignored; it is produced by `make fetch`
- `freeze.sh` requires the Node image to be loaded locally before it can compute the digest
- `thaw` strips `@sha256:...` from image refs and `=version` from apt packages, then regenerates manifest
- The Docker workspace consumes `artiary/artifacts/` during container build
