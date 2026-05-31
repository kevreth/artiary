# Artiary

Artifact management system for offline Docker development environments. Downloads, builds, and version-pins external dependencies — Docker images, apt packages, npm/pip packages, and script binaries — so Docker workspaces can be built entirely without internet access.

## How it works

Artiary operates in two passes:

1. **Resolve** — queries upstream APIs (Docker Registry, npm, PyPI, apt, GitHub Releases) and pins every floating version to an exact digest or version number, writing a locked manifest to `~/.local/share/artiary/versions.yml`.
2. **Fetch** — downloads every artifact in the locked manifest to `~/.cache/artiary/artifacts/`, where the `docker/` repo picks them up via Docker `additional_contexts`.

`versions.yml` in this repo is the source of truth for *what* to track; the resolved copy outside the repo is the source of truth for *which exact version* to use.

## Usage

```bash
make resolve      # Pin all floating versions to exact digests/versions
make fetch        # Download all artifacts per resolved manifest
make update       # Alias for resolve
make clean        # Remove all cached artifacts
```

Checking and updating versions:

```bash
uv run update-versions.py          # List outdated packages
uv run update-versions.py -i       # Interactive — pick which packages to update
uv run update-versions.py -u       # Update all to latest
uv run update-versions.py --resolve  # Same as make resolve
```

## Structure

```
artiary/
├── versions.yml              # Source manifest (floating versions)
├── update-versions.py        # Version resolver & updater
├── artifacts.sh              # Downloads artifacts per resolved manifest
├── Makefile
├── builders/                 # Custom offline bundle builders
│   ├── mistral/              # mistral-vibe CLI offline bundle
│   ├── playwright/           # playwright-chromium offline bundle
│   ├── kimi/                 # kimi-cli offline bundle
│   └── kiro/                 # kiro-cli offline bundle
└── docs/
    ├── CONTEXT.md
    └── PROTOCOL.md
```

## Supported artifact types

| Type | Source | Example |
|------|--------|---------|
| Docker images | Docker Registry API | `node:24-trixie` → `node:24-trixie@sha256:…` |
| npm packages | npm registry JSON API | `playwright`, `opencode-ai` |
| pip packages | PyPI JSON API | `black`, `pytest`, `mypy` |
| apt packages | Debian package repos | `git`, `build-essential` |
| Script binaries | GitHub Releases / direct URLs | `gh`, `claude`, `jq`, `yq` |
| Custom builders | Builder scripts | `mistral-vibe`, `playwright-chromium`, `kimi-cli` |

Custom builders produce self-contained tarballs with install scripts for offline use.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ARTIARY_DATA_DIR` | `~/.local/share/artiary` | Where the resolved `versions.yml` is stored |
| `ARTIARY_VERSIONS` | `$ARTIARY_DATA_DIR/versions.yml` | Path to resolved manifest |
| `ARTIARY_ARTIFACTS` | `~/.cache/artiary/artifacts` | Where downloaded artifacts are stored |
| `ARTIARY_TMP` | `~/.cache/artiary/tmp` | Temporary working directory |
| `ARTIARY_UPDATE_CACHE` | `/tmp/artiary-update-cache` | Cache for apt package metadata (24h TTL) |

## Requirements

- Python 3.13 via [`uv`](https://github.com/astral-sh/uv)
- No local Docker daemon required — version checks query the Docker Registry API directly
