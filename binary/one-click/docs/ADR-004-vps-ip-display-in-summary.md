# ADR-004: Summary 远程访问 URL 显示 VPS IP

## 状态

已采纳 (Accepted) — 2026-08-12

## 背景

`openan_install.sh` 部署在 VPS 上运行，用户从本机浏览器远程访问。脚本最终的 Summary
输出段列出所有已启动服务及其访问 URL，但 frontend 和 nginx 两行使用 `localhost`：

```bash
echo " orchestration frontend: http://localhost:3003   (PID: ${FRONTEND_REAL_PID})"
echo " nginx (HTTPS):          https://localhost        (PID: ${NGINX_PID})"
```

用户在本机看到 `localhost` 后需要手动替换为 VPS IP 才能访问，体验不友好。

### 服务绑定地址分析

| 服务 | 启动命令 | 绑定地址 | 远程直连？ |
|------|---------|---------|-----------|
| registry-center | `python -m agent_registry.start` | 127.0.0.1:5000 | 否 |
| orchestration backend | `python -m orchestrate.start` | 127.0.0.1:5001 | 否 |
| orchestration frontend | `npm run dev`（无 `--host`） | 127.0.0.1:3003 | 否 |
| agents examples server | `python -m samples.start_agents_server` | 127.0.0.1:8080 | 否 |
| nginx | `listen 443 ssl` | 0.0.0.0:443 | **是** |

所有后端服务绑定在 `127.0.0.1`，外部无法直连。nginx 是唯一的远程入口，代理关系：

```
https://VPS_IP/                    → frontend (3003)
https://VPS_IP/api/orchestrate/    → backend  (5001)
https://VPS_IP/registry/           → registry (5000)
```

### 约束

- 脚本已有 `set -euo pipefail`，IP 检测命令失败会导致脚本退出，需要回退机制
- `hostname -I` 可能返回多个 IP（空格分隔），需取第一个
- `hostname -I` 在极少数精简系统上可能不可用，需回退到 `localhost`
- `--register` 模式下无 nginx，frontend 和 nginx 行不显示（PID 为空），改动无影响
- `--orchestrate` 模式下 registry 行不显示（REGISTRY_PID 为空），无需处理 registry URL
- agents examples server 无 nginx 代理，远程不可访问，保持 `127.0.0.1` 不变

## 决策

### 1. VPS IP 检测

在 Summary 输出段之前添加 IP 检测逻辑：

```bash
VPS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || VPS_IP=""
[ -z "${VPS_IP}" ] && VPS_IP="localhost"
```

- `hostname -I` 输出所有非回环网卡 IP（空格分隔），`awk '{print $1}'` 取第一个
- `2>/dev/null` 抑制错误输出，`|| VPS_IP=""` 防止 `set -e` 退出
- 空值回退到 `localhost`，确保变量始终非空

### 2. 仅改 frontend 和 nginx 两行

| 行 | 改前 | 改后 |
|----|------|------|
| frontend | `http://localhost:3003` | `https://${VPS_IP}` |
| nginx | `https://localhost` | `https://${VPS_IP}` |

frontend URL 从 `http://localhost:3003` 改为 `https://${VPS_IP}`（经 nginx 代理），
因为 Vite 开发服务器绑定在 127.0.0.1:3003，外部无法直连 3003 端口。用户通过 nginx
的 `/` 路径代理访问前端，与 nginx 行显示相同的 `https://${VPS_IP}` URL。

### 3. 其余行保持不变

| 行 | 服务 | 保持原样的原因 |
|----|------|---------------|
| registry | registry-center | `--register` 模式无 nginx，127.0.0.1 是唯一正确地址 |
| backend | orchestration backend | 本地调试地址，远程通过 nginx `/api/orchestrate/` 代理 |
| agents | agents examples server | 无 nginx 代理，远程不可访问 |

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 所有行改为 nginx 代理 URL | 信息一致 | `--register` 模式无 nginx，显示 `https://VPS_IP/registry/` 误导用户 | 模式兼容性不足 |
| `ip route get 1.1.1.1` 检测 IP | 更精确 | 语法因 iproute2 版本略有差异 | 兼容性风险 |
| `curl ifconfig.me` 获取公网 IP | 获取真实公网 IP | 需要联网，增加外部依赖，VPS 内网 IP 即可访问 | 不必要的依赖 |
| 命令行参数传入 VPS IP | 最灵活 | 破坏一键部署体验，用户需预先知道 IP | 用户体验差 |
| 同时修改 SSL 证书 CN 为 VPS IP | 证书匹配 | 自签名证书浏览器本就不信任，CN 修改收益有限 | 收益低于成本 |

## 后果

- **正面**：VPS 用户在 Summary 中直接看到可用的远程访问 URL，无需手动替换 localhost
- **正面**：IP 检测有 `localhost` 回退，在精简系统或容器中不会导致脚本失败
- **正面**：`--register` 和 `--orchestrate` 模式不受影响（对应行不显示）
- **负面**：`hostname -I` 可能返回 Docker 网桥 IP（如 172.17.0.1），但通常不是第一个 IP
- **负面**：frontend 和 nginx 行显示相同 URL，但 PID 不同，信息不冗余

## 关联

- 仅修改 Summary 输出段（lines 1577-1609），不涉及服务启动逻辑
- nginx 代理配置（lines 1384-1417）保持不变，`/` → `127.0.0.1:3003`
- 与 ADR-003（nginx sbin 路径检测）同属 nginx 相关改进
