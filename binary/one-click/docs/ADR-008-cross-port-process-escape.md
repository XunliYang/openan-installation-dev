# ADR-008: 跨端口进程逃逸修复与 8902 端口覆盖

## 状态

已采纳 (Accepted) — 2026-08-13

## 背景

用户运行 `openan_uninstall.sh` 卸载后，再次运行 `openan_install.sh` 时，orchestration
后端 API 返回 404：

```
GET  /api/orchestrate/rest/v1/orchestrate/agent-cards        → 404
POST /api/orchestrate/rest/v1/orchestrate/generate-from-intent → 404
```

卸载日志中出现以下警告：

```
[WARN] Port 5000 (PID: 1462962) — cmdline does not match OpenAN pattern 'agent_registry'.
       cmdline: python -m samples.start_agents_server
       Skipping to avoid killing non-OpenAN process.
[WARN] Port 8902 (PID: 1462962) — cmdline does not match OpenAN pattern 'orchestrate'.
       cmdline: python -m samples.start_agents_server
       Skipping to avoid killing non-OpenAN process.
```

### 调查过程

通过六轮追问锁定根因：

1. **fuser 行为分析** — `fuser 5000/tcp` 返回所有与端口关联的进程，包括 listener
   和 client。`start_agents_server` 作为 client 连接到 registry-center (port 5000)
   注册 agent card，被 `fuser` 误报为端口占用者。

2. **端口 8080 空置** — 卸载日志显示 `Port 8080 — no process listening`。说明
   `start_agents_server` 的 8080 listener 已退出，但主进程 (PID 1462962) 仍存活。

3. **端口 8902 归属** — 卸载脚本按 `OPENAN_PORTS` 顺序处理：5000 → 5001 → 3003 →
   8080 → 8902。处理 port 5001 时 `orchestrate.start` 被杀死，其内部 8902 listener
   随之死亡。但处理 port 8902 时仍检测到 PID 1462962，说明该进程自身也是 8902
   的 listener（`start_agents_server` 模块也启动了 Assurance Agent 端点）。

4. **pattern 匹配失效** — `start_agents_server` 的 cmdline 为
   `python -m samples.start_agents_server`，不包含 `orchestrate`（port 8902 的
   匹配模式），也不包含 `agent_registry`（port 5000 的匹配模式）。进程在所有端口
   上均被跳过，永远不会被杀死。

5. **free_port 覆盖缺口** — `openan_install.sh` 的 `free_port()` 仅覆盖 5000、5001、
   3003、8080、443 五个端口，**不包含 8902**（见 ADR-006）。残留的 8902 进程
   不会被安装脚本主动清理。

6. **404 而非 502** — 502 表示 Nginx 无法连接后端（port 5001 down）。404 表示
   后端在运行但路由不存在。新 `orchestrate.start` 在 5001 上成功启动，但内部
   Assurance Agent 绑定 8902 失败（端口被旧进程占用），导致依赖 Assurance Agent
   的路由（`agent-cards`、`generate-from-intent`）未注册，返回 404。

### 根因

**跨端口进程逃逸**：`start_agents_server` 是一个多端口进程（同时关联 5000 client
连接、8080 listener、8902 listener）。卸载脚本的"每端口单一 pattern"设计无法
处理这类进程——在所有端口上 pattern 均不匹配，进程逃逸。

残留进程占用 port 8902，安装脚本的 `free_port()` 不覆盖 8902，新
`orchestrate.start` 的 Assurance Agent 绑定失败，导致 404。

### 根因链

```
1. start_agents_server 同时在 8902 上启动 listener（与 orchestrate.start 重叠）
2. 卸载脚本 kill orchestrate.start → 其内部 8902 listener 死亡
   但 start_agents_server 的 8902 listener 存活（pattern 不匹配 → 跳过）
3. 卸载脚本 kill agent_registry.start → port 5000 listener 死亡
   start_agents_server 到 5000 的 client 连接断开
4. 安装脚本 free_port(5000) → fuser 无返回 → 无法发现残留进程
5. 安装脚本不调用 free_port(8902) → 8902 仍被占用
6. orchestrate.start 在 5001 启动成功 → Assurance Agent 绑定 8902 失败
7. 依赖 Assurance Agent 的路由未注册 → 404
```

## 决策

### 1. 卸载脚本：全局 OpenAN pattern 匹配

将"每端口单一 pattern"改为"检查 cmdline 是否匹配**任意**已知 OpenAN pattern"。

**修改前**（per-port single pattern）：
```bash
OPENAN_PORTS=(
    "5000:agent_registry:registry-center"
    "8902:orchestrate:Assurance Agent (internal)"
)
# 对 port 8902 只检查 "orchestrate"，不匹配 "samples" → 跳过
```

**修改后**（global pattern set）：
```bash
# 全局 OpenAN 进程 pattern 集合
OPENAN_PATTERNS="agent_registry|orchestrate|vite|samples"

# 每个端口仍保留 label 用于日志显示
OPENAN_PORTS=(
    "5000:registry-center"
    "5001:orchestration backend"
    "3003:orchestration frontend"
    "8080:agents examples server"
    "8902:Assurance Agent (internal)"
)

# 对每个端口上的每个 PID，检查 cmdline 是否匹配任意 OpenAN pattern
# 匹配任意一个即 kill，全部不匹配才 skip
```

**理由**：OpenAN 进程可能出现在非预期端口上（如 `start_agents_server` 同时在
8080 和 8902 上启动 listener）。全局 pattern 匹配确保任何 OpenAN 进程无论出现在
哪个端口上都能被识别和清理。同时仍保留端口扫描范围（仅扫描已知端口）以避免
误杀端口范围外的用户进程。

### 2. 安装脚本：free_port 覆盖 8902

在启动 `orchestrate.start` 之前增加 `free_port 8902` 调用。

```bash
# Start orchestration-center backend (port 5001)
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    free_port 5001
    free_port 8902  # ← 新增：清理残留的 Assurance Agent 端口
    ...
    nohup python -m orchestrate.start > ... &
```

**理由**：`orchestrate.start` 内部启动 Assurance Agent 绑定 8902（见 ADR-006）。
如果 8902 被残留进程占用，Assurance Agent 绑定失败但主 API（5001）仍正常启动，
导致 404 而非 502——难以诊断。`free_port 8902` 作为防御性清理，确保端口可用。

### 3. fuser 输出过滤（仅保留 listener）

`fuser` 返回所有与端口关联的进程（包括 client 连接）。为减少误报，在卸载脚本的
`find_pids_on_port` 中优先使用 `ss -tlnp`（仅返回 listener）而非 `fuser`。

**修改后的 find_pids_on_port 优先级**：
1. `ss -tlnp`（仅 listener，最精确）
2. `lsof -i :PORT -sTCP:LISTEN`（仅 listener）
3. `fuser`（listener + client，最宽泛，作为兜底）

**理由**：`fuser` 的 client 误报导致不必要的 WARN 日志和 pattern 检查开销。使用
`ss -tlnp` 只返回真正监听端口的进程，减少噪音。但保留 `fuser` 作为兜底，因为
某些最小化安装的系统可能没有 `ss` 或 `lsof`。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 仅修卸载脚本 pattern | 最小改动 | 安装脚本仍不覆盖 8902，非卸载场景（如手动 kill 后重启）仍会出问题 | 单点修复不够健壮 |
| 仅在安装脚本加 free_port 8902 | 最小改动 | 卸载脚本仍会逃逸进程，残留进程可能占用其他资源 | 未解决根因 |
| 按进程名 kill（pkill -f samples） | 简单 | 可能误杀非 OpenAN 的 samples 进程 | 安全性不足 |
| 使用 PID 文件追踪 | 精确 | 需修改安装脚本写 PID 文件，改动范围大 | 改动范围过大 |
| 进程组 kill（kill -- -PGID） | 一次杀死父进程和所有子进程 | 需设置进程组，nohup 启动的进程不在独立进程组中 | 需修改启动方式 |

## 后果

- **正面**：卸载脚本能正确清理 `start_agents_server` 等多端口 OpenAN 进程，
  不再出现跨端口逃逸
- **正面**：安装脚本覆盖 8902 端口，即使卸载脚本未完全清理，重启时也能
  防御性释放端口
- **正面**：`ss -tlnp` 优先策略减少 fuser client 误报，日志更清晰
- **正面**：404 问题根因消除，Assurance Agent 能正确绑定 8902
- **负面**：全局 pattern 匹配的粒度更粗——如果用户的非 OpenAN 进程 cmdline
  恰好包含 `samples`、`orchestrate` 等关键词，可能被误杀。但这种情况极少
  （这些是 OpenAN 特有的模块名）
- **负面**：`free_port 8902` 会无条件 kill 8902 上的进程，即使用户在该端口
  上运行了其他服务。但 8902 是非标准端口，冲突概率低

## 验证方法

```bash
# 1. 启动带 --sample 的完整部署
./openan_install.sh --all --sample

# 2. 确认 8902 上有两个 listener（orchestrate.start + start_agents_server）
ss -lnt | grep 8902

# 3. 运行卸载脚本
./openan_uninstall.sh --force

# 4. 验证所有端口已释放（包括 8902）
ss -lnt | grep -E ':5000|:5001|:3003|:8080|:8902|:443'
# 应无输出

# 5. 重新运行安装脚本（不带 --sample）
./openan_install.sh

# 6. 验证 API 不再返回 404
curl -k https://localhost/api/orchestrate/rest/v1/orchestrate/agent-cards
# 应返回 JSON（非 404）
```

## 关联

- [ADR-006](./ADR-006-orchestration-built-in-agent-self-registration.md) —
  Assurance Agent 内嵌启动机制，端口 8902 的来源
- [ADR-007](./ADR-007-uninstall-script.md) — 卸载脚本设计，智能进程识别
  （本 ADR 修正其 pattern 匹配缺陷）
- `openan_install.sh` `free_port()` 函数（lines 718-735）— 端口清理逻辑，
  本 ADR 扩展其覆盖范围至 8902
- `openan_uninstall.sh` `OPENAN_PORTS` 数组（lines 148-154）— 端口-pattern
  映射，本 ADR 改为全局 pattern 匹配
