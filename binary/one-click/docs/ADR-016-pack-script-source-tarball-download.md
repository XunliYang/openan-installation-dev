# ADR-016: Pack 脚本源码 tarball 下载

## 状态

已采纳 (Accepted) — 2026-08-17

## 背景

### 问题

`pack_reg.sh` 和 `pack_orc.sh` 两个离线打包脚本运行在 `openan-deployment` 部署专用仓库中，
但它们的源码复制逻辑假设本地已存在应用源码目录：

```bash
# pack_reg.sh — ROOT_DIR 解析为 binary/，期望应用源码在 binary/ 下
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 然后逐个 cp 本地目录
cp -r "${ROOT_DIR}/agent_registry" "${BUILD_DIR}/"
cp -r "${ROOT_DIR}/common" "${BUILD_DIR}/"
cp -r "${ROOT_DIR}/etc" "${BUILD_DIR}/"
cp -r "${ROOT_DIR}/bin" "${BUILD_DIR}/"
cp "${ROOT_DIR}/requirements.txt" "${BUILD_DIR}/"
```

实际运行时报错：

```
[4/7] Copying project source...
cp: cannot stat '/home/y00879326/openan-installation-dev/binary/agent_registry': No such file or directory
```

### 根因

1. **仓库分离**：`openan-deployment` 是部署专用仓库，仅包含部署脚本（`one-click/`、
   `orchestration-center/`、`registry-center/`），不包含应用源码（`agent_registry/`、
   `common/`、`etc/`、`bin/`、`requirements.txt`）。应用源码托管在独立的 GitHub 仓库中：
   - `project-openan/registry-center`
   - `project-openan/orchestration-center`

2. **ROOT_DIR 语义错误**：`ROOT_DIR = SCRIPT_DIR/..` 解析为部署仓库的 `binary/` 目录，
   而脚本期望它指向应用源码仓库根目录。这个设计前提在仓库分离后不再成立。

3. **两个脚本表现不同**：
   - `pack_reg.sh` 使用显式 `cp -r` 逐个目录复制 → **直接报错**（找不到 `agent_registry/`）
   - `pack_orc.sh` 使用 `rsync` 整体复制 `ROOT_DIR/` → **静默失败**（复制了部署脚本
     而非应用源码，产出的 bundle 内容错误）

4. **one-click 安装脚本已有正确模式**：`openan_install.sh` 的 Step 1 已从 GitHub release
   下载 tarball 并解压，使用 `curl -fsSL` + `tar --strip-components=1` 模式。pack 脚本
   应采用相同模式。

## 决策

### 1. Pack 脚本自行下载应用源码 tarball

两个 pack 脚本都改为从 GitHub release 下载应用源码 tarball，不再依赖本地预置的源码目录。

下载 URL 硬编码在脚本中（与 `openan_install.sh` 保持一致）：

```bash
# pack_reg.sh
SOURCE_URL="https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz"
SOURCE_VERSION="v1.0.0"

# pack_orc.sh
SOURCE_URL="https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz"
SOURCE_VERSION="v1.0.0"
```

### 2. 下载方式

采用与 `openan_install.sh` Step 1 完全一致的模式：

```bash
TMP_TAR=$(mktemp /tmp/{component}-source-XXXXXX.tar.gz)
curl -fsSL "${SOURCE_URL}" -o "${TMP_TAR}"
tar -xzf "${TMP_TAR}" -C "${DEST_DIR}" --strip-components=1
rm -f "${TMP_TAR}"
```

- `curl -fsSL`：静默失败（`-f`）、跟随重定向（`-L`）、显示进度（`-S`）
- `--strip-components=1`：去除 tarball 顶层目录名（如 `registry-center-1.0.0/`），
  使内容直接解压到目标目录

### 3. 版本硬编码

版本号 `v1.0.0` 硬编码在脚本中，不提供命令行参数控制。与 `openan_install.sh` 的
`REGISTRY_VERSION="v1.0.0"` / `ORCHESTRATION_VERSION="v1.0.0"` 保持一致。

`pack_reg.sh` 现有的 `--version` 参数仍用于包名标签（`PKG_NAME`），不用于源码下载。

### 4. 不缓存源码

每次运行 pack 脚本都重新下载源码，不检查本地是否已有缓存。与 `openan_install.sh`
的"已存在则跳过"逻辑不同——pack 脚本的 `BUILD_DIR` 在每次运行前都会被清理
（`rm -rf "$BUILD_DIR"`），不存在"残留源码"的情况。每次打包都从最新 release tag
获取源码，确保一致性。

### 5. 移除 ROOT_DIR 对源码的依赖

`ROOT_DIR` 变量不再用于查找应用源码。各脚本中 `ROOT_DIR` 的残留用途替换为：

| 原用途 | 替换为 |
|--------|--------|
| `cp -r "${ROOT_DIR}/agent_registry"` 等源码复制 | 下载 tarball + 解压到 `BUILD_DIR` |
| `pip download -r "${ROOT_DIR}/requirements.txt"` | `pip download -r "${BUILD_DIR}/requirements.txt"` |
| `VENV_PACKAGING_DIR="${ROOT_DIR}/.venv"` | 临时目录或 `BUILD_DIR` 子目录 |
| `OUTPUT_DIR="${ROOT_DIR}/dist"` (pack_reg.sh) | `OUTPUT_DIR="${SCRIPT_DIR}/dist"` |
| `TARBALL="${ROOT_DIR}/..."` (pack_orc.sh) | `TARBALL="${SCRIPT_DIR}/..."` |
| `cd "$ROOT_DIR"` (pack_orc.sh) | `cd "$SCRIPT_DIR"` |

### 6. 两个脚本的具体修改

#### pack_reg.sh

- Step 2 的 `VENV_PACKAGING_DIR` 从 `${ROOT_DIR}/.venv` 改为临时目录
  （`mktemp -d`），脚本结束时清理
- Step 4 从"Copy project source"（`cp -r`）改为"Download project source"
  （`curl` + `tar --strip-components=1`）
- Step 5 的 `pip download` 使用 `${BUILD_DIR}/requirements.txt`
- 默认 `OUTPUT_DIR` 从 `${ROOT_DIR}/dist` 改为 `${SCRIPT_DIR}/dist`

#### pack_orc.sh

- Step 2 从"Copying project source"（`rsync $ROOT_DIR/`）改为"Downloading project source"
  （`curl` + `tar --strip-components=1` 到临时目录，再 `rsync` 到 `BUNDLE_DIR`）
- `TARBALL` 输出路径从 `${ROOT_DIR}/` 改为 `${SCRIPT_DIR}/`
- `cd "$ROOT_DIR"` 改为 `cd "$SCRIPT_DIR"`
- `rsync` 的 exclude 列表保留（用于排除 tarball 中可能包含的 `.git`、`__pycache__` 等）

### 7. 前置依赖检查

两个 pack 脚本在 Step 0/1 中新增 `curl` 和 `tar` 的存在性检查（与
`openan_install.sh` Step 0 的 `command -v curl` / `command -v tar` 检查一致）。
缺失时报错退出。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| Git clone 源码仓库 | 可获取完整 Git 历史 | 需要安装 git、包体积增大、clone 慢 | 不需要 Git 历史，tarball 更轻量 |
| `--source-dir` 指定本地路径 | 支持离线打包机、开发时快速测试 | 增加参数复杂度、用户需手动管理源码 | 用户要求脚本自行下载，不需要本地源码 |
| `--source-url` 自定义下载 URL | 支持企业内部镜像/fork | 增加参数复杂度 | 用户要求与 one-click 一致，不自定义 URL |
| 缓存已下载源码（跳过重复下载） | 加快重复打包速度 | 可能打包到过期源码、增加缓存管理逻辑 | 用户要求每次都下载，确保一致性 |
| 仅修复 pack_reg.sh | 改动最小 | pack_orc.sh 静默失败（产出错误 bundle） | 用户要求同时修复两个脚本 |

## 后果

- **正面**：pack 脚本成为真正的自包含部署工具，无需用户预置应用源码
- **正面**：与 `openan_install.sh` 的源码下载模式统一，降低维护成本
- **正面**：消除 `ROOT_DIR` 对源码位置的隐式依赖，避免路径推断错误
- **正面**：pack_orc.sh 的静默失败问题被修复
- **负面**：每次打包都需要网络下载源码 tarball（约几 MB，影响较小）
- **负面**：打包机必须有网络访问 GitHub 的能力（`openan_install.sh` 已有此要求）

## 关联

- `binary/registry-center/pack_reg.sh` — 替换 `cp -r` 为 tarball 下载
- `binary/orchestration-center/pack_orc.sh` — 替换 `rsync $ROOT_DIR/` 为 tarball 下载
- `binary/one-click/openan_install.sh` — 已有的源码下载模式参考（Step 1）
- `binary/one-click/docs/glossary.md` — 新增术语：Source Tarball Download、ROOT_DIR 去源码化
- `binary/registry-center/README.md` — 更新打包流程说明
- `binary/orchestration-center/README.md` — 更新打包流程说明
