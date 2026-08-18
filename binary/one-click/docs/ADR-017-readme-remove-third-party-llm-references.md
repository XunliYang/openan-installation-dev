# ADR-017: README 移除第三方 LLM 引用

## 状态

已采纳 (Accepted) — 2026-08-18

## 背景

### 问题

`configure_llm.sh` 脚本已在前序工作中移除了所有第三方 LLM 厂商的默认值和示例
（`DEFAULT_LLM_MODEL=""`、`DEFAULT_LLM_URL=""`，见脚本第 23-25 行注释
"No third-party defaults — users must provide their own model and URL"）。
脚本的帮助文本也已使用 `<model-name>`、`<api-url>` 等通用占位符。

但 `README.md` 与脚本不同步，仍包含大量第三方厂商内容：

1. **"建议使用"块**（中文第 178-182 行）：直接写死 `model name: glm-5.1` 和
   `model url: https://open.bigmodel.cn/api/paas/v4/chat/completions`
2. **命令示例**（中文第 244-260 行）：使用 `glm-5.1` 和 GLM URL 真实值，
   而英文部分（第 716-721 行）已使用占位符
3. **交互提示默认值**：模型名提示 `[qwen3.6-flash]`、API URL 提示
   `[https://dashscope.aliyuncs.com/compatible-mode/v1]`——脚本中这些默认值已为空
4. **"常见选择"/"Common choices"表格**：列出阿里云通义千问和智谱 GLM 两个提供商的
   模型名和 API URL
5. **默认值描述**：`qwen3.6-flash（阿里云通义千问）`等，与脚本空默认值矛盾

### 根因

脚本清理第三方内容时未同步更新 README。README 中的提示文本、默认值、示例和表格
仍反映旧的厂商绑定状态，导致用户文档与实际脚本行为不一致。

## 决策

### 1. 移除"建议使用"块

中文第 178-182 行的"建议使用"块整块删除。脚本默认值已为空，不需要任何建议使用
特定厂商的内容。

### 2. 命令示例统一为占位符

中文部分的命令示例（第 244-260 行）从真实值改为占位符，与英文部分（第 716-721 行）
完全一致：

```bash
./configure_llm.sh --model <model-name> --url <url> --api-key <your-api-key>
LLM_API_KEY=<your-api-key> ./configure_llm.sh --model <model-name> --url <url>
```

### 3. 交互提示同步为无默认值

脚本中 `DEFAULT_LLM_MODEL=""` 和 `DEFAULT_LLM_URL=""` 为空字符串，交互提示不显示
默认值方括号。README 中的提示文本相应修改：

- `Enter LLM model name [qwen3.6-flash]:` → `Enter LLM model name:`
- `Enter LLM API URL [https://dashscope.aliyuncs.com/compatible-mode/v1]:` → `Enter LLM API URL:`

### 4. 默认值描述改为"无（必须输入）"

模型名和 API URL 的默认值描述从 `qwen3.6-flash（阿里云通义千问）` 等改为
`无（必须输入）` / `None (must be entered)`，与 API Key 的默认值描述风格一致。

### 5. "常见选择"表改为占位符表

保留表格结构，但内容替换为通用占位符：

| 提供商 | 模型名称 |
|--------|---------|
| 你的 LLM 服务商 | `<model-name>` |

英文部分同理。不再列出任何具体厂商名称或 URL。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 完全删除"常见选择"表 | 彻底无第三方内容 | 失去表格结构对用户的格式引导 | 用户选择保留占位符表 |
| 保留真实值但标注"示例" | 用户可直接复制使用 | 仍绑定第三方厂商，与脚本空默认值矛盾 | 违反去厂商化规范 |
| 改为 OpenAI 官方示例 | 使用最通用的 LLM 提供商 | 仍为第三方内容，OpenAI 在部分地区不可用 | 不符合"完全移除第三方"要求 |
| 保留"建议使用"块改为通用说明 | 保留引导性内容 | 脚本已无默认值，建议使用块无实际意义 | 用户选择整块删除 |

## 后果

- **正面**：README 与 `configure_llm.sh` 脚本行为完全同步，不再展示不存在的默认值
- **正面**：消除厂商绑定，文档适用于任何 OpenAI 兼容格式的 LLM 服务商
- **正面**：中英文部分风格统一，均使用占位符
- **负面**：新用户无法从 README 直接获取推荐的 LLM 配置，需自行查阅 LLM 服务商文档

## 关联

- `binary/one-click/configure_llm.sh` — 已完成第三方内容清除的脚本（第 23-25 行）
- `binary/one-click/README.md` — 本次修改的目标文件
- `binary/one-click/docs/glossary.md` — 新增术语：第三方 LLM 引用移除
- 移除第三方依赖引用规范（开发实践规范）— 脚本层面的去厂商化规范，本次为文档层面同步
