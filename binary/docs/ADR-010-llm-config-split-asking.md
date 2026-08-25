# ADR-010: LLM 配置分开询问与复用选项

## 状态

已采纳 (Accepted) — 2026-08-14

## 背景

ADR-005 将 LLM 配置逻辑提取为独立脚本 `configure_llm.sh`，通过 `--project` flag
选择目标项目（`registry`/`orchestration`/`all`）。当 `--project all` 时，同一组
model/url/api_key 被写入两个项目的 `llm_config.json`。

### 问题

- **无法分别配置**：registry-center 和 orchestration-center 可能使用不同的 LLM
  提供商或不同的 API key，但现有脚本只能对两个项目写入相同的配置值
- **安装脚本交互不够灵活**：`openan_install.sh` Step 3.5 的交互式 LLM 配置只输入
  一组 model/url/api_key，写入两个项目时无法区分
- **独立运行缺乏交互模式**：用户安装后独立运行 `configure_llm.sh` 重新配置时，
  必须通过 flag 提供全部参数；缺少交互式输入能力，体验不如安装脚本

## 决策

### 1. 用 `--reg`/`--orc` 替代 `--project`

完全移除 `--project` flag，改用两个独立的项目选择 flag：

| Flag | 说明 |
|------|------|
| `--reg` | 配置 registry-center |
| `--orc` | 配置 orchestration-center |

- 同时指定 `--reg --orc` → 配置两者（替代原 `--project all`）
- 仅 `--reg` → 仅配置 registry-center（替代原 `--project registry`）
- 仅 `--orc` → 仅配置 orchestration-center（替代原 `--project orchestration`）
- 两者均未指定 → 默认配置两者

### 2. 交互模式自动触发

当 `--model`、`--url`、`--api-key` 三个参数中**任意一个**未提供（且 `LLM_API_KEY`
环境变量也未设置时），自动进入交互模式。已提供的参数作为交互提示中的默认值。

| 场景 | 模式 |
|------|------|
| `--reg --orc`（无 model/url/api-key） | 交互模式，分开询问 + 复用选项 |
| `--reg --orc --model xxx --url yyy --api-key zzz` | 非交互模式，同值写两个文件 |
| `--reg --orc --model xxx`（部分参数） | 交互模式，model 以 xxx 为默认值 |
| `--reg`（无参数） | 交互模式，仅问 registry 一组配置 |

### 3. 分开询问 + 复用选项（`--reg --orc` 交互模式）

交互流程按 **registry 优先**顺序：

```
1. [Registry] 输入 model / url / api_key（api_key 掩码输入）
2. [Registry] 验证 API 连通性（逐项目验证，失败可重试或 skip）
   └─ 验证失败且用户放弃 → 询问 "Continue to orchestration? [y/N]"
3. [Orchestration] 提示 "Use same LLM config for orchestration? [Y/n]"
   ├─ Y → 复用 registry 的 model + url + api_key 全部值，验证后写入
   └─ n → 重新输入 model / url / api_key，验证后写入
4. [写入] 分别写入两个项目的 llm_config.json
```

### 4. 复用范围

选择复用时，**model + url + api_key 三个字段全部**从 registry 复制到 orchestration。

### 5. API key 掩码输入

将 `openan_install.sh` 中的 `read_masked()` 函数复制到 `configure_llm.sh`。
交互模式下 API key 通过星号掩码输入，支持退格。

### 6. 逐项目验证

每个项目的配置独立验证（发送测试请求到 LLM API）。验证失败时允许重新输入或
输入 `skip` 跳过验证。registry 验证失败不影响 orchestration 的配置流程
（用户可选择继续）。

### 7. 安装脚本委托

`openan_install.sh` Step 3.5 **删除**现有的交互式 read/validate/retry 逻辑
（`validate_llm()`、`read_masked()`、交互式输入、重试循环、`export LLM_API_KEY`、
`PROJECT_FLAG` 映射），**替换为**直接调用 `configure_llm.sh --reg --orc`
（或根据安装模式映射为 `--reg` / `--orc`），由独立脚本全权处理交互、验证和写入。

**保留**：
- "Skip LLM configuration? [y/N]" 提示
- Step 3.5 结束时的 `configure_llm.sh` 使用说明（更新为 `--reg`/`--orc` 语法）

### 8. 安装脚本 flag 统一

`openan_install.sh` 的安装模式 flag 也从 `--all`/`--register`/`--orchestrate` 改为
`--reg`/`--orc`，与 `configure_llm.sh` 完全统一。安装脚本直接将安装 flag 传递给
`configure_llm.sh`，无需中间映射：

| 安装 flag | configure_llm.sh 调用 |
|-----------|----------------------|
| `--reg --orc`（默认） | `configure_llm.sh --reg --orc` |
| `--reg` | `configure_llm.sh --reg` |
| `--orc` | `configure_llm.sh --orc` |

旧 flag `--all`/`--register`/`--orchestrate` 被移除，使用时报错并提示新 flag。

### 9. 向后兼容性

`--project` flag 和 `--all`/`--register`/`--orchestrate` flag 均被完全移除
（**破坏性变更**）。等价映射：

| 旧命令 | 新命令 |
|--------|--------|
| `configure_llm.sh --project all ...` | `configure_llm.sh --reg --orc ...` |
| `configure_llm.sh --project registry ...` | `configure_llm.sh --reg ...` |
| `configure_llm.sh --project orchestration ...` | `configure_llm.sh --orc ...` |
| `openan_install.sh --all` | `openan_install.sh --reg --orc`（或无 flag） |
| `openan_install.sh --register` | `openan_install.sh --reg` |
| `openan_install.sh --orchestrate` | `openan_install.sh --orc` |

非交互模式（全部参数通过 flag 提供）的行为与原脚本一致：同一组值写入所有目标项目。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 保留 `--project`，新增 `--reg`/`--orc` 并存 | 零破坏性 | 两套 flag 语义重叠，用户困惑 | 增加复杂度 |
| `--reg`/`--orc` 仅作 `--project` 别名 | 不破坏现有用法 | 未能表达"分开配置"语义 | 未解决核心问题 |
| 交互逻辑放 `openan_install.sh`，`configure_llm.sh` 保持纯 flag | 安装脚本完全控制 | 独立运行 `configure_llm.sh` 时无交互能力 | 体验不一致 |
| 复用选项仅复制 model+url，api_key 单独输入 | 安全性更高 | 用户通常两个项目用同一 key，逐字段询问繁琐 | 体验差 |
| `--project all` 时默认复用，不询问 | 更简洁 | 用户无法选择分开配置 | 缺乏灵活性 |
| 两组 `--reg-model`/`--orc-model` flag 分别传参 | 全非交互，可脚本化 | flag 数量过多（6+个），使用复杂 | 可用性差 |
| 安装脚本保留自己的交互逻辑 | 改动最小 | 交互逻辑在两个脚本中重复，维护成本高 | 代码重复 |

## 后果

- **正面**：registry-center 和 orchestration-center 可配置不同的 LLM 参数
- **正面**：独立运行 `configure_llm.sh` 时支持交互式输入，体验与安装脚本一致
- **正面**：`--reg`/`--orc` 语义比 `--project` 更直观，无需记忆 `all`/`registry`/
  `orchestration` 三个值
- **正面**：`openan_install.sh` 的安装 flag 也统一为 `--reg`/`--orc`，两个脚本
  flag 语义完全一致，用户只需记忆一套 flag
- **正面**：`openan_install.sh` Step 3.5 删除约 190 行交互/验证代码
  （`validate_llm()`、`read_masked()`、交互输入、重试循环），替换为 1 行调用，
  可维护性显著提升
- **正面**：`validate_llm()` 和 `read_masked()` 不再在两个脚本中各存一份副本
  （ADR-005 的已知负面后果被消除）
- **负面**：`--project` flag 和 `--all`/`--register`/`--orchestrate` flag 被移除，
  已有文档和使用习惯需更新（README、glossary、ADR-005）
- **负面**：`configure_llm.sh` 代码量增加（新增交互模式约 150 行），但整体复杂度
  因消除了安装脚本中的重复逻辑而降低

## 关联

- 承接 ADR-005（LLM 配置脚本独立化），将其 `--project` flag 替换为 `--reg`/`--orc`
- 将 `openan_install.sh` 的 `--all`/`--register`/`--orchestrate` 也替换为 `--reg`/`--orc`，
  实现两个脚本的 flag 完全统一
- 消除 ADR-005 的负面后果：`validate_llm()` 和 `read_masked()` 不再有两份副本
- ADR-005 的 glossary 条目（`--project 标志`、`Flag 传入`、`API Key 环境变量回退`）
  需更新为 `--reg`/`--orc` 语法
- README.md 中英文两处的安装模式说明和 `configure_llm.sh` 使用说明需同步更新
