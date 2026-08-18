# ADR-018: Pack 脚本移除 --platform any 通道并消除下载吞错

## 状态

已采纳 (Accepted) — 2026-08-18

## 背景

### 问题

运行 `pack_orc.sh` 时控制台出现：

```
ERROR: Could not find a version that satisfies the requirement PyYAML>=6.0.3 (from versions: none)
ERROR: No matching distribution found for PyYAML>=6.0.3
```

`orchestration-center` 的 requirements.txt（GitHub 源码）指定 `PyYAML>=6.0.3`，
两条错误消息均被 `|| true` 静默吞掉，打包仍"成功"结束，问题延后到离线安装阶段才能暴露。

### 初步假设（已被实证推翻）

用户最初假设：PyYAML 6.0.3 使用 PEP 600 压缩多标签文件名
（`pyyaml-6.0.3-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl`），
pip download 的 `--platform` 标签匹配机制无法识别这种格式，导致 wheel 未下载。

实证结果（pip 23.2.1 与 26.1.2，Python 3.14 打包机，完整 x86_64 平台列表）：
压缩多标签匹配正常，PyYAML 6.0.3 wheel 成功下载。该假设不成立。

### 真实根因

1. **`--platform any` 冗余通道必然失败**：pack 脚本 Step 3 有第三个下载通道，
   用 `--platform any` 尝试下载纯 Python wheel。但 `--only-binary=:all:` 意味着
   PyYAML 这类 C 扩展包必须在**二进制平台通道**下载（它没有 `py3-none-any` wheel），
   `--platform any` 从存在起就必然解析失败。用户看到的错误消息即来自这个通道。
2. **pip 整批解析机制放大为误导性错误**：pip 对 `-r requirements.txt` 整批解析，
   任一需求解析失败 → 整条命令失败 → **一个文件都不写盘**。因此该通道每次运行
   都打印完整错误并零产出，看起来像"离线包缺 PyYAML"。
3. **`|| true` 静默吞错**：三个下载通道全部以 `2>&1 | sed 's/^/  /' || true`
   结尾，真实下载失败（网络断、依赖缺失、平台无 wheel）被静默消化，打包照常退出 0。
4. **`WHEEL_COUNT > 0` 检查无法验证依赖完整性**：只能证明目录里有 wheel 文件，
   无法证明 requirements.txt 的全部依赖都被覆盖。

### 波及范围（与初步判断不同）

- `pack_reg.sh` 有**完全相同**的 `--platform any` 通道骨架和 `|| true` 吞错问题，
  其 requirements.txt 含 `pyyaml>=6.0`、`cryptography`、`psycopg2-binary` 等
  二进制包，同样会打印误导性错误——并非用户最初判断的"仅影响 pack_orc.sh"。
- `openan_install.sh`（在线安装）直接用 venv pip install，无此问题。
- 离线包**不缺 PyYAML**：实证中二进制通道成功下载 67 个 wheel，覆盖全部
  15 个直接依赖（含 PyYAML）。

## 决策

### 1. 删除 `--platform any` 下载通道

`py3-none-any` 的纯 Python wheel 会匹配**任意** `--platform`，因此二进制平台
通道（`manylinux_2_34_*` 等）已经顺带下载全部纯 Python wheel。`--platform any`
通道既是死代码（零产出）又是噪音来源（必然报错），直接删除。

### 2. 移除 `|| true`，下载失败即退出

`set -euo pipefail` 配合 `set -o pipefail`，pip download 管道内任一步失败都会
传播非零退出码，脚本立即中止。错误在**打包阶段**暴露而非延后到安装阶段。
保留 `2>&1 | sed 's/^/  /'` 缩进格式，通过注释说明为何此处无 `|| true`。

### 3. 两脚本同步修复

`pack_orc.sh` 与 `pack_reg.sh` 同步删除 any 通道、移除 `|| true`。

### 4. pack_reg.sh 补充 pip 升级行

在 `download_wheels_for_arch()` 中补 `pip install --upgrade pip wheel`，
与 `pack_orc.sh` 行为对齐。打包机要求 Python 3.12+，其中 pip ≥ 23.2.1
（pip 21.x 因 `pkgutil.ImpImporter` 在 Python 3.12 移除而无法运行），
无需额外版本守卫。

### 5. 保留 WHEEL_COUNT 验证

`WHEEL_COUNT`、`X86_COUNT`、`AARCH64_COUNT` 计数检查保留作为 defense-in-depth，
并保留 pack_reg.sh 中"某架构无 arch-specific wheel"的警告逻辑。

## 替代方案考虑

| 方案 | 优点 | 缺点 | 否决原因 |
|------|------|------|---------|
| sed 将 requirements.txt 中 `PyYAML>=6.0.3` 降级为 `>=6.0.2` | 改动极小 | 掩盖真实问题；下载本身正常，降级无必要 | 基于错误根因假设；且 6.0.2 的 PyYAML wheel 同样只有二进制平台标签，any 通道照样失败 |
| 保留 any 通道 + 移除 `\|\| true` | 错误不再被吞 | 通道仍零产出，每天打印必然的失败噪音 | 冗余通道无保留价值 |
| 仅修复 pack_orc.sh | 改动最小 | pack_reg.sh 存在相同缺陷，下次踩雷 | 用户确认两脚本同步修 |
| 加 pip 最低版本守卫 | 防止旧 pip 行为差异 | 打包机 Python 3.12+ 已隐含 pip ≥ 23.2.1，守卫永不触发 | 冗余防护 |

## 后果

- **正面**：误导性错误消息消失，打包日志干净
- **正面**：wheel 下载失败在打包阶段即中止，不再产出残缺离线包
- **正面**：两 pack 脚本行为对齐（pip 升级 + 失败即退出）
- **负面**：下载失败时留下不完整的 `BUILD_DIR`（下次打包的 Step 1 clean 会自行清理）

## 关联

- `binary/orchestration-center/pack_orc.sh` — 删除 `--platform any` 通道、移除 `|| true`
- `binary/registry-center/pack_reg.sh` — 删除 `--platform any` 通道、移除 `|| true`、补 pip 升级行
- `binary/one-click/docs/ADR-011-cross-arch-offline-packaging.md` — wheel-only 双架构打包策略的背景（本 ADR 的下载通道即该策略的实施）
- `binary/one-click/docs/glossary.md` — 新增术语：--platform any 通道、pip 整批解析、打包吞错