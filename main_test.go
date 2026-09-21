package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseDuration(t *testing.T) {
	tests := map[string]time.Duration{
		"3600":  time.Hour,
		"1h30m": 90 * time.Minute,
		"2.5s":  2500 * time.Millisecond,
	}
	for input, expected := range tests {
		actual, err := parseDuration("timeout", input)
		if err != nil || actual != expected {
			t.Fatalf("parseDuration(%q) = %s, %v; want %s", input, actual, err, expected)
		}
	}
	if _, err := parseDuration("timeout", "1x"); err == nil {
		t.Fatal("parseDuration accepted an invalid unit")
	}
}

func TestSARIFFindingsIgnoreCoverageAndStayStable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "findings.sarif")
	data := []byte(`{"runs":[{"results":[
{"ruleId":"R1","level":"warning","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/a.js"},"region":{"startLine":4}}}],"message":{"text":"same finding"}},
{"ruleId":"strix-coverage/missing","level":"note"}
]}]}`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	document, err := parseSARIF(path)
	if err != nil {
		t.Fatal(err)
	}
	fingerprints, total, coverage := document.findings()
	if len(fingerprints) != 1 || total != 2 || coverage != 1 {
		t.Fatalf("findings() = fingerprints=%d total=%d coverage=%d", len(fingerprints), total, coverage)
	}
	other, _, _ := document.findings()
	if fingerprints[0] != other[0] {
		t.Fatal("SARIF fingerprint is not stable")
	}
}

func TestPruneRemovesExcludedInputs(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "node_modules"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "node_modules", "ignored.js"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "keep.go"), []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dirs, files, err := prune(root)
	if err != nil {
		t.Fatal(err)
	}
	if dirs != 1 || files != 0 {
		t.Fatalf("prune() removed dirs=%d files=%d", dirs, files)
	}
	if _, err := os.Stat(filepath.Join(root, "keep.go")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "node_modules")); !os.IsNotExist(err) {
		t.Fatal("prune left node_modules behind")
	}
}
