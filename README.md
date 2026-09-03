# OpenAN Installation

System-level installation tooling for OpenAN, providing one-click binary installation and clustered containerized installation with modular component selection and fully configurable parameters.

## Project Structure

```
openan-installation/
├── binary/one-click/                # Binary installation
│   ├── openan_install.sh            # one-click installation script
│   ├── openan_uninstall.sh          # one-click uninstall script
│   ├── README.md                    # Binary installation guide
└── containerized/                   # Containerized installation
    ├── build/                       # Image build scripts
    ├── install.sh                   # Interactive installation tool
    ├── uninstall.sh                 # One-click uninstall script
    ├── openan-chart/                # Helm chart
    └── QUICKSTART.md                # Containerized installation guide
```

## Architecture

### Containerized Deployment (Kubernetes)

```
┌──────────────────────────────────────────────────────────────────┐
│                       Kubernetes Cluster                         │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Ingress (Nginx)                       │   │
│  │  / → workflow-designer:80                                │   │
│  │  /api/orchestrate/* → orchestration-center:5001          │   │
│  │  /registry/* → registry-center:5000                      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                   │
│         ┌────────────────────┼────────────────────┐             │
│         ▼                    ▼                    ▼             │
│  ┌─────────────┐    ┌─────────────────┐  ┌──────────────┐     │
│  │  Workflow   │    │  Orchestration  │  │   Registry   │     │
│  │  Designer   │    │    Center       │  │   Center     │     │
│  │  (Frontend) │    │                 │  │              │     │
│  │             │    │  - LLM Chat     │  │  - LLM Chat  │     │
│  │  - Nginx    │    │  - A2AT         │  │  - LLM Embed │     │
│  │  - React    │    │  - Workflow     │  │  - LLM Rerank│     │
│  │             │    │    Execution    │  │  - VectorDB  │     │
│  │  Port: 80   │    │                 │  │              │     │
│  │  HPA: 2-10  │    │  Port: 5001     │  │  Port: 5000  │     │
│  └─────────────┘    │  HPA: 1-10      │  │  Replicas: 2 │     │
│                     └─────────────────┘  └──────────────┘     │
│                              │                    │             │
│                              └────────┬───────────┘             │
│                                       ▼                         │
│                     ┌─────────────────────────────┐            │
│                     │        PostgreSQL           │            │
│                     │                             │            │
│                     │  - registry_center DB       │            │
│                     │  - orchestration_center DB  │            │
│                     │  - PVC 20Gi                 │            │
│                     │                             │            │
│                     │  Port: 5432                 │            │
│                     └─────────────────────────────┘            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Components:**

| Component | Description | Port | Replicas |
|-----------|-------------|------|----------|
| Workflow Designer | Frontend UI (React + Nginx) | 80 | 2 (HPA: 2-10) |
| Orchestration Center | Workflow execution engine | 5001 | 1 (HPA: 1-10) |
| Registry Center | Agent registration & discovery | 5000 | 2 |
| PostgreSQL | Shared database | 5432 | 1 (StatefulSet) |

**Features:**
- Auto-detection: StorageClass, LoadBalancer, Ingress Controller
- MetalLB auto-installation for bare-metal clusters
- TLS certificates auto-generation (registry center)
- HPA auto-scaling for frontend and orchestration
- Optional VectorDB (Milvus) integration

### Binary Deployment (Single Node)

```
┌──────────────────────────────────────────────────────────────────┐
│                      Single Node / VM                            │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Nginx (Port 443)                      │   │
│  │  HTTPS reverse proxy with self-signed certificate        │   │
│  │  / → /var/www/openan (static files)                     │   │
│  │  /api/orchestrate/* → 127.0.0.1:5001                    │   │
│  │  /registry/* → 127.0.0.1:5000                           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                   │
│         ┌────────────────────┼────────────────────┐             │
│         ▼                    ▼                    ▼             │
│  ┌─────────────┐    ┌─────────────────┐  ┌──────────────┐     │
│  │   Static    │    │  Orchestration  │  │   Registry   │     │
│  │   Files     │    │    Center       │  │   Center     │     │
│  │             │    │                 │  │              │     │
│  │  /var/www/  │    │  Python venv    │  │  Python venv │     │
│  │  openan/    │    │  Port: 5001     │  │  Port: 5000  │     │
│  │  (React)    │    │  PID: dynamic   │  │  PID: dynamic│     │
│  └─────────────┘    └─────────────────┘  └──────────────┘     │
│                              │                    │             │
│                              └────────┬───────────┘             │
│                                       ▼                         │
│                     ┌─────────────────────────────┐            │
│                     │        PostgreSQL           │            │
│                     │                             │            │
│                     │  - registry_center DB       │            │
│                     │  - orchestration_center DB  │            │
│                     │                             │            │
│                     │  Port: 5432                 │            │
│                     └─────────────────────────────┘            │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Agents Server (Optional)                    │   │
│  │  Sample agents for testing (Port 8080)                   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Components:**

| Component | Description | Port | Process |
|-----------|-------------|------|---------|
| Nginx | HTTPS reverse proxy | 443 | systemd / manual |
| Static Files | Frontend (React build) | - | Served by Nginx |
| Orchestration Center | Workflow execution | 5001 | Python process |
| Registry Center | Agent registration | 5000 | Python process |
| PostgreSQL | Shared database | 5432 | System service |
| Agents Server | Sample agents (optional) | 8080 | Python process |

**Features:**
- One-click installation with automatic dependency setup
- Python 3.12+ auto-installation (apt/dnf/standalone)
- Node.js 20.19+ auto-installation for frontend build
- Self-signed SSL certificate generation
- Automatic venv creation and dependency installation
- Process management with PID tracking

## Installation Methods

### 1. Clustered Containerized Installation (Kubernetes)

Production-grade installation using Helm charts. Supports multi-node clusters, HPA auto-scaling, and TLS certificates.

```bash
git clone https://github.com/project-openan/openan-installation.git
cd openan-installation/containerized
./install.sh
```

**Features:**
- Modular component selection (Registry Center, Orchestration Center, Workflow Designer)
- Fully configurable parameters (LLM API keys, image registry, storage)
- Auto-detects cluster environment (StorageClass, Ingress Controller, LoadBalancer)
- MetalLB auto-installation for bare-metal clusters
- One-click uninstall with optional data cleanup

**Manual / System Admin Installation:**
If you prefer to manually install the Helm chart, follow these steps:
- Prerequisites: Ensure you have a Kubernetes cluster (v1.25+) and Helm 3.10.0+ installed.
- Build your local images by running `containerized/build/build.sh` or pull from ghcr.io.
- Customize the Helm chart values in `containerized/openan-chart/values.yaml`, and then install the chart using Helm:
```bash
cd containerized
helm install openan ./openan-chart -n openan --create-namespace
```

### 2. One-Click Binary Installation

Binary-based installation for virtual machines or bare-metal servers. Downloads and starts all services locally with automatic dependency setup.

**Linux/macOS:**
```bash
cd binary/one-click
./openan_install.sh
```

**Features:**
- Downloads and starts all services locally (PostgreSQL, Registry, Orchestration, Frontend)
- Automatic dependency setup (Python venvs, Node.js)
- Ready for installation in minutes

## Uninstall

### Containerized

```bash
cd containerized
./uninstall.sh
```

Or manually:

```bash
helm uninstall openan -n openan
kubectl delete namespace openan
```

### Binary

```bash
cd binary/one-click
./openan_uninstall.sh
```

## Upgrade

> **Note:** Upgrade functionality including single component upgrades and all-in-one upgrades is currently under development and not yet available.

## Documentation

- [Quick Start](./containerized/QUICKSTART.md) - One-click installation guide
- [Helm Chart](./containerized/openan-chart/README.md) - Helm configuration reference
- [Image Build](./containerized/build/README.md) - Custom image building
- [Binary Installation](./binary/one-click/README.md) - Binary installation details

