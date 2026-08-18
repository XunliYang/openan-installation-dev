# ADR-019: 离线包命名统一与 tarball 顶层目录检测

## 状态

已采纳 (Accepted) — 2026-08-18

## 背景

### 问题

`pack_orc.sh` 打包出的 tarball 文件名与其包内顶层目录名不一致：

- Tarball 文件名：`orchestration-center-offline-bundle.tar.gz`
  （`TARBALL="${SCRIPT_DIR}/${BUNDLE_NAME}-bundle.tar.gz"`，`BUNDLE_NAME=orchestration-center-offline`）
- 包内顶层目录名：`orchestration-center-offline`
  （`BUNDLE_DIR="${BUILD_DIR}/${BUNDLE_NAME}"`）

安装脚本（`install_orc.sh`、`install_reg.sh`）用文件名推断解压后目录：

```bash
PKG_NAME=$(basename "$TARBALL" .tar.gz)      # → orchestration-center-offline-bundle
EXTRACT_DIR="${SCRIPT_DIR}/${PKG_NAME}"      # 期望目录
tar -xzf "$TARBALL" -C "$SCRIPT_DIR"         # 实际解压出 orchestration-center-offline
```

`EXTRACT_DIR` 指向不存在的目录，之后 `cd "$ROOT_DIR"`、wheels/venv 路径全部失效，
安装在中途失败。README 第二阶段还带着"解压后 `cd orchestration-center-offline`
再运行 `./install_orc.sh`"的手动步骤（`./start.sh` 亦不存在），与实际包内目录名
同样不匹配。

### 相关性发现

排查时发现三处独立问题叠加，需一并修复：

1. **命名双轨**：文件名后缀 `-bundle`，包内目录名不含后缀——双名不一致是根因。
2. **install 以文件名推断目录**：`basename` 推断在"文件名 == 包内目录名"时恰好
   正确，一旦命名变化即静默指向错误路径（改包侧命名后旧 install 立刻坏掉）。
3. **产物目录不统一**：`pack_reg.sh` 默认输出到 `dist/`，`pack_orc.sh` 输出到
   脚本目录；`install_orc.sh` 的搜索顺序（脚本目录优先、dist/ 兜底）也与 pack
   默认方向相反。
4. **README/manifest 与脚本行为脱节**：文档仍描述"手动解压 + 进包内运行"的旧模式，
   与 install 脚本"自动解压安装"的实际行为不符；参数表含脚本不支持的
   `--dir`/`--service`/`--no-service`。

## 决策

### 1. pack 侧命名统一：文件名 == 包内顶层目录名

`BUNDLE_NAME` 统一为 `orchestration-center-offline-bundle`。`BUNDLE_DIR` 与
`TARBALL` 均由此派生，tarball 文件名与包内顶层目录名恒等，消除双名不一致的根因。

### 2. tarball 输出统一到 dist/ 目录

`pack_orc.sh` 新增 `OUTPUT_DIR="${SCRIPT_DIR}/dist"`，tarball 输出到
`dist/orchestration-center-offline-bundle.tar.gz`，与 `pack_reg.sh` 既有行为
对齐。产物与源码/脚本分离：git 卫生（dist/ 可加入 .gitignore）、`rm -rf dist`
一键重建、多版本 tarball 并存不污染脚本目录。

### 3. install 侧以 tar -tzf 解析真实顶层目录

删除 `PKG_NAME=$(basename ...)` 推断，改为直接从 tarball 读出真实顶层目录：

```bash
TOP_LEVELS=$(tar -tzf "$TARBALL" | cut -d/ -f1 | sort -u)
TOP_LEVEL_COUNT=$(echo "${TOP_LEVELS}" | sed '/^$/d' | wc -l)
# 非 1 即报错退出（列出找到的顶层项）
EXTRACT_DIR="${SCRIPT_DIR}/${TOP_LEVELS}"
```

配以单顶层目录校验（恰好一个才继续），杜绝"文件名猜目录名"的脆弱依赖。
`install_orc.sh` 搜索顺序同步改为 dist/ 优先、脚本目录兜底，兼容新旧两种摆放方式。

### 4. README 与 manifest 改外层包装模式

中英文 README 第二阶段与 `OFFLINE_BUNDLE_MANIFEST.txt` 安装说明统一为：
将 `install_orc.sh` 与离线包放在同一目录，直接运行 `./install_orc.sh`（脚本自动
完成解压 → 检测架构 → 创建 venv → 本地 wheels 安装依赖 → 构建前端 → 配置
nginx HTTPS → 启动服务）。删除"手动解压 + cd 进包内"的 6 步说明与不存在的
`--dir`/`--service`/`--no-service` 参数表。

### 5. install_reg.sh 同步加固

`pack_reg.sh` 产出的 tarball 命名与包内目录名本已一致，仍将 `install_reg.sh`
的目录推导替换为同样的 tar -tzf 解析 + 单顶层校验，两脚本防御能力对齐
（未来任一 pack 脚本再改命名都不会破坏 install）。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| 仅改 pack 侧命名（-bundle 放回 BUNDLE_NAME）| 改动最小 | install 仍以 basename 推断目录，未来命名再变仍然坏 | 推断式是脆弱依赖，未根治 |
| 仅改 install 侧：`PKG_NAME=${BUNDLE_NAME/bundle/}` 之类的字符串修正 | 无需改 pack | 双名状态保留，改动靠硬编码补丁匹配 | 命名双轨本身才是可维护性负担 |
| README 继续让用户手动解压（改回目录名）| 不改脚本 | 与"一条命令安装"的 install 行为矛盾；用户多一步手工操作，出错面大 | ADR 评审决定 install 脚本即入口，文档跟随脚本 |
| install 支持 `--dir=PATH` 覆盖目录 | 用户可自选 | 脚本无此参数，文档长期虚构；扩大接口面 | 无需求驱动，仅删除文档即可对齐 |

## 后果

- **正面**：tarball 文件名与包内顶层目录名恒定一致，安装路径 `EXTRACT_DIR`
  永远来自 tarball 真实内容而非文件名猜测。
- **正面**：旧 tarball（含 `orchestration-center-offline` 目录或旧文件名）也能被
  新 install 正确解压——解析逻辑与文件名无关，dist/ 与脚本目录双搜索覆盖两种摆放。
- **正面**：两组件产物目录对齐（dist/），find/搜索顺序统一为 dist/ 优先。
- **正面**：文档、manifest、脚本行为三处一致，用户不再需要手动解压。
- **负面**：脚本目录内残留的旧版 tarball 不会被搜索到（只在 dist/ 找不到时兜底
  才搜脚本目录）——属预期，旧产物应移至 dist/ 或删除。
- **负面**：`--dir`/`--service`/`--no-service` 参数说明删除后，如果未来真要支持
  自定义安装目录，需重新设计并经 ADR 记录。

## 关联

- `binary/orchestration-center/pack_orc.sh` — BUNDLE_NAME 统一、输出到 dist/、manifest 改外层包装模式
- `binary/orchestration-center/install_orc.sh` — 搜索 dist/ 优先、tar -tzf 解析顶层目录 + 单顶层校验
- `binary/registry-center/install_reg.sh` — 同样的顶层目录解析与校验加固
- `binary/orchestration-center/README.md` — 中英两节第二阶段改外层包装模式、参数表对齐
- `binary/one-click/docs/glossary.md` — 新增术语：顶层目录解析、外层包装安装器、打包产物 dist 目录
- `binary/one-click/docs/ADR-014-frontend-static-serving.md` — 前端 build 产物 dist/ 的背景（注意与打包输出 dist/ 区分）