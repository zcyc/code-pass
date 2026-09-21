/**
 * /strix-fix-loop — bounded Strix scan → Pi fix → rescan loop.
 *
 * The extension owns the whole workflow inside the current Pi session:
 *   1. copy the project into a sanitized temporary workspace,
 *   2. run a headless Strix scan in a dedicated Docker network,
 *   3. hand the SARIF findings to the current agent for triage and repair,
 *   4. rescan and stop on pass, repeated findings, no change, failure, or round limit.
 *
 * Load with `pi -e ./extensions/strix-fix-loop.ts`, install the repository as a
 * Pi package, or copy the extension into ~/.pi/agent/extensions/.
 */
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { Box, Text } from "@earendil-works/pi-tui";
import { execFile, spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { createWriteStream, promises as fs } from "node:fs";
import type { FileHandle } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import {
  USAGE,
  budgetPerAttempt,
  buildFixPrompt,
  buildInstruction,
  completedRunError,
  fingerprintDigest,
  isBinaryHeader,
  messageOf,
  parseArgs,
  parseVersion,
  sanitizeName,
  sarifFindings,
  shouldPruneEntry,
  versionAtLeast,
  type LoopOptions,
} from "./strix-core.ts";

const STATUS_KEY = "strix-fix-loop";
const ENTRY_TYPE = "strix-fix-loop";
const READ_ONLY_TOOLS = new Set(["read", "grep", "find", "ls"]);
const MIN_STRIX_VERSION: [number, number, number] = [1, 4, 1];

const CONTEXT_ERROR_NEEDLES = [
  "context window",
  "ContextWindowExceeded",
  "prompt is too long",
  "input exceeds the context window",
];
const RUNTIME_ERROR_NEEDLES = [
  "Strix lifecycle recovery exhausted",
  "Too many open files",
  "unable to open database file",
  "render_system_prompt failed; returning empty prompt",
  "Prepared model input is empty",
  "proactive compaction failed",
];
const CONTENT_FILTER_NEEDLES = ["This content was flagged for possible cybersecurity risk"];

const COPIED_ARTIFACTS = [
  "findings.sarif",
  "penetration_test_report.md",
  "run.json",
  "strix.log",
  "vulnerabilities.json",
  "coverage.json",
  "vulnerabilities.csv",
];

const COMPLETION_SUGGESTIONS = [
  "quick", "standard", "deep",
  "--scan-mode", "--scope-mode", "--max-budget", "--max-turns", "--max-rounds",
  "--dry-run", "--keep-workspace", "--output-dir", "--target", "--instruction",
  "--instruction-file", "--help",
];

interface LoopEntry {
  title: string;
  lines: string[];
  tone?: "info" | "success" | "warning" | "error";
}

interface RunState {
  pi: ExtensionAPI;
  ctx: ExtensionCommandContext;
  options: LoopOptions;
  project: string;
  runId: string;
  runDir: string;
  summaryFile: string;
  summaryLines: string[];
  strixBin: string;
  dockerBin: string;
  roundBudget: string;
  instruction: string;
}

interface RoundScan {
  status: "success" | "failure";
  error?: string;
  exitCode: number;
  scanDir: string;
  sarif: string;
  report: string;
  findings: number;
  coverage: number;
  totalResults: number;
  fingerprints: string[];
  digest: string;
}

interface RoundFix {
  fixDir: string;
  diffPath: string;
  baselineAvailable: boolean;
  changedPaths: string[];
}

interface LoopOutcome {
  kind: "pass" | "stalled" | "round_limit" | "scan_failed" | "fix_unavailable";
  message: string;
}

interface CaptureResult {
  stdout: string;
  stderr: string;
  code: number;
}

let loopRunning = false;
const activeChildren = new Set<ChildProcess>();

export default function strixFixLoop(pi: ExtensionAPI): void {
  pi.registerEntryRenderer<LoopEntry>(ENTRY_TYPE, renderLoopEntry);

  pi.on("session_shutdown", () => {
    for (const child of activeChildren) killProcessTree(child, "SIGTERM");
    activeChildren.clear();
  });

  pi.registerCommand("strix-fix-loop", {
    description: "Strix scan → Pi triage/fix → rescan (bounded loop)",
    getArgumentCompletions: (prefix) => {
      const items = COMPLETION_SUGGESTIONS
        .filter((item) => item.startsWith(prefix))
        .map((item) => ({ value: item, label: item }));
      return items.length > 0 ? items : null;
    },
    handler: async (rawArgs, ctx) => {
      const options = parseArgs(rawArgs, process.env);
      if (options.help) {
        appendLoopEntry(pi, { title: "strix-fix-loop usage", lines: USAGE.split("\n") });
        ctx.ui.notify("strix-fix-loop: usage added to the transcript", "info");
        return;
      }
      if (options.errors.length > 0) {
        appendLoopEntry(pi, {
          title: "strix-fix-loop: invalid arguments",
          lines: [...options.errors.map((item) => `error: ${item}`), "", ...USAGE.split("\n")],
          tone: "error",
        });
        ctx.ui.notify(`strix-fix-loop: ${options.errors[0]}`, "error");
        return;
      }
      if (loopRunning) {
        ctx.ui.notify("strix-fix-loop: a run is already active in this session", "warning");
        return;
      }
      if (!ctx.isIdle()) {
        ctx.ui.notify("strix-fix-loop: wait for the current turn to finish, then retry", "warning");
        return;
      }
      loopRunning = true;
      try {
        await runStrixFixLoop(pi, ctx, options);
      } catch (error) {
        const text = messageOf(error);
        appendLoopEntry(pi, { title: "strix-fix-loop: failed", lines: [text], tone: "error" });
        ctx.ui.notify(`strix-fix-loop: ${text}`, "error");
      } finally {
        loopRunning = false;
        ctx.ui.setStatus(STATUS_KEY, undefined);
      }
    },
  });
}

function renderLoopEntry(entry: { data?: LoopEntry }, options: { expanded: boolean }, theme: {
  bold: (text: string) => string;
  fg: (color: string, text: string) => string;
  bg: (color: string, text: string) => string;
}): Box | undefined {
  const data = entry.data;
  if (data === undefined) return undefined;
  const color = data.tone === "error"
    ? "error"
    : data.tone === "success"
      ? "success"
      : data.tone === "warning"
        ? "warning"
        : "accent";
  const box = new Box(1, 1, (text: string) => theme.bg("customMessageBg", text));
  box.addChild(new Text(theme.fg(color, theme.bold(data.title)), 0, 0));
  const visible = options.expanded ? data.lines : data.lines.slice(0, 6);
  for (const line of visible) box.addChild(new Text(theme.fg("dim", line), 0, 0));
  if (!options.expanded && data.lines.length > visible.length) {
    box.addChild(new Text(theme.fg("muted", `… ${data.lines.length - visible.length} more`), 0, 0));
  }
  return box;
}

function appendLoopEntry(pi: ExtensionAPI, entry: LoopEntry): void {
  pi.appendEntry<LoopEntry>(ENTRY_TYPE, entry);
}

async function runStrixFixLoop(pi: ExtensionAPI, ctx: ExtensionCommandContext, options: LoopOptions): Promise<void> {
  const project = await canonicalPath(options.project !== "" ? resolve(ctx.cwd, options.project) : ctx.cwd);
  const projectStat = await fs.stat(project);
  if (!projectStat.isDirectory()) throw new Error(`project directory does not exist: ${project}`);
  if (project === "/" || project.includes("\n")) {
    throw new Error("refusing to operate on the filesystem root or a path containing a newline");
  }
  const gitCheck = await execCapture("git", ["rev-parse", "--is-inside-work-tree"], { cwd: project });
  if (gitCheck.code !== 0 || gitCheck.stdout.trim() !== "true") {
    throw new Error("strix-fix-loop requires a Git worktree for change tracking");
  }

  const outputRoot = await canonicalPath(expandHome(options.outputRoot));
  requireOutside(project, outputRoot, "output directory");
  const tempRoot = await canonicalPath(tmpdir());
  requireOutside(project, tempRoot, "TMPDIR");
  await fs.mkdir(outputRoot, { recursive: true, mode: 0o700 });

  const strixBin = await resolveStrixBinary(options.strixBin);
  await inspectDocker();
  const roundBudget = budgetPerAttempt(options.maxBudget, options.maxRounds);

  let userInstruction = options.instruction;
  if (options.instructionFile !== "") {
    userInstruction = await readInstructionFile(resolve(ctx.cwd, options.instructionFile));
  }
  const projectInstruction = await readProjectInstruction(project);
  const instruction = buildInstruction({
    frontendStatic: options.frontendStatic,
    coordinationOptimized: options.coordinationOptimized,
    tokenOptimized: options.tokenOptimized,
    projectInstruction,
    userInstruction,
  });

  const runId = `${sanitizeName(basename(project), 24)}-${timestamp()}-${process.pid}`;
  const runDir = join(outputRoot, runId);
  await fs.mkdir(runDir, { recursive: false, mode: 0o700 });
  await fs.mkdir(join(runDir, "strix"), { recursive: true, mode: 0o700 });
  await fs.mkdir(join(runDir, "pi"), { recursive: true, mode: 0o700 });
  const summaryFile = join(runDir, "summary.md");
  await fs.writeFile(summaryFile, `# strix-fix-loop ${runId}\n\n`, { mode: 0o600 });

  const state: RunState = {
    pi,
    ctx,
    options,
    project,
    runId,
    runDir,
    summaryFile,
    summaryLines: [],
    strixBin,
    dockerBin: "docker",
    roundBudget,
    instruction,
  };

  progress(state, `run ${runId}: starting`);
  appendLoopEntry(pi, {
    title: `strix-fix-loop ${runId}`,
    lines: [
      `project: ${project}`,
      `scan mode: ${options.scanMode}, rounds: ${options.maxRounds}, budget/round: ${roundBudget}`,
      `dry run: ${options.dryRun}, keep workspace: ${options.keepWorkspace}`,
      `output: ${runDir}`,
    ],
  });

  const outcome = await executeRounds(state);
  await addSummary(state, `- result=${outcome.kind}`);
  const tail = state.summaryLines.slice(-10);
  appendLoopEntry(pi, {
    title: `strix-fix-loop: ${outcome.kind}`,
    lines: [...tail, `artifacts: ${runDir}`],
    tone: outcome.kind === "pass" ? "success" : "warning",
  });
  ctx.ui.notify(`strix-fix-loop: ${outcome.message}`, outcome.kind === "pass" ? "info" : "warning");
}

async function executeRounds(state: RunState): Promise<LoopOutcome> {
  let previousDigest = "";
  for (let round = 1; round <= state.options.maxRounds; round++) {
    progress(state, `round ${round}/${state.options.maxRounds}: Strix ${state.options.scanMode} scan`);
    let scan: RoundScan;
    try {
      scan = await scanRound(state, round);
    } catch (error) {
      await addSummary(state, `- round=${round} status=scan_error`);
      return { kind: "scan_failed", message: `round ${round}: Strix failed to run: ${messageOf(error)}` };
    }
    await addSummary(
      state,
      `- round=${round} status=${scan.status} findings=${scan.findings} coverage=${scan.coverage} digest=${scan.digest}`,
    );
    if (scan.status !== "success") {
      return { kind: "scan_failed", message: scan.error ?? `Strix did not complete successfully (see ${scan.scanDir})` };
    }
    appendLoopEntry(state.pi, {
      title: `round ${round}/${state.options.maxRounds}: scan ok`,
      lines: [
        `findings: ${scan.findings}`,
        `coverage checks: ${scan.coverage}`,
        `fingerprint: ${scan.digest.slice(0, 12)}`,
        `artifacts: ${scan.scanDir}`,
      ],
    });
    if (scan.findings === 0) {
      return { kind: "pass", message: `no findings remain after ${round} round(s)` };
    }
    if (previousDigest !== "" && scan.digest === previousDigest) {
      return {
        kind: "stalled",
        message: "the same findings returned after remediation; stopping before spending more budget",
      };
    }
    previousDigest = scan.digest;
    if (round === state.options.maxRounds) {
      return { kind: "round_limit", message: `maximum rounds reached with ${scan.findings} finding(s) remaining` };
    }

    progress(state, `round ${round}/${state.options.maxRounds}: Pi triage and fix`);
    const fix = await fixRound(state, round, scan);
    await addSummary(state, `- round=${round} pi_changed_files=${fix.changedPaths.length}`);
    if (!fix.baselineAvailable) {
      return { kind: "fix_unavailable", message: `cannot compute the round ${round} change baseline; inspect ${fix.fixDir}` };
    }
    if (fix.changedPaths.length === 0) {
      return { kind: "stalled", message: "Pi made no repository change; stopping the loop" };
    }
    appendLoopEntry(state.pi, {
      title: `round ${round}: Pi changed ${fix.changedPaths.length} file(s)`,
      lines: [
        ...fix.changedPaths.slice(0, 8),
        ...(fix.changedPaths.length > 8 ? [`… and ${fix.changedPaths.length - 8} more`] : []),
        `diff: ${fix.diffPath}`,
      ],
      tone: "success",
    });
  }
  return { kind: "round_limit", message: "maximum rounds reached" };
}

async function scanRound(state: RunState, round: number): Promise<RoundScan> {
  const roundDir = join(state.runDir, "strix", `round-${round}`);
  await fs.mkdir(roundDir, { recursive: true, mode: 0o700 });
  const workRoot = await fs.mkdtemp(join(tmpdir(), `strix-fix-loop-${state.runId}-${round}.`));
  const targetDir = join(workRoot, "target");
  const network = `strix-fix-loop-${sanitizeName(state.runId, 40)}-${round}`;
  const consoleLog = join(roundDir, "strix-console.log");
  let networkCreated = false;
  try {
    progress(state, `round ${round}/${state.options.maxRounds}: copying and sanitizing the project`);
    await fs.cp(state.project, targetDir, { recursive: true, dereference: false, verbatimSymlinks: true });
    await fs.rm(join(targetDir, ".git"), { recursive: true, force: true });
    const pruned = await pruneTree(targetDir);
    await addSummary(state, `- round=${round} pruned_dirs=${pruned.directories} pruned_files=${pruned.files}`);
    await fs.writeFile(join(roundDir, "instruction.md"), state.instruction, { mode: 0o600 });

    progress(state, `round ${round}/${state.options.maxRounds}: preparing Strix Docker network`);
    await createNetwork(state.dockerBin, network);
    networkCreated = true;

    const args = [
      "-n",
      "--target", targetDir,
      "--scan-mode", state.options.scanMode,
      "--scope-mode", state.options.scopeMode,
      "--max-budget", state.roundBudget,
      "--max-turns", String(state.options.maxTurns),
      "--instruction", state.instruction,
    ];
    progress(state, `round ${round}/${state.options.maxRounds}: Strix ${state.options.scanMode} scan running`);
    let lastStatusUpdate = 0;
    const { code, timedOut } = await spawnLogged(state.strixBin, args, {
      cwd: roundDir,
      env: strixEnvironment(network),
      timeoutMs: state.options.timeoutMs,
      logPath: consoleLog,
      onLine: (line) => {
        const now = Date.now();
        if (now - lastStatusUpdate < 500) return;
        lastStatusUpdate = now;
        progress(state, `round ${round} Strix: ${line.slice(0, 140)}`);
      },
    });
    return await finalizeRound(state, round, roundDir, targetDir, timedOut ? 124 : code);
  } finally {
    if (networkCreated && !(await removeNetwork(state.dockerBin, network))) {
      await addSummary(state, `- round=${round} warning=docker_network_not_removed name=${network}`);
    }
    if (state.options.keepWorkspace) {
      await addSummary(state, `- round=${round} workspace=${workRoot}`);
    } else {
      await fs.rm(workRoot, { recursive: true, force: true });
    }
  }
}

async function finalizeRound(
  state: RunState,
  round: number,
  roundDir: string,
  targetDir: string,
  exitCode: number,
): Promise<RoundScan> {
  const sarifs = await findFilesNamed([roundDir, targetDir], "findings.sarif");
  const reports = await findFilesNamed([roundDir, targetDir], "penetration_test_report.md");
  let sarifPath = sarifs.length === 1 ? sarifs[0] : "";
  let reportPath = reports.length === 1 ? reports[0] : "";
  let artifactsDir = sarifPath === "" ? roundDir : dirname(sarifPath);

  if (sarifPath !== "" && artifactsDir !== roundDir) {
    await copyRunArtifacts(artifactsDir, roundDir);
    sarifPath = join(roundDir, "findings.sarif");
    reportPath = reportPath === "" ? "" : join(roundDir, basename(reportPath));
    artifactsDir = roundDir;
  }
  const reportExists = reportPath !== "" && (await pathExists(reportPath));
  const sameRun = sarifPath !== "" && reportExists && dirname(sarifPath) === dirname(reportPath);

  let sarifValid = false;
  let total = 0;
  let coverage = 0;
  let fingerprints: string[] = [];
  if (sarifPath !== "") {
    try {
      const parsed = sarifFindings(JSON.parse(await fs.readFile(sarifPath, "utf8")));
      fingerprints = parsed.fingerprints;
      total = parsed.total;
      coverage = parsed.coverage;
      sarifValid = true;
    } catch (error) {
      await addSummary(state, `- round=${round} sarif_invalid=${messageOf(error)}`);
    }
  }
  const findings = total - coverage;

  let runCompleted = false;
  let runJsonError = "run.json is missing";
  if (sarifPath !== "") {
    try {
      const runJson = JSON.parse(await fs.readFile(join(dirname(sarifPath), "run.json"), "utf8"));
      runJsonError = completedRunError(runJson) ?? "";
      runCompleted = runJsonError === "";
    } catch (error) {
      runJsonError = messageOf(error);
    }
  }

  const logs = [
    join(roundDir, "strix-console.log"),
    join(roundDir, "strix.log"),
    ...(sarifPath === "" ? [] : [join(dirname(sarifPath), "strix.log")]),
  ];
  const contextError = state.options.failOnContextError && (await containsAny(logs, CONTEXT_ERROR_NEEDLES));
  const runtimeError = await containsAny(logs, RUNTIME_ERROR_NEEDLES);
  const contentFilter = await containsAny(logs, CONTENT_FILTER_NEEDLES);

  let status: "success" | "failure" = "failure";
  const cleanRun = runCompleted && !contextError && !runtimeError && !contentFilter && sameRun && sarifValid;
  if (cleanRun && (exitCode === 0 || exitCode === 124)) status = "success";
  else if (cleanRun && exitCode === 2 && findings > 0) status = "success";

  const digest = fingerprintDigest(fingerprints);
  await fs.writeFile(
    join(roundDir, "scan-status.txt"),
    `status=${status}\nexit_code=${exitCode}\nfindings=${findings}\ncoverage=${coverage}\ntotal_results=${total}\n`,
    { mode: 0o600 },
  );
  await fs.writeFile(
    join(state.runDir, `findings-round-${round}.txt`),
    fingerprints.map((item) => `${item}\n`).join(""),
    { mode: 0o600 },
  );

  let error: string | undefined;
  if (status !== "success") {
    const reasons: string[] = [];
    if (!runCompleted) reasons.push(`run.json not completed (${runJsonError})`);
    if (!sameRun) reasons.push("findings.sarif and penetration_test_report.md are missing or belong to different runs");
    if (!sarifValid) reasons.push("findings.sarif is not valid SARIF");
    if (contextError) reasons.push("context window error detected");
    if (runtimeError) reasons.push("Strix runtime error detected");
    if (contentFilter) reasons.push("content filter triggered");
    if (exitCode !== 0 && exitCode !== 124 && !(exitCode === 2 && findings > 0)) reasons.push(`exit code ${exitCode}`);
    error = `round ${round}: Strix did not produce a successful, complete scan (${reasons.join("; ") || "unknown reason"}); inspect ${roundDir}`;
  }

  return {
    status,
    error,
    exitCode,
    scanDir: roundDir,
    sarif: sarifPath,
    report: reportPath,
    findings,
    coverage,
    totalResults: total,
    fingerprints,
    digest,
  };
}

async function fixRound(state: RunState, round: number, scan: RoundScan): Promise<RoundFix> {
  const fixDir = join(state.runDir, "pi", `round-${round}`);
  await fs.mkdir(fixDir, { recursive: true, mode: 0o700 });
  const statusAfterPath = join(fixDir, "git-status-after.txt");
  const diffPath = join(fixDir, "changes.diff");
  const baselineIndex = join(fixDir, "git-index-before");
  const afterIndex = join(fixDir, "git-index-after");

  await fs.writeFile(join(fixDir, "git-status-before.txt"), await gitStatus(state.project), { mode: 0o600 });
  let baselineTree = "";
  try {
    baselineTree = await indexTree(state.project, baselineIndex);
  } catch (error) {
    await addSummary(state, `- round=${round} baseline_error=${messageOf(error)}`);
  }

  const prompt = buildFixPrompt({
    project: state.project,
    sarif: scan.sarif,
    report: scan.report,
    dryRun: state.options.dryRun,
    allowBreaking: state.options.allowBreaking,
  });
  await fs.writeFile(join(fixDir, "prompt.md"), prompt, { mode: 0o600 });

  const readOnly = state.options.dryRun || !state.options.allowBreaking;
  const savedTools = state.pi.getActiveTools();
  if (readOnly) state.pi.setActiveTools(savedTools.filter((name) => READ_ONLY_TOOLS.has(name)));
  try {
    progress(state, `round ${round}: asking Pi to triage and fix ${scan.findings} finding(s)`);
    await askAgent(state, prompt);
  } finally {
    if (readOnly) state.pi.setActiveTools(savedTools);
  }

  await fs.writeFile(statusAfterPath, await gitStatus(state.project), { mode: 0o600 });

  let diffText: string;
  let baselineAvailable = baselineTree !== "";
  if (baselineTree !== "") {
    try {
      const afterTree = await indexTree(state.project, afterIndex);
      const env = await gitIndexEnvironment(state.project, afterIndex);
      const diff = await execCapture(
        "git",
        ["diff", "--cached", "--no-ext-diff", "--binary", baselineTree, "--"],
        { cwd: state.project, env },
      );
      if (diff.code !== 0) throw new Error(diff.stderr.trim() || "git diff failed");
      diffText = diff.stdout;
    } catch (error) {
      baselineAvailable = false;
      diffText = `# Unable to generate the change diff: ${messageOf(error)}\n`;
    }
  } else {
    diffText = "# Baseline diff unavailable; inspect git-status-before.txt and git-status-after.txt.\n";
  }
  await fs.writeFile(diffPath, diffText, { mode: 0o600 });
  await cleanupIndex(baselineIndex);
  await cleanupIndex(afterIndex);

  return { fixDir, diffPath, baselineAvailable, changedPaths: changedPaths(diffText) };
}

/**
 * Send the fix prompt to the current agent and wait for it to settle.
 *
 * pi.sendUserMessage() schedules the run asynchronously, so waitForIdle() may
 * race ahead of it; poll until the run (or compaction) is active, then wait for
 * the settled state. A 10s grace period keeps a preflight failure from hanging
 * the loop forever.
 */
async function askAgent(state: RunState, prompt: string): Promise<void> {
  if (!state.ctx.isIdle()) await state.ctx.waitForIdle();
  let settled = false;
  const unsubscribe = state.pi.on("agent_settled", () => {
    settled = true;
  });
  try {
    state.pi.sendUserMessage(prompt);
    const deadline = Date.now() + 10_000;
    while (!settled && state.ctx.isIdle() && Date.now() < deadline) await delay(100);
    if (!settled && !state.ctx.isIdle()) await state.ctx.waitForIdle();
  } finally {
    unsubscribe();
  }
}

async function addSummary(state: RunState, line: string): Promise<void> {
  state.summaryLines.push(line);
  await fs.appendFile(state.summaryFile, `${line}\n`);
}

function progress(state: RunState, text: string): void {
  state.ctx.ui.setStatus(STATUS_KEY, `strix-fix-loop: ${text}`);
}

async function copyRunArtifacts(sourceDir: string, destinationDir: string): Promise<void> {
  if (sourceDir === destinationDir) return;
  for (const name of COPIED_ARTIFACTS) {
    const source = join(sourceDir, name);
    try {
      const stat = await fs.stat(source);
      if (stat.isFile()) await fs.copyFile(source, join(destinationDir, name));
    } catch {
      // Artifact is optional.
    }
  }
  const sourceVulnerabilities = join(sourceDir, "vulnerabilities");
  try {
    const stat = await fs.stat(sourceVulnerabilities);
    if (!stat.isDirectory()) return;
    await fs.rm(join(destinationDir, "vulnerabilities"), { recursive: true, force: true });
    await fs.cp(sourceVulnerabilities, join(destinationDir, "vulnerabilities"), { recursive: true });
  } catch {
    // Artifact directory is optional.
  }
}

async function pruneTree(root: string): Promise<{ directories: number; files: number }> {
  let directories = 0;
  let files = 0;
  const walk = async (dir: string): Promise<void> => {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isSymbolicLink() || (!entry.isDirectory() && !entry.isFile())) {
        await fs.rm(path, { recursive: entry.isDirectory(), force: true });
        files++;
        continue;
      }
      if (entry.isDirectory()) {
        if (shouldPruneEntry(entry.name, true, false)) {
          await fs.rm(path, { recursive: true, force: true });
          directories++;
          continue;
        }
        await walk(path);
        continue;
      }
      if (shouldPruneEntry(entry.name, false, false)) {
        await fs.rm(path, { force: true });
        files++;
        continue;
      }
      if (await looksBinary(path)) {
        await fs.rm(path, { force: true });
        files++;
      }
    }
  };
  await walk(root);
  return { directories, files };
}

async function looksBinary(path: string): Promise<boolean> {
  let handle: FileHandle | undefined;
  try {
    handle = await fs.open(path, "r");
    const buffer = Buffer.alloc(4);
    const { bytesRead } = await handle.read(buffer, 0, 4, 0);
    return isBinaryHeader(buffer.subarray(0, bytesRead));
  } catch {
    return false;
  } finally {
    await handle?.close();
  }
}

async function findFilesNamed(roots: string[], name: string): Promise<string[]> {
  const found = new Set<string>();
  const walk = async (dir: string): Promise<void> => {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.isSymbolicLink()) continue;
      const path = join(dir, entry.name);
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile() && entry.name === name) found.add(resolve(path));
    }
  };
  for (const root of roots) await walk(root);
  return [...found].sort();
}

async function containsAny(paths: string[], needles: string[]): Promise<boolean> {
  for (const path of new Set(paths)) {
    let text: string;
    try {
      text = await fs.readFile(path, "utf8");
    } catch {
      continue;
    }
    for (const needle of needles) {
      if (text.includes(needle)) return true;
    }
  }
  return false;
}

async function readProjectInstruction(source: string): Promise<string> {
  const path = join(source, ".strix-instructions.md");
  let stat;
  try {
    stat = await fs.lstat(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return "";
    throw error;
  }
  if (stat.isSymbolicLink() || !stat.isFile()) {
    throw new Error("project instruction path is not a regular file: .strix-instructions.md");
  }
  if (stat.size > 65536) throw new Error(".strix-instructions.md exceeds the 64 KiB limit");
  return await fs.readFile(path, "utf8");
}

async function readInstructionFile(raw: string): Promise<string> {
  const path = resolve(raw);
  const stat = await fs.stat(path);
  if (!stat.isFile()) throw new Error(`instruction file is not a regular file: ${raw}`);
  if (stat.size > 65536) throw new Error(`instruction file exceeds the 64 KiB limit: ${raw}`);
  return await fs.readFile(path, "utf8");
}

async function resolveStrixBinary(configured: string): Promise<string> {
  const candidates = configured !== ""
    ? [expandHome(configured)]
    : ["strix", join(homedir(), ".strix", "bin", "strix")];
  for (const candidate of candidates) {
    const version = await tryExecCapture(candidate, ["-v"]);
    if (version === null) continue;
    let parsed: [number, number, number];
    try {
      parsed = parseVersion(`${version.stdout}\n${version.stderr}`);
    } catch {
      continue;
    }
    if (!versionAtLeast(parsed, MIN_STRIX_VERSION)) {
      throw new Error(`Strix ${parsed.join(".")} is too old; version 1.4.1 or newer is required`);
    }
    const help = await tryExecCapture(candidate, ["--help"]);
    if (help === null || help.code !== 0) throw new Error(`cannot read Strix CLI help: ${candidate}`);
    const helpText = `${help.stdout}\n${help.stderr}`;
    for (const required of ["--scan-mode", "--scope-mode", "--max-budget", "--max-turns", "--instruction"]) {
      if (!helpText.includes(required)) throw new Error(`Strix does not support required option: ${required}`);
    }
    return candidate;
  }
  throw new Error(
    `Strix executable not found (tried ${candidates.join(", ")}); set STRIX_BIN or install strix`,
  );
}

async function inspectDocker(): Promise<void> {
  const info = await tryExecCapture("docker", ["info"], { timeoutMs: 60_000 });
  if (info === null) throw new Error("docker executable not found; Docker Engine or Docker Desktop is required");
  if (info.code !== 0) throw new Error("Docker daemon is unavailable to the current user");
}

function strixEnvironment(network: string): NodeJS.ProcessEnv {
  return {
    ...process.env,
    STRIX_FORCE_REQUIRED_TOOL_CHOICE: "true",
    STRIX_DOCKER_SANDBOX_NETWORK: network,
    STRIX_SANDBOX_CPUS: process.env.STRIX_SANDBOX_CPUS || "2",
    STRIX_SANDBOX_MEM_LIMIT: process.env.STRIX_SANDBOX_MEM_LIMIT || "3g",
    STRIX_SANDBOX_PIDS_LIMIT: process.env.STRIX_SANDBOX_PIDS_LIMIT || "1024",
    STRIX_SANDBOX_SHM_SIZE: process.env.STRIX_SANDBOX_SHM_SIZE || "1g",
  };
}

async function createNetwork(dockerBin: string, name: string): Promise<void> {
  const existing = await execCapture(dockerBin, [
    "network", "ls", "--filter", `name=^${name}$`, "--format", "{{.Name}}",
  ]);
  if (existing.stdout.trim() !== "") throw new Error(`job-specific Docker network already exists: ${name}`);
  const created = await execCapture(dockerBin, ["network", "create", "--label", "strix-managed=true", name]);
  if (created.code !== 0) {
    throw new Error(`docker network create failed: ${created.stderr.trim() || created.stdout.trim()}`);
  }
}

async function removeNetwork(dockerBin: string, name: string): Promise<boolean> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const result = await execCapture(dockerBin, ["network", "rm", name]);
    if (result.code === 0) return true;
    await delay(200);
  }
  return false;
}

async function gitStatus(project: string): Promise<string> {
  const result = await execCapture("git", ["status", "--short", "--untracked-files=all"], { cwd: project });
  return result.code === 0 ? result.stdout : "";
}

async function gitIndexEnvironment(project: string, indexPath: string): Promise<NodeJS.ProcessEnv> {
  const objectDir = `${indexPath}.objects`;
  await fs.mkdir(objectDir, { recursive: true, mode: 0o700 });
  const gitPath = (await execCapture("git", ["rev-parse", "--git-path", "objects"], { cwd: project })).stdout.trim();
  const gitObjectDir = isAbsolute(gitPath) ? gitPath : join(project, gitPath);
  return {
    ...process.env,
    GIT_ALTERNATE_OBJECT_DIRECTORIES: gitObjectDir,
    GIT_INDEX_FILE: indexPath,
    GIT_OBJECT_DIRECTORY: objectDir,
  };
}

async function indexTree(project: string, indexPath: string): Promise<string> {
  const env = await gitIndexEnvironment(project, indexPath);
  const head = await execCapture("git", ["rev-parse", "--verify", "HEAD"], { cwd: project, env });
  const readTree = await execCapture("git", ["read-tree", head.code === 0 ? "HEAD" : "--empty"], { cwd: project, env });
  if (readTree.code !== 0) throw new Error(readTree.stderr.trim() || "git read-tree failed");
  const add = await execCapture("git", ["add", "-A", "--", "."], { cwd: project, env });
  if (add.code !== 0) throw new Error(add.stderr.trim() || "git add failed");
  const tree = await execCapture("git", ["write-tree"], { cwd: project, env });
  if (tree.code !== 0) throw new Error(tree.stderr.trim() || "git write-tree failed");
  return tree.stdout.trim();
}

async function cleanupIndex(indexPath: string): Promise<void> {
  await fs.rm(indexPath, { force: true });
  await fs.rm(`${indexPath}.objects`, { recursive: true, force: true });
}

function changedPaths(diffText: string): string[] {
  const paths = new Set<string>();
  for (const line of diffText.split("\n")) {
    if (!line.startsWith("diff --git a/")) continue;
    const rest = line.slice("diff --git a/".length);
    const index = rest.indexOf(" b/");
    if (index >= 0) paths.add(rest.slice(0, index));
  }
  return [...paths].sort();
}

interface SpawnLoggedOptions {
  cwd: string;
  env: NodeJS.ProcessEnv;
  timeoutMs: number;
  logPath: string;
  onLine?: (line: string) => void;
}

async function spawnLogged(
  command: string,
  args: string[],
  options: SpawnLoggedOptions,
): Promise<{ code: number; timedOut: boolean }> {
  const log = createWriteStream(options.logPath, { flags: "a", mode: 0o600 });
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: ["ignore", "pipe", "pipe"],
    detached: process.platform !== "win32",
  });
  log.on("error", () => {
    // A failed log stream must not crash the loop.
  });
  activeChildren.add(child);
  let timedOut = false;
  let killTimer: NodeJS.Timeout | undefined;
  const timer = options.timeoutMs > 0
    ? setTimeout(() => {
        timedOut = true;
        killProcessTree(child, "SIGTERM");
        killTimer = setTimeout(() => killProcessTree(child, "SIGKILL"), 10_000);
      }, options.timeoutMs)
    : undefined;

  const onChunk = (chunk: Buffer): void => {
    log.write(chunk);
    if (options.onLine === undefined) return;
    for (const line of chunk.toString("utf8").split(/\r?\n/)) {
      const trimmed = line.trim();
      if (trimmed !== "") options.onLine(trimmed);
    }
  };
  child.stdout?.on("data", onChunk);
  child.stderr?.on("data", onChunk);

  return await new Promise((resolvePromise, rejectPromise) => {
    const finish = (): void => {
      if (timer !== undefined) clearTimeout(timer);
      if (killTimer !== undefined) clearTimeout(killTimer);
      activeChildren.delete(child);
      log.end();
    };
    child.on("error", (error) => {
      finish();
      rejectPromise(error);
    });
    child.on("close", (code) => {
      finish();
      resolvePromise({ code: code ?? 1, timedOut });
    });
  });
}

function killProcessTree(child: ChildProcess, signal: NodeJS.Signals): void {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, signal);
  } catch {
    try {
      child.kill(signal);
    } catch {
      // Process already exited.
    }
  }
}

function execCapture(
  command: string,
  args: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv; timeoutMs?: number } = {},
): Promise<CaptureResult> {
  return new Promise((resolvePromise, rejectPromise) => {
    execFile(
      command,
      args,
      {
        cwd: options.cwd,
        env: options.env,
        timeout: options.timeoutMs,
        maxBuffer: 32 * 1024 * 1024,
        encoding: "utf8",
      },
      (error, stdout, stderr) => {
        const code = (error as { code?: unknown } | null)?.code;
        if (error !== null && typeof code === "string") {
          rejectPromise(error);
          return;
        }
        resolvePromise({
          stdout: String(stdout ?? ""),
          stderr: String(stderr ?? ""),
          code: error === null ? 0 : typeof code === "number" ? code : 1,
        });
      },
    );
  });
}

async function tryExecCapture(
  command: string,
  args: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv; timeoutMs?: number } = {},
): Promise<CaptureResult | null> {
  try {
    return await execCapture(command, args, options);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
}

async function canonicalPath(raw: string): Promise<string> {
  const absolute = resolve(raw);
  const missing: string[] = [];
  let current = absolute;
  for (;;) {
    try {
      const real = await fs.realpath(current);
      return missing.length === 0 ? real : join(real, ...missing.reverse());
    } catch {
      const parent = dirname(current);
      if (parent === current) throw new Error(`cannot resolve path: ${raw}`);
      missing.push(basename(current));
      current = parent;
    }
  }
}

function expandHome(raw: string): string {
  if (raw === "~") return homedir();
  if (raw.startsWith("~/")) return join(homedir(), raw.slice(2));
  return raw;
}

function isWithin(base: string, candidate: string): boolean {
  const rel = relative(base, candidate);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function requireOutside(base: string, candidate: string, label: string): void {
  if (isWithin(base, candidate)) throw new Error(`${label} must be outside the project directory: ${candidate}`);
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await fs.stat(path);
    return true;
  } catch {
    return false;
  }
}

function timestamp(): string {
  const now = new Date();
  const pad = (value: number): string => String(value).padStart(2, "0");
  return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}
