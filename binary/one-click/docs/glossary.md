# 术语表 / Glossary

本术语表涵盖 `openan_install.sh` 中涉及的自动安装机制相关术语。

---

## 三级回退 (Three-level Fallback)

自动安装策略的核心模式。当需要安装某个依赖（Python、Node.js）时，按以下顺序依次尝试：

1. **已有命令检测** — 检查系统中是否已存在满足版本要求的命令
2. **包管理器安装** — 通过 apt/dnf/yum 安装，含外部仓库回退（deadsnakes PPA / NodeSource）
3. **预编译二进制下载** — 从官方源下载独立二进制，安装到本地目录

每一级失败后自动进入下一级，所有级别均失败才报错退出。

## 预编译二进制 (Prebuilt Binary)

由软件官方提供的、已针对特定平台（OS + 架构）编译好的二进制包。用户无需从源码编译，
直接下载解压即可使用。

- **Python**: 来自 [python-build-standalone](https://github.com/indygreg/python-build-standalone) 项目
- **Node.js**: 来自 [nodejs.org/dist](https://nodejs.org/dist/) 官方分发

## PATH 前置 (PATH Prepending)

将本地安装的二进制目录添加到 `PATH` 环境变量的最前面，使其优先于系统已安装的同名命令。
仅在当前脚本会话中生效（`export PATH=...`），不修改系统配置。

## NodeSource

第三方 Node.js 仓库提供者，通过 setup 脚本（如 `setup_20.x`）向系统添加 Node.js 官方仓库，
使得 `apt/dnf install nodejs` 可以安装指定大版本的 Node.js。

- Debian/Ubuntu: `https://deb.nodesource.com/setup_20.x`
- CentOS/RHEL: `https://rpm.nodesource.com/setup_20.x`

## deadsnakes PPA

Ubuntu 的第三方 PPA，提供比官方仓库更新的 Python 版本。当 `apt install python3.12`
在默认仓库中不可用时，脚本会添加此 PPA 作为回退。

## run_sudo()

脚本中的辅助函数。以 root 用户运行时直接执行命令，非 root 用户通过 `sudo` 执行。
所有需要 root 权限的操作（包管理器安装、修改 /etc 目录等）均通过此函数调用。

## resolve_python() / resolve_node()

Python / Node.js 的主解析函数。封装了三级回退逻辑的完整流程，设置全局变量
`PYTHON_CMD` / 确保命令可用，供后续步骤使用。

## npm (Node Package Manager)

Node.js 的包管理器。在预编译二进制中随 Node.js 自带；在 Debian/Ubuntu 的 apt 中
可能是独立包（`nodejs` 包不含 `npm`），需显式安装。

## EOL (End of Life)

软件版本停止维护和安全更新的时间点。Node.js 20.x 于 2026 年 4 月达到 EOL，
但 nodejs.org 仍保留所有历史版本的预编译二进制可供下载。

## 本地安装 (Local Install)

将软件安装到脚本工作目录下（如 `${WORK_DIR}/.node`、`${WORK_DIR}/.python3.12`），
而非系统目录（如 `/usr/local`、`/opt`）。优点：无需 sudo、不影响系统环境、目录自包含。
