# ADR-007: 卸载脚本设计与环境保留策略

## 状态

已采纳 (Accepted) — 2026-08-13

## 背景

`openan_install.sh` 部署了完整的 OpenAN 栈：registry-center、orchestration-center
（后端 + 前端）、agents 示例服务、nginx HTTPS 反向代理。随着用户反复测试，
需要一个对称的卸载脚本来清理项目文件和进程，同时保留 Python、Node.js、npm、nginx
等环境工具，避免每次重新安装时重新下载和安装环境依赖。

### 卸载范围分析

安装脚本的完整副作用如下：

**进程（5 + 1 个内部）：**

| 服务 | 端口 | 启动命令 | 发现方式 |
|------|------|---------|----------|
| registry-center | 5000 | `python -m agent_registry.start` | 端口 |
| orchestration 后端 | 5001 | `python -m orchestrate.start` | 端口 |
| orchestration 前端 | 3003 | `npm run dev` → vite | 端口 |
| agents 示例服务 | 8080 | `python -m samples.start_agents_server` | 端口 |
| nginx HTTPS 代理 | 443 | `systemctl start nginx` 或 `nginx` | systemctl/pgrep |
| Assurance Agent（内部） | 8902 | `orchestrate.start` 内部启动 | 端口 |

> 端口 8902 不在安装脚本的 Summary 输出中，由 orchestration-center 内部启动
> （见 [ADR-006](./ADR-006-orchestration-built-in-agent-self-registration.md)）。
> 8902 进程有独立 PID，kill 5001 的主进程不一定能终止 8902 子进程，需单独处理。

**文件/目录：**

| 路径 | 类型 | 删除决策 |
|------|------|---------|
| `${WORK_DIR}/registry-center/` | 项目目录（源码+venv+证书+日志+配置+数据） | 删除 |
| `${WORK_DIR}/orchestration-center/` | 项目目录（源码+venv+node_modules+日志+配置） | 删除 |
| `${WORK_DIR}/openan-nginx.conf` | nginx 配置本地副本 | 删除 |
| `/etc/nginx/conf.d/openan.conf` | 部署的 nginx 配置 | 删除 |
| `/etc/nginx/ssl/cert.pem` | 自签名 SSL 证书 | 删除 |
| `/etc/nginx/ssl/key.pem` | SSL 私钥 | 删除 |
| `/etc/nginx/sites-enabled/default` | 已被安装脚本删除 | 不恢复 |

**环境工具（保留）：**

| 工具 | 来源 | 位置 |
|------|------|------|
| Python 3.12+ | 系统包管理器 或 standalone 下载 | 系统目录 或 `${WORK_DIR}/.python3.12/` |
| Node.js 20.19+ | 系统包管理器 或 prebuilt 下载 | 系统目录 或 `${WORK_DIR}/.node/` |
| npm | 随 Node.js | 同上 |
| nginx 二进制 | 系统包管理器 | `/usr/sbin/nginx` |
| openssl | 系统包管理器 | 系统目录 |

## 决策

### 1. 仅支持 `--all` 模式

卸载脚本不支持 `--register` / `--orchestrate` 选择性卸载，统一卸载所有 OpenAN 组件。
若某项目目录不存在，自动跳过并打印 `[SKIP]`。

**理由**：简化设计。安装脚本的 `--register` / `--orchestrate` 模式主要用于
分机部署（registry 和 orchestration 部署在不同服务器），卸载时分别处理意义不大。
自动跳过不存在的目录已足够覆盖"只装了一个"的场景。

### 2. 按端口 kill 进程 + 智能识别

对每个端口，查找占用进程并检查其命令行是否匹配 OpenAN 已知模式：

| 端口 | 匹配模式 | 服务 |
|------|---------|------|
| 5000 | `agent_registry` | registry-center |
| 5001 | `orchestrate` | orchestration backend |
| 3003 | `vite` | orchestration frontend |
| 8080 | `samples` | agents examples server |
| 8902 | `orchestrate` | Assurance Agent（内部） |

匹配则 kill（先 TERM 后 KILL），不匹配则打印 `[WARN]` 并跳过，避免误杀
非 OpenAN 进程。

**理由**：安装脚本输出的 PID 仅在当前 session 有效，重启后失效。按端口查找
是唯一可靠的进程发现方式。智能识别避免误杀用户可能在这些端口上运行的其他服务。

### 3. Nginx 三级停止 + 配置清理

停止 nginx 采用三级回退（与安装脚本的启动逻辑对称）：
1. `systemctl stop nginx`（systemd 管理的系统）
2. `nginx -s stop`（非 systemd 或 systemctl 失败时）
3. `pkill nginx`（兜底）

停止后删除：
- `/etc/nginx/conf.d/openan.conf`
- `/etc/nginx/ssl/cert.pem` 和 `/etc/nginx/ssl/key.pem`

**不恢复** `/etc/nginx/sites-enabled/default`（安装时被删除）。

**保留** nginx 二进制和系统包，用户可随时重新启动 nginx 做其他用途。

### 4. 交互式确认 + `--force` 跳过

执行卸载前，列出将要执行的所有操作（kill 的进程、删除的文件/目录），
询问 `y/N` 确认。`--force` flag 跳过确认，适用于自动化场景。

### 5. 环境工具保留

保留以下内容，方便用户下次重新运行 `openan_install.sh` 时跳过环境安装步骤：
- `.python3.12/`（standalone Python 目录）
- `.node/`（prebuilt Node.js 目录）
- 系统级 Python、Node.js、npm、nginx、openssl 包

### 6. 容错设计

卸载脚本使用 `set -uo pipefail`（不含 `-e`），单步失败不中断，
继续执行后续步骤并在 Summary 中汇总结果。这与安装脚本的 `set -euo pipefail`
不同——卸载脚本的设计目标是"尽可能多清理"，而非"任一步失败即中止"。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 支持 `--register` / `--orchestrate` 模式 | 与安装脚本对称 | 增加复杂度，分机卸载场景极少 | 收益不抵成本 |
| 按 PID 文件 kill | 精确 | 安装脚本不写 PID 文件，需修改安装脚本 | 改动范围过大 |
| 无差别 kill 端口上的进程 | 简单 | 可能误杀用户其他服务 | 用户明确要求智能识别 |
| 停止 nginx 但不删配置 | 保留配置方便恢复 | 残留无用配置，nginx 重启后 443 端口被占 | 不彻底 |
| 完全卸载 nginx 包 | 彻底 | 用户明确要求保留 nginx | 违背需求 |
| 恢复 sites-enabled/default | 恢复初始状态 | 该文件属于 nginx 包，非脚本创建 | 超出脚本职责 |
| 删除 .python3.12/.node | 完全清理 | 用户明确要求保留环境工具 | 违背需求 |

## 后果

- **正面**：用户可快速卸载 OpenAN 项目文件，保留环境工具，下次安装跳过环境准备
- **正面**：智能识别避免误杀非 OpenAN 进程
- **正面**：交互式确认防止误操作
- **正面**：容错设计确保即使部分步骤失败，也能尽可能清理
- **负面**：8902 端口的 Assurance Agent 进程如果 cmdline 不含 `orchestrate`
  （例如是独立的 Python 子进程），可能无法被自动 kill，需用户手动处理
- **负面**：不恢复 `/etc/nginx/sites-enabled/default`，用户如需恢复需手动操作
  或重新安装 nginx 包

## 验证方法

```bash
# 1. 运行卸载脚本（交互式确认）
./openan_uninstall.sh

# 2. 运行卸载脚本（跳过确认，适用于自动化）
./openan_uninstall.sh --force

# 3. 验证进程已终止
ss -lnt | grep -E ':5000|:5001|:3003|:8080|:8902|:443'
# 应无输出

# 4. 验证目录已删除
ls -la registry-center/ orchestration-center/ 2>&1
# 应提示 No such file or directory

# 5. 验证 nginx 配置已删除
ls -la /etc/nginx/conf.d/openan.conf 2>&1
# 应提示 No such file or directory

# 6. 验证 SSL 证书已删除
ls -la /etc/nginx/ssl/cert.pem /etc/nginx/ssl/key.pem 2>&1
# 应提示 No such file or directory

# 7. 验证环境工具仍可用
python3 --version   # 3.12+
node --version      # v20.19+
npm --version
nginx -v
```

## 关联

- `openan_install.sh` Step 4（lines 1418-1526）启动所有服务
- `openan_install.sh` Step 3.7（lines 1306-1406）部署 nginx 配置和 SSL 证书
- [ADR-006](./ADR-006-orchestration-built-in-agent-self-registration.md) —
  Assurance Agent 内嵌启动机制，端口 8902 的来源
- `free_port()` 函数（lines 718-735）— 安装脚本的端口清理逻辑，
  卸载脚本参考其进程发现方式但增加了智能识别
