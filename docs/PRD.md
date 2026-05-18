---
title: "Artiary - Product Requirements Document"
---

# Artiary - Product Requirements Document

## 1. Overview

Artiary is an artifact management system designed for offline Docker development environments. It addresses the challenge of building Docker images in air-gapped or unreliable network environments by pre-downloading, version-pinning, and caching all external dependencies required by a development workspace.

## 2. Problem Statement

Building Docker development environments typically requires downloading dependencies from multiple external sources (Docker Hub, npm registry, PyPI, Debian repos, GitHub Releases). In offline or restricted network environments, this creates several problems:

- **Unreliable builds**: Network failures cause build failures
- **Non-reproducible builds**: Floating versions lead to inconsistent environments
- **Slow iteration**: Repeated downloads waste time during development
- **Air-gap incompatibility**: Cannot build without internet access

## 3. Target Users

- **DevOps Engineers**: Setting up reproducible development environments
- **Developer Experience Teams**: Creating offline-capable development containers
- **Enterprise Teams**: Working in air-gapped or security-restricted networks
- **Open Source Maintainers**: Providing offline installation options for their tools

## 4. Core Features

### 4.1 Version Management

**Description**: Maintain a manifest (`versions.yml`) that tracks all external dependencies with their version requirements.

**Requirements**:
- Support floating versions (e.g., `node:24-trixie`, `playwright` latest)
- Resolve floating versions to exact pins (digest for images, exact versions for packages)
- Store resolved manifest separately from source manifest
- Support multiple package ecosystems: Docker, npm, PyPI, APT, binary scripts

### 4.2 Version Resolution (`update-versions.py`)

**Description**: Query upstream sources to determine latest available versions and update the manifest.

**Requirements**:
- Query Docker Registry API v2 for image digest pins
- Query npm registry JSON API for latest package versions
- Query PyPI JSON API for latest package versions
- Query Debian package repositories for APT package versions
- Query GitHub Releases API for script binary versions
- Support direct version URL checks (e.g., Claude CLI)
- Cache APT package metadata for 24 hours to avoid slow downloads
- Operate without local Docker daemon for version checks

**CLI Interface**:
```
uv run update-versions.py            # List outdated packages
uv run update-versions.py -i         # Interactive multi-select update
uv run update-versions.py -u         # Update all outdated packages
uv run update-versions.py --resolve  # Generate pinned manifest
```

### 4.3 Artifact Fetching (`artifacts.sh`)

**Description**: Download all artifacts defined in the resolved manifest into a local cache.

**Requirements**:
- Download Docker images via `docker pull` and `docker save`
- Download APT packages with full dependency resolution
- Download npm packages via Docker container or host npm
- Download pip packages via `pip download`
- Download script binaries via direct URL or builder scripts
- Prune stale artifacts not in current manifest
- Support offline operation after initial fetch

**Environment Variables**:
- `ARTIARY_DATA_DIR`: Where resolved manifest is stored (default: `~/.local/share/artiary`)
- `ARTIARY_VERSIONS`: Path to resolved manifest
- `ARTIARY_ARTIFACTS`: Where downloaded artifacts are stored (default: `~/.cache/artiary/artifacts`)
- `ARTIARY_TMP`: Temporary working directory
- `ARTIARY_UPDATE_CACHE`: Cache location for APT metadata

### 4.4 Custom Builders

**Description**: Build self-contained offline installation bundles for complex tools.

**Requirements**:
- Support builder scripts in `builders/` directory
- Each builder produces a tarball with install script
- Bundle all dependencies needed for offline installation
- Current builders:
  - `mistral-vibe`: Python CLI tool with uv package manager
  - `playwright-chromium`: Browser binaries with APT dependencies
  - `kimi-cli`: Python CLI tool with uv-managed virtualenv

### 4.5 Makefile Interface

**Description**: Provide simple make targets for common operations.

**Targets**:
- `make resolve`: Pin all versions to exact digests/versions
- `make fetch`: Download all artifacts (runs resolve first)
- `make update`: Alias for resolve
- `make clean`: Remove all cached artifacts

## 5. User Stories

### Story 1: Initial Setup
As a DevOps engineer, I want to set up a new offline development environment so that I can build Docker images without internet access.

**Steps**:
1. Clone the artiary repository
2. Run `make fetch` to resolve versions and download all artifacts
3. Copy `~/.cache/artiary/artifacts/` to the target offline environment
4. Build Docker image referencing local artifacts

### Story 2: Update Dependencies
As a developer, I want to update specific dependencies to their latest versions so that I can stay current with security patches and features.

**Steps**:
1. Run `uv run update-versions.py` to see outdated packages
2. Run `uv run update-versions.py -i` for interactive selection
3. Select packages to update using spacebar, press Enter
4. Run `make fetch` to download new artifacts

### Story 3: Reproducible Build
As a team lead, I want to pin all dependency versions so that every team member gets identical development environments.

**Steps**:
1. Run `make resolve` to generate pinned manifest
2. Commit the source `versions.yml` to version control
3. Each team member runs `make fetch` to get identical artifacts
4. Docker builds use pinned digest from resolved manifest

### Story 4: Add New Tool
As a developer, I want to add a new CLI tool to the offline environment so that my team can use it without internet.

**Steps**:
1. Add tool to `versions.yml` under appropriate section (npm, pip, scripts)
2. If complex (like playwright), create a builder in `builders/`
3. Run `make fetch` to download/bundle the tool
4. Verify offline installation works using builder's install script

## 6. Technical Requirements

### 6.1 Architecture

```
Source versions.yml (floating) → update-versions.py → Resolved versions.yml (pinned)
                                                    ↓
                                            artifacts.sh → ~/.cache/artiary/artifacts/
                                                    ↓
                                            Docker build (offline)
```

### 6.2 Dependencies

**Python (update-versions.py)**:
- `requests` (hard requirement)
- `ruamel.yaml` or `PyYAML` (YAML handling)
- `questionary` (optional, for interactive mode)
- `rich` (optional, for pretty output)
- `prompt_toolkit` (optional, for advanced interactive UI)

**Bash (artifacts.sh)**:
- `bash` 4.0+
- `yq` (YAML processor)
- `docker` (optional, for image/npm fetching)
- `apt-get`/`apt-cache` (for APT resolution)
- `pip`/`python3` (for pip packages)
- `curl` (for script downloads)

### 6.3 Supported Package Types

| Type | Source | Pin Format | Example |
|------|--------|------------|---------|
| Docker images | Docker Registry API v2 | `sha256:` digest | `node:24-trixie@sha256:abc...` |
| NPM packages | npm registry JSON API | Exact version | `playwright@1.49.0` |
| Pip packages | PyPI JSON API | Exact version | `black==24.10.0` |
| APT packages | Debian package repos | Version string | `git=1:2.45.2-1` |
| Script binaries | GitHub Releases / URLs | Version string | `yq: 4.44.3` |
| Custom builders | Builder scripts | Version via script | `mistral-vibe-offline.tar.gz` |

## 7. Non-Functional Requirements

### 7.1 Performance
- APT metadata caching must expire after 24 hours
- Version checks should complete in < 30 seconds for typical manifest
- Artifact fetching should skip already-downloaded files

### 7.2 Reliability
- Graceful handling of network failures with informative errors
- Atomic manifest updates (don't corrupt on failure)
- Prune stale artifacts to prevent disk bloat

### 7.3 Usability
- Clear CLI output showing progress and errors
- Interactive mode with visual version diff highlighting
- Environment variables for customization without editing scripts

### 7.4 Maintainability
- Modular design: version resolution separate from artifact fetching
- Well-documented builder interface for adding new tools
- Python script with comprehensive docstring for AI reviewer guidance

## 8. Current Limitations

1. **APT architecture**: Currently hardcoded to `amd64`
2. **Docker dependency**: NPM artifact fetching prefers Docker container (falls back to host npm)
3. **Single distro**: APT packages derived from image base (e.g., `node:24-trixie` → `trixie`)
4. **No version rollback**: Manifest only tracks latest resolved versions

## 9. Future Considerations

### 9.1 Potential Enhancements
- Support multiple architectures (arm64, etc.)
- Add `make verify` target to check artifact integrity
- Support multiple Debian distros simultaneously
- Add `make diff` target to show version changes
- Implement artifact sharing via rsync/scp
- Add progress bars for long-running downloads
- Support private Docker registries and npm registries
- Add GPG signature verification for downloaded artifacts

### 9.2 Scalability
- Consider SQLite or similar for large artifact caches
- Implement incremental artifact fetching
- Add compression options for artifact storage

## 10. Success Metrics

- **Build reproducibility**: 100% identical builds from same resolved manifest
- **Offline capability**: Zero network calls during Docker build after `make fetch`
- **Update speed**: Interactive update workflow completes in < 1 minute
- **Disk efficiency**: Pruning removes > 95% of stale artifacts

## 11. Glossary

| Term | Definition |
|------|------------|
| **Manifest** | YAML file listing all dependencies and their versions |
| **Source manifest** | `versions.yml` in repo with floating versions |
| **Resolved manifest** | `~/.local/share/artiary/versions.yml` with pinned versions |
| **Artifact** | Downloaded file (image tar, .deb, .tgz, .whl, binary) |
| **Builder** | Script that creates self-contained offline installation bundle |
| **Digest** | SHA256 hash pinning Docker image to exact layer set |
