# CodePass

CodePass is a local, authorized source-code security workflow built around Strix and Pi:

1. `strix.sh` copies a target project into an isolated workspace and runs a Strix scan.
2. `pi.sh` reads one explicitly selected Strix result, triages the findings, and can fix confirmed issues.
3. `codepass.sh` orchestrates a bounded scan → fix → rescan loop.

The scripts never commit, push, or deploy code automatically.

[简体中文](README.zh-CN.md)

## Prerequisites

Install and configure these before running CodePass:

- macOS or Linux.
- Bash. The scripts use Bash features such as `[[ ... ]]`, arrays, and `set -Eeuo pipefail`.
- Python 3, available as `python3`.
- Git, available as `git`. The full `codepass.sh` loop requires the target to be a Git worktree.
- Docker Engine or Docker Desktop, with a running daemon accessible by the current user. Verify with `docker info`.
- Strix CLI `1.4.1` or newer, available as `strix`, or provide its path with `STRIX_BIN`.
- Pi CLI, available as `pi`, or provide its path with `PI_BIN`.
- A local project that you are authorized to inspect. Configure any credentials required by Strix or Pi separately.

The scripts also need permission to create temporary workspaces and write their output directories. Keep scan reports and Pi output private: they can contain source paths, vulnerability evidence, and remediation details.

Quick preflight:

```bash
command -v bash python3 git docker
docker info
command -v strix   # or set STRIX_BIN
command -v pi      # or set PI_BIN
```

## Quick start

Run these commands from the CodePass directory:

```bash
chmod +x strix.sh pi.sh codepass.sh
./codepass.sh --auto /path/to/project quick
```

The loop runs at most three rounds by default. It stops when the scan fails or is incomplete, no findings remain, Pi makes no change, the same finding fingerprint returns, or the round limit is reached.

For a read-only remediation pass:

```bash
PI_FIX_DRY_RUN=true ./pi.sh --auto /path/to/project /path/to/scan-result
```

## Commands

### Full loop

```text
./codepass.sh [--interactive|--auto] [--max-rounds N] \
  <local-project-dir> [quick|standard|deep]
```

Examples:

```bash
./codepass.sh --auto /path/to/project quick
CODE_PASS_MAX_ROUNDS=2 ./codepass.sh --auto /path/to/project standard
```

The target must be a Git worktree so CodePass can detect whether Pi made progress. The total Strix budget defaults to `STRIX_MAX_BUDGET`, or `50` when that variable is unset, and is split across rounds.

### Strix scan

```text
./strix.sh [--interactive|--auto] <local-project-dir> [quick|standard|deep]
```

`quick` is the default scan mode. `standard` and `deep` increase scan coverage and cost.

```bash
# Interactive scan (default)
./strix.sh /path/to/project

# Headless scan with captured console logs
./strix.sh --auto /path/to/project standard

./strix.sh --version
./strix.sh --help
```

Strix scans a sanitized copy rather than the original project. The copy excludes `.git`, dependencies, build outputs, caches, logs, and binaries. The original project is not modified by `strix.sh`.

By default, results are written to:

```text
~/strix_runs/<project>-<timestamp>-<pid>/
```

The command prints the concrete result directory. Use that exact directory for the next step; do not guess the latest result by sorting directory names.

Strix's native run data is kept under `<result-directory>/strix_runs/`, so the `strix view` command printed during the scan remains usable after `strix.sh` exits.

### Pi remediation

```text
./pi.sh [--interactive|--auto] <local-project-dir> <strix-scan-result>
```

`<strix-scan-result>` must be either a result directory containing `findings.sarif` or that file itself. Pi never guesses which scan is latest.

```bash
# Interactive remediation (default)
./pi.sh /path/to/project /path/to/scan-result

# Headless remediation
./pi.sh --auto /path/to/project /path/to/scan-result

# Read-only analysis; do not modify the target project
PI_FIX_DRY_RUN=true ./pi.sh --auto /path/to/project /path/to/scan-result
```

Pi output is written to a separate directory by default:

```text
~/pi_runs/<project>-<timestamp>-<pid>/
```

`PI_FIX_ALLOW_BREAKING=true` is the default and permits necessary file edits, including unavoidable breaking fixes. Set it to `false`, or set `PI_FIX_DRY_RUN=true`, to use the read-only tool policy.

## Environment variables

### `strix.sh`

| Variable | Default | Purpose |
| --- | --- | --- |
| `STRIX_BIN` | `strix` or `~/.strix/bin/strix` | Strix executable |
| `STRIX_OUTPUT_DIR` | `~/strix_runs` | Output root; must be outside the target project |
| `STRIX_RUN_ID` | `<project>-<timestamp>-<pid>` | Run identifier; ASCII letters, digits, `.`, `_`, `-`, max 48 characters |
| `STRIX_RUN_UI_MODE` | `interactive` | `interactive` or `auto`; an explicit CLI flag wins |
| `STRIX_SCAN_MODE` | `quick` | `quick`, `standard`, or `deep` |
| `STRIX_MAX_BUDGET` | `50` | Strix budget; `STRIX_MAX_BUDGET_USD` is also accepted |
| `STRIX_TIMEOUT` | `9h30m` | Total scan timeout, for example `30m`, `2h`, or `3600s` |
| `STRIX_MAX_TURNS` | Mode-dependent | Maximum turns per agent |
| `STRIX_NETWORK_RETRIES` | `1` | Automatic-mode transient network retries, from `0` to `2` |
| `STRIX_KEEP_WORKSPACE` | `false` | Keep the temporary scan workspace for recovery |
| `STRIX_FRONTEND_STATIC` | `false` | Force static-only analysis |

### `pi.sh`

| Variable | Default | Purpose |
| --- | --- | --- |
| `PI_BIN` | `pi` | Pi executable |
| `PI_OUTPUT_DIR` | `~/pi_runs` | Output root; must be outside the target and selected scan result |
| `PI_FIX_DRY_RUN` | `false` | Use Pi's read-only tools and do not modify files |
| `PI_FIX_ALLOW_BREAKING` | `true` | Allow file edits, including necessary breaking fixes |
| `PI_TIMEOUT` | unset | Optional total Pi timeout, for example `30m`, `2h`, or `3600s` |

### `codepass.sh`

| Variable | Default | Purpose |
| --- | --- | --- |
| `CODE_PASS_OUTPUT_DIR` | `~/code_pass_runs` | Loop output root; must be outside the target project |
| `CODE_PASS_MAX_ROUNDS` | `3` | Maximum scan/fix rounds |
| `CODE_PASS_MAX_TOTAL_BUDGET` | `STRIX_MAX_BUDGET` or `50` | Total Strix budget split across rounds |
| `CODE_PASS_RUN_UI_MODE` | `auto` | `interactive` or `auto` |
| `STRIX_MAX_BUDGET` | `50` | Fallback total loop budget |
| `PI_TIMEOUT` | unset | Passed through to `pi.sh` |

## Output files

A Strix result commonly contains:

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

`scan-status.txt` records whether the scan completed and whether runtime/result validation passed. Partial output is preserved when possible. If the temporary workspace must be retained for recovery, the script prints its path.

A Pi result commonly contains:

```text
prompt.md
pi-summary.md
changes.diff
git-status-before.txt
git-status-after.txt
metadata.txt
```

Check `pi-summary.md` for the run summary, `changes.diff` for changes made by that run, and `git-status-after.txt` for the final project state.

## Safety and data boundaries

- Only scan projects you are authorized to inspect.
- `strix.sh` works on a sanitized copy and does not modify the original project.
- `pi.sh` can modify the selected project when it is not in read-only mode. Review the project path and scan result before running it.
- Do not edit or upgrade `strix.sh` while a scan is running; Bash reads the script as it executes.
- Do not commit SARIF files, reports, or `pi_runs/` unless the repository is intended to store audit results.
- No script automatically commits, pushes, or deploys changes.

## Exit codes

- `0`: completed successfully.
- Non-zero: invalid arguments, missing dependencies, Docker/Strix/Pi failure, timeout, or result validation failure. Check the terminal output and the generated logs or summaries.
