# ADR-020: offline_pack 脚本合并

## 状态

已采纳 (Accepted) — 2026-08-19

## 背景

### 问题

离线部署脚本按组件分散在两个独立目录中：

- `binary/registry-center/`：`install_reg.sh`、`pack_reg.sh`
- `binary/orchestration-center/`：`install_orc.sh`、`pack_orc.sh`

每个组件有独立的安装和打包脚本，用户需分别运行两次命令完成双组件部署。
脚本间存在大量重复代码（`free_port`、`find_nginx_binary`、`run_sudo`、wheel 下载逻辑、
tarball 搜索逻辑等），且缺少 LLM 配置集成和卸载脚本。

同时，`binary/offline_pack/` 目录已存在但为空，原计划作为统一的离线打包入口。

### 相关差异

两组件脚本之间存在以下不一致：

| 差异点 | registry-center | orchestration-center |
|--------|-----------------|----------------------|
| wheel 存放路径 | `wheels/` | `vendor/wheels/` |
| 额外依赖 | 无 | Node.js 20.19+ / npm / nginx |
| 前端构建 | 无 | npm cache + `npm run build` |
| nginx 配置 | 无 | HTTPS 反向代理 (port 443) |
| 证书生成 | Python CertificateGenerator | openssl (nginx SSL) |
| init 流程 | `agent_registry.init` | 无（直接修改 server.conf） |
| Apache 许可头 | 有 | 无 |
| 步骤编号格式 | `[1/8]`...`[8/8]` | `Step 1:`...`Step 10:` |

## 决策

### 1. 脚本合并

在 `binary/offline_pack/` 中创建四个脚本：

| 文件 | 合并来源 | 功能 |
|------|---------|------|
| `install.sh` | `install_orc.sh` + `install_reg.sh` | 统一离线安装器 |
| `pack.sh` | `pack_orc.sh` + `pack_reg.sh` | 统一离线打包器 |
| `configure_llm.sh` | one-click `configure_llm.sh` 适配 | LLM 配置（Glob 目录定位） |
| `uninstall.sh` | one-click `openan_uninstall.sh` 适配 | 全量卸载（Glob 目录定位） |

原有脚本保留不删除，offline_pack 中的合并版作为新选择。

### 2. Flag 设计

`install.sh` 和 `pack.sh` 采用与 `openan_install.sh` 一致的 `--reg`/`--orc` flag 设计：

| 参数 | INSTALL_REGISTRY | INSTALL_ORCHESTRATION | 说明 |
|------|-------------------|----------------------|------|
| 无 flag（默认） | true | true | 安装/打包两个组件 |
| `--reg` | true | false | 仅 registry-center |
| `--orc` | false | true | 仅 orchestration-center |
| `--reg --orc` | true | true | 两个组件（与无 flag 等效） |

`--all` 被拒绝并报错提示使用无 flag 或 `--reg --orc`，与 `openan_install.sh` 一致。

### 3. 输出风格

采用现有离线脚本的 ANSI 颜色码风格（`echo -e "${GREEN}✓${NC}"`），不使用 one-click
的纯文本标签风格。理由：offline_pack 是离线脚本的延续，保持视觉一致性。

### 4. wheel 目录统一

`pack.sh` 对两个组件统一使用 `vendor/wheels/` 作为 wheel 存放路径（原 `pack_reg.sh`
使用 `wheels/`）。`install.sh` 统一从 `vendor/wheels/` 读取。消除两组件间的路径差异。

### 5. Glob 目录定位

`configure_llm.sh` 和 `uninstall.sh` 使用 Glob 模式定位解压后的项目目录：

```bash
# configure_llm.sh
REG_CONFIG=$(ls "${SCRIPT_DIR}"/registry-center-*/common/config/llm_config.json 2>/dev/null | head -1)
ORC_CONFIG=$(ls "${SCRIPT_DIR}"/orchestration-center-*/common/config/llm_config.json 2>/dev/null | head -1)

# uninstall.sh
REGISTRY_DIR=$(ls -d "${WORK_DIR}"/registry-center-* 2>/dev/null | head -1)
ORCHESTRATION_DIR=$(ls -d "${WORK_DIR}"/orchestration-center-* 2>/dev/null | head -1)
```

适配离线模式下 tarball 解压后目录名含版本号（如 `registry-center-1.0.0-linux/`）的特点。
`configure_llm.sh` 的 venv Python 解析也改用 Glob：

```bash
PYTHON_CMD=$(ls "${SCRIPT_DIR}"/registry-center-*/venv/bin/python 2>/dev/null | head -1)
```

### 6. LLM 配置集成

`install.sh` 在服务启动前集成 LLM 配置步骤（与 `openan_install.sh` Step 3.5 一致），
提供跳过选项。用户跳过时仍打印 `configure_llm.sh` 使用说明。install flag 直接传递给
`configure_llm.sh`：

```bash
LLM_FLAGS=""
[ "${INSTALL_REGISTRY}" = "true" ] && LLM_FLAGS="--reg"
[ "${INSTALL_ORCHESTRATION}" = "true" ] && LLM_FLAGS="${LLM_FLAGS} --orc"
bash "${SCRIPT_DIR}/configure_llm.sh" ${LLM_FLAGS}
```

### 7. nginx 配置

`install.sh` 在安装 orchestration-center 时配置 nginx HTTPS 反向代理（与 `install_orc.sh`
一致）。`uninstall.sh` 清理 nginx 配置、SSL 证书和静态资源。

### 8. --orc only 模式的 registry URL

`install.sh` 在 `--orc` only 模式下提示用户输入远程 registry URL（与 `openan_install.sh`
一致），并修改 `server.conf` 和 nginx `/registry/` proxy_pass。

### 9. uninstall 全量卸载

`uninstall.sh` 不支持 `--reg`/`--orc` 选择性卸载，一次性清理所有内容（进程、nginx、
项目目录、静态资源），与 one-click `openan_uninstall.sh` 一致。支持 `--force` 跳过确认。

### 10. 离线模式前置假设

`install.sh` 假设 Python 3.12+、Node.js 20.19+、npm、nginx 已预装（离线机器无网络，
无法自动安装）。与现有 `install_orc.sh`/`install_reg.sh` 一致，不做自动安装。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 接受 `--all` flag | 用户明确要求 | 与 openan_install.sh 不一致，双语义（--all 和 no-flag） | 一致性优先 |
| one-click 纯文本输出风格 | 与 openan_install.sh 一致 | 与现有离线脚本视觉风格不连贯 | 离线脚本延续性优先 |
| 符号链接固定路径 | configure_llm.sh 无需改动 | 引入额外符号链接管理，解压后需额外步骤 | Glob 更简洁 |
| 路径文件传递 | 精确路径 | 引入隐式状态文件，脚本间耦合 | Glob 无状态更健壮 |
| uninstall 支持 --reg/--orc | 选择性卸载 | 复杂度高，卸载场景通常全量清理 | 无需求驱动 |
| 删除旧脚本 | 避免维护两套代码 | 破坏向后兼容 | 用户要求保留 |

## 后果

- **正面**：用户一条命令完成双组件离线安装/打包，无需分别运行两个脚本
- **正面**：LLM 配置集成到安装流程中，与 one-click 体验一致
- **正面**：wheel 目录统一，消除两组件间的路径差异
- **正面**：configure_llm.sh 和 uninstall.sh 使离线部署体验完整（安装→配置→卸载）
- **正面**：Glob 目录定位适应版本化目录名，无需硬编码版本号
- **负面**：pack_reg.sh 的 wheel 路径从 `wheels/` 改为 `vendor/wheels/`，旧版 tarball
  中的 wheel 路径仍为 `wheels/`，install.sh 需兼容两种路径（先查 `vendor/wheels/`，
  兜底查 `wheels/`）
- **负面**：保留旧脚本导致代码重复，未来修改需同步两处

## 关联

- `binary/offline_pack/install.sh` — 合并安装器
- `binary/offline_pack/pack.sh` — 合并打包器
- `binary/offline_pack/configure_llm.sh` — Glob 适配的 LLM 配置脚本
- `binary/offline_pack/uninstall.sh` — Glob 适配的卸载脚本
- `binary/one-click/openan_install.sh` — flag 设计和 LLM 集成的参考
- `binary/orchestration-center/install_orc.sh` — 离线安装逻辑来源
- `binary/registry-center/install_reg.sh` — 离线安装逻辑来源
- `binary/orchestration-center/pack_orc.sh` — 离线打包逻辑来源
- `binary/registry-center/pack_reg.sh` — 离线打包逻辑来源
- `binary/one-click/docs/ADR-019-unify-bundle-naming-and-top-level-detection.md` — tarball 顶层目录检测
- `binary/one-click/docs/ADR-011-cross-arch-offline-packaging.md` — 双架构 wheel 策略
