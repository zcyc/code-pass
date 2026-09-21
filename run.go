package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

func runLoopCLI(ctx context.Context, args []string) error {
	fs := newFlagSet("run")
	interactive := fs.Bool("interactive", false, "keep Strix and Pi attached to the terminal")
	auto := fs.Bool("auto", false, "run Strix and Pi non-interactively")
	headless := fs.Bool("headless", false, "alias for --auto")
	maxRoundsFlag := fs.Int("max-rounds", 0, "maximum scan/fix rounds")
	help := fs.Bool("help", false, "show help")
	showVersion := fs.Bool("version", false, "show version")
	if err := fs.Parse(args); err != nil {
		return &exitError{code: 2, err: err}
	}
	if *help {
		printLoopUsage(os.Stdout)
		return nil
	}
	if *showVersion {
		fmt.Println("codepass run", version)
		return nil
	}
	if *interactive && (*auto || *headless) {
		return &exitError{code: 2, err: errors.New("--interactive and --auto cannot be used together")}
	}
	positionals := fs.Args()
	if len(positionals) < 1 || len(positionals) > 2 {
		printLoopUsage(os.Stderr)
		return &exitError{code: 2, err: errors.New("project directory is required, with an optional scan mode")}
	}
	mode, err := configuredMode("CODE_PASS_RUN_UI_MODE", uiAuto)
	if err != nil {
		return err
	}
	if *interactive {
		mode = uiInteractive
	}
	if *auto || *headless {
		mode = uiAuto
	}
	maxRounds := *maxRoundsFlag
	if maxRounds == 0 {
		maxRounds, err = parsePositiveInt("CODE_PASS_MAX_ROUNDS", envString("CODE_PASS_MAX_ROUNDS", "3"))
		if err != nil {
			return err
		}
	} else if maxRounds < 1 {
		return &exitError{code: 2, err: errors.New("--max-rounds must be positive")}
	}
	scanMode := envString("STRIX_SCAN_MODE", "quick")
	if len(positionals) == 2 {
		scanMode = positionals[1]
	}
	return runLoop(ctx, positionals[0], scanMode, mode, maxRounds)
}

func printLoopUsage(w io.Writer) {
	fmt.Fprintln(w, `Usage:
  codepass run [--interactive|--auto] [--max-rounds N] <local-project-dir> [quick|standard|deep]

Environment:
  CODE_PASS_OUTPUT_DIR, CODE_PASS_MAX_ROUNDS, CODE_PASS_MAX_TOTAL_BUDGET
  CODE_PASS_RUN_UI_MODE, STRIX_MAX_BUDGET, PI_TIMEOUT`)
}

func runLoop(ctx context.Context, projectArg, scanMode string, mode uiMode, maxRounds int) error {
	if scanMode != "quick" && scanMode != "standard" && scanMode != "deep" {
		return &exitError{code: 2, err: fmt.Errorf("unsupported scan mode: %s", scanMode)}
	}
	project, err := canonicalPath(projectArg)
	if err != nil {
		return err
	}
	info, err := os.Stat(project)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("project directory does not exist: %s", projectArg)
	}
	if project == string(filepath.Separator) || strings.Contains(project, "\n") {
		return errors.New("refusing to operate on filesystem root or a path containing a newline")
	}
	if _, err := runGit(project, "rev-parse", "--is-inside-work-tree"); err != nil {
		return errors.New("codepass run requires a Git worktree for no-progress detection")
	}
	home, err := homeDir()
	if err != nil {
		return err
	}
	outputRoot := envString("CODE_PASS_OUTPUT_DIR", filepath.Join(home, "code_pass_runs"))
	outputRoot, err = canonicalPath(outputRoot)
	if err != nil {
		return err
	}
	if err := requireOutside(project, outputRoot, "CODE_PASS_OUTPUT_DIR"); err != nil {
		return err
	}
	runID := sanitizeName(filepath.Base(project), 24) + "-" + time.Now().Format("20060102-150405") + "-" + strconv.Itoa(os.Getpid())
	runDir := filepath.Join(outputRoot, runID)
	if err := os.MkdirAll(filepath.Join(runDir, "strix"), 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(runDir, "pi"), 0o700); err != nil {
		return err
	}
	summaryFile := filepath.Join(runDir, "summary.md")
	if err := os.WriteFile(summaryFile, []byte("# code-pass run "+runID+"\n\n"), 0o600); err != nil {
		return err
	}
	out := os.Stdout
	fmt.Fprintln(out, "code-pass run:", runID)
	fmt.Fprintln(out, "Project:", project)
	fmt.Fprintln(out, "Scan mode:", scanMode)
	fmt.Fprintln(out, "Max rounds:", maxRounds)
	fmt.Fprintln(out, "Output:", runDir)
	previousDigest := ""
	for round := 1; round <= maxRounds; round++ {
		fmt.Fprintf(out, "\n=== Round %d/%d: Strix ===\n", round, maxRounds)
		scanDir := filepath.Join(runDir, "strix", fmt.Sprintf("round-%d", round))
		scanLogPath := filepath.Join(runDir, fmt.Sprintf("scan-round-%d.log", round))
		scanLog, logErr := os.OpenFile(scanLogPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if logErr != nil {
			return logErr
		}
		scanOptions, err := newScanOptions(project, mode, scanMode)
		if err != nil {
			_ = scanLog.Close()
			return err
		}
		scanOptions.outputDir = filepath.Join(runDir, "strix")
		scanOptions.runID = fmt.Sprintf("round-%d", round)
		if totalBudget := envString("CODE_PASS_MAX_TOTAL_BUDGET", envString("STRIX_MAX_BUDGET", "50")); totalBudget != "" {
			perRound, budgetErr := budgetPerAttempt(totalBudget, maxRounds)
			if budgetErr != nil {
				_ = scanLog.Close()
				return budgetErr
			}
			scanOptions.budget = perRound
		}
		if mode == uiAuto {
			scanOptions.output = &lockedWriter{writers: []io.Writer{out, scanLog}}
		} else {
			scanOptions.output = out
		}
		scanErr := runScan(ctx, scanOptions)
		_ = scanLog.Close()
		if scanErr != nil {
			appendSummary(summaryFile, fmt.Sprintf("- round=%d status=scan_failed\n", round))
			return &exitError{code: 1, err: fmt.Errorf("Strix failed or produced an incomplete scan: %w", scanErr)}
		}
		statusFile := filepath.Join(scanDir, "scan-status.txt")
		sarifFile := filepath.Join(scanDir, "findings.sarif")
		status := firstLineValue(statusFile, "status=")
		if status != "success" || !fileRegularNonEmpty(sarifFile) {
			appendSummary(summaryFile, fmt.Sprintf("- round=%d status=scan_failed\n", round))
			return &exitError{code: 1, err: fmt.Errorf("Strix did not produce a successful result in %s", scanDir)}
		}
		document, err := parseSARIF(sarifFile)
		if err != nil {
			return &exitError{code: 1, err: err}
		}
		fingerprints, _, _ := document.findings()
		fingerprintFile := filepath.Join(runDir, fmt.Sprintf("findings-round-%d.txt", round))
		digest, err := writeFingerprints(fingerprintFile, fingerprints)
		if err != nil {
			return err
		}
		findings := len(fingerprints)
		appendSummary(summaryFile, fmt.Sprintf("- round=%d status=scan_ok findings=%d fingerprint=%s\n", round, findings, digest))
		fmt.Fprintln(out, "Findings:", findings)
		fmt.Fprintln(out, "Finding fingerprint:", digest)
		if findings == 0 {
			appendSummary(summaryFile, "- result=pass\n")
			fmt.Fprintln(out, "PASS: no findings remain.")
			return nil
		}
		if previousDigest != "" && digest == previousDigest {
			appendSummary(summaryFile, "- result=stalled reason=repeated-finding-fingerprint\n")
			return &exitError{code: 3, err: errors.New("the same findings returned after remediation; no more Pi tokens will be spent")}
		}
		previousDigest = digest
		if round == maxRounds {
			appendSummary(summaryFile, "- result=round_limit\n")
			return &exitError{code: 3, err: errors.New("maximum rounds reached with findings remaining")}
		}
		fmt.Fprintf(out, "=== Round %d/%d: Pi ===\n", round, maxRounds)
		piRoot := filepath.Join(runDir, "pi", fmt.Sprintf("round-%d", round))
		if err := os.MkdirAll(piRoot, 0o700); err != nil {
			return err
		}
		piLogPath := filepath.Join(runDir, fmt.Sprintf("pi-round-%d.log", round))
		piLog, err := os.OpenFile(piLogPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			return err
		}
		fixOptions, err := newFixOptions(project, scanDir, mode)
		if err != nil {
			_ = piLog.Close()
			return err
		}
		fixOptions.outputDir = piRoot
		if mode == uiAuto {
			fixOptions.output = &lockedWriter{writers: []io.Writer{out, piLog}}
		} else {
			fixOptions.output = out
		}
		fixErr := runFix(ctx, fixOptions)
		_ = piLog.Close()
		if fixErr != nil {
			appendSummary(summaryFile, fmt.Sprintf("- round=%d status=pi_failed\n", round))
			return &exitError{code: 1, err: fmt.Errorf("Pi failed: %w", fixErr)}
		}
		diffPath := firstNamedFile(piRoot, "changes.diff")
		if diffPath == "" {
			return &exitError{code: 3, err: errors.New("Pi did not produce changes.diff; no-progress state is unknown")}
		}
		changed := changedPaths(diffPath)
		if len(changed) == 0 {
			appendSummary(summaryFile, fmt.Sprintf("- round=%d result=stalled reason=pi_no_change\n", round))
			return &exitError{code: 3, err: errors.New("Pi made no repository change")}
		}
		appendSummary(summaryFile, fmt.Sprintf("- round=%d pi_changed_files=%d\n", round, len(changed)))
		fmt.Fprintf(out, "Pi changed %d file(s); the next scan is the only allowed retry.\n", len(changed))
	}
	appendSummary(summaryFile, "- result=round_limit\n")
	return &exitError{code: 3, err: errors.New("maximum rounds reached")}
}

func appendSummary(path, line string) {
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	_, _ = file.WriteString(line)
	_ = file.Close()
}

func firstNamedFile(root, name string) string {
	paths := allFilesNamed([]string{root}, name)
	if len(paths) == 0 {
		return ""
	}
	return paths[0]
}

func changedPaths(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	set := make(map[string]bool)
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "diff --git a/") {
			continue
		}
		line = strings.TrimPrefix(line, "diff --git a/")
		if index := strings.Index(line, " b/"); index >= 0 {
			set[line[:index]] = true
		}
	}
	paths := make([]string, 0, len(set))
	for path := range set {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths
}

func selfTest() error {
	dir, err := os.MkdirTemp("", "codepass-self-test.")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	sarif := filepath.Join(dir, "findings.sarif")
	content := `{"runs":[{"results":[{"ruleId":"R1","level":"warning","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/a.js"},"region":{"startLine":4}}}],"message":{"text":"same finding"}}]}]}`
	if err := os.WriteFile(sarif, []byte(content), 0o600); err != nil {
		return err
	}
	document, err := parseSARIF(sarif)
	if err != nil {
		return err
	}
	fingerprints, _, _ := document.findings()
	first, err := writeFingerprints(filepath.Join(dir, "one.txt"), fingerprints)
	if err != nil {
		return err
	}
	second, err := writeFingerprints(filepath.Join(dir, "two.txt"), fingerprints)
	if err != nil {
		return err
	}
	if first != second || len(fingerprints) != 1 {
		return errors.New("SARIF fingerprint self-test failed")
	}
	fmt.Println("codepass self-test: ok")
	return nil
}
