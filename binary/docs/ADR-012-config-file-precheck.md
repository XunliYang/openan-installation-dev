# ADR-012: LLM 配置文件预检

## 状态

已采纳 (Accepted) — 2026-08-14

## 背景

`configure_llm.sh`（ADR-005、ADR-010）在交互模式下按 registry → orchestration
顺序询问用户 LLM 配置（model/url/api_key），包括 API key 掩码输入和网络验证。
写入阶段（`write_config()` 函数内部）才检查 `llm_config.json` 是否存在。

### 问题

- **用户输入白费**：当目标项目未安装（`llm_config.json` 不存在）时，用户已经
  输入了完整的 LLM 配置（model、url、api_key）并等待了网络验证完成，最后才发现
  文件不存在、配置无法写入。两组配置全部白费
- **网络验证白费**：非交互模式下同样先执行 LLM API 网络验证（curl 请求），再在
  `write_config()` 中检测文件存在性。文件不存在时验证也无意义
- **用户体验差**：用户看到 `Updated: 0 file(s), Failed: 2 file(s)` 的汇总结果，
  但已经花费了大量时间输入和验证

### 根因

文件存在性检查被埋在 `write_config()` 函数内部（作为写入时的防御性检查），而非
在每个项目的交互询问之前执行。

## 决策

在脚本参数解析和 `SCRIPT_DIR` 解析之后、Python 解析和任何用户交互之前，新增
**Step 0 预检段**，对每个请求的目标项目检查 `llm_config.json` 是否存在。

### 预检逻辑

```
对每个 DO_REGISTRY / DO_ORCHESTRATION 为 true 的项目：
  1. 检查 ${REG_CONFIG} / ${ORC_CONFIG} 文件是否存在
  2. 不存在 → 打印 [WARN]，设置 DO_* = false（跳过该项目）
  3. 存在 → 保持 DO_* = true，继续后续流程

两个项目都被跳过 → 立即打印 [ERROR] 并 exit 1
```

### 影响范围

预检同时覆盖**交互模式和非交互模式**：

| 模式 | 预检前行为 | 预检后行为 |
|------|-----------|-----------|
| 交互模式 | 先问两组 LLM 配置 + 验证，写入时才发现文件不存在 | 先检测文件，只对存在的项目询问配置 |
| 非交互模式 | 先做 LLM 网络验证，写入时才发现文件不存在 | 先检测文件，只对存在的项目验证和写入 |

### 与现有流程的交互

- **交互模式复用选项**：如果 registry 的文件不存在（`DO_REGISTRY` 被设为 false），
  orchestration 的 "Use same LLM config?" 复用提示不会出现（条件为
  `DO_REGISTRY = true && REG_API_KEY 非空`），直接进入 orchestration 独立输入流程
- **非交互模式 targets 显示**：预检后 `DO_*` 标志已更新，非交互模式的
  `targets: registry + orchestration` 显示自动反映实际可用目标
- **Summary 汇总**：预检后 `DO_*` 为 false 的项目不会出现在 Summary 中

### write_config 保留防御性检查

`write_config()` 函数内部的文件存在性检查**保留不删除**，作为 defense-in-depth。
正常流程中该检查不会触发（Step 0 已过滤），但防止 `write_config` 被直接调用时
写入不存在的文件。

### 变量提取

预检段定义 `REG_CONFIG` 和 `ORC_CONFIG` 两个路径变量，替代写入阶段中四处内联的
`${SCRIPT_DIR}/registry-center/common/config/llm_config.json` 和
`${SCRIPT_DIR}/orchestration-center/common/config/llm_config.json`，消除路径重复。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 仅改交互模式，非交互保持现状 | 改动小 | 非交互模式仍浪费网络验证 | 用户确认非交互也需预检 |
| 文件不存在时报错退出（不跳过） | 更严格 | 一个项目未安装就阻止另一个项目配置 | 过度严格，与 ADR-005 的异常处理策略不一致 |
| 删除 write_config 内部的文件检查 | 代码更简洁 | 失去 defense-in-depth | 安全性降低 |
| 预检时检查目录而非文件 | 更早发现问题 | 目录存在但文件不存在的情况（部分安装）无法覆盖 | 粒度不够 |
| 两个文件都不存在时走完流程再汇总 | 保持现有行为 | 用户体验差（白费输入后才知道） | 用户确认要提前退出 |

## 后果

- **正面**：文件不存在的项目不再浪费用户输入时间和网络验证请求
- **正面**：两个项目都未安装时立即报错退出，用户无需等待即可知道问题
- **正面**：交互模式下复用选项的逻辑自然正确（registry 被跳过时不提示复用）
- **正面**：路径变量 `REG_CONFIG`/`ORC_CONFIG` 消除了写入阶段的路径重复
- **负面**：新增约 20 行预检代码，脚本总行数略增
- **负面**：`write_config` 内部的文件检查成为冗余（但保留作为防御性编程）

## 关联

- 承接 ADR-005（LLM 配置脚本独立化）和 ADR-010（分开询问与复用选项）
- ADR-005 的异常处理策略表中"指定项目目录不存在 → [WARN] 跳过"的行为不变，
  但执行时机从写入阶段提前到交互/验证之前
- glossary 新增"配置文件预检"术语
