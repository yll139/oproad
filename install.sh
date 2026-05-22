#!/usr/bin/env bash
# oproad install script
# Usage: ./install.sh
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
REPO_ROOT="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

STEP=0
next_step() {
    STEP=$((STEP + 1))
    echo ""
    echo "========================================================================"
    echo "  Step $STEP: $1"
    echo "========================================================================="
    echo ""
}

ok()   { echo "  [OK] $1"; }
info() { echo "  [..] $1"; }
warn() { echo "  [WARN] $1" >&2; }
fail() { echo "  [FAIL] $1" >&2; echo "Aborted." >&2; exit 1; }

# -------------------------------------------------------
exec_cmd() {
    local desc="$1"
    shift
    info "$desc"
    if "$@"; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

# =========================================================
# Step 1: Welcome
# =========================================================
clear 2>/dev/null || true
echo ""
echo "============================================"
echo "  oproad - Install Script"
echo "============================================"
echo ""
echo "This script will:"
echo "  1. Check prerequisites"
echo "  2. Build the Docker image"
echo "  3. Detect VS Code and configure tasks"
echo ""

# =========================================================
# Step 2: Check prerequisites
# =========================================================
next_step "Check prerequisites"

# Check OS
os_name="$(uname -s)"
info "Detected OS: $os_name"

# Check Git
if command -v git &>/dev/null; then
    ok "Git found: $(git --version 2>/dev/null | head -1)"
else
    warn "Git not found. Install Git: https://git-scm.com/downloads"
fi

# Check Docker
if command -v docker &>/dev/null; then
    ok "Docker found: $(docker --version 2>/dev/null | head -1)"
else
    fail "Docker not found. Please install Docker Desktop: https://www.docker.com/products/docker-desktop/"
fi

# Check Docker is running
if docker info &>/dev/null; then
    ok "Docker daemon is running"
else
    fail "Docker daemon is not running. Please start Docker Desktop."
fi

# Check Docker login
if docker info 2>/dev/null | grep -q '^Username:'; then
    ok "Docker is logged in"
else
    warn "Docker not logged in. Attempting docker login..."
    if docker login; then
        ok "Docker login successful"
    else
        warn "Docker login skipped or failed. Some images may not be pullable."
    fi
fi


# =========================================================
# Step 3: Build Docker image
# =========================================================
next_step "Build Docker image"

# Check if oproad:latest image already exists
if docker image inspect oproad:latest &>/dev/null; then
    ok "oproad:latest Docker image already exists. Skipping build."
else
    info "Running: ./oproad build-image"
    echo ""
    "$REPO_ROOT/oproad" build-image
    echo ""
    ok "Docker image build completed"
fi

# Verify the image exists and show version info
if docker image inspect oproad:latest &>/dev/null; then
    ok "Image oproad:latest is available"
    # Extract ORFS version and architecture from the config
    image_arch="$(docker inspect oproad:latest --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || echo "unknown")"
    echo ""
    echo "  Image info:"
    echo "    Tag  : oproad:latest"
    echo "    CPU  : $image_arch"
    echo ""
    # Try to read ORFS_BASE_IMAGE from .oproad-config
    if [ -f "$REPO_ROOT/.oproad-config" ]; then
        source "$REPO_ROOT/.oproad-config"
        orfs_version="${OPROAD_ORFS_BASE_IMAGE#openroad/orfs:}"
        [ -z "$orfs_version" ] && orfs_version="$OPROAD_ORFS_BASE_IMAGE"
        echo "    ORFS : ${orfs_version:-unknown}"
        echo "    Platform : ${OPROAD_RESOLVED_DOCKER_PLATFORM:-auto}"
    fi
    echo ""
else
    warn "Image oproad:latest not found. Build may have failed."
fi

# =========================================================
# Step 4: Create projects directory
# =========================================================
next_step "Create projects directory"

mkdir -p "$REPO_ROOT/projects"
ok "Projects directory: $REPO_ROOT/projects"

# =========================================================
# Step 5: Detect VS Code
# =========================================================
next_step "Detect VS Code"

has_code=0
if command -v code &>/dev/null; then
    ok "VS Code CLI found (code command)"
    has_code=1
elif [ -d "/Applications/Visual Studio Code.app" ]; then
    ok "VS Code found in /Applications"
    has_code=1
elif [ -d "$HOME/Applications/Visual Studio Code.app" ]; then
    ok "VS Code found in $HOME/Applications"
    has_code=1
else
    warn "VS Code not detected. Skipping VS Code configuration."
    has_code=0
fi

if [ "$has_code" -eq 1 ]; then
    info "Configuring VS Code workspace..."

    # Ensure .vscode/tasks.json exists (created by the repo)
    if [ -f "$REPO_ROOT/.vscode/tasks.json" ]; then
        ok "tasks.json already exists"
    else
        info "tasks.json not found; ensure repo is fully cloned."
    fi

    # Create VS Code workspace file for easy opening
    cat > "$REPO_ROOT/oproad.code-workspace" <<EOF
{
    "folders": [
        { "path": "." }
    ],
    "settings": {
        "oproad.projectDir": "\${workspaceFolder}/projects/test"
    }
}
EOF
    ok "Workspace file created: oproad.code-workspace"

    echo ""
    echo "  To open in VS Code:"
    echo "    code $REPO_ROOT/oproad.code-workspace"
    echo ""
    echo "  Then use: Terminal -> Run Task... -> oproad: menu"
    echo "  for the interactive button menu."
    echo ""
fi

# =========================================================
# Step 6: Summary
# =========================================================
echo ""
echo "============================================"
echo "  Installation Complete!"
echo "============================================"
echo ""
echo "  Quick start:"
echo ""
echo "    cd $REPO_ROOT"
echo "    ./oproad new nangate45 mydesign 1.0"
echo "    ./oproad menu"
echo ""
echo "  Or in VS Code:"
echo "    code $REPO_ROOT/oproad.code-workspace"
echo "    Terminal -> Run Task... -> oproad: menu"
echo ""
echo "  Supported platforms:"
echo "    asap7, gf180, ihp-sg13g2, nangate15, nangate45"
echo "    sky130hd, sky130hs, sky130io, sky130ram"
echo ""
echo "============================================"
