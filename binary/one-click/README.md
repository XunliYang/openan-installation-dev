# OpenAN 一键部署与卸载脚本使用说明 / One-Click Deployment & Uninstallation Script Guide

[中文](#中文) | [English](#english)

---

## 中文

本脚本用于在 Linux 服务器上一键部署 OpenAN 全套服务，包括 registry-center、orchestration-center 后端与前端、agents 示例服务，以及 Nginx HTTPS 反向代理。部署在 VPS 上时，脚本会自动检测 VPS IP 并在 Summary 中显示远程访问地址（`https://[ip-of-vps]`），用户可直接从本地浏览器访问。

---

### 目录

- [环境要求](#环境要求)
- [从 Git Clone 到运行](#从-git-clone-到运行)
- [脚本执行流程详解](#脚本执行流程详解)
- [用户交互提示一览](#用户交互提示一览)
- [服务端口与访问地址](#服务端口与访问地址)
- [日志文件位置](#日志文件位置)
- [停止服务](#停止服务)
- [卸载 OpenAN](#卸载-openan)

---

### 环境要求

| 组件 | 最低版本 | 说明 |
|------|---------|------|
| 操作系统 | Linux (x86_64 / aarch64) | 支持 Debian/Ubuntu、CentOS/RHEL/Rocky/Alma/openEuler |
| Python | 3.12+ | 脚本会自动检测并尝试安装 |
| Node.js | 20.19+ | 脚本会自动检测并尝试安装 |
| npm | 随 Node.js 附带 | — |
| curl | 任意 | 系统自带 |
| tar | 任意 | 系统自带 |
| 网络连接 | 必需 | 需访问 GitHub 下载组件 Release |

> 如果 Python 3.12+、Node.js 20.19+ 或 nginx 未安装，脚本会尝试通过包管理器或预编译二进制自动安装，此时可能需要 **sudo 权限**。

---

### 从 Git Clone 到运行

#### 1. 克隆仓库

```bash
git clone https://github.com/XunliYang/openan-installation-dev.git
cd openan-installation-dev/binary/one-click
```

#### 2. 赋予执行权限（如果需要）

```bash
chmod +x openan_install.sh openan_uninstall.sh configure_llm.sh
```

#### 3. 运行脚本

```bash
./openan_install.sh
```

脚本会自动完成所有下载、配置和启动工作。运行过程中会有少量交互提示（见下文），其余全自动完成。

#### 4. 选择安装模式（可选）

脚本支持通过 `--reg` 和 `--orc` 两个 flag 选择安装目标，与 `configure_llm.sh` 的 flag 设计保持一致：

| 参数 | 说明 |
|------|------|
| `--reg` | 安装 registry-center |
| `--orc` | 安装 orchestration-center |
| （两者均未指定） | 默认安装两者（等同 `--reg --orc`） |
| `--sample` | 启动 agents 示例服务（端口 8080，默认关闭） |
| `-h` / `--help` | 显示帮助并退出 |

```bash
# 示例
./openan_install.sh                    # 安装全部（默认：--reg --orc）
./openan_install.sh --reg               # 仅安装 registry-center
./openan_install.sh --orc               # 仅安装 orchestration-center
./openan_install.sh --reg --orc --sample # 安装全部并启动示例 agents
./openan_install.sh --help              # 查看帮助
```

> `--orc`（不含 `--reg`）模式下，脚本会提示输入已在运行的 registry-center 的 URL（默认 `https://127.0.0.1:5000`），该 URL 将原样写入 `server.conf` 和环境变量 `AGENT_REGISTRY_URL`，不做 `https→http` 转换。

**各模式执行的步骤对比：**

| 步骤 | `--reg --orc` | `--reg` | `--orc` |
|------|---------------|---------|---------|
| Python 3.12+ 检查 | ✅ | ✅ | ✅ |
| Node.js / npm 检查与安装 | ✅ | ❌ 跳过 | ✅ |
| Nginx 检查与安装 | ✅ | ❌ 跳过 | ✅ |
| 下载 registry-center | ✅ | ✅ | ❌ 跳过 |
| 下载 orchestration-center | ✅ | ❌ 跳过 | ✅ |
| 配置 registry-center | ✅ | ✅ | ❌ 跳过 |
| 配置 orchestration-center | ✅ | ❌ 跳过 | ✅ |
| LLM 配置 | ✅ 两者都配 | ✅ 仅 registry | ✅ 仅 orchestration |
| 询问 registry URL | ❌ 自动修复 | ❌ 不需要 | ✅ 交互式输入 |
| Nginx 配置 | ✅ | ❌ 跳过 | ✅ /registry/ 指向用户 URL |
| 启动 registry-center | ✅ | ✅ | ❌ |
| 启动 orchestration 后端 | ✅ | ❌ | ✅ |
| 启动 orchestration 前端 | ✅ | ❌ | ✅ |
| 启动 agents 示例服务 | ⬜ 可选 | ❌ | ⬜ 可选 |
| 启动 Nginx | ✅ | ❌ | ✅ |

> **关于 Assurance Agent**：即使不指定 `--sample`，`--reg --orc` 和 `--orc` 模式下
> registry-center 中仍会出现一个 "Assurance Agent"。这是 orchestration-center
> 启动时内嵌注册的 agent（端口 8902），不是 agents 示例服务。详见
> [ADR-006](./docs/ADR-006-orchestration-built-in-agent-self-registration.md)。

#### 5. 卸载（可选）

如需完全卸载 OpenAN（停止所有进程、清理 nginx 配置、删除项目目录），使用卸载脚本：

```bash
./openan_uninstall.sh           # 交互式确认
./openan_uninstall.sh --force   # 跳过确认（适用于自动化场景）
```

> 卸载脚本会**保留环境工具**（Python、Node.js、npm、nginx），方便下次重装时跳过环境准备。详见[卸载 OpenAN](#卸载-openan) 章节。

---

### 脚本执行流程详解

#### Step 0：环境检查

- **Python 3.12+**：依次尝试 `python3.12` → `python3`。若均不存在，自动检测发行版并尝试：
  - Debian/Ubuntu：`apt-get install python3.12`（含 deadsnakes PPA 回退）
  - CentOS/RHEL/Rocky/Alma/openEuler：`dnf/yum install python3.12`（含 module enable 回退）
  - 最终回退：从 [python-build-standalone](https://github.com/indygreg/python-build-standalone) 下载独立版 Python
- **Node.js 20.19+**：依次尝试已有 `node` 命令。若不存在或版本不足，自动检测发行版并尝试：
  - Debian/Ubuntu：`apt-get install nodejs npm`（含 NodeSource setup_20.x 回退）
  - CentOS/RHEL/Rocky/Alma/openEuler：`dnf/yum install nodejs npm`（含 NodeSource setup_20.x 回退）
  - 最终回退：从 [nodejs.org](https://nodejs.org/dist/) 下载预编译二进制（v20.19.0，含 npm，安装到本地 `.node` 目录）
- **npm**：随 Node.js 一起验证；若已有 Node.js 但缺少 npm，尝试通过包管理器安装
- **curl / tar**：检查是否存在

#### Step 0.5：检查 Nginx

- 若 `nginx` 或 `openssl` 未安装，自动通过包管理器安装（apt / dnf / yum）
- 安装需要 sudo 权限

#### Step 1：下载组件源码

从 GitHub Release 下载并解压（使用 `curl` + `tar`，不依赖 `git clone`）：

| 组件 | 下载地址 | 版本 |
|------|---------|------|
| registry-center | `https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |
| orchestration-center | `https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |

> 若目录已存在且非空，则跳过下载。

#### Step 2：配置 registry-center

1. 创建 Python 虚拟环境（venv）
2. 安装 Python 依赖（`pip install -r requirements.txt`）
3. 生成自签名证书（RSA，serverAuth，密码 `Dev@12345`）
4. 准备 SSL 目录（`etc/ssl/`），复制证书并设置 0600 权限
5. 修正 `server.conf` 中的 `jwk_private_key_path` 路径
6. 运行 `python -m agent_registry.init` 初始化（自动输入默认值，无需用户交互）

#### Step 3：配置 orchestration-center

1. 创建 Python 虚拟环境（venv）
2. 安装后端 Python 依赖
3. 进入 `workflow-designer/` 目录，运行 `npm install --force` 安装前端依赖

#### Step 3.5：配置 LLM 与注册中心地址

**此步骤有用户交互，详见[用户交互提示一览](#用户交互提示一览)。**

- 可选择跳过 LLM 配置
- 委托 `configure_llm.sh` 处理交互式输入、验证和写入（`--reg --orc` 模式下分开询问 registry 和 orchestration 的配置，并提供复用选项）
- 建议使用：
```
model name: glm-5.1
model url: https://open.bigmodel.cn/api/paas/v4/chat/completions
```
- 自动验证 LLM 连通性（逐项目验证，发送测试请求）
- 验证失败时允许重新输入或跳过
- 将配置写入 `llm_config.json`（根据安装目标：`--reg --orc` 配置两个项目，`--reg` 仅 registry-center，`--orc` 仅 orchestration-center）
- 无论是否跳过，脚本都会在 Step 3.5 结束时输出 `configure_llm.sh` 的使用说明，供用户随时重新配置 LLM（通过 `--reg`/`--orc` 参数指定目标）
- `--reg --orc` 模式：将 `server.conf` 中的 `agent_registry_url` 从 `https://` 修正为 `http://`（避免 SSL 版本不匹配错误）
- `--orc`（不含 `--reg`）模式：交互式询问用户已在运行的 registry-center 的 URL，原样写入 `server.conf` 和环境变量

#### Step 3.7：配置 Nginx HTTPS 反向代理

1. 生成自签名 SSL 证书（`/etc/nginx/ssl/cert.pem`、`key.pem`，有效期 365 天）
2. 生成 Nginx 配置文件并部署到 `/etc/nginx/conf.d/openan.conf`
3. 移除 Debian/Ubuntu 默认站点配置（避免端口冲突）
4. 测试 Nginx 配置有效性

#### Step 4：启动所有服务

依次启动以下 4 个服务，每个服务启动前会自动清理被占用的端口：

| 服务 | 端口 | 启动方式 |
|------|------|---------|
| registry-center | 5000 | `python -m agent_registry.start` |
| orchestration-center 后端 | 5001 | `python -m orchestrate.start` |
| agents 示例服务 | 8080 | `python -m samples.start_agents_server` |
| Nginx HTTPS 代理 | 443 | `systemctl start nginx` 或 `nginx` |

> 前端在安装阶段由 `npm run build` 构建为静态文件，由 nginx 直接服务，不作为独立进程运行（见 ADR-014）。

---

### 用户交互提示一览

运行过程中，脚本可能出现以下交互提示。除 LLM 配置外，其余均为 sudo 密码提示或自动完成。

#### 1. sudo 密码提示（可能多次出现）

```
[sudo] password for <用户名>:
```

**触发时机**：当脚本需要安装 Python、Node.js、npm、nginx、openssl，或操作 `/etc/nginx/` 目录时。

**你需要做什么**：输入当前用户的 sudo 密码。如果你以 root 用户运行，则不会出现此提示。

---

#### 2. 是否跳过 LLM 配置

```
Skip LLM configuration and configure manually? [y/N]:
```

**这是什么**：选择是否跳过 LLM 配置步骤。如果跳过，脚本不会询问模型名、API URL 和 API Key，也不会修改 `llm_config.json`。如果不跳过，`configure_llm.sh` 会交互式配置 LLM：`--reg --orc` 模式下先配置 registry，再提示是否为 orchestration 使用相同配置。

**默认值**：`N`（不跳过，进入交互式配置）

**你需要做什么**：
- 直接回车（或输入 `n`）进入交互式 LLM 配置流程
- 输入 `y` 跳过 LLM 配置，使用默认值

> 无论是否跳过，脚本都会在 Step 3.5 结束时输出 `configure_llm.sh` 的使用说明，供你随时重新配置 LLM：

```bash
# 重新配置 LLM（在脚本目录下运行）：
./configure_llm.sh --model glm-5.1 --url https://open.bigmodel.cn/api/paas/v4/chat/completions --api-key your-key

# 或通过环境变量传递 API key（避免 key 出现在 shell history 中）：
LLM_API_KEY=your-key ./configure_llm.sh --model glm-5.1 --url https://open.bigmodel.cn/api/paas/v4/chat/completions

# 交互模式（分开配置 registry 和 orchestration，含复用选项）：
./configure_llm.sh --reg --orc

# 仅更新指定项目（默认两者都配）：
./configure_llm.sh --reg --api-key your-key
./configure_llm.sh --orc --api-key your-key

# 查看完整帮助：
./configure_llm.sh --help
```

> **`--reg`/`--orc` 参数与安装模式的对应关系**：安装脚本和 `configure_llm.sh` 使用相同的 flag。如果指定的项目未安装（`llm_config.json` 不存在），脚本会在询问配置前检测并跳过，打印警告。两个项目都未安装时脚本直接报错退出。
>
> 如果跳过了交互式配置，LLM 相关功能将使用默认值，可能无法正常工作。请在启动服务前运行 `configure_llm.sh` 完成配置。

---

> **`--reg --orc` 模式下的分开询问流程**：`configure_llm.sh` 会先询问 registry 的 LLM 配置（下方提示 3-5），验证通过后提示 "Use same LLM config for orchestration? [Y/n]"。选择 Y 则复用 registry 的全部配置值；选择 n 则重新询问 orchestration 的配置。仅指定 `--reg` 或 `--orc` 时只询问一个项目的配置。

#### 3. LLM 模型名称

```
Enter LLM model name [qwen3.6-flash]:
```

**这是什么**：指定 LLM 聊天模型名称。脚本会用此名称调用大语言模型 API。

**默认值**：`qwen3.6-flash`（阿里云通义千问）

**常见选择**：

| 提供商 | 模型名称 |
|--------|---------|
| 阿里云通义千问 | `qwen3.6-flash` |
| 智谱 GLM | `glm-5.1` |

**你需要做什么**：直接回车使用默认值，或输入你使用的模型名称。

---

#### 4. LLM API URL

```
Enter LLM API URL [https://dashscope.aliyuncs.com/compatible-mode/v1]:
```

**这是什么**：LLM 服务的 API 接口地址（OpenAI 兼容格式）。脚本会自动在 URL 后拼接 `/chat/completions`（如果尚未包含）。

**默认值**：`https://dashscope.aliyuncs.com/compatible-mode/v1`（阿里云通义千问）

**常见选择**：

| 提供商 | API URL |
|--------|---------|
| 阿里云通义千问 | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4/chat/completions` |

**你需要做什么**：直接回车使用默认值，或输入你的 API 地址。

---

#### 5. LLM API Key

```
Enter your API key:
```

**这是什么**：调用 LLM API 的密钥，用于身份认证。

**默认值**：无（必须输入）

**你需要做什么**：输入你在 LLM 服务商处获取的 API Key。如果不输入，会跳过验证并提示后续手动编辑 `llm_config.json`。

> 脚本会对 Key 做掩码显示（仅显示前 4 位和后 4 位）。

---

#### 6. LLM 验证失败后的重试提示

当 API Key / URL / 模型验证失败时，脚本会依次重新询问以上三项：

```
[RETRY] Please re-enter LLM configuration.
        (Type 'skip' at any prompt to bypass validation)

Model [当前模型]:
API URL [当前URL]:
API key [***]:
```

**你需要做什么**：
- 修正输入错误的值后回车
- 在任意一个提示处输入 `skip` 可跳过验证（配置可能不正确，需后续手动修改 `llm_config.json`）
- 直接回车保留当前值不变

---

#### 7. Registry Center URL（仅 --orc 模式，不含 --reg）

```
Enter registry center URL [https://127.0.0.1:5000]:
```

**这是什么**：在 `--orc`（不含 `--reg`）模式下，orchestration-center 需要连接到一个已在运行的 registry-center。脚本会要求你输入其访问地址。

**默认值**：`https://127.0.0.1:5000`

**你需要做什么**：
- 直接回车使用默认值（适用于本地已运行的 registry-center）
- 输入远程 registry-center 的实际 URL（如 `https://10.0.0.5:5000`）

> 该 URL 会原样写入 `server.conf` 中的 `agent_registry_url` 和环境变量 `AGENT_REGISTRY_URL`，不做 `https→http` 转换。请确保输入的地址与 registry-center 的实际运行模式（HTTP 或 HTTPS）匹配。
>
> Nginx 配置中的 `/registry/` location 也会指向该 URL。

---

### 服务端口与访问地址

部署完成后，可通过以下地址访问各服务：

| 服务 | 本地访问（HTTP） | 远程访问（HTTPS，经 Nginx 代理） |
|------|-----------------|-------------------------------|
| registry-center | http://127.0.0.1:5000 | https://[ip-of-vps]/registry/ |
| orchestration 后端 | http://127.0.0.1:5001 | https://[ip-of-vps]/api/orchestrate/ |
| 前端（静态文件） | — | https://[ip-of-vps]/ |
| agents 示例服务 | http://127.0.0.1:8080 | — |
| Nginx HTTPS 入口 | — | https://[ip-of-vps] |

> **VPS 远程访问**：当脚本在 VPS 上运行时，Summary 输出会自动检测 VPS 网卡 IP（通过 `hostname -I`）并显示 `https://[ip-of-vps]` 形式的远程访问地址。将 `[ip-of-vps]` 替换为你的 VPS 实际 IP 地址（如 `https://203.0.113.50`）。
>
> 所有后端服务均绑定在 `127.0.0.1`，外部无法直连。**Nginx 是唯一的远程访问入口**（监听 `0.0.0.0:443`），通过路径前缀代理到各服务：`/` → 前端、`/api/orchestrate/` → 后端、`/registry/` → registry-center。agents 示例服务无 nginx 代理，远程不可访问。
>
> Nginx 使用自签名证书，浏览器会提示安全警告，选择"继续访问"即可。

---

### 日志文件位置

| 服务 | 日志路径 |
|------|---------|
| registry-center | `registry-center/registry-center.log` |
| orchestration 后端 | `orchestration-center/backend.log` |
| orchestration 前端 | `orchestration-center/frontend.log` |
| agents 示例服务 | `orchestration-center/agents-server.log` |

> 日志文件相对于脚本所在目录（即 `binary/one-click/`）。

---

### 停止服务

脚本运行结束后会动态输出本次实际启动的服务的 PID 和停止命令（仅列出已启动的服务）。停止方式：

```bash
# 停止 Python 和 Node.js 服务
kill <REGISTRY_PID> <BACKEND_PID> <FRONTEND_PID> <AGENTS_PID>

# 停止 Nginx
sudo systemctl stop nginx
# 或
sudo nginx -s stop
```

> 将 `<PID>` 替换为脚本结束时输出的实际 PID。

---

### 卸载 OpenAN

如果需要完全卸载 OpenAN 项目（删除项目目录、停止所有进程、清理 nginx 配置），
可以使用 `openan_uninstall.sh` 脚本。**环境工具（Python、Node.js、npm、nginx）会被保留**，
方便下次重新安装时跳过环境准备。

#### 使用方法

```bash
./openan_uninstall.sh           # 交互式确认
./openan_uninstall.sh --force   # 跳过确认（适用于自动化场景）
```

#### 卸载内容

脚本会执行以下操作：

| 步骤 | 操作 | 说明 |
|------|------|------|
| Step 1 | kill 进程 | 按端口查找并 kill OpenAN 进程（5000/5001/8080/8899-8907/26335/26336），智能识别避免误杀非 OpenAN 进程 |
| Step 2 | 停止 nginx | 三级回退：`systemctl stop` → `nginx -s stop` → `pkill nginx` |
| Step 3 | 删除 nginx 配置 | 删除 `/etc/nginx/conf.d/openan.conf`、`/etc/nginx/ssl/` 证书、本地 `openan-nginx.conf` |
| Step 4 | 删除项目目录 | 删除 `registry-center/` 和 `orchestration-center/` |

#### 保留内容

以下内容**不会被删除**，方便下次重装：

- Python 3.12+（系统安装或 `.python3.12/` 目录）
- Node.js 20.19+（系统安装或 `.node/` 目录）
- npm
- nginx 二进制和系统包
- openssl
- `configure_llm.sh`（部署仓库的一部分）

#### 交互式确认

运行 `./openan_uninstall.sh` 时，脚本会先扫描系统并列出将要执行的操作：

```
==========================================
 OpenAN Uninstallation Plan
==========================================

Processes to kill:
  kill PID 12345 (port 5000, registry-center)
  kill PID 12346 (port 5001, orchestration backend)
  ...

Nginx to stop/clean:
  stop nginx process (port 443)
  delete /etc/nginx/conf.d/openan.conf
  delete /etc/nginx/ssl/cert.pem, key.pem
  ...

Directories to delete:
  delete /path/to/registry-center/
  delete /path/to/orchestration-center/

Environment tools (Python, Node.js, npm, nginx) will be PRESERVED.

Proceed with uninstallation? [y/N]:
```

输入 `y` 确认执行，其他输入或回车则取消。使用 `--force` 可跳过此确认步骤。

> 详细设计决策见 [ADR-007](./docs/ADR-007-uninstall-script.md)。

---

## English

This script deploys the full OpenAN stack on a Linux server in one command, including registry-center, orchestration-center backend and frontend, agents example server, and an Nginx HTTPS reverse proxy. When deployed on a VPS, the script auto-detects the VPS IP and displays remote access URLs (`https://[ip-of-vps]`) in the summary output, accessible directly from a local browser.

---

### Table of Contents

- [Prerequisites](#prerequisites)
- [From Clone to Running](#from-clone-to-running)
- [Script Execution Flow](#script-execution-flow)
- [Interactive Prompts](#interactive-prompts)
- [Service Ports and URLs](#service-ports-and-urls)
- [Log File Locations](#log-file-locations)
- [Stopping Services](#stopping-services)
- [Uninstalling OpenAN](#uninstalling-openan)

---

### Prerequisites

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| OS | Linux (x86_64 / aarch64) | Supports Debian/Ubuntu, CentOS/RHEL/Rocky/Alma/openEuler |
| Python | 3.12+ | Auto-detected; script will attempt to install |
| Node.js | 20.19+ | Auto-detected; script will attempt to install |
| npm | Bundled with Node.js | — |
| curl | Any | Pre-installed |
| tar | Any | Pre-installed |
| Network | Required | Needs GitHub access to download component releases |

> If Python 3.12+, Node.js 20.19+, or nginx is not installed, the script will attempt to install them via the system package manager or prebuilt binaries. This may require **sudo privileges**.

---

### From Clone to Running

#### 1. Clone the repository

```bash
git clone https://github.com/XunliYang/openan-installation.git
cd openan-installation/binary/one-click
```

#### 2. Grant execute permission (if needed)

```bash
chmod +x openan_install.sh openan_uninstall.sh configure_llm.sh
```

#### 3. Run the script

```bash
./openan_install.sh
```

The script handles all downloads, configuration, and service startup automatically. There are a few interactive prompts during execution (see below); everything else is fully automated.

#### 4. Choose installation mode (optional)

The script uses `--reg` and `--orc` flags to select installation targets, consistent with `configure_llm.sh`'s flag design:

| Flag | Description |
|------|-------------|
| `--reg` | Install registry-center |
| `--orc` | Install orchestration-center |
| (neither specified) | Default: install both (equivalent to `--reg --orc`) |
| `--sample` | Start agents examples server (port 8080, off by default) |
| `-h` / `--help` | Show help and exit |

```bash
# Examples
./openan_install.sh                    # Install everything (default: --reg --orc)
./openan_install.sh --reg               # Install only registry-center
./openan_install.sh --orc               # Install only orchestration-center
./openan_install.sh --reg --orc --sample # Install everything and start sample agents
./openan_install.sh --help              # Show help
```

> In `--orc` mode (without `--reg`), the script prompts for the URL of the running registry-center (default `https://127.0.0.1:5000`). The URL is written as-is to `server.conf` and the `AGENT_REGISTRY_URL` environment variable — no `https→http` conversion.

**Step comparison by mode:**

| Step | `--reg --orc` | `--reg` | `--orc` |
|------|---------------|---------|---------|
| Python 3.12+ check | ✅ | ✅ | ✅ |
| Node.js / npm check & install | ✅ | ❌ Skipped | ✅ |
| Nginx check & install | ✅ | ❌ Skipped | ✅ |
| Download registry-center | ✅ | ✅ | ❌ Skipped |
| Download orchestration-center | ✅ | ❌ Skipped | ✅ |
| Configure registry-center | ✅ | ✅ | ❌ Skipped |
| Configure orchestration-center | ✅ | ❌ Skipped | ✅ |
| LLM configuration | ✅ Both | ✅ Registry only | ✅ Orchestration only |
| Prompt for registry URL | ❌ Auto-fix | ❌ Not needed | ✅ Interactive input |
| Nginx configuration | ✅ | ❌ Skipped | ✅ /registry/ → user URL |
| Start registry-center | ✅ | ✅ | ❌ |
| Start orchestration backend | ✅ | ❌ | ✅ |
| Start orchestration frontend | ✅ | ❌ | ✅ |
| Start agents server | ⬜ Optional | ❌ | ⬜ Optional |
| Start Nginx | ✅ | ❌ | ✅ |

> **About Assurance Agent**: Even without `--sample`, in `--reg --orc` and `--orc`
> modes, an "Assurance Agent" will appear in registry-center. This is an embedded
> agent (port 8902) registered by orchestration-center on startup, not the agents
> examples server. See [ADR-006](./docs/ADR-006-orchestration-built-in-agent-self-registration.md).

#### 5. Uninstall (optional)

To completely uninstall OpenAN (stop all processes, clean nginx configuration, remove project directories), use the uninstall script:

```bash
./openan_uninstall.sh           # Interactive confirmation
./openan_uninstall.sh --force   # Skip confirmation (for automation)
```

> The uninstall script **preserves environment tools** (Python, Node.js, npm, nginx) for faster reinstallation. See [Uninstalling OpenAN](#uninstalling-openan) for details.

---

### Script Execution Flow

#### Step 0: Environment Check

- **Python 3.12+**: Tries `python3.12` → `python3` in order. If neither exists, auto-detects the distribution and attempts:
  - Debian/Ubuntu: `apt-get install python3.12` (with deadsnakes PPA fallback)
  - CentOS/RHEL/Rocky/Alma/openEuler: `dnf/yum install python3.12` (with module enable fallback)
  - Final fallback: Download standalone Python from [python-build-standalone](https://github.com/indygreg/python-build-standalone)
- **Node.js 20.19+**: Tries existing `node` command. If not found or version insufficient, auto-detects the distribution and attempts:
  - Debian/Ubuntu: `apt-get install nodejs npm` (with NodeSource setup_20.x fallback)
  - CentOS/RHEL/Rocky/Alma/openEuler: `dnf/yum install nodejs npm` (with NodeSource setup_20.x fallback)
  - Final fallback: Download prebuilt binary from [nodejs.org](https://nodejs.org/dist/) (v20.19.0, includes npm, installed to local `.node` directory)
- **npm**: Verified alongside Node.js; if Node.js exists but npm is missing, attempts to install npm via package manager
- **curl / tar**: Checks availability

#### Step 0.5: Check Nginx

- If `nginx` or `openssl` is not installed, auto-installs via package manager (apt / dnf / yum)
- Requires sudo privileges

#### Step 1: Download Component Source

Downloads and extracts from GitHub Release (using `curl` + `tar`, no `git clone` dependency):

| Component | Download URL | Version |
|-----------|-------------|---------|
| registry-center | `https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |
| orchestration-center | `https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |

> If the directory already exists and is non-empty, the download is skipped.

#### Step 2: Configure registry-center

1. Create a Python virtual environment (venv)
2. Install Python dependencies (`pip install -r requirements.txt`)
3. Generate self-signed certificate (RSA, serverAuth, password `Dev@12345`)
4. Prepare SSL directory (`etc/ssl/`), copy certificates and set 0600 permissions
5. Fix `jwk_private_key_path` in `server.conf`
6. Run `python -m agent_registry.init` initialization (automated input with defaults, no user interaction needed)

#### Step 3: Configure orchestration-center

1. Create a Python virtual environment (venv)
2. Install backend Python dependencies
3. Enter `workflow-designer/` directory, run `npm install --force` to install frontend dependencies

#### Step 3.5: Configure LLM and Registry URL

**This step involves user interaction. See [Interactive Prompts](#interactive-prompts).**

- Option to skip LLM configuration
- Delegates to `configure_llm.sh` for interactive input, validation, and writing (in `--reg --orc` mode, configures registry and orchestration separately with a reuse option)
- Suggested values:
```
model name: glm-5.1
model url: https://open.bigmodel.cn/api/paas/v4/chat/completions
```
- Automatic LLM connectivity validation (per-project, sends a test request)
- Allows re-entry or skipping on validation failure
- Writes configuration to `llm_config.json` (mode-dependent: `--reg --orc` configures both, `--reg` writes registry-center only, `--orc` writes orchestration-center only)
- Regardless of whether skipped, the script always prints `configure_llm.sh` usage at the end of Step 3.5 for users to reconfigure LLM at any time (use `--reg`/`--orc` to target specific projects)
- `--reg --orc` mode: Fixes `agent_registry_url` in `server.conf` from `https://` to `http://` (avoids SSL version mismatch errors)
- `--orc` (without `--reg`) mode: Interactively prompts for the running registry-center URL, written as-is to `server.conf` and environment variable

#### Step 3.7: Configure Nginx HTTPS Reverse Proxy

1. Generate self-signed SSL certificate (`/etc/nginx/ssl/cert.pem`, `key.pem`, valid for 365 days)
2. Generate Nginx configuration and deploy to `/etc/nginx/conf.d/openan.conf`
3. Remove Debian/Ubuntu default site config (avoids port conflicts)
4. Test Nginx configuration validity

#### Step 4: Start All Services

Starts the following 4 services in order. Each service's port is automatically freed before startup:

| Service | Port | Start Method |
|---------|------|-------------|
| registry-center | 5000 | `python -m agent_registry.start` |
| orchestration-center backend | 5001 | `python -m orchestrate.start` |
| agents example server | 8080 | `python -m samples.start_agents_server` |
| Nginx HTTPS proxy | 443 | `systemctl start nginx` or `nginx` |

> The frontend is built as static assets via `npm run build` during installation and served directly by nginx, not as a separate process (see ADR-014).

---

### Interactive Prompts

During execution, the script may present the following interactive prompts. Except for LLM configuration, all are sudo password prompts or automated.

#### 1. sudo Password Prompt (may appear multiple times)

```
[sudo] password for <username>:
```

**When**: When the script needs to install Python, Node.js, npm, nginx, openssl, or modify `/etc/nginx/` directory.

**What to do**: Enter your sudo password. If running as root, this prompt will not appear.

---

#### 2. Skip LLM Configuration

```
Skip LLM configuration and configure manually? [y/N]:
```

**What**: Choose whether to skip the LLM configuration step. If skipped, the script will not ask for model name, API URL, or API Key, and will not modify `llm_config.json`. If not skipped, `configure_llm.sh` handles the interactive configuration: in `--reg --orc` mode, it configures registry first, then prompts whether to use the same config for orchestration.

**Default**: `N` (do not skip, enter interactive configuration)

**What to do**:
- Press Enter (or type `n`) to enter the interactive LLM configuration flow
- Type `y` to skip LLM configuration and use defaults

> Regardless of whether you skip, the script always prints `configure_llm.sh` usage at the end of Step 3.5 for you to reconfigure the LLM at any time:

```bash
# Reconfigure LLM (run from the script directory):
./configure_llm.sh --model glm-5.1 --url https://open.bigmodel.cn/api/paas/v4/chat/completions --api-key your-key

# Or pass API key via env var (avoids key in shell history):
LLM_API_KEY=your-key ./configure_llm.sh --model glm-5.1 --url https://open.bigmodel.cn/api/paas/v4/chat/completions

# Interactive mode (configure registry and orchestration separately, with reuse option):
./configure_llm.sh --reg --orc

# Update only a specific project (default: both):
./configure_llm.sh --reg --api-key your-key
./configure_llm.sh --orc --api-key your-key

# Show full help:
./configure_llm.sh --help
```

> **`--reg`/`--orc` flags**: The install script and `configure_llm.sh` use the same flags. If the specified project is not installed (`llm_config.json` missing), the script detects this before asking for config and skips it with a warning. If neither project is installed, the script exits with an error.
>
> If you skipped interactive configuration, LLM-related features will use defaults and may not work correctly. Please run `configure_llm.sh` to configure before starting services.

---

> **Split-asking flow in `--reg --orc` mode**: `configure_llm.sh` first asks for registry's LLM config (prompts 3-5 below), then after validation prompts "Use same LLM config for orchestration? [Y/n]". Choose Y to reuse all registry config values; choose n to enter orchestration config separately. When only `--reg` or `--orc` is specified, only one project is configured.

#### 3. LLM Model Name

```
Enter LLM model name [qwen3.6-flash]:
```

**What**: Specifies the LLM chat model name. The script uses this name to call the LLM API.

**Default**: `qwen3.6-flash` (Alibaba Cloud Qwen)

**Common choices**:

| Provider | Model Name |
|----------|-----------|
| Alibaba Cloud Qwen | `qwen3.6-flash` |
| Zhipu GLM | `glm-5.1` |

**What to do**: Press Enter for the default, or type your model name.

---

#### 4. LLM API URL

```
Enter LLM API URL [https://dashscope.aliyuncs.com/compatible-mode/v1]:
```

**What**: The LLM service API endpoint (OpenAI-compatible format). The script automatically appends `/chat/completions` if not already present.

**Default**: `https://dashscope.aliyuncs.com/compatible-mode/v1` (Alibaba Cloud Qwen)

**Common choices**:

| Provider | API URL |
|----------|---------|
| Alibaba Cloud Qwen | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| Zhipu GLM | `https://open.bigmodel.cn/api/paas/v4/chat/completions` |

**What to do**: Press Enter for the default, or type your API URL.

---

#### 5. LLM API Key

```
Enter your API key:
```

**What**: The API key for calling the LLM API, used for authentication.

**Default**: None (must be entered)

**What to do**: Enter the API key obtained from your LLM provider. If left empty, validation is skipped and you'll be prompted to edit `llm_config.json` manually.

> The key is masked in output (only first 4 and last 4 characters shown).

---

#### 6. Retry Prompt After LLM Validation Failure

When API Key / URL / model validation fails, the script re-prompts for all three:

```
[RETRY] Please re-enter LLM configuration.
        (Type 'skip' at any prompt to bypass validation)

Model [current model]:
API URL [current URL]:
API key [***]:
```

**What to do**:
- Correct the erroneous value and press Enter
- Type `skip` at any prompt to bypass validation (configuration may be incorrect; edit `llm_config.json` manually later)
- Press Enter to keep the current value unchanged

---

#### 7. Registry Center URL (--orc mode only, without --reg)

```
Enter registry center URL [https://127.0.0.1:5000]:
```

**What**: In `--orc` mode (without `--reg`), the orchestration-center needs to connect to a running registry-center. The script prompts you for its URL.

**Default**: `https://127.0.0.1:5000`

**What to do**:
- Press Enter for the default (for a locally running registry-center)
- Enter the actual URL of a remote registry-center (e.g., `https://10.0.0.5:5000`)

> The URL is written as-is to `agent_registry_url` in `server.conf` and the `AGENT_REGISTRY_URL` environment variable — no `https→http` conversion. Ensure the URL matches the registry-center's actual running mode (HTTP or HTTPS).
>
> The Nginx `/registry/` location block also proxies to this URL.

---

### Service Ports and URLs

After deployment, services are accessible at the following addresses:

| Service | Local Access (HTTP) | Remote Access (HTTPS, via Nginx proxy) |
|---------|---------------------|---------------------------------------|
| registry-center | http://127.0.0.1:5000 | https://[ip-of-vps]/registry/ |
| orchestration backend | http://127.0.0.1:5001 | https://[ip-of-vps]/api/orchestrate/ |
| Frontend (static files) | — | https://[ip-of-vps]/ |
| agents example server | http://127.0.0.1:8080 | — |
| Nginx HTTPS entry | — | https://[ip-of-vps] |

> **VPS remote access**: When the script runs on a VPS, the Summary output auto-detects the VPS network IP (via `hostname -I`) and displays remote access URLs in the form `https://[ip-of-vps]`. Replace `[ip-of-vps]` with your actual VPS IP address (e.g., `https://203.0.113.50`).
>
> All backend services bind to `127.0.0.1` and cannot be accessed externally. **Nginx is the sole remote entry point** (listening on `0.0.0.0:443`), proxying to services via path prefixes: `/` → frontend, `/api/orchestrate/` → backend, `/registry/` → registry-center. The agents example server has no nginx proxy and is not remotely accessible.
>
> Nginx uses a self-signed certificate. Browsers will show a security warning; choose "Proceed" to continue.

---

### Log File Locations

| Service | Log Path |
|---------|----------|
| registry-center | `registry-center/registry-center.log` |
| orchestration backend | `orchestration-center/backend.log` |
| orchestration frontend | `orchestration-center/frontend.log` |
| agents example server | `orchestration-center/agents-server.log` |

> Log files are relative to the script directory (i.e., `binary/one-click/`).

---

### Stopping Services

The script dynamically outputs the PIDs and stop command for services that were actually started (only lists started services). To stop:

```bash
# Stop Python and Node.js services
kill <REGISTRY_PID> <BACKEND_PID> <FRONTEND_PID> <AGENTS_PID>

# Stop Nginx
sudo systemctl stop nginx
# or
sudo nginx -s stop
```

> Replace `<PID>` with the actual PIDs output at the end of the script.

---

### Uninstalling OpenAN

To completely uninstall OpenAN projects (remove project directories, stop all processes,
and clean nginx configuration), use the `openan_uninstall.sh` script.
**Environment tools (Python, Node.js, npm, nginx) are preserved** for faster reinstallation.

#### Usage

```bash
./openan_uninstall.sh           # Interactive confirmation
./openan_uninstall.sh --force   # Skip confirmation (for automation)
```

#### What Gets Removed

| Step | Action | Description |
|------|--------|-------------|
| Step 1 | Kill processes | Find and kill OpenAN processes by port (5000/5001/8080/8899-8907/26335/26336), with smart identification to avoid killing non-OpenAN processes |
| Step 2 | Stop nginx | Three-level fallback: `systemctl stop` → `nginx -s stop` → `pkill nginx` |
| Step 3 | Remove nginx config | Delete `/etc/nginx/conf.d/openan.conf`, `/etc/nginx/ssl/` certificates, local `openan-nginx.conf` |
| Step 4 | Remove project dirs | Delete `registry-center/` and `orchestration-center/` |

#### What Gets Preserved

The following are **not deleted**, for faster reinstallation:

- Python 3.12+ (system-installed or `.python3.12/` directory)
- Node.js 20.19+ (system-installed or `.node/` directory)
- npm
- nginx binary and system package
- openssl
- `configure_llm.sh` (part of the deployment repo)

#### Interactive Confirmation

When running `./openan_uninstall.sh`, the script first scans the system and lists all
planned actions:

```
==========================================
 OpenAN Uninstallation Plan
==========================================

Processes to kill:
  kill PID 12345 (port 5000, registry-center)
  kill PID 12346 (port 5001, orchestration backend)
  ...

Nginx to stop/clean:
  stop nginx process (port 443)
  delete /etc/nginx/conf.d/openan.conf
  delete /etc/nginx/ssl/cert.pem, key.pem
  ...

Directories to delete:
  delete /path/to/registry-center/
  delete /path/to/orchestration-center/

Environment tools (Python, Node.js, npm, nginx) will be PRESERVED.

Proceed with uninstallation? [y/N]:
```

Type `y` to confirm, or any other input / Enter to cancel. Use `--force` to skip this confirmation.

> See [ADR-007](./docs/ADR-007-uninstall-script.md) for detailed design decisions.
