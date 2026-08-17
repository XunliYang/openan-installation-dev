# ADR-014: 前端改为静态文件服务

## 状态

已采纳 (Accepted) — 2026-08-17

## 背景

### 问题

`openan_install.sh` 原先将 orchestration-center 前端以 Vite 开发服务器模式运行
（`npm run dev`，监听端口 3003），nginx 通过 `proxy_pass` 将 `location /` 的请求
转发到该 dev server。

该方案在开发场景下有 HMR（热模块替换）优势，但在演示和部署场景中存在以下问题：

1. **多一个常驻进程** — Vite dev server 占用约 200-400MB 内存，纯演示场景下是浪费
2. **进程管理复杂** — 安装脚本需要后台启动 Vite、轮询 30 秒验证端口监听、管理 PID、
   在摘要中单独列出停止命令
3. **nginx 配置复杂** — `location /` 需要 WebSocket 升级头（`Upgrade`/`Connection`）
   支持 HMR，与纯静态文件服务相比多余
4. **首次加载慢** — Vite 按需编译，首次访问页面时需要实时编译模块，响应较慢
5. **卸载脚本额外清理** — 需要扫描端口 3003 和匹配 `vite` 进程 pattern

### 根因

`npm run dev` 是开发模式命令，不适合作为部署/演示的运行方式。生产级部署应使用
`npm run build` 产出预编译的静态文件（HTML/JS/CSS），由 nginx 直接服务。

## 决策

### 1. 构建阶段新增 `npm run build`

在 Step 3 的 `npm install --force` 之后，新增 `npm run build` 构建静态资源：

```bash
echo "[BUILD] Building frontend static assets..."
npm run build > "${ORCHESTRATION_DIR}/frontend-build.log" 2>&1
echo "  [OK] Frontend built to dist/"
```

- 构建输出重定向到 `frontend-build.log`，终端仅显示状态行
- `set -euo pipefail` 保证构建失败时脚本直接退出（exit 1）
- 构建产物在 `${ORCHESTRATION_DIR}/workflow-designer/dist/` 目录

### 2. nginx `location /` 从 proxy 改为静态文件服务

改造前：
```nginx
location / {
    proxy_pass http://127.0.0.1:3003;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

改造后：
```nginx
location / {
    root /var/www/openan;
    try_files $uri $uri/ /index.html;
}
```

- `root` 指向 `/var/www/openan/`（系统标准 Web 目录），nginx 直接读取静态文件
- `try_files $uri $uri/ /index.html` 实现 SPA 路由回退（Vue Router history 模式必需）
- 移除 WebSocket 升级头（HMR 不再需要）
- 移除 `X-Forwarded-Proto` / `X-Real-IP` 头（静态文件服务不需要）

### 2a. 静态资源部署到 /var/www/openan/

`npm run build` 产出的 `dist/` 目录位于用户 home 目录下。nginx worker 进程以
`www-data` 用户运行，需要穿越 `/home/<user>/` 才能访问 dist 文件。用户 home
目录默认权限为 750 或 700，`www-data` 无法穿越，导致 `Permission denied` 和
`try_files` 重定向循环（500 Internal Server Error）。

修复方案：安装阶段将 dist 内容复制到 `/var/www/openan/` 并设置 755 权限：

```bash
run_sudo mkdir -p /var/www/openan
run_sudo cp -r "${ORCHESTRATION_DIR}/workflow-designer/dist/"* /var/www/openan/
run_sudo chmod -R 755 /var/www/openan
```

卸载时 `run_sudo rm -rf /var/www/openan` 清理。

### 3. 移除 Vite dev server 启动逻辑

Step 4 中以下内容全部删除：
- `free_port 3003` 端口清理
- `nohup npm run dev` 后台启动
- 30 秒轮询验证端口监听
- `OC_FRONTEND_PID` / `FRONTEND_REAL_PID` 变量
- 摘要中的 frontend 行和 `frontend.log` 日志引用

### 4. 卸载脚本同步清理

`openan_uninstall.sh` 移除：
- `OPENAN_PORTS` 中的 `"3003:orchestration frontend"` 条目
- `OPENAN_PATTERNS` 中的 `vite` pattern
- Summary 中的 3003 端口引用

### 5. Node.js 依赖不变

Node.js 仍由 `resolve_node()` 自动安装（Step 0），因为 `npm install` + `npm run build`
需要 Node.js 运行时。变化仅在于 Node.js 从"运行时依赖"变为"构建时依赖"——安装完成后
不再需要 Node.js 进程常驻运行。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 保留 dev 模式，新增 --static flag | 保留开发灵活性 | 增加脚本复杂度，两条代码路径需维护 | 用户明确要求彻底替换 |
| build 失败回退到 dev 模式 | 容错性好 | 掩盖构建错误，两种模式行为不一致 | 可能隐藏真正的问题 |
| dist 复制到 /var/www/openan | 符合系统目录规范 | 增加部署步骤和卸载清理点 | **已采纳**：项目内 dist 路径经用户 home 目录，nginx www-data 无法穿越，导致 Permission denied（500）。系统目录无此问题 |
| 构建后用 curl 验证 nginx 能返回 index.html | 验证完整 | nginx 此时未启动，需启动后再验证 | nginx -t 已验证配置，过度验证 |

## 后果

- **正面**：减少一个常驻进程（Vite dev server），降低内存占用
- **正面**：nginx 配置更简洁，`location /` 从 6 行 proxy 配置简化为 2 行静态服务
- **正面**：首次页面加载更快（预编译静态文件 vs Vite 按需编译）
- **正面**：卸载脚本减少一个端口扫描和 pattern 匹配
- **正面**：安装脚本删除 30 秒轮询验证逻辑，安装更快
- **负面**：失去 HMR 热更新能力，修改前端代码需重新 `npm run build`
- **负面**：安装阶段新增构建步骤（约 10-30 秒），但一次性成本
- **负面**：`frontend-build.log` 为一次性日志，不反映运行时状态
- **负面**：需要额外的 `/var/www/openan/` 目录和卸载清理步骤

## 关联

- `binary/one-click/openan_install.sh` — Step 3 新增 build + 部署到 /var/www/openan、Step 3.7 改 nginx 配置、Step 4 删 Vite 启动
- `binary/one-click/openan_uninstall.sh` — 移除 3003 端口和 vite pattern、新增 /var/www/openan 清理
- `binary/one-click/docs/glossary.md` — 新增术语：静态文件服务模式、SPA 路由回退、构建时依赖、dist 目录
