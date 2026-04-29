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
import json
import lzma
import os
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

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
    from prompt_toolkit.key_binding import KeyBindings
    from prompt_toolkit.layout import Layout, Window
    from prompt_toolkit.layout.controls import FormattedTextControl
    from prompt_toolkit.styles import Style
    from prompt_toolkit.formatted_text import to_formatted_text, ANSI
    prompt_toolkit_available = True
except ImportError:
    prompt_toolkit_available = False

# ─── Constants ───
VERSIONS_FILE = Path(__file__).parent / "versions.yml"
CACHE_DIR = Path("/tmp/artiary-update-cache")
CACHE_EXPIRY = 86400  # 24 hours in seconds
DOCKER_REGISTRY = "https://registry-1.docker.io"
DOCKER_AUTH_URL = "https://auth.docker.io/token"

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
            elif script == "mistral":
                resp = requests.get("https://pypi.org/pypi/mistral-vibe/json", timeout=10)
                latest = resp.json().get("info", {}).get("version")
            elif script == "yarn":
                resp = requests.get("https://api.github.com/repos/yarnpkg/berry/releases/latest", timeout=10)
                latest = resp.json().get("tag_name", "").lstrip("v").replace("@yarnpkg/cli/", "")
            else:
                print(f"Warning: No check method for script {script}", file=sys.stderr)
                continue

            if latest and latest != current:
                updates.append(("script", script, current, latest))
        except Exception as e:
            print(f"Warning: Script check failed for {script}: {e}", file=sys.stderr)
    return updates

def check_apt_packages(config: dict) -> list[tuple]:
    """Check APT packages for updates. Returns list of (type, name, current, latest)."""
    updates = []
    apt_cfg = config.get("apt", {})
    if not isinstance(apt_cfg, dict):
        return updates

    distro = apt_cfg.get("distro", "bullseye")
    arch = apt_cfg.get("architecture", "amd64")
    packages_to_check = {k: v for k, v in apt_cfg.items() if k not in ("distro", "architecture")}
    if not packages_to_check:
        return updates

    url = f"http://ftp.debian.org/debian/dists/{distro}/main/binary-{arch}/Packages.xz"
    print(f"Checking APT packages (distro: {distro}, arch: {arch})...", file=sys.stderr)

    try:
        # Fetch and cache package index
        cache_file, valid = get_cached_path(url)
        if valid:
            content = cache_file.read_bytes()
        else:
            resp = requests.get(url, timeout=30)
            resp.raise_for_status()
            content = resp.content
            cache_file.write_bytes(content)

        # Decompress and parse
        packages_text = lzma.decompress(content).decode("utf-8")
        pkg_versions = {}
        current_pkg = None
        for line in packages_text.splitlines():
            if line.startswith("Package:"):
                current_pkg = line.split(":")[1].strip()
            elif line.startswith("Version:") and current_pkg:
                pkg_versions[current_pkg] = line.split(":")[1].strip()

        # Compare versions
        for pkg, current in packages_to_check.items():
            latest = pkg_versions.get(pkg)
            if latest and latest != current:
                updates.append(("apt", pkg, current, latest))
    except Exception as e:
        print(f"Warning: APT check failed: {e}", file=sys.stderr)
    return updates

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
            config["apt"][name] = latest
        print(f"Updated {type_}/{name}: {current} -> {latest}")

    # Write back to versions.yml
    with open(VERSIONS_FILE, "w") as f:
        if ruamel_yaml:
            ruamel_yaml.dump(config, f)
        else:
            yaml.dump(config, f, default_flow_style=False)
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
    args = parser.parse_args()

    # Load versions.yml
    if not VERSIONS_FILE.exists():
        print(f"Error: {VERSIONS_FILE} not found", file=sys.stderr)
        sys.exit(1)

    if ruamel_yaml:
        with open(VERSIONS_FILE, "r") as f:
            config = ruamel_yaml.load(f)
    else:
        with open(VERSIONS_FILE, "r") as f:
            config = yaml.safe_load(f)

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
