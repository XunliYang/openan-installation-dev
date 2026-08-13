# ADR-006: orchestration-center 内嵌 Agent 自注册机制

## 状态

已采纳 (Accepted) — 2026-08-12

## 背景

用户运行 `./openan_install.sh`（默认 `--all` 模式，未指定 `--sample`）后，在前端
registry center 页面中发现一个已注册的 agent："Assurance Agent"。这引发了困惑：

- `--sample` 未指定，agents examples server（port 8080）被脚本明确跳过
- `openan_install.sh` 中没有任何向 registry-center 注册 agent 的操作（无 POST 请求）
- Summary 输出中报告的端口仅包含 5000/5001/3003/443，无 8902

### 调查过程

通过五轮验证锁定根因：

1. **API 查询** — `curl http://127.0.0.1:5000/rest/v1/registry-center/agent-cards`
   返回 Assurance Agent 的完整 card，端口指向 `http://127.0.0.1:8902`

2. **端口验证** — `ss -lnt | grep 8902` 确认 8902 端口正在监听

3. **持久化确认** — `registry-center/data/agentcard.json` 文件存在，内容与 API 返回
   一致，时间戳 16:53（registry-center 启动后 23 分钟）

4. **日志分析** — `orchestration-center/backend.log` 中仅有 GET 请求（从 registry-center
   拉取 agent cards），未见 POST。说明注册发生在日志记录的时间窗口之前

5. **进程归属** — `lsof -i :8902` 确认监听进程为 Python（PID 308385），
   与 `orchestrate.start` 属同一用户

6. **源码定位** — `grep -rn "8902" orchestration-center/` 找到静态种子文件：
   `orchestration-center/samples/agentcard/assurance_agent.json`，其中硬编码了
   `"url": "http://127.0.0.1:8902"`

### 根因

`python -m orchestrate.start` 不只启动 port 5001 的编排后端 API，还在其启动流程内部：

1. 启动一个 A2A Agent 服务端点（port 8902）—— Assurance Agent 的实际服务进程
2. 读取种子 agent card 文件（`samples/agentcard/assurance_agent.json`）
3. 通过环境变量 `AGENT_REGISTRY_URL` 向 registry-center POST 注册 agent card

registry-center 接收注册后，将 card 持久化到 `data/agentcard.json`（file 存储模式）。

此行为是 orchestration-center **组件源码层面的内部行为**，`openan_install.sh`
仅负责启动 `orchestrate.start` 进程并设置 `AGENT_REGISTRY_URL` 环境变量，不感知
也不控制内嵌 agent 的启动和注册。

### 关键概念区分

`openan_install.sh` 中存在两个容易混淆的 "agent" 概念：

| 概念 | 控制 | 端口 | 启动模块 | 默认 |
|------|------|------|---------|------|
| agents examples server | `--sample` flag | 8080 | `samples.start_agents_server` | 关闭 |
| Assurance Agent（内嵌） | 无（始终启动） | 8902 | `orchestrate.start` 内部 | 开启 |

`--sample` 控制的是独立的示例服务（port 8080），提供额外的 demo agent 端点。
Assurance Agent 是 orchestration-center 核心功能的一部分，由 `orchestrate.start`
内部启动，不受 `--sample` 控制。

## 决策

本 ADR 为**记录性决策**（documentary ADR），记录已有行为而非改变行为。
具体决策如下：

### 1. 文档化内嵌 Agent 行为

在 glossary 中新增以下条目，明确区分 `--sample` 与内嵌 Agent：
- Agent Card
- Assurance Agent
- 端口 8902 (Port 8902)
- Agent Card 自注册 (Agent Card Self-Registration)
- 种子 Agent Card (Seed Agent Card)
- `--sample` 与内嵌 Agent 的区别

### 2. 不在部署脚本层面拦截

`openan_install.sh` **不做任何修改**来阻止或控制内嵌 agent 的自注册行为。原因：
- 这是 orchestration-center 的核心功能，拦截会破坏组件正常工作
- agent 注册是 A2A 架构的预期行为——orchestration-center 既是编排者，也是 agent 提供者
- `AGENT_REGISTRY_URL` 环境变量已在 Step 4 中正确设置（lines 1424-1428），
  确保自注册指向正确的 registry-center 地址

### 3. README 文档修正

README 中的模式对比表存在文档错误：`--all` 模式下列 "启动 agents 示例服务" 标记为 ✅，
但实际代码中 `--all` 模式默认不启动 agents examples server（`START_SAMPLE=false`，
需显式 `--sample`）。修正为明确标注默认关闭。

同时新增说明：即使不加 `--sample`，`--all` 和 `--orchestrate` 模式下 registry-center
中仍会出现 Assurance Agent（由 orchestration-center 内嵌启动并自注册）。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 在脚本中加 `--no-agent` 参数控制内嵌 agent | 用户可选择不启动 agent | 需修改 orchestration-center 源码支持该 flag | 超出部署脚本职责范围 |
| 在 Summary 中输出 8902 端口信息 | 透明性提升 | 需检测内嵌进程端口，增加脚本复杂度 | 检测不可靠（进程可能延迟启动） |
| 删除 seed agent card 文件 | 彻底消除困惑 | 破坏 orchestration-center 功能 | 不可接受 |
| 不记录此行为 | 无改动 | 用户持续困惑 | 违背文档化原则 |

## 后果

- **正面**：用户可通过 glossary 和本 ADR 理解 Assurance Agent 的来源和机制，
  不再误认为 `--sample` 控制该行为
- **正面**：明确了 `openan_install.sh`（部署脚本）与 `orchestrate.start`
  （组件内部行为）的职责边界
- **正面**：README 修正消除了 "agents 示例服务在 --all 模式下默认启动" 的误导
- **负面**：8902 端口不在脚本 Summary 输出中，用户需通过 `ss`/`lsof` 自行发现
- **负面**：seed agent card 路径（`samples/agentcard/`）与 `--sample` flag 的命名
  容易混淆，需通过 glossary 条目明确区分
- **负面**：agent card 数据持久化在 `registry-center/data/` 中，重新运行脚本时
  不会自动清理。即使 kill 8902 进程后重新运行脚本（甚至以 `--register` 模式运行），
  Assurance Agent 仍会因残留数据文件而出现在 registry-center 中。用户需手动
  `rm -rf registry-center/data/` 才能彻底清除（见下文"数据残留"章节）

## 数据残留 (Data Residue)

### 现象

用户 kill 8902 进程后重新运行 `./openan_install.sh`（无 `--sample`），Assurance Agent
仍然出现在 registry-center 中。即使以 `--register` 模式重新运行（不启动
orchestration-center），Assurance Agent 仍存在。

### 根因

registry-center 使用 file 存储模式（`storage_mode=file`），agent card 注册后被持久化到
`registry-center/data/agentcard.json`。`openan_install.sh` 重新运行时：

1. **Step 2 不清理 `data/` 目录** — 只运行 `agent_registry.init`（配置向导），
   不删除已有数据文件
2. **registry-center 启动时加载已有数据** — 发现 `data/agentcard.json` 存在，
   直接读取到内存中返回
3. **`free_port()` 不覆盖 8902** — 脚本只清理 5000/5001/3003/443/8080 五个端口

因此 Assurance Agent 的出现有两个**独立的来源**：

| 来源 | 条件 | 可清除方式 |
|------|------|----------|
| orchestrate.start 自注册 | orchestration-center 启动时 | kill 8902 进程（阻止重新注册） |
| data/agentcard.json 残留 | 文件未被删除 | `rm -rf registry-center/data/` |

### 彻底清除方法

```bash
# 1. 停止所有服务（使用脚本输出的 kill 命令）
kill <PIDs>
sudo systemctl stop nginx

# 2. 删除持久化数据
rm -rf registry-center/data/

# 3. 重新运行
./openan_install.sh
```

### 设计权衡

不在脚本中自动清理 `data/` 目录的决定是合理的：
- registry-center 的数据可能包含用户手动注册的其他 agent card，自动清理会造成数据丢失
- `data/` 目录是 registry-center 组件的内部存储，部署脚本不应越权清理
- 需要清理的用户可通过上述命令手动操作

## 验证方法

用户可通过以下命令验证本 ADR 描述的行为：

```bash
# 1. 确认 8902 端口监听（--all 或 --orchestrate 模式下）
ss -lnt | grep 8902

# 2. 确认进程归属
lsof -i :8902

# 3. 查看 registry-center 中已注册的 agent card
curl http://127.0.0.1:5000/rest/v1/registry-center/agent-cards

# 4. 查看持久化文件
cat registry-center/data/agentcard.json

# 5. 确认 seed 文件来源
cat orchestration-center/samples/agentcard/assurance_agent.json
```

## 关联

- `openan_install.sh` Step 4（lines 1418-1432）启动 `orchestrate.start`，
  设置 `AGENT_REGISTRY_URL` 环境变量
- `AGENT_REGISTRY_URL` 的设置依赖 Step 3.5（lines 1257-1285）中的 registry URL 配置
- registry-center 的 file 存储模式由 Step 2（line 999）的 init 输入决定
  （`storage_mode=file`）
- `--sample` flag 仅控制 `samples.start_agents_server`（lines 1477-1489），
  与内嵌 Agent 无关
- `free_port()` 函数（lines 718-735）仅清理 5000/5001/3003/443/8080 五个端口，
  不覆盖 8902，残留的 8902 进程不会被脚本主动 kill
- registry-center 的 `data/` 目录在重新运行脚本时不被清理，导致 agent card
  数据残留（见上文"数据残留"章节）
