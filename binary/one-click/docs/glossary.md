# 术语表 / Glossary

本术语表涵盖 `openan_install.sh` 中涉及的自动安装机制、安装模式及 PATH 查找相关术语。

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

## 安装模式 (Installation Mode)

脚本通过命令行参数控制安装哪些组件。三种模式对应不同的 `INSTALL_REGISTRY` 和
`INSTALL_ORCHESTRATION` 布尔标志组合：

| 参数 | INSTALL_REGISTRY | INSTALL_ORCHESTRATION | 说明 |
|------|-------------------|----------------------|------|
| `--all`（默认） | true | true | 同时安装 registry-center 和 orchestration-center |
| `--register` | true | false | 仅安装 registry-center |
| `--orchestrate` | false | true | 仅安装 orchestration-center |

所有模式相关的步骤（环境检查、下载、配置、启动）均通过这两个标志进行条件控制。

## Heredoc 拆分 (Heredoc Splitting)

当需要在静态 heredoc 文本中插入动态内容时，将一个 heredoc 拆分为多个段：
- 静态头部 heredoc（单引号分隔符，零变量展开）
- 动态中间段（使用 `echo` + 条件判断输出变量内容）
- 静态尾部 heredoc（单引号分隔符，零变量展开）

用于手动 LLM 命令输出中根据安装模式动态生成文件列表（见 ADR-002）。

## 手动 LLM 命令 (Manual LLM Command) — 已废弃

Step 3.5 结束时输出的 bash 命令片段，供用户随时重新配置 LLM（修改 model、url、api_key）。
无论用户是否跳过交互式 LLM 配置，该命令都会输出。文件列表根据安装模式动态生成：
`--all` 包含两个项目，`--register` 仅 registry-center，`--orchestrate` 仅 orchestration-center。

**已由 `configure_llm.sh` 替代**（见 ADR-005）。原 60 行 bash 片段被替换为
`configure_llm.sh` 的使用说明。

## PATH 不对称 (PATH Asymmetry)

脚本中 `run_sudo` 以 root 身份执行安装（root 的 PATH 包含 `/usr/sbin`），
但 `command -v` 验证以当前用户身份执行（非 root 的 PATH 不含 `/usr/sbin`），
导致安装成功但验证失败的假阴性。这是 `setup_nginx()` 中 nginx 验证误报的根因
（见 ADR-003）。

## /usr/sbin 目录 (sbin Directory)

Linux 系统管理类二进制的标准安装目录。Debian 策略将系统服务（如 nginx）安装到
`/usr/sbin`，该目录仅出现在 root 用户的默认 PATH 中，非 root 用户的 PATH 不包含。
这是 `command -v nginx` 在非 root 身份下失败的直接原因。

## find_nginx_binary()

nginx 二进制路径查找辅助函数。采用两级查找策略：
1. 先通过 `command -v nginx` 检查 PATH（覆盖 root 用户或 nginx 已在 PATH 中的情况）
2. 再依次检查 `/usr/sbin/nginx` 和 `/sbin/nginx` 是否存在且可执行

成功时 echo 二进制路径并返回 0，失败时返回 1。用于替代 `setup_nginx()` 中原有的
`command -v nginx` 调用，解决 PATH 不对称导致的假阴性问题（见 ADR-003）。

## VPS_IP

Summary 输出段中用于显示远程访问 URL 的 VPS 网卡 IP 变量。通过 `hostname -I`
获取第一个非回环 IP，失败时回退到 `localhost`。仅用于 frontend 和 nginx 两行的
URL 显示，其余服务保持 `127.0.0.1`（因 `--register` 模式无 nginx 代理，
直接显示内网地址更准确）（见 ADR-004）。

## 远程访问入口 (Remote Access Entry Point)

nginx 反向代理是 VPS 部署中唯一的远程访问入口。所有后端服务（registry-center、
orchestration backend、frontend、agents server）均绑定在 `127.0.0.1`，外部无法
直连。nginx 监听 `0.0.0.0:443`，通过路径前缀代理到各服务：
`/` → frontend、`/api/orchestrate/` → backend、`/registry/` → registry。
agents server 无 nginx 代理，远程不可访问（见 ADR-004）。

## hostname -I

Linux 命令，输出所有非回环网卡的 IP 地址（空格分隔）。与 `hostname -i`（仅输出
回环 IP 127.0.0.1）不同，`-I`（大写）返回实际网卡 IP。脚本中用 `awk '{print $1}'`
取第一个 IP 作为 VPS_IP，用 `2>/dev/null` 和 `|| VPS_IP=""` 防止 `set -e` 退出
（见 ADR-004）。

## configure_llm.sh

独立 LLM 配置脚本，从 `openan_install.sh` 中提取的 LLM 参数修改逻辑。通过 flag
接收参数（`--model`、`--url`、`--api-key`、`--project`、`--validate`/`--no-validate`），
替代了原 Step 3.5 中的手动 bash 命令输出段。支持从 `LLM_API_KEY` 环境变量读取
API key（避免 key 出现在 shell history 中）。基于脚本自身目录（SCRIPT_DIR）查找
`registry-center/` 和 `orchestration-center/` 项目目录（见 ADR-005）。

## Flag 传入 (Flag-based Input)

命令行参数传递方式，通过 `--flag value` 形式接收参数。`configure_llm.sh` 使用此
方式接收 model、url、api_key 等参数，替代了原手动命令中的 shell 变量赋值
（`MODEL="xxx"`）+ `for f in ... do ... done` 循环模式。优点：参数语义明确、
支持默认值、可由其他脚本程序化调用。

## API Key 环境变量回退 (API Key Env Var Fallback)

`configure_llm.sh` 的安全设计：`--api-key` flag 优先，未指定时从 `LLM_API_KEY`
环境变量读取。`openan_install.sh` 调用 `configure_llm.sh` 时不传 `--api-key` flag，
而是通过已 `export` 的 `LLM_API_KEY` 环境变量传递，避免 API key 出现在 `ps` 输出
和 shell history 中（见 ADR-005）。

## --project 标志 (--project Flag)

`configure_llm.sh` 的目标项目选择参数。可选值：`registry`（仅 registry-center）、
`orchestration`（仅 orchestration-center）、`all`（两者都更新，默认）。与
`openan_install.sh` 的安装模式映射：`--all` → `all`，`--register` → `registry`，
`--orchestrate` → `orchestration`。缺失项目目录时打印 `[WARN]` 并跳过（见 ADR-005）。

## venv 优先 Python 解析 (venv-first Python Resolution)

`configure_llm.sh` 的 Python 命令解析策略：先尝试项目 venv 中的 Python
（`registry-center/venv/bin/python` 或 `orchestration-center/venv/bin/python`），
未找到时回退到系统 `python3`。与 `openan_install.sh` 的 `resolve_python()` 不同：
后者面向安装阶段（需检测版本、自动安装），前者面向安装后运行（venv 已存在）。
`configure_llm.sh` 仅使用标准库 `json`，不依赖 venv 中的第三方包，回退到 `python3`
亦可正常工作（见 ADR-005）。
