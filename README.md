# Strix 扫描与 Pi 修复脚本

这两个脚本用于本地授权的源代码安全审计：

1. `run_strix.sh`：复制并清理目标项目后，调用 Strix 生成扫描报告。
2. `run_pi.sh`：读取指定的 Strix 扫描结果，由 Pi 分诊并修复确认的安全问题。

脚本不会自动提交、推送或部署代码。

## 前置条件

- macOS 或 Linux
- Bash
- `python3`
- Docker，且当前用户可以访问 Docker daemon
- Strix CLI `1.4.1` 或更高版本
- 执行第二步时需要安装 `pi` CLI

如果命令不在 `PATH` 中，可以通过 `STRIX_BIN` 或 `PI_BIN` 指定完整路径。

首次使用前确认脚本可执行：

```bash
chmod +x run_strix.sh run_pi.sh
```

## 推荐流程

### 1. 运行 Strix 扫描

```bash
./run_strix.sh --auto /path/to/project standard
```

参数格式：

```text
./run_strix.sh [--interactive|--auto] <local-project-dir> [quick|standard|deep]
```

扫描模式：

- `quick`：快速扫描，默认值。
- `standard`：标准扫描。
- `deep`：深度扫描。

运行模式：

- `--interactive`：启动 Strix 交互式 TUI，默认模式。
- `--auto`：无交互运行，适合脚本或 CI，并保存完整控制台日志。

示例：

```bash
# 默认交互模式和 quick 扫描
./run_strix.sh /path/to/project

# 交互模式执行 standard 扫描
./run_strix.sh --interactive /path/to/project standard

# 无交互执行 deep 扫描
./run_strix.sh --auto /path/to/project deep

# 查看版本或帮助
./run_strix.sh --version
./run_strix.sh --help
```

默认报告目录为：

```text
~/strix_runs/<project>-<timestamp>-<pid>/
```

可通过 `STRIX_OUTPUT_DIR` 修改输出根目录：

```bash
STRIX_OUTPUT_DIR=/path/to/scan-results \
  ./run_strix.sh --auto /path/to/project standard
```

输出根目录必须位于项目目录之外，脚本会按真实路径解析符号链接，避免扫描结果被再次复制进扫描工作区或修改项目目录。

扫描完成后，命令行会打印实际的 `Results` 路径。后续运行 `run_pi.sh` 时，应使用这次扫描打印出的具体目录，不要依赖目录排序猜测最新结果。

### 2. 使用 Pi 处理扫描结果

`run_pi.sh` 接受一个本地项目目录，以及一个明确指定的扫描结果目录或 `findings.sarif` 文件：

```text
./run_pi.sh [--interactive|--auto] <local-project-dir> <strix-scan-result>
```

示例：

```bash
# 使用扫描结果目录，启动交互式 Pi（默认）
./run_pi.sh /path/to/project \
  ~/strix_runs/project-20260918-153000-12345

# 直接指定 SARIF 文件，并使用无交互模式
./run_pi.sh --auto /path/to/project \
  ~/strix_runs/project-20260918-153000-12345/findings.sarif

# 仅分析并输出建议，不修改项目文件
PI_FIX_DRY_RUN=true ./run_pi.sh --auto /path/to/project \
  ~/strix_runs/project-20260918-153000-12345

# 查看版本或帮助
./run_pi.sh --version
./run_pi.sh --help
```

运行模式：

- `--interactive`：启动 Pi 交互界面，默认模式。
- `--auto`：无交互运行，并将 Pi 输出保存到摘要文件。

非 dry-run 且 `PI_FIX_ALLOW_BREAKING=true` 时，Pi 可以修改项目中的必要文件。`PI_FIX_DRY_RUN=true` 或 `PI_FIX_ALLOW_BREAKING=false` 都会启用 Pi 的只读工具白名单，禁止文件修改。

Pi 修复结果默认写入独立目录 `~/pi_runs/<project>-<timestamp>-<pid>/`，不会写回 Strix 扫描结果目录。可通过 `PI_OUTPUT_DIR` 修改输出根目录，但该目录必须同时位于项目目录和选定的 Strix 扫描结果目录之外。

## 常用环境变量

### `run_strix.sh`

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `STRIX_BIN` | `strix` 或 `~/.strix/bin/strix` | Strix 可执行文件路径 |
| `STRIX_OUTPUT_DIR` | `~/strix_runs` | 报告输出根目录 |
| `STRIX_RUN_ID` | `<project>-<timestamp>-<pid>` | 自定义本次扫描 ID；仅允许 ASCII 字符，最多 48 个字符 |
| `STRIX_RUN_UI_MODE` | `interactive` | `interactive` 或 `auto` |
| `STRIX_SCAN_MODE` | `quick` | 未通过位置参数指定时的扫描模式 |
| `STRIX_MAX_BUDGET` | `50` | Strix 最大预算；也支持 `STRIX_MAX_BUDGET_USD` |
| `STRIX_TIMEOUT` | `9h30m` | 总扫描超时时间，如 `30m`、`3600s` |
| `STRIX_MAX_TURNS` | 按扫描模式设置 | 每个 agent 的最大轮数 |
| `STRIX_NETWORK_RETRIES` | `1` | 无交互模式下的临时网络错误重试次数，范围 `0-2` |
| `STRIX_KEEP_WORKSPACE` | `false` | 设为 `true` 时保留临时扫描工作区；默认情况下若结果未能写入输出目录，也会自动保留并打印恢复路径 |
| `STRIX_FRONTEND_STATIC` | `false` | 设为 `true` 时强制纯静态审计 |

例如：

```bash
STRIX_BIN=/opt/strix/bin/strix \
STRIX_TIMEOUT=2h \
STRIX_MAX_BUDGET=30 \
./run_strix.sh --auto /path/to/project quick
```

### `run_pi.sh`

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PI_BIN` | `pi` | Pi 可执行文件路径 |
| `PI_OUTPUT_DIR` | `~/pi_runs` | Pi 修复结果输出根目录 |
| `PI_FIX_DRY_RUN` | `false` | 设为 `true` 时只分析，不修改项目 |
| `PI_FIX_ALLOW_BREAKING` | `true` | `true` 允许写入；`false` 启用只读建议模式，禁止所有文件修改 |
| `PI_TIMEOUT` | 未设置 | 可选，设置后为 Pi 增加总超时，如 `30m`、`2h`、`3600s`；不设置则不限时 |

例如：

```bash
PI_BIN=/opt/pi/bin/pi \
PI_FIX_ALLOW_BREAKING=false \
./run_pi.sh --auto /path/to/project /path/to/scan-result
```

## 输出文件

### Strix 扫描结果

每次扫描对应一个独立目录，常见文件如下：

```text
<scan-result>/
├── findings.sarif
├── penetration_test_report.md
├── vulnerabilities.csv
├── vulnerabilities.json
├── coverage.json
├── vulnerabilities/
├── run.json
├── strix.log
├── scan-status.txt
├── strix-console.log
└── attempt-<n>.log
```

`scan-status.txt` 中的 `status=success` 表示脚本完成了报告、SARIF、运行状态和运行时错误校验：

- `findings` 只统计真实发现，`coverage` 是 `strix-coverage/*` 覆盖项数量，`total_results` 是全部 SARIF result 数。
- 若 Strix 因总超时被终止（`exit_code=124`），但 `run.json` 已确认扫描完成、报告和 SARIF 校验通过，仍记为 `success`；未确认完成即超时的扫描记为 `failure`，失败时也会打印 `strix view` 命令，便于查看已产出的结果。
- 运行时错误校验优先读取 Strix 自带的 `strix.log`，interactive 和 `--auto` 模式都会执行；`run.json` 中的 `scan_results.scan_completed` / `success` 也会参与完成度判定（字段存在时）。
- interactive TUI 的终端输出不会写进 `strix-console.log`；需要完整控制台日志时使用 `--auto`。
- `run.json` 和 `strix.log` 会随结果一起复制出来，便于事后核对扫描完成度、批次中断和成本。

扫描失败或不完整时，脚本仍会尽量保留可用的部分结果：Strix 的原始输出会在校验之前先复制到结果目录；如果连这一步都没来得及完成（脚本崩溃、被中断等），临时工作区不会被删掉，而会打印 `keeping local scan workspace for recovery: <path>`，可手动从该目录取回结果。

注意：不要在扫描运行期间修改或升级 `run_strix.sh` 本身。bash 是边执行边从脚本文件读取的，运行中修改文件会使后续读取错位并中断脚本（结果虽然可由上面的恢复机制找回，但本次扫描需要重跑）。

### Pi 修复结果

Pi 的产物保存在独立的 `~/pi_runs/<project>-<timestamp>-<pid>/` 目录：

```text
~/pi_runs/<project>-<timestamp>-<pid>/
├── prompt.md
├── pi-summary.md
├── changes.diff
├── git-status-before.txt
├── git-status-after.txt
└── metadata.txt
```

重点检查：

- `pi-summary.md`：Pi 的自动运行摘要；交互模式下是会话说明。
- `changes.diff`：仅本次 Pi 运行产生的项目差异，不包含运行前已存在的修改。
- `git-status-after.txt`：修复完成后的 Git 状态。
- `metadata.txt`：本次修复的输入路径、模式和退出码。

## 安全与数据边界

- `run_strix.sh` 不直接扫描原始项目，而是先复制到临时工作区，并移除 `.git`、依赖、构建产物、缓存、日志、二进制等非源代码内容。
- 原始项目不会被 `run_strix.sh` 修改。
- `run_pi.sh` 只有在非 dry-run 且 `PI_FIX_ALLOW_BREAKING=true` 时才允许 Pi 修改指定项目；执行前应确认项目路径和扫描结果路径正确。
- 报告可能包含源码路径、漏洞证据和修复建议，应按敏感文件处理。
- 不要把 `findings.sarif`、报告或 `pi_runs/` 目录提交到不应包含审计结果的代码仓库。

## 退出码

- `0`：脚本成功完成。
- 非 `0`：参数、依赖、Docker、Strix/Pi 执行或结果校验失败。具体原因会输出到终端，并通常保存在对应日志或摘要文件中。
