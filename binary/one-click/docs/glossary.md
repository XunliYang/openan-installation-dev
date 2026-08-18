# 术语表 / Glossary

本术语表涵盖 `openan_install.sh` 和 `openan_uninstall.sh` 中涉及的自动安装机制、
安装模式、卸载策略及 PATH 查找相关术语。

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

脚本通过 `--reg` 和 `--orc` 两个命令行 flag 控制安装哪些组件，与 `configure_llm.sh`
的 flag 设计保持一致。两个 flag 对应不同的 `INSTALL_REGISTRY` 和 `INSTALL_ORCHESTRATION`
布尔标志组合：

| 参数 | INSTALL_REGISTRY | INSTALL_ORCHESTRATION | 说明 |
|------|-------------------|----------------------|------|
| `--reg --orc`（默认） | true | true | 同时安装 registry-center 和 orchestration-center |
| `--reg` | true | false | 仅安装 registry-center |
| `--orc` | false | true | 仅安装 orchestration-center |

两者均未指定时默认安装两者。所有模式相关的步骤（环境检查、下载、配置、启动）均通过这两个
标志进行条件控制。旧 flag `--all`/`--register`/`--orchestrate` 已移除，使用旧 flag 会
报错并提示使用 `--reg`/`--orc`（见 ADR-010）。

## Heredoc 拆分 (Heredoc Splitting)

当需要在静态 heredoc 文本中插入动态内容时，将一个 heredoc 拆分为多个段：
- 静态头部 heredoc（单引号分隔符，零变量展开）
- 动态中间段（使用 `echo` + 条件判断输出变量内容）
- 静态尾部 heredoc（单引号分隔符，零变量展开）

用于手动 LLM 命令输出中根据安装目标动态生成文件列表（见 ADR-002）。

## 手动 LLM 命令 (Manual LLM Command) — 已废弃

Step 3.5 结束时输出的 bash 命令片段，供用户随时重新配置 LLM（修改 model、url、api_key）。
无论用户是否跳过交互式 LLM 配置，该命令都会输出。文件列表根据安装目标动态生成：
`--reg --orc` 包含两个项目，`--reg` 仅 registry-center，`--orc` 仅 orchestration-center。

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
获取第一个非回环 IP，失败时回退到 `localhost`。仅用于 nginx 行的
URL 显示，其余服务保持 `127.0.0.1`（因仅 `--reg` 模式无 nginx 代理，
直接显示内网地址更准确）（见 ADR-004）。

## 远程访问入口 (Remote Access Entry Point)

nginx 反向代理是 VPS 部署中唯一的远程访问入口。所有后端服务（registry-center、
orchestration backend、agents server）均绑定在 `127.0.0.1`，外部无法
直连。nginx 监听 `0.0.0.0:443`，通过路径前缀代理到各服务：
`/` → 前端静态文件（dist 目录）、`/api/orchestrate/` → backend、`/registry/` → registry。
agents server 无 nginx 代理，远程不可访问（见 ADR-004、ADR-014）。

## hostname -I

Linux 命令，输出所有非回环网卡的 IP 地址（空格分隔）。与 `hostname -i`（仅输出
回环 IP 127.0.0.1）不同，`-I`（大写）返回实际网卡 IP。脚本中用 `awk '{print $1}'`
取第一个 IP 作为 VPS_IP，用 `2>/dev/null` 和 `|| VPS_IP=""` 防止 `set -e` 退出
（见 ADR-004）。

## configure_llm.sh

独立 LLM 配置脚本，从 `openan_install.sh` 中提取的 LLM 参数修改逻辑。通过 flag
接收参数（`--reg`、`--orc`、`--model`、`--url`、`--api-key`、`--validate`/`--no-validate`），
支持交互式和非交互式两种模式。当 `--model`/`--url`/`--api-key` 任意一个缺失时自动进入
交互模式；`--reg --orc` 同时指定时支持分开询问 registry 和 orchestration 的 LLM 配置
并提供复用选项。脚本在询问用户或验证 LLM 之前，先预检每个目标项目的 `llm_config.json`
是否存在，文件缺失的项目直接跳过，避免浪费用户输入和网络验证（见 ADR-005、ADR-010、ADR-012）。
交互模式下用户未提供任何配置（全空输入）时视为跳过，`exit 0` 而非 `exit 1`（见 ADR-013）。

## Flag 传入 (Flag-based Input)

命令行参数传递方式，通过 `--flag value` 形式接收参数。`configure_llm.sh` 使用此
方式接收 model、url、api_key 等参数，替代了原手动命令中的 shell 变量赋值
（`MODEL="xxx"`）+ `for f in ... do ... done` 循环模式。优点：参数语义明确、
支持默认值、可由其他脚本程序化调用。

## API Key 环境变量回退 (API Key Env Var Fallback)

`configure_llm.sh` 的安全设计：`--api-key` flag 优先，未指定时从 `LLM_API_KEY`
环境变量读取。在非交互模式下，环境变量作为 API key 来源；在交互模式下，环境变量的值
作为提示中的默认值（显示 `[***]`），用户可直接回车采用或输入新值。避免 API key 出现在
`ps` 输出和 shell history 中（见 ADR-005、ADR-010）。

## --reg/--orc 标志 (--reg/--orc Flags)

`configure_llm.sh` 和 `openan_install.sh` 共同使用的目标项目选择参数（ADR-010）。`--reg`
配置 registry-center，`--orc` 配置 orchestration-center，同时指定时配置两者，两者均未
指定时默认配置两者。两个脚本的 flag 语义完全一致，`openan_install.sh` 直接将安装 flag
传递给 `configure_llm.sh`。缺失项目配置文件时在 Step 0 预检阶段打印 `[WARN]` 并跳过
（见 ADR-005、ADR-010、ADR-012）。

## 配置文件预检 (Config File Pre-check)

`configure_llm.sh` 的 Step 0 预检机制（ADR-012）。在参数解析和 `SCRIPT_DIR` 解析之后、
Python 解析和任何用户交互之前，对每个 `DO_REGISTRY`/`DO_ORCHESTRATION` 为 true 的项目
检查 `llm_config.json` 是否存在。文件不存在的项目打印 `[WARN]` 并设置 `DO_* = false`
（跳过该项目的交互询问和验证）。两个项目都被跳过时立即打印 `[ERROR]` 并 `exit 1`。
预检同时覆盖交互模式（避免浪费用户输入）和非交互模式（避免浪费网络验证请求）。
`write_config()` 函数内部的文件存在性检查保留作为 defense-in-depth。

## 交互模式自动触发 (Interactive Mode Auto-trigger)

`configure_llm.sh` 的模式选择机制：当 `--model`、`--url`、`--api-key` 三个参数中任意
一个未提供（且 `LLM_API_KEY` 环境变量也未设置时），自动进入交互模式。已提供的参数作为
交互提示中的默认值。三个参数全部提供时走非交互模式（同值写入所有目标项目，与原 `--project`
行为一致）（见 ADR-010）。

## 分开询问与复用选项 (Split Asking with Reuse Option)

`configure_llm.sh` 交互模式下 `--reg --orc` 的配置流程：先询问 registry 的
model/url/api_key 并验证，然后提示 "Use same LLM config for orchestration? [Y/n]"。
选择 Y 则复用 registry 的全部值（model + url + api_key）；选择 n 则重新输入
orchestration 的配置。registry 验证失败时询问是否继续配置 orchestration。此流程使
两个项目可配置不同的 LLM 参数（见 ADR-010）。

## 逐项目验证 (Per-project Validation)

`configure_llm.sh` 交互模式下的验证策略：每个项目的 LLM 配置独立验证（发送测试请求
到 LLM API）。验证失败时允许重新输入或输入 `skip` 跳过验证。registry 验证失败不影响
orchestration 的配置流程（用户可选择继续）。复用配置时也会验证（同一 API 端点，结果
应一致）（见 ADR-010）。

## read_masked 掩码输入 (Masked Input)

从 `openan_install.sh` 复制到 `configure_llm.sh` 的函数，用于交互模式下安全输入
API key。读取 `/dev/tty`，每输入一个字符显示一个 `*`，支持退格。在 ADR-010 中，
此函数不再在两个脚本中各存一份——`openan_install.sh` 的 Step 3.5 已删除自身的
`read_masked` 副本，委托给 `configure_llm.sh` 处理全部交互逻辑（见 ADR-010）。

## venv 优先 Python 解析 (venv-first Python Resolution)

`configure_llm.sh` 的 Python 命令解析策略：先尝试项目 venv 中的 Python
（`registry-center/venv/bin/python` 或 `orchestration-center/venv/bin/python`），
未找到时回退到系统 `python3`。与 `openan_install.sh` 的 `resolve_python()` 不同：
后者面向安装阶段（需检测版本、自动安装），前者面向安装后运行（venv 已存在）。
`configure_llm.sh` 仅使用标准库 `json`，不依赖 venv 中的第三方包，回退到 `python3`
亦可正常工作（见 ADR-005）。

## Agent Card

Agent 的元数据描述符，遵循 TM Forum A2A-T 协议规范。以 JSON 格式存储于
registry-center 中，包含 agent 的名称、描述、服务端点 URL、能力声明（capabilities）、
技能列表（skills）、提供者信息等。registry-center 提供 REST API
（`/rest/v1/registry-center/agent-cards`）用于 agent card 的注册（POST）、
查询（GET）、删除（DELETE）。前端页面的 registry center 视图展示的就是已注册的
agent card 列表（见 ADR-006）。

## Assurance Agent

OpenAN 平台的电信保障场景 A2A Agent，随 orchestration-center v1.0.0
源码分发。其 agent card 定义位于 `orchestration-center/samples/agentcard/
assurance_agent.json`，描述为"负责保障策略及其恢复策略的生成"。具备两个技能：
`strategy-generation`（将赛事保障需求转换为网络需求）和 `recovery-delivery`
（恢复保障前网络配置）。provider 为 Huawei，遵循 TM Forum A2A-T 电信扩展协议
（Task-T、NEGOTIATION-T、DATA-NEGOTIATION-T）。

> **修正 (ADR-009)**：Assurance Agent 由 `samples.start_agents_server` 启动
> （端口 8902），**仅在 `--sample` 模式下运行**。原 ADR-006 声称由
> `orchestrate.start` 内部启动，该结论已被证伪。详见 ADR-006 修正记录。

## 端口 8902 (Port 8902)

Assurance Agent 的 A2A 服务端点端口。由 `python -m samples.start_agents_server`
启动，监听于 `127.0.0.1:8902`，采用 HTTP+JSON 协议绑定。是 11 个示例 agent
端口之一（见"Sample Agent 端口集群"）。

> **修正 (ADR-009)**：原 ADR-006 声称此端口由 `orchestrate.start` 内部启动，
> 该结论已被证伪。8902 实际由 `samples.start_agents_server` 启动，受 `--sample`
> flag 控制。此端口不在 `openan_install.sh` 的 Summary 输出中，Nginx 配置中
> 亦无代理规则，仅本地可访问。

## Agent Card 自注册 (Agent Card Self-Registration)

> **修正 (ADR-009)**：原 ADR-006 声称此行为由 `orchestrate.start` 完成，
> 该结论已被证伪。Agent Card 注册实际由 `samples.start_agents_server` 完成。

`samples.start_agents_server` 启动时的行为：
1. 启动 11 个示例 A2A Agent 端点（ports 8899-8907, 26335, 26336）
2. 读取种子 agent card JSON 文件（`samples/agentcard/*.json`）
3. 通过 `AGENT_REGISTRY_URL` 向 registry-center POST 注册全部 11 个 agent card

此行为仅在 `--sample` 模式下发生。注册后 registry-center 将 agent card
持久化到 `data/agentcard.json`（file 存储模式）（见 ADR-006 修正记录、ADR-009）。

## 种子 Agent Card (Seed Agent Card)

随组件源码分发的静态 agent card JSON 文件，位于 `orchestration-center/samples/
agentcard/` 目录。包含 11 个 agent 的 card 定义（如 `assurance_agent.json`、
`ran_energy_saving_agent.json` 等）。由 `samples.start_agents_server` 读取
并向 registry-center 注册，仅在 `--sample` 模式下触发
（见 ADR-006 修正记录、ADR-009）。

## --sample 与示例 Agent 的关系 (--sample and Sample Agents)

> **修正 (ADR-009)**：原 ADR-006 声称存在"内嵌 Agent"（不受 `--sample` 控制），
> 该结论已被证伪。所有 11 个示例 agent（含 Assurance Agent）均由
> `samples.start_agents_server` 启动，受 `--sample` flag 控制。

`--sample` flag 控制 `samples.start_agents_server` 的启动，该进程启动后：
- 在端口 8080 提供管理端点
- 在端口 8899-8907、26335、26336 启动 11 个示例 A2A Agent
- 向 registry-center 注册全部 11 个 agent card

不带 `--sample` 时，**没有任何示例 agent 启动**，registry-center 中不应出现
agent card（除非有残留数据文件，见"Agent Card 数据残留"）（见 ADR-009）。

## Agent Card 数据残留 (Agent Card Data Residue)

registry-center 在 file 存储模式下将 agent card 持久化到 `data/agentcard.json`。

> **修正 (ADR-009)**：ADR-006 原来决定不清理 `data/` 目录，该决定已被推翻。
> 自 ADR-009 起，`openan_install.sh` Step 2 在 `agent_registry.init` 之前自动清理
> `data/` 目录，消除残留数据导致的 404 问题。

**残留导致 404 的机制**：上一次以 `--sample` 运行时，11 个 agent 注册到
registry-center 并持久化。再次运行（不带 `--sample`）时，`data/agentcard.json`
未被清理，registry-center 加载残留的 agent card。`orchestrate.start` 从
registry-center 拿到 agent card（HTTP 200），但 card 中的 URL 指向的 agent 端点
（8899-8907 等）未启动，handler 返回 404。

**修复**：Step 2 在 `agent_registry.init` 之前执行 `rm -rf data/`，确保每次
安装都是干净状态。带有 `--sample` 运行时会自动重新注册全部 11 个 agent
（见 ADR-006 修正记录、ADR-009）。

## free_port() 端口覆盖范围 (free_port Coverage)

`openan_install.sh` 中的 `free_port()` 函数（lines 718-735）在启动服务前清理被占用的
端口。自 ADR-014 起覆盖 15 个端口：5000、5001、443、8080、**8899-8907、26335、
26336**。ADR-008 新增了 8902 的清理（基于错误前提，已被 ADR-009 修正），ADR-009
将范围扩展到全部 11 个 sample agent 端口。`free_port()` 采用无差别 kill（不检查
cmdline），与卸载脚本的智能识别不同——安装场景中端口上的进程几乎都是 OpenAN
自己的残留进程（见 ADR-008、ADR-009）。

## openan_uninstall.sh

OpenAN 卸载脚本，与 `openan_install.sh` 对称。清理安装脚本创建的项目文件、进程和
nginx 配置，保留环境工具（Python、Node.js、npm、nginx 二进制）。支持 `--force` 跳过
交互式确认。设计决策见 ADR-007。

## 智能进程识别 (Smart Process Identification)

卸载脚本在 kill 端口上的进程前，检查进程命令行是否匹配**任意** OpenAN 已知模式
（全局 pattern 集合：`agent_registry|orchestrate|samples`）。匹配任意一个即 kill，
全部不匹配才打印 `[WARN]` 并跳过，避免误杀用户在相同端口上运行的非 OpenAN 服务。
与安装脚本的 `free_port()` 无差别 kill 不同——卸载场景中用户可能已将端口挪作他用
（见 ADR-007、ADR-008）。

## 环境保留策略 (Environment Preservation)

卸载脚本的核心设计原则：删除 OpenAN 项目文件和配置，但保留环境工具
（Python、Node.js、npm、nginx 二进制、openssl）及安装脚本下载的 standalone 环境
目录（`.python3.12/`、`.node/`）。这样用户重新运行 `openan_install.sh` 时可跳过
环境安装步骤，加速重装流程（见 ADR-007）。

## 容错卸载 (Fault-tolerant Uninstallation)

卸载脚本使用 `set -uo pipefail`（不含 `-e`），单步失败不中断，继续执行后续步骤
并在 Summary 中汇总结果。与安装脚本的 `set -euo pipefail`（任一步失败即中止）
不同——卸载脚本的设计目标是"尽可能多清理"，即使部分文件已不存在或部分进程
已终止，也能完成剩余清理工作（见 ADR-007）。

## 跨端口进程逃逸 (Cross-port Process Escape)

卸载脚本中的一种进程逃逸现象：一个多端口 OpenAN 进程（如 `samples.start_agents_server`，
同时关联 12 个端口：8080 管理端口 + 11 个 agent 端口）在所有端口上的 pattern
匹配均失败，导致进程永远不会被杀死。根因是 ADR-007 的"每端口单一 pattern"设计
无法处理跨端口进程。ADR-008 通过全局 pattern 匹配修复了 pattern 失效问题，
但仅覆盖 8902 一个端口，遗留 9 个端口未扫描。ADR-009 将端口覆盖扩展到全部
11 个 sample agent 端口，彻底消除逃逸（见 ADR-008、ADR-009）。

## 全局 Pattern 匹配 (Global Pattern Matching)

ADR-008 引入的卸载脚本进程识别策略。定义全局 OpenAN pattern 集合
（`OPENAN_PATTERNS="agent_registry|orchestrate|samples"`），对每个端口上发现
的进程，检查其 cmdline 是否匹配任意一个 pattern（`grep -qE`）。匹配任意一个即 kill，
全部不匹配才跳过。替代了 ADR-007 的"每端口单一 pattern"设计，消除跨端口进程逃逸
问题（见 ADR-008）。

## fuser 误报 (fuser False Positive)

`fuser PORT/tcp` 返回所有与端口关联的进程，包括 listener 和 client 连接。当 OpenAN
进程（如 `start_agents_server`）作为 client 连接到另一个 OpenAN 服务（如
registry-center port 5000）时，`fuser` 会将其误报为端口占用者，触发不必要的
pattern 检查和 WARN 日志。ADR-008 将 `find_pids_on_port` 的优先级改为
`ss -tlnp` → `lsof -sTCP:LISTEN` → `fuser`，前两者仅返回 listener，避免 client 误报
（见 ADR-008）。

## 卸载端口覆盖范围 (Uninstall Port Coverage)

`openan_uninstall.sh` 自 ADR-014 起覆盖 14 个端口：5000、5001、8080、
8899-8907、26335、26336。443 由 nginx 停止逻辑单独处理。
`samples.start_agents_server` 是单进程多端口（12 个端口），在任意一个端口上发现并
kill 即可终止全部端口监听。扩展端口范围确保该进程在所有端口上都能被发现
（见 ADR-007、ADR-008、ADR-009）。

## Sample Agent 端口集群 (Sample Agent Port Cluster)

`python -m samples.start_agents_server` 启动的 11 个示例 A2A Agent 的端口集合。
由**同一个 Python 进程**监听全部 11 个端口，加上管理端口 8080 共 12 个端口。

| 端口 | Agent 名称 | Seed 文件 |
|------|-----------|----------|
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

端口 26335 和 26336 模拟真实运维平台的端口分配。全部 11 个 agent 的 seed JSON
文件位于 `orchestration-center/samples/agentcard/` 目录。仅在 `--sample` 模式下
启动（见 ADR-009）。

## 管理端口 8080 (Management Port 8080)

`samples.start_agents_server` 的管理/入口端口。与 11 个 agent 端口（8899-8907、
26335、26336）同属一个 Python 进程。`openan_install.sh` 的 Summary 输出中将其
标注为 "agents examples server"。Nginx 配置中无 8080 的代理规则，仅本地可访问
（见 ADR-009）。

## 单进程多端口 (Single Process Multi-Port)

`samples.start_agents_server` 的进程模型：一个 Python 进程同时监听 12 个端口
（8080 + 11 个 agent 端口）。这意味着：
- kill 主进程 PID 即可终止全部 12 个端口的监听
- 在任意一个端口上发现进程并 kill，等效于 kill 主进程
- 卸载脚本扩展端口覆盖范围后，`samples` pattern 在任意一个端口上匹配即可完成清理

与多进程模型（每个 agent 独立进程）不同，单进程模型下不需要逐端口 kill
（见 ADR-009）。

## 架构归一化 (Architecture Normalization)

离线 setup/install 脚本中的 CPU 架构检测与标准化逻辑。`uname -m` 在不同 Linux
发行版上可能返回不同字符串表示同一架构：`x86_64` / `amd64` 均指 x86-64 架构，
`aarch64` / `arm64` 均指 ARM 64 架构。脚本通过 case 语句将多种别名归一化为
标准值 `x86_64` 或 `aarch64`，用于后续 wheels 匹配。不支持的架构直接报错退出
（见 ADR-011）。

## 双架构 Wheels (Dual-arch Wheels)

离线打包策略：一个离线包内同时包含 x86_64 和 aarch64 两种架构的 Python wheel
包，混放在同一个 `wheels/` 目录中。pip 的 `--find-links` 会根据当前架构自动
选择匹配的 wheel（通过文件名中的平台标签如 `manylinux_2_34_x86_64` 或
`manylinux_2_34_aarch64` 区分），同名不同架构的 wheel 可共存。pure-Python
wheel（平台标签 `any`）只下载一份，两种架构共用。打包机自身架构无关——
`pip download --platform` 在任意架构的机器上均可下载任意目标架构的 wheels
（见 ADR-011）。

## 纯 Wheel 策略 (Wheel-only Strategy)

离线打包策略：联网机器上不构建 Python venv，只用 `pip download --platform`
下载 wheel 包；离线机器上从 wheels 本地构建 venv（`pip install --no-index
--find-links wheels/`）。与 pre-built venv 策略（在联网机器上构建好 venv 直接
打包）不同，纯 wheel 策略的 venv 在离线机器上本地构建，架构和 Python 版本
自然匹配，不存在跨架构或版本不兼容问题。registry-center 原本即采用此策略，
orchestration-center 自 ADR-011 起也从 pre-built venv 改为纯 wheel 策略
（见 ADR-011）。

## 空配置跳过 (Empty Config Skip)

`configure_llm.sh` 交互模式下的行为分类机制（ADR-013）。当用户在交互模式中
未提供任何配置（model、url、api_key 全部为空），导致 `SUCCESS_COUNT == 0` 且
`FAIL_COUNT == 0` 时，脚本将此场景归类为"跳过"而非"错误"：打印 `[SKIP]` 消息
并 `exit 0`，使调用方（`openan_install.sh`）的安装流程不被中断。与"写入失败"
（`FAIL_COUNT > 0`，仍 `exit 1`）区分。Summary 标题在此场景下从
`LLM configuration complete` 改为 `LLM configuration skipped`。非交互模式不受影响
（缺少参数时自动进入交互模式）。

## 静态文件服务模式 (Static File Serving Mode)

orchestration-center 前端的部署方式（ADR-014）。在安装阶段执行 `npm run build`
将 Vue 源码编译为纯静态文件（HTML/JS/CSS），产出在 `workflow-designer/dist/`
目录。nginx 通过 `root` 指令直接服务该目录，`location /` 不再 `proxy_pass`
到 Vite dev server。与原先的 dev 模式（`npm run dev` 后台常驻 Vite 进程）
相比：减少一个常驻进程、nginx 配置更简洁、首次加载更快，但失去 HMR 热更新
能力（见 ADR-014）。

## SPA 路由回退 (SPA Route Fallback)

nginx 静态文件服务中的 `try_files` 指令配置（ADR-014）：
`try_files $uri $uri/ /index.html`。workflow-designer 是 Vue 单页应用，
前端路由如 `/workflow-designer/edit/123` 是客户端路由，磁盘上无对应文件。
该指令让 nginx 在找不到匹配文件时回退到 `index.html`，由 Vue Router 接管
路由。缺少此配置会导致刷新非根路径页面时返回 404（见 ADR-014）。

## 构建时依赖 (Build-time Dependency)

Node.js 在 ADR-014 后的角色变化。安装阶段需要 Node.js 执行 `npm install`
和 `npm run build`，但安装完成后不再需要 Node.js 进程常驻运行（前端以
静态文件形式由 nginx 服务）。与原先的"运行时依赖"（Vite dev server
需要 Node.js 持续运行）不同。`resolve_node()` 仍在 Step 0 自动安装
Node.js，但仅用于构建阶段（见 ADR-014）。

## dist 目录 (dist Directory)

`npm run build` 产出的前端静态文件目录，位于
`orchestration-center/workflow-designer/dist/`。包含 `index.html`、
`assets/`（编译后的 JS/CSS 包，文件名含内容哈希）等文件。安装时复制到
`/var/www/openan/`（系统目录），nginx 配置中 `location /` 的 `root` 指令指向
`/var/www/openan`。不直接指向项目内 dist 的原因是：nginx worker 进程以
`www-data` 用户运行，无法穿越用户 home 目录（权限 750/700）读取 dist 文件，
导致 Permission denied（500）。卸载时通过 `rm -rf /var/www/openan` 清理
（见 ADR-014）。

## 源码 Tarball 下载 (Source Tarball Download)

pack 脚本（`pack_reg.sh`、`pack_orc.sh`）获取应用源码的方式（ADR-016）。从 GitHub
release 下载源码 tarball（`https://github.com/project-openan/{component}/archive/
refs/tags/v1.0.0.tar.gz`），用 `curl -fsSL` 下载、`tar --strip-components=1` 解压
到打包目录。与 `openan_install.sh` Step 1 的源码下载模式完全一致。替代了原先
假设源码已存在于本地（`ROOT_DIR/`）的 `cp -r` 复制方式。每次打包都重新下载，
不缓存源码。

## ROOT_DIR 去源码化 (ROOT_DIR Decoupling)

ADR-016 中对 pack 脚本 `ROOT_DIR` 变量的重构。原设计中 `ROOT_DIR = SCRIPT_DIR/..`
被用作应用源码根目录，pack 脚本通过 `cp -r "${ROOT_DIR}/agent_registry"` 等命令
复制源码。但部署仓库（`openan-deployment`）的 `binary/` 目录不包含应用源码，
导致 `cp: cannot stat` 错误。ADR-016 移除了 `ROOT_DIR` 变量，源码改为从 GitHub
tarball 下载，`ROOT_DIR` 的其他用途（默认输出目录、tarball 输出路径、cd 回原目录）
替换为 `SCRIPT_DIR`。

## 部署仓库与应用仓库分离 (Deployment/App Repo Separation)

`openan-deployment` 仓库是部署专用仓库，仅包含部署脚本（`one-click/`、
`orchestration-center/`、`registry-center/`）。应用源码托管在独立的 GitHub
仓库中：`project-openan/registry-center` 和 `project-openan/orchestration-center`。
pack 脚本和 one-click 安装脚本都需要从 GitHub 下载应用源码 tarball，不能假设
源码已存在于部署仓库本地。此分离是 ADR-016 中 pack 脚本改为 tarball 下载的
根本原因。

## 临时打包 Venv (Temporary Packaging Venv)

`pack_reg.sh` 中用于 `pip download` 的临时虚拟环境（ADR-016）。创建在
`mktemp -d /tmp/pack-reg-venv-XXXXXX` 中，脚本退出时通过 `trap` 自动清理。
替代了原先创建在 `ROOT_DIR/.venv` 中的持久化 venv（需要“已存在则重建”逻辑）。
临时 venv 每次都是干净的，不存在状态残留问题。`pack_orc.sh` 的打包 venv
位于 `BUILD_DIR/.packaging-venv`，随 `BUILD_DIR` 一起在每次打包时清理。

## 第三方 LLM 引用移除 (Third-party LLM Reference Removal)

README 文档与 `configure_llm.sh` 脚本同步去厂商化的过程（ADR-017）。脚本中
`DEFAULT_LLM_MODEL` 和 `DEFAULT_LLM_URL` 已为空字符串（注释标注 "No third-party
defaults"），但 README 仍残留阿里云通义千问（`qwen3.6-flash`、
`dashscope.aliyuncs.com`）和智谱 GLM（`glm-5.1`、`open.bigmodel.cn`）等
第三方厂商的模型名、API URL 和提供商表格。ADR-017 将 README 中的交互提示
默认值方括号移除、"常见选择"/"Common choices" 表改为通用占位符表（
`<model-name>`、`<api-url>`）、命令示例统一为占位符风格、"建议使用"块整块
删除，使文档与脚本行为完全一致。此变更属于脚本层面去厂商化规范（见开发实践
规范"移除第三方依赖引用规范"）在文档层面的同步延伸。
