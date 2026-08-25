# ADR-002: 手动 LLM 命令的安装模式感知

## 状态

已采纳 (Accepted) — 2026-08-11

## 背景

`openan_install.sh` 的 Step 3.5 中存在两套 LLM 配置逻辑：

1. **交互式配置路径**（写入 `llm_config.json`）— 已根据安装模式动态构建文件列表：
   ```bash
   LLM_CONFIGS=()
   if [ "${INSTALL_REGISTRY}" = "true" ]; then
       LLM_CONFIGS+=("${REGISTRY_DIR}/common/config/llm_config.json")
   fi
   if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
       LLM_CONFIGS+=("${ORCHESTRATION_DIR}/common/config/llm_config.json")
   fi
   ```

2. **手动命令输出路径**（打印给用户后续使用的 bash 命令）— 使用静态 heredoc
   (`cat << 'MANUAL_LLM_CMD'`)，硬编码了两个文件路径：
   ```
   for f in \
     registry-center/common/config/llm_config.json \
     orchestration-center/common/config/llm_config.json
   do
   ```

### 问题

当用户运行 `--register` 模式（仅安装 registry-center）时，orchestration-center 未被下载，
但脚本输出的手动 LLM 配置命令仍然包含 `orchestration-center/common/config/llm_config.json`。

虽然命令中的 `[ -f "$f" ] || continue` 检查会跳过不存在的文件（不会报错），但输出本身
具有误导性：用户会以为需要为未安装的组件配置 LLM。

`--orchestrate` 模式存在对称问题：输出的命令包含 `registry-center/common/config/llm_config.json`，
但 registry-center 未被下载。

### 根因

heredoc 使用单引号分隔符 (`'MANUAL_LLM_CMD'`) 导致零变量展开，无法根据 `INSTALL_MODE`
动态调整内容。两套逻辑（交互式 vs 手动命令）的设计不一致是问题的根源。

## 决策

将静态 heredoc 拆分为三段，在中间动态生成文件列表：

### 结构

```
cat << 'MANUAL_LLM_HEADER'     ← 静态头部（MODEL/URL/API_KEY 设置）
    ...header content...
MANUAL_LLM_HEADER

echo "  for f in \\"             ← 动态文件列表（根据 INSTALL_MODE）

if [ "$INSTALL_REGISTRY" = "true" ] && [ "$INSTALL_ORCHESTRATION" = "true" ]; then
    echo "    registry-center/common/config/llm_config.json \\"
    echo "    orchestration-center/common/config/llm_config.json"
elif [ "$INSTALL_REGISTRY" = "true" ]; then
    echo "    registry-center/common/config/llm_config.json"
elif [ "$INSTALL_ORCHESTRATION" = "true" ]; then
    echo "    orchestration-center/common/config/llm_config.json"
fi

cat << 'MANUAL_LLM_FOOTER'     ← 静态尾部（do...done + Python 代码）
    ...footer content...
MANUAL_LLM_FOOTER
```

### 设计要点

1. **头部和尾部使用单引号 heredoc** — 保持 Python 代码中的 `$f`、`$MODEL` 等变量为
   字面量（不展开），与原始行为一致

2. **文件列表使用 `echo` 动态输出** — 根据 `INSTALL_REGISTRY` 和 `INSTALL_ORCHESTRATION`
   标志决定输出哪些文件路径

3. **项目标签动态化** — 注释 `# 2. Apply to ${MANUAL_PROJECT_LABEL}` 中的标签也根据
   安装模式变化（`both projects` / `registry-center` / `orchestration-center`）

4. **反斜杠续行处理** — 两个文件时第一个文件带 `\` 续行，最后一个不带；单个文件时
   不带续行符

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 保留静态 heredoc，靠 `[ -f ] \|\| continue` 兜底 | 零改动 | 输出仍包含不存在的文件路径，误导用户 | 用户体验差，正是被报告的 bug |
| 使用不带引号的 heredoc + 转义所有 `$` | 只需一个 heredoc | Python 代码中有大量 `$` 需转义，易出错 | 可维护性差 |
| 复用 `LLM_CONFIGS` 数组生成命令 | 消除两套逻辑 | `LLM_CONFIGS` 在跳过路径中未构建；数组存储绝对路径但命令需要相对路径 | 需额外重构，收益有限 |
| 构建完整命令字符串后 `printf` 输出 | 灵活 | 字符串拼接复杂，可读性差 | 过度工程化 |

## 后果

- **正面**：`--register` 模式输出的命令仅包含 `registry-center/common/config/llm_config.json`，
  与实际安装的组件一致
- **正面**：`--orchestrate` 模式输出的命令仅包含 `orchestration-center/common/config/llm_config.json`
- **正面**：`--all` 模式行为不变，仍输出两个文件路径
- **正面**：注释文字也根据模式变化（`both projects` / `registry-center` / `orchestration-center`）
- **负面**：heredoc 从 1 个变为 2 个 + 中间 echo 段，代码行数增加约 20 行

## 关联

- 修复了 Step 3.5 中交互式配置路径与手动命令输出路径的逻辑不一致
- README.md 中英文两处手动 LLM 命令示例已同步添加模式说明
- 交互式配置路径的 `LLM_CONFIGS` 数组逻辑（lines 1186-1192）保持不变
