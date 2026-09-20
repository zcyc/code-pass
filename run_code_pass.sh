#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

usage() {
  cat <<'USAGE'
Usage:
  run_code_pass.sh [--interactive|--auto] [--max-rounds N] \
    [--verify-cmd "command"] <local-project-dir> [quick|standard|deep]

The loop runs a bounded Strix scan -> Pi remediation cycle. It stops when:
  - the scan is incomplete or operationally failed;
  - no findings remain (then the optional verify command is run);
  - Pi makes no change;
  - the same finding fingerprint returns in the next scan; or
  - the round limit is reached.

Examples:
  ./run_code_pass.sh --auto --verify-cmd "npm test" ~/src/my-project standard
  ./run_code_pass.sh --auto --verify-cmd "pytest -q" ~/src/my-project quick
  CODE_PASS_MAX_ROUNDS=2 ./run_code_pass.sh --auto ~/src/my-project

Environment:
  CODE_PASS_OUTPUT_DIR          Default: ~/code_pass_runs
  CODE_PASS_MAX_ROUNDS          Default: 3
  CODE_PASS_MAX_TOTAL_BUDGET    Total Strix budget split across rounds; defaults to STRIX_MAX_BUDGET or 50
  CODE_PASS_VERIFY_CMD          Optional trusted local verification command
  STRIX_MAX_BUDGET              Used as the total loop budget unless overridden above
  PI_TIMEOUT                    Optional timeout passed through to run_pi.sh

CODE_PASS_VERIFY_CMD and --verify-cmd are operator-provided local commands.
USAGE
}

die() {
  echo "ERROR: $*" >&2
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

parse_findings() {
  local sarif_file="$1"
  local fingerprint_file="$2"

  python3 - "$sarif_file" "$fingerprint_file" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

sarif_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
with sarif_path.open("r", encoding="utf-8") as handle:
    document = json.load(handle)
if not isinstance(document, dict) or not isinstance(document.get("runs"), list):
    raise SystemExit("invalid SARIF: missing runs")

fingerprints = set()

def text_value(value):
    return re.sub(r"\s+", " ", value).strip() if isinstance(value, str) else ""

for run in document["runs"]:
    if not isinstance(run, dict):
        continue
    for result in run.get("results", []):
        if not isinstance(result, dict):
            continue
        rule_id = text_value(result.get("ruleId"))
        if rule_id.startswith("strix-coverage/"):
            continue

        partial = result.get("partialFingerprints")
        if isinstance(partial, dict) and partial:
            identity = "partial:" + json.dumps(
                partial, sort_keys=True, ensure_ascii=False
            )
        else:
            locations = []
            for location in result.get("locations", []):
                physical = location.get("physicalLocation", {}) if isinstance(location, dict) else {}
                artifact = physical.get("artifactLocation", {}) if isinstance(physical, dict) else {}
                region = physical.get("region", {}) if isinstance(physical, dict) else {}
                if not isinstance(artifact, dict):
                    artifact = {}
                if not isinstance(region, dict):
                    region = {}
                locations.append({
                    "uri": text_value(artifact.get("uri", "")),
                    "startLine": region.get("startLine", 0),
                    "startColumn": region.get("startColumn", 0),
                    "endLine": region.get("endLine", 0),
                })
            locations.sort(key=lambda item: json.dumps(item, sort_keys=True))
            message = result.get("message", {})
            message_text = message.get("text", "") if isinstance(message, dict) else ""
            identity = json.dumps({
                "rule": rule_id,
                "level": text_value(result.get("level")),
                "locations": locations,
                "message": "" if locations else text_value(message_text),
            }, sort_keys=True, ensure_ascii=False, separators=(",", ":"))

        fingerprints.add(hashlib.sha256(identity.encode("utf-8")).hexdigest())

ordered = sorted(fingerprints)
output_path.write_text("".join(f"{item}\n" for item in ordered), encoding="utf-8")
digest = hashlib.sha256("\n".join(ordered).encode("utf-8")).hexdigest()
print(f"{len(ordered)} {digest}")
PY
}

budget_for_round() {
  python3 - "$1" "$2" <<'PY'
import math
import sys
total = float(sys.argv[1])
rounds = int(sys.argv[2])
if not math.isfinite(total) or total <= 0 or rounds < 1:
    raise SystemExit("budget must be a finite positive number")
print(f"{total / rounds:.12f}".rstrip("0").rstrip("."))
PY
}

run_self_test() {
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/code-pass-self-test.XXXXXX")"
  trap 'rm -rf "$temp_dir"' RETURN
  printf '%s\n' '{"runs":[{"results":[{"ruleId":"R1","level":"warning","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/a.js"},"region":{"startLine":4}}}],"message":{"text":"same finding"}}]}]}' > "$temp_dir/one.sarif"
  local first second
  first="$(parse_findings "$temp_dir/one.sarif" "$temp_dir/one.txt")"
  second="$(parse_findings "$temp_dir/one.sarif" "$temp_dir/two.txt")"
  [[ "$first" == "$second" ]] || die "self-test fingerprint is not stable"
  [[ "$(wc -l < "$temp_dir/one.txt" | tr -d ' ')" == "1" ]] || die "self-test finding count is wrong"
  echo "run_code_pass self-test: ok"
}

run_verification() {
  local round="$1"
  local log_file="$RUN_DIR/verify-round-$round.log"
  if [[ -z "$VERIFY_CMD" ]]; then
    echo "Verification: skipped (no command supplied)."
    return 0
  fi

  echo "Verification: $VERIFY_CMD"
  set +e
  (
    cd "$PROJECT_DIR"
    bash -c "$VERIFY_CMD"
  ) >"$log_file" 2>&1
  local verify_status=$?
  set -e
  if (( verify_status != 0 )); then
    echo "Verification failed with exit code $verify_status; see $log_file" >&2
    return "$verify_status"
  fi
  echo "Verification passed."
}

changed_paths_from_diff() {
  local diff_file="$1"
  sed -n 's/^diff --git a\/\(.*\) b\/.*$/\1/p' "$diff_file" | sort -u
}

RUN_MODE="${CODE_PASS_RUN_UI_MODE:-auto}"
MAX_ROUNDS="${CODE_PASS_MAX_ROUNDS:-3}"
TOTAL_BUDGET="${CODE_PASS_MAX_TOTAL_BUDGET:-${STRIX_MAX_BUDGET:-50}}"
VERIFY_CMD="${CODE_PASS_VERIFY_CMD:-}"
PROJECT_ARG=""
SCAN_MODE_ARG=""
SELF_TEST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive)
      RUN_MODE="interactive"
      shift
      ;;
    --auto|--headless)
      RUN_MODE="auto"
      shift
      ;;
    --max-rounds)
      [[ $# -ge 2 ]] || die "--max-rounds requires a positive integer"
      MAX_ROUNDS="$2"
      shift 2
      ;;
    --verify-cmd)
      [[ $# -ge 2 ]] || die "--verify-cmd requires a command"
      VERIFY_CMD="$2"
      shift 2
      ;;
    --self-test)
      SELF_TEST=true
      shift
      ;;
    --version)
      echo "run_code_pass $VERSION"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$PROJECT_ARG" ]] || [[ -z "$SCAN_MODE_ARG" ]] || die "too many positional arguments"
      if [[ -z "$PROJECT_ARG" ]]; then
        PROJECT_ARG="$1"
      else
        SCAN_MODE_ARG="$1"
      fi
      shift
      ;;
  esac
done

if [[ "$SELF_TEST" == true ]]; then
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  run_self_test
  exit 0
fi

case "$RUN_MODE" in
  interactive|auto) ;;
  *) die "CODE_PASS_RUN_UI_MODE must be interactive or auto: $RUN_MODE" ;;
esac
[[ "$MAX_ROUNDS" =~ ^[1-9][0-9]*$ ]] || die "max rounds must be a positive integer: $MAX_ROUNDS"
[[ -n "$PROJECT_ARG" ]] || {
  usage >&2
  die "project directory is required"
}
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
[[ -x "$SCRIPT_DIR/run_strix.sh" ]] || die "run_strix.sh is missing or not executable"
[[ -x "$SCRIPT_DIR/run_pi.sh" ]] || die "run_pi.sh is missing or not executable"

if [[ -n "$TOTAL_BUDGET" ]]; then
  python3 - "$TOTAL_BUDGET" <<'PY'
import math
import sys
value = float(sys.argv[1])
if not math.isfinite(value) or value <= 0:
    raise SystemExit("total budget must be a finite positive number")
PY
fi

PROJECT_DIR="$(canonicalize_path "$PROJECT_ARG")" || die "cannot resolve project directory"
[[ -d "$PROJECT_DIR" ]] || die "project directory does not exist: $PROJECT_ARG"
[[ "$PROJECT_DIR" != "/" ]] || die "refusing to operate on filesystem root"
[[ "$PROJECT_DIR" != *$'\n'* ]] || die "project path must not contain a newline"
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "run_code_pass.sh requires a Git worktree for no-progress detection"

SCAN_MODE="${SCAN_MODE_ARG:-${STRIX_SCAN_MODE:-quick}}"
case "$SCAN_MODE" in
  quick|standard|deep) ;;
  *) die "unsupported scan mode: $SCAN_MODE" ;;
esac

PROJECT_NAME="$(basename "$PROJECT_DIR" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$PROJECT_NAME" ]] || PROJECT_NAME="project"
PROJECT_NAME="$(printf '%s' "$PROJECT_NAME" | cut -c1-24)"

: "${HOME:?HOME is required}"
OUTPUT_ROOT="${CODE_PASS_OUTPUT_DIR:-$HOME/code_pass_runs}"
OUTPUT_ROOT="$(canonicalize_path "$OUTPUT_ROOT")" || die "cannot resolve output directory"
case "$OUTPUT_ROOT/" in
  "$PROJECT_DIR/"*) die "CODE_PASS_OUTPUT_DIR must be outside the project directory: $OUTPUT_ROOT" ;;
esac

RUN_ID="$PROJECT_NAME-$(date '+%Y%m%d-%H%M%S')-$$"
RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR/strix" "$RUN_DIR/pi"
SUMMARY_FILE="$RUN_DIR/summary.md"
printf '%s\n' "# code-pass run $RUN_ID" "" > "$SUMMARY_FILE"

echo "code-pass run: $RUN_ID"
echo "Project: $PROJECT_DIR"
echo "Scan mode: $SCAN_MODE"
echo "Max rounds: $MAX_ROUNDS"
echo "Output: $RUN_DIR"
if [[ -n "$VERIFY_CMD" ]]; then
  echo "Verify command: $VERIFY_CMD"
else
  echo "Verify command: not configured"
fi

previous_digest=""
for ((round = 1; round <= MAX_ROUNDS; round++)); do
  scan_id="round-$round"
  scan_dir="$RUN_DIR/strix/$scan_id"
  scan_log="$RUN_DIR/scan-round-$round.log"
  fingerprint_file="$RUN_DIR/findings-round-$round.txt"
  round_budget=""
  if [[ -n "$TOTAL_BUDGET" ]]; then
    round_budget="$(budget_for_round "$TOTAL_BUDGET" "$MAX_ROUNDS")"
  fi

  echo
  echo "=== Round $round/$MAX_ROUNDS: Strix ==="
  set +e
  if [[ "$RUN_MODE" == "auto" ]]; then
    if [[ -n "$round_budget" ]]; then
      env STRIX_OUTPUT_DIR="$RUN_DIR/strix" \
        STRIX_RUN_ID="$scan_id" \
        STRIX_MAX_BUDGET="$round_budget" \
        "$SCRIPT_DIR/run_strix.sh" --auto "$PROJECT_DIR" "$SCAN_MODE" \
        >"$scan_log" 2>&1
    else
      env STRIX_OUTPUT_DIR="$RUN_DIR/strix" \
        STRIX_RUN_ID="$scan_id" \
        "$SCRIPT_DIR/run_strix.sh" --auto "$PROJECT_DIR" "$SCAN_MODE" \
        >"$scan_log" 2>&1
    fi
    scan_status_code=$?
    cat "$scan_log"
  else
    if [[ -n "$round_budget" ]]; then
      env STRIX_OUTPUT_DIR="$RUN_DIR/strix" \
        STRIX_RUN_ID="$scan_id" \
        STRIX_MAX_BUDGET="$round_budget" \
        "$SCRIPT_DIR/run_strix.sh" --interactive "$PROJECT_DIR" "$SCAN_MODE"
    else
      env STRIX_OUTPUT_DIR="$RUN_DIR/strix" \
        STRIX_RUN_ID="$scan_id" \
        "$SCRIPT_DIR/run_strix.sh" --interactive "$PROJECT_DIR" "$SCAN_MODE"
    fi
    scan_status_code=$?
  fi
  set -e

  if [[ "$scan_status_code" -ne 0 ]]; then
    printf '%s\n' "- round=$round status=scan_failed exit=$scan_status_code" >> "$SUMMARY_FILE"
    echo "STOP: Strix failed or produced an incomplete scan." >&2
    exit 1
  fi

  status_file="$scan_dir/scan-status.txt"
  sarif_file="$scan_dir/findings.sarif"
  [[ -f "$status_file" && -f "$sarif_file" ]] || {
    echo "STOP: Strix did not produce the expected result files." >&2
    exit 1
  }
  scan_status="$(sed -n 's/^status=//p' "$status_file" | head -n1 | tr -d '\r')"
  [[ "$scan_status" == "success" ]] || {
    echo "STOP: scan status is '$scan_status', not success." >&2
    exit 1
  }
  read -r findings_count findings_digest <<< "$(parse_findings "$sarif_file" "$fingerprint_file")"
  printf '%s\n' "- round=$round status=scan_ok findings=$findings_count fingerprint=$findings_digest" >> "$SUMMARY_FILE"
  echo "Findings: $findings_count"
  echo "Finding fingerprint: $findings_digest"

  if [[ "$findings_count" == "0" ]]; then
    if run_verification "$round"; then
      printf '%s\n' "- result=pass" >> "$SUMMARY_FILE"
      echo "PASS: no findings remain and verification passed/skipped."
      exit 0
    fi
    printf '%s\n' "- result=verification_failed" >> "$SUMMARY_FILE"
    echo "STOP: verification failed; this security-only Pi loop will not spend more scan tokens." >&2
    exit 4
  fi

  if [[ -n "$previous_digest" && "$findings_digest" == "$previous_digest" ]]; then
    printf '%s\n' "- result=stalled reason=repeated-finding-fingerprint" >> "$SUMMARY_FILE"
    echo "STOP: the same findings returned after remediation; no more Pi tokens will be spent." >&2
    exit 3
  fi
  previous_digest="$findings_digest"

  if (( round == MAX_ROUNDS )); then
    printf '%s\n' "- result=round_limit" >> "$SUMMARY_FILE"
    echo "STOP: maximum rounds reached with findings remaining." >&2
    exit 3
  fi

  pi_root="$RUN_DIR/pi/round-$round"
  mkdir -p "$pi_root"
  pi_log="$RUN_DIR/pi-round-$round.log"
  echo "=== Round $round/$MAX_ROUNDS: Pi ==="
  set +e
  if [[ "$RUN_MODE" == "auto" ]]; then
    env PI_OUTPUT_DIR="$pi_root" \
      "$SCRIPT_DIR/run_pi.sh" --auto "$PROJECT_DIR" "$scan_dir" \
      >"$pi_log" 2>&1
    pi_status_code=$?
    cat "$pi_log"
  else
    env PI_OUTPUT_DIR="$pi_root" \
      "$SCRIPT_DIR/run_pi.sh" --interactive "$PROJECT_DIR" "$scan_dir"
    pi_status_code=$?
  fi
  set -e
  if [[ "$pi_status_code" -ne 0 ]]; then
    printf '%s\n' "- round=$round status=pi_failed exit=$pi_status_code" >> "$SUMMARY_FILE"
    echo "STOP: Pi failed; no automatic retry." >&2
    exit 1
  fi

  pi_diff="$(find "$pi_root" -type f -name changes.diff -print -quit 2>/dev/null || true)"
  [[ -n "$pi_diff" && -f "$pi_diff" ]] || {
    echo "STOP: Pi did not produce changes.diff; no-progress state is unknown." >&2
    exit 3
  }
  changed_paths="$(changed_paths_from_diff "$pi_diff")"
  if [[ -z "$changed_paths" ]]; then
    printf '%s\n' "- round=$round result=stalled reason=pi_no_change" >> "$SUMMARY_FILE"
    echo "STOP: Pi made no repository change." >&2
    exit 3
  fi
  changed_count="$(printf '%s\n' "$changed_paths" | sed '/^$/d' | wc -l | tr -d ' ')"
  printf '%s\n' "- round=$round pi_changed_files=$changed_count" >> "$SUMMARY_FILE"
  echo "Pi changed $changed_count file(s); the next scan is the only allowed retry."
done

printf '%s\n' "- result=round_limit" >> "$SUMMARY_FILE"
echo "STOP: maximum rounds reached." >&2
exit 3
