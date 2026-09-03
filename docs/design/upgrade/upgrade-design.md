# OpenAN 平台升级方案

## 1. 概述

### 1.1 背景

OpenAN 平台支持两种部署模式：
- **容器化部署**：基于 Kubernetes + Helm Chart，适用于生产环境
- **二进制部署**：单机本地进程，适用于开发测试环境

本文档定义两种部署模式的升级策略、操作流程和回滚方案，确保升级过程中业务连续性和数据安全性。

### 1.2 升级目标

- 支持全量升级（所有组件同时升级）
- 支持按组件升级（仅升级指定组件）
- 支持配置升级（仅更新配置，不改变镜像版本）
- 升级过程中业务不中断（容器化部署）
- 升级失败自动回滚

### 1.3 适用范围

| 部署模式 | 升级类型 | 支持版本 |
|---------|---------|---------|
| 容器化（Kubernetes） | 镜像版本升级、Chart 升级、配置升级 | v1.0.0+ |
| 二进制（Single Node） | 镜像版本升级、依赖包升级 | v1.0.0+ |

---

## 2. 容器化部署升级方案

### 2.1 架构设计

#### 2.1.1 升级流程

```
┌─────────────────────────────────────────────────────────────────┐
│                        升级前检查                                │
│  - 检查当前 release 状态                                         │
│  - 检查 Pod 状态（所有 Pod 必须 Running）                        │
│  - 检查版本兼容性（SemVer 规则）                                 │
│  - 可选：数据库备份提示                                          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                        执行升级                                  │
│  - helm upgrade --atomic --reuse-values --timeout 5m            │
│  - 滚动升级策略（RollingUpdate）                                 │
│  - 就绪探针控制流量切换                                          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                        升级后验证                                │
│  - 等待所有 Pod 就绪                                             │
│  - 验证 API 端点可访问                                           │
│  - 验证数据库连接正常                                            │
│  - 输出升级结果摘要                                              │
└─────────────────────────────────────────────────────────────────┘
                              ↓
                    [升级成功 / 自动回滚]
```

#### 2.1.2 组件依赖关系

```
                    ┌─────────────────┐
                    │  PostgreSQL     │
                    │  (数据库)        │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
    ┌─────────▼─────────┐      ┌───────────▼──────────┐
    │  Registry Center  │◄────►│ Orchestration Center │
    │  (注册中心)        │      │  (编排中心)           │
    └───────────────────┘      └──────────────────────┘
                                        │
                              ┌─────────▼─────────┐
                              │ Workflow Designer │
                              │  (前端)            │
                              └───────────────────┘
```

**升级顺序建议：**
1. PostgreSQL（如有 schema 变更）
2. Registry Center
3. Orchestration Center
4. Workflow Designer

### 2.2 升级策略

#### 2.2.1 滚动升级配置

Deployment 采用滚动升级策略，确保升级过程中始终有 Pod 提供服务：

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0      # 升级过程中不允许 Pod 不可用
    maxSurge: 1            # 每次最多创建 1 个新 Pod
```

**参数说明：**
- `maxUnavailable: 0`：升级过程中始终保持所有副本可用，确保业务不中断
- `maxSurge: 1`：每次创建 1 个新 Pod，等新 Pod 就绪后再删除旧 Pod

#### 2.2.2 健康检查探针

升级过程中，健康检查探针确保只有就绪的 Pod 才接收流量：

```yaml
# 就绪探针：控制 Pod 何时接收流量
readinessProbe:
  httpGet:
    path: /rest/v1/registry-center/agent-cards
    port: 5000
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 3

# 存活探针：检测 Pod 是否存活
livenessProbe:
  httpGet:
    path: /rest/v1/registry-center/agent-cards
    port: 5000
  initialDelaySeconds: 30
  periodSeconds: 30
```

#### 2.2.3 配置保留策略

使用 `helm upgrade --reuse-values` 保留现有配置：

```bash
helm upgrade openan ./openan-chart -n openan \
  --reuse-values \
  --atomic \
  --timeout 5m \
  --set registry.image.tag=v1.1.0 \
  --set orchestration.image.tag=v1.1.0 \
  --set frontend.image.tag=v1.1.0
```

**配置保留范围：**
- LLM API Key
- 数据库密码
- 资源限制（requests/limits）
- 副本数
- Ingress 配置
- TLS 证书

**注意：** 如果新 Chart 版本引入新的必填字段，`--reuse-values` 不会自动设置这些字段，需要用户手动补充。

### 2.3 升级类型

#### 2.3.1 全量升级

升级所有组件到新版本：

```bash
# 交互式
./upgrade.sh

# 命令行模式
./upgrade.sh --tag v1.1.0
```

**执行流程：**
1. 检查当前版本（`helm get values openan -n openan`）
2. 检查版本兼容性（Major 版本变更需要确认）
3. 执行 `helm upgrade` 升级所有组件
4. 等待所有 Pod 就绪
5. 验证 API 端点
6. 输出升级结果

#### 2.3.2 按组件升级

仅升级指定组件：

```bash
# 仅升级 Registry Center
./upgrade.sh --tag v1.1.0 --components registry

# 升级 Registry 和 Orchestration
./upgrade.sh --tag v1.1.0 --components registry,orchestration
```

**执行流程：**
1. 检查指定组件的当前版本
2. 执行 `helm upgrade` 仅更新指定组件的镜像 tag
3. 等待指定组件的 Pod 就绪
4. 验证指定组件的 API 端点

#### 2.3.3 配置升级

仅更新配置，不改变镜像版本：

```bash
# 更新资源限制
./upgrade.sh --config-only --components registry \
  --set registry.resources.requests.cpu=500m

# 更新副本数
./upgrade.sh --config-only --components orchestration \
  --set orchestration.replicas=3
```

**执行流程：**
1. 执行 `helm upgrade` 仅更新配置字段
2. 触发 Pod 滚动重启（配置变更会自动触发）
3. 等待 Pod 就绪

### 2.4 版本管理

#### 2.4.1 语义化版本（SemVer）

采用语义化版本规范：`vMAJOR.MINOR.PATCH`

| 版本变更 | 含义 | 升级风险 |
|---------|------|---------|
| `v1.0.0` → `v1.0.1` | Bug 修复，向后兼容 | 低 |
| `v1.0.0` → `v1.1.0` | 功能新增，向后兼容 | 中 |
| `v1.0.0` → `v2.0.0` | Breaking change | 高 |

#### 2.4.2 版本兼容性检查

升级脚本自动检查版本兼容性：

```bash
# 检查 Major 版本变更
if [ "${current_major}" != "${target_major}" ]; then
    log_warn "Major 版本变更检测到 (v${current_major} → v${target_major})"
    log_warn "可能包含 Breaking Changes，请查看 CHANGELOG.md"
    if ! ask_yes_no "是否继续升级？" "no"; then
        exit 0
    fi
fi
```

#### 2.4.3 CHANGELOG 规范

每个版本在 `CHANGELOG.md` 中记录变更：

```markdown
## v1.1.0 (2026-01-20)

### Added
- Registry Center: 新增 Agent 批量导入功能
- Orchestration Center: 新增工作流模板功能

### Changed
- Orchestration Center: 优化工作流执行性能

### Fixed
- Registry Center: 修复 Agent 注册失败的问题

### Breaking Changes
- None

## v2.0.0 (2026-02-01)

### Breaking Changes
- Registry Center: API 路径从 `/api/v1/agents` 改为 `/rest/v1/registry-center/agent-cards`
- 需要手动更新客户端配置
```

### 2.5 升级失败处理

#### 2.5.1 自动回滚

使用 `helm upgrade --atomic` 实现自动回滚：

```bash
helm upgrade openan ./openan-chart -n openan \
  --reuse-values \
  --atomic \
  --timeout 5m \
  --set registry.image.tag=v1.1.0
```

**`--atomic` 行为：**
- 如果升级失败（Pod 未就绪、健康检查失败等），自动回滚到上一个版本
- 回滚后输出失败原因和日志查看命令

#### 2.5.2 失败场景处理

| 失败场景 | 处理方式 |
|---------|---------|
| 镜像拉取失败 | 自动回滚，检查镜像地址和 tag 是否正确 |
| Pod 启动失败 | 自动回滚，检查日志 `kubectl logs -n openan <pod-name>` |
| 健康检查失败 | 自动回滚，检查应用配置是否正确 |
| 数据库连接失败 | 自动回滚，检查数据库密码和连接配置 |
| 超时（5 分钟） | 自动回滚，检查集群资源和网络 |

#### 2.5.3 手动回滚

如果自动回滚失败，可以手动回滚：

```bash
# 查看 release 历史
helm history openan -n openan

# 回滚到上一个版本
helm rollback openan -n openan

# 回滚到指定版本
helm rollback openan <revision> -n openan
```

### 2.6 操作步骤

#### 2.6.1 升级前准备

```bash
# 1. 检查当前版本
helm get values openan -n openan | grep -E "tag:|repository:"

# 2. 检查 Pod 状态
kubectl get pods -n openan
# 预期：所有 Pod 状态为 Running

# 3. 检查当前 release 状态
helm status openan -n openan
# 预期：STATUS: deployed

# 4. 备份数据库（可选但推荐）
kubectl exec -n openan openan-postgres-0 -- \
  pg_dump -U postgres registry_center > registry_center_backup.sql
kubectl exec -n openan openan-postgres-0 -- \
  pg_dump -U postgres orchestration_center > orchestration_center_backup.sql
```

#### 2.6.2 执行升级

```bash
# 方式 1：交互式升级
cd containerized
./upgrade.sh

# 方式 2：命令行升级（全量）
./upgrade.sh --tag v1.1.0

# 方式 3：命令行升级（按组件）
./upgrade.sh --tag v1.1.0 --components registry,orchestration
```

#### 2.6.3 升级后验证

```bash
# 1. 检查 Pod 状态
kubectl get pods -n openan
# 预期：所有 Pod 状态为 Running，READY 为 1/1 或 2/2

# 2. 检查 release 状态
helm status openan -n openan
# 预期：STATUS: deployed, REVISION: N+1

# 3. 验证 API 端点
curl http://<INGRESS_IP>/registry/rest/v1/registry-center/agent-cards
curl http://<INGRESS_IP>/api/orchestrate/rest/v1/orchestrate/agent-cards

# 4. 检查日志
kubectl logs -n openan -l app=registry-center --tail=50
kubectl logs -n openan -l app=orchestration-center --tail=50
```

### 2.7 验证方法

#### 2.7.1 功能验证

```bash
# 1. 验证 Registry API
curl -X POST http://<INGRESS_IP>/registry/rest/v1/registry-center/agent-cards \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-agent",
    "description": "Test agent for upgrade validation",
    "url": "http://test-agent:8080",
    "version": "1.0.0"
  }'

# 2. 验证 Orchestration API
curl http://<INGRESS_IP>/api/orchestrate/rest/v1/orchestrate/agent-cards

# 3. 验证前端访问
# 浏览器访问 http://<INGRESS_IP>/
```

#### 2.7.2 性能验证

升级前后对比关键指标：
- API 响应时间
- Pod 启动时间
- 数据库查询性能

```bash
# 使用 hey 进行压力测试
hey -n 1000 -c 10 http://<INGRESS_IP>/registry/rest/v1/registry-center/agent-cards
```

---

## 3. 二进制部署升级方案

### 3.1 架构设计

#### 3.1.1 升级流程

```
┌─────────────────────────────────────────────────────────────────┐
│                        升级前检查                                │
│  - 检查当前版本                                                  │
│  - 检查进程状态                                                  │
│  - 检查备份状态                                                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                        停止服务                                  │
│  - 停止所有进程                                                  │
│  - 备份数据库                                                    │
│  - 备份配置文件                                                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                        执行升级                                  │
│  - 下载新版本 release 包                                         │
│  - 更新 venv 依赖                                                │
│  - 更新配置文件                                                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                        启动服务                                  │
│  - 启动所有进程                                                  │
│  - 验证服务状态                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.1.2 组件结构

```
binary/one-click/
├── registry-center/           # Registry Center
│   ├── venv/                  # Python 虚拟环境
│   ├── etc/                   # 配置文件
│   └── data/                  # 数据目录
├── orchestration-center/      # Orchestration Center
│   ├── venv/                  # Python 虚拟环境
│   ├── etc/                   # 配置文件
│   └── workflow-designer/     # 前端（需要重新构建）
└── openan_install.sh          # 安装脚本
```

### 3.2 升级策略

#### 3.2.1 停机升级

二进制部署采用**停机升级**策略：

1. 停止所有进程
2. 备份数据和配置
3. 更新代码和依赖
4. 启动服务

**原因：**
- 单机部署无法实现滚动升级
- 进程间有依赖关系，需要统一升级

#### 3.2.2 配置保留

升级过程中保留以下配置：
- `etc/conf/server.conf`：服务配置
- `common/config/llm_config.json`：LLM 配置
- 数据库数据（`data/` 目录）

### 3.3 升级类型

#### 3.3.1 全量升级

升级所有组件：

```bash
# 交互式
./upgrade.sh

# 命令行模式
./upgrade.sh --tag v1.1.0
```

#### 3.3.2 按组件升级

仅升级指定组件：

```bash
# 仅升级 Registry Center
./upgrade.sh --tag v1.1.0 --components registry

# 升级 Registry 和 Orchestration
./upgrade.sh --tag v1.1.0 --components registry,orchestration
```

### 3.4 操作步骤

#### 3.4.1 升级前准备

```bash
# 1. 检查当前版本
cat registry-center/VERSION 2>/dev/null || echo "Unknown"
cat orchestration-center/VERSION 2>/dev/null || echo "Unknown"

# 2. 检查进程状态
ps aux | grep -E "agent_registry|orchestrate" | grep -v grep

# 3. 备份数据库
cd registry-center
source venv/bin/activate
python -m agent_registry.backup --output ../backup/registry_center_$(date +%Y%m%d).sql

# 4. 备份配置文件
cp -r registry-center/etc ../backup/etc_registry_$(date +%Y%m%d)
cp -r orchestration-center/etc ../backup/etc_orchestration_$(date +%Y%m%d)
```

#### 3.4.2 执行升级

```bash
# 方式 1：交互式升级
cd binary/one-click
./upgrade.sh

# 方式 2：命令行升级（全量）
./upgrade.sh --tag v1.1.0

# 方式 3：命令行升级（按组件）
./upgrade.sh --tag v1.1.0 --components registry
```

#### 3.4.3 升级后验证

```bash
# 1. 检查进程状态
ps aux | grep -E "agent_registry|orchestrate" | grep -v grep
# 预期：看到 registry-center 和 orchestration-center 进程

# 2. 检查端口
ss -tlnp | grep -E "5000|5001"
# 预期：5000 和 5001 端口监听中

# 3. 验证 API
curl http://localhost:5000/rest/v1/registry-center/agent-cards
curl http://localhost:5001/rest/v1/orchestrate/agent-cards

# 4. 检查日志
tail -f registry-center/registry-center.log
tail -f orchestration-center/backend.log
```

### 3.5 回滚方案

#### 3.5.1 自动回滚

升级脚本内置回滚逻辑：

```bash
# 升级失败时自动回滚
if [ $? -ne 0 ]; then
    log_error "Upgrade failed, rolling back..."
    # 恢复备份
    cp -r ../backup/etc_registry_$(date +%Y%m%d)/* registry-center/etc/
    # 重启服务
    ./openan_install.sh --reg --orc
fi
```

#### 3.5.2 手动回滚

```bash
# 1. 停止服务
./openan_uninstall.sh

# 2. 恢复备份
cp -r ../backup/etc_registry_20260120/* registry-center/etc/
cp -r ../backup/etc_orchestration_20260120/* orchestration-center/etc/

# 3. 恢复数据库
cd registry-center
source venv/bin/activate
python -m agent_registry.restore --input ../backup/registry_center_20260120.sql

# 4. 启动服务
./openan_install.sh --reg --orc
```

---

## 4. 升级脚本设计

### 4.1 脚本结构

```
containerized/
├── upgrade.sh                 # 容器化升级脚本
└── binary/one-click/
    └── upgrade.sh             # 二进制升级脚本
```

### 4.2 命令行参数

```bash
Usage: ./upgrade.sh [OPTIONS]

Options:
  --tag <version>              Target version (e.g., v1.1.0)
  --components <list>          Components to upgrade (comma-separated)
                               Available: registry,orchestration,frontend,postgresql
  --config-only                Only update configuration, don't change image tag
  --set <key=value>            Set specific values (can be used multiple times)
  --force                      Force upgrade without confirmation
  --dry-run                    Show what would be done without making changes
  --backup                     Backup database before upgrade (default: true)
  --no-backup                  Skip database backup
  -h, --help                   Show help message

Examples:
  # Full upgrade (all components)
  ./upgrade.sh --tag v1.1.0

  # Upgrade specific components
  ./upgrade.sh --tag v1.1.0 --components registry,orchestration

  # Configuration only upgrade
  ./upgrade.sh --config-only --components registry --set registry.replicas=3

  # Dry run (show what would be done)
  ./upgrade.sh --tag v1.1.0 --dry-run
```

### 4.3 核心函数

```bash
# 版本兼容性检查
check_version_compatibility() {
    local current_version="$1"
    local target_version="$2"
    
    local current_major=$(echo "$current_version" | cut -d. -f1 | tr -d 'v')
    local target_major=$(echo "$target_version" | cut -d. -f1 | tr -d 'v')
    
    if [ "$current_major" != "$target_major" ]; then
        log_warn "Major version change detected (v${current_major} → v${target_major})"
        log_warn "This may include breaking changes. Check CHANGELOG.md before proceeding."
        if ! ask_yes_no "Continue with upgrade?" "no"; then
            exit 0
        fi
    fi
}

# 升级前检查
preflight_checks() {
    log_step "Running pre-flight checks..."
    
    # Check release status
    if ! helm status openan -n openan &>/dev/null; then
        log_error "Release 'openan' not found"
        exit 1
    fi
    
    # Check pod status
    local not_ready=$(kubectl get pods -n openan -o json | \
        jq -r '.items[] | select(.status.phase != "Running" or .status.containerStatuses[].ready != true) | .metadata.name')
    
    if [ -n "$not_ready" ]; then
        log_error "Some pods are not ready:"
        echo "$not_ready"
        log_info "Please fix pod issues before upgrade"
        exit 1
    fi
    
    log_info "All pre-flight checks passed"
}

# 升级后验证
post_upgrade_validation() {
    log_step "Validating upgrade..."
    
    # Wait for pods to be ready
    log_info "Waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=registry-center -n openan --timeout=300s
    kubectl wait --for=condition=ready pod -l app=orchestration-center -n openan --timeout=300s
    kubectl wait --for=condition=ready pod -l app=workflow-designer -n openan --timeout=300s
    
    # Validate API endpoints
    log_info "Validating API endpoints..."
    local ingress_ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    
    if curl -s http://$ingress_ip/registry/rest/v1/registry-center/agent-cards > /dev/null; then
        log_info "Registry API: OK"
    else
        log_error "Registry API: FAILED"
        return 1
    fi
    
    if curl -s http://$ingress_ip/api/orchestrate/rest/v1/orchestrate/agent-cards > /dev/null; then
        log_info "Orchestration API: OK"
    else
        log_error "Orchestration API: FAILED"
        return 1
    fi
    
    log_info "Upgrade validation complete"
}
```

### 4.4 输出示例

```
==========================================
  OpenAN Platform Upgrade
==========================================

[STEP] Pre-flight checks...
[INFO] Current version: v1.0.0
[INFO] Target version: v1.1.0
[INFO] Version compatibility: OK
[INFO] Release status: deployed
[INFO] Pod status: All pods running

[STEP] Upgrading to v1.1.0...
[INFO] Components: registry, orchestration, frontend
[INFO] Command: helm upgrade openan ./openan-chart -n openan --reuse-values --atomic --timeout 5m --set registry.image.tag=v1.1.0 --set orchestration.image.tag=v1.1.0 --set frontend.image.tag=v1.1.0
[INFO] Release "openan" has been upgraded. Happy Helming!

[STEP] Post-upgrade validation...
[INFO] Waiting for pods to be ready...
[INFO] registry-center: Ready (2/2)
[INFO] orchestration-center: Ready (1/1)
[INFO] workflow-designer: Ready (2/2)
[INFO] Validating API endpoints...
[INFO] Registry API: OK
[INFO] Orchestration API: OK

==========================================
  Upgrade Complete!
==========================================
  Previous version: v1.0.0
  Current version:  v1.1.0
  Revision:         4
  
  Check status:
    kubectl -n openan get pods
    helm status openan -n openan
  
  Rollback (if needed):
    helm rollback openan -n openan
==========================================
```

---

## 5. 注意事项

### 5.1 升级前

1. **备份数据库**：升级前务必备份数据库，防止数据丢失
2. **检查版本兼容性**：查看 `CHANGELOG.md` 确认是否有 Breaking Changes
3. **检查集群资源**：确保集群有足够的资源支持升级过程中的滚动更新
4. **通知用户**：如果是生产环境，提前通知用户可能的短暂中断

### 5.2 升级中

1. **不要中断升级**：升级过程中不要手动终止脚本，可能导致状态不一致
2. **监控日志**：在新终端中监控 Pod 日志，及时发现异常
3. **准备回滚**：如果升级失败，准备好回滚方案

### 5.3 升级后

1. **验证功能**：测试关键 API 和前端功能
2. **监控性能**：观察升级后的性能指标
3. **清理备份**：确认升级成功后，可以删除旧备份

### 5.4 已知限制

1. **Major 版本升级**：Major 版本变更（如 v1.x → v2.x）可能包含 Breaking Changes，需要手动处理配置迁移
2. **数据库 Schema 变更**：如果新版本包含数据库 Schema 变更，升级脚本会自动执行迁移，但建议先备份
3. **二进制部署中断**：二进制部署升级需要停机，无法实现零中断

---

## 6. 故障排查

### 6.1 升级失败

```bash
# 查看 release 状态
helm status openan -n openan

# 查看 Pod 日志
kubectl logs -n openan -l app=registry-center --tail=100
kubectl logs -n openan -l app=orchestration-center --tail=100

# 查看事件
kubectl describe pod -n openan -l app=registry-center

# 手动回滚
helm rollback openan -n openan
```

### 6.2 Pod 无法启动

```bash
# 检查镜像拉取
kubectl describe pod -n openan <pod-name> | grep -A 10 Events

# 检查配置
kubectl get configmap -n openan
kubectl get secret -n openan

# 检查资源限制
kubectl describe pod -n openan <pod-name> | grep -A 5 Limits
```

### 6.3 API 无法访问

```bash
# 检查 Ingress
kubectl get ingress -n openan
kubectl describe ingress -n openan

# 检查 Service
kubectl get svc -n openan
kubectl describe svc -n openan registry-center

# 检查端口
kubectl exec -n openan <pod-name> -- ss -tlnp
```

---

## 7. 附录

### 7.1 相关文档

- [Helm Chart 部署指南](../../containerized/openan-chart/README.md)
- [二进制安装指南](../../binary/one-click/README.md)
- [镜像构建指南](../../containerized/build/README.md)

### 7.2 版本历史

| 版本 | 日期 | 变更说明 |
|------|------|---------|
| v1.0 | 2026-08-19 | 初始版本 |

### 7.3 术语表

| 术语 | 说明 |
|------|------|
| Release | Helm 的一个部署实例 |
| Revision | Release 的版本号，每次升级递增 |
| Rolling Update | 滚动升级，逐步替换旧 Pod |
| Atomic Upgrade | 原子升级，失败时自动回滚 |
| SemVer | 语义化版本规范 |
