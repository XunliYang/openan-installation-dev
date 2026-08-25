# ADR-003: nginx 二进制 PATH 扩展查找

## 状态

已采纳 (Accepted) — 2026-08-11

## 背景

`openan_install.sh` 的 `setup_nginx()` 函数使用 `command -v nginx` 检测 nginx 是否已安装
以及验证安装是否成功。在 Debian/Ubuntu 上，`apt-get install nginx` 将二进制安装到
`/usr/sbin/nginx`，而**非 root 用户的默认 PATH 不包含 `/usr/sbin`**。

### 问题

当用户以非 root 身份（通过 sudo）运行脚本时，存在三类缺陷：

1. **安装后验证假阴性** — `run_sudo apt-get install nginx` 以 root 成功安装 nginx 到
   `/usr/sbin/nginx`，但后续 `command -v nginx` 以当前用户身份执行，PATH 中找不到
   `/usr/sbin`，返回失败。脚本报错 `nginx installation failed` 并退出，尽管 nginx
   实际已成功安装。**这是用户报告的错误。**

2. **已安装 nginx 误判为未安装** — 如果 nginx 已通过 apt 安装（位于 `/usr/sbin/nginx`），
   初始检测 `command -v nginx` 同样失败，`need_nginx` 被设为 `true`，触发不必要的
   重新安装，且安装后验证仍然失败。

3. **版本显示失败** — `nginx -v` 调用同样受 PATH 限制，无法获取版本信息。

### 根因

`command -v` 是 PATH 感知的命令查找工具。系统服务类二进制（如 nginx）按 Debian
策略安装到 `/usr/sbin`，该目录仅出现在 root 的 PATH 中。脚本中 `run_sudo apt-get install`
以 root 执行安装，但 `command -v nginx` 验证以当前用户执行，造成 **PATH 不对称**。

### 约束

- 脚本后续（Step 3.7、Step 4）中的 `nginx -t`、`nginx -s reload`、`systemctl start nginx`
  均通过 `run_sudo` 以 root 执行（root 的 PATH 含 `/usr/sbin`），**不受此问题影响**
- 问题严格限于 `setup_nginx()` 内部的 `command -v nginx` 和 `nginx -v` 调用
- openssl 安装到 `/usr/bin`（非 root PATH 中），不受此问题影响
- CentOS/RHEL 通过 EPEL 安装的 nginx 同样位于 `/usr/sbin/nginx`

## 决策

引入 `find_nginx_binary()` 辅助函数，采用两级查找策略：

### 查找顺序

1. **PATH 查找** — `command -v nginx`，覆盖 root 用户或 nginx 已在 PATH 中的情况
2. **sbin 回退** — 依次检查 `/usr/sbin/nginx` 和 `/sbin/nginx` 是否存在且可执行

### 函数设计

```bash
find_nginx_binary() {
    local nginx_bin
    local dir
    # 1. Check PATH (works for root or if already in PATH)
    if nginx_bin=$(command -v nginx 2>/dev/null); then
        echo "$nginx_bin"
        return 0
    fi
    # 2. Check common sbin locations (Debian/CentOS install nginx to /usr/sbin)
    for dir in /usr/sbin /sbin; do
        if [ -x "${dir}/nginx" ]; then
            echo "${dir}/nginx"
            return 0
        fi
    done
    return 1
}
```

### 调用点改造

`setup_nginx()` 中三处 `command -v nginx` 和两处 `nginx -v` 统一改用 `find_nginx_binary`：

| 位置 | 原始调用 | 改造后 |
|------|---------|--------|
| 初始检测 | `command -v nginx` | `find_nginx_binary` |
| 快速返回版本显示 | `nginx -v` | `"$nginx_bin" -v`（路径来自 find_nginx_binary） |
| 安装后验证 | `command -v nginx` | `find_nginx_binary` |
| 安装后版本显示 | `nginx -v` | `"$nginx_bin" -v`（路径来自 find_nginx_binary） |

### 设计要点

- **纯函数，无全局状态** — 每次调用即时查找，不依赖全局变量。函数调用廉价
  （command -v + 文件存在性检查），与 `detect_distro()` 同属无状态辅助函数
- **输出二进制路径** — 成功时 echo 路径，供版本显示调用使用；验证调用时 `>/dev/null` 丢弃输出
- **仅检查可执行文件** — 使用 `[ -x ]` 而非 `[ -f ]`，确保找到的二进制可执行
- **仅适用于 nginx** — openssl 在 `/usr/bin`（非 root PATH 中），不受此问题影响；
  其他命令（curl、tar、ss 等）同样位于 `/usr/bin`，无需扩展
- **set -e 安全** — `if nginx_bin=$(command -v nginx 2>/dev/null)` 在 `if` 条件中
  执行赋值，`set -e` 不会因 `command -v` 失败而退出脚本

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| `run_sudo command -v nginx` | 简单 | 验证依赖 sudo 可用性；与其他 command -v 调用风格不一致 | 不必要的 sudo 依赖 |
| `dpkg -l nginx` / `rpm -q nginx` | 不依赖 PATH | 需区分发行版；不验证二进制可执行性 | 发行版耦合 |
| 全局 NGINX_BIN 变量 | 与 PYTHON_CMD 模式一致 | 增加全局状态；setup_nginx 仅在一处调用 | 过度工程化 |
| 通用 find_binary() 函数 | 可复用 | 当前仅 nginx 受影响 | 预防性扩展，无实际收益 |
| 将 /usr/sbin 加入 PATH | 一劳永逸 | 修改全局 PATH 可能影响其他命令的查找 | 副作用不可控 |

## 后果

- **正面**：非 root 用户以 sudo 运行脚本时，nginx 安装后验证不再误报失败
- **正面**：已安装的 nginx（位于 /usr/sbin）被正确检测，避免不必要的重新安装
- **正面**：版本显示使用完整路径，不再依赖 PATH
- **正面**：CentOS/RHEL 通过 EPEL 安装的 nginx 同样位于 /usr/sbin，修复同时生效
- **负面**：新增一个辅助函数（约 15 行），但复用于 4 处调用，净减少重复逻辑

## 关联

- 修复了 `setup_nginx()` 中 `command -v nginx` 的 PATH 不对称问题
- 不影响后续 Step 3.7 和 Step 4 中的 nginx 调用（均通过 `run_sudo` 以 root 执行）
- 与 `detect_distro()` 和 `run_sudo()` 同属 nginx 安装相关的辅助函数层
