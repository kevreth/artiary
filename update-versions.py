#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Artiary Update Versions Script - AI Reviewer Guide
=================================================

## Context
Artiary uses `versions.yml` as the canonical manifest of all dependency versions (Docker images, NPM packages, PyPI packages, script binaries, APT packages).

## Requirements
1.  **Package Type Coverage**: Check all package categories defined in `versions.yml`:
    - Docker images: Query Docker Registry V2 API for latest digest (no local image pull required)
    - NPM packages: Query npm registry JSON API for latest version (no local npm install required)
    - PyPI packages: Query PyPI JSON API for latest version
    - Script binaries: Query appropriate upstream (GitHub Releases, direct version URLs, PyPI for CLI wrappers)
    - APT packages: Query Debian package repositories with 24-hour caching to avoid slow ~50MB Packages.xz downloads
2.  **CLI Compatibility**: Maintain identical interface to the original bash script:
    - Default: List outdated packages only
    - `-i`/`--interactive`: Interactive multi-select for packages to update (prefer `questionary` library, fallback to numbered stdin menu)
    - `-u`/`--update-all`: Update all outdated packages without prompting
    - `-h`/`--help`: Show usage instructions
3.  **YAML Preservation**: Update `versions.yml` in-place while preserving existing formatting, comments, and structure (use `ruamel.yaml` for round-trip support, fall back to `PyYAML` with formatting warnings)
4.  **Output**: Display outdated packages in a readable table (prefer `rich` library for pretty output, fallback to plain text)

## Design Decisions & Rationale
- **Direct Upstream Queries**: Eliminates the legacy freeze/thaw workflow that required local Docker image loads and APT list caching. All version data is fetched directly from authoritative sources.
- **Edge Case Handling**:
    - Yarn Berry: GitHub Releases return `@yarnpkg/cli/4.14.1` tags, so we strip the `@yarnpkg/cli/` prefix
    - Claude CLI: Version is served as plain text at `https://downloads.claude.ai/claude-code-releases/latest`
    - Factory Droid CLI: Version is stored as `VER="x.y.z"` in the script at `https://app.factory.ai/cli`
    - Docker Images: Use token-based auth with Docker Registry API, no local image required
- **Graceful Degradation**: Optional dependencies (`questionary` for prompts, `rich` for output, `ruamel.yaml` for YAML preservation) are used if available, with functional fallbacks if missing. `requests` and `PyYAML` are hard requirements.
- **Caching**: APT package index files are cached in `/tmp/artiary-update-cache/` with 24-hour expiration to avoid repeated slow downloads.

## Constraints
- Must not modify `versions.yml` unless packages are explicitly selected for update
- Must handle network errors (timeouts, rate limits, unreachable hosts) gracefully with informative stderr warnings
- Must maintain backward compatibility with the original bash script's CLI flags
- Script must be executable with `./update-versions.py` (shebang line included)
"""

import argparse
import hashlib
import lzma
import os
import re
import sys
import time
from pathlib import Path

# ─── Hard Requirements ───
try:
    import requests
except ImportError:
    print("Error: requests library is required. Install with: pip install requests", file=sys.stderr)
    sys.exit(1)

try:
    from ruamel.yaml import YAML
    ruamel_yaml = YAML()
    ruamel_yaml.preserve_quotes = True
    ruamel_yaml.indent(mapping=2, sequence=4, offset=2)
except ImportError:
    try:
        import yaml
        ruamel_yaml = None
        print("Warning: ruamel.yaml not found, using PyYAML which may not preserve formatting. Install ruamel.yaml for better results.", file=sys.stderr)
    except ImportError:
        print("Error: YAML library required. Install with: pip install ruamel.yaml or pyyaml", file=sys.stderr)
        sys.exit(1)

# ─── Optional Dependencies ───
try:
    import questionary
except ImportError:
    questionary = None

try:
    from rich.console import Console
    from rich.table import Table
except ImportError:
    Console = Table = None

try:
    from prompt_toolkit import Application
    from prompt_toolkit.formatted_text import ANSI, to_formatted_text
    from prompt_toolkit.key_binding import KeyBindings
    from prompt_toolkit.layout import Layout, Window
    from prompt_toolkit.layout.controls import FormattedTextControl
    from prompt_toolkit.styles import Style
    prompt_toolkit_available = True
except ImportError:
    prompt_toolkit_available = False

# ─── Constants ───
SOURCE_VERSIONS_FILE = Path(__file__).parent / "versions.yml"
ARTIARY_DATA_DIR = Path(os.environ.get("ARTIARY_DATA_DIR", Path.home() / ".local/share/artiary"))
VERSIONS_FILE = Path(os.environ.get("ARTIARY_VERSIONS", ARTIARY_DATA_DIR / "versions.yml"))
CACHE_DIR = Path(os.environ.get("ARTIARY_UPDATE_CACHE", "/tmp/artiary-update-cache"))
CACHE_EXPIRY = 86400  # 24 hours in seconds
DOCKER_REGISTRY = "https://registry-1.docker.io"
DOCKER_AUTH_URL = "https://auth.docker.io/token"
DEFAULT_HEADERS = {"User-Agent": "artiary-update-versions"}

# ─── Helpers ───
def get_cached_path(url: str) -> tuple[Path, bool]:
    """Return cache file path and whether it's still valid (under expiry time)."""
    CACHE_DIR.mkdir(exist_ok=True)
    url_hash = hashlib.md5(url.encode()).hexdigest()
    cache_file = CACHE_DIR / f"{url_hash}.cache"
    if cache_file.exists():
        age = time.time() - cache_file.stat().st_mtime
        if age < CACHE_EXPIRY:
            return cache_file, True
    return cache_file, False

def fetch_url(url: str, timeout: int = 10, cache_large: bool = True) -> str | None:
    """Fetch URL content with optional caching for large responses."""
    cache_file, valid = get_cached_path(url)
    if valid:
        return cache_file.read_text()
    try:
        resp = requests.get(url, timeout=timeout)
        resp.raise_for_status()
        content = resp.text
        if cache_large and len(content) > 1024 * 1024:  # Cache files >1MB
            cache_file.write_text(content)
        return content
    except Exception as e:
        print(f"Warning: Failed to fetch {url}: {e}", file=sys.stderr)
        return None

def fetch_response(url: str, timeout: int = 20, attempts: int = 3) -> requests.Response:
    """Fetch a URL with basic retries for transient network failures."""
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            resp = requests.get(url, timeout=timeout, headers=DEFAULT_HEADERS)
            resp.raise_for_status()
            return resp
        except Exception as e:
            last_error = e
            if attempt < attempts:
                time.sleep(attempt)
    raise last_error

# ─── Check Functions ───
def check_docker_image(config: dict) -> tuple | None:
    """Check Docker image for digest updates. Returns (type, name, current, latest) or None."""
    img_cfg = config.get("image", {})
    base = img_cfg.get("base")
    current = img_cfg.get("version")
    if not base or not current:
        return None

    image_name = base.split(":")[0]
    tag = base.split(":")[1] if ":" in base else "latest"
    repo = f"library/{image_name}" if "/" not in image_name else image_name

    try:
        # Get auth token
        token_resp = requests.get(
            f"{DOCKER_AUTH_URL}?service=registry.docker.io&scope=repository:{repo}:pull",
            timeout=10
        )
        token_resp.raise_for_status()
        token = token_resp.json().get("token")

        # Get manifest digest
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.docker.distribution.manifest.v2+json"
        }
        resp = requests.head(f"{DOCKER_REGISTRY}/v2/{repo}/manifests/{tag}", headers=headers, timeout=10)
        resp.raise_for_status()
        latest = resp.headers.get("Docker-Content-Digest")
        if latest and latest != current:
            return ("image", "image.base", current, latest)
    except Exception as e:
        print(f"Warning: Docker image check failed: {e}", file=sys.stderr)
    return None

def resolve_docker_image(config: dict) -> str | None:
    """Resolve the configured Docker image tag to a registry digest."""
    img_cfg = config.get("image", {})
    base = img_cfg.get("base")
    if not base:
        return None

    image_name = base.split(":")[0]
    tag = base.split(":")[1] if ":" in base else "latest"
    repo = f"library/{image_name}" if "/" not in image_name else image_name

    try:
        token_resp = requests.get(
            f"{DOCKER_AUTH_URL}?service=registry.docker.io&scope=repository:{repo}:pull",
            timeout=10
        )
        token_resp.raise_for_status()
        token = token_resp.json().get("token")
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.docker.distribution.manifest.v2+json"
        }
        resp = requests.head(f"{DOCKER_REGISTRY}/v2/{repo}/manifests/{tag}", headers=headers, timeout=10)
        resp.raise_for_status()
        return resp.headers.get("Docker-Content-Digest")
    except Exception as e:
        print(f"Warning: Docker image resolve failed for {base}: {e}", file=sys.stderr)
        return img_cfg.get("version")

def check_npm_packages(config: dict) -> list[tuple]:
    """Check NPM packages for updates. Returns list of (type, name, current, latest)."""
    updates = []
    for pkg, current in config.get("npm", {}).items():
        if not pkg or not current:
            continue
        try:
            resp = requests.get(f"https://registry.npmjs.org/{pkg}/latest", timeout=10)
            resp.raise_for_status()
            latest = resp.json().get("version")
            if latest and latest != current:
                updates.append(("npm", pkg, current, latest))
        except Exception as e:
            print(f"Warning: NPM check failed for {pkg}: {e}", file=sys.stderr)
    return updates

def check_pip_packages(config: dict) -> list[tuple]:
    """Check PyPI packages for updates. Returns list of (type, name, current, latest)."""
    updates = []
    for pkg, current in config.get("pip", {}).items():
        if not pkg or not current:
            continue
        try:
            resp = requests.get(f"https://pypi.org/pypi/{pkg}/json", timeout=10)
            resp.raise_for_status()
            latest = resp.json().get("info", {}).get("version")
            if latest and latest != current:
                updates.append(("pip", pkg, current, latest))
        except Exception as e:
            print(f"Warning: PyPI check failed for {pkg}: {e}", file=sys.stderr)
    return updates

def check_script_packages(config: dict) -> list[tuple]:
    """Check script binaries for updates. Returns list of (type, name, current, latest)."""
    updates = []
    for script, info in config.get("scripts", {}).items():
        current = info.get("version") if isinstance(info, dict) else info
        if not script or not current or current == "latest":
            continue

        latest = None
        try:
            if script == "claude":
                resp = requests.get("https://downloads.claude.ai/claude-code-releases/latest", timeout=10)
                latest = resp.text.strip()
            elif script == "gh":
                resp = requests.get("https://api.github.com/repos/cli/cli/releases/latest", timeout=10)
                latest = resp.json().get("tag_name", "").lstrip("v")
            elif script == "yq":
                resp = requests.get("https://api.github.com/repos/mikefarah/yq/releases/latest", timeout=10)
                latest = resp.json().get("tag_name", "").lstrip("v")
            elif script == "jq":
                resp = requests.get("https://api.github.com/repos/jqlang/jq/releases/latest", timeout=10)
                latest = resp.json().get("tag_name", "").lstrip("jq-")
            elif script == "goose":
                resp = requests.get("https://api.github.com/repos/aaif-goose/goose/releases/latest", timeout=10)
                latest = resp.json().get("tag_name", "").lstrip("v")
            elif script == "copilot":
                resp = requests.get("https://api.github.com/repos/github/copilot-cli/releases/latest", timeout=10)
                latest = resp.json().get("tag_name", "").lstrip("v")
            elif script == "factory-droid":
                resp = requests.get("https://app.factory.ai/cli", timeout=10)
                match = re.search(r'VER="([^"]+)"', resp.text)
                latest = match.group(1) if match else None
            elif script == "kimi":
                resp = requests.get("https://pypi.org/pypi/kimi-cli/json", timeout=10)
                latest = resp.json().get("info", {}).get("version")
            elif script == "kiro":
                resp = requests.get("https://prod.download.cli.kiro.dev/stable/latest/manifest.json", timeout=10)
                latest = resp.json().get("version")
            elif script == "mistral":
                resp = requests.get("https://pypi.org/pypi/mistral-vibe/json", timeout=10)
                latest = resp.json().get("info", {}).get("version")
            elif script == "yarn":
                resp = requests.get("https://api.github.com/repos/yarnpkg/berry/releases/latest", timeout=10)
                latest = resp.json().get("tag_name", "").lstrip("v").replace("@yarnpkg/cli/", "")
            elif script == "mise":
                resp = requests.get("https://mise.run", timeout=10)
                match = re.search(r'current_version="v([^"]+)"', resp.text)
                latest = match.group(1) if match else None
            elif script == "quarto":
                resp = requests.get("https://api.github.com/repos/quarto-dev/quarto-cli/releases/latest", timeout=10)
                latest = resp.json().get("tag_name", "").lstrip("v")
            else:
                print(f"Warning: No check method for script {script}", file=sys.stderr)
                continue

            if latest and latest != current:
                updates.append(("script", script, current, latest))
        except Exception as e:
            print(f"Warning: Script check failed for {script}: {e}", file=sys.stderr)
    return updates

def resolve_script_version(script: str, info: dict | str) -> str | None:
    """Resolve the latest supported script or builder version."""
    current = info.get("version") if isinstance(info, dict) else info
    try:
        if script == "claude":
            resp = fetch_response("https://downloads.claude.ai/claude-code-releases/latest")
            return resp.text.strip()
        if script == "gh":
            resp = fetch_response("https://api.github.com/repos/cli/cli/releases/latest")
            return resp.json().get("tag_name", "").lstrip("v")
        if script == "yq":
            resp = fetch_response("https://api.github.com/repos/mikefarah/yq/releases/latest")
            return resp.json().get("tag_name", "").lstrip("v")
        if script == "jq":
            resp = fetch_response("https://api.github.com/repos/jqlang/jq/releases/latest")
            return resp.json().get("tag_name", "").lstrip("jq-")
        if script == "goose":
            resp = fetch_response("https://api.github.com/repos/aaif-goose/goose/releases/latest")
            return resp.json().get("tag_name", "").lstrip("v")
        if script == "copilot":
            resp = fetch_response("https://api.github.com/repos/github/copilot-cli/releases/latest")
            return resp.json().get("tag_name", "").lstrip("v")
        if script == "factory-droid":
            resp = fetch_response("https://app.factory.ai/cli")
            match = re.search(r'VER="([^"]+)"', resp.text)
            return match.group(1) if match else current
        if script == "kimi":
            resp = fetch_response("https://pypi.org/pypi/kimi-cli/json")
            return resp.json().get("info", {}).get("version")
        if script == "kiro":
            resp = fetch_response("https://prod.download.cli.kiro.dev/stable/latest/manifest.json")
            return resp.json().get("version")
        if script == "mistral":
            resp = fetch_response("https://pypi.org/pypi/mistral-vibe/json")
            return resp.json().get("info", {}).get("version")
        if script == "yarn":
            resp = fetch_response("https://api.github.com/repos/yarnpkg/berry/releases/latest")
            return resp.json().get("tag_name", "").lstrip("v").replace("@yarnpkg/cli/", "")
        if script == "mise":
            resp = fetch_response("https://mise.run")
            match = re.search(r'current_version="v([^"]+)"', resp.text)
            return match.group(1) if match else current
        if script == "playwright-chromium":
            return current or "latest"
        if script == "quarto":
            resp = fetch_response("https://api.github.com/repos/quarto-dev/quarto-cli/releases/latest")
            return resp.json().get("tag_name", "").lstrip("v")
        print(f"Warning: No resolve method for script {script}", file=sys.stderr)
    except Exception as e:
        print(f"Warning: Script resolve failed for {script}: {e}", file=sys.stderr)
    return current

def check_apt_packages(config: dict) -> list[tuple]:
    """Check APT packages for updates. Returns list of (type, name, current, latest)."""
    updates = []
    apt_cfg = config.get("apt", {})

    # Determine distro and arch
    distro = None
    arch = "amd64"

    # Parse packages based on apt config format (dict or list)
    packages_to_check = {}  # lookup_name -> (original_name, version)

    if isinstance(apt_cfg, dict):
        distro = apt_cfg.get("distro", None)
        arch = apt_cfg.get("architecture", "amd64")
        for pkg, ver in apt_cfg.items():
            if pkg in ("distro", "architecture"):
                continue
            lookup_name = pkg.split(':')[0]
            packages_to_check[lookup_name] = (pkg, ver)
    elif isinstance(apt_cfg, list):
        # List format: "pkg=version" or "pkg"
        for entry in apt_cfg:
            if '=' in entry:
                pkg, ver = entry.split('=', 1)
                lookup_name = pkg.split(':')[0]
                packages_to_check[lookup_name] = (pkg, ver)
            # Entries without version are skipped (nothing to compare)
    else:
        return updates

    if not packages_to_check:
        return updates

    # Derive distro from image base if not specified
    if distro is None:
        image_base = config.get("image", {}).get("base", "")
        for d in ["trixie", "bookworm", "bullseye", "buster", "sid"]:
            if d in image_base:
                distro = d
                break
        if distro is None:
            distro = "bullseye"

    print(f"Checking APT packages (distro: {distro}, arch: {arch})...", file=sys.stderr)

    try:
        pkg_versions = fetch_debian_versions(config)

        # Compare versions
        for lookup_name, (original_name, current) in packages_to_check.items():
            latest = pkg_versions.get(lookup_name)
            if latest and latest != current:
                updates.append(("apt", original_name, current, latest))
    except Exception as e:
        print(f"Warning: APT check failed: {e}", file=sys.stderr)
    return updates

def _dpkg_version_gt(v1: str, v2: str) -> bool:
    """Return True if v1 is strictly greater than v2 per dpkg version ordering."""
    import subprocess
    return subprocess.run(["dpkg", "--compare-versions", v1, "gt", v2],
                          capture_output=True).returncode == 0

def fetch_debian_package_metadata(config: dict) -> tuple[dict[str, str], dict[str, list[str]]]:
    """Fetch Debian package versions and Provides mappings for the distro implied by image.base."""
    distro = None
    arch = "amd64"
    apt_cfg = config.get("apt", {})
    if isinstance(apt_cfg, dict):
        distro = apt_cfg.get("distro")
        arch = apt_cfg.get("architecture", arch)

    if distro is None:
        image_base = config.get("image", {}).get("base", "")
        for candidate in ["trixie", "bookworm", "bullseye", "buster", "sid"]:
            if candidate in image_base:
                distro = candidate
                break
    distro = distro or "bullseye"

    print(f"Resolving APT packages (distro: {distro}, arch: {arch})...", file=sys.stderr)
    versions = {}
    provides = {}
    suites = [
        ("http://deb.debian.org/debian", distro),
        ("http://deb.debian.org/debian-security", f"{distro}-security"),
        ("http://deb.debian.org/debian", f"{distro}-updates"),
    ]
    architectures = [arch]
    if arch != "all":
        architectures.append("all")

    for base_url, suite in suites:
        for package_arch in architectures:
            url = f"{base_url}/dists/{suite}/main/binary-{package_arch}/Packages.xz"
            cache_file, valid = get_cached_path(url)
            if valid:
                content = cache_file.read_bytes()
            else:
                resp = requests.get(url, timeout=30)
                resp.raise_for_status()
                content = resp.content
                cache_file.write_bytes(content)

            packages_text = lzma.decompress(content).decode("utf-8")
            current_pkg = None
            for line in packages_text.splitlines():
                if line.startswith("Package:"):
                    current_pkg = line.split(":", 1)[1].strip()
                elif line.startswith("Version:") and current_pkg:
                    new_ver = line.split(":", 1)[1].strip()
                    existing = versions.get(current_pkg)
                    # Keep the highest version across all suites (security repos can lag main).
                    if existing is None or _dpkg_version_gt(new_ver, existing):
                        versions[current_pkg] = new_ver
                elif line.startswith("Provides:") and current_pkg:
                    for provided in line.split(":", 1)[1].split(","):
                        alias = provided.strip().split(" ", 1)[0]
                        if not alias:
                            continue
                        providers = provides.setdefault(alias, [])
                        if current_pkg not in providers:
                            providers.append(current_pkg)
    return versions, provides

def fetch_debian_versions(config: dict) -> dict[str, str]:
    """Fetch Debian package versions for the distro implied by image.base."""
    versions, _ = fetch_debian_package_metadata(config)
    return versions

def resolve_apt_packages(config: dict) -> tuple[list[str], list[str]]:
    """Resolve top-level APT package entries to exact Debian versions."""
    apt_cfg = config.get("apt", {})
    if isinstance(apt_cfg, dict):
        package_entries = [
            name for name in apt_cfg
            if name not in ("distro", "architecture")
        ]
    elif isinstance(apt_cfg, list):
        package_entries = list(apt_cfg)
    else:
        return [], []

    try:
        debian_versions, provided_by = fetch_debian_package_metadata(config)
    except Exception as e:
        raise RuntimeError(f"APT resolve failed: {e}") from e

    resolved = []
    unresolved = []
    for entry in package_entries:
        entry_str = str(entry)
        # Locked entries (pkg=version) are preserved as-is, not re-resolved to latest.
        if "=" in entry_str:
            resolved.append(entry_str)
            continue
        name = entry_str
        lookup_name = name.split(":", 1)[0]
        latest = debian_versions.get(lookup_name)
        if latest:
            resolved.append(f"{name}={latest}")
            continue

        providers = provided_by.get(lookup_name, [])
        if len(providers) == 1 and debian_versions.get(providers[0]):
            provider_name = providers[0]
            resolved.append(f"{provider_name}={debian_versions[provider_name]}")
        else:
            unresolved.append(name)
    return resolved, unresolved

def resolve_mapping_versions(packages, fetch_latest) -> tuple[dict, list[str]]:
    """Resolve a list or mapping of package names to exact versions."""
    names = packages.keys() if isinstance(packages, dict) else packages or []
    resolved = {}
    unresolved = []
    for name in names:
        current = packages.get(name) if isinstance(packages, dict) else None
        try:
            latest = fetch_latest(name)
            if latest:
                resolved[name] = latest
            elif current:
                resolved[name] = current
            else:
                unresolved.append(name)
        except Exception as e:
            if current:
                print(f"Warning: Failed to resolve {name}: {e}", file=sys.stderr)
                resolved[name] = current
            else:
                unresolved.append(name)
    return resolved, unresolved

def resolve_versions(config: dict) -> dict:
    """Resolve the source manifest into a pinned lock manifest."""
    resolved = dict(config)
    unresolved = []
    resolved["image"] = dict(config.get("image", {}))
    digest = resolve_docker_image(config)
    if digest:
        resolved["image"]["version"] = digest
    else:
        unresolved.append("image.base")

    resolved["npm"], npm_unresolved = resolve_mapping_versions(
        config.get("npm", {}),
        lambda name: requests.get(f"https://registry.npmjs.org/{name}/latest", timeout=10).json().get("version")
    )
    unresolved.extend(f"npm:{name}" for name in npm_unresolved)

    resolved["pip"], pip_unresolved = resolve_mapping_versions(
        config.get("pip", {}),
        lambda name: requests.get(f"https://pypi.org/pypi/{name}/json", timeout=10).json().get("info", {}).get("version")
    )
    unresolved.extend(f"pip:{name}" for name in pip_unresolved)

    scripts = {}
    for name, info in (config.get("scripts", {}) or {}).items():
        script_info = dict(info) if isinstance(info, dict) else {"version": info}
        latest = resolve_script_version(name, script_info)
        if latest:
            script_info["version"] = latest
        else:
            unresolved.append(f"script:{name}")
        scripts[name] = script_info
    resolved["scripts"] = scripts
    resolved["apt"], apt_unresolved = resolve_apt_packages(config)
    unresolved.extend(f"apt:{name}" for name in apt_unresolved)

    if unresolved:
        raise RuntimeError("Failed to resolve: " + ", ".join(unresolved))
    return resolved

def write_versions(config: dict, path: Path) -> None:
    """Write a manifest to disk."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        if ruamel_yaml:
            ruamel_yaml.dump(config, f)
        else:
            yaml.dump(config, f, default_flow_style=False)

# ─── Core Logic ───
def collect_outdated(config: dict) -> list[tuple]:
    """Collect all outdated packages across all categories."""
    outdated = []
    print("Checking Docker image...", file=sys.stderr)
    if docker_update := check_docker_image(config):
        outdated.append(docker_update)
    print("Checking NPM packages...", file=sys.stderr)
    outdated.extend(check_npm_packages(config))
    print("Checking PIP packages...", file=sys.stderr)
    outdated.extend(check_pip_packages(config))
    print("Checking script packages...", file=sys.stderr)
    outdated.extend(check_script_packages(config))
    print("Checking APT packages...", file=sys.stderr)
    outdated.extend(check_apt_packages(config))
    return outdated

def format_outdated(outdated: list[tuple]) -> str:
    """Format outdated packages into a readable table."""
    if not outdated:
        return "All packages are up to date!"

    if Console and Table:
        console = Console()
        table = Table(title="Outdated Packages")
        table.add_column("Type", style="cyan")
        table.add_column("Package", style="magenta")
        table.add_column("Current", style="red")
        table.add_column("Latest", style="green")
        for type_, name, current, latest in outdated:
            table.add_row(type_, name, current, latest)
        with console.capture() as capture:
            console.print(table)
        return capture.get()
    else:
        lines = [
            f"{'TYPE':<6} {'PACKAGE':<25} {'CURRENT':<10} {'LATEST':<20}",
            "-" * 65
        ]
        for type_, name, current, latest in outdated:
            display_name = name[:25]
            lines.append(f"{type_:<6} {display_name:<25} {current:<10} {latest:<20}")
        return "\n".join(lines)

def update_versions(config: dict, to_update: list[tuple]) -> None:
    """Update versions.yml with selected package updates."""
    for type_, name, current, latest in to_update:
        if type_ == "image":
            config["image"]["version"] = latest
        elif type_ == "npm":
            config["npm"][name] = latest
        elif type_ == "pip":
            config["pip"][name] = latest
        elif type_ == "script":
            if isinstance(config["scripts"][name], dict):
                config["scripts"][name]["version"] = latest
            else:
                config["scripts"][name] = latest
        elif type_ == "apt":
            # Handle both dict and list formats for apt
            if isinstance(config["apt"], dict):
                config["apt"][name] = latest
            elif isinstance(config["apt"], list):
                for i, entry in enumerate(config["apt"]):
                    if entry.startswith(name + "=") or entry == name:
                        config["apt"][i] = f"{name}={latest}"
                        break
        print(f"Updated {type_}/{name}: {current} -> {latest}")

    # Write back to versions.yml
    write_versions(config, VERSIONS_FILE)
    print(f"\nUpdated {VERSIONS_FILE}")

def highlight_version_diff(current: str, latest: str) -> str:
    """Return latest version string with changed parts in green ANSI."""
    GREEN = "\033[32m"
    RESET = "\033[0m"

    cur_parts = current.split(".")
    lat_parts = latest.split(".")

    result = []
    for i in range(len(lat_parts)):
        if i >= len(cur_parts) or lat_parts[i] != cur_parts[i]:
            result.append(f"{GREEN}{lat_parts[i]}{RESET}")
        else:
            result.append(lat_parts[i])

    return ".".join(result)


def format_package_line(idx: int, type_: str, name: str, current: str, latest: str,
                        selected: bool, is_cursor: bool) -> str:
    """Format a single package line for the interactive UI."""
    BOLD = "\033[1m"
    CYAN = "\033[36m"
    YELLOW = "\033[33m"
    GREEN = "\033[32m"
    RESET = "\033[0m"
    GREEN_BG = "\033[42m"
    WHITE = "\033[37m"

    # Cursor indicator
    cursor = "❯ " if is_cursor else "  "

    # Checkbox: filled (selected) or empty
    if selected:
        checkbox = f"{GREEN}◉{RESET}"
    else:
        checkbox = "◯"

    # Highlight version diff
    highlighted_latest = highlight_version_diff(current, latest)

    # Format: cursor + checkbox + type + name + current -> latest
    # Truncate name to fit in terminal (assume ~80 cols)
    display_name = name[:35] if len(name) > 35 else name
    type_short = type_[:4]  # npm, pip, apt, script->scr, image->img

    line = f"{cursor}{checkbox} {CYAN}{type_short}{RESET} {display_name:<35} {YELLOW}{current}{RESET} → {highlighted_latest}"
    return line


def select_packages_interactive(outdated: list[tuple]) -> list[tuple]:
    """Interactive package selection like npm-check-updates.

    UI similar to:
      ? Choose which packages to update ›
        ↑/↓: Select a package
        Space: Toggle selection
        a: Toggle all
        Enter: Upgrade

      ❯ ◉ @types/tabulator-tables    6.3.1  →    6.3.2
        ◉ astro                      6.1.7  →   6.1.10
    """
    if not outdated:
        return []

    # Check requirements: prompt_toolkit installed AND real terminal
    if not prompt_toolkit_available:
        print("Error: prompt_toolkit is required for interactive mode.", file=sys.stderr)
        print("Install with: uv add prompt_toolkit", file=sys.stderr)
        sys.exit(1)

    if not sys.stdin.isatty():
        print("Error: Interactive mode requires a real terminal.", file=sys.stderr)
        print("Use -u flag to update all packages non-interactively.", file=sys.stderr)
        sys.exit(1)

    selected_indices = set(range(len(outdated)))  # Start with all selected
    cursor_idx = 0

    # ANSI color codes (foreground only, no background)
    GREEN = "\033[32m"
    CYAN = "\033[36m"
    MAGENTA = "\033[35m"
    YELLOW = "\033[33m"
    BOLD = "\033[1m"
    RESET = "\033[0m"

    def get_formatted_text():
        lines = [
            "? Choose which packages to update ›",
            "  ↑/↓: Select a package",
            "  Space: Toggle selection",
            "  a: Toggle all",
            "  Enter: Upgrade",
            ""
        ]

        for i, (type_, name, current, latest) in enumerate(outdated):
            is_cursor = (i == cursor_idx)
            is_selected = i in selected_indices

            cursor_mark = f"{BOLD}❯{RESET} " if is_cursor else "  "

            if is_selected:
                checkbox = f"{GREEN}◉{RESET}"
            else:
                checkbox = "◯"

            type_str = f"{CYAN}{type_:<6}{RESET} "
            name_str = f"{MAGENTA}{name[:25]:<25}{RESET} "
            current_str = f"{YELLOW}{current:<10}{RESET} "
            arrow = "→ "

            # Version diff highlighting (only changed parts in green)
            cur_parts = current.split(".")
            lat_parts = latest.split(".")
            latest_display = ""
            for j in range(len(lat_parts)):
                if j >= len(cur_parts) or lat_parts[j] != cur_parts[j]:
                    latest_display += f"{GREEN}{lat_parts[j]}{RESET}"
                else:
                    latest_display += lat_parts[j]
                if j < len(lat_parts) - 1:
                    latest_display += "."

            line = f"{cursor_mark}{checkbox} {type_str}{name_str}{current_str}{arrow}{latest_display}"
            lines.append(line)

        return ANSI("\n".join(lines))

    # Key bindings
    kb = KeyBindings()

    @kb.add("up")
    def _(event):
        nonlocal cursor_idx
        cursor_idx = (cursor_idx - 1) % len(outdated)

    @kb.add("down")
    def _(event):
        nonlocal cursor_idx
        cursor_idx = (cursor_idx + 1) % len(outdated)

    @kb.add("space")
    def _(event):
        if cursor_idx in selected_indices:
            selected_indices.discard(cursor_idx)
        else:
            selected_indices.add(cursor_idx)

    @kb.add("a")
    def _(event):
        if len(selected_indices) == len(outdated):
            selected_indices.clear()
        else:
            selected_indices.update(range(len(outdated)))

    @kb.add("enter")
    def _(event):
        event.app.exit()

    @kb.add("c-c")
    @kb.add("q")
    def _(event):
        event.app.exit()
        selected_indices.clear()

    # Create and run the application
    control = FormattedTextControl(get_formatted_text)
    layout = Layout(Window(control))
    app = Application(layout=layout, key_bindings=kb, full_screen=False)
    app.run()

    # Return selected packages
    return [outdated[i] for i in sorted(selected_indices)]

# ─── Main ───
def main():
    parser = argparse.ArgumentParser(description="Check and update package versions in versions.yml")
    parser.add_argument("-i", "--interactive", action="store_true", help="Interactive mode to select packages")
    parser.add_argument("-u", "--update-all", action="store_true", help="Update all outdated packages")
    parser.add_argument("--resolve", action="store_true", help=f"Resolve source versions.yml into {VERSIONS_FILE}")
    args = parser.parse_args()

    # Load versions.yml
    input_file = SOURCE_VERSIONS_FILE if args.resolve else VERSIONS_FILE
    if not input_file.exists():
        print(f"Error: {input_file} not found", file=sys.stderr)
        sys.exit(1)

    if ruamel_yaml:
        with open(input_file, "r") as f:
            config = ruamel_yaml.load(f)
    else:
        with open(input_file, "r") as f:
            config = yaml.safe_load(f)

    if args.resolve:
        try:
            resolved = resolve_versions(config)
        except RuntimeError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
        write_versions(resolved, VERSIONS_FILE)
        print(f"Resolved {SOURCE_VERSIONS_FILE} -> {VERSIONS_FILE}")
        sys.exit(0)

    # Collect and display outdated packages
    outdated = collect_outdated(config)
    if not outdated:
        print("All packages are up to date!")
        sys.exit(0)

    # Determine packages to update
    to_update = []
    if args.update_all:
        print("\n" + format_outdated(outdated) + "\n")
        to_update = outdated
    elif args.interactive:
        # Skip printing table - interactive UI shows packages directly
        to_update = select_packages_interactive(outdated)
    else:
        print("\n" + format_outdated(outdated) + "\n")
        print("Run with -i for interactive selection or -u to update all.")
        sys.exit(0)

    if not to_update:
        print("No packages selected for update.")
        sys.exit(0)

    # Apply updates
    update_versions(config, to_update)
    print("\nDone! Run 'make fetch' to download new artifacts.")

if __name__ == "__main__":
    main()
