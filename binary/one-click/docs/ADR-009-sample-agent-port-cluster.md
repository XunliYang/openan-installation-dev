# ADR-009: Sample Agent 多端口架构与完整端口覆盖

## 状态

已采纳 (Accepted) — 2026-08-13

**本 ADR 修正 ADR-006 和 ADR-008 中的事实性错误。**

## 背景

### 新发现

用户揭示 `python -m samples.start_agents_server`（由 `--sample` flag 触发）启动了
**11 个示例 A2A Agent**，每个 agent 监听独立端口。加上管理端口 8080，
`samples.start_agents_server` 共占用 **12 个端口**，由**同一个 Python 进程**监听。

| 端口 | Agent 名称 | Seed JSON 文件 |
|------|-----------|---------------|
| 8899 | RAN Energy Saving Agent | `ran_energy_saving_agent.json` |
| 8900 | Energy Saving Intent Agent | |
| 8901 | Live Streaming Agent | |
| 8902 | Assurance Agent | `assurance_agent.json` |
| 8903 | RAN Agent | |
| 8904 | Transport Workbench Agent | |
| 8905 | SPN Fault Handling Agent City1 OMC | |
| 8906 | SPN Fault Handling Agent City2 OMC | |
| 8907 | Uncertainty Simulation Agent | |
| 26335 | SPN Domain Agent | |
| 26336 | Workbench Platform Agent | |

端口 26335 和 26336 并非随意选取，而是模拟真实运维平台的端口分配。

### 对 ADR-006 的修正

ADR-006 声称 `python -m orchestrate.start` 内部启动 Assurance Agent（端口 8902），
这是**错误的**。

**实际情况**：Assurance Agent（端口 8902）由 `samples.start_agents_server` 启动，
受 `--sample` flag 控制。`orchestrate.start` **不启动**任何 A2A Agent 端点。

ADR-006 观察到的"不带 `--sample` 时 Assurance Agent 仍出现"现象，实际原因是：
1. 上一次以 `--sample` 运行后，`samples.start_agents_server` 进程未被完全清理（残留）
2. 或 `registry-center/data/agentcard.json` 中持久化了上一次注册的 agent card 数据

### 对 ADR-008 的修正

ADR-008 的根因分析基于 ADR-006 的错误前提——认为 `orchestrate.start` 内部启动
Assurance Agent（8902）。实际根因是：

1. `samples.start_agents_server` 占用 12 个端口（8080 + 11 个 agent 端口）
2. 卸载脚本的 `OPENAN_PORTS` 仅覆盖 8080 和 8902，**遗漏 9 个端口**
3. 安装脚本的 `free_port()` 仅覆盖 8080 和 8902（ADR-008 新增），**同样遗漏 9 个端口**
4. 残留的 `samples.start_agents_server` 进程（单进程多端口）在卸载后存活
5. 下次安装时，残留进程占用端口导致 `samples.start_agents_server` 部分 agent 绑定失败
6. 依赖这些 agent 的 API 路由（如 `generate-from-intent`、`agent-cards`）返回 404

ADR-008 中的 `free_port 8902` 修复**方向正确但范围不足**——只覆盖了 11 个端口中的 1 个。

### 端口覆盖缺口

修复前的端口覆盖情况：

| 端口 | Agent | 安装脚本 `free_port()` | 卸载脚本 `OPENAN_PORTS` |
|------|-------|----------------------|----------------------|
| 8080 | 管理端口 | ✅ | ✅ |
| 8899 | RAN Energy Saving Agent | ❌ | ❌ |
| 8900 | Energy Saving Intent Agent | ❌ | ❌ |
| 8901 | Live Streaming Agent | ❌ | ❌ |
| 8902 | Assurance Agent | ✅ (ADR-008) | ✅ (ADR-008) |
| 8903 | RAN Agent | ❌ | ❌ |
| 8904 | Transport Workbench Agent | ❌ | ❌ |
| 8905 | SPN Fault Handling Agent City1 OMC | ❌ | ❌ |
| 8906 | SPN Fault Handling Agent City2 OMC | ❌ | ❌ |
| 8907 | Uncertainty Simulation Agent | ❌ | ❌ |
| 26335 | SPN Domain Agent | ❌ | ❌ |
| 26336 | Workbench Platform Agent | ❌ | ❌ |

**9 个端口完全未覆盖**，是 404 问题的真正根因。

## 决策

### 1. 安装脚本：Step 4 开始时清理全部 11 个 sample agent 端口

在 Step 4（启动所有服务）开始时，**无条件**清理全部 11 个 sample agent 端口
（不论是否使用 `--sample`）。这确保即使上一次以 `--sample` 运行后未正确卸载，
残留进程也不会影响本次启动。

```bash
# Clean all sample agent ports (defensive — residual samples.start_agents_server
# processes from a previous --sample run can cause 404 on orchestration API routes).
# See ADR-009 for the full 11-port sample agent architecture.
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    for sap in 8899 8900 8901 8902 8903 8904 8905 8906 8907 26335 26336; do
        free_port "${sap}"
    done
fi
```

同时**移除** ADR-008 在 `orchestrate.start` 启动前添加的 `free_port 8902`，
因为该位置的注释理由（"orchestrate.start 内部启动 Assurance Agent"）已被证伪。
8902 的清理由上述 11 端口循环覆盖。

### 2. 卸载脚本：`OPENAN_PORTS` 扩展到全部 11 个 sample agent 端口

```bash
OPENAN_PORTS=(
    "5000:registry-center"
    "5001:orchestration backend"
    "3003:orchestration frontend"
    "8080:agents examples server (management port)"
    "8899:sample agent — RAN Energy Saving Agent"
    "8900:sample agent — Energy Saving Intent Agent"
    "8901:sample agent — Live Streaming Agent"
    "8902:sample agent — Assurance Agent"
    "8903:sample agent — RAN Agent"
    "8904:sample agent — Transport Workbench Agent"
    "8905:sample agent — SPN Fault Handling Agent City1 OMC"
    "8906:sample agent — SPN Fault Handling Agent City2 OMC"
    "8907:sample agent — Uncertainty Simulation Agent"
    "26335:sample agent — SPN Domain Agent"
    "26336:sample agent — Workbench Platform Agent"
)
```

全局 pattern 匹配（`OPENAN_PATTERNS`）保持不变——`samples` pattern 已能匹配
`samples.start_agents_server` 的 cmdline。扩展端口范围确保该进程在**任意一个**
端口上被发现即可被 kill（单进程多端口，kill 一次即终止全部端口监听）。

### 3. 修正 ADR-006 状态

ADR-006 标记为 **"已修正 (Superseded by ADR-009)"**，保留原文不删除，
在文末添加修正说明。

### 4. 修正 ADR-008 根因分析

ADR-008 的修复措施（`free_port 8902`、全局 pattern 匹配、`ss -tlnp` 优先）
方向正确但范围不足。在文末添加修正说明，指向 ADR-009 的完整修复。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 仅扩展卸载脚本端口列表 | 最小改动 | 安装脚本仍有残留风险 | 单点修复不够健壮 |
| 用 `pkill -f samples` 替代端口扫描 | 简单，不依赖端口列表 | 可能误杀非 OpenAN 的 samples 进程 | 安全性不足 |
| 在 `samples.start_agents_server` 启动时写 PID 文件 | 精确追踪 | 需修改组件源码 | 超出部署脚本职责 |
| 仅在 `--sample` 模式下清理 11 端口 | 有针对性 | 非 `--sample` 模式下残留进程仍会干扰 | 无法防御残留进程 |
| 无条件清理 11 端口（采用） | 全面防御，覆盖所有场景 | 增加少量启动时间（11 次 free_port 调用） | 可接受 |

## 后果

- **正面**：卸载脚本能完整清理 `samples.start_agents_server` 的全部 12 个端口，
  不再有进程逃逸
- **正面**：安装脚本在 Step 4 开始时防御性清理 11 个端口，即使卸载不完整也能恢复
- **正面**：ADR-006 和 ADR-008 的事实性错误被纠正，文档与实际行为一致
- **正面**：404 问题的根因被完整定位和修复（9 个遗漏端口 + 残留进程）
- **负面**：卸载脚本的端口扫描从 5 个增加到 15 个，扫描时间略增（可忽略）
- **负面**：`free_port()` 会无条件 kill 11 个端口上的进程，即使用户在这些端口上
  运行了其他服务。但 8899-8907 和 26335/26336 是非标准端口，冲突概率极低

## 验证方法

```bash
# 1. 启动带 --sample 的完整部署
./openan_install.sh --all --sample

# 2. 确认全部 12 个端口监听
ss -lnt | grep -E ':8080|:8899|:8900|:8901|:8902|:8903|:8904|:8905|:8906|:8907|:26335|:26336'
# 应有 12 行输出

# 3. 运行卸载脚本
./openan_uninstall.sh --force

# 4. 验证全部端口已释放
ss -lnt | grep -E ':5000|:5001|:3003|:8080|:8899|:8900|:8901|:8902|:8903|:8904|:8905|:8906|:8907|:26335|:26336|:443'
# 应无输出

# 5. 重新运行安装脚本（不带 --sample）
./openan_install.sh

# 6. 验证 API 不再返回 404
curl -k https://localhost/api/orchestrate/rest/v1/orchestrate/agent-cards
# 应返回 JSON（非 404）
```

## 关联

- [ADR-006](./ADR-006-orchestration-built-in-agent-self-registration.md) —
  **已被本 ADR 修正**。ADR-006 错误地将 Assurance Agent 归因于
  `orchestrate.start` 内部启动，实际由 `samples.start_agents_server` 启动
- [ADR-007](./ADR-007-uninstall-script.md) — 卸载脚本设计，本 ADR 扩展其端口覆盖范围
- [ADR-008](./ADR-008-cross-port-process-escape.md) —
  **已被本 ADR 部分修正**。ADR-008 的修复方向正确但范围不足（仅覆盖 8902，
  遗漏 9 个端口）
- `openan_install.sh` Step 4（lines 1408-1530）— 启动所有服务，本 ADR 新增
  11 端口防御性清理
- `openan_uninstall.sh` `OPENAN_PORTS` 数组（lines 165-171）— 端口扫描列表，
  本 ADR 扩展至 15 个端口
- `free_port()` 函数（lines 718-735）— 端口清理逻辑，本 ADR 扩展其调用范围
