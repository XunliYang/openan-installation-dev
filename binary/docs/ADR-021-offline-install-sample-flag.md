# ADR-021: 离线 install.sh 集成 --sample Flag

## 状态

已采纳 (Accepted) — 2026-08-24

## 背景

### 问题

`binary/offline_pack/install.sh`（ADR-020 创建的合并安装器）目前缺少 sample agent
启动功能。用户在离线模式下部署 orchestration-center 后，无法启动示例 A2A Agent
进行功能验证。

`binary/one-click/openan_install.sh` 已有成熟的 `--sample` flag 设计：

1. `--sample` flag 显式触发 sample 启动
2. 未指定 `--sample` 时交互式询问用户 `[y/N]`
3. 启动 `python -m samples.start_agents_server`（端口 8080 + 11 个 agent 端口）
4. Summary 中显示 AGENTS_PID 和端口
5. Stop 命令包含 AGENTS_PID
6. 启动服务前防御性清理 11 个 sample agent 端口（ADR-009）

### 相关约束

- `samples.start_agents_server` 属于 orchestration-center 源码，已在 tarball 中
- `--sample` 依赖 orchestration-center，`--reg` only 模式下无意义
- 离线 `uninstall.sh` 已覆盖全部 11 个 sample agent 端口（ADR-020 适配时保留）
- 离线 `install.sh` 已清理 registry-center `data/` 目录（防止残留 agent card 导致 404）

## 决策

### 1. 集成 --sample flag（不创建独立脚本）

在 `install.sh` 中添加 `--sample` flag，不创建独立的 `start_sample.sh` 脚本。
与 `openan_install.sh` 的集成方式一致。

理由：离线部署场景下，sample 通常在首次安装时一并启动，独立脚本增加维护成本
而收益有限。后续手动启动可由用户参照 summary 中的信息自行执行。

### 2. 交互式提示

未指定 `--sample` 时，在 LLM 配置后、nginx 配置前交互式询问：

```
[INPUT] Sample agents server provides demo agents for testing (port 8080).
        Start sample agents server? [y/N]:
```

与 `openan_install.sh` 行为一致（lines 1183-1196）。

### 3. --sample 依赖 --orc

`--sample` 在 `--reg` only 模式下无意义（sample 属于 orchestration-center）。
检测到此情况时打印提示并禁用：

```bash
if [ "${START_SAMPLE}" = "true" ] && [ "${INSTALL_ORCHESTRATION}" = "false" ]; then
    echo -e "${YELLOW}  ⚠ --sample has no effect without --orc (sample requires orchestration-center).${NC}"
    START_SAMPLE=false
fi
```

### 4. 防御性端口清理

在 Step 9（启动服务）开始时，如果 `INSTALL_ORCHESTRATION=true`，无条件清理
全部 11 个 sample agent 端口（8899-8907, 26335, 26336），防止上次 `--sample`
运行的残留进程导致 404（ADR-009）：

```bash
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    for sap in 8899 8900 8901 8902 8903 8904 8905 8906 8907 26335 26336; do
        free_port "${sap}"
    done
fi
```

### 5. Sample 启动逻辑

在 orchestration-center backend 启动后、nginx 启动前，如果 `START_SAMPLE=true`：

```bash
if [ "${INSTALL_ORCHESTRATION}" = "true" ] && [ "${START_SAMPLE}" = "true" ]; then
    AGENTS_PORT=8080
    free_port "${AGENTS_PORT}"
    cd "$ORC_ROOT_DIR"
    nohup "${ORC_VENV_DIR}/bin/python" -m samples.start_agents_server \
        > "${ORC_ROOT_DIR}/log/agents-server.log" 2>&1 &
    AGENTS_PID=$!
    sleep 2
    if kill -0 "$AGENTS_PID" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Sample agents server started (PID: ${AGENTS_PID})"
    else
        echo -e "${RED}  Error: Sample agents server failed to start.${NC}"
    fi
    cd "$SCRIPT_DIR"
fi
```

### 6. Summary 显示

与 `openan_install.sh` 一致，仅显示 PID 和端口，不打印手动启动命令：

```
  agents examples server: http://127.0.0.1:8080  (PID: xxx)
```

Stop 命令包含 AGENTS_PID：

```
  To stop:
    kill <REGISTRY_PID> <OC_BACKEND_PID> <AGENTS_PID>
```

### 7. 日志路径

Sample agent 日志输出到 `${ORC_ROOT_DIR}/log/agents-server.log`，
与 `openan_install.sh` 的 `${ORCHESTRATION_DIR}/agents-server.log` 路径模式一致。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 独立 start_sample.sh 脚本 | 可安装后单独启动 | 增加维护成本，与 openan_install.sh 不一致 | 用户选择集成方案 |
| 仅 flag 触发（无交互提示） | 更简洁 | 用户可能不知道有此功能 | 与 openan_install.sh 不一致 |
| Summary 打印手动启动命令 | 方便后续启动 | 与 openan_install.sh 不一致 | 用户选择跟 openan_install.sh 一致 |
| 不加防御性端口清理 | 启动更快 | 残留进程导致 404（ADR-009） | 防御性清理是 ADR-009 的核心修复 |

## 后果

- **正面**：离线安装时可一键启动 sample agent，与 one-click 体验一致
- **正面**：交互式提示让用户知道 sample 功能存在
- **正面**：防御性端口清理防止残留进程导致 404
- **负面**：用户安装后想单独启动 sample 需自行执行命令（无独立脚本）
- **负面**：install.sh 新增约 40 行 sample 相关代码

## 关联

- `binary/offline_pack/install.sh` — 被修改的脚本
- `binary/one-click/openan_install.sh` — `--sample` flag 设计的参考
- [ADR-009](./ADR-009-sample-agent-port-cluster.md) — 11 端口防御性清理的根因
- [ADR-020](./ADR-020-offline-pack-script-merge.md) — install.sh 的创建
