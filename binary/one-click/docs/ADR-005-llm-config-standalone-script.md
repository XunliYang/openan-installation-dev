# ADR-005: LLM 配置脚本独立化

## 状态

已采纳 (Accepted) — 2026-08-12

## 背景

`openan_install.sh` 的 Step 3.5 中，LLM 配置修改逻辑以两种形式存在：

1. **交互式配置路径**（lines 1143-1258）— read 提示输入 model/url/api_key，
   `validate_llm()` 验证后通过内联 Python 代码写入 `llm_config.json`
2. **手动命令输出路径**（lines 1260-1320）— 打印一段 60 行的 bash 片段
   （含 `for f in ... do ... done` + 内联 Python），供用户复制粘贴重新配置 LLM

### 问题

手动命令输出路径存在以下痛点：

- **用户体验差**：用户需要复制 60 行 bash 代码，手动替换 `MODEL`、`URL`、`API_KEY`
  三个变量值，然后在正确的目录下运行。操作繁琐且容易出错
- **API key 安全风险**：手动命令中 `API_KEY` 作为 shell 变量直接传入 Python 的
  `sys.argv`，会出现在 shell history 和 `ps` 输出中
- **代码重复**：交互式路径的内联 Python 写入逻辑（lines 1225-1253）与手动命令
  输出路径的 Python 代码（lines 1305-1316）功能相同但写法不同，维护时需同步修改
- **不可复用**：安装完成后，用户若想修改 LLM 配置只能手动编辑 `llm_config.json`
  或重新运行安装脚本，缺少专用工具

## 决策

将 LLM 配置修改逻辑提取为独立脚本 `configure_llm.sh`，通过 flag 接收参数。

### 脚本设计

```
configure_llm.sh --model <name> --url <url> --api-key <key> \
                 --project registry|orchestration|all \
                 --validate|--no-validate
```

| Flag | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `--model` | 否 | `qwen3.6-flash` | LLM 模型名称 |
| `--url` | 否 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | LLM API URL |
| `--api-key` | 否 | — | API key；未指定时从 `LLM_API_KEY` 环境变量读取 |
| `--project` | 否 | `all` | 目标项目：`registry` / `orchestration` / `all` |
| `--validate` / `--no-validate` | 否 | `--validate` | 是否验证 API 连通性 |
| `-h` / `--help` | — | — | 显示帮助 |

### 功能范围

`configure_llm.sh` 包含：
1. **参数解析** — flag 解析 + 默认值填充
2. **API key 解析** — `--api-key` flag 优先，回退到 `LLM_API_KEY` 环境变量
3. **API 连通性验证** — 复用 `validate_llm()` 函数逻辑（从 `openan_install.sh` 复制）
4. **配置写入** — 通过 Python 修改 `llm_config.json` 中的 `chat.model`、`chat.url`、
   `chat.api_key` 字段

### 路径查找

基于脚本自身所在目录（`SCRIPT_DIR`）查找项目目录：
- `registry` → `${SCRIPT_DIR}/registry-center/common/config/llm_config.json`
- `orchestration` → `${SCRIPT_DIR}/orchestration-center/common/config/llm_config.json`

与 `openan_install.sh` 的 `SCRIPT_DIR` 逻辑一致，确保从任意目录运行均可正确找到文件。

### Python 依赖

按以下顺序解析 Python 命令：
1. 项目 venv 中的 Python（`${SCRIPT_DIR}/registry-center/venv/bin/python` 或
   `${SCRIPT_DIR}/orchestration-center/venv/bin/python`）
2. 系统的 `python3`

venv 优先策略确保使用安装时创建的 Python 环境（依赖已安装），回退到系统 python3
作为兜底（`configure_llm.sh` 仅使用标准库 `json`，不需要额外依赖）。

### 异常处理策略

| 异常情况 | 处理方式 |
|---------|---------|
| `--api-key` 和 `LLM_API_KEY` 均未设置 | 报错退出 |
| 指定项目目录不存在 | `[WARN]` 跳过，继续处理其他项目 |
| `llm_config.json` 不存在 | `[ERROR]` 跳过该文件 |
| JSON 格式损坏或缺少 `chat` 键 | `[ERROR]` 跳过该文件 |
| API 验证失败 | 报错退出（`--no-validate` 时跳过） |

### openan_install.sh 集成

**保留**（不变）：
- `validate_llm()` 函数（lines 1086-1141）
- 交互式 read 提示输入 model/url/api_key（lines 1143-1189）
- API key 掩码显示（lines 1192-1203）
- `export LLM_API_KEY`（line 1207）

**删除**（替换）：
- 内联 Python 写入代码（lines 1211-1255）→ 替换为调用 `configure_llm.sh --no-validate`
- 手动命令输出段（lines 1260-1320）→ 替换为 `configure_llm.sh` 使用说明

**调用方式**：
```bash
"${SCRIPT_DIR}/configure_llm.sh" \
    --model "${LLM_MODEL}" \
    --url "${LLM_URL}" \
    --project "${PROJECT_FLAG}" \
    --no-validate
```

- `--no-validate`：安装脚本已通过自己的 `validate_llm()` 完成验证，避免双重验证
- API key 通过已 `export` 的 `LLM_API_KEY` 环境变量传递，不出现在命令行参数中
- `PROJECT_FLAG` 根据安装模式映射：`all` → `all`，`register` → `registry`，
  `orchestrate` → `orchestration`

**使用说明输出**：
无论用户是否跳过 LLM 配置，Step 3.5 结束时都打印 `configure_llm.sh` 的使用说明，
替代原来的 60 行手动 bash 命令片段。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 保留手动命令输出段，仅新增独立脚本 | 零改动 openan_install.sh | 代码重复依旧，用户仍需复制 60 行命令 | 未解决核心问题 |
| 将交互式流程也移入 configure_llm.sh | 单一脚本包含全部 LLM 逻辑 | openan_install.sh 与安装流程的耦合变复杂 | 过度耦合 |
| configure_llm.sh 不含验证逻辑 | 更简单 | 用户独立运行时无法验证配置正确性 | 功能不完整 |
| 用 `--api-key` flag 传递 key（不设 env var 回退） | 简单 | key 出现在 ps 和 shell history 中 | 安全风险 |
| 不设默认 model/url 值 | 更严格 | 与 openan_install.sh 的默认值不一致 | 体验不一致 |
| JSON 异常时报错退出 | 防止部分写入 | 一个项目的问题影响另一个项目 | 过度严格 |

## 后果

- **正面**：用户可通过 `./configure_llm.sh --model glm-5.1 --url xxx --api-key xxx`
  一行命令修改 LLM 配置，无需复制粘贴 60 行代码
- **正面**：API key 支持环境变量传入，避免出现在 shell history 和 `ps` 输出中
- **正面**：openan_install.sh 删除约 65 行内联代码（Python 写入 + 手动命令输出），
  替换为 1 行调用 + ~10 行使用说明，可维护性提升
- **正面**：`validate_llm()` 函数在两个脚本中各有一份（未提取为公共库），
  权衡为可接受的重复 — 两个脚本的运行上下文不同（安装脚本有 venv 激活，
  独立脚本需要自行解析 Python），共享代码会增加不必要的复杂度
- **负面**：`validate_llm()` 逻辑存在两份副本，修改时需同步更新两处
- **负面**：新增一个脚本文件，部署包多一个组件

## 关联

- 替代了 ADR-002 中的手动 LLM 命令输出段（heredoc 拆分方案被完全移除）
- 复用了 ADR-002 中的 `--project` 安装模式映射逻辑
- `validate_llm()` 函数从 openan_install.sh（lines 1086-1141）复制到 configure_llm.sh
- README.md 中英文两处的"手动 LLM 命令"示例更新为 `configure_llm.sh` 用法
