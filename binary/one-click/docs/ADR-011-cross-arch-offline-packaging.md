# ADR-011: 跨架构离线打包与部署

## 状态

已采纳 (Accepted) — 2026-08-14

## 背景

### 问题

离线部署的两个 center（registry-center、orchestration-center）采用两阶段模式：
联网机器打包 → 离线机器安装。但**打包机和部署机的 CPU 架构可能不同**
（如 x86 机器打包、arm64 机器部署）。

改造前两个 center 的架构感知情况：

| 脚本 | 架构感知现状 | 问题 |
|------|-------------|------|
| `registry-center/package_offline.sh` | 有 `--arch=x86_64\|aarch64`，只下载单一架构 wheels | 打包机和部署机架构不同时，必须手动指定 `--arch`，否则下载的 wheels 无法在目标机器安装 |
| `registry-center/setup_offline.sh` | 无架构检测 | 不校验 wheels 是否匹配本机架构，pip install 失败时报错不清晰 |
| `orchestration-center/pack_offline_bundle.sh` | 完全无架构感知 | 在联网机器上构建 pre-built venv（含编译好的 `.so` 文件）和 pre-built node_modules（含原生模块），两者都是架构绑定的，跨架构部署必然失败 |
| `orchestration-center/install_offline.sh` | 无架构检测 | 不校验 venv/node_modules 的架构兼容性 |

### 根因

1. **Orchestration Center 的 pre-built venv 策略**：在联网机器上执行 `python -m venv` + `pip install`，
   生成包含架构绑定二进制扩展的 venv 目录，直接打包进 tarball。venv 中的 `.so` 文件
   只能在构建时的架构上运行。
2. **pre-built node_modules 策略**：在联网机器上执行 `npm install`，生成包含原生模块
   （`.node` 文件）的 node_modules 目录。原生模块同样架构绑定。
3. **Registry Center 虽采用 wheel-only 策略**（不在联网机器上构建 venv，只下载 wheels），
   但只下载单一架构，且 setup 脚本不检测架构。

## 决策

### 1. 统一为 Wheel-only 策略

两个 center 的 pack 脚本都改为 **wheel-only** 策略：
- 不在联网机器上构建 venv
- 只用 `pip download --platform` 下载 wheels（pip 的原生能力，不依赖宿主架构）
- 离线机器上从 wheels 本地构建 venv

venv 在离线机器上本地构建，架构自然匹配，不存在跨架构问题。

### 2. 前端改为 Cache-only 策略

Orchestration Center 的 pack 脚本不再保留 pre-built node_modules：
- 在联网机器上执行一次 `npm install`（仅为填充 `~/.npm/_cacache`）
- 复制 npm cache 到 bundle 中，**不保留 node_modules**
- 离线机器上从 npm cache 执行 `npm install --prefer-offline` 本地构建 node_modules

npm 包的 tarball 本身是跨架构的——大多数包含原生模块的 npm 包（如 `esbuild`、`sharp`）
在单个 tarball 内捆绑了所有平台的 prebuilt binary，离线机器安装时自动选择匹配平台的二进制。

### 3. Pack 脚本无条件下载双架构 Wheels

两个 pack 脚本都**无条件下载 x86_64 和 aarch64 两套 wheels**，混放在同一个 `wheels/` 目录中：

```
wheels/
├── package-1.0-cpython-3.12-manylinux_2_34_x86_64.whl
├── package-1.0-cpython-3.12-manylinux_2_34_aarch64.whl
├── package-1.0-cpython-3.12-any.whl
└── ...
```

pip 的 `--find-links` 会自动根据当前架构选择匹配的 wheel，同名不同架构的 wheel
可以共存（pip 根据文件名中的平台标签选择）。

### 4. 移除 Pack 脚本的 `--arch` Flag

- `registry-center/package_offline.sh`：移除 `--arch` flag，无条件下载双架构
- `orchestration-center/pack_offline_bundle.sh`：新增双架构下载（原本无 `--arch`）

打包机自身架构完全无关——它只是"下载器 + 文件复制器"。`pip download --platform`
在 x86 机器上能正常下载 arm64 的 wheels，不依赖宿主架构。

### 5. Setup/Install 脚本自动检测架构（无 Flag）

两个 setup/install 脚本**不提供 `--arch` flag**，纯自动检测：

```bash
# Detect and normalize architecture
RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
    x86_64|amd64)  NORMALIZED_ARCH="x86_64" ;;
    aarch64|arm64) NORMALIZED_ARCH="aarch64" ;;
    *)
        echo -e "${RED}Error: Unsupported architecture '$RAW_ARCH'. Supported: x86_64, aarch64.${NC}"
        exit 1
        ;;
esac
```

检测后验证 `wheels/` 目录中存在对应架构的 wheels，若无则报错退出：

```
Error: No wheels found for architecture 'aarch64' in wheels/ directory.
       This package may be incomplete. Re-run the packager to download both architectures.
```

### 6. 移除 Orchestration Center 的 `--skip-frontend`、`--rebuild-venv`、`--rebuild-frontend` Flags

- `--skip-frontend`：移除。pack 脚本总是下载 Python wheels + npm cache
- `--rebuild-venv`：移除。venv 总是在离线机器上从 wheels 构建，不存在"使用 pre-built venv"的路径
- `--rebuild-frontend`：移除。node_modules 总是在离线机器上从 npm cache 构建

保留 `--dir`、`--service`、`--no-service` flags。

### 7. 安装步骤顺序调整

架构检测放在最前面（Step 1），后续步骤依赖检测结果：

1. **检测系统架构**（新增）
2. **验证 wheels 存在对应架构**（新增）
3. 检查 Python
4. 创建 venv（从 wheels 本地构建）
5. 安装依赖
6. 前端构建（orchestration-center 专属）
7. 安装目录 / systemd / 配置指南

### 8. npm install 失败检查

pack 脚本中执行 `npm install` 填充 cache 时，若失败则报错退出（`set -euo pipefail` 已覆盖）。

### 9. Python 版本

保持 `--python-version=3.12`（默认值），两种架构均按此版本下载 wheels。
离线机器需 Python 3.12+，不再需要版本匹配检查（venv 本地构建，版本自然匹配）。

### 10. 报错信息语言

所有新增的报错信息使用英文，与现有脚本风格一致。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 保留 pre-built venv，额外下载另一架构 wheels | 改动小 | venv 体积大、需维护两套 venv、复杂度高 | 方案不简洁 |
| 产出两个独立包（x86 + arm64 各一个） | 包体积小 | 用户需选择正确包、与"一个包含双架构"的需求不符 | 用户体验差 |
| setup 脚本提供 `--arch` flag | 用户可覆盖检测 | 用户可能给错 flag 导致冲突 | 用户明确要求无 flag、纯自动检测 |
| `npm pack` 逐个打包 npm 依赖 | 精确 | 需手动解析依赖树、不递归处理子依赖 | 复杂且脆弱 |
| 保留 `--skip-frontend` | 减小包体积 | 增加复杂度、前端总是需要 | 用户明确要求移除 |

## 后果

- **正面**：一个离线包同时支持 x86_64 和 aarch64 两种架构，用户无需关心架构匹配
- **正面**：setup 脚本自动检测架构，无需手动指定 flag
- **正面**：venv 和 node_modules 在离线机器上本地构建，架构自然匹配
- **正面**：Python 版本匹配问题消除（venv 本地构建）
- **正面**：两个 center 的打包/部署策略统一（wheel-only + cache-only）
- **负面**：离线包体积增大（包含两套架构的 wheels），但 pure-Python wheels 只有一份
- **负面**：orchestration-center 离线安装时间增加（需本地构建 venv + node_modules，而非直接使用 pre-built）
- **负面**：orchestration-center 离线机器必须有 Node.js（之前 pre-built node_modules 时不强制）

## 关联

- `binary/registry-center/package_offline.sh` — 移除 `--arch`，改为双架构下载
- `binary/registry-center/setup_offline.sh` — 新增架构自动检测与校验
- `binary/orchestration-center/pack_offline_bundle.sh` — 改为 wheel-only + cache-only
- `binary/orchestration-center/install_offline.sh` — 新增架构检测，移除 rebuild flags
- `binary/registry-center/README.md` — 更新文档
- `binary/orchestration-center/README.md` — 更新文档
- `binary/one-click/docs/glossary.md` — 新增术语：Architecture Normalization、Dual-arch Wheels、Wheel-only Strategy
