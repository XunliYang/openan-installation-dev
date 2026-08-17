# Registry Center 离线部署 / Offline Deployment

[中文](#中文) | [English](#english)

---

## 中文

### 概述

本目录包含 Registry Center（注册中心）的离线部署脚本。采用**两阶段部署模式**：在联网机器上下载 x86_64 和 aarch64 双架构的 wheel 包并打包，然后在气隙（离线）机器上自动检测架构并安装。

### 目录文件

| 文件 | 说明 |
|------|------|
| `pack_reg.sh` | 在**联网机器**上运行，构建自包含的离线部署包 |
| `install_reg.sh` | 在**离线机器**上运行，创建虚拟环境、安装依赖、配置服务 |

### 部署流程

```
┌─────────────────┐     tar.gz      ┌─────────────────┐
│  联网机器 (Online) │ ──────────────▶ │  离线机器 (Air-gapped) │
│                  │   USB / SCP     │                  │
│  pack_reg.sh     │                 │  install_reg.sh  │
└─────────────────┘                  └─────────────────┘
```

#### 第一阶段：在联网机器上打包

```bash
# 前提条件：Python 3.12+、互联网连接
./bin/pack_reg.sh

# 指定版本号和输出目录
./bin/pack_reg.sh --version=1.0.0 --output=dist
```

支持的参数：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--python-version=VER` | 目标 Python 版本 | `3.12` |
| `--version=VER` | 包版本号 | `1.0.0` |
| `--output=DIR` | 输出目录 | `./dist` |

> 打包脚本无条件下载 x86_64 和 aarch64 双架构 wheels，无需指定目标架构。

打包过程：
1. 验证 Python 3.12+ 环境
2. 创建打包用虚拟环境
3. 复制项目源码
4. 下载 x86_64 和 aarch64 双架构 wheel 包（支持 manylinux_2_34/2_28/2_17/2014）
5. 生成 `README_OFFLINE.txt`
6. 创建 `tar.gz` 压缩包

> **架构说明**：离线包同时包含 x86_64 和 aarch64 双架构的 wheel 包。setup 脚本会自动检测离线机器的架构并安装对应的 wheels，无需手动指定。

#### 第二阶段：在离线机器上安装

```bash
# 1. 解压离线包
tar -xzf registry-center-1.0.0-linux.tar.gz
cd registry-center-1.0.0-linux

# 2. 运行安装脚本（推荐用 source 激活 venv）
source bin/install_reg.sh

# 跳过交互式配置
source bin/install_reg.sh --skip-init

# 指定 Python 解释器
source bin/install_reg.sh --python=python3.12

# 3. 启动服务
bin/start.sh

# 4. 停止服务
bin/stop.sh
```

`install_reg.sh` 支持的参数：

| 参数 | 说明 |
|------|------|
| `--skip-init` | 跳过交互式配置向导 |
| `--python=PATH` | 指定 Python 解释器（默认自动检测 `python3.12`） |

> **架构自动检测**：setup 脚本会自动检测系统架构（`uname -m`），归一化为 `x86_64` 或 `aarch64`，并验证 wheels 目录中存在对应架构的 wheel 包。无需手动指定架构。

安装过程：
1. 检测系统架构并验证 wheels（自动检测 `x86_64` / `aarch64`）
2. 检查 Python（最低 3.10+）
3. 创建虚拟环境（venv）
4. 从本地 wheels 安装依赖（无需联网）
5. 运行交互式配置向导（可跳过）

> **注意**：使用 `source` 执行脚本可在当前 shell 中激活虚拟环境。直接执行（`./bin/install_reg.sh`）则不会激活，需手动运行 `source venv/bin/activate`。

### 离线机器前提条件

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| 操作系统 | Linux（x86_64 / aarch64） | 离线包包含双架构 wheels，自动检测 |
| Python | 3.10+（推荐 3.12） | 需预装 |
| 网络连接 | 不需要 | 完全离线运行 |

### 配置文件

安装后可通过交互式向导配置，也可手动编辑：

```bash
# 重新运行配置向导（随时可用）
./venv/bin/python -m agent_registry.init
```

或手动编辑以下文件：

| 文件 | 说明 |
|------|------|
| `etc/conf/server.conf` | IP、端口、TLS、签名配置 |
| `etc/conf/persistence.conf` | 存储模式：`file` 或 `postgresql` |
| `common/config/llm_config.json` | LLM API 密钥（可选） |

### TLS 证书

如果启用了 HTTPS，需将证书放入 `etc/ssl/` 目录：

```
etc/ssl/server.cer       ← 服务器证书
etc/ssl/server_key.pem   ← 私钥
etc/ssl/trust.cer        ← CA 信任库
etc/ssl/cert_pwd         ← 私钥密码
```

### systemd 服务（可选）

```bash
# 安装为 systemd 服务（需要 root）
sudo ./bin/install_service.sh install
sudo systemctl start registry-center

# 查看状态
sudo systemctl status registry-center

# 停止 / 卸载
sudo systemctl stop registry-center
sudo ./bin/install_service.sh uninstall
```

### 目录结构

```
registry-center-1.0.0-linux/
├── agent_registry/       应用源码
├── common/               共享模块和配置模板
├── etc/conf/             配置文件
├── etc/systemd/          systemd 服务模板
├── bin/                  运维脚本
├── wheels/               预下载的 Python wheel 包（x86_64 + aarch64）
├── venv/                 虚拟环境（由 install_reg.sh 创建）
├── log/                  运行日志
├── run/                  PID/socket 文件
├── data/                 文件存储数据
└── requirements.txt      Python 依赖清单
```

### 常见问题

**Q: wheel 包安装失败怎么办？**
A: 离线包包含 x86_64 和 aarch64 双架构 wheels。如果安装失败，检查 wheels 目录中是否存在对应架构的 wheel 包（文件名包含 `x86_64` 或 `aarch64`）。可能是打包过程中网络问题导致某种架构的 wheels 下载不完整，重新运行打包脚本即可。

**Q: 如何重新配置？**
A: 运行 `./venv/bin/python -m agent_registry.init`，可随时重新配置 IP、端口、TLS、存储等。

**Q: 虚拟环境损坏了怎么办？**
A: 删除 `venv/` 目录后重新运行 `source bin/install_reg.sh`，会从本地 wheels 重建。

---

## English

### Overview

This directory contains offline deployment scripts for the Registry Center. It uses a **two-phase deployment model**: download wheels for both x86_64 and aarch64 architectures and package on an online machine, then auto-detect architecture and install on an air-gapped (offline) machine.

### Directory Files

| File | Description |
|------|-------------|
| `pack_reg.sh` | Run on the **online** machine to build a self-contained offline package |
| `install_reg.sh` | Run on the **offline** machine to create venv, install deps, and configure |

### Deployment Workflow

```
┌─────────────────┐     tar.gz      ┌─────────────────┐
│  Online Machine  │ ──────────────▶ │  Air-gapped Machine │
│                  │   USB / SCP     │                  │
│  pack_reg.sh     │                 │  install_reg.sh  │
└─────────────────┘                  └─────────────────┘
```

#### Phase 1: Package on the Online Machine

```bash
# Prerequisites: Python 3.12+, internet access
./bin/pack_reg.sh

# Specify version label and output directory
./bin/pack_reg.sh --version=1.0.0 --output=dist
```

Supported options:

| Option | Description | Default |
|--------|-------------|---------|
| `--python-version=VER` | Target Python version | `3.12` |
| `--version=VER` | Package version label | `1.0.0` |
| `--output=DIR` | Output directory | `./dist` |

> The packager downloads wheels for both x86_64 and aarch64 unconditionally. No need to specify a target architecture.

Packaging process:
1. Verify Python 3.12+ environment
2. Create a packaging virtual environment
3. Copy project source code
4. Download wheels for both x86_64 and aarch64 (supports manylinux_2_34/2_28/2_17/2014)
5. Generate `README_OFFLINE.txt`
6. Create the `tar.gz` archive

> **Architecture note**: The offline package contains wheels for both x86_64 and aarch64. The setup script auto-detects the machine architecture and installs the matching wheels. No manual arch specification needed.

#### Phase 2: Install on the Offline Machine

```bash
# 1. Extract the package
tar -xzf registry-center-1.0.0-linux.tar.gz
cd registry-center-1.0.0-linux

# 2. Run the setup script (use 'source' to activate venv in your shell)
source bin/install_reg.sh

# Skip interactive configuration
source bin/install_reg.sh --skip-init

# Specify Python interpreter
source bin/install_reg.sh --python=python3.12

# 3. Start the service
bin/start.sh

# 4. Stop the service
bin/stop.sh
```

`install_reg.sh` supported options:

| Option | Description |
|--------|-------------|
| `--skip-init` | Skip the interactive configuration wizard |
| `--python=PATH` | Python interpreter to use (default: auto-detect `python3.12`) |

> **Architecture auto-detection**: The setup script auto-detects the system architecture (`uname -m`), normalizes it to `x86_64` or `aarch64`, and verifies that matching wheels exist. No manual arch flag needed.

Setup process:
1. Detect system architecture and verify wheels (auto-detects `x86_64` / `aarch64`)
2. Check Python (minimum 3.10+)
3. Create a virtual environment (venv)
4. Install dependencies from local wheels (no internet needed)
5. Run interactive configuration wizard (can be skipped)

> **Note**: Use `source` to run the script so the venv is activated in your current shell. If you run it directly (`./bin/install_reg.sh`), the venv will not be activated; you must manually run `source venv/bin/activate`.

### Offline Machine Prerequisites

| Component | Version | Notes |
|-----------|---------|-------|
| OS | Linux (x86_64 / aarch64) | Package contains both architectures, auto-detected |
| Python | 3.10+ (3.12 recommended) | Must be pre-installed |
| Network | Not required | Fully offline operation |

### Configuration

After setup, configure via the interactive wizard or by editing files manually:

```bash
# Re-run the configuration wizard (anytime)
./venv/bin/python -m agent_registry.init
```

Or manually edit the following files:

| File | Description |
|------|-------------|
| `etc/conf/server.conf` | IP, port, TLS, signing configuration |
| `etc/conf/persistence.conf` | Storage mode: `file` or `postgresql` |
| `common/config/llm_config.json` | LLM API key (optional) |

### TLS Certificates

If HTTPS is enabled, place certificates in the `etc/ssl/` directory:

```
etc/ssl/server.cer       ← Server certificate
etc/ssl/server_key.pem   ← Private key
etc/ssl/trust.cer        ← CA trust store
etc/ssl/cert_pwd         ← Private key password
```

### systemd Service (Optional)

```bash
# Install as systemd service (requires root)
sudo ./bin/install_service.sh install
sudo systemctl start registry-center

# Check status
sudo systemctl status registry-center

# Stop / uninstall
sudo systemctl stop registry-center
sudo ./bin/install_service.sh uninstall
```

### Directory Layout

```
registry-center-1.0.0-linux/
├── agent_registry/       Application source code
├── common/               Shared modules and config templates
├── etc/conf/             Configuration files
├── etc/systemd/          Systemd service templates
├── bin/                  Operational scripts
├── wheels/               Pre-downloaded Python wheel packages (x86_64 + aarch64)
├── venv/                 Virtual environment (created by install_reg.sh)
├── log/                  Runtime logs
├── run/                  PID/socket files
├── data/                 File-based storage data
└── requirements.txt      Python dependency list
```

### Troubleshooting

**Q: Wheel installation failed. What should I do?**
A: The offline package contains wheels for both x86_64 and aarch64. If installation fails, check that the wheels directory contains arch-specific wheels (filenames containing `x86_64` or `aarch64`). A network issue during packaging may have caused incomplete downloads for one architecture. Re-run the packager to fix.

**Q: How do I reconfigure?**
A: Run `./venv/bin/python -m agent_registry.init` to reconfigure IP, port, TLS, storage, etc. at any time.

**Q: The virtual environment is broken. What now?**
A: Delete the `venv/` directory and re-run `source bin/install_reg.sh`. It will rebuild from the local wheels.
