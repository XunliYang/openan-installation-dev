#!/bin/bash
# =============================================================================
# install_orc.sh - One-click offline installer for Orchestration Center
#
# Runs on the OFFLINE machine, in the same directory as pack_orc.sh.
# Finds the tarball produced by pack_orc.sh, extracts it, creates venv,
# installs dependencies from local wheels, builds frontend from npm cache,
# deploys static assets, configures nginx HTTPS reverse proxy, and starts
# the service — all in one step.
#
# Usage:
#   ./install_orc.sh
#
# Prerequisites on the offline machine:
#   - Python 3.12+ (pre-installed)
#   - Node.js 20.19+ + npm (pre-installed, for frontend build)
#   - nginx (pre-installed, for HTTPS reverse proxy)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Parse arguments ──────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "Usage: $0"
            echo ""
            echo "Finds the offline tarball (produced by pack_orc.sh),"
            echo "extracts it, sets up venv, installs deps from local wheels,"
            echo "builds frontend, configures nginx HTTPS, and starts the service."
            echo ""
            echo "Prerequisites: Python 3.12+, Node.js 20.19+, npm, nginx"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Orchestration Center - One-Click Installer${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ─── Helper: run a command with sudo if not root ──────────────────────────────
run_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ─── Helper: kill any process listening on a given TCP port ───────────────────
free_port() {
    local port="$1"
    local pids=""
    if command -v fuser >/dev/null 2>&1; then
        pids="$(fuser "${port}/tcp" 2>/dev/null)" || true
    elif command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -t -i:"${port}" 2>/dev/null)" || true
    elif command -v ss >/dev/null 2>&1; then
        pids="$(ss -tlnp 2>/dev/null | grep ":${port}\b" | grep -oE 'pid=[0-9]+' | cut -d= -f2)" || true
    fi
    if [ -n "${pids}" ]; then
        echo -e "${YELLOW}  Port ${port} is in use, killing PID(s): ${pids}...${NC}"
        echo "${pids}" | tr ' ' '\n' | xargs -r kill 2>/dev/null || true
        sleep 1
        echo "${pids}" | tr ' ' '\n' | xargs -r kill -9 2>/dev/null || true
    fi
}

# ─── Helper: find nginx binary path ───────────────────────────────────────────
find_nginx_binary() {
    local nginx_bin
    if nginx_bin=$(command -v nginx 2>/dev/null); then
        echo "$nginx_bin"
        return 0
    fi
    for dir in /usr/sbin /sbin; do
        if [ -x "${dir}/nginx" ]; then
            echo "${dir}/nginx"
            return 0
        fi
    done
    return 1
}

# ─── Step 1: Find tarball ────────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Finding offline package...${NC}"

TARBALL=""
for f in "${SCRIPT_DIR}"/orchestration-center-offline-*.tar.gz; do
    if [ -f "$f" ]; then
        TARBALL="$f"
        break
    fi
done
# Also check dist/ subdirectory
if [ -z "$TARBALL" ]; then
    for f in "${SCRIPT_DIR}"/dist/orchestration-center-offline-*.tar.gz; do
        if [ -f "$f" ]; then
            TARBALL="$f"
            break
        fi
    done
fi

if [ -z "$TARBALL" ]; then
    echo -e "${RED}Error: No orchestration-center tarball found.${NC}"
    echo "       Searched: ${SCRIPT_DIR}/orchestration-center-offline-*.tar.gz"
    echo "       Searched: ${SCRIPT_DIR}/dist/orchestration-center-offline-*.tar.gz"
    echo "       Please run pack_orc.sh first to build the offline package."
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Found: ${TARBALL}"

PKG_NAME=$(basename "$TARBALL" .tar.gz)

# ─── Step 2: Extract ─────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Extracting package...${NC}"

EXTRACT_DIR="${SCRIPT_DIR}/${PKG_NAME}"

if [ -d "$EXTRACT_DIR" ]; then
    echo -e "${YELLOW}  Directory already exists: ${EXTRACT_DIR}${NC}"
    read -p "  Overwrite? (y/n): " choice
    case "$choice" in
        [Yy]|[Yy][Ee][Ss])
            rm -rf "$EXTRACT_DIR"
            tar -xzf "$TARBALL" -C "$SCRIPT_DIR"
            echo -e "  ${GREEN}✓${NC} Extracted (overwritten)."
            ;;
        *)
            echo -e "  ${GREEN}✓${NC} Using existing directory."
            ;;
    esac
else
    tar -xzf "$TARBALL" -C "$SCRIPT_DIR"
    echo -e "  ${GREEN}✓${NC} Extracted to: ${EXTRACT_DIR}"
fi

# Set paths relative to extracted directory
ROOT_DIR="$EXTRACT_DIR"
WHEELS_DIR="${ROOT_DIR}/vendor/wheels"
NPM_CACHE_DIR="${ROOT_DIR}/vendor/npm-cache"
FRONTEND_DIR="${ROOT_DIR}/workflow-designer"
VENV_DIR="${ROOT_DIR}/venv"
REQUIREMENTS_FILE="${ROOT_DIR}/requirements.txt"

cd "$ROOT_DIR"

# ─── Step 3: Detect architecture and verify bundle ───────────────────────────
echo -e "${YELLOW}Step 3: Detecting system architecture and verifying bundle...${NC}"

RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
    x86_64|amd64)
        NORMALIZED_ARCH="x86_64"
        ;;
    aarch64|arm64)
        NORMALIZED_ARCH="aarch64"
        ;;
    *)
        echo -e "${RED}Error: Unsupported architecture '${RAW_ARCH}'. Supported: x86_64, aarch64.${NC}"
        exit 1
        ;;
esac
echo -e "  ${GREEN}✓${NC} Detected: ${RAW_ARCH} → ${NORMALIZED_ARCH}"

# Check wheels directory
if [ ! -d "$WHEELS_DIR" ]; then
    echo -e "${RED}Error: Wheels directory not found at $WHEELS_DIR${NC}"
    echo "       The bundle may be incomplete."
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
    echo -e "${RED}Error: No wheels found for architecture '${NORMALIZED_ARCH}'.${NC}"
    echo "       This package may be incomplete. Re-run pack_orc.sh to download both architectures."
    exit 1
fi
echo -e "  ${GREEN}✓${NC} ${WHEEL_COUNT} wheel packages found (${NORMALIZED_ARCH} confirmed)"

# Check npm cache
if [ -d "$FRONTEND_DIR" ] && [ ! -d "$NPM_CACHE_DIR" ]; then
    echo -e "  ${YELLOW}⚠ npm cache not found, frontend will not be available.${NC}"
elif [ -d "$NPM_CACHE_DIR" ]; then
    echo -e "  ${GREEN}✓${NC} npm cache found"
fi

# Create runtime directories (not included in the bundle)
mkdir -p "${ROOT_DIR}/log" "${ROOT_DIR}/run"

echo -e "  ${GREEN}✓${NC} Bundle verified"

# ─── Step 4: Check Python ────────────────────────────────────────────────────
echo -e "${YELLOW}Step 4: Checking Python...${NC}"

PYTHON_CMD=""
for candidate in python3.13 python3.12 python3; do
    if command -v "$candidate" &>/dev/null; then
        CAND_VERSION=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        CAND_MAJOR=$(echo "$CAND_VERSION" | cut -d. -f1)
        CAND_MINOR=$(echo "$CAND_VERSION" | cut -d. -f2)
        if [ "$CAND_MAJOR" -eq 3 ] && [ "$CAND_MINOR" -ge 12 ]; then
            PYTHON_CMD="$candidate"
            SYSTEM_PY="$CAND_VERSION"
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    echo -e "${RED}Error: Python 3.12+ not found.${NC}"
    echo "       Searched: python3.13, python3.12, python3"
    echo "       Please install Python 3.12+ and try again."
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python ${SYSTEM_PY} ($PYTHON_CMD)"

# ─── Step 5: Check Node.js, npm, and nginx ───────────────────────────────────
echo -e "${YELLOW}Step 5: Checking Node.js, npm, and nginx...${NC}"

# Check Node.js 20.19+
if ! command -v node &>/dev/null; then
    echo -e "${RED}Error: Node.js not found. Need Node.js 20.19+.${NC}"
    echo "       Please install Node.js 20.19+ and try again."
    exit 1
fi
NODE_VERSION=$(node --version | sed 's/v//')
NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
NODE_MINOR=$(echo "$NODE_VERSION" | cut -d. -f2)
if [ "$NODE_MAJOR" -lt 20 ] || { [ "$NODE_MAJOR" -eq 20 ] && [ "$NODE_MINOR" -lt 19 ]; }; then
    echo -e "${RED}Error: Node.js 20.19+ required, found v${NODE_VERSION}.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Node.js v${NODE_VERSION}"

# Check npm
if ! command -v npm &>/dev/null; then
    echo -e "${RED}Error: npm not found. Need npm for frontend build.${NC}"
    echo "       Please install npm and try again."
    exit 1
fi
NPM_VERSION=$(npm --version)
echo -e "  ${GREEN}✓${NC} npm ${NPM_VERSION}"

# Check nginx (must be pre-installed on the offline machine)
if ! find_nginx_binary >/dev/null 2>&1; then
    echo -e "${RED}Error: nginx not found.${NC}"
    echo "       nginx is required for HTTPS reverse proxy and frontend serving."
    echo "       Please install nginx and try again."
    exit 1
fi
NGINX_BIN=$(find_nginx_binary)
echo -e "  ${GREEN}✓${NC} nginx $("$NGINX_BIN" -v 2>&1 | awk '{print $3}')"

# Check openssl (for SSL certificate generation)
if ! command -v openssl &>/dev/null; then
    echo -e "${YELLOW}  ⚠ openssl not found; SSL certificate generation may fail.${NC}"
else
    echo -e "  ${GREEN}✓${NC} openssl $(openssl version 2>/dev/null | awk '{print $2}')"
fi

echo ""

# ─── Step 6: Create venv and install dependencies ────────────────────────────
echo -e "${YELLOW}Step 6: Building Python venv from wheels...${NC}"

if [ -d "$VENV_DIR" ]; then
    echo -e "${YELLOW}  venv already exists, recreating...${NC}"
    rm -rf "$VENV_DIR"
fi

"$PYTHON_CMD" -m venv "$VENV_DIR"
echo -e "  ${GREEN}✓${NC} venv created at ${VENV_DIR}"

# Upgrade pip from local wheels
"${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --no-index --find-links "$WHEELS_DIR" 2>/dev/null || true

# Install dependencies from local wheels (no internet needed)
echo -e "  ${YELLOW}Installing dependencies from wheels (this may take a moment)...${NC}"
if ! "${VENV_DIR}/bin/pip" install --no-index --find-links "$WHEELS_DIR" \
    -r "$REQUIREMENTS_FILE" 2>&1 | sed 's/^/  /'; then
    echo -e "${RED}Error: Failed to install dependencies.${NC}"
    echo "       Some wheels may be missing for your platform."
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python dependencies installed"
echo ""

# ─── Step 7: Build frontend and deploy static assets ─────────────────────────
echo -e "${YELLOW}Step 7: Building frontend from npm cache...${NC}"

if [ -d "$FRONTEND_DIR" ] && [ -d "$NPM_CACHE_DIR" ]; then
    cd "$FRONTEND_DIR"

    echo -e "  ${YELLOW}Running npm install (offline, from cache)...${NC}"
    npm install --force --cache "$NPM_CACHE_DIR" --prefer-offline 2>&1 | sed 's/^/  /' || {
        echo -e "${RED}Error: npm install failed.${NC}"
        echo "       The npm cache may be incomplete."
        cd "$ROOT_DIR"
        exit 1
    }
    echo -e "  ${GREEN}✓${NC} Frontend dependencies installed"

    echo -e "  ${YELLOW}Building frontend static assets...${NC}"
    npm run build > "${ROOT_DIR}/log/frontend-build.log" 2>&1 || {
        echo -e "${RED}Error: Frontend build failed.${NC}"
        echo "       Check log: ${ROOT_DIR}/log/frontend-build.log"
        cd "$ROOT_DIR"
        exit 1
    }
    echo -e "  ${GREEN}✓${NC} Frontend built to dist/"

    # Deploy static assets to system web directory (see ADR-014)
    # nginx (www-data) cannot traverse user home directory, so we copy dist/
    # to /var/www/openan/ with world-readable permissions.
    echo -e "  ${YELLOW}Deploying static assets to /var/www/openan/...${NC}"
    run_sudo mkdir -p /var/www/openan
    run_sudo cp -r "${FRONTEND_DIR}/dist/"* /var/www/openan/
    run_sudo chmod -R 755 /var/www/openan
    echo -e "  ${GREEN}✓${NC} Static assets deployed to /var/www/openan/"

    cd "$ROOT_DIR"
else
    echo -e "${YELLOW}  Frontend not available (no npm cache or no frontend dir)${NC}"
fi
echo ""

# ─── Step 8: Auto-configure server.conf ──────────────────────────────────────
echo -e "${YELLOW}Step 8: Auto-configuring server.conf...${NC}"

SERVER_CONF="${ROOT_DIR}/etc/conf/server.conf"
if [ -f "$SERVER_CONF" ]; then
    # Fix agent_registry_url: convert https to http for local registry connection
    # (see memory: orchestration-center connecting to registry-center needs HTTP)
    sed -i 's|agent_registry_url=https://|agent_registry_url=http://|' "$SERVER_CONF"
    echo -e "  ${GREEN}✓${NC} agent_registry_url set to http (local registry)"

    echo -e "  ${YELLOW}Note: Default agent_registry_url is http://127.0.0.1:5000${NC}"
    echo -e "  ${YELLOW}      If registry-center is on a different host, edit:${NC}"
    echo -e "  ${YELLOW}      ${SERVER_CONF}${NC}"
else
    echo -e "${YELLOW}  ⚠ server.conf not found, skipping auto-config${NC}"
fi
echo ""

# ─── Step 9: Configure nginx (HTTPS reverse proxy) ───────────────────────────
echo -e "${YELLOW}Step 9: Configuring nginx...${NC}"

# Generate self-signed SSL certificate for HTTPS
NGINX_SSL_DIR="/etc/nginx/ssl"
if [ ! -f "${NGINX_SSL_DIR}/cert.pem" ] || [ ! -f "${NGINX_SSL_DIR}/key.pem" ]; then
    echo -e "  ${YELLOW}Generating self-signed SSL certificate...${NC}"
    run_sudo mkdir -p "${NGINX_SSL_DIR}"
    run_sudo openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${NGINX_SSL_DIR}/key.pem" \
        -out "${NGINX_SSL_DIR}/cert.pem" \
        -subj "/CN=localhost" 2>/dev/null
    if [ -f "${NGINX_SSL_DIR}/cert.pem" ] && [ -f "${NGINX_SSL_DIR}/key.pem" ]; then
        echo -e "  ${GREEN}✓${NC} SSL certificate generated at ${NGINX_SSL_DIR}"
    else
        echo -e "${RED}Error: Failed to generate SSL certificate.${NC}"
        exit 1
    fi
else
    echo -e "  ${GREEN}✓${NC} SSL certificate already exists at ${NGINX_SSL_DIR}"
fi

# Generate nginx configuration file
echo -e "  ${YELLOW}Generating nginx configuration...${NC}"
NGINX_CONF_LOCAL="${ROOT_DIR}/log/openan-nginx.conf"
cat > "$NGINX_CONF_LOCAL" << 'NGINX_EOF'
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    # Frontend (static files served from /var/www/openan, see ADR-014)
    location / {
        root /var/www/openan;
        try_files $uri $uri/ /index.html;
    }

    # Orchestration backend API (trailing slash strips /api/orchestrate prefix)
    location /api/orchestrate/ {
        proxy_pass http://127.0.0.1:5001/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Registry Center (trailing slash strips /registry prefix)
    location /registry/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX_EOF

# Deploy configuration to nginx conf.d
NGINX_CONF_DEST="/etc/nginx/conf.d/openan.conf"
run_sudo cp "$NGINX_CONF_LOCAL" "$NGINX_CONF_DEST"
echo -e "  ${GREEN}✓${NC} Configuration deployed to ${NGINX_CONF_DEST}"

# Remove default site if it conflicts (Debian/Ubuntu ships a default server on port 80)
if [ -f /etc/nginx/sites-enabled/default ]; then
    echo -e "  ${YELLOW}Removing default nginx site to avoid conflicts...${NC}"
    run_sudo rm -f /etc/nginx/sites-enabled/default
fi

# Test nginx configuration
echo -e "  ${YELLOW}Validating nginx configuration...${NC}"
if run_sudo "$NGINX_BIN" -t 2>&1; then
    echo -e "  ${GREEN}✓${NC} nginx configuration is valid."
else
    echo -e "${RED}Error: nginx configuration test failed.${NC}"
    exit 1
fi
echo ""

# ─── Step 10: Start services ─────────────────────────────────────────────────
echo -e "${YELLOW}Step 10: Starting services...${NC}"

# Free ports if occupied by previous processes
free_port 5001
free_port 443

# Start orchestration-center backend (port 5001)
echo -e "  ${YELLOW}Starting orchestration-center backend (http://127.0.0.1:5001)...${NC}"
cd "$ROOT_DIR"

# Set AGENT_REGISTRY_URL for the backend process
# Default to local registry-center; user can edit server.conf to change
export AGENT_REGISTRY_URL="http://127.0.0.1:5000"

nohup "${VENV_DIR}/bin/python" -m orchestrate.start > "${ROOT_DIR}/log/backend.log" 2>&1 &
OC_BACKEND_PID=$!
sleep 2

if kill -0 "$OC_BACKEND_PID" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Backend started (PID: ${OC_BACKEND_PID})"
else
    echo -e "${RED}  Error: Backend failed to start.${NC}"
    echo "  Check log: ${ROOT_DIR}/log/backend.log"
    exit 1
fi

# Start nginx (HTTPS reverse proxy on port 443)
echo -e "  ${YELLOW}Starting nginx (https://localhost)...${NC}"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
    echo -e "  ${YELLOW}nginx is already running, reloading configuration...${NC}"
    run_sudo "$NGINX_BIN" -s reload 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    run_sudo systemctl start nginx 2>/dev/null || run_sudo "$NGINX_BIN"
else
    run_sudo "$NGINX_BIN" 2>/dev/null || true
fi
sleep 1

NGINX_PID="$(pgrep -f 'nginx: master' 2>/dev/null | head -1)" || NGINX_PID=""
if [ -n "$NGINX_PID" ]; then
    echo -e "  ${GREEN}✓${NC} nginx started (PID: ${NGINX_PID})"
else
    echo -e "${YELLOW}  ⚠ Could not determine nginx master PID.${NC}"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
VPS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || VPS_IP=""
[ -z "${VPS_IP}" ] && VPS_IP="localhost"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Orchestration Center installed and started!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "  Frontend:        https://${VPS_IP}"
echo "  Backend API:     http://127.0.0.1:5001"
echo "  Backend PID:     ${OC_BACKEND_PID}"
if [ -n "$NGINX_PID" ]; then
    echo "  nginx PID:       ${NGINX_PID}"
fi
echo "  Directory:       ${ROOT_DIR}"
echo ""
echo "  Logs:"
echo "    Backend:       ${ROOT_DIR}/log/backend.log"
echo "    Frontend build: ${ROOT_DIR}/log/frontend-build.log"
echo ""
echo "  To stop:"
echo "    kill ${OC_BACKEND_PID}"
if [ -n "$NGINX_PID" ]; then
    echo "    nginx: sudo systemctl stop nginx  (or: sudo ${NGINX_BIN} -s stop)"
fi
echo ""
echo -e "${YELLOW}  Configuration files (edit and restart if needed):${NC}"
echo "    ${ROOT_DIR}/etc/conf/server.conf"
echo "    ${ROOT_DIR}/common/config/llm_config.json"
echo "    ${ROOT_DIR}/etc/conf/db_config.json  (if persistence_mode=postgresql)"
echo ""
echo -e "${YELLOW}  Note: agent_registry_url defaults to http://127.0.0.1:5000${NC}"
echo -e "${YELLOW}  If registry-center is remote, edit server.conf and restart.${NC}"
echo ""
echo -e "${BLUE}========================================${NC}"
