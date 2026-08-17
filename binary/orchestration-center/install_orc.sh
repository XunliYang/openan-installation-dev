#!/bin/bash
# =============================================================================
# install_offline.sh
# =============================================================================
# Run this on the AIR-GAPPED (offline) machine to install the Orchestration
# Center from the offline bundle.
#
# This script:
#   1. Detects the system architecture (x86_64 or aarch64)
#   2. Verifies the bundle is complete (wheels + npm cache for detected arch)
#   3. Installs the project to /opt/orchestration-center (or custom dir)
#   4. Builds a Python venv from the bundled wheels (no internet needed)
#   5. Builds frontend node_modules from the bundled npm cache (no internet)
#   6. Optionally installs as a systemd service
#   7. Prints next steps for configuration
#
# Usage:
#   ./install_offline.sh [--dir=/custom/path] [--service] [--no-service]
#
# Prerequisites on the offline machine:
#   - Python 3.12+ (system Python)
#   - Node.js 20.19+ (for frontend build)
#   - npm (for frontend build)
#   - Root privileges (for systemd install; non-root for manual start)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR=""
INSTALL_SERVICE=""

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir=*)
            INSTALL_DIR="${1#*=}"
            shift
            ;;
        --service)
            INSTALL_SERVICE=true
            shift
            ;;
        --no-service)
            INSTALL_SERVICE=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --dir=PATH           Install directory (default: /opt/orchestration-center)"
            echo "  --service            Install as systemd service (requires root)"
            echo "  --no-service         Do not install as systemd service (manual start)"
            echo ""
            echo "Without --service or --no-service, you will be prompted."
            echo ""
            echo "Architecture is auto-detected (x86_64 or aarch64). No flag needed."
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Offline Bundle Installer${NC}"
echo -e "${BLUE}  Orchestration Center${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ─── Step 1: Detect architecture ─────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Detecting system architecture...${NC}"

RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
    x86_64|amd64)
        NORMALIZED_ARCH="x86_64"
        ;;
    aarch64|arm64)
        NORMALIZED_ARCH="aarch64"
        ;;
    *)
        echo -e "${RED}Error: Unsupported architecture '$RAW_ARCH'. Supported: x86_64, aarch64.${NC}"
        exit 1
        ;;
esac
echo -e "  ${GREEN}✓${NC} Detected: ${RAW_ARCH} → ${NORMALIZED_ARCH}"
echo ""

# ─── Step 2: Verify bundle integrity ─────────────────────────────────────────
echo -e "${YELLOW}Step 2: Verifying bundle...${NC}"

if [ ! -f "${ROOT_DIR}/OFFLINE_BUNDLE_MANIFEST.txt" ]; then
    echo -e "${RED}Error: Not running from inside the offline bundle.${NC}"
    echo -e "       Expected to find OFFLINE_BUNDLE_MANIFEST.txt in project root."
    echo -e "       Run this script from: orchestration-center-offline/bin/install_offline.sh"
    exit 1
fi

WHEELS_DIR="${ROOT_DIR}/vendor/wheels"
NPM_CACHE_DIR="${ROOT_DIR}/vendor/npm-cache"
FRONTEND_DIR="${ROOT_DIR}/workflow-designer"

# Check wheels directory
if [ ! -d "$WHEELS_DIR" ]; then
    echo -e "${RED}Error: Wheels directory not found at $WHEELS_DIR${NC}"
    echo -e "       The bundle may be incomplete."
    exit 1
fi

WHEEL_COUNT=$(find "$WHEELS_DIR" -name "*.whl" 2>/dev/null | wc -l)
if [ "$WHEEL_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No wheel packages found in $WHEELS_DIR${NC}"
    exit 1
fi

# Verify wheels exist for the detected architecture
ARCH_WHEELS=$(find "$WHEELS_DIR" -name "*.whl" 2>/dev/null | grep -i "$NORMALIZED_ARCH" | head -1)
if [ -z "$ARCH_WHEELS" ]; then
    echo -e "${RED}Error: No wheels found for architecture '${NORMALIZED_ARCH}' in wheels/ directory.${NC}"
    echo -e "       This package may be incomplete. Re-run the packager to download both architectures."
    exit 1
fi

echo -e "  ${GREEN}✓${NC} ${WHEEL_COUNT} wheel packages found (${NORMALIZED_ARCH} wheels confirmed)"

# Check npm cache
if [ -d "$FRONTEND_DIR" ]; then
    if [ ! -d "$NPM_CACHE_DIR" ]; then
        echo -e "  ${YELLOW}⚠ npm cache not found, frontend will not be available.${NC}"
    else
        echo -e "  ${GREEN}✓${NC} npm cache found"
    fi
fi

echo -e "  ${GREEN}✓${NC} Bundle verified"
echo ""

# ─── Step 3: Check system Python ─────────────────────────────────────────────
echo -e "${YELLOW}Step 3: Checking system Python...${NC}"

# Auto-detect Python 3.12+ — try common binary names in order of preference
PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" &>/dev/null; then
        CAND_VERSION=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        CAND_MAJOR=$(echo "$CAND_VERSION" | cut -d. -f1)
        CAND_MINOR=$(echo "$CAND_VERSION" | cut -d. -f2)
        if [ "$CAND_MAJOR" -eq 3 ] && [ "$CAND_MINOR" -ge 12 ]; then
            PYTHON_BIN="$candidate"
            SYSTEM_PY="$CAND_VERSION"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo -e "${RED}Error: Python 3.12+ not found on this machine.${NC}"
    echo -e "       Searched: python3.13, python3.12, python3.11, python3"
    echo -e "       The project requires Python 3.12+."
    exit 1
fi
echo -e "  ${GREEN}✓${NC} System Python: ${SYSTEM_PY} ($PYTHON_BIN)"
echo ""

# ─── Step 4: Determine install directory ─────────────────────────────────────
if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="${ROOT_DIR}"
    echo -e "${YELLOW}Step 4: Install location${NC}"
    echo -e "  Bundle is at: ${ROOT_DIR}"
    echo -e "  You can run directly from here, or install to a system path."
    echo ""
    read -p "$(echo -e "${YELLOW}Install to /opt/orchestration-center? (y/n): ${NC}")" choice
    case "$choice" in
        [Yy]|[Yy][Ee][Ss])
            INSTALL_DIR="/opt/orchestration-center"
            ;;
        *)
            INSTALL_DIR="${ROOT_DIR}"
            echo -e "  ${GREEN}✓${NC} Running in-place from ${INSTALL_DIR}"
            ;;
    esac
else
    echo -e "${YELLOW}Step 4: Install location${NC}"
    echo -e "  Install directory: ${INSTALL_DIR}"
fi
echo ""

# ─── Step 5: Copy to install directory if different ──────────────────────────
if [ "$INSTALL_DIR" != "$ROOT_DIR" ]; then
    echo -e "${YELLOW}Step 5: Copying to ${INSTALL_DIR}...${NC}"

    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}⚠ Not running as root. Need sudo to copy to ${INSTALL_DIR}.${NC}"
        SUDO="sudo"
    else
        SUDO=""
    fi

    $SUDO mkdir -p "$INSTALL_DIR"
    $SUDO cp -r "$ROOT_DIR"/* "$INSTALL_DIR/"
    echo -e "  ${GREEN}✓${NC} Installed to ${INSTALL_DIR}"

    ROOT_DIR="$INSTALL_DIR"
    WHEELS_DIR="${INSTALL_DIR}/vendor/wheels"
    NPM_CACHE_DIR="${INSTALL_DIR}/vendor/npm-cache"
    FRONTEND_DIR="${INSTALL_DIR}/workflow-designer"
    VENV_DIR="${INSTALL_DIR}/venv"
else
    VENV_DIR="${ROOT_DIR}/venv"
    echo -e "${YELLOW}Step 5: Running in-place, no copy needed${NC}"
fi
echo ""

# ─── Step 6: Build Python venv from wheels ───────────────────────────────────
echo -e "${YELLOW}Step 6: Building Python venv from wheels...${NC}"

rm -rf "$VENV_DIR"
"$PYTHON_BIN" -m venv "$VENV_DIR"
echo -e "  ${GREEN}✓${NC} venv created at ${VENV_DIR}"

# Upgrade pip from local wheels
"${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --no-index --find-links "$WHEELS_DIR" 2>/dev/null || true

# Install dependencies from local wheels (no internet needed)
echo -e "  ${YELLOW}Installing dependencies from wheels (this may take a moment)...${NC}"
"${VENV_DIR}/bin/pip" install --no-index --find-links "$WHEELS_DIR" \
    -r "${ROOT_DIR}/requirements.txt"
echo -e "  ${GREEN}✓${NC} Python dependencies installed"
echo ""

# ─── Step 7: Build frontend from npm cache ───────────────────────────────────
if [ -d "$FRONTEND_DIR" ] && [ -d "$NPM_CACHE_DIR" ]; then
    echo -e "${YELLOW}Step 7: Building frontend from npm cache...${NC}"

    if ! command -v npm &>/dev/null; then
        echo -e "${RED}Error: npm not found on this machine.${NC}"
        echo -e "${YELLOW}Frontend will not be available. Install Node.js 20.19+ and npm.${NC}"
    else
        cd "$FRONTEND_DIR"
        npm install --force --cache "$NPM_CACHE_DIR" --prefer-offline
        echo -e "  ${GREEN}✓${NC} Frontend built from cache"
        cd "$ROOT_DIR"
    fi
else
    echo -e "${YELLOW}Step 7: Frontend not available (no npm cache or no frontend dir)${NC}"
fi
echo ""

# ─── Make scripts executable ─────────────────────────────────────────────────
chmod +x "${ROOT_DIR}/bin/"*.sh 2>/dev/null || true

# ─── Prompt for systemd service install ──────────────────────────────────────
if [ -z "$INSTALL_SERVICE" ]; then
    echo -e "${YELLOW}Step 8: systemd service${NC}"
    read -p "$(echo -e "${YELLOW}Install as systemd service? (y/n): ${NC}")" choice
    case "$choice" in
        [Yy]|[Yy][Ee][Ss]) INSTALL_SERVICE=true ;;
        *) INSTALL_SERVICE=false ;;
    esac
fi

if [ "$INSTALL_SERVICE" = true ]; then
    echo -e "${YELLOW}Installing systemd service...${NC}"

    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}⚠ Need root for systemd. Using sudo...${NC}"
        SUDO="sudo"
    else
        SUDO=""
    fi

    # Use the bundled install_service.sh, passing --no-deps since venv is pre-built
    $SUDO "${ROOT_DIR}/bin/install_service.sh" install --dir="$INSTALL_DIR" --no-deps
    echo ""
else
    echo -e "${YELLOW}Step 8: Skipping systemd service${NC}"
    echo -e "  You can start manually with: ${ROOT_DIR}/bin/start.sh"
    echo ""
fi

# ─── Print configuration guide ───────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Before starting, configure these files:${NC}"
echo ""
echo -e "  ${GREEN}1. Backend config:${NC} ${ROOT_DIR}/etc/conf/server.conf"
echo -e "     - ip, port, enable_https, ssl_certfile, ssl_keyfile"
echo -e "     - access_password, persistence_mode, agent_registry_url"
echo ""
echo -e "  ${GREEN}2. LLM config:${NC}    ${ROOT_DIR}/common/config/llm_config.json"
echo -e "     - chat.api_key, chat.url, chat.model"
echo -e "     - embed/rerank settings (if used)"
echo ""
echo -e "  ${GREEN}3. Database config:${NC} ${ROOT_DIR}/etc/conf/db_config.json"
echo -e "     - host, port, user, password (only if persistence_mode=postgresql)"
echo ""
echo -e "  ${GREEN}4. TLS properties:${NC} ${ROOT_DIR}/etc/conf/server.properties"
echo -e "     - tls.version, tls.cipher, connection limits"
echo ""
echo -e "  ${GREEN}5. SSL certs:${NC}     ${ROOT_DIR}/etc/ssl/"
echo -e "     - server.cer, server_key.pem, trust.cer, cert_pwd"
echo -e "     - Generate self-signed: python generate_selfsign_cert.py etc/ssl serverAuth"
echo ""
echo -e "  See: bin/OFFLINE_CONFIG_GUIDE.md for detailed instructions"
echo ""
echo -e "${YELLOW}To start:${NC}"
if [ "$INSTALL_SERVICE" = true ]; then
    echo -e "  sudo systemctl start orchestration-center"
    echo -e "  sudo systemctl status orchestration-center"
else
    echo -e "  ${ROOT_DIR}/bin/start.sh"
    echo -e "  (frontend: cd ${ROOT_DIR}/workflow-designer && npm run dev)"
fi
echo ""
