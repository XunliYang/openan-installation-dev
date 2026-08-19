#!/bin/bash
# =============================================================================
# pack_orc.sh
# =============================================================================
# Run this on the ONLINE machine to build a self-contained offline deployment
# package for the Orchestration Center.
#
# The resulting tarball contains:
#   - Full project source code (downloaded from GitHub release)
#   - Pre-downloaded Python wheels (x86_64 + aarch64, for offline venv build)
#   - npm cache (for offline frontend build on the target machine)
#   - Config templates (user edits these on the air-gapped machine)
#
# Usage:
#   ./pack_orc.sh
#
# Prerequisites on the online machine:
#   - Python 3.12+
#   - Node.js 20.19+
#   - npm
#   - curl, tar (for source download and extraction)
#   - Internet access (for source download, pip download and npm install)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source code download (see ADR-016)
SOURCE_URL="https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz"
SOURCE_VERSION="v1.0.0"

# Defaults
VERSION="1.0.0"
OUTPUT_DIR="${SCRIPT_DIR}/dist"
PKG_NAME="orchestration-center-${VERSION}-linux"
BUILD_DIR="${OUTPUT_DIR}/build/${PKG_NAME}"

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0"
            echo ""
            echo "Downloads wheels for both x86_64 and aarch64 architectures."
            echo "No options needed — the packager always includes both architectures."
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Offline Bundle Packager${NC}"
echo -e "${BLUE}  Orchestration Center${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ─── Check prerequisites ─────────────────────────────────────────────────────
echo -e "${YELLOW}Step 0: Checking prerequisites...${NC}"

# Auto-detect Python 3.12+ — try common binary names in order of preference
PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" &>/dev/null; then
        CAND_VERSION=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        CAND_MAJOR=$(echo "$CAND_VERSION" | cut -d. -f1)
        CAND_MINOR=$(echo "$CAND_VERSION" | cut -d. -f2)
        if [ "$CAND_MAJOR" -eq 3 ] && [ "$CAND_MINOR" -ge 12 ]; then
            PYTHON_BIN="$candidate"
            PY_VERSION="$CAND_VERSION"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo -e "${RED}Error: Python 3.12+ not found.${NC}"
    echo -e "       Searched: python3.13, python3.12, python3.11, python3"
    echo -e "       The project requires Python 3.12+."
    echo -e "       Install it with:"
    echo -e "         Ubuntu/Debian: sudo apt install python3.12"
    echo -e "         Or use pyenv:  pyenv install 3.12 && pyenv local 3.12"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python ${PY_VERSION} ($PYTHON_BIN)"

if ! command -v node &>/dev/null; then
    echo -e "${RED}Error: node not found. Need Node.js 20.19+.${NC}"
    exit 1
fi
NODE_VERSION=$(node --version | sed 's/v//')
echo -e "  ${GREEN}✓${NC} Node.js ${NODE_VERSION}"

if ! command -v npm &>/dev/null; then
    echo -e "${RED}Error: npm not found.${NC}"
    exit 1
fi
NPM_VERSION=$(npm --version)
echo -e "  ${GREEN}✓${NC} npm ${NPM_VERSION}"

# Check curl and tar (required for source download)
if ! command -v curl &>/dev/null; then
    echo -e "${RED}Error: curl not found. Required to download source code.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} curl (for source download)"
if ! command -v tar &>/dev/null; then
    echo -e "${RED}Error: tar not found. Required to extract source code.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} tar (for source extraction)"

echo ""

# ─── Clean previous build ────────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Cleaning previous build...${NC}"
rm -rf "${OUTPUT_DIR}/build"
mkdir -p "$BUILD_DIR"
echo -e "  ${GREEN}✓${NC} Build directory ready: $BUILD_DIR"
echo ""

# ─── Download project source ───────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Downloading project source ${SOURCE_VERSION}...${NC}"

TMP_TAR=$(mktemp /tmp/orchestration-center-source-XXXXXX.tar.gz)
if ! curl -fsSL "${SOURCE_URL}" -o "${TMP_TAR}"; then
    echo -e "${RED}Error: Failed to download orchestration-center source ${SOURCE_VERSION}.${NC}"
    rm -f "${TMP_TAR}"
    exit 1
fi

# Extract to a temp source dir, then rsync to build dir with excludes
TMP_SOURCE=$(mktemp -d /tmp/orchestration-center-src-XXXXXX)
tar -xzf "${TMP_TAR}" -C "${TMP_SOURCE}" --strip-components=1
rm -f "${TMP_TAR}"

if command -v rsync &>/dev/null; then
    rsync -a \
        --exclude='.git' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.venv' \
        --exclude='venv' \
        --exclude='node_modules' \
        --exclude='.pytest_cache' \
        --exclude='.ruff_cache' \
        --exclude='.mypy_cache' \
        --exclude='/log/' \
        --exclude='/run/' \
        --exclude='*.log' \
        "$TMP_SOURCE/" "$BUILD_DIR/"
else
    # Fallback: cp + manual cleanup
    cp -r "$TMP_SOURCE"/* "$BUILD_DIR/"
    cp -r "$TMP_SOURCE"/.??* "$BUILD_DIR/" 2>/dev/null || true
    rm -rf "$BUILD_DIR/.git"
    find "$BUILD_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    find "$BUILD_DIR" -name '*.pyc' -delete 2>/dev/null || true
    rm -rf "$BUILD_DIR/.venv" "$BUILD_DIR/venv" "$BUILD_DIR/workflow-designer/node_modules"
    rm -rf "$BUILD_DIR/.pytest_cache" "$BUILD_DIR/.ruff_cache" "$BUILD_DIR/.mypy_cache"
fi
rm -rf "$TMP_SOURCE"
echo -e "  ${GREEN}✓${NC} Source downloaded and copied"
echo ""

# ─── Download Python wheels for both architectures ──────────────────────────
echo -e "${YELLOW}Step 3: Downloading Python wheels (x86_64 + aarch64)...${NC}"

# Create a temporary packaging venv (only used for pip download, not bundled)
VENV_PACKAGING_DIR=$(mktemp -d /tmp/pack-orc-venv-XXXXXX)
trap 'rm -rf "$VENV_PACKAGING_DIR"' EXIT
"$PYTHON_BIN" -m venv "$VENV_PACKAGING_DIR"
echo -e "  ${GREEN}✓${NC} Packaging venv created: ${VENV_PACKAGING_DIR}"

WHEELS_DIR="${BUILD_DIR}/vendor/wheels"
mkdir -p "$WHEELS_DIR"

PYTHON_VERSION="3.12"

# Platform tags for each architecture (newer packages like cryptography require manylinux_2_28+)
PIP_PLATFORMS_X86_64=("manylinux_2_34_x86_64" "manylinux_2_28_x86_64" "manylinux_2_17_x86_64" "manylinux2014_x86_64")
PIP_PLATFORMS_AARCH64=("manylinux_2_34_aarch64" "manylinux_2_28_aarch64" "manylinux_2_17_aarch64" "manylinux2014_aarch64")

# Helper function to download wheels for a specific architecture
download_wheels_for_arch() {
    local arch_name="$1"
    shift
    local platforms=("$@")
    local flags=()
    for p in "${platforms[@]}"; do
        flags+=("--platform" "$p")
    done

    echo -e "  ${YELLOW}Downloading binary wheels for ${arch_name}...${NC}"
    "${VENV_PACKAGING_DIR}/bin/pip" install --upgrade pip wheel >/dev/null 2>&1
    # NOTE: no '|| true' here — a failed download must abort the pack run so
    # the error surfaces at pack time, not at install time (see ADR-018).
    # With 'set -o pipefail' the pipeline propagates pip's exit code.
    "${VENV_PACKAGING_DIR}/bin/pip" download \
        -r "${BUILD_DIR}/requirements.txt" \
        "${flags[@]}" \
        --python-version "$PYTHON_VERSION" \
        --only-binary=:all: \
        --dest "$WHEELS_DIR" \
        2>&1 | sed 's/^/  /'
}

# Download binary wheels for both architectures.
# pure-Python wheels (tag 'any') are picked up here as well: a py3-none-any
# wheel matches any --platform, so a separate --platform any pass is both
# redundant and guaranteed to fail on C-extension deps (see ADR-018).
download_wheels_for_arch "x86_64" "${PIP_PLATFORMS_X86_64[@]}"
download_wheels_for_arch "aarch64" "${PIP_PLATFORMS_AARCH64[@]}"

# Verify wheels were downloaded
WHEEL_COUNT=$(find "$WHEELS_DIR" -name "*.whl" | wc -l)
X86_COUNT=$(find "$WHEELS_DIR" -name "*.whl" | grep -i "x86_64" | wc -l)
AARCH64_COUNT=$(find "$WHEELS_DIR" -name "*.whl" | grep -i "aarch64" | wc -l)
if [ "$WHEEL_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No wheel packages downloaded. Check network and requirements.txt.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Wheels downloaded: ${WHEEL_COUNT} total (x86_64: ${X86_COUNT}, aarch64: ${AARCH64_COUNT})"
echo ""

# ─── Prepare npm cache for offline frontend build ───────────────────────────
echo -e "${YELLOW}Step 4: Preparing npm cache for offline frontend build...${NC}"

FRONTEND_DIR="${BUILD_DIR}/workflow-designer"
cd "$FRONTEND_DIR"

echo -e "  ${YELLOW}Running npm install to fill cache (this may take a while)...${NC}"
echo -e "  ${YELLOW}(node_modules will NOT be bundled — built on the target machine)${NC}"
npm install --force
echo -e "  ${GREEN}✓${NC} npm install completed (cache populated)"

# Copy npm cache for offline use
NPM_CACHE_DIR="${BUILD_DIR}/vendor/npm-cache"
mkdir -p "$NPM_CACHE_DIR"
npm cache verify 2>/dev/null || true
NPM_GLOBAL_CACHE=$(npm config get cache 2>/dev/null || echo "")
if [ -n "$NPM_GLOBAL_CACHE" ] && [ -d "$NPM_GLOBAL_CACHE" ]; then
    cp -r "$NPM_GLOBAL_CACHE"/* "$NPM_CACHE_DIR/" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} npm cache copied to vendor/npm-cache/"
else
    echo -e "  ${YELLOW}⚠ npm cache not found, frontend offline build may fail${NC}"
fi

# Clean up node_modules — not bundled (target machine will rebuild from cache)
rm -rf "$FRONTEND_DIR/node_modules"

cd "$SCRIPT_DIR"
echo ""

# ─── Ensure bin scripts are executable ───────────────────────────────────────
echo -e "${YELLOW}Step 5: Ensuring scripts are executable...${NC}"
chmod +x "${BUILD_DIR}/bin/"*.sh 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Scripts are executable"
echo ""

# ─── Create bundle manifest ──────────────────────────────────────────────────
echo -e "${YELLOW}Step 6: Creating manifest...${NC}"
MANIFEST="${BUILD_DIR}/OFFLINE_BUNDLE_MANIFEST.txt"

cat > "$MANIFEST" << EOF
============================================================
  Orchestration Center - Offline Deployment Bundle
============================================================

Bundle created:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Created on host:   $(hostname)
Python version:    $("$PYTHON_BIN" --version)
Node.js version:   $(node --version)
npm version:       $(npm --version)
Target archs:      x86_64, aarch64

Contents:
  - Project source code (Python + React)
  - vendor/wheels/       — Pre-downloaded Python wheels (x86_64 + aarch64)
  - vendor/npm-cache/    — npm cache for offline frontend build
  - etc/conf/            — Configuration files (EDIT THESE on target machine)
  - common/config/       — LLM configuration (EDIT THESE on target machine)

Note: venv and node_modules are NOT pre-built. They will be created on the
target machine from the bundled wheels and npm cache. This ensures architecture
compatibility (the target machine may have a different CPU architecture).

To install on the air-gapped machine:
  Copy this tarball and install_orc.sh into the SAME directory, then run
  ./install_orc.sh — it handles everything: extraction, venv creation,
  dependency installation, frontend build, nginx configuration, and
  service start.

  ./install_orc.sh

EOF

echo -e "  ${GREEN}✓${NC} Manifest created"
echo ""

# ─── Create the tarball ──────────────────────────────────────────────────────
echo -e "${YELLOW}Step 7: Creating tarball...${NC}"

mkdir -p "$OUTPUT_DIR"
tar -czf "${OUTPUT_DIR}/${PKG_NAME}.tar.gz" -C "${OUTPUT_DIR}/build" "$PKG_NAME"

# Cleanup build directory
rm -rf "${OUTPUT_DIR}/build"

TARBALL="${OUTPUT_DIR}/${PKG_NAME}.tar.gz"
TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
echo -e "  ${GREEN}✓${NC} Tarball created: $TARBALL ($TARBALL_SIZE)"
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Package built successfully!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Output:  $TARBALL"
echo "Size:    $TARBALL_SIZE"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Copy dist/${PKG_NAME}.tar.gz and install_orc.sh to the air-gapped machine (USB, SCP, etc.)"
echo "  2. Install:  ./install_orc.sh"
echo ""
