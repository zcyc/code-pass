#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

RUN_STRIX_PIPELINE_VERSION="3.3.2-local"

usage() {
  cat <<'EOF'
Usage:
  run_strix.sh [--interactive|--auto] <local-project-dir> [quick|standard|deep]

Modes:
  --interactive  Start the normal Strix TUI (default). Keeps a real terminal so
                 the live visual interface remains usable.
  --auto         Headless mode. Adds -n, captures console logs, and enables the
                 transient transport retry behavior used by the old CI runner.

Examples:
  ./run_strix.sh ~/src/my-project
  ./run_strix.sh ~/src/my-project standard
  ./run_strix.sh --auto ~/src/my-project quick
  STRIX_MAX_BUDGET=30 ./run_strix.sh --auto /opt/code/api deep

Results are written to ~/strix_runs/<project>-<timestamp>-<pid>/ by default.
Override the output root with STRIX_OUTPUT_DIR.
You can also set STRIX_RUN_UI_MODE=interactive|auto; an explicit CLI flag wins.
EOF
}

RUN_UI_MODE="${STRIX_RUN_UI_MODE:-interactive}"
_positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive)
      RUN_UI_MODE="interactive"
      shift
      ;;
    --auto|--headless)
      RUN_UI_MODE="auto"
      shift
      ;;
    --version)
      echo "run_strix ${RUN_STRIX_PIPELINE_VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        _positional[${#_positional[@]}]="$1"
        shift
      done
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      _positional[${#_positional[@]}]="$1"
      shift
      ;;
  esac
done
set -- "${_positional[@]}"
unset _positional

case "$RUN_UI_MODE" in
  interactive|auto) ;;
  *) echo "ERROR: STRIX_RUN_UI_MODE must be interactive or auto: $RUN_UI_MODE" >&2; exit 2 ;;
esac
readonly RUN_UI_MODE

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
[[ -d "$1" ]] || { echo "ERROR: local project directory does not exist: $1" >&2; exit 1; }
# Portable canonicalization: works with the macOS system Bash and does not
# require GNU realpath.
SOURCE_DIR="$(cd "$1" 2>/dev/null && pwd -P)" || {
  echo "ERROR: unable to resolve local project directory: $1" >&2
  exit 1
}
[[ "$SOURCE_DIR" != "/" ]] || { echo "ERROR: refusing to scan the filesystem root" >&2; exit 1; }
readonly SOURCE_DIR

# Include the source project name in the run directory so scans from multiple
# local projects are easy to distinguish under ~/strix_runs. Sanitize the
# basename because RUN_ID is also used in systemd/Docker resource names.
PROJECT_NAME="$(basename "$SOURCE_DIR")"
PROJECT_NAME="$(printf '%s' "$PROJECT_NAME" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$PROJECT_NAME" ]] || PROJECT_NAME="project"
# Docker network names include this value plus a fixed prefix. Keep generated
# IDs short enough for Docker, mktemp and systemd resource names.
PROJECT_NAME="${PROJECT_NAME:0:24}"
readonly PROJECT_NAME

STRIX_SCAN_MODE="${2:-${STRIX_SCAN_MODE:-quick}}"
readonly STRIX_SCAN_MODE

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required" >&2
  exit 1
}
canonicalize_path() {
  python3 - "$1" <<'PY'
import os
import sys
from pathlib import Path

print(Path(os.path.abspath(sys.argv[1])).resolve(strict=False))
PY
}

OUTPUT_ROOT="${STRIX_OUTPUT_DIR:-${HOME:?HOME is required}/strix_runs}"
OUTPUT_ROOT="$(canonicalize_path "$OUTPUT_ROOT")" || {
  echo "ERROR: unable to resolve STRIX_OUTPUT_DIR: ${STRIX_OUTPUT_DIR:-$OUTPUT_ROOT}" >&2
  exit 1
}
case "$OUTPUT_ROOT/" in
  "$SOURCE_DIR/"*) echo "ERROR: STRIX_OUTPUT_DIR must be outside the project directory: $OUTPUT_ROOT" >&2; exit 1 ;;
esac
readonly OUTPUT_ROOT
RUN_ID="${STRIX_RUN_ID:-${PROJECT_NAME}-$(date '+%Y%m%d-%H%M%S')-$$}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid STRIX_RUN_ID: $RUN_ID" >&2; exit 1; }
(( ${#RUN_ID} <= 48 )) || {
  echo "ERROR: STRIX_RUN_ID is too long (maximum 48 ASCII characters): $RUN_ID" >&2
  exit 1
}
readonly RUN_ID
readonly ARTIFACT_DIR="${OUTPUT_ROOT}/${RUN_ID}"
TMP_ROOT="${TMPDIR:-/tmp}"
case "$TMP_ROOT" in
  /*) ;;
  *) TMP_ROOT="$(pwd -P)/$TMP_ROOT" ;;
esac
[[ -d "$TMP_ROOT" ]] || { echo "ERROR: TMPDIR does not exist: $TMP_ROOT" >&2; exit 1; }
TMP_ROOT="$(cd "$TMP_ROOT" 2>/dev/null && pwd -P)" || {
  echo "ERROR: unable to resolve TMPDIR: $TMP_ROOT" >&2
  exit 1
}
case "$TMP_ROOT/" in
  "$SOURCE_DIR/"*) echo "ERROR: TMPDIR must be outside the project directory: $TMP_ROOT" >&2; exit 1 ;;
esac
WORK_DIR="$(mktemp -d "${TMP_ROOT}/strix-local-${RUN_ID}.XXXXXX")"
readonly WORK_DIR
# Ensure early validation/copy failures do not leave a temporary source copy.
trap 'rm -rf "$WORK_DIR"' EXIT
readonly TARGET_DIR="${WORK_DIR}/target"
readonly STRIX_RUN_ROOT="${WORK_DIR}/strix_runs"

_default_strix_bin="$(command -v strix 2>/dev/null || true)"
_requested_strix_bin="${STRIX_BIN:-${_default_strix_bin:-${HOME}/.strix/bin/strix}}"
if [[ "$_requested_strix_bin" != */* ]]; then
  _requested_strix_bin="$(command -v "$_requested_strix_bin" 2>/dev/null || true)"
fi
if [[ -n "$_requested_strix_bin" && "$_requested_strix_bin" != /* ]]; then
  _requested_strix_bin="$(cd "$(dirname "$_requested_strix_bin")" 2>/dev/null &&
    printf '%s/%s\n' "$(pwd -P)" "$(basename "$_requested_strix_bin")")" || {
    echo "ERROR: unable to resolve STRIX_BIN: $_requested_strix_bin" >&2
    exit 1
  }
fi
readonly STRIX_BIN="$_requested_strix_bin"
# Standalone implementation: all pipeline helper logic is embedded in this
# launcher. Do not probe or depend on the old CI helper scripts.
readonly PIPELINE_UTILS="${WORK_DIR}/strix_pipeline_utils_builtin.py"
cat > "$PIPELINE_UTILS" <<'PYUTIL'
#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path

DIR_NAMES = {
    'node_modules', 'vendor', 'vendors', 'bower_components', 'Pods',
    'DerivedData', '__pycache__', 'dist', 'build', 'out', 'coverage',
    'htmlcov', 'strix_runs', '.pytest_cache', '.mypy_cache', '.ruff_cache',
}
FILE_SUFFIXES = {
    '.log', '.zip', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.7z', '.rar',
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.svgz',
    '.mp3', '.wav', '.ogg', '.mp4', '.mov', '.avi', '.mkv', '.webm',
    '.ttf', '.otf', '.woff', '.woff2', '.eot',
    '.so', '.dylib', '.dll', '.a', '.o', '.obj', '.class', '.jar', '.war',
    '.exe', '.bin', '.pyc', '.pyo',
}

def rm_path(p: Path):
    if p.is_symlink() or not p.is_dir():
        p.unlink(missing_ok=True)
    elif p.is_dir():
        shutil.rmtree(p)

def prune(root: str):
    root = Path(root).resolve()
    removed_dirs = removed_files = 0
    errors = 0

    def onerror(exc):
        nonlocal errors
        errors += 1
        print(f'prune: cannot access {getattr(exc, "filename", root)}: {exc}', file=sys.stderr)

    for cur, dirs, files in os.walk(root, topdown=True, onerror=onerror):
        curp = Path(cur)
        kept = []
        for name in dirs:
            p = curp / name
            if p.is_symlink() or name.startswith('.') or name in DIR_NAMES or (name == 'target' and p != root):
                rm_path(p); removed_dirs += 1
            else:
                kept.append(name)
        dirs[:] = kept
        for name in files:
            p = curp / name
            if p.is_symlink():
                rm_path(p); removed_files += 1
                continue
            if not p.is_file():
                rm_path(p); removed_files += 1
                continue
            suffix = p.suffix.lower()
            if name.startswith('.') or suffix in FILE_SUFFIXES:
                rm_path(p); removed_files += 1
                continue
            try:
                with p.open('rb') as f:
                    head = f.read(4)
                if head == b'\x7fELF' or head[:2] == b'MZ' or head in {
                    b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe',
                    b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
                }:
                    rm_path(p); removed_files += 1
            except OSError as exc:
                onerror(exc)
    if errors:
        raise OSError(f'prune encountered {errors} inaccessible path(s)')
    print(f"dirs={removed_dirs} files={removed_files}")

def sarif_count(path: str):
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get('runs'), list):
        raise ValueError('invalid SARIF: missing runs array')
    total = 0
    for run in data['runs']:
        if not isinstance(run, dict):
            raise ValueError('invalid SARIF run')
        results = run.get('results', [])
        if not isinstance(results, list):
            raise ValueError('invalid SARIF results')
        total += len(results)
    print(total)

def retry_budget(total: str, attempts: str):
    # Strix does not expose authoritative local billing usage. Split the total
    # budget across all possible attempts so retries cannot exceed the cap.
    import math
    value = float(total)
    count = int(attempts)
    if not math.isfinite(value) or value <= 0:
        raise ValueError('total budget must be a finite positive number')
    if count < 1:
        raise ValueError('attempt count must be positive')
    per_attempt = value / count
    if per_attempt <= 0:
        raise ValueError('per-attempt budget must be positive')
    print(('%0.12f' % per_attempt).rstrip('0').rstrip('.'))

def completed(run_dir: str):
    p = Path(run_dir) / 'run.json'
    if not p.is_file():
        raise ValueError('missing run.json')
    with p.open('r', encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError('run.json is not an object')
    for key in ('status', 'state'):
        val = data.get(key)
        if isinstance(val, str):
            low = val.lower()
            if low in {'completed', 'complete', 'finished', 'success', 'succeeded', 'done'}:
                return
            if low in {'failed', 'failure', 'error', 'cancelled', 'canceled', 'running', 'pending'}:
                raise ValueError(f'run {key}={val}')
    for key in ('completed', 'is_completed', 'finished'):
        if key in data and isinstance(data[key], bool):
            if data[key]:
                return
            raise ValueError(f'run {key}=false')
    raise ValueError('run.json has no recognized completion marker')

def main():
    if len(sys.argv) < 2:
        raise SystemExit(2)
    cmd = sys.argv[1]
    if cmd == 'prune' and len(sys.argv) == 3:
        prune(sys.argv[2])
    elif cmd == 'sarif-count' and len(sys.argv) == 3:
        sarif_count(sys.argv[2])
    elif cmd == 'retry-budget' and len(sys.argv) == 4:
        retry_budget(sys.argv[2], sys.argv[3])
    elif cmd == 'completed' and len(sys.argv) == 3:
        completed(sys.argv[2])
    else:
        raise SystemExit(2)

if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f"pipeline-utils: {e}", file=sys.stderr)
        raise SystemExit(1)
PYUTIL

export STRIX_FORCE_REQUIRED_TOOL_CHOICE="true"
readonly STRIX_MIN_VERSION="${STRIX_MIN_VERSION:-1.4.1}"
readonly STRIX_TIMEOUT="${STRIX_TIMEOUT:-9h30m}"
readonly STRIX_BUDGET="${STRIX_MAX_BUDGET:-${STRIX_MAX_BUDGET_USD:-50}}"
# Limit per-agent work; context compaction is managed by Strix.
case "$STRIX_SCAN_MODE" in
  quick) _default_max_turns=60 ;;
  standard) _default_max_turns=100 ;;
  deep) _default_max_turns=120 ;;
  *) _default_max_turns=100 ;;
esac
readonly STRIX_MAX_TURNS="${STRIX_MAX_TURNS:-$_default_max_turns}"
readonly STRIX_HOST_CPU_QUOTA="${STRIX_HOST_CPU_QUOTA:-100%}"
readonly STRIX_HOST_MEMORY_MAX="${STRIX_HOST_MEMORY_MAX:-1G}"
_nofile_hard_default="$(ulimit -Hn)"
if [[ "$_nofile_hard_default" == "unlimited" ]] || (( 10#$_nofile_hard_default >= 65536 )); then
  _nofile_default=65536
else
  _nofile_default="$_nofile_hard_default"
fi
readonly STRIX_NOFILE_LIMIT="${STRIX_NOFILE_LIMIT:-$_nofile_default}"
readonly STRIX_SANDBOX_CPUS="${STRIX_SANDBOX_CPUS:-2}"
readonly STRIX_SANDBOX_MEM_LIMIT="${STRIX_SANDBOX_MEM_LIMIT:-3g}"
readonly STRIX_SANDBOX_PIDS_LIMIT="${STRIX_SANDBOX_PIDS_LIMIT:-1024}"
readonly STRIX_SANDBOX_SHM_SIZE="${STRIX_SANDBOX_SHM_SIZE:-1g}"
readonly PROJECT_INSTRUCTION_FILE="${TARGET_DIR}/.strix-instructions.md"
readonly SCAN_LOG="${ARTIFACT_DIR}/strix-console.log"
readonly SANDBOX_NETWORK="strix-local-${RUN_ID}"
readonly STRIX_MANAGED_LABEL="strix-managed=true"
readonly STRIX_RUN_LABEL="strix-run-id=${RUN_ID}"
readonly STRIX_FAIL_ON_CONTEXT_ERROR="${STRIX_FAIL_ON_CONTEXT_ERROR:-true}"
readonly STRIX_NETWORK_RETRIES="${STRIX_NETWORK_RETRIES:-1}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_bool() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *) die "$name must be true or false: $value" ;;
  esac
}

if [[ ! "$STRIX_MAX_TURNS" =~ ^[1-9][0-9]*$ ]]; then
  die "Invalid STRIX_MAX_TURNS: $STRIX_MAX_TURNS"
fi
if [[ ! "$STRIX_NOFILE_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  die "Invalid STRIX_NOFILE_LIMIT: $STRIX_NOFILE_LIMIT"
fi
if [[ ! "$STRIX_NETWORK_RETRIES" =~ ^[0-2]$ ]]; then
  die "Invalid STRIX_NETWORK_RETRIES (expected 0-2)"
fi
require_bool STRIX_FAIL_ON_CONTEXT_ERROR "$STRIX_FAIL_ON_CONTEXT_ERROR"
require_bool STRIX_KEEP_WORKSPACE "${STRIX_KEEP_WORKSPACE:-false}"
require_bool STRIX_COORDINATION_OPTIMIZED "${STRIX_COORDINATION_OPTIMIZED:-false}"
require_bool STRIX_TOKEN_OPTIMIZED "${STRIX_TOKEN_OPTIMIZED:-false}"
case "${STRIX_FRONTEND_STATIC:-auto}" in
  auto|true|false) ;;
  *) die "STRIX_FRONTEND_STATIC must be auto, true, or false" ;;
esac

# Raise only this process tree's soft open-file limit; Strix, systemd-run and
# descendants inherit it. No host-wide limit change is required.
nofile_hard="$(ulimit -Hn)"
if [[ "$nofile_hard" != "unlimited" ]] &&
   (( 10#$nofile_hard < 10#$STRIX_NOFILE_LIMIT )); then
  die "Open-file hard limit ${nofile_hard} is below requested ${STRIX_NOFILE_LIMIT}"
fi
ulimit -S -n "$STRIX_NOFILE_LIMIT" ||
  die "Unable to set open-file soft limit to ${STRIX_NOFILE_LIMIT}"
echo "Open-file limit: soft=$(ulimit -Sn), hard=$(ulimit -Hn)"

case "$STRIX_SCAN_MODE" in
  quick | standard | deep) ;;
  *) die "Unsupported Strix scan mode: $STRIX_SCAN_MODE" ;;
esac

[[ -f "$PIPELINE_UTILS" ]] || die "Failed to initialize built-in pipeline utilities"
[[ -x "$STRIX_BIN" ]] || die "Strix executable not found: $STRIX_BIN"
strix_version_text="$("$STRIX_BIN" -v 2>&1 || true)"
strix_version="${strix_version_text##* }"
if [[ ! "$strix_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "Cannot determine Strix version from: ${strix_version_text:-unknown}"
fi
if [[ ! "$STRIX_MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "Invalid STRIX_MIN_VERSION: $STRIX_MIN_VERSION"
fi
IFS=. read -r strix_major strix_minor strix_patch <<< "$strix_version"
IFS=. read -r min_major min_minor min_patch <<< "$STRIX_MIN_VERSION"
if (( 10#$strix_major < 10#$min_major ||
      (10#$strix_major == 10#$min_major && 10#$strix_minor < 10#$min_minor) ||
      (10#$strix_major == 10#$min_major && 10#$strix_minor == 10#$min_minor && 10#$strix_patch < 10#$min_patch) )); then
  die "Strix ${strix_version} is too old; version ${STRIX_MIN_VERSION}+ is required for sandbox cleanup and resource limits"
fi
echo "Strix version: $strix_version"

strix_help="$("$STRIX_BIN" --help 2>&1)" || die "Cannot read Strix CLI help"
require_strix_option() {
  local option="$1"
  local pattern="(^|[[:space:][:punct:]])${option}([[:space:]=,]|$)"
  if ! grep -Eq "$pattern" <<< "$strix_help"; then
    die "Strix ${strix_version} does not support required option: ${option}"
  fi
}
require_strix_option "--scan-mode"
require_strix_option "--scope-mode"
require_strix_option "--max-budget"
require_strix_option "--max-turns"
require_strix_option "--instruction"

if [[ "$RUN_UI_MODE" == "interactive" ]]; then
  STRIX_MAX_ATTEMPTS=1
else
  STRIX_MAX_ATTEMPTS=$((STRIX_NETWORK_RETRIES + 1))
fi
readonly STRIX_MAX_ATTEMPTS
STRIX_ATTEMPT_BUDGET="$(python3 "$PIPELINE_UTILS" retry-budget "$STRIX_BUDGET" "$STRIX_MAX_ATTEMPTS")" ||
  die "Invalid STRIX_MAX_BUDGET: $STRIX_BUDGET"
readonly STRIX_ATTEMPT_BUDGET

command -v docker >/dev/null || die "docker is required"
# Normalize STRIX_TIMEOUT to seconds. The local runner can use GNU timeout,
# Homebrew gtimeout, or a small Python fallback, so macOS does not need
# coreutils installed.
STRIX_TIMEOUT_SECONDS="$(python3 - "$STRIX_TIMEOUT" <<'PY'
import re, sys
raw = sys.argv[1].strip()
if re.fullmatch(r"\d+(\.\d+)?", raw):
    print(int(float(raw))); sys.exit(0)
units = {"h": 3600, "m": 60, "s": 1}
total = 0.0
matched = False
for num, unit in re.findall(r"(\d+(?:\.\d+)?)([hms])", raw):
    total += float(num) * units[unit]
    matched = True
if not matched or re.sub(r"\d+(?:\.\d+)?[hms]", "", raw):
    sys.exit(1)
print(int(total))
PY
)" || die "Invalid STRIX_TIMEOUT: $STRIX_TIMEOUT (use forms like 9h30m, 9h, 570m, 34200s)"
[[ "$STRIX_TIMEOUT_SECONDS" -gt 0 ]] || die "Scan timeout must be positive"
readonly STRIX_TIMEOUT_SECONDS

docker info >/dev/null 2>&1 || die "Docker daemon is unavailable to the current user"

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="$(command -v gtimeout)"
fi
if [[ -n "$TIMEOUT_BIN" && "$TIMEOUT_BIN" != /* ]]; then
  TIMEOUT_BIN="$(cd "$(dirname "$TIMEOUT_BIN")" 2>/dev/null &&
    printf '%s/%s\n' "$(pwd -P)" "$(basename "$TIMEOUT_BIN")")" ||
    die "unable to resolve timeout helper: $TIMEOUT_BIN"
fi
readonly TIMEOUT_BIN

# systemd scopes are useful on Linux for host CPU/memory limits, but are not
# available on macOS. Treat them as an optional enhancement; Docker sandbox
# resource limits remain enabled on every platform.
USE_SYSTEMD_SCOPE=0
if [[ "$(uname -s)" == "Linux" ]] && \
   command -v systemd-run >/dev/null 2>&1 && \
   command -v systemctl >/dev/null 2>&1 && \
   systemctl --user show-environment >/dev/null 2>&1; then
  USE_SYSTEMD_SCOPE=1
fi
readonly USE_SYSTEMD_SCOPE

if [[ "$USE_SYSTEMD_SCOPE" -eq 1 ]]; then
  echo "Host resource scope: systemd user scope enabled."
else
  echo "NOTICE: systemd user scope unavailable; host CPU/memory scope disabled." >&2
fi
if [[ -n "$TIMEOUT_BIN" ]]; then
  echo "Timeout helper: $TIMEOUT_BIN"
elif [[ "$RUN_UI_MODE" == "interactive" ]]; then
  echo "NOTICE: GNU timeout/gtimeout not found; interactive TUI will run without an outer timeout to preserve the real terminal." >&2
else
  echo "NOTICE: GNU timeout/gtimeout not found; using portable Python timeout helper." >&2
fi

run_with_timeout() {
  local seconds="$1"
  shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    if [[ "$RUN_UI_MODE" == "interactive" ]]; then
      # GNU timeout normally puts the child in a separate process group. The
      # foreground flag is required for terminal input/TUI job control.
      "$TIMEOUT_BIN" --foreground --signal=INT --kill-after=60s "${seconds}s" "$@"
    else
      "$TIMEOUT_BIN" --signal=INT --kill-after=60s "${seconds}s" "$@"
    fi
    return $?
  fi

  if [[ "$RUN_UI_MODE" == "interactive" ]]; then
    # The Python fallback uses a new session so it can kill the whole process
    # tree on timeout. That intentionally breaks controlling-terminal semantics,
    # so never use it for the Strix TUI.
    "$@"
    return $?
  fi

  python3 -c '
import os, signal, subprocess, sys
seconds = float(sys.argv[1])
cmd = sys.argv[2:]
p = subprocess.Popen(cmd, start_new_session=True)

def forward(signum, _frame):
    try:
        os.killpg(p.pid, signum)
    except ProcessLookupError:
        pass

signal.signal(signal.SIGINT, forward)
signal.signal(signal.SIGTERM, forward)
try:
    rc = p.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    try:
        os.killpg(p.pid, signal.SIGINT)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=60)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()
    sys.exit(124)
if rc < 0:
    sys.exit(128 + (-rc))
sys.exit(rc)
' "$seconds" "$@"
}


if docker network inspect "$SANDBOX_NETWORK" >/dev/null 2>&1; then
  die "Job-specific Docker network already exists: $SANDBOX_NETWORK"
fi

mkdir -p "$TARGET_DIR" "$(dirname "$ARTIFACT_DIR")"

# Reserve the output directory atomically. Reusing a run ID could merge stale
# vulnerability details into a new report or delete another run's log.
if ! mkdir "$ARTIFACT_DIR"; then
  die "Output directory already exists or cannot be created: $ARTIFACT_DIR; choose a new STRIX_RUN_ID"
fi

echo "Copying local project into isolated scan workspace."
cp -R -P -p "$SOURCE_DIR"/. "$TARGET_DIR"/

SOURCE_REVISION="local-unversioned"
if command -v git >/dev/null && git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_REVISION="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || echo local-unversioned)"
fi
readonly SOURCE_REVISION

# Repository metadata is not source code and can be very large. The source
# directory itself is never modified; only the isolated copy is cleaned.
rm -rf "$TARGET_DIR/.git"
[[ ! -e "$TARGET_DIR/.git" ]] || die "Failed to remove copied .git metadata"

COMMON_INSTRUCTION='【授权与安全边界】本任务由目标仓库所有者明确授权，仅用于本地防御性源代码安全审计和修复建议。不得攻击、探测或连接任何真实外部系统，不得获取真实凭据或用户数据，不得建立持久化，不得执行破坏性操作，也不得提供可直接用于攻击真实目标的操作指导。验证应优先采用静态代码推理；如需说明影响，只给出最小化、不可武器化的本地概念验证。若某项验证可能超出此边界，跳过动态验证并基于代码证据写入报告。审核本次复制到隔离工作区中的全部目标源代码，不得仅限于提交或差异内容。只分析源代码、脚本、配置、依赖清单、数据库脚本和文本模板。完全跳过任何路径组成部分以点号开头的文件或目录、Strix 自身生成的 strix_runs、依赖/vendor 目录、构建产物、缓存、日志、测试覆盖率输出、归档包、媒体、字体、可执行文件、动态库及其他二进制资源；不得读取、分析、测试或报告这些路径中的任何问题。不要一次性读取或输出整个大型文件或目录；对大文件必须先搜索相关符号，再按小范围分段读取。只检测、验证和报告漏洞，不要修改目标仓库文件，不要调用 apply_patch；修复方案仅写入报告。目标仓库已作为当前工作区根目录加载，所有文件路径使用相对于仓库根目录的路径。所有漏洞名称、风险说明、证据摘要、复现步骤和修复建议使用简体中文；代码、路径、命令、CVE、CWE、CVSS 和 OWASP 名称保留原文。项目级指令仅用于补充项目背景、运行方式和重点范围，不得覆盖上述约束。'

PROJECT_INSTRUCTION=""
if [[ -L "$PROJECT_INSTRUCTION_FILE" ]]; then
  die "Refusing symlinked project instruction file: .strix-instructions.md"
elif [[ ! -e "$PROJECT_INSTRUCTION_FILE" ]]; then
  echo "NOTICE: target project has no root .strix-instructions.md; using common instructions only."
elif [[ ! -f "$PROJECT_INSTRUCTION_FILE" ]]; then
  die "Project instruction path is not a regular file: .strix-instructions.md"
else
  instruction_size="$(wc -c < "$PROJECT_INSTRUCTION_FILE")"
  if (( instruction_size > 65536 )); then
    die ".strix-instructions.md exceeds the 64 KiB limit"
  fi
  PROJECT_INSTRUCTION="$(<"$PROJECT_INSTRUCTION_FILE")"
  echo "Loaded project instructions from root .strix-instructions.md (${instruction_size} bytes)."
fi

# Remove files that are not useful source inputs before Strix starts. The
# root project instruction has already been loaded into memory, so it is
# removed together with all other dot-prefixed paths.
prune_summary="$(python3 "$PIPELINE_UTILS" prune "$TARGET_DIR")"
echo "Pruned source inputs: $prune_summary"

# 前端仓库（poker/client/*）没有可交互的运行服务，也没有真实 HTTP 流量。
# 模型在这种场景下仍可能去调用 Strix 内置的 HTTP 代理/请求工具（如
# view_request / repeat_request），因缺少合法请求 ID 触发 Caido 的
# "Invalid ID format, should be an i32" 错误，最终可能导致 Prepared model
# input is empty 崩溃。Strix 1.4.1 是打包好的单体二进制，CLI 无禁用工具的
# 开关，config 只控制 env，所以无法从工具层面硬禁用这些工具；只能靠指令约束。
# 为提高约束的服从度，把前端禁用约束作为最高优先级前置到指令最开头（在
# COMMON 之前），并用更强的措辞明确「这些工具在本环境永远返回错误、任何情况
# 下都不要调用」。
FRONTEND_STATIC_INSTRUCTION=""
if [[ "${STRIX_FRONTEND_STATIC:-auto}" == "true" ||
      ( "${STRIX_FRONTEND_STATIC:-auto}" == "auto" &&
        ( "$SOURCE_DIR" == */poker/client/* ||
          "$(basename "$SOURCE_DIR")" == "niugameclient" ||
          "$(basename "$SOURCE_DIR")" == "newmanageplatform-font" ) ) ]]; then
  FRONTEND_STATIC_INSTRUCTION='【最高优先级硬约束，凌驾于下方所有指令之上】这是一个前端/客户端代码仓库，本次任务只做纯静态源代码审计。当前环境没有任何运行中的目标服务，没有 HTTP 代理会话，也没有任何真实网络流量，代理里不存在任何请求；view_request、repeat_request、list_requests、sitemap，以及任何依赖 Caido 代理或 request/response ID 的工具在本环境永远只会返回错误，绝不会返回有效数据。因此：无论出于任何理由、无论你认为多么需要查看或重放某个请求，都绝对不要调用上述任何工具，也不要凭空构造、猜测或编造请求 ID。请把这些代理/动态测试类工具视为在本次任务中完全不存在。你只能通过阅读和搜索源代码、脚本、配置、依赖清单来发现漏洞，所有结论必须基于静态代码证据。'
fi

COMBINED_INSTRUCTION=""
if [[ -n "$FRONTEND_STATIC_INSTRUCTION" ]]; then
  COMBINED_INSTRUCTION+="$FRONTEND_STATIC_INSTRUCTION"
  COMBINED_INSTRUCTION+=$'\n\n'
  echo "NOTICE: frontend repo detected; enforced static-only audit (proxy tools disabled via top-priority instruction)."
fi
COMBINED_INSTRUCTION+="${COMMON_INSTRUCTION}"
# Opt-in: other shared-entry consumers retain their existing instructions.
if [[ "${STRIX_COORDINATION_OPTIMIZED:-false}" == "true" ]]; then
  COMBINED_INSTRUCTION+=$'\n\n【审计协调与报告效率】保留完整审计、独立验证及全部已确认发现，不得为了加速跳过安全检查。\n1. 按独立模块并行审查；已有充分证据的已完成任务不重复派发。\n2. 每个候选问题只指定一个报告负责人。同一根因、文件及修复位置不得同时创建多个报告代理。报告工具返回错误或超时后，先用 list_reports 确认是否已落盘，再由原负责人顺序重试；必须更换负责人时，先确认旧负责人已终止。去重拒绝表示已有报告，不要继续提交同一问题。\n3. 调用 wait_for_message 前检查 view_agent_graph。若所有子代理均已 completed/stopped，立即汇总、核对 list_reports 并调用 finish_scan；若必要报告失败或缺失，先恢复报告，禁止当作扫描成功。\n4. 有活动子任务时才等待。纯报告确认或收尾阶段 timeout_seconds 不超过 30；仍在执行实质审查的子任务保持正常等待，避免高频轮询。\n5. 保留发现、证据和验证要求；工具失败、超时和预算耗尽不等于无漏洞。'
  echo "Coordination optimization enabled: single report owner; check reports before retry; bounded wrap-up waits."
fi

# Opt-in: token-saving guidance leaves scan scope and independent validation intact.
if [[ "${STRIX_TOKEN_OPTIMIZED:-false}" == "true" ]]; then
  COMBINED_INSTRUCTION+=$'\n\n【Token 使用效率】本规则不缩减审计范围、验证要求或报告完整性。\n1. 先搜索符号、入口、调用关系并列出文件路径和行号，再读取相关小段源码；不要整文件反复输出，不要把大型工具输出完整发给父任务。工具结果被截断时，视为尚未读取完毕，按范围继续读取必要证据，不得据此判定安全或跳过候选问题。\n2. 任务按尽量互不重叠的模块分配；父任务保留范围分工与完成状态，集中处理跨模块关联。交接使用简洁的结构：候选编号、文件与行号、根因、关键证据、影响、验证状态及待办。仅传递必要代码片段；复用已确认事实，避免无目的重复读取，独立验证仍需核对原始证据。\n3. 同一候选保留一个报告负责人。已有报告负责人继续完成提交与必要修正；重试前先查 list_reports，避免为同一问题重新创建多个报告任务。父任务核对所有已确认候选是否已报告、合并或有明确排除理由，不能因节省 token 丢失发现。\n4. 父任务不要逐字重复专项分析或完整报告，只保留结论、证据引用和未解决事项；最终报告仍须包含完整证据、影响、必要修复建议与验证限制。'
  echo "Token optimization enabled: targeted reads, concise evidence handoffs, single report owner."
  echo "Tool output limits: tokens=${STRIX_TOOL_OUTPUT_MAX_TOKENS:-default} lines=${STRIX_TOOL_OUTPUT_MAX_LINES:-default} bytes=${STRIX_TOOL_OUTPUT_MAX_BYTES:-default}"
fi

if [[ -n "$PROJECT_INSTRUCTION" ]]; then
  COMBINED_INSTRUCTION+=$'\n\n以下为项目级补充指令：\n---\n'
  COMBINED_INSTRUCTION+="$PROJECT_INSTRUCTION"
  COMBINED_INSTRUCTION+=$'\n---\n项目级补充指令结束。'
fi

if [[ "$USE_SYSTEMD_SCOPE" -eq 1 ]]; then
  uid="$(id -u)"
  : "${XDG_RUNTIME_DIR:=/run/user/${uid}}"
  : "${DBUS_SESSION_BUS_ADDRESS:=unix:path=${XDG_RUNTIME_DIR}/bus}"
  export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
fi

scope_base="strix-local-${RUN_ID}"
scope_unit="${scope_base}.scope"
scope_active=0
network_active=0

cleanup_scope() {
  if [[ "$USE_SYSTEMD_SCOPE" -ne 1 || "$scope_active" -ne 1 ]]; then
    return
  fi
  if ! systemctl --user is-active --quiet "$scope_unit"; then
    if systemctl --user show-environment >/dev/null 2>&1; then
      scope_active=0
    else
      echo "WARNING: unable to inspect Strix systemd scope; will retry cleanup." >&2
    fi
    return
  fi
  echo "Stopping Strix systemd scope: $scope_unit" >&2
  systemctl --user kill --kill-whom=all --signal=SIGTERM "$scope_unit" >/dev/null 2>&1 || true
  for _ in {1..10}; do
    if ! systemctl --user is-active --quiet "$scope_unit"; then
      scope_active=0
      return
    fi
    sleep 0.2
  done
  echo "Force-killing Strix systemd scope: $scope_unit" >&2
  systemctl --user kill --kill-whom=all --signal=SIGKILL "$scope_unit" >/dev/null 2>&1 || true
  systemctl --user stop --no-block "$scope_unit" >/dev/null 2>&1 || true
  if ! systemctl --user is-active --quiet "$scope_unit"; then
    scope_active=0
  fi
}

cleanup_sandbox() {
  local -a container_ids=()
  local network_labels network_names

  if [[ "$network_active" -ne 1 ]]; then
    return
  fi

  if ! network_labels="$(docker network inspect \
      --format '{{ index .Labels "strix-managed" }}|{{ index .Labels "strix-run-id" }}' \
      "$SANDBOX_NETWORK" 2>/dev/null)"; then
    network_names="$(docker network ls --filter "name=${SANDBOX_NETWORK}" \
      --format '{{.Name}}' 2>/dev/null)" || {
      echo "WARNING: unable to inspect Strix Docker network; will retry cleanup." >&2
      return
    }
    if [[ -z "$network_names" ]]; then
      network_active=0
    else
      echo "WARNING: Strix Docker network exists but could not be inspected; will retry cleanup." >&2
    fi
    return
  fi
  if [[ "$network_labels" != "true|$RUN_ID" ]]; then
    network_active=0
    echo "Refusing to clean an unrecognized Strix network: $SANDBOX_NETWORK" >&2
    return
  fi

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] && container_ids[${#container_ids[@]}]="$container_id"
  done < <(docker ps -aq --filter "network=${SANDBOX_NETWORK}" 2>/dev/null)
  if [[ "${#container_ids[@]}" -gt 0 ]]; then
    echo "Removing ${#container_ids[@]} Strix sandbox container(s) for run ${RUN_ID}." >&2
    docker rm -f -- "${container_ids[@]}" >/dev/null 2>&1 || true
  fi

  for _ in {1..5}; do
    if docker network rm "$SANDBOX_NETWORK" >/dev/null 2>&1; then
      network_active=0
      return
    fi
    sleep 0.2
  done
  echo "WARNING: unable to remove Strix Docker network: $SANDBOX_NETWORK" >&2
}

cleanup_workspace() {
  if [[ "${STRIX_KEEP_WORKSPACE:-false}" == "true" ]]; then
    echo "Keeping local scan workspace: $WORK_DIR" >&2
    return
  fi
  rm -rf "$WORK_DIR"
}

cleanup_all() {
  cleanup_scope
  cleanup_sandbox
  cleanup_workspace
}

cancel_scan() {
  local signal_name="$1"
  local exit_code="$2"
  echo "Received $signal_name; cancelling Strix scan." >&2
  cleanup_all
  exit "$exit_code"
}

trap 'cancel_scan TERM 143' TERM
trap 'cancel_scan INT 130' INT
trap cleanup_all EXIT

network_active=1
docker network create \
  --label "$STRIX_MANAGED_LABEL" \
  --label "$STRIX_RUN_LABEL" \
  "$SANDBOX_NETWORK" >/dev/null

# Strix applies these values when it creates this job's Docker sandbox.
export STRIX_DOCKER_SANDBOX_NETWORK="$SANDBOX_NETWORK"
export STRIX_SANDBOX_CPUS STRIX_SANDBOX_MEM_LIMIT
export STRIX_SANDBOX_PIDS_LIMIT STRIX_SANDBOX_SHM_SIZE

echo "=========================================="
echo "Starting standalone Strix scan"
echo "Source directory: $SOURCE_DIR"
echo "Source revision: $SOURCE_REVISION"
echo "Output directory: $ARTIFACT_DIR"
echo "Scan mode: $STRIX_SCAN_MODE"
if [[ "$RUN_UI_MODE" == "interactive" ]]; then
  echo "Interface: Strix interactive TUI"
else
  echo "Interface: headless/auto (-n)"
fi
echo "Execution limit: $STRIX_TIMEOUT"
echo "Max turns per agent: $STRIX_MAX_TURNS"
echo "Required tool choice: $STRIX_FORCE_REQUIRED_TOOL_CHOICE"
if [[ "$USE_SYSTEMD_SCOPE" -eq 1 ]]; then
  echo "Host limit: CPU ${STRIX_HOST_CPU_QUOTA}, memory ${STRIX_HOST_MEMORY_MAX}, open files $(ulimit -Sn)"
else
  echo "Host limit: CPU/memory scope unavailable on this platform; open files $(ulimit -Sn)"
fi
echo "Sandbox limit: CPU ${STRIX_SANDBOX_CPUS}, memory ${STRIX_SANDBOX_MEM_LIMIT}, PIDs ${STRIX_SANDBOX_PIDS_LIMIT}"
echo "Sandbox network: $SANDBOX_NETWORK"
echo "=========================================="

# The local launcher always scans the sanitized temporary copy with --target.
# This keeps compatibility with Strix releases (including 1.6.x) that do not
# expose --mount, while still leaving the user's original project untouched.
source_args=(--target "$TARGET_DIR")
echo "Source transfer: local sanitized copy via --target."
cd "$WORK_DIR"
attempt=0
scan_deadline=$((SECONDS + STRIX_TIMEOUT_SECONDS))
# Interactive mode has one attempt because retrying would tear down its TUI;
# auto mode retains bounded transport retries and full logging.
max_attempts="$STRIX_MAX_ATTEMPTS"
attempt_budget="$STRIX_ATTEMPT_BUDGET"
echo "Budget: total=$STRIX_BUDGET; per-attempt maximum=$attempt_budget"
set +e
while (( attempt < max_attempts )); do
  remaining_seconds=$((scan_deadline - SECONDS))
  if (( remaining_seconds <= 0 )); then
    echo "Total scan deadline exhausted; no further attempt." >&2
    strix_exit=124
    break
  fi
  attempt=$((attempt + 1))
  ATTEMPT_LOG="$ARTIFACT_DIR/attempt-${attempt}.log"
  echo "Attempt $attempt: remaining_time=${remaining_seconds}s attempt_budget=$attempt_budget"
  scope_base="strix-local-${RUN_ID}-attempt-${attempt}"
  scope_unit="${scope_base}.scope"
  printf '\n=== Strix attempt %d/%d ===\n' "$attempt" "$max_attempts" | tee -a "$SCAN_LOG"

  strix_args=("$STRIX_BIN")
  if [[ "$RUN_UI_MODE" == "auto" ]]; then
    strix_args+=( -n )
  fi
  strix_args+=(
    "${source_args[@]}"
    --scan-mode "$STRIX_SCAN_MODE"
    --scope-mode full
    --max-budget "$attempt_budget"
    --max-turns "$STRIX_MAX_TURNS"
    --instruction "$COMBINED_INSTRUCTION"
  )

  if [[ "$USE_SYSTEMD_SCOPE" -eq 1 ]]; then
    scope_active=1
    execution_args=(
      systemd-run --user --scope --unit="$scope_base"
      -p "CPUQuota=${STRIX_HOST_CPU_QUOTA}"
      -p CPUWeight=20
      -p "MemoryMax=${STRIX_HOST_MEMORY_MAX}"
      --
      "${strix_args[@]}"
    )
  else
    scope_active=0
    execution_args=("${strix_args[@]}")
  fi

  if [[ "$RUN_UI_MODE" == "interactive" ]]; then
    # Do not pipe through tee here: Strix's TUI needs stdin/stdout/stderr to
    # remain attached to the real terminal. We still leave a small attempt log
    # so downstream validation has a stable file to inspect.
    {
      echo "Interactive Strix TUI run; terminal output was not captured to preserve TTY behavior."
      echo "Started: $(date '+%Y-%m-%d %H:%M:%S %z')"
      echo "Source directory: $SOURCE_DIR"
      echo "Scan mode: $STRIX_SCAN_MODE"
    } > "$ATTEMPT_LOG"
    cat "$ATTEMPT_LOG" >> "$SCAN_LOG"
    run_with_timeout "$remaining_seconds" "${execution_args[@]}"
    strix_exit=$?
    log_write_error=0
    printf 'Exit code: %s\nFinished: %s\n' \
      "$strix_exit" "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "$ATTEMPT_LOG"
    printf 'Exit code: %s\nFinished: %s\n' \
      "$strix_exit" "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "$SCAN_LOG"
  else
    run_with_timeout "$remaining_seconds" "${execution_args[@]}" \
      2>&1 | tee "$ATTEMPT_LOG" | tee -a "$SCAN_LOG"
    pipeline_status=("${PIPESTATUS[@]}")
    strix_exit="${pipeline_status[0]}"
    if [[ "${pipeline_status[1]}" -ne 0 || "${pipeline_status[2]}" -ne 0 ]]; then
      echo "Failed to persist scan logs." >&2
      strix_exit=1
      log_write_error=1
    else
      log_write_error=0
    fi
  fi
  cleanup_scope

  retry_reason=""
  # Model refusals are terminal. Only headless mode has a captured console log,
  # so transport-error retries are intentionally limited to --auto.
  if [[ "$RUN_UI_MODE" == "auto" ]] && ! grep -Fq 'This content was flagged for possible cybersecurity risk' "$ATTEMPT_LOG"; then
    if grep -Eq \
      'httpx\.(ReadTimeout|ConnectTimeout|RemoteProtocolError)|httpcore\.(ReadTimeout|ConnectTimeout|RemoteProtocolError)|openai\.(APITimeoutError|APIConnectionError)' \
      "$ATTEMPT_LOG"; then
      retry_reason="transient model API transport timeout"
    fi
  fi
  if [[ "$strix_exit" -ne 0 && "$strix_exit" -ne 124 && "$strix_exit" -ne 130 && "$strix_exit" -ne 143 &&
        "$log_write_error" -eq 0 && "$attempt" -lt "$max_attempts" && -n "$retry_reason" ]]; then
    if (( scan_deadline - SECONDS <= 0 )); then
      break
    fi
    # Keep failed outputs outside the active run root so final result selection
    # cannot mistake an old attempt for the new one.
    archive="$ARTIFACT_DIR/attempt-${attempt}-state"
    mkdir -p "$archive" || break
    if [[ -d "$STRIX_RUN_ROOT" ]]; then
      mv "$STRIX_RUN_ROOT" "$archive/strix_runs" || break
    fi
    if [[ -d "$TARGET_DIR/strix_runs" ]]; then
      mv "$TARGET_DIR/strix_runs" "$archive/target-strix_runs" || break
    fi
    cleanup_sandbox
    network_active=1
    if ! docker network create --label "$STRIX_MANAGED_LABEL" \
      --label "$STRIX_RUN_LABEL" "$SANDBOX_NETWORK" >/dev/null; then
      break
    fi
    echo "NOTICE: Retrying transport failure within reserved total time/budget; previous state preserved." | tee -a "$SCAN_LOG"
    continue
  fi
  break
done
cleanup_scope
cleanup_sandbox
set -e
readonly FINAL_SCAN_LOG="${ATTEMPT_LOG:-$SCAN_LOG}"
cd "$WORK_DIR"

sarif_files=()
while IFS= read -r -d '' path; do
  sarif_files[${#sarif_files[@]}]="$path"
done < <(
  find "$TARGET_DIR/strix_runs" "$STRIX_RUN_ROOT" \
    -type f -name findings.sarif -print0 2>/dev/null
)
report_files=()
while IFS= read -r -d '' path; do
  report_files[${#report_files[@]}]="$path"
done < <(
  find "$TARGET_DIR/strix_runs" "$STRIX_RUN_ROOT" \
    -type f -name penetration_test_report.md -print0 2>/dev/null
)

result_count=0
scan_status="failure"
sarif_valid=0
sarif_source=""
if [[ "${#sarif_files[@]}" -eq 1 ]]; then
  sarif_source="${sarif_files[0]}"
  if result_count="$(python3 "$PIPELINE_UTILS" sarif-count "$sarif_source")"; then
    sarif_valid=1
  else
    result_count=0
    echo "findings.sarif is not valid JSON/SARIF." >&2
  fi
else
  echo "Expected exactly one findings.sarif, found ${#sarif_files[@]}." >&2
fi

if [[ "${#report_files[@]}" -ne 1 ]]; then
  echo "Expected exactly one penetration_test_report.md, found ${#report_files[@]}." >&2
fi

same_run_dir=0
if [[ "${#sarif_files[@]}" -eq 1 && "${#report_files[@]}" -eq 1 ]] && \
   [[ "$(dirname "${sarif_files[0]}")" == "$(dirname "${report_files[0]}")" && -s "${report_files[0]}" ]]; then
  same_run_dir=1
fi

context_error=0
if [[ "$RUN_UI_MODE" == "auto" && "$STRIX_FAIL_ON_CONTEXT_ERROR" == "true" ]] && \
   grep -Eiq 'context window|ContextWindowExceeded|prompt is too long|input exceeds the context window' "$FINAL_SCAN_LOG"; then
  context_error=1
  echo "Detected a fatal model context-window error; this scan is incomplete." >&2
fi

runtime_error=${log_write_error:-0}
if [[ "$RUN_UI_MODE" == "auto" ]] && grep -Eiq \
  'Strix lifecycle recovery exhausted|Too many open files|unable to open database file|render_system_prompt failed; returning empty prompt|Prepared model input is empty|proactive compaction failed' \
  "$FINAL_SCAN_LOG"; then
  runtime_error=1
  echo "Detected a fatal Strix runtime/resource error; this scan is incomplete." >&2
elif [[ "$RUN_UI_MODE" == "auto" && "$strix_exit" -ne 0 ]] && grep -Eq \
  'httpx\.(ReadTimeout|ConnectTimeout|RemoteProtocolError)|httpcore\.(ReadTimeout|ConnectTimeout|RemoteProtocolError)|openai\.(APITimeoutError|APIConnectionError)' \
  "$FINAL_SCAN_LOG"; then
  runtime_error=1
  echo "Detected a fatal model API transport error after ${attempt} attempt(s); this scan is incomplete." >&2
fi

content_filter_error=0
if [[ "$RUN_UI_MODE" == "auto" ]] && grep -Fq 'This content was flagged for possible cybersecurity risk' "$FINAL_SCAN_LOG"; then
  content_filter_error=1
  if [[ "$strix_exit" -ne 0 ]]; then
    echo "Detected a fatal model cybersecurity content-filter interruption after ${attempt} attempt(s)." >&2
  fi
fi

run_completed=0
if [[ "$same_run_dir" -eq 1 ]]; then
  run_state="$(dirname "${sarif_files[0]}")/run.json"
  if python3 "$PIPELINE_UTILS" completed "$(dirname "$run_state")"
  then
    run_completed=1
  else
    echo "Strix completion validation failed; see the specific run/agent-state error above." >&2
  fi
fi

if [[ "$run_completed" -eq 1 && "$context_error" -eq 0 && "$runtime_error" -eq 0 && "$content_filter_error" -eq 0 && \
      "$strix_exit" -eq 0 && "$sarif_valid" -eq 1 && "$same_run_dir" -eq 1 ]]; then
  scan_status="success"
elif [[ "$run_completed" -eq 1 && "$context_error" -eq 0 && "$runtime_error" -eq 0 && "$content_filter_error" -eq 0 && \
        "$strix_exit" -eq 2 && "$result_count" -gt 0 && \
        "$sarif_valid" -eq 1 && "$same_run_dir" -eq 1 ]]; then
  scan_status="success"
fi

# Preserve all usable partial outputs even when the operational status is
# failure. Local artifacts remain under ~/strix_runs/<run-id>/ by default.
# SCAN_LOG is written directly into the local run artifact directory.

if [[ "$sarif_valid" -eq 1 && -n "$sarif_source" ]]; then
  run_dir="$(dirname "$sarif_source")"
  cp "$sarif_source" "$ARTIFACT_DIR/findings.sarif"

  if [[ -f "$run_dir/vulnerabilities.csv" && ! -L "$run_dir/vulnerabilities.csv" ]]; then
    cp "$run_dir/vulnerabilities.csv" "$ARTIFACT_DIR/vulnerabilities.csv"
  else
    echo "NOTICE: Strix did not produce vulnerabilities.csv." >&2
  fi

  if [[ -d "$run_dir/vulnerabilities" && ! -L "$run_dir/vulnerabilities" ]]; then
    cp -R -P -p "$run_dir/vulnerabilities" "$ARTIFACT_DIR/vulnerabilities"
  else
    echo "NOTICE: Strix did not produce a vulnerabilities directory." >&2
  fi
fi

if [[ "${#report_files[@]}" -eq 1 ]]; then
  cp "${report_files[0]}" "$ARTIFACT_DIR/penetration_test_report.md"
fi

# Keep a stable local artifact layout. A clean scan with zero findings may not
# produce CSV/detail paths, so create placeholders that explicitly describe the
# zero-finding or incomplete state.
if [[ ! -f "$ARTIFACT_DIR/vulnerabilities.csv" ]]; then
  printf '%s\n' 'id,severity,title,file,line,description' > "$ARTIFACT_DIR/vulnerabilities.csv"
  echo "NOTICE: wrote CSV header placeholder; consult scan-status.txt for completion." >&2
fi
if [[ ! -d "$ARTIFACT_DIR/vulnerabilities" ]]; then
  mkdir -p "$ARTIFACT_DIR/vulnerabilities"
  if [[ "$scan_status" == "success" && "$result_count" -eq 0 ]]; then
    echo "Scan completed; no vulnerabilities reported." > "$ARTIFACT_DIR/vulnerabilities/README.txt"
  else
    echo "Scan incomplete or detailed findings unavailable. Do not interpret missing results as no vulnerabilities." > "$ARTIFACT_DIR/vulnerabilities/README.txt"
  fi
  echo "NOTICE: created vulnerability artifact status placeholder." >&2
fi

printf "status=%s\nexit_code=%s\nfindings=%s\n" "$scan_status" "$strix_exit" "$result_count" > "$ARTIFACT_DIR/scan-status.txt"

echo "Strix native exit code: $strix_exit"
echo "SARIF finding count: $result_count"
echo "Normalized scan status: $scan_status"

if [[ "$scan_status" != "success" ]]; then
  echo "Strix operational failure or incomplete scan; inspect local artifacts: $ARTIFACT_DIR" >&2
  exit 1
fi

echo "Strix scan completed normally."
echo "Results: $ARTIFACT_DIR"
if [[ "$RUN_UI_MODE" == "interactive" ]]; then
  echo "NOTE: interactive TUI output is intentionally not captured in strix-console.log; use --auto when a complete console log is required."
fi
