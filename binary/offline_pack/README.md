# OpenAN Offline Deployment Guide

This directory provides a **two-phase offline deployment solution** for OpenAN, designed for air-gapped or network-restricted environments. Unlike the [one-click installer](../one-click/README.md) which downloads everything at install time, the offline packager pre-downloads all dependencies (Python wheels, npm cache, source code) on an **online machine**, producing self-contained tarballs that can be transferred to an **offline machine** and installed without any internet access.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Phase 1: Build Offline Packages (Online Machine)](#phase-1-build-offline-packages-online-machine)
- [Phase 2: Install on Air-Gapped Machine (Offline)](#phase-2-install-on-air-gapped-machine-offline)
- [Script Reference](#script-reference)
- [Interactive Prompts](#interactive-prompts)
- [Service Ports and URLs](#service-ports-and-urls)
- [Log File Locations](#log-file-locations)
- [Stopping Services](#stopping-services)
- [Uninstalling OpenAN](#uninstalling-openan)
- [LLM Configuration](#llm-configuration)

---

## How It Works

```
 ┌───────────────────────┐          ┌───────────────────────┐
 │   Online Machine      │          │  Offline Machine      │
 │                       │          │                       │
 │  1. ./pack.sh         │  transfer│  2. ./install.sh      │
 │     ↓                 │ ───────> │     ↓                 │
 │  dist/*.tar.gz        │  USB/SCP │  Extract + venv +     │
 │  (source + wheels +   │          │  install wheels +     │
 │   npm cache)          │          │  build frontend +     │
 │                       │          │  nginx + start        │
 └───────────────────────┘          └───────────────────────┘
```

Each component (registry-center, orchestration-center) is packed into an independent tarball containing:
- Full project source code
- Pre-downloaded Python wheels for **both x86_64 and aarch64** architectures
- npm cache for offline frontend build (orchestration-center only)

The install script auto-detects the target machine's architecture and installs the appropriate wheels — no internet connection needed at install time.

---

## Prerequisites

### Packing Machine (Online)

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| OS | Linux (x86_64 / aarch64) | — |
| Python | 3.12+ | Required |
| Node.js | 20.19+ + npm | Required for `--orc` (frontend cache) |
| curl | Any | For source download |
| tar | Any | For source extraction |
| Internet | Required | Needs GitHub and PyPI access |

### Installing Machine (Offline / Air-Gapped)

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| OS | Linux (x86_64 / aarch64) | Supports Debian/Ubuntu, CentOS/RHEL/Rocky/Alma/openEuler |
| Python | 3.12+ | **Must be pre-installed** (no auto-install in offline mode) |
| Node.js | 20.19+ + npm | **Must be pre-installed** (required for `--orc`) |
| nginx | Any | **Must be pre-installed** (required for `--orc`) |
| openssl | Any | For SSL certificate generation |
| Internet | **Not required** | Fully offline |

> **Key difference from one-click:** The offline installer does **not** attempt to install Python, Node.js, or nginx — these must be pre-installed on the target machine. This is because the auto-install feature relies on internet access (package managers, prebuilt binary downloads).

---

## Phase 1: Build Offline Packages (Online Machine)

Run `pack.sh` on a machine with internet access to build self-contained tarballs.

#### 1. Clone and enter the directory

```bash
git clone https://github.com/project-openan/openan-installation.git
cd openan-installation/binary/offline_pack
```

#### 2. Grant execute permission (if needed)

```bash
chmod +x pack.sh
```

#### 3. Run the packager

```bash
./pack.sh              # Pack both components (default)
```

Or pack individual components:

| Flag | Description |
|------|-------------|
| `--reg` | Pack only registry-center |
| `--orc` | Pack only orchestration-center |
| (neither specified) | Default: pack both (equivalent to `--reg --orc`) |
| `-h` / `--help` | Show help and exit |

```bash
# Examples
./pack.sh                    # Pack everything (default)
./pack.sh --reg              # Pack only registry-center
./pack.sh --orc              # Pack only orchestration-center
./pack.sh --reg --orc        # Pack both
./pack.sh --help             # Show help
```

#### 4. Check the output

Tarballs are produced in `dist/`:

```
dist/
├── registry-center-1.0.0-linux.tar.gz
└── orchestration-center-1.0.0-linux.tar.gz
```

Each tarball is fully self-contained — no additional downloads are needed at install time.

---

## Phase 2: Install on Air-Gapped Machine (Offline)

Transfer the tarballs and scripts to the offline machine, then install.

#### 1. Transfer files

Copy the following to the offline machine (USB, SCP, etc.):

```
offline_pack/
├── dist/
│   ├── registry-center-1.0.0-linux.tar.gz      # from pack.sh
│   └── orchestration-center-1.0.0-linux.tar.gz  # from pack.sh
├── install.sh
├── uninstall.sh
└── configure_llm.sh
```

> All files must be in the **same directory**. The install script searches for tarballs in `dist/` first, then in the script directory.

#### 2. Grant execute permission (if needed)

```bash
chmod +x install.sh uninstall.sh configure_llm.sh
```

#### 3. Run the installer

```bash
./install.sh              # Auto-detect and install available package(s)
```

Or specify installation targets:

| Flag | Description |
|------|-------------|
| `--reg` | Install only registry-center |
| `--orc` | Install only orchestration-center |
| (neither specified) | Auto-detect: search for tarballs and install what's found |
| `--sample` | Start agents examples server (port 8080, off by default) |
| `-h` / `--help` | Show help and exit |

```bash
# Examples
./install.sh                    # Auto-detect and install available package(s)
./install.sh --reg              # Install only registry-center
./install.sh --orc              # Install only orchestration-center
./install.sh --reg --orc        # Install both
./install.sh --reg --orc --sample  # Install everything and start sample agents
./install.sh --help             # Show help
```

> In `--orc` mode (without `--reg`), the script prompts for the URL of the running registry-center (default `https://127.0.0.1:5000`). The URL is written as-is to `server.conf` and the `AGENT_REGISTRY_URL` environment variable — no `https→http` conversion.

---

## Script Reference

### pack.sh

Run on the **online machine** to build offline packages.

**What it does:**
1. Downloads project source from GitHub Release (via `curl` + `tar`, no `git clone`)
2. Downloads Python wheels for both x86_64 and aarch64 (using `pip download` with manylinux platform tags)
3. Runs `npm install` to populate the npm cache (orchestration-center only; `node_modules` are NOT bundled)
4. Generates README/manifest inside the tarball
5. Creates the tarball in `dist/`

**Output:** `dist/<component>-<version>-linux.tar.gz`

### install.sh

Run on the **offline machine** to install from tarballs.

**What it does:**
1. Finds and extracts tarballs (auto-detect or `--reg`/`--orc`)
2. Detects system architecture (x86_64 / aarch64) and verifies wheels exist
3. Creates Python venvs and installs dependencies from local wheels (no internet)
4. Builds frontend from npm cache and deploys static assets to `/var/www/openan/`
5. Generates self-signed SSL certificates
6. Configures nginx HTTPS reverse proxy
7. Starts all services

### uninstall.sh

Removes OpenAN installation while preserving environment tools.

```bash
./uninstall.sh           # Interactive confirmation
./uninstall.sh --force   # Skip confirmation (for automation)
```

### configure_llm.sh

Standalone LLM configuration script. Updates `llm_config.json` for registry-center and/or orchestration-center. Can be run at any time after installation.

```bash
# Interactive mode (configure both projects separately, with reuse option):
./configure_llm.sh --reg --orc

# Non-interactive (same config for both projects):
./configure_llm.sh --model <model-name> --url <url> --api-key <your-api-key>

# API key via env var (avoids key in shell history):
LLM_API_KEY=<your-api-key> ./configure_llm.sh --model <model-name> --url <url>

# Show full help:
./configure_llm.sh --help
```

---

## Interactive Prompts

During `install.sh` execution, the following interactive prompts may appear. Except for LLM configuration, all are automated or sudo password prompts.

### 1. sudo Password Prompt (may appear multiple times)

```
[sudo] password for <username>:
```

**When**: When the script needs to modify `/etc/nginx/`, deploy static assets to `/var/www/openan/`, or generate SSL certificates.

### 2. Skip LLM Configuration

```
Skip LLM configuration and configure manually? [y/N]:
```

**Default**: `N` (do not skip, enter interactive configuration). Type `y` to skip and configure later via `configure_llm.sh`.

### 3. LLM Model Name / API URL / API Key

If not skipped, `configure_llm.sh` handles the interactive configuration:
- Prompts for model name, API URL, and API key (masked input)
- Validates the LLM connection by sending a test request
- On validation failure, offers retry or skip
- In `--reg --orc` mode: configures registry first, then offers to reuse the same config for orchestration

See [LLM Configuration](#llm-configuration) for details.

### 4. Registry Center URL (--orc mode only, without --reg)

```
Enter registry center URL [https://127.0.0.1:5000]:
```

**Default**: `https://127.0.0.1:5000`. Enter the actual URL of a running registry-center.

### 5. Start Sample Agents Server

```
Start sample agents server? [y/N]:
```

**Default**: `N`. Only prompted if `--sample` flag was not passed. Sample agents provide demo agents for testing on port 8080.

---

## Service Ports and URLs

After deployment, services are accessible at the following addresses:

| Service | Local Access (HTTP) | Remote Access (HTTPS, via Nginx proxy) |
|---------|---------------------|---------------------------------------|
| registry-center | http://127.0.0.1:5000 | https://[ip-of-vps]/registry/ |
| orchestration backend | http://127.0.0.1:5001 | https://[ip-of-vps]/api/orchestrate/ |
| Frontend (static files) | — | https://[ip-of-vps]/ |
| agents example server | http://127.0.0.1:8080 | — |
| Nginx HTTPS entry | — | https://[ip-of-vps] |

> **VPS remote access**: When deployed on a VPS, the Summary output auto-detects the VPS network IP (via `hostname -I`) and displays remote access URLs in the form `https://[ip-of-vps]`.
>
> All backend services bind to `127.0.0.1` and cannot be accessed externally. **Nginx is the sole remote entry point** (listening on `0.0.0.0:443`), proxying to services via path prefixes: `/` → frontend, `/api/orchestrate/` → backend, `/registry/` → registry-center.
>
> Nginx uses a self-signed certificate. Browsers will show a security warning; choose "Proceed" to continue.

---

## Log File Locations

| Service | Log Path |
|---------|----------|
| registry-center | `registry-center-*/log/registry-center.log` |
| orchestration backend | `orchestration-center-*/log/backend.log` |
| frontend build | `orchestration-center-*/log/frontend-build.log` |
| agents example server | `orchestration-center-*/log/agents-server.log` |
| nginx (local copy) | `orchestration-center-*/log/openan-nginx.conf` |

> Log files are relative to the install directory. Directory names are versioned (e.g., `registry-center-1.0.0-linux/`).

---

## Stopping Services

The install script dynamically outputs the PIDs and stop command for services that were actually started. To stop:

```bash
# Stop Python services
kill <REGISTRY_PID> <BACKEND_PID> <AGENTS_PID>

# Stop Nginx
sudo systemctl stop nginx
# or
sudo nginx -s stop
```

> Replace `<PID>` with the actual PIDs output at the end of the install script.

---

## Uninstalling OpenAN

To completely uninstall OpenAN (stop all processes, clean nginx configuration, remove project directories):

```bash
./uninstall.sh           # Interactive confirmation
./uninstall.sh --force   # Skip confirmation (for automation)
```

#### What Gets Removed

| Step | Action | Description |
|------|--------|-------------|
| Step 1 | Kill processes | Find and kill OpenAN processes by port (5000/5001/8080/8899-8907/26335/26336), with smart identification to avoid killing non-OpenAN processes |
| Step 2 | Stop nginx | Three-level fallback: `systemctl stop` → `nginx -s stop` → `pkill nginx` |
| Step 3 | Remove nginx config | Delete `/etc/nginx/conf.d/openan.conf`, `/etc/nginx/ssl/` certificates, `/var/www/openan/` static assets, local `openan-nginx.conf` |
| Step 4 | Remove project dirs | Delete `registry-center-*/` and `orchestration-center-*/` |

#### What Gets Preserved

The following are **not deleted**, for faster reinstallation:

- Python 3.12+
- Node.js 20.19+ + npm
- nginx binary and system package
- openssl
- `configure_llm.sh`

---

## LLM Configuration

LLM configuration is required for the chat model. You can configure it during installation or at any time afterwards using `configure_llm.sh`.

### Flags

| Flag | Description |
|------|-------------|
| `--reg` | Configure registry-center |
| `--orc` | Configure orchestration-center |
| (neither specified) | Default: configure both |
| `--model <name>` | LLM model name (non-interactive mode) |
| `--url <url>` | LLM API URL (non-interactive mode) |
| `--api-key <key>` | API key (or use `LLM_API_KEY` env var) |
| `--no-validate` | Skip API connection validation |
| `-h` / `--help` | Show help |

### Modes

- **Interactive** (auto-triggered when any of `--model`/`--url`/`--api-key` is missing): Prompts for each value, validates the connection, and offers retry on failure. In `--reg --orc` mode, configures registry first, then offers to reuse the same config for orchestration.
- **Non-interactive** (all parameters provided via flags): Validates once and writes the same config to all target projects.

### Examples

```bash
# Interactive (configure both projects separately, with reuse option):
./configure_llm.sh --reg --orc

# Non-interactive (same config for both projects):
./configure_llm.sh --model <model-name> --url <url> --api-key <your-api-key>

# API key via env var (avoids key in shell history):
LLM_API_KEY=<your-api-key> ./configure_llm.sh --model <model-name> --url <url>

# Update only a specific project:
./configure_llm.sh --reg --api-key <your-api-key>
./configure_llm.sh --orc --api-key <your-api-key>

# Skip validation:
./configure_llm.sh --reg --orc --model <model> --url <url> --api-key <key> --no-validate
```

> The script automatically detects installed projects via Glob patterns (e.g., `registry-center-*/common/config/llm_config.json`). If a project is not installed, it is skipped with a warning.
