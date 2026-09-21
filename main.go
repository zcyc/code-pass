package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
)

const version = "0.2.0"

type exitError struct {
	code int
	err  error
}

func (e *exitError) Error() string { return e.err.Error() }
func (e *exitError) Unwrap() error { return e.err }

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		var exitErr *exitError
		if errors.As(err, &exitErr) {
			if exitErr.err != nil {
				fmt.Fprintln(os.Stderr, "ERROR:", exitErr.err)
			}
			os.Exit(exitErr.code)
		}
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		printUsage(os.Stderr)
		return &exitError{code: 2, err: errors.New("a command is required")}
	}

	switch args[0] {
	case "scan", "strix":
		return runScanCLI(ctx, args[1:])
	case "fix", "pi":
		return runFixCLI(ctx, args[1:])
	case "run", "codepass":
		return runLoopCLI(ctx, args[1:])
	case "self-test":
		return selfTest()
	case "help", "-h", "--help":
		printUsage(os.Stdout)
		return nil
	case "version", "--version":
		fmt.Println("codepass", version)
		return nil
	default:
		printUsage(os.Stderr)
		return &exitError{code: 2, err: fmt.Errorf("unknown command: %s", args[0])}
	}
}

func newFlagSet(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, `Usage:
  codepass scan [--interactive|--auto] <local-project-dir> [quick|standard|deep]
  codepass fix [--interactive|--auto] <local-project-dir> <strix-scan-result>
  codepass run [--interactive|--auto] [--max-rounds N] <local-project-dir> [quick|standard|deep]
  codepass self-test

Commands:
  scan       Copy, sanitize, and run a Strix scan.
  fix        Triage an explicitly selected Strix result with Pi.
  run        Run the bounded scan -> fix -> rescan workflow.

The original project is never modified by scan. fix may modify it unless
PI_FIX_DRY_RUN=true or PI_FIX_ALLOW_BREAKING=false.`)
}
