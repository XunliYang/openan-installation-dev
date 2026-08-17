#!/bin/bash

# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

# ============================================================================
# install_reg.sh - One-click offline installer for Registry Center
#
# Runs on the OFFLINE machine, in the same directory as pack_reg.sh.
# Finds the tarball produced by pack_reg.sh, extracts it, creates venv,
# installs dependencies from local wheels, generates self-signed certificates,
# auto-configures via init, and starts the service — all in one step.
#
# Usage:
#   ./install_reg.sh
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Password for self-signed certificate generation
CERT_PASSWORD="Dev@12345"

# ─── Parse arguments ──────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "Usage: $0"
            echo ""
            echo "Finds the offline tarball (produced by pack_reg.sh),"
            echo "extracts it, sets up venv, installs deps from local wheels,"
            echo "generates certificates, auto-configures, and starts the service."
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Registry Center - One-Click Installer${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

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

# ─── Step 1: Find tarball ────────────────────────────────────────────────────
echo -e "${GREEN}[1/8] Finding offline package...${NC}"

TARBALL=""
# Check dist/ subdirectory first (pack_reg.sh default output location)
for f in "${SCRIPT_DIR}"/dist/registry-center-*.tar.gz; do
    if [ -f "$f" ]; then
        TARBALL="$f"
        break
    fi
done
# Then check script directory itself
if [ -z "$TARBALL" ]; then
    for f in "${SCRIPT_DIR}"/registry-center-*.tar.gz; do
        if [ -f "$f" ]; then
            TARBALL="$f"
            break
        fi
    done
fi

if [ -z "$TARBALL" ]; then
    echo -e "${RED}Error: No registry-center tarball found.${NC}"
    echo "       Searched: ${SCRIPT_DIR}/dist/registry-center-*.tar.gz"
    echo "       Searched: ${SCRIPT_DIR}/registry-center-*.tar.gz"
    echo "       Please run pack_reg.sh first to build the offline package."
    exit 1
fi
echo "  Found: ${TARBALL}"

PKG_NAME=$(basename "$TARBALL" .tar.gz)

# ─── Step 2: Extract ─────────────────────────────────────────────────────────
echo -e "${GREEN}[2/8] Extracting package...${NC}"

EXTRACT_DIR="${SCRIPT_DIR}/${PKG_NAME}"

if [ -d "$EXTRACT_DIR" ]; then
    echo -e "${YELLOW}  Directory already exists: ${EXTRACT_DIR}${NC}"
    read -p "  Overwrite? (y/n): " choice
    case "$choice" in
        [Yy]|[Yy][Ee][Ss])
            rm -rf "$EXTRACT_DIR"
            tar -xzf "$TARBALL" -C "$SCRIPT_DIR"
            echo "  Extracted (overwritten)."
            ;;
        *)
            echo "  Using existing directory."
            ;;
    esac
else
    tar -xzf "$TARBALL" -C "$SCRIPT_DIR"
    echo "  Extracted to: ${EXTRACT_DIR}"
fi

# Set paths relative to extracted directory
ROOT_DIR="$EXTRACT_DIR"
WHEELS_DIR="${ROOT_DIR}/wheels"
VENV_DIR="${ROOT_DIR}/venv"
REQUIREMENTS_FILE="${ROOT_DIR}/requirements.txt"

cd "$ROOT_DIR"

# ─── Step 3: Detect architecture ─────────────────────────────────────────────
echo -e "${GREEN}[3/8] Detecting system architecture...${NC}"

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
echo "  Detected: ${RAW_ARCH} → ${NORMALIZED_ARCH}"

# Verify wheels exist for this architecture
ARCH_WHEELS=$(find "$WHEELS_DIR" -name "*.whl" 2>/dev/null | grep -i "$NORMALIZED_ARCH" | head -1)
if [ -z "$ARCH_WHEELS" ]; then
    echo -e "${RED}Error: No wheels found for architecture '${NORMALIZED_ARCH}' in wheels/ directory.${NC}"
    echo "       This package may be incomplete. Re-run pack_reg.sh to download both architectures."
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Architecture-specific wheels found"

WHEEL_COUNT=$(find "$WHEELS_DIR" -name "*.whl" 2>/dev/null | wc -l)
echo "  Total wheels: ${WHEEL_COUNT}"

# ─── Step 4: Check Python ────────────────────────────────────────────────────
echo -e "${GREEN}[4/8] Checking Python...${NC}"

PYTHON_CMD=""
for candidate in python3.13 python3.12 python3; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON_MAJOR=$("$candidate" -c "import sys; print(sys.version_info.major)" 2>/dev/null)
        PYTHON_MINOR=$("$candidate" -c "import sys; print(sys.version_info.minor)" 2>/dev/null)
        if [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -ge 12 ]; then
            PYTHON_CMD="$candidate"
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

PYTHON_VER=$($PYTHON_CMD --version 2>&1)
echo "  Found: ${PYTHON_VER} ($PYTHON_CMD)"

# ─── Step 5: Create venv and install dependencies ────────────────────────────
echo -e "${GREEN}[5/8] Creating virtual environment and installing dependencies...${NC}"

if [ -d "$VENV_DIR" ]; then
    echo -e "${YELLOW}  venv already exists, recreating...${NC}"
    rm -rf "$VENV_DIR"
fi

$PYTHON_CMD -m venv "$VENV_DIR"

if [ ! -f "${VENV_DIR}/bin/python3" ]; then
    echo -e "${RED}Error: Failed to create virtual environment.${NC}"
    exit 1
fi

echo "  Virtual environment created: ${VENV_DIR}"

# Upgrade pip from local wheels
"${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --no-index --find-links="$WHEELS_DIR" 2>/dev/null || true

# Install dependencies from local wheels (no internet needed)
if ! "${VENV_DIR}/bin/pip" install \
    --no-index \
    --find-links="$WHEELS_DIR" \
    -r "$REQUIREMENTS_FILE" \
    2>&1 | sed 's/^/  /'; then
    echo -e "${RED}Error: Failed to install dependencies.${NC}"
    echo "       Some wheels may be missing for your platform."
    exit 1
fi

echo -e "${GREEN}  Dependencies installed successfully.${NC}"

# ─── Step 6: Generate self-signed certificates ───────────────────────────────
echo -e "${GREEN}[6/8] Generating self-signed certificates...${NC}"

CERT_DIR="${ROOT_DIR}/etc/cert"
SSL_DIR="${ROOT_DIR}/etc/ssl"
mkdir -p "$CERT_DIR" "$SSL_DIR"

"${VENV_DIR}/bin/python" -c "
import sys
sys.path.insert(0, '.')
from common.cert.certificate_generator import CertificateGenerator

generator = CertificateGenerator(key_algorithm='RSA')
if generator.generate_self_signed_cert('${CERT_DIR}', 'serverAuth', '${CERT_PASSWORD}'):
    print('  Certificate generated.')
else:
    print('  Certificate already exists.')
" || {
    echo -e "${YELLOW}  Warning: Certificate generation failed, continuing anyway.${NC}"
}

# Prepare SSL directory with certificate copies expected by server.conf.
# generate_self_signed_cert creates server_RSA.cer and server_key_RSA.pem in etc/cert/,
# but server.conf defaults reference etc/ssl/server.cer and etc/ssl/server_key.pem.
# init validates these paths (file exists, correct extension, 0o600 permissions).
cp -f "${CERT_DIR}/server_RSA.cer" "${SSL_DIR}/server.cer" 2>/dev/null || true
cp -f "${CERT_DIR}/server_RSA.cer" "${SSL_DIR}/trust.cer" 2>/dev/null || true
cp -f "${CERT_DIR}/server_key_RSA.pem" "${SSL_DIR}/server_key.pem" 2>/dev/null || true
chmod 600 "${SSL_DIR}"/*.pem "${SSL_DIR}"/*.cer 2>/dev/null || true

# Update jwk_private_key_path in server.conf to point to a valid .pem file.
# Default template has jwk_private_key_path=etc/sign_cert (wrong extension, file missing).
SERVER_CONF="${ROOT_DIR}/etc/conf/server.conf"
if [ -f "$SERVER_CONF" ]; then
    sed -i 's|^jwk_private_key_path=.*|jwk_private_key_path=etc/ssl/server_key.pem|' "$SERVER_CONF"
fi

# Clean stale agent card data from a previous run.
# data/agentcard.json persists across runs and causes 404 when agents
# are not running (see ADR-009).
if [ -d "${ROOT_DIR}/data" ]; then
    rm -rf "${ROOT_DIR}/data"
    echo "  Cleaned stale data/ directory."
fi

echo -e "${GREEN}  Certificates and SSL prepared.${NC}"

# ─── Step 7: Auto-configure via init ─────────────────────────────────────────
echo -e "${GREEN}[7/8] Auto-configuring (init)...${NC}"

# Run init with automated input:
#   - IP: default (empty -> 127.0.0.1)
#   - Port: default (empty -> 5000)
#   - Enable HTTPS: n
#   - Enable registry signing: n
#   - Enable signature validation: n
#   - JWK cert path: default (empty -> etc/ssl/server.cer)
#   - JWK private key path: default (empty -> etc/ssl/server_key.pem)
#   - Enable agent approval: n
#   - Storage mode: default (empty -> file)
printf '\n\nn\nn\nn\n\n\nn\n\n' | "${VENV_DIR}/bin/python" -m agent_registry.init

echo -e "${GREEN}  Configuration complete.${NC}"

# ─── Step 8: Start service ───────────────────────────────────────────────────
echo -e "${GREEN}[8/8] Starting service...${NC}"

# Free port 5000 if occupied by a previous process
free_port 5000

# Ensure log directory exists
mkdir -p "${ROOT_DIR}/log"

# Start service in background
nohup "${VENV_DIR}/bin/python" -m agent_registry.start > "${ROOT_DIR}/log/registry-center.log" 2>&1 &
SERVICE_PID=$!
sleep 2

# Check if process is still running
if kill -0 "$SERVICE_PID" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Service started (PID: ${SERVICE_PID})"
else
    echo -e "${RED}  Error: Service failed to start.${NC}"
    echo "  Check log: ${ROOT_DIR}/log/registry-center.log"
    exit 1
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
VPS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || VPS_IP=""
[ -z "${VPS_IP}" ] && VPS_IP="localhost"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Registry Center installed and started!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  URL:       http://${VPS_IP}:5000"
echo "  PID:       ${SERVICE_PID}"
echo "  Directory: ${ROOT_DIR}"
echo "  Log:       ${ROOT_DIR}/log/registry-center.log"
echo ""
echo "  To stop:   kill ${SERVICE_PID}"
echo "  Reconfigure: ${VENV_DIR}/bin/python -m agent_registry.init"
echo ""
echo "  Manual config files:"
echo "    etc/conf/server.conf"
echo "    etc/conf/persistence.conf"
echo "    common/config/llm_config.json"
echo -e "${GREEN}============================================${NC}"
