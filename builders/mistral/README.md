Project: Mistral Vibe Offline Installer for x64 Linux
  Goal
  Create a zero-internet installation bundle for mistral-vibe (and all its Python dependencies) that can be transferred to an offline x64 Linux machine and installed with a single script. Th
  e bundle must not interfere with existing uv tool installations (e.g., kimi-cli).
  ──────────────────────────────
  Architecture
  The project consists of two scripts and a generated bundle:
   File                          Purpose
  ──────────────────────────────
   build.sh                      Runs on an internet-connected machine. Downloads uv, fetches mistral-vibe and all dependency wheels, and packages everything into a tarball.
   install.sh                    Runs on the offline target machine. Installs uv (if missing) and uses it to install mistral-vibe from the bundled wheels.
   mistral-vibe-offline.tar.gz   The deliverable. Contains uv, install.sh, the main wheel, and a wheels/ directory with all dependencies.
  ──────────────────────────────
  Bundle Structure (after extraction)
  mistral-vibe-offline/
  ├── uv                          # uv binary (~58 MB)
  ├── install.sh                  # offline installer
  ├── wheels/                     # all Python wheels (~100+ packages)
  │   ├── mistral_vibe-2.7.6-py3-none-any.whl
  │   ├── mistralai-2.3.2-py3-none-any.whl
  │   └── ... (dependencies)
  ──────────────────────────────
  Build Process (build.sh)
  1. Create output directory.
  2. Download uv.
    • Fetches the latest release from GitHub: uv-x86_64-unknown-linux-gnu.tar.gz.
    • Extracts the uv binary with --strip-components=1 (the tarball nests files under uv-x86_64-unknown-linux-gnu/).
    • Rationale: GitHub distributes uv as a compressed archive, not a bare binary. Using the latest release URL avoids hard-coding a version.
  3. Download mistral-vibe and all dependencies.
    • Uses pip download mistral-vibe --only-binary :all: --ignore-requires-python -d wheels/.
    • Rationale: The build machine may run Python 3.11, but mistral-vibe requires >=3.12. --ignore-requires-python ensures wheels are fetched for the target environment regardless of the bui
      ’s Python version. --only-binary :all: guarantees everything is pre-compiled (no source builds needed offline).
  4. Copy installer.
  5. Create tarball for transfer.
  ──────────────────────────────
  Install Process (install.sh)
  1. Platform check: Exits if not x86_64 + Linux.
  2. Install uv (if missing).
    • Copies the bundled uv binary to $HOME/.local/bin/uv.
    • If uv is already present, it skips this step.
  3. Install mistral-vibe.
    • Discovers the real wheel filename inside wheels/ (e.g., mistral_vibe-2.7.6-py3-none-any.whl).
    • Runs: uv tool install --offline --find-links wheels/ <wheel>
    • Rationale: uv tool install is stricter than pip and requires a valid PEP 440 wheel filename. The install script therefore references the original wheel in wheels/ rather than a generic
      renamed copy.
  4. Verify.
    • Checks that vibe is available in PATH or in the uv tool bin directory, and advises the user if PATH needs updating.
  ──────────────────────────────
  Key Design Decisions & Rationale
   Decision                                      Rationale
  ──────────────────────────────
   Use pip download instead of uv pip download   pip is more universally available on build machines. The script only requires uv on the target machine.
   --ignore-requires-python                      The builder’s Python version must not restrict what can be packaged for the target.
   --only-binary :all:                           Offline machines cannot compile C extensions. Wheels only.
   uv tool install on the target                 Integrates vibe into the user’s uv tool ecosystem alongside other tools (like kimi-cli) without using system Python or virtualenvs directly.
   --offline --find-links                        Ensures zero network access during install. uv resolves dependencies exclusively from the bundled wheels/ directory.
   Do not rename the main wheel                  uv rejects filenames like mistral-vibe.whl because they lack the required Python-tag portion. The install script dynamically discovers the c
                                                 orrect filename.
  ──────────────────────────────
  Verification Steps Performed
  1. bash build.sh succeeds and produces mistral-vibe-offline.tar.gz (~47 MB).
  2. Extracting and running bash install.sh on the same machine reinstalls mistral-vibe from the offline wheel.
  3. Existing uv tools (e.g., kimi-cli) remain untouched.
  ──────────────────────────────
  Current State
  • build.sh and install.sh are both working.
  • The bundle mistral-vibe-offline.tar.gz is ready for transfer.
  • No further changes are required unless the target platform changes (e.g., ARM64, macOS, Windows) or the installer needs to handle uv/vibe already being installed differently.
