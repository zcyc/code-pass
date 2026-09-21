package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

var prunedDirectoryNames = map[string]bool{
	"node_modules": true, "vendor": true, "vendors": true, "bower_components": true,
	"Pods": true, "DerivedData": true, "__pycache__": true, "dist": true,
	"build": true, "out": true, "coverage": true, "htmlcov": true,
	"strix_runs": true, ".pytest_cache": true, ".mypy_cache": true, ".ruff_cache": true,
}

var prunedFileSuffixes = map[string]bool{
	".log": true, ".zip": true, ".tar": true, ".gz": true, ".tgz": true, ".bz2": true,
	".xz": true, ".7z": true, ".rar": true, ".png": true, ".jpg": true, ".jpeg": true,
	".gif": true, ".webp": true, ".bmp": true, ".ico": true, ".svgz": true,
	".mp3": true, ".wav": true, ".ogg": true, ".mp4": true, ".mov": true, ".avi": true,
	".mkv": true, ".webm": true, ".ttf": true, ".otf": true, ".woff": true,
	".woff2": true, ".eot": true, ".so": true, ".dylib": true, ".dll": true,
	".a": true, ".o": true, ".obj": true, ".class": true, ".jar": true,
	".war": true, ".exe": true, ".bin": true, ".pyc": true, ".pyo": true,
}

func prune(root string) (dirs, files int, err error) {
	err = filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == root {
			return nil
		}
		name := entry.Name()
		if entry.IsDir() {
			if strings.HasPrefix(name, ".") || prunedDirectoryNames[name] || name == "target" {
				if removeErr := os.RemoveAll(path); removeErr != nil {
					return removeErr
				}
				dirs++
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 || !entry.Type().IsRegular() {
			if removeErr := os.Remove(path); removeErr != nil {
				return removeErr
			}
			files++
			return nil
		}
		if strings.HasPrefix(name, ".") || prunedFileSuffixes[strings.ToLower(filepath.Ext(name))] {
			if removeErr := os.Remove(path); removeErr != nil {
				return removeErr
			}
			files++
			return nil
		}
		file, openErr := os.Open(path)
		if openErr != nil {
			return openErr
		}
		var header [4]byte
		_, readErr := io.ReadFull(file, header[:])
		_ = file.Close()
		if readErr != nil && !errors.Is(readErr, io.EOF) && !errors.Is(readErr, io.ErrUnexpectedEOF) {
			return readErr
		}
		if binaryHeader(header[:]) {
			if removeErr := os.Remove(path); removeErr != nil {
				return removeErr
			}
			files++
		}
		return nil
	})
	if err != nil {
		return dirs, files, fmt.Errorf("prune encountered an inaccessible path: %w", err)
	}
	return dirs, files, nil
}

func binaryHeader(header []byte) bool {
	if len(header) >= 2 && string(header[:2]) == "MZ" {
		return true
	}
	if len(header) >= 4 && string(header[:4]) == "\x7fELF" {
		return true
	}
	if len(header) < 4 {
		return false
	}
	for _, magic := range []string{"\xcf\xfa\xed\xfe", "\xce\xfa\xed\xfe", "\xfe\xed\xfa\xcf", "\xfe\xed\xfa\xce"} {
		if string(header[:4]) == magic {
			return true
		}
	}
	return false
}

type ttyState struct {
	state string
}

func captureTTY(mode uiMode) *ttyState {
	if mode != uiInteractive || !isTerminal(os.Stdin) || !isTerminal(os.Stdout) {
		return nil
	}
	state, err := commandOutput("stty", "-g")
	if err != nil || trimOutput(state) == "" {
		return nil
	}
	return &ttyState{state: trimOutput(state)}
}

func (state *ttyState) restore() {
	if state == nil || state.state == "" {
		return
	}
	_, _ = commandOutput("stty", state.state)
	_, _ = os.Stdout.WriteString("\033[0m\033[?25h\033[?1l\033[?2004l")
}

func isTerminal(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
