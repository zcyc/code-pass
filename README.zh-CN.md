# CodePass

CodePass 是一个面向本地授权代码库的安全审计与修复工作流，基于 Strix 和 Pi：

1. `strix.sh` 将目标项目复制到隔离工作区并执行 Strix 扫描。
2. `pi.sh` 读取明确指定的 Strix 扫描结果，分诊发现并修复确认的问题。
3. `codepass.sh` 编排有限轮次的“扫描 → 修复 → 再扫描”流程。

脚本不会自动提交、推送或部署代码。

[English](README.md)

## 前置条件

运行 CodePass 前，请先安装并配置以下依赖：

- macOS 或 Linux。
- Bash。脚本使用 `[[ ... ]]`、数组和 `set -Eeuo pipefail` 等 Bash 特性。
- Python 3，命令名为 `python3`。
- Git，命令名为 `git`。完整的 `codepass.sh` 循环要求目标项目是 Git 工作树。
- Docker Engine 或 Docker Desktop，并确保 Docker daemon 正在运行且当前用户可以访问。使用 `docker info` 验证。
- Strix CLI `1.4.1` 或更高版本。默认从 `PATH` 查找 `strix`，也可以通过 `STRIX_BIN` 指定路径。
- Pi CLI。默认从 `PATH` 查找 `pi`，也可以通过 `PI_BIN` 指定路径。
- 你有权审计的本地项目。Strix 或 Pi 所需的账号凭据需要另行配置。

脚本还需要权限创建临时工作区和写入输出目录。扫描报告和 Pi 输出可能包含源码路径、漏洞证据和修复细节，请按敏感数据处理。

快速检查环境：

```bash
command -v bash python3 git docker
docker info
command -v strix   # 或设置 STRIX_BIN
command -v pi      # 或设置 PI_BIN
```

## 快速开始

在 CodePass 目录中执行：

```bash
chmod +x strix.sh pi.sh codepass.sh
./codepass.sh --auto /path/to/project quick
```

默认最多执行 3 轮。当扫描失败或不完整、没有发现问题、Pi 没有改动、同一 finding 指纹再次出现或达到轮数上限时，循环会停止。

只分析并输出建议、不修改目标项目：

```bash
PI_FIX_DRY_RUN=true ./pi.sh --auto /path/to/project /path/to/scan-result
```

## 命令

### 完整循环

```text
./codepass.sh [--interactive|--auto] [--max-rounds N] \
  <local-project-dir> [quick|standard|deep]
```

示例：

```bash
./codepass.sh --auto /path/to/project quick
CODE_PASS_MAX_ROUNDS=2 ./codepass.sh --auto /path/to/project standard
```

目标项目必须是 Git 工作树，以便 CodePass 判断 Pi 是否产生了有效改动。Strix 总预算默认取 `STRIX_MAX_BUDGET`；未设置时为 `50`，并在各轮之间分配。

### Strix 扫描

```text
./strix.sh [--interactive|--auto] <local-project-dir> [quick|standard|deep]
```

`quick` 是默认扫描模式；`standard` 和 `deep` 会增加扫描覆盖范围和成本。

```bash
# 交互式扫描（默认）
./strix.sh /path/to/project

# 无交互扫描，并保存控制台日志
./strix.sh --auto /path/to/project standard

./strix.sh --version
./strix.sh --help
```

Strix 扫描的是清理后的副本，不会直接扫描原始项目。副本会排除 `.git`、依赖、构建产物、缓存、日志和二进制文件。`strix.sh` 不会修改原始项目。

默认结果目录：

```text
~/strix_runs/<project>-<timestamp>-<pid>/
```

命令会打印本次扫描的实际结果目录。下一步必须使用该具体目录，不要依赖目录排序猜测最新结果。

### Pi 修复

```text
./pi.sh [--interactive|--auto] <local-project-dir> <strix-scan-result>
```

`<strix-scan-result>` 必须是包含 `findings.sarif` 的结果目录，或该 SARIF 文件本身。Pi 不会自动猜测最新扫描结果。

```bash
# 交互式修复（默认）
./pi.sh /path/to/project /path/to/scan-result

# 无交互修复
./pi.sh --auto /path/to/project /path/to/scan-result

# 只读分析，不修改目标项目
PI_FIX_DRY_RUN=true ./pi.sh --auto /path/to/project /path/to/scan-result
```

Pi 结果默认写入独立目录：

```text
~/pi_runs/<project>-<timestamp>-<pid>/
```

`PI_FIX_ALLOW_BREAKING=true` 是默认值，允许必要的文件修改，包括不可避免的破坏性修复。设置为 `false`，或设置 `PI_FIX_DRY_RUN=true`，即可启用只读工具策略。

## 环境变量

### `strix.sh`

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `STRIX_BIN` | `strix` 或 `~/.strix/bin/strix` | Strix 可执行文件 |
| `STRIX_OUTPUT_DIR` | `~/strix_runs` | 输出根目录，必须位于目标项目之外 |
| `STRIX_RUN_ID` | `<project>-<timestamp>-<pid>` | 运行 ID，只允许 ASCII 字母、数字、`.`、`_`、`-`，最多 48 个字符 |
| `STRIX_RUN_UI_MODE` | `interactive` | `interactive` 或 `auto`，显式 CLI 参数优先 |
| `STRIX_SCAN_MODE` | `quick` | `quick`、`standard` 或 `deep` |
| `STRIX_MAX_BUDGET` | `50` | Strix 预算，也支持 `STRIX_MAX_BUDGET_USD` |
| `STRIX_TIMEOUT` | `9h30m` | 总扫描超时，例如 `30m`、`2h` 或 `3600s` |
| `STRIX_MAX_TURNS` | 按模式决定 | 每个 agent 的最大轮数 |
| `STRIX_NETWORK_RETRIES` | `1` | 无交互模式下的临时网络错误重试次数，范围 `0` 到 `2` |
| `STRIX_KEEP_WORKSPACE` | `false` | 保留临时扫描工作区，以便恢复结果 |
| `STRIX_FRONTEND_STATIC` | `false` | 强制执行纯静态分析 |

### `pi.sh`

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PI_BIN` | `pi` | Pi 可执行文件 |
| `PI_OUTPUT_DIR` | `~/pi_runs` | 输出根目录，必须位于目标项目和选定扫描结果之外 |
| `PI_FIX_DRY_RUN` | `false` | 使用 Pi 只读工具，不修改文件 |
| `PI_FIX_ALLOW_BREAKING` | `true` | 允许文件修改，包括必要的破坏性修复 |
| `PI_TIMEOUT` | 未设置 | 可选的 Pi 总超时，例如 `30m`、`2h` 或 `3600s` |

### `codepass.sh`

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CODE_PASS_OUTPUT_DIR` | `~/code_pass_runs` | 循环输出根目录，必须位于目标项目之外 |
| `CODE_PASS_MAX_ROUNDS` | `3` | 最大扫描/修复轮数 |
| `CODE_PASS_MAX_TOTAL_BUDGET` | `STRIX_MAX_BUDGET` 或 `50` | 在各轮之间分配的 Strix 总预算 |
| `CODE_PASS_RUN_UI_MODE` | `auto` | `interactive` 或 `auto` |
| `STRIX_MAX_BUDGET` | `50` | 循环总预算的兜底值 |
| `PI_TIMEOUT` | 未设置 | 透传给 `pi.sh` |

## 输出文件

Strix 结果通常包含：

```text
findings.sarif
penetration_test_report.md
vulnerabilities.csv
vulnerabilities.json
coverage.json
vulnerabilities/
run.json
strix.log
scan-status.txt
strix-console.log
attempt-<n>.log
```

`scan-status.txt` 记录扫描是否完成，以及运行时和结果校验是否通过。脚本会尽可能保留部分结果；如果需要保留临时工作区用于恢复，会打印其路径。

Pi 结果通常包含：

```text
prompt.md
pi-summary.md
changes.diff
git-status-before.txt
git-status-after.txt
metadata.txt
```

重点检查 `pi-summary.md` 中的运行摘要、`changes.diff` 中本次运行产生的修改，以及 `git-status-after.txt` 中的最终项目状态。

## 安全与数据边界

- 只审计你获授权的项目。
- `strix.sh` 使用清理后的副本，不修改原始项目。
- `pi.sh` 在非只读模式下可以修改指定项目；运行前请确认项目路径和扫描结果。
- 扫描运行期间不要修改或升级 `strix.sh`；Bash 会边执行边读取脚本文件。
- 除非仓库本来就用于保存审计结果，否则不要提交 SARIF、报告或 `pi_runs/`。
- 脚本不会自动提交、推送或部署改动。

## 退出码

- `0`：成功完成。
- 非 `0`：参数错误、依赖缺失、Docker/Strix/Pi 执行失败、超时或结果校验失败。请检查终端输出及生成的日志或摘要文件。
