# ADR-001: Node.js 自动安装策略

## 状态

已采纳 (Accepted) — 2026-08-11

## 背景

`openan_install.sh` 的 Step 0 环境检查中，Python 3.12+ 已具备完整的三级自动安装能力
（已有命令 → 包管理器 → 独立二进制下载），但 Node.js 20.19+ 和 npm 仍为硬性约束：
不存在或版本不足时直接 `exit 1`，要求用户手动安装。

这导致部署体验不一致：用户在全新 Linux 服务器上运行脚本时，Python 可以自动装好，
但 Node.js 必须手动处理，破坏了"一键部署"的体验。

### 约束

- 脚本要求 Node.js >= 20.19（用于 orchestration-center 前端 `npm install` 和 `npm run dev`）
- 需支持 x86_64 和 aarch64 架构
- 需支持 Debian/Ubuntu 和 CentOS/RHEL/Rocky/Alma/openEuler 发行版
- 大多数发行版默认仓库中的 Node.js 版本 < 18，无法满足 20.19+ 要求
- Node.js 20.x 已于 2026 年 4 月达到 EOL，NodeSource setup_20.x 可能不可用
- npm 在 apt 中可能是独立包（`nodejs` 包不含 `npm`），在预编译二进制中则随 Node.js 附带

## 决策

采用与 Python 3.12 完全一致的三级回退混合策略：

### 1. 尝试已有 Node.js（版本 >= 20.19）

```
command -v node → check_node_version() → 验证 npm → 通过
```

若已有 Node.js 版本 < 20.19，不替换系统 Node.js，而是继续尝试安装新版到本地目录。

### 2. 包管理器安装（默认仓库 → NodeSource 回退）

| 发行版 | 第一尝试 | 第二尝试（回退） |
|--------|---------|-----------------|
| Debian/Ubuntu | `apt-get install nodejs npm` | NodeSource `setup_20.x` 脚本 |
| CentOS/RHEL/Rocky/Alma | `dnf/yum install nodejs npm` | NodeSource `setup_20.x` 脚本 |

包管理器路径接受任何版本 >= 20.19 的 Node.js（不限于精确 20.19.0）。

### 3. 预编译二进制下载（最终回退）

```
URL: https://nodejs.org/dist/v20.19.0/node-v20.19.0-linux-{x64|arm64}.tar.xz
安装到: ${WORK_DIR}/.node
PATH 前置: export PATH="${WORK_DIR}/.node/bin:${PATH}"
```

- 精确版本 20.19.0（nodejs.org 永久保留所有发布版本，EOL 亦可下载）
- 包含 node 和 npm，无需额外安装
- 本地安装，不修改系统 Node.js，无需 sudo
- 与 Python standalone（`.python3.12`）模式完全一致

### npm 验证

每个安装路径完成后显式验证 npm 可用性：
- 已有 Node.js 路径：若 npm 缺失，尝试包管理器安装 npm
- 包管理器路径：安装时显式包含 npm 包
- 预编译路径：npm 随 Node.js 自带，但仍验证

### 函数结构

```
check_node_version()     — 检查 node 命令版本 >= 20.19
install_node_apt()       — Debian/Ubuntu 包管理器安装（含 NodeSource 回退）
install_node_yum()       — CentOS/RHEL 包管理器安装（含 NodeSource 回退）
install_node_prebuilt()  — nodejs.org 预编译二进制下载
resolve_node()           — 主入口：已有 → 包管理器 → 预编译
```

放置在 Python 函数之后、Step 0 之前，复用已有的 `run_sudo()` 辅助函数。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 仅预编译二进制 | 简单快速 | 放弃系统包管理器整合 | 与 Python 模式不一致 |
| 仅 NodeSource | 精确版本控制 | 不支持 openEuler 等非标准发行版 | 架构兼容性不足 |
| 仅系统包管理器 | 最简单 | 默认仓库版本 < 18，几乎必然失败 | 实际不可行 |
| 替换系统 Node.js | 全局生效 | 可能破坏其他依赖旧版的程序 | 风险过高 |
| nvm | 版本管理灵活 | 增加 shell 依赖，修改 profile | 过度复杂 |

## 后果

- **正面**：Step 0 体验与 Python 完全一致，真正实现一键部署
- **正面**：本地安装不污染系统环境，不影响其他程序
- **负面**：NodeSource setup_20.x 可能因 EOL 不可用（通过 `|| true` 优雅降级到预编译路径）
- **负面**：预编译二进制为 .tar.xz 格式，需 tar 支持 xz（现代 Linux 标配，极少数精简系统可能缺失）

## 关联

- 替代了 Step 0 中 Node.js/npm 的硬性检查逻辑（原 lines 398-421）
- 镜像了 `resolve_python()` 的设计模式（lines 304-385）
- 复用了 `run_sudo()` 辅助函数（line 128）
