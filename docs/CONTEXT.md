---
title: "Artiary"
---

# Artiary

> **Docs Convention**: Read `docs/PROTOCOL.md` if you haven't already in this session.

## Purpose

Artifact management system for offline Docker development environments. Downloads, builds, and version-pins external dependencies (Docker images, apt packages, npm packages, pip packages, script binaries) so the Docker workspace can be built entirely offline.

## Architecture

```
artiary/
├── versions.yml              # Source manifest (floating versions)
├── update-versions.py        # Version resolver & updater (replaces legacy freeze.sh)
├── artifacts.sh              # Downloads artifacts per resolved manifest
├── Makefile                  # Build targets
├── builders/                 # Custom offline bundle builders
│   ├── mistral/              # mistral-vibe CLI offline bundle
│   ├── playwright/           # playwright-chromium offline bundle
│   └── kimi/                 # kimi-cli offline bundle
└── docs/
    ├── CONTEXT.md            # This file
    └── PROTOCOL.md           # Development guidelines
```

## Files

| File | Purpose |
|------|---------|
| `versions.yml` | Source manifest with floating versions (apt, npm, pip, images, scripts) |
| `update-versions.py` | Checks/updates versions via upstream APIs; resolves to pinned manifest |
| `artifacts.sh` | Fetches all artifacts defined in resolved manifest into `ARTIARY_ARTIFACTS` |
| `Makefile` | Targets: `resolve`, `fetch`, `clean`, `update` |
| `~/.local/share/artiary/versions.yml` | Resolved manifest with pinned versions (digest, exact versions) |
| `~/.cache/artiary/artifacts/` | Downloaded artifacts (images, apt .deb, npm tarballs, pip wheels, scripts) |
| `builders/` | Custom builder scripts that produce offline-installable tarballs |

## Commands

```bash
make resolve      # Pin versions (Docker digest, exact apt/npm/pip/script versions)
make fetch        # Download all artifacts per resolved versions.yml
make update       # Alias for resolve (update version pins)
make clean        # Remove all cached artifacts
```

### Python Script Direct Usage

```bash
uv run update-versions.py          # List outdated packages
uv run update-versions.py -i       # Interactive mode (select packages to update)
uv run update-versions.py -u       # Update all outdated packages
uv run update-versions.py --resolve  # Resolve and pin versions (same as make resolve)
```

## Key Details

- **Source vs Resolved**: `versions.yml` in repo has floating versions; resolved copy in `~/.local/share/artiary/versions.yml` has pinned versions with digest and exact package versions
- **Artifacts directory**: Controlled by `ARTIARY_ARTIFACTS` env var (default: `~/.cache/artiary/artifacts`), not in repo
- **Data directory**: Controlled by `ARTIARY_DATA_DIR` env var (default: `~/.local/share/artiary`)
- **No local Docker required for version checks**: `update-versions.py` queries Docker Registry API directly
- **APT caching**: Package metadata cached for 24 hours in `/tmp/artiary-update-cache/` to avoid slow downloads
- **Builders**: Produce self-contained tarballs with install scripts for offline use

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ARTIARY_DATA_DIR` | `~/.local/share/artiary` | Where resolved `versions.yml` is stored |
| `ARTIARY_VERSIONS` | `$ARTIARY_DATA_DIR/versions.yml` | Path to resolved manifest |
| `ARTIARY_ARTIFACTS` | `~/.cache/artiary/artifacts` | Where downloaded artifacts are stored |
| `ARTIARY_TMP` | `~/.cache/artiary/tmp` | Temporary working directory |
| `ARTIARY_UPDATE_CACHE` | `/tmp/artiary-update-cache` | Cache for APT package metadata |

## Supported Package Types

| Type | Source | Example |
|------|--------|---------|
| Docker images | Docker Registry API | `node:24-trixie` → `node:24-trixie@sha256:...` |
| NPM packages | npm registry JSON API | `playwright`, `opencode-ai` |
| Pip packages | PyPI JSON API | `black`, `pytest`, `mypy` |
| APT packages | Debian package repos | `git`, `python3`, `build-essential` |
| Script binaries | GitHub Releases / direct URLs | `gh`, `claude`, `yq`, `jq` |
| Custom builders | Builder scripts | `mistral-vibe`, `playwright-chromium`, `kimi-cli` |
