# ADR-013: 交互模式空配置跳过退出

## 状态

已采纳 (Accepted) — 2026-08-14

## 背景

`configure_llm.sh`（ADR-005、ADR-010、ADR-012）交互模式下，当用户对所有提示
直接按回车（model、url、api_key 全部为空），脚本会：

1. 跳过 API 验证（因 api_key 为空，line 437-439）
2. 跳过配置写入（因 api_key 为空，write_config 不被调用，line 611-613）
3. 在 Summary 段打印 `Updated: 0 file(s)`
4. 在最终检查（line 722-725）因 `SUCCESS_COUNT == 0` 打印 `[ERROR]` 并 `exit 1`

### 问题

- **安装流程中断**：`openan_install.sh` 使用 `set -euo pipefail`，子进程
  `configure_llm.sh` 的 `exit 1` 会导致整个安装脚本中止。用户仅在 LLM 配置
  步骤中未输入任何值，却导致整个安装失败
- **语义错误**：用户在交互模式下未提供配置是一种"跳过"行为（类似于
  `openan_install.sh` 中的 "Skip LLM configuration? [y/N]" 路径），不应被视为
  错误。真正的错误是写入失败（`FAIL_COUNT > 0`），而非用户选择不配置
- **消息级别不当**：`[ERROR] No files were updated` 暗示脚本执行出错，但实际
  情况是用户主动选择不提供配置

## 决策

将交互模式下"未写入任何文件且无写入失败"的场景从**错误**重新分类为**跳过**。

### 判定逻辑

```
最终检查（SUCCESS_COUNT == 0 时）：
  if FAIL_COUNT > 0:
    [ERROR] No files were updated. Please check the warnings above.
    exit 1  (保持不变)
  else:
    [SKIP] LLM configuration skipped. No files were updated.
           Run configure_llm.sh later to configure.
    exit 0  (新增)
```

### Summary 标题

当 `SUCCESS_COUNT == 0` 且 `FAIL_COUNT == 0` 时，Summary 标题从
`LLM configuration complete` 改为 `LLM configuration skipped`。其他情况
（有文件写入或有写入失败）保持 `LLM configuration complete`。

### 非交互模式

不变。非交互模式下缺少 api_key 时已在 line 635-638 报错退出（defense-in-depth，
实际不会触发，因为任意参数缺失会自动进入交互模式）。

### 中间警告

不变。交互模式中的 `[WARN] No API key provided. Skipping validation.` 和
`[WARN] No API key set for registry.` 保持 `[WARN]` 级别，提供有用的诊断信息
（告知用户哪个项目缺少 key），不降级为 `[INFO]`。

### openan_install.sh 调用方

不变。`configure_llm.sh` 改为 `exit 0` 后，`set -e` 不再触发中止，
`openan_install.sh` 的调用行 `bash configure_llm.sh ${LLM_FLAGS}`（line 1104）
无需修改。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| `SUCCESS_COUNT==0` 即 exit 0（不管 FAIL_COUNT） | 更简单 | 掩盖真正的写入失败 | 无法区分跳过和错误 |
| 在 openan_install.sh 调用行加 `\|\| true` | 不改 configure_llm.sh | 掩盖所有错误，包括真正的写入失败 | 过度宽松 |
| 交互输入阶段检测全空立即退出 | 更早退出 | 需在每个项目输入后加检查，代码复杂 | 过度工程 |
| 改为在 openan_install.sh 中用 if 检查 exit code | 调用方更灵活 | 需修改两个文件 | 不必要，修复 configure_llm.sh 即可 |
| Summary 标题始终为 `complete` | 一致性 | 0 文件更新时 `complete` 具有误导性 | 语义不准确 |
| 中间警告也降级为 `[INFO]` | 与最终消息级别一致 | 丢失诊断价值（用户不知道哪个项目缺 key） | 用户确认保持 `[WARN]` |

## 后果

- **正面**：交互模式下未提供配置不再中断安装流程，与 `openan_install.sh` 中
 已有的 "Skip LLM configuration? [y/N]" 跳过路径语义一致
- **正面**：`exit 0` 与"跳过"语义一致，`exit 1` 保留给真正的写入失败
- **正面**：Summary 标题准确反映实际状态（`skipped` vs `complete`）
- **正面**：`[SKIP]` 消息级别明确告知用户这不是错误，并提示稍后可通过
  `configure_llm.sh` 配置
- **负面**：无（行为变更范围小，且两层跳过机制——安装脚本预跳过 + 配置脚本
  内跳过——均已覆盖）

## 关联

- 承接 ADR-005（LLM 配置脚本独立化）和 ADR-010（分开询问与复用选项）
- 与 ADR-012（配置文件预检）的"两个项目都未安装时 exit 1"不冲突——那是真正的
  错误（项目未安装），本 ADR 处理的是项目已安装但用户选择不配置的场景
- glossary 新增"空配置跳过"术语，更新 `configure_llm.sh` 条目引用
- `openan_install.sh` 的 "Skip LLM configuration? [y/N]" 路径（line 1091-1099）
  与本 ADR 的跳过路径形成两层跳过机制：用户可在进入 configure_llm.sh 之前跳过，
  也可在 configure_llm.sh 交互中跳过
