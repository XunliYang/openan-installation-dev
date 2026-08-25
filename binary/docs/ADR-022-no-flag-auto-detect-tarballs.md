# ADR-022: 无 flag 时自动检测可用离线包

## 状态

已采纳 (Accepted) — 2026-08-24

## 背景

### 问题

`binary/offline_pack/install.sh`（ADR-020 创建的合并安装器）当前的无 flag 行为是
**默认安装两个组件**（`INSTALL_REGISTRY=true`, `INSTALL_ORCHESTRATION=true`）。
Step 1 随后搜索两个 tarball，任一未找到即 `exit 1`。

这意味着用户只打包了 registry-center（`pack.sh --reg`）后运行 `./install.sh`（无 flag），
脚本会因找不到 orchestration-center tarball 而失败退出，即使 registry-center tarball
已存在且可正常安装。用户必须显式使用 `./install.sh --reg` 才能安装单个组件。

### 用户期望

离线部署场景中，用户可能只打包了一个组件（磁盘空间有限、只需 registry-center 做
agent 注册测试等）。无 flag 运行时，脚本应**自动检测已存在的 tarball**，有什么装什么：

1. 只找到 registry-center tarball → 仅安装 registry-center
2. 只找到 orchestration-center tarball → 仅安装 orchestration-center
3. 两个都找到 → 安装两个（等价于旧行为）
4. 两个都没找到 → 打印提示信息并退出

### 相关约束

- 显式指定 `--reg` / `--orc` 时，行为不变（找不到对应 tarball 仍 `exit 1`）
- `--sample` flag 依赖 `INSTALL_ORCHESTRATION`，需在自动检测完成后才能校验
- `configure_llm.sh` 的 `LLM_FLAGS` 由 `INSTALL_REGISTRY` / `INSTALL_ORCHESTRATION` 构建，
  自动检测设置这两个标志后，LLM 配置步骤自动适配
- `--orc` only 模式（含自动检测仅找到 orc 的情况）需提示用户输入远程 registry URL

## 决策

### 1. 引入 AUTO_DETECT 模式

新增 `AUTO_DETECT` 布尔变量。参数解析阶段，当 `--reg` 和 `--orc` 均未指定时，
设置 `AUTO_DETECT=true`，**不**预设 `INSTALL_REGISTRY` / `INSTALL_ORCHESTRATION`
（两者初始为 `false`，由 Step 1 的检测结果决定）。

```bash
REG_FLAG_SET=false
ORC_FLAG_SET=false
AUTO_DETECT=false
INSTALL_REGISTRY=false
INSTALL_ORCHESTRATION=false
```

```bash
if [ "${REG_FLAG_SET}" = "false" ] && [ "${ORC_FLAG_SET}" = "false" ]; then
    AUTO_DETECT=true
fi
```

显式指定 `--reg` / `--orc` 时，`AUTO_DETECT` 保持 `false`，走原有逻辑。

### 2. Step 1 自动检测逻辑

`AUTO_DETECT=true` 时，Step 1 同时搜索两个 tarball，按搜索结果设置安装标志：

```bash
if [ "${AUTO_DETECT}" = "true" ]; then
    REG_TARBALL=$(find_tarball "registry-center")
    ORC_TARBALL=$(find_tarball "orchestration-center")

    if [ -n "$REG_TARBALL" ]; then
        INSTALL_REGISTRY=true
        echo -e "  ${GREEN}✓${NC} Found: ${REG_TARBALL}"
    else
        echo -e "  ${YELLOW}⚠ registry-center tarball not found.${NC}"
    fi

    if [ -n "$ORC_TARBALL" ]; then
        INSTALL_ORCHESTRATION=true
        echo -e "  ${GREEN}✓${NC} Found: ${ORC_TARBALL}"
    else
        echo -e "  ${YELLOW}⚠ orchestration-center tarball not found.${NC}"
    fi

    if [ "${INSTALL_REGISTRY}" = "false" ] && [ "${INSTALL_ORCHESTRATION}" = "false" ]; then
        echo -e "${RED}Error: No offline packages found.${NC}"
        echo "       Searched: ${SCRIPT_DIR}/dist/{registry,orchestration}-center-*.tar.gz"
        echo "       Searched: ${SCRIPT_DIR}/{registry,orchestration}-center-*.tar.gz"
        echo "       Please run pack.sh first to build offline packages."
        exit 1
    fi
fi
```

`AUTO_DETECT=false` 时，Step 1 保持原有行为（按显式标志搜索，找不到 `exit 1`）。

### 3. 两个都没找到时的退出码

`exit 1`。与显式指定 flag 但找不到 tarball 的行为一致，便于脚本/CI 判断安装未成功。

### 4. 模式信息显示

`AUTO_DETECT=true` 时，在 Step 1 之前显示自动检测模式提示：

```
  Mode: auto-detect (no --reg/--orc specified)
  Will search for available packages and install what's found.
```

Step 1 检测完成后，打印解析出的安装目标：

```
  Auto-detect result:
    registry-center:       true
    orchestration-center:  false
```

`AUTO_DETECT=false` 时，保持原有显示（直接打印 `Install targets`）。

### 5. --sample 校验时机后移

原 `--sample` 依赖校验在参数解析后立即执行（line 128-131），依赖
`INSTALL_ORCHESTRATION`。自动检测模式下，`INSTALL_ORCHESTRATION` 在 Step 1
才确定，因此将 `--sample` 校验移到 Step 1 之后：

```bash
# --sample requires orchestration-center; warn and disable if not installing it.
if [ "${START_SAMPLE}" = "true" ] && [ "${INSTALL_ORCHESTRATION}" = "false" ]; then
    echo -e "${YELLOW}  ⚠ --sample has no effect without --orc (sample requires orchestration-center).${NC}"
    START_SAMPLE=false
fi
```

显式 flag 模式下此校验行为不变（`INSTALL_ORCHESTRATION` 在参数解析阶段已确定，
后移不影响结果）。

### 6. 后续步骤自动适配

Step 2-10 均通过 `INSTALL_REGISTRY` / `INSTALL_ORCHESTRATION` 条件控制，
无需修改：

| 步骤 | 依赖 | 自动适配说明 |
|------|------|-------------|
| Step 2 (Extract) | INSTALL_REGISTRY / INSTALL_ORCHESTRATION | 仅解压检测到的 tarball |
| Step 3 (Architecture) | INSTALL_REGISTRY / INSTALL_ORCHESTRATION | 仅验证检测到的组件 wheels |
| Step 4 (Prerequisites) | INSTALL_ORCHESTRATION | 仅找到 orc 时检查 Node.js/nginx |
| Step 5 (Registry setup) | INSTALL_REGISTRY | 仅找到 reg 时执行 |
| Step 6 (Orchestration setup) | INSTALL_ORCHESTRATION | 仅找到 orc 时执行 |
| Step 7 (LLM config) | LLM_FLAGS from INSTALL_* | 自动传递正确的 flag 给 configure_llm.sh |
| Step 8 (nginx) | INSTALL_ORCHESTRATION | 仅找到 orc 时配置 |
| Step 9 (Start services) | INSTALL_REGISTRY / INSTALL_ORCHESTRATION | 仅启动检测到的组件 |
| Step 10 (Summary) | PIDs | 仅显示已启动的服务 |

### 7. --orc only 模式的 registry URL 提示

自动检测仅找到 orc tarball 时，`INSTALL_REGISTRY=false` +
`INSTALL_ORCHESTRATION=true`，与显式 `--orc` 模式一致。Step 7 中的远程
registry URL 交互提示和 nginx `/registry/` proxy_pass 配置自动触发。

### 8. pack.sh 不变

`pack.sh` 在联网机器上运行，创建 tarball 而非查找 tarball，无自动检测场景。
保持 `--reg` / `--orc` 默认"两个都打包"的行为。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 无 flag 仍默认两个，找不到时跳过而非退出 | 不引入 AUTO_DETECT 变量 | 与显式 flag 行为不一致（显式找不到退出，无 flag 找不到跳过） | 语义不一致 |
| 无 flag 时交互式询问用户装哪个 | 用户可选择 | 离线场景应尽量减少交互，且用户已通过 tarball 表达了意图 | 过度交互 |
| 添加 --auto flag 显式触发自动检测 | 用户明确选择 | 增加一个 flag，与"无 flag = 自动检测"直觉不符 | 无 flag 本身已是明确的"不指定"信号 |
| 两个都没找到时 exit 0 | 不触发 set -e | 用户运行安装器却什么都没装，应视为失败 | exit 1 更符合安装失败语义 |
| 两个都没找到时逐个列出搜索路径 | 便于排查 | 搜索路径已在 Step 1 的 ⚠ 消息中体现 | 冗余 |
| pack.sh 也添加自动检测 | 对称 | pack.sh 不查找 tarball，无适用场景 | 不适用 |

## 后果

- **正面**：用户只打包一个组件时，无 flag 运行即可安装，无需记住 `--reg` / `--orc`
- **正面**：两个都打包时，无 flag 行为与旧版一致（安装两个），向后兼容
- **正面**：显式 flag 行为完全不变，向后兼容
- **正面**：后续步骤（Step 2-10）无需修改，通过条件标志自动适配
- **正面**：`--sample` 校验后移同时兼容自动检测和显式 flag 两种模式
- **负面**：`--sample` 校验从参数解析后移到 Step 1 后，位置略有调整（行为不变）
- **负面**：新增 `AUTO_DETECT` 变量和 Step 1 分支逻辑，增加约 30 行代码

## 关联

- `binary/offline_pack/install.sh` — 被修改的脚本
- [ADR-020](./ADR-020-offline-pack-script-merge.md) — install.sh 的创建和 flag 设计
- [ADR-021](./ADR-021-offline-install-sample-flag.md) — `--sample` flag 设计（校验时机受本 ADR 影响）
- glossary 新增"Tarball 自动检测"术语
